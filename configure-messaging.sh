#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
HELPER="$SCRIPT_DIR/scripts/first-agent-helper.py"
VERIFY_SCRIPT="$SCRIPT_DIR/verify.sh"
LINE_TUNNEL_SCRIPT="$SCRIPT_DIR/line-tunnel-update.sh"
AGENT_ID=""
TERMINAL_ECHO_DISABLED=false

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn(){ printf 'WARNING: %s\n' "$*" >&2; }
validate_agent_id(){ [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "Agent ID must use lowercase letters, numbers, and single hyphens only."; }
check_single_line(){ case "$2" in *$'\n'*|*$'\r'*) die "$1 must be a single line";; esac; }

restore_terminal(){
  if [ "$TERMINAL_ECHO_DISABLED" = true ] && [ -t 0 ]; then
    stty echo 2>/dev/null || true
    TERMINAL_ECHO_DISABLED=false
    printf '\n' >&2
  fi
}
trap restore_terminal EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage(){
  cat <<'EOF'
Usage:
  bash configure-messaging.sh
  bash configure-messaging.sh --agent-id <agent-id>

Repairs messaging credentials/settings for an existing First Agent.
It does not create a new Agent and does not change the Agent's Tenant,
Business, SOUL, Skills, Memory, or LLM configuration.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent-id)
      [ "$#" -ge 2 ] || die "--agent-id requires a value"
      AGENT_ID="$2"
      shift 2
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

read_secret(){
  local label="$1" var="$2" value=""
  while [ -z "$value" ]; do
    printf '%s: ' "$label"
    if [ -t 0 ]; then
      stty -echo
      TERMINAL_ECHO_DISABLED=true
      IFS= read -r value
      stty echo
      TERMINAL_ECHO_DISABLED=false
      printf '\n'
    else
      IFS= read -r value
    fi
  done
  check_single_line "$label" "$value"
  printf -v "$var" '%s' "$value"
}

upsert_env_line(){
  local file="$1" key="$2" value="$3" tmp
  check_single_line "$key" "$value"
  tmp="$(mktemp "${TMPDIR:-/tmp}/first-agent-env.XXXXXX")"
  if [ -f "$file" ]; then
    grep -v -E "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$file"
  chmod 600 "$file"
}

env_value(){
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -m1 -E "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true
}

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


ensure_line_processing_indicator(){
  local config="$PROFILE_HOME/config.yaml"
  [ -f "$config" ] || return 1
  "$HERMES_PYTHON" - "$config" <<'PY'
import sys, yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

platforms = cfg.setdefault("gateway", {}).setdefault("platforms", {})
line = platforms.get("line")
if not isinstance(line, dict) or line.get("enabled") is not True:
    print("not-enabled")
    raise SystemExit(0)

extra = line.setdefault("extra", {})
changed = line.get("typing_indicator") is not True or extra.get("customer_clean_mode") is not False
line["typing_indicator"] = True
extra["customer_clean_mode"] = False

if changed:
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)

print("changed" if changed else "already")
PY
}

line_token_valid(){
  local token="$1"
  printf 'url = "https://api.line.me/v2/bot/info"\nheader = "Authorization: Bearer %s"\nsilent\nshow-error\nfail\nconnect-timeout = 10\nmax-time = 20\n' "$token" \
    | curl --config - >/dev/null 2>&1
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

platform_enabled(){
  case ",$GATEWAYS," in
    *,"$1",*) return 0;;
    *) return 1;;
  esac
}

restart_after_change(){
  if [ "$TOPOLOGY" = "multiplex" ]; then
    warn "Credentials were saved, but this Agent uses the shared multiplex gateway."
    warn "Restart/reload the shared gateway in a maintenance window before testing: hermes gateway restart"
    return 1
  fi
  say "Restarting gateway for $AGENT_ID..."
  if hermes -p "$AGENT_ID" gateway restart >/dev/null 2>&1; then
    say "✓ Gateway restarted."
    return 0
  fi
  warn "Credentials were saved, but the gateway restart failed."
  warn "Check: hermes -p $AGENT_ID gateway status"
  return 1
}

confirm_save_invalid(){
  local label="$1" answer
  warn "$label validation failed."
  read -r -p "Save it anyway for later correction/testing? [y/N]: " answer
  case "${answer,,}" in
    y|yes) return 0;;
    *) return 1;;
  esac
}

configure_line(){
  local choice token secret changed=false indicator_state
  platform_enabled line || { say "LINE is not enabled for this First Agent."; return 0; }

  indicator_state="$(ensure_line_processing_indicator || true)"
  if [ "$indicator_state" = "changed" ]; then
    chmod 600 "$PROFILE_HOME/config.yaml"
    say "✓ LINE processing indicator settings repaired."
    restart_after_change || true
  fi

  while true; do
    say ""
    say "LINE Configuration"
    say "------------------"
    say "  1) Replace Channel Access Token"
    say "  2) Replace Channel Secret"
    say "  3) Replace both Token and Secret"
    say "  4) Manage public HTTPS / Quick Tunnel / domain"
    say "  5) Verify LINE"
    say "  6) Back"
    read -r -p "Selection [6]: " choice
    choice="${choice:-6}"
    case "$choice" in
      1)
        read_secret "New LINE Channel Access Token" token
        if line_token_valid "$token"; then
          say "✓ LINE accepted the Channel Access Token."
        elif ! confirm_save_invalid "LINE Channel Access Token"; then
          unset token
          continue
        fi
        upsert_env_line "$ENV_FILE" LINE_CHANNEL_ACCESS_TOKEN "$token"
        unset token
        changed=true
        ;;
      2)
        read_secret "New LINE Channel Secret" secret
        upsert_env_line "$ENV_FILE" LINE_CHANNEL_SECRET "$secret"
        unset secret
        changed=true
        say "Channel Secret saved. Use Verify LINE to test webhook signature validation."
        ;;
      3)
        read_secret "New LINE Channel Access Token" token
        if line_token_valid "$token"; then
          say "✓ LINE accepted the Channel Access Token."
        elif ! confirm_save_invalid "LINE Channel Access Token"; then
          unset token
          continue
        fi
        read_secret "New LINE Channel Secret" secret
        upsert_env_line "$ENV_FILE" LINE_CHANNEL_ACCESS_TOKEN "$token"
        upsert_env_line "$ENV_FILE" LINE_CHANNEL_SECRET "$secret"
        unset token secret
        changed=true
        ;;
      4)
        [ -f "$LINE_TUNNEL_SCRIPT" ] || { warn "line-tunnel-update.sh not found."; continue; }
        bash "$LINE_TUNNEL_SCRIPT" --agent-id "$AGENT_ID"
        ;;
      5)
        [ -f "$VERIFY_SCRIPT" ] || { warn "verify.sh not found."; continue; }
        bash "$VERIFY_SCRIPT" --agent-id "$AGENT_ID" --messaging-only || true
        ;;
      6)
        break
        ;;
      *)
        say "Invalid selection."
        ;;
    esac

    if [ "$changed" = true ]; then
      restart_after_change || true
      changed=false
      say "Run verification when ready:"
      say "  bash $VERIFY_SCRIPT --agent-id $AGENT_ID --messaging-only"
    fi
  done
}

configure_telegram(){
  local choice token changed=false
  platform_enabled telegram || { say "Telegram is not enabled for this First Agent."; return 0; }

  while true; do
    say ""
    say "Telegram Configuration"
    say "----------------------"
    say "  1) Replace Bot Token"
    say "  2) Verify Telegram"
    say "  3) Back"
    read -r -p "Selection [3]: " choice
    choice="${choice:-3}"
    case "$choice" in
      1)
        read_secret "New Telegram Bot Token" token
        if telegram_token_valid "$token"; then
          say "✓ Telegram accepted the Bot Token."
        elif ! confirm_save_invalid "Telegram Bot Token"; then
          unset token
          continue
        fi
        upsert_env_line "$ENV_FILE" TELEGRAM_BOT_TOKEN "$token"
        unset token
        changed=true
        ;;
      2)
        [ -f "$VERIFY_SCRIPT" ] || { warn "verify.sh not found."; continue; }
        bash "$VERIFY_SCRIPT" --agent-id "$AGENT_ID" --messaging-only || true
        ;;
      3)
        break
        ;;
      *)
        say "Invalid selection."
        ;;
    esac

    if [ "$changed" = true ]; then
      restart_after_change || true
      changed=false
      say "Run verification when ready:"
      say "  bash $VERIFY_SCRIPT --agent-id $AGENT_ID --messaging-only"
    fi
  done
}

configure_weixin(){
  local answer access_mode
  platform_enabled weixin || { say "WeChat / Weixin is not enabled for this First Agent."; return 0; }

  say ""
  say "WeChat / Weixin uses Hermes native Tencent iLink QR setup."
  read -r -p "Re-run Hermes Weixin QR setup now? [y/N]: " answer
  case "${answer,,}" in
    y|yes)
      if hermes -p "$AGENT_ID" gateway setup; then
        access_mode="$(env_value FIRST_AGENT_ACCESS_MODE)"
        if [ "$access_mode" = "allow_all" ]; then
          upsert_env_line "$ENV_FILE" WEIXIN_ALLOW_ALL_USERS true
          upsert_env_line "$ENV_FILE" WEIXIN_DM_POLICY open
        else
          upsert_env_line "$ENV_FILE" WEIXIN_ALLOW_ALL_USERS false
          upsert_env_line "$ENV_FILE" WEIXIN_DM_POLICY pairing
        fi
        restart_after_change || true
      else
        warn "Weixin QR setup did not complete. Existing Agent data was kept."
      fi
      ;;
    *) say "No changes made.";;
  esac
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
[ -f "$MANIFEST" ] || die "FIRST_AGENT.yaml not found for $AGENT_ID"
"$HERMES_PYTHON" "$HELPER" verify-manifest --path "$MANIFEST" --agent-id "$AGENT_ID" >/dev/null
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

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

while true; do
  say ""
  say "First Agent Messaging Configuration"
  say "-----------------------------------"
  say "Agent:     $DISPLAY_NAME [$AGENT_ID]"
  say "Platforms: ${GATEWAYS:-none}"
  say ""
  say "  1) LINE"
  say "  2) Telegram"
  say "  3) WeChat / Weixin"
  say "  4) Verify messaging"
  say "  5) Exit"
  read -r -p "Selection [5]: " CHOICE
  CHOICE="${CHOICE:-5}"
  case "$CHOICE" in
    1) configure_line ;;
    2) configure_telegram ;;
    3) configure_weixin ;;
    4)
      [ -f "$VERIFY_SCRIPT" ] || { warn "verify.sh not found."; continue; }
      bash "$VERIFY_SCRIPT" --agent-id "$AGENT_ID" --messaging-only || true
      ;;
    5) exit 0;;
    *) say "Invalid selection.";;
  esac
done
