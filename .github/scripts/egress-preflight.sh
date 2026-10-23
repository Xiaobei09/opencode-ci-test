#!/usr/bin/env bash
# Preflight the exact OpenCode free-tier inference endpoint through one
# candidate egress. Exit 0 only when the endpoint answers 200 with a real
# completion (not a FreeUsageLimitError body).
#
# Usage: egress-preflight.sh <direct|relay|http> <target> [timeout-seconds]
#   relay <ip:port>  --connect-to opencode.ai:443:<ip>:<port> (TLS SNI kept)
#   http  <host:port> -x http://<host:port> (CONNECT proxy)
#   direct            no proxy
#
# Stdout: "<http-code>\t<reason>" (reason: ok|quota|transport|http_<code>|body_error)
set -uo pipefail

KIND="${1:?usage: egress-preflight.sh <direct|relay|http> <target> [timeout]}"
TARGET="${2:-}"
TMO="${3:-15}"

BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy

make_sid() {
  local hex rnd
  hex=$(openssl rand -hex 6 2>/dev/null || od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  rnd=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 14 || true)
  printf 'ses_%s%s' "$hex" "$rnd"
}

PAYLOAD='{"model":"big-pickle","stream":true,"messages":[{"role":"user","content":"Say hello"}],"tools":[{"type":"function","function":{"name":"read","description":"Read a file","parameters":{"type":"object","properties":{"filePath":{"type":"string","description":"Path to the file to read"}},"required":["filePath"]}}}]}'

ARGS=(--noproxy '*')
case "$KIND" in
  direct) ;;
  relay)
    ip=${TARGET%:*}; port=${TARGET##*:}
    [ -n "$ip" ] && [ -n "$port" ] || { echo -e "000\ttransport"; exit 1; }
    ARGS+=(--connect-to "opencode.ai:443:$ip:$port")
    ;;
  http)
    [ -n "$TARGET" ] || { echo -e "000\ttransport"; exit 1; }
    ARGS=(-x "http://$TARGET")
    ;;
  *) echo -e "000\tbad_kind"; exit 64 ;;
esac

code=$(curl -sS -o "$BODY" -w '%{http_code}' -m "$TMO" "${ARGS[@]}" \
  -X POST "https://opencode.ai/inference/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "User-Agent: opencode/1.18.32" \
  -H "Authorization: Bearer public" \
  -H "x-opencode-session: $(make_sid)" \
  -d "$PAYLOAD" 2>/dev/null)
[ -n "$code" ] || code=000

reason="ok"
if [ "$code" = "429" ]; then
  reason="quota"
elif [ "$code" = "000" ]; then
  reason="transport"
elif [ "$code" != "200" ]; then
  reason="http_$code"
elif grep -q 'FreeUsageLimitError' "$BODY" 2>/dev/null; then
  reason="body_error"
elif ! grep -q '"choices"\|data:' "$BODY" 2>/dev/null; then
  reason="body_error"
fi

printf '%s\t%s\n' "$code" "$reason"
[ "$reason" = "ok" ] && exit 0
exit 1
