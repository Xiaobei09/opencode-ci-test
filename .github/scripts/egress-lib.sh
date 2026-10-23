#!/usr/bin/env bash
# Shared state for the egress switcher.
#
# The blacklist is intentionally under $HOME/.config/opencode so the whole-$HOME
# snapshot carries it across runs. It is keyed by the candidate (entry ip:port),
# because that is what the preflight can address; the observed egress IP is
# stored alongside for diagnostics.
set -uo pipefail

EGRESS_STATE_DIR="${EGRESS_STATE_DIR:-${RUNNER_TEMP:-/tmp}/egress}"
EGRESS_BLACKLIST="${EGRESS_BLACKLIST:-$HOME/.config/opencode/egress-blacklist.json}"
EGRESS_UPSTREAM_FILE="$EGRESS_STATE_DIR/upstream"
EGRESS_EPOCH_FILE="$EGRESS_STATE_DIR/epoch"
EGRESS_CANDIDATES_FILE="$EGRESS_STATE_DIR/candidates.tsv"
EGRESS_STATE_FILE="$HOME/.config/opencode/exit-proxy.json"
EGRESS_LOCAL_PORT="${EGRESS_LOCAL_PORT:-8089}"

egress_now() { date +%s; }
egress_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

egress_bl_init() {
  mkdir -p "$(dirname "$EGRESS_BLACKLIST")" "$EGRESS_STATE_DIR"
  if [ ! -s "$EGRESS_BLACKLIST" ]; then
    printf '%s\n' '{"version":1,"entries":{}}' > "$EGRESS_BLACKLIST"
  fi
  chmod 600 "$EGRESS_BLACKLIST" 2>/dev/null || true
}

egress_bl_prune() {
  local now tmp
  now=$(egress_now)
  [ -s "$EGRESS_BLACKLIST" ] || return 0
  tmp=$(mktemp "${EGRESS_BLACKLIST}.XXXXXX") || return 0
  if jq --argjson now "$now" \
       '.entries |= with_entries(select((.value.until // 0) > $now))' \
       "$EGRESS_BLACKLIST" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$EGRESS_BLACKLIST"
    chmod 600 "$EGRESS_BLACKLIST" 2>/dev/null || true
  else
    rm -f "$tmp"
  fi
}

# egress_bl_has <key>
egress_bl_has() {
  local key="$1" now
  now=$(egress_now)
  jq -e --arg k "$key" --argjson now "$now" \
    '(.entries[$k].until // 0) > $now' "$EGRESS_BLACKLIST" >/dev/null 2>&1
}

# egress_bl_add <key> <egress> <reason> <ttl-seconds>
egress_bl_add() {
  local key="$1" egress="$2" reason="$3" ttl="${4:-21600}" until at tmp
  until=$(( $(egress_now) + ttl ))
  at=$(egress_iso)
  tmp=$(mktemp "${EGRESS_BLACKLIST}.XXXXXX") || return 1
  if jq --arg k "$key" --arg e "$egress" --arg r "$reason" \
        --argjson u "$until" --arg at "$at" \
        '.entries[$k] = ((.entries[$k] // {}) + {
           egress:$e, reason:$r, until:$u, at:$at,
           strikes:(((.entries[$k].strikes // 0) + 1))
         })' "$EGRESS_BLACKLIST" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$EGRESS_BLACKLIST"
    chmod 600 "$EGRESS_BLACKLIST" 2>/dev/null || true
  else
    rm -f "$tmp"
    return 1
  fi
}

egress_bl_del() {
  local key="$1" tmp
  tmp=$(mktemp "${EGRESS_BLACKLIST}.XXXXXX") || return 0
  if jq --arg k "$key" 'del(.entries[$k])' "$EGRESS_BLACKLIST" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$EGRESS_BLACKLIST"
    chmod 600 "$EGRESS_BLACKLIST" 2>/dev/null || true
  else
    rm -f "$tmp"
  fi
}

egress_epoch_bump() {
  local e
  e=$(cat "$EGRESS_EPOCH_FILE" 2>/dev/null || echo 0)
  echo $((e + 1)) > "$EGRESS_EPOCH_FILE"
}

# egress_write_upstream <direct|relay:ip:port|http:host:port>
egress_write_upstream() {
  printf '%s\n' "$1" > "$EGRESS_UPSTREAM_FILE"
  egress_epoch_bump
}

# egress_write_state <kind> <upstream> <egress_ip> <source> <direct_ip>
egress_write_state() {
  local kind="$1" upstream="$2" egress="$3" source="$4" direct="$5"
  mkdir -p "$(dirname "$EGRESS_STATE_FILE")"
  jq -n \
    --arg proxy "127.0.0.1:${EGRESS_LOCAL_PORT}" \
    --arg scheme "http" \
    --arg upstream "$upstream" \
    --arg kind "$kind" \
    --arg egress "$egress" \
    --arg direct "$direct" \
    --arg source "$source" \
    --arg at "$(egress_iso)" \
    '{proxy:$proxy, scheme:$scheme, upstream:$upstream, kind:$kind,
      egress_ip:$egress, direct_ip:$direct, latency_s:"",
      source:$source, picked_at:$at}' > "$EGRESS_STATE_FILE"
  chmod 600 "$EGRESS_STATE_FILE" 2>/dev/null || true
}

# egress_trace_relay <ip:port>
egress_trace_relay() {
  local hp="$1" ip port
  ip=${hp%:*}; port=${hp##*:}
  curl -sS -m 10 --noproxy '*' --connect-to "www.cloudflare.com:443:$ip:$port" \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | awk -F= '/^ip=/{print $2; exit}'
}

# egress_trace_http <host:port>
egress_trace_http() {
  local hp="$1"
  curl -sS -m 10 -x "http://$hp" \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | awk -F= '/^ip=/{print $2; exit}'
}

# egress_trace_direct
egress_trace_direct() {
  curl -sS -m 10 --noproxy '*' \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | awk -F= '/^ip=/{print $2; exit}'
}

# egress_candidate_ip <direct|relay|http> <target>
# Best-effort observed exit IP for a candidate. Used for diagnostics and for
# recording what an unavailable entry actually pointed at.
egress_candidate_ip() {
  local kind="$1" target="${2:-}"
  case "$kind" in
    direct) egress_trace_direct ;;
    relay)  egress_trace_relay "$target" ;;
    http)   egress_trace_http "$target" ;;
  esac
}
