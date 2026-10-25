#!/usr/bin/env bash
# Select the initial egress for this CI run and write a local-proxy handoff.
#
# This replaces the old "probe /zen/v1/models" logic: a 200 from that endpoint
# does NOT mean the free-tier quota is available. Every candidate is tested
# with the real inference call (egress-preflight.sh) and only a 200 switches.
#
# Outputs:
#   $RUNNER_TEMP/egress/upstream        direct | relay:ip:port | http:host:port
#   $RUNNER_TEMP/egress/candidates.tsv  ordered fallbacks for runtime rotation
#                                       (direct + proxyip relays; public HTTP
#                                       only with EGRESS_ALLOW_PUBLIC_HTTP=1)
#   $RUNNER_TEMP/exit-proxy.env         HTTP_PROXY=http://127.0.0.1:8089
#   $HOME/.config/opencode/exit-proxy.json
#   $HOME/.config/opencode/egress-blacklist.json (persisted, 0600)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
EGRESS_STATE_DIR="${EGRESS_STATE_DIR:-$RUNNER_TEMP/egress}"
export EGRESS_STATE_DIR
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

mkdir -p "$EGRESS_STATE_DIR"
: > "$EGRESS_CANDIDATES_FILE"
echo 0 > "$EGRESS_EPOCH_FILE"
egress_bl_init
egress_bl_prune

# R2501 (2026-10-23): time-to-first-good-egress is what delays the OpenCode step.
# Three changes keep the same correctness (every candidate still has to pass the
# REAL inference preflight) while cutting the worst case:
#   1. probe up to 4 candidates concurrently, in candidate order (so a good
#      direct IP still wins); failures are blacklisted exactly as before.
#   2. 8s per attempt instead of 12s — a healthy inference call returns in 1-3s;
#      12s only made dead relays slower to discard.
#   3. 48 candidates / 180s budget (was 80 / 240s). The reputation list is
#      ordered, and 48 misses in a row means the pool is unhealthy anyway.
#   4. the previous run's working relay is re-probed in the first batch even if
#      it is not near the head of the list (kills the "known-good but buried"
#      regression after a rotation).
SELECT_BUDGET="${EGRESS_SELECT_BUDGET:-180}"
SELECT_MAX="${EGRESS_SELECT_MAX:-48}"
PARALLEL="${EGRESS_PARALLEL:-4}"
PREFLIGHT_TMO="${EGRESS_PREFLIGHT_TIMEOUT:-8}"
# R2509: quota is account/model-wide (measured 2026-10-25: direct + 48 proxyip
# relays all answered 429 quota). Once direct itself answers quota, probing the
# whole relay list only delays startup; sample a few relays and then fall back
# to direct. Transport failures still use the full budget.
QUOTA_PROBE_MAX="${EGRESS_QUOTA_PROBE_MAX:-4}"
quota_fails=0
direct_quota=0
# A killed probe must not leave its curl/inference child running for the full
# timeout after we already picked a winner; timeout forwards TERM to the child.
PROBE_TIMEOUT=$((PREFLIGHT_TMO + 2))
[ "$PARALLEL" -ge 1 ] 2>/dev/null || PARALLEL=1
[ "$PARALLEL" -le 8 ] 2>/dev/null || PARALLEL=8
START=$(egress_now)

log() { echo "[egress-select] $*"; }

DIRECT_IP=$(egress_trace_direct)
DIRECT_COLO=$(curl -sS -m 10 --noproxy '*' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^colo=/{print $2}')
log "direct egress=${DIRECT_IP:-unknown} colo=${DIRECT_COLO:-?}"

# ---- candidate list -------------------------------------------------------
# 1) direct (a fresh runner IP is often the best bucket)
printf 'direct\t-\tdirect\n' >> "$EGRESS_CANDIDATES_FILE"

# 2) proxyip relay entries (non-CF ASN + CF edge ports; --connect-to relays TCP)
RELAY_SOURCE="${EGRESS_RELAY_SOURCE:-all_rep_verified.txt}"
RELAY_URL="https://raw.githubusercontent.com/Xiaobei09/proxyip/main/data/valid/$RELAY_SOURCE"
if curl -fsSL --retry 3 --retry-delay 2 --max-time 90 "$RELAY_URL" -o "$EGRESS_STATE_DIR/relays.txt"; then
  # all_rep_verified is reputation-ordered. Keep the head; dedupe entries.
  head -n 220 "$EGRESS_STATE_DIR/relays.txt" \
    | tr -d '\r' \
    | sed 's/#.*//' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$' \
    | awk '!seen[$0]++' \
    | while IFS= read -r hp; do printf 'relay\t%s\tproxyip\n' "$hp"; done \
    >> "$EGRESS_CANDIDATES_FILE"
  log "relay candidates: $(grep -c '^relay' "$EGRESS_CANDIDATES_FILE" || true) from $RELAY_SOURCE"
else
  log "relay source unavailable: $RELAY_URL"
fi

# 3) public HTTP CONNECT proxies are DISABLED by default. They are untrusted,
#    unstable, and can observe SNI metadata. Keep the code behind an explicit
#    opt-in for experiments; production uses direct + proxyip relays only.
if [ "${EGRESS_ALLOW_PUBLIC_HTTP:-0}" = "1" ]; then
  HTTP_SOURCES=(
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt"
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt"
    "https://raw.githubusercontent.com/jetkai/proxy-list/main/online-proxies/txt/proxies-http.txt"
    "https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTPS_RAW.txt"
  )
  i=0
  for url in "${HTTP_SOURCES[@]}"; do
    f="$EGRESS_STATE_DIR/http_$i.txt"
    i=$((i + 1))
    if curl -fsSL -m 25 "$url" -o "$f.raw" 2>/dev/null; then
      tr -d '\r' < "$f.raw" | sed 's/#.*//' \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$' | sort -u > "$f"
      head -n 80 "$f" | awk '!seen[$0]++' \
        | while IFS= read -r hp; do printf 'http\t%s\thttp-pool\n' "$hp"; done \
        >> "$EGRESS_CANDIDATES_FILE"
      log "http source $(wc -l < "$f") entries ${url}"
    else
      log "http source unavailable: ${url}"
    fi
  done
else
  log "public HTTP proxy pool disabled (set EGRESS_ALLOW_PUBLIC_HTTP=1 to enable)"
fi

# Deduplicate while preserving order.
awk -F'\t' '!seen[$1 FS $2]++' "$EGRESS_CANDIDATES_FILE" > "$EGRESS_CANDIDATES_FILE.tmp" \
  && mv "$EGRESS_CANDIDATES_FILE.tmp" "$EGRESS_CANDIDATES_FILE"
log "candidates: $(wc -l < "$EGRESS_CANDIDATES_FILE")"

# ---- prioritize the previous run's working relay (after direct) ------------
LAST_UP=$(jq -r '.upstream // ""' "$EGRESS_STATE_FILE" 2>/dev/null || true)
if [ "${LAST_UP#relay:}" != "$LAST_UP" ] && [ -n "${LAST_UP#relay:}" ]; then
  last_target="${LAST_UP#relay:}"
  # Keep direct first (fresh runner IP is still the preferred egress), then put
  # the known-good relay second. It may be buried deep in the reputation list;
  # this moves it (or inserts it when the list changed).
  awk -F'\t' -v OFS='\t' -v t="$last_target" '
    NR == 1 { print; print "relay", t, "last-good-relay"; next }
    $1 == "relay" && $2 == t { next }
    { print }
  ' "$EGRESS_CANDIDATES_FILE" > "$EGRESS_CANDIDATES_FILE.tmp" \
    && mv "$EGRESS_CANDIDATES_FILE.tmp" "$EGRESS_CANDIDATES_FILE"
  log "previous relay promoted: $last_target"
fi

# ---- pick the first candidate that passes the real preflight --------------
SELECTED_KIND=""; SELECTED_TARGET=""; SELECTED_SOURCE=""; SELECTED_UP=""; SELECTED_EGRESS=""
# Snapshot the ordered list, then probe small batches in parallel. We still pick
# the earliest candidate in list order that succeeds, so priority is unchanged.
mapfile -t CAND_LINES < "$EGRESS_CANDIDATES_FILE"
KIND=(); TARGET=(); SOURCE=()
for line in "${CAND_LINES[@]}"; do
  IFS=$'\t' read -r k t s <<< "$line"
  [ -n "${k:-}" ] || continue
  case "$k" in direct|relay|http) ;; *) continue ;; esac
  [ ${#KIND[@]} -ge "$SELECT_MAX" ] && break
  KIND+=("$k"); TARGET+=("${t:-}"); SOURCE+=("${s:-}")
done
log "selection plan: ${#KIND[@]} candidate(s), parallel=$PARALLEL, timeout=${PREFLIGHT_TMO}s"

i=0
while [ "$i" -lt "${#KIND[@]}" ] && [ -z "$SELECTED_KIND" ]; do
  now=$(egress_now)
  [ $((now - START)) -ge "$SELECT_BUDGET" ] && { log "selection budget exhausted"; break; }
  B_REC=(); B_KEYS=()
  batch_start=$i
  while [ "$i" -lt "${#KIND[@]}" ] && [ ${#B_REC[@]} -lt "$PARALLEL" ]; do
    kind="${KIND[$i]}"; target="${TARGET[$i]}"; source="${SOURCE[$i]}"
    idx=$i; i=$((i + 1))
    case "$kind" in
      direct) key="direct:${DIRECT_IP:-unknown}"; up="direct"; target="-" ;;
      relay)  key="relay:$target"; up="relay:$target" ;;
      http)   key="http:$target"; up="http:$target" ;;
    esac
    if egress_bl_has "$key"; then
      log "skip blacklisted $key"
      continue
    fi
    pf="$EGRESS_STATE_DIR/preflight.$$.$idx"
    rm -f "$pf"
    if [ "$kind" = "direct" ]; then
      timeout --signal=TERM --kill-after=2s "$PROBE_TIMEOUT" \
        bash "$SCRIPT_DIR/egress-preflight.sh" direct "" "$PREFLIGHT_TMO" > "$pf" 2>/dev/null &
    else
      timeout --signal=TERM --kill-after=2s "$PROBE_TIMEOUT" \
        bash "$SCRIPT_DIR/egress-preflight.sh" "$kind" "$target" "$PREFLIGHT_TMO" > "$pf" 2>/dev/null &
    fi
    B_REC+=("$idx|$kind|$target|$source|$key|$up|$pf|$!")
    B_KEYS+=("$key")
  done
  # Process the batch in list order, but do not wait for lower-priority probes
  # once the earliest success is known. The old `wait` made a healthy direct
  # candidate sit through the full 8s timeout of three dead relays; with 4-way
  # parallelism that wait was pure latency. We still wait for every candidate
  # *before* the winner, so priority is unchanged. Failures that were still
  # running at fast-exit are not blacklisted this round (they are retried next
  # run) — correctness of the chosen egress is unaffected.
  pos=0
  for rec in "${B_REC[@]+"${B_REC[@]}"}"; do
    IFS='|' read -r idx kind target source key up pf pid <<< "$rec"
    pos=$((pos + 1))
    if [ -n "${pid:-}" ]; then wait "$pid" 2>/dev/null || true; fi
    out=$(cat "$pf" 2>/dev/null || true); rm -f "$pf"
    code=${out%%$'\t'*}
    why=${out##*$'\t'}
    [ -n "$code" ] || code=000
    [ -n "$why" ] || why=transport
    if [ "$code" = "200" ] && [ "$why" = "ok" ]; then
      if [ -z "$SELECTED_KIND" ]; then
        SELECTED_KIND="$kind"; SELECTED_TARGET="$target"; SELECTED_SOURCE="$source"; SELECTED_UP="$up"
        case "$kind" in
          direct) SELECTED_EGRESS="${DIRECT_IP:-unknown}" ;;
          relay)  SELECTED_EGRESS=$(egress_trace_relay "$target") ;;
          http)   SELECTED_EGRESS=$(egress_trace_http "$target") ;;
        esac
        [ -n "$SELECTED_EGRESS" ] || SELECTED_EGRESS="unknown"
        egress_bl_del "$key"
        log "selected $kind $target egress=$SELECTED_EGRESS code=200 (batch=$batch_start)"
      fi
      # Stop paying for lower-priority probes as soon as the winner is known.
      killed=0
      for rec2 in "${B_REC[@]:$pos}"; do
        IFS='|' read -r _i2 _k2 _t2 _s2 _key2 _up2 pf2 pid2 <<< "$rec2"
        if [ -n "${pid2:-}" ]; then
          if kill "$pid2" 2>/dev/null; then killed=$((killed + 1)); fi
          rm -f "$pf2"
        fi
      done
      log "fast-exit after success (killed=$killed lower-priority probe(s))"
      break
    fi
    ttl=21600
    [ "$why" = "transport" ] && ttl=1800
    [ "$why" = "quota" ] && ttl=1800
    if [ "$why" = "quota" ]; then
      quota_fails=$((quota_fails + 1))
      [ "$kind" = "direct" ] && direct_quota=1
    fi
    if [ "$kind" = "direct" ]; then
      failed_egress="${DIRECT_IP:-}"
    elif [ "$why" = "quota" ] || [ "$why" = "body_error" ]; then
      # Only trace quota failures: a dead relay would burn the trace timeout for
      # no diagnostic value, and the entry address is enough to blacklist it.
      failed_egress=$(egress_candidate_ip "$kind" "$target" 2>/dev/null || true)
    else
      failed_egress=""
    fi
    # R2509: never blacklist direct for quota — it is the fallback route and
    # quota follows the account, not this runner's IP.
    if [ "$kind" = "direct" ] && [ "$why" = "quota" ]; then
      log "candidate direct failed code=$code reason=quota egress=${failed_egress:-?} (kept as fallback)"
    else
      egress_bl_add "$key" "$failed_egress" "$why" "$ttl" || true
      log "candidate $kind $target failed code=$code reason=$why egress=${failed_egress:-?} (blacklist ${ttl}s)"
    fi
  done
  if [ "$direct_quota" = 1 ] && [ "$quota_fails" -ge "$QUOTA_PROBE_MAX" ] && [ -z "$SELECTED_KIND" ]; then
    log "quota on direct + $quota_fails relay(s): account-wide quota, stop probing (budget ${QUOTA_PROBE_MAX} relays)"
    break
  fi
done

if [ -z "$SELECTED_KIND" ]; then
  log "no candidate passed; falling back to direct (the next run gets a fresh runner IP)"
  SELECTED_KIND="direct"; SELECTED_TARGET="-"; SELECTED_SOURCE="fallback-direct"
  SELECTED_UP="direct"; SELECTED_EGRESS="${DIRECT_IP:-unknown}"
fi

egress_write_upstream "$SELECTED_UP"
egress_write_state "$SELECTED_KIND" "$SELECTED_UP" "$SELECTED_EGRESS" "$SELECTED_SOURCE" "${DIRECT_IP:-unknown}"

# ---- handoff to the Run OpenCode step ------------------------------------
NO_PROXY_LIST="localhost,127.0.0.1,::1,api.telegram.org,github.com,api.github.com,objects.githubusercontent.com,release-assets.githubusercontent.com,raw.githubusercontent.com,codeload.github.com,registry.npmjs.org"
{
  echo "HTTP_PROXY=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "HTTPS_PROXY=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "http_proxy=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "https_proxy=http://127.0.0.1:${EGRESS_LOCAL_PORT}"
  echo "NO_PROXY=${NO_PROXY_LIST}"
  echo "no_proxy=${NO_PROXY_LIST}"
} > "$RUNNER_TEMP/exit-proxy.env"
chmod 600 "$RUNNER_TEMP/exit-proxy.env" 2>/dev/null || true

echo "[egress-select] upstream=$SELECTED_UP kind=$SELECTED_KIND egress=$SELECTED_EGRESS source=$SELECTED_SOURCE direct=${DIRECT_IP:-unknown}"
exit 0
