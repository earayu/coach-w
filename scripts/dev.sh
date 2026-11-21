#!/usr/bin/env bash
# Start the whole server side locally: LiveKit server, token API and coach agent.
# No Docker needed. Each service logs to logs/<service>.log. Ctrl-C stops everything.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
logs="$root/logs"
mkdir -p "$logs"

if [[ ! -f "$root/.env" ]]; then
  echo "error: .env missing. cp .env.example .env and fill in DASHSCOPE_API_KEY" >&2
  exit 1
fi
# Load .env (KEY=value, unquoted). Variables already set in the shell win.
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  [[ -n "${!key+x}" ]] || export "$key=$value"
done <"$root/.env"
if [[ -z "${DASHSCOPE_API_KEY:-${QWEN_API_KEY:-}}" ]]; then
  echo "error: DASHSCOPE_API_KEY is empty in .env" >&2
  exit 1
fi
command -v uv >/dev/null || { echo "error: uv not found" >&2; exit 1; }

# LAN mode: a phone on the same Wi-Fi talks to this Mac. `--lan` picks the en0 address,
# or set COACHW_LAN_IP explicitly.
if [[ "${1:-}" == "--lan" && -z "${COACHW_LAN_IP:-}" ]]; then
  COACHW_LAN_IP="$(ipconfig getifaddr en0 || true)"
  [[ -n "$COACHW_LAN_IP" ]] || { echo "error: no en0 address; set COACHW_LAN_IP" >&2; exit 1; }
fi
livekit_net=()
if [[ -n "${COACHW_LAN_IP:-}" ]]; then
  livekit_net=(--bind 0.0.0.0 --node-ip "$COACHW_LAN_IP")
  export COACHW_API_HOST="${COACHW_API_HOST:-0.0.0.0}"
  export LIVEKIT_PUBLIC_URL="ws://$COACHW_LAN_IP:7880"
fi

livekit_bin="${LIVEKIT_SERVER_BIN:-$(command -v livekit-server || true)}"
if [[ -z "$livekit_bin" ]]; then
  livekit_bin="$root/.tools/bin/livekit-server"
  [[ -x "$livekit_bin" ]] || "$root/scripts/install-livekit.sh"
fi

pids=()
cleanup() {
  trap - INT TERM EXIT
  echo
  echo "stopping…"
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

wait_for() { # name, command
  for _ in $(seq 1 60); do
    if eval "$2" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  echo "error: $1 did not become ready, see logs/$1.log" >&2
  exit 1
}

(cd "$root/server" && uv sync --locked --quiet)
py="$root/server/.venv/bin/python"

echo "livekit → logs/livekit.log"
LIVEKIT_KEYS="$LIVEKIT_API_KEY: $LIVEKIT_API_SECRET" LIVEKIT_WEBHOOK_API_KEY="$LIVEKIT_API_KEY" \
  "$livekit_bin" --config "$root/deploy/livekit.dev.yaml" ${livekit_net[@]+"${livekit_net[@]}"} \
  >"$logs/livekit.log" 2>&1 &
pids+=($!)
wait_for livekit "curl -fsS http://127.0.0.1:7880"

echo "api     → logs/api.log"
"$py" -m coachw.api >"$logs/api.log" 2>&1 &
pids+=($!)
wait_for api "curl -fsS http://127.0.0.1:${COACHW_API_PORT:-8000}/healthz"

echo "agent   → logs/agent.log"
# DEBUG logs conversation text, which can hold spoken health numbers (spec 11)
"$py" -m coachw.agent dev --log-level "${LIVEKIT_LOG_LEVEL:-info}" >"$logs/agent.log" 2>&1 &
pids+=($!)
wait_for agent "grep -q 'registered worker' '$logs/agent.log'"

cat <<EOF

coach-w server is up:
  LiveKit:   ${LIVEKIT_PUBLIC_URL:-$LIVEKIT_URL}
  Token API: http://${COACHW_LAN_IP:-127.0.0.1}:${COACHW_API_PORT:-8000}/v1/session
  Logs:      logs/{livekit,api,agent}.log
Ctrl-C stops all services.
EOF

wait
