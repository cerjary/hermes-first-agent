#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
HELPER="$SCRIPT_DIR/scripts/first-agent-helper.py"
AGENT_ID=""
INITIAL=false
STOP_MANAGED=false

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
validate_agent_id(){ [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "Agent ID must use lowercase letters, numbers, and single hyphens only."; }

usage(){
  cat <<'EOF'
Usage:
  bash line-tunnel-update.sh
  bash line-tunnel-update.sh --agent-id <agent-id>
  bash line-tunnel-update.sh --agent-id <agent-id> --initial

Internal uninstall cleanup:
  bash line-tunnel-update.sh --agent-id <agent-id> --stop-managed
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent-id)
      [ "$#" -ge 2 ] || die "--agent-id requires a value"
      AGENT_ID="$2"
      shift 2
      ;;
    --initial)
      INITIAL=true
      shift
      ;;
    --stop-managed)
      STOP_MANAGED=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

find_hermes_install_dir(){
  local raw dir
  raw="$(hermes --version 2>/dev/null || true)"
  dir="$(printf '%s\n' "$raw" | sed -n 's/^Install directory:[[:space:]]*//p' | head -n 1)"
  if [ -n "$dir" ] && [ -d "$dir" ]; then printf '%s\n' "$dir"; return 0; fi
  if [ -d "$HERMES_ROOT/hermes-agent" ]; then printf '%s\n' "$HERMES_ROOT/hermes-agent"; return 0; fi
  return 1
}

find_hermes_python(){
  local install_dir="$1" candidate
  for candidate in "$install_dir/venv/bin/python" "$install_dir/.venv/bin/python"; do
    if [ -x "$candidate" ] && "$candidate" -c 'import yaml' >/dev/null 2>&1; then printf '%s\n' "$candidate"; return 0; fi
  done
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then command -v python3; return 0; fi
  return 1
}

[ -f "$HELPER" ] || die "First Agent lifecycle helper not found: $HELPER"
HERMES_INSTALL_DIR="$(find_hermes_install_dir)" || die "Cannot determine Hermes install directory"
HERMES_PYTHON="$(find_hermes_python "$HERMES_INSTALL_DIR")" || die "Cannot find Python with PyYAML"

if [ -z "$AGENT_ID" ]; then
  mapfile -t FIRST_AGENT_ROWS < <("$HERMES_PYTHON" "$HELPER" list-first-agents --hermes-root "$HERMES_ROOT")
  [ "${#FIRST_AGENT_ROWS[@]}" -gt 0 ] || die "No installed Hermes First Agents were found."

  say ""
  say "Installed Hermes First Agents:"
  say ""
  for idx in "${!FIRST_AGENT_ROWS[@]}"; do
    IFS=$'\t' read -r row_agent_id row_display_name row_version <<< "${FIRST_AGENT_ROWS[$idx]}"
    printf '  %d) %s  [%s]  v%s\n' "$((idx + 1))" "$row_display_name" "$row_agent_id" "$row_version"
  done
  say ""

  while true; do
    read -r -p "Select LINE First Agent [1-${#FIRST_AGENT_ROWS[@]}]: " SELECTION
    if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "${#FIRST_AGENT_ROWS[@]}" ]; then
      break
    fi
    say "Invalid selection."
  done
  IFS=$'\t' read -r AGENT_ID _ _ <<< "${FIRST_AGENT_ROWS[$((SELECTION - 1))]}"
fi

validate_agent_id "$AGENT_ID"
PROFILE_HOME="$HERMES_ROOT/profiles/$AGENT_ID"
MANIFEST="$PROFILE_HOME/FIRST_AGENT.yaml"
ENV_FILE="$PROFILE_HOME/.env"
[ -f "$MANIFEST" ] || die "FIRST_AGENT.yaml not found for $AGENT_ID"
"$HERMES_PYTHON" "$HELPER" verify-manifest --path "$MANIFEST" --agent-id "$AGENT_ID" >/dev/null

line_info(){
  "$HERMES_PYTHON" "$HELPER" line-info --path "$MANIFEST" --field "$1"
}

DISPLAY_NAME="$(line_info display_name)"
TOPOLOGY="$(line_info topology)"
LINE_PORT="$(line_info line_port)"
CURRENT_MODE="$(line_info mode)"
CURRENT_MANAGED_BY="$(line_info managed_by)"
CURRENT_PUBLIC_URL="$(line_info public_url)"
WEBHOOK_PATH="$(line_info webhook_path)"
CURRENT_WEBHOOK_URL="$(line_info webhook_url)"

if [ "$TOPOLOGY" = "multiplex" ]; then
  ORIGIN_PORT="$("$HERMES_PYTHON" "$HELPER" shared-listener-port --hermes-root "$HERMES_ROOT")" || die "Cannot determine the shared Hermes HTTP listener port"
else
  [ -n "$LINE_PORT" ] || die "LINE local port is missing from FIRST_AGENT.yaml"
  ORIGIN_PORT="$LINE_PORT"
fi
ORIGIN_URL="http://127.0.0.1:$ORIGIN_PORT"

RUNTIME_DIR="$PROFILE_HOME/runtime"
LOG_DIR="$PROFILE_HOME/logs"
PID_FILE="$RUNTIME_DIR/line-quick-tunnel.pid"
LOG_FILE="$LOG_DIR/line-quick-tunnel.log"

mkdir -p "$RUNTIME_DIR" "$LOG_DIR"
chmod 700 "$RUNTIME_DIR"

managed_quick_pid(){
  local pid cmd
  [ -f "$PID_FILE" ] || return 1
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$cmd" in
    *cloudflared*"$ORIGIN_URL"*) printf '%s\n' "$pid"; return 0;;
    *) return 1;;
  esac
}

stop_managed_quick(){
  local pid attempt
  if ! pid="$(managed_quick_pid)"; then
    rm -f "$PID_FILE"
    return 0
  fi
  say "Stopping First Agent-managed LINE Quick Tunnel (PID $pid)..."
  kill "$pid" 2>/dev/null || true
  for attempt in 1 2 3 4 5; do
    : "$attempt"
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    say "WARNING: Quick Tunnel process $pid did not stop; leaving its PID file for review."
    return 1
  fi
  rm -f "$PID_FILE"
  say "Quick Tunnel stopped."
}

if [ "$STOP_MANAGED" = true ]; then
  if [ "$CURRENT_MODE" = "cloudflare_quick" ] && [ "$CURRENT_MANAGED_BY" = "first-agent" ]; then
    stop_managed_quick
  fi
  exit 0
fi

show_current(){
  say ""
  say "LINE Public Access"
  say "------------------"
  say "Agent:       $DISPLAY_NAME [$AGENT_ID]"
  say "Topology:    $TOPOLOGY"
  say "Local port:  $ORIGIN_PORT"
  say "Mode:        $CURRENT_MODE"
  if [ -n "$CURRENT_PUBLIC_URL" ]; then
    say "Public URL:  $CURRENT_PUBLIC_URL"
    say "Webhook:     $CURRENT_WEBHOOK_URL"
  else
    say "Public URL:  not configured"
    say "Webhook path: $WEBHOOK_PATH"
  fi
}

set_access_state(){
  local mode="$1" managed_by="$2" public_url="$3"
  "$HERMES_PYTHON" "$HELPER" set-line-public-access     --path "$MANIFEST"     --env-path "$ENV_FILE"     --mode "$mode"     --managed-by "$managed_by"     --public-url "$public_url" >/dev/null
  CURRENT_MODE="$mode"
  CURRENT_MANAGED_BY="$managed_by"
  CURRENT_PUBLIC_URL="$public_url"
  if [ -n "$public_url" ]; then
    CURRENT_WEBHOOK_URL="${public_url%/}$WEBHOOK_PATH"
  else
    CURRENT_WEBHOOK_URL=""
  fi
}

origin_is_listening(){
  "$HERMES_PYTHON" -c '
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(1.5)
try:
    s.connect(("127.0.0.1", port))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
' "$ORIGIN_PORT"
}

create_quick_tunnel(){
  local pid public_url attempt
  [ "$TOPOLOGY" != "multiplex" ] || die "Automatic Quick Tunnel is disabled for multiplex gateways because the shared listener may serve other profiles. Use an existing HTTPS URL/domain instead."
  command -v cloudflared >/dev/null 2>&1 || die "cloudflared is not installed. Install it or choose an existing HTTPS URL."
  origin_is_listening || die "LINE gateway is not listening on $ORIGIN_URL. Check: hermes -p $AGENT_ID gateway status"

  if [ "$CURRENT_MODE" = "cloudflare_quick" ] && [ "$CURRENT_MANAGED_BY" = "first-agent" ]; then
    stop_managed_quick || die "Could not stop the previous First Agent-managed Quick Tunnel"
  fi

  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  say "Starting isolated Cloudflare Quick Tunnel for $ORIGIN_URL..."
  nohup cloudflared tunnel --url "$ORIGIN_URL" >"$LOG_FILE" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  chmod 600 "$PID_FILE"

  public_url=""
  for attempt in $(seq 1 30); do
    : "$attempt"
    if ! kill -0 "$pid" 2>/dev/null; then
      say "cloudflared exited before a Quick Tunnel URL was created."
      tail -n 20 "$LOG_FILE" >&2 || true
      rm -f "$PID_FILE"
      return 1
    fi
    public_url="$(grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$LOG_FILE" | head -n 1 || true)"
    [ -z "$public_url" ] || break
    sleep 1
  done

  if [ -z "$public_url" ]; then
    say "Timed out waiting for a trycloudflare.com URL."
    tail -n 20 "$LOG_FILE" >&2 || true
    stop_managed_quick || true
    return 1
  fi

  set_access_state "cloudflare_quick" "first-agent" "$public_url"
  say ""
  say "✓ Cloudflare Quick Tunnel ready"
  say "Public URL:  $CURRENT_PUBLIC_URL"
  say "LINE Webhook URL:"
  say "$CURRENT_WEBHOOK_URL"
  say ""
  say "Next in LINE Developers:"
  say "  1. Messaging API → Webhook URL"
  say "  2. Paste the URL above"
  say "  3. Click Verify"
  say "  4. Enable Use webhook"
  say ""
  say "Quick Tunnel is for testing only. The hostname changes when a new Quick Tunnel is created."
}

use_existing_url(){
  local public_url
  if [ "$CURRENT_MODE" = "cloudflare_quick" ] && [ "$CURRENT_MANAGED_BY" = "first-agent" ]; then
    stop_managed_quick || die "Could not stop the previous First Agent-managed Quick Tunnel"
  fi

  while true; do
    read -r -p "Public HTTPS base URL (example: https://line.example.com): " public_url
    public_url="${public_url%/}"
    case "$public_url" in
      https://*.*) break;;
      *) say "URL must be a public https:// hostname.";;
    esac
  done

  set_access_state "external" "user" "$public_url"
  say ""
  say "✓ LINE public URL recorded"
  say "Public URL:  $CURRENT_PUBLIC_URL"
  say "LINE Webhook URL:"
  say "$CURRENT_WEBHOOK_URL"
  say ""
  say "This script records the endpoint but does not modify or delete externally managed Cloudflare/DNS infrastructure."
}

show_current

say ""
say "Choose LINE public access:"
say "  1) Cloudflare Quick Tunnel (Testing only)"
say "     Creates an isolated temporary trycloudflare.com URL for this First Agent."
say "  2) Existing HTTPS URL / domain"
say "     Records an endpoint managed by you or existing infrastructure."
if [ "$INITIAL" = true ]; then
  say "  3) Configure later"
else
  say "  3) Keep current configuration and exit"
fi
read -r -p "Selection [3]: " CHOICE
CHOICE="${CHOICE:-3}"

case "$CHOICE" in
  1) create_quick_tunnel ;;
  2) use_existing_url ;;
  3)
    if [ "$INITIAL" = true ] && [ "$CURRENT_MODE" = "unconfigured" ]; then
      set_access_state "unconfigured" "none" ""
      say "LINE public HTTPS access is not configured yet."
      say "Run later: bash $SCRIPT_DIR/line-tunnel-update.sh --agent-id $AGENT_ID"
    else
      say "No changes made."
    fi
    ;;
  *) die "Invalid selection" ;;
esac
