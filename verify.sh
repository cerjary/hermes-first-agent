#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
HELPER="$SCRIPT_DIR/scripts/first-agent-helper.py"
AGENT_ID=""
MESSAGING_ONLY=false
FAILURES=0
WARNINGS=0

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
pass(){ printf '✓ %s\n' "$*"; }
warn(){ printf '⚠ %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
fail(){ printf '✗ %s\n' "$*"; FAILURES=$((FAILURES+1)); }
validate_agent_id(){ [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "Agent ID must use lowercase letters, numbers, and single hyphens only."; }

usage(){
  cat <<'EOF'
Usage:
  bash verify.sh
  bash verify.sh --agent-id <agent-id>
  bash verify.sh --agent-id <agent-id> --messaging-only

This script is read-only. It does not change credentials, webhook URLs,
gateway configuration, or Agent data.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent-id)
      [ "$#" -ge 2 ] || die "--agent-id requires a value"
      AGENT_ID="$2"
      shift 2
      ;;
    --messaging-only)
      MESSAGING_ONLY=true
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

env_value(){
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -m1 -E "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true
}

has_gateway(){
  if [ "$TOPOLOGY" = "multiplex" ]; then
    hermes gateway status >/dev/null 2>&1
  else
    hermes -p "$AGENT_ID" gateway status >/dev/null 2>&1
  fi
}

gateway_pids_for_profile(){
  "$HERMES_PYTHON" - "$AGENT_ID" <<'PY'
import os, sys
agent_id = sys.argv[1]
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    try:
        raw = open(f"/proc/{name}/cmdline", "rb").read()
    except (OSError, PermissionError):
        continue
    argv = [x.decode("utf-8", "replace") for x in raw.split(b"\0") if x]
    if not argv:
        continue
    try:
        g = argv.index("gateway")
    except ValueError:
        continue
    if g + 1 >= len(argv) or argv[g + 1] != "run":
        continue
    profile = None
    for i, arg in enumerate(argv):
        if arg in ("-p", "--profile") and i + 1 < len(argv):
            profile = argv[i + 1]
            break
        if arg.startswith("--profile="):
            profile = arg.split("=", 1)[1]
            break
    if profile == agent_id:
        print(name)
PY
}

listener_pids_for_port(){
  local port="$1"
  ss -H -ltnp "sport = :${port}" 2>/dev/null \
    | grep -oE 'pid=[0-9]+' \
    | cut -d= -f2 \
    | sort -u || true
}

pid_in_list(){
  local wanted="$1"
  shift || true
  local pid
  for pid in "$@"; do
    [ "$pid" = "$wanted" ] && return 0
  done
  return 1
}

quick_tunnel_pid(){
  local pid_file="$PROFILE_HOME/runtime/line-quick-tunnel.pid" pid
  [ -f "$pid_file" ] || return 1
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

line_token_valid(){
  local token="$1"
  printf 'url = "https://api.line.me/v2/bot/info"\nheader = "Authorization: Bearer %s"\nsilent\nshow-error\nfail\nconnect-timeout = 10\nmax-time = 20\n' "$token" \
    | curl --config - >/dev/null 2>&1
}

line_webhook_test(){
  local token="$1" endpoint="$2" payload response
  payload="$(mktemp "${TMPDIR:-/tmp}/first-agent-line-payload.XXXXXX")"
  response="$(mktemp "${TMPDIR:-/tmp}/first-agent-line-response.XXXXXX")"
  chmod 600 "$payload" "$response"
  "$HERMES_PYTHON" - "$endpoint" >"$payload" <<'PY'
import json, sys
print(json.dumps({"endpoint": sys.argv[1]}))
PY
  if ! printf 'url = "https://api.line.me/v2/bot/channel/webhook/test"\nrequest = "POST"\nheader = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\nsilent\nshow-error\nfail\nconnect-timeout = 10\nmax-time = 25\n' "$token" \
      | curl --config - --data-binary "@$payload" -o "$response" 2>/dev/null; then
    rm -f "$payload" "$response"
    return 1
  fi
  if "$HERMES_PYTHON" - "$response" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if data.get("success") is True else 1)
PY
  then
    rm -f "$payload" "$response"
    return 0
  fi
  rm -f "$payload" "$response"
  return 1
}

line_channel_endpoint_info(){
  local token="$1" response
  response="$(mktemp "${TMPDIR:-/tmp}/first-agent-line-endpoint.XXXXXX")"
  chmod 600 "$response"
  if ! printf 'url = "https://api.line.me/v2/bot/channel/webhook/endpoint"\nheader = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\nsilent\nshow-error\nfail\nconnect-timeout = 10\nmax-time = 20\n' "$token" \
      | curl --config - -o "$response" 2>/dev/null; then
    rm -f "$response"
    return 1
  fi
  "$HERMES_PYTHON" - "$response" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(str(data.get("endpoint") or ""))
print("true" if data.get("active") is True else "false")
PY
  rm -f "$response"
}

telegram_token_valid(){
  local token="$1" response
  if ! response="$(
    printf 'url = "https://api.telegram.org/bot%s/getMe"\nsilent\nshow-error\nfail\nconnect-timeout = 10\nmax-time = 20\n' "$token" \
      | curl --config - 2>/dev/null
  )"; then
    return 1
  fi
  "$HERMES_PYTHON" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if data.get("ok") is True else 1)
' <<< "$response"
}


line_processing_indicator_ready(){
  [ -f "$CONFIG_FILE" ] || return 1
  "$HERMES_PYTHON" - "$CONFIG_FILE" <<'PY'
import sys, yaml

with open(sys.argv[1], encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

line = ((cfg.get("gateway") or {}).get("platforms") or {}).get("line") or {}
extra = line.get("extra") or {}
raise SystemExit(
    0 if line.get("typing_indicator") is True and extra.get("customer_clean_mode") is False else 1
)
PY
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
    read -r -p "Select First Agent [1-${#FIRST_AGENT_ROWS[@]}]: " SELECTION
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
CONFIG_FILE="$PROFILE_HOME/config.yaml"
[ -f "$MANIFEST" ] || die "FIRST_AGENT.yaml not found for $AGENT_ID"

MANIFEST_VERSION="$("$HERMES_PYTHON" "$HELPER" verify-manifest --path "$MANIFEST" --agent-id "$AGENT_ID")"
IFS=$'\t' read -r DISPLAY_NAME TOPOLOGY GATEWAYS <<< "$("$HERMES_PYTHON" - "$MANIFEST" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}
print(
    str(data.get("display_name") or data.get("agent_id") or ""),
    str(data.get("gateway_topology") or "standalone"),
    ",".join(str(x) for x in (data.get("gateways") or [])),
    sep="\t",
)
PY
)"

say ""
say "First Agent Verification"
say "------------------------"
say "Agent:    $DISPLAY_NAME [$AGENT_ID]"
say "Version:  $MANIFEST_VERSION"
say "Topology: $TOPOLOGY"
say ""

if [ "$MESSAGING_ONLY" = false ]; then
  say "Core"
  say "----"
  pass "FIRST_AGENT.yaml is valid"
  if [ -f "$CONFIG_FILE" ]; then
    pass "config.yaml exists"
  else
    fail "config.yaml is missing"
  fi
  if [ -f "$ENV_FILE" ]; then
    pass ".env exists"
  else
    fail ".env is missing"
  fi

  ACCESS_MODE="$(env_value FIRST_AGENT_ACCESS_MODE)"
  case "$ACCESS_MODE" in
    passcode)
      if [ -n "$(env_value FIRST_AGENT_PASSCODE_SALT)" ] \
        && [ -n "$(env_value FIRST_AGENT_PASSCODE_HASH)" ] \
        && [ -n "$(env_value FIRST_AGENT_PASSCODE_ITERATIONS)" ]; then
        pass "Company passcode access control is configured"
      else
        fail "Company passcode access control is incomplete"
      fi
      ;;
    allow_all)
      warn "Access control is allow-all (testing only)"
      ;;
    *)
      fail "FIRST_AGENT_ACCESS_MODE is missing or unsupported"
      ;;
  esac

  if hermes -p "$AGENT_ID" doctor >/dev/null 2>&1; then
    pass "Hermes doctor completed without errors"
  else
    warn "Hermes doctor reported unresolved items"
  fi

  if hermes -p "$AGENT_ID" chat -q "Reply only: OK" >/dev/null 2>&1; then
    pass "LLM smoke test passed"
  else
    fail "LLM smoke test failed"
  fi
  say ""
fi

say "Gateway"
say "-------"
GATEWAY_PIDS=()
if [ "$TOPOLOGY" = "standalone" ]; then
  mapfile -t GATEWAY_PIDS < <(gateway_pids_for_profile)
  if [ "${#GATEWAY_PIDS[@]}" -eq 0 ]; then
    fail "No running gateway process was found for profile $AGENT_ID"
  elif [ "${#GATEWAY_PIDS[@]}" -eq 1 ]; then
    pass "Gateway process is running for this profile (PID ${GATEWAY_PIDS[0]})"
  else
    fail "Multiple gateway processes are running for this profile (PIDs: ${GATEWAY_PIDS[*]})"
  fi

  SERVICE_NAME="hermes-gateway-${AGENT_ID}.service"
  if systemctl --user show "$SERVICE_NAME" >/dev/null 2>&1; then
    SERVICE_ACTIVE="$(systemctl --user show "$SERVICE_NAME" -p ActiveState --value 2>/dev/null || true)"
    SERVICE_SUB="$(systemctl --user show "$SERVICE_NAME" -p SubState --value 2>/dev/null || true)"
    SERVICE_PID="$(systemctl --user show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || true)"
    SERVICE_RESTARTS="$(systemctl --user show "$SERVICE_NAME" -p NRestarts --value 2>/dev/null || true)"

    if [ "$SERVICE_ACTIVE" = "active" ] && [ "$SERVICE_SUB" = "running" ] \
      && [[ "$SERVICE_PID" =~ ^[1-9][0-9]*$ ]] \
      && pid_in_list "$SERVICE_PID" "${GATEWAY_PIDS[@]}"; then
      pass "Profile gateway user service owns the running gateway"
    elif [ "$SERVICE_ACTIVE" = "active" ] || [ "$SERVICE_ACTIVE" = "activating" ]; then
      warn "Profile gateway user service is $SERVICE_ACTIVE/$SERVICE_SUB but does not own the stable profile gateway process; possible duplicate supervisor"
    elif [ "$SERVICE_ACTIVE" = "failed" ]; then
      warn "Profile gateway user service is failed"
    elif [ "${#GATEWAY_PIDS[@]}" -gt 0 ]; then
      pass "Gateway is running under an external supervisor (profile user service is $SERVICE_ACTIVE)"
    fi

    if [[ "$SERVICE_RESTARTS" =~ ^[0-9]+$ ]] && [ "$SERVICE_RESTARTS" -ge 3 ] \
      && { [ "$SERVICE_ACTIVE" = "active" ] || [ "$SERVICE_ACTIVE" = "activating" ]; }; then
      warn "Profile gateway user service has restarted $SERVICE_RESTARTS times; check for a restart loop or competing supervisor"
    fi
  fi
else
  if has_gateway; then
    pass "Shared gateway status command reports available"
  else
    fail "Shared gateway is not healthy or not running"
  fi
fi
say ""

case ",$GATEWAYS," in
  *,line,*)
    say "LINE"
    say "----"
    LINE_TOKEN="$(env_value LINE_CHANNEL_ACCESS_TOKEN)"
    LINE_SECRET="$(env_value LINE_CHANNEL_SECRET)"

    if [ -n "$LINE_TOKEN" ]; then
      if line_token_valid "$LINE_TOKEN"; then
        pass "Channel Access Token is accepted by LINE"
      else
        fail "Channel Access Token was rejected by LINE"
      fi
    else
      fail "Channel Access Token is missing"
    fi

    if [ -n "$LINE_SECRET" ]; then
      pass "Channel Secret is present"
    else
      fail "Channel Secret is missing"
    fi

    if line_processing_indicator_ready; then
      pass "LINE processing indicator configuration is enabled"
    else
      fail "LINE processing indicator configuration is incomplete (requires typing_indicator=true and extra.customer_clean_mode=false)"
    fi

    if [ "$TOPOLOGY" = "multiplex" ]; then
      LINE_PORT="$("$HERMES_PYTHON" "$HELPER" shared-listener-port --hermes-root "$HERMES_ROOT" 2>/dev/null || true)"
    else
      LINE_PORT="$("$HERMES_PYTHON" "$HELPER" line-info --path "$MANIFEST" --field line_port 2>/dev/null || true)"
    fi
    WEBHOOK_PATH="$("$HERMES_PYTHON" "$HELPER" line-info --path "$MANIFEST" --field webhook_path 2>/dev/null || true)"
    PUBLIC_URL="$("$HERMES_PYTHON" "$HELPER" line-info --path "$MANIFEST" --field public_url 2>/dev/null || true)"
    WEBHOOK_URL="$("$HERMES_PYTHON" "$HELPER" line-info --path "$MANIFEST" --field webhook_url 2>/dev/null || true)"

    LOCAL_LINE_HEALTH=false
    if [ -n "$LINE_PORT" ]; then
      mapfile -t LINE_LISTENER_PIDS < <(listener_pids_for_port "$LINE_PORT")
      if [ "${#LINE_LISTENER_PIDS[@]}" -eq 0 ]; then
        fail "No process is listening on configured LINE port $LINE_PORT"
      elif [ "$TOPOLOGY" = "standalone" ] && [ "${#GATEWAY_PIDS[@]}" -gt 0 ]; then
        LINE_OWNER_OK=false
        for listener_pid in "${LINE_LISTENER_PIDS[@]}"; do
          if pid_in_list "$listener_pid" "${GATEWAY_PIDS[@]}"; then
            LINE_OWNER_OK=true
            break
          fi
        done
        if [ "$LINE_OWNER_OK" = true ]; then
          pass "Configured LINE port $LINE_PORT is owned by this profile gateway"
        else
          fail "Configured LINE port $LINE_PORT is owned by another process"
        fi
      else
        pass "Configured LINE port $LINE_PORT has a listener"
      fi

      if curl -fsS --connect-timeout 3 --max-time 8 "http://127.0.0.1:${LINE_PORT}${WEBHOOK_PATH}/health" >/dev/null 2>&1; then
        LOCAL_LINE_HEALTH=true
        pass "Local LINE webhook health check passed on port $LINE_PORT"
      else
        fail "Local LINE webhook backend is unavailable on port $LINE_PORT"
      fi
    else
      fail "Configured LINE port is missing"
    fi

    case "$PUBLIC_URL" in
      https://*.trycloudflare.com*)
        if QUICK_TUNNEL_PID="$(quick_tunnel_pid 2>/dev/null)"; then
          QUICK_TUNNEL_CMD="$(tr '\0' ' ' < "/proc/$QUICK_TUNNEL_PID/cmdline" 2>/dev/null || true)"
          if [[ "$QUICK_TUNNEL_CMD" == *"cloudflared tunnel --url http://127.0.0.1:${LINE_PORT}"* ]]; then
            pass "Cloudflare Quick Tunnel process is running for LINE port $LINE_PORT (PID $QUICK_TUNNEL_PID)"
          else
            warn "Cloudflare Quick Tunnel process is running but its origin does not match LINE port $LINE_PORT"
          fi
        else
          fail "Cloudflare Quick Tunnel PID is missing or not running"
        fi
        ;;
    esac

    if [ -n "$PUBLIC_URL" ]; then
      pass "Public HTTPS URL is configured"
      if curl -fsS --connect-timeout 5 --max-time 12 "${PUBLIC_URL%/}${WEBHOOK_PATH}/health" >/dev/null 2>&1; then
        pass "Public LINE webhook health check passed"
      elif [ "$LOCAL_LINE_HEALTH" = false ]; then
        fail "Public LINE webhook health check failed because the local LINE backend is unavailable"
      else
        fail "Public LINE webhook health check failed while the local backend is healthy (check tunnel/DNS)"
      fi

      if [ -n "$LINE_TOKEN" ] && [ -n "$LINE_SECRET" ]; then
        if line_webhook_test "$LINE_TOKEN" "$WEBHOOK_URL"; then
          pass "LINE webhook signature/integration test passed"
        else
          fail "LINE webhook integration test failed (check Channel Secret and endpoint)"
        fi
      fi

      if [ -n "$LINE_TOKEN" ]; then
        if CHANNEL_RAW="$(line_channel_endpoint_info "$LINE_TOKEN" 2>/dev/null)"; then
          mapfile -t CHANNEL_INFO <<< "$CHANNEL_RAW"
          CHANNEL_ENDPOINT="${CHANNEL_INFO[0]:-}"
          CHANNEL_ACTIVE="${CHANNEL_INFO[1]:-false}"
          if [ "$CHANNEL_ENDPOINT" = "$WEBHOOK_URL" ]; then
            pass "LINE channel webhook endpoint matches this First Agent"
          else
            warn "LINE channel webhook endpoint does not match this First Agent URL"
          fi
          if [ "$CHANNEL_ACTIVE" = "true" ]; then
            pass "LINE Use webhook is enabled"
          else
            warn "LINE Use webhook is disabled"
          fi
        else
          warn "Could not read LINE channel webhook settings"
        fi
      fi
    else
      warn "LINE public HTTPS URL is not configured"
    fi
    say ""
    ;;
esac

case ",$GATEWAYS," in
  *,telegram,*)
    say "Telegram"
    say "--------"
    TELEGRAM_TOKEN="$(env_value TELEGRAM_BOT_TOKEN)"
    if [ -z "$TELEGRAM_TOKEN" ]; then
      fail "Telegram Bot Token is missing"
    elif telegram_token_valid "$TELEGRAM_TOKEN"; then
      pass "Telegram Bot Token is accepted by Telegram"
    else
      fail "Telegram Bot Token was rejected by Telegram"
    fi
    say ""
    ;;
esac

case ",$GATEWAYS," in
  *,weixin,*)
    say "WeChat / Weixin"
    say "---------------"
    warn "Weixin uses Hermes native QR identity; this script does not independently validate the QR session"
    say ""
    ;;
esac

say "Summary"
say "-------"
say "Failures: $FAILURES"
say "Warnings: $WARNINGS"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
