#!/usr/bin/env bash
# Move the local CONNECT proxy to the next candidate that passes the real
# inference preflight with HTTP 200. The current candidate is blacklisted for a
# while first, so a quota-exhausted relay is not retried immediately.
#
# Usage: egress-rotate.sh [--reason quota|transport|http]
#
# The candidate list is produced by select-proxy.sh:
#   <direct|relay|http>\t<target>\t<source>
# with target "-" for direct.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

REASON="${1:-quota}"
[ "$REASON" = "--reason" ] && REASON="${2:-quota}"
case "$REASON" in
  quota)     TTL=1800 ;;  # 30m: quota is usually account/model-wide, not IP-wide
  transport) TTL=1800 ;;  # 30m for dead relays
  *)         TTL=3600  ;;
esac

egress_bl_init
egress_bl_prune
mkdir -p "$EGRESS_STATE_DIR"
[ -f "$EGRESS_CANDIDATES_FILE" ] || { echo "rotate: no candidate list"; exit 1; }

CUR_KIND=$(jq -r '.kind // "direct"' "$EGRESS_STATE_FILE" 2>/dev/null || echo direct)
CUR_UP=$(jq -r '.upstream // "direct"' "$EGRESS_STATE_FILE" 2>/dev/null || echo direct)
DIRECT_IP=$(jq -r '.direct_ip // empty' "$EGRESS_STATE_FILE" 2>/dev/null || true)
[ -n "$DIRECT_IP" ] || DIRECT_IP=$(egress_trace_direct)
[ -n "$DIRECT_IP" ] || DIRECT_IP="unknown"

case "$CUR_KIND" in
  direct) CUR_KEY="direct:$DIRECT_IP" ;;
  *)      CUR_KEY="$CUR_UP" ;;
esac

# R2509: quota follows the account/model, not the egress IP (measured: direct +
# 48 relays all 429). Do not blacklist the current route for quota, and only
# sample a few relays before keeping it; transport failures still use the full
# candidate budget.
MAX_TRIES=${EGRESS_SELECT_MAX:-48}
[ "$REASON" = "quota" ] && MAX_TRIES=${EGRESS_QUOTA_PROBE_MAX:-4}

# Mark the current egress as unusable for a while. For a relay/http candidate
# the key is the entry address; the preflight that just failed was the same one.
CUR_EGRESS=$(jq -r '.egress_ip // empty' "$EGRESS_STATE_FILE" 2>/dev/null || true)
if [ "$REASON" = "quota" ]; then
  echo "rotate: quota is account-wide; keeping $CUR_KEY eligible (not blacklisted)"
else
  egress_bl_add "$CUR_KEY" "$CUR_EGRESS" "$REASON" "$TTL" || true
  echo "rotate: blacklisted $CUR_KEY ($REASON, ${TTL}s)"
fi

tries=0
quota_fails=0
other_fails=0
while IFS=$'\t' read -r kind target source; do
  [ -n "${kind:-}" ] || continue
  case "$kind" in
    direct) key="direct:$DIRECT_IP"; up="direct"; target="-" ;;
    relay)  key="relay:$target";     up="relay:$target" ;;
    http)   key="http:$target";      up="http:$target" ;;
    *) continue ;;
  esac

  [ "$up" = "$CUR_UP" ] && continue
  if egress_bl_has "$key"; then
    echo "rotate: skip blacklisted $key"
    continue
  fi
  tries=$((tries + 1))
  # Same tuning as select-proxy: 8s is enough for a real inference answer. Quota
  # rotations only sample EGRESS_QUOTA_PROBE_MAX relays (default 4); transport
  # rotations keep the full 48-candidate budget.
  [ "$tries" -gt "$MAX_TRIES" ] && { echo "rotate: candidate budget exhausted ($MAX_TRIES)"; break; }

  out=$(bash "$SCRIPT_DIR/egress-preflight.sh" "$kind" "$([ "$kind" = direct ] && echo '' || echo "$target")" "${EGRESS_PREFLIGHT_TIMEOUT:-8}" 2>/dev/null || true)
  code=${out%%$'\t'*}
  why=${out##*$'\t'}
  [ -n "$code" ] || code=000
  [ -n "$why" ] || why=transport

  if [ "$code" = "200" ] && [ "$why" = "ok" ]; then
    egress_write_upstream "$up"
    case "$kind" in
      direct) egress="$DIRECT_IP" ;;
      relay)  egress=$(egress_trace_relay "$target") ;;
      http)   egress=$(egress_trace_http "$target") ;;
    esac
    [ -n "$egress" ] || egress="unknown"
    egress_write_state "$kind" "$up" "$egress" "$source" "$DIRECT_IP"
    egress_bl_del "$key"
    echo "rotate: switched to $kind $target egress=$egress (source=$source)"
    exit 0
  fi

  if [ "$kind" = "direct" ]; then
    failed_egress="$DIRECT_IP"
  elif [ "$why" = "quota" ] || [ "$why" = "body_error" ]; then
    failed_egress=$(egress_candidate_ip "$kind" "$target" 2>/dev/null || true)
  else
    failed_egress=""
  fi
  if [ "$why" = "quota" ]; then quota_fails=$((quota_fails + 1)); else other_fails=$((other_fails + 1)); fi
  egress_bl_add "$key" "$failed_egress" "$why" "$TTL" || true
  echo "rotate: candidate $kind $target failed code=$code reason=$why egress=${failed_egress:-?}"
done < "$EGRESS_CANDIDATES_FILE"

# No alternative passed. The egress we were already using is still the best
# choice we have, so undo its blacklist entry instead of leaving the runner
# with no usable route (and a 30m hole in the candidate list). Quota failures
# are almost always account/model-wide: rotating IPs cannot buy quota back.
egress_bl_del "$CUR_KEY"
echo "rotate: no candidate passed the preflight; keeping current egress and unblacklisting $CUR_KEY (quota_fails=$quota_fails other_fails=$other_fails)"
if [ "$quota_fails" -gt 0 ] && [ "$other_fails" -eq 0 ]; then
  exit 2
fi
exit 1
