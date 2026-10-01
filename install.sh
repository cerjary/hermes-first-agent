#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
ROLLBACK_ACTIVE=false
OWNED_PROFILE=""
TERMINAL_ECHO_DISABLED=false
VERIFY_WARNINGS=0

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

restore_terminal(){
  if [ "$TERMINAL_ECHO_DISABLED" = true ] && [ -t 0 ]; then
    stty echo 2>/dev/null || true
    TERMINAL_ECHO_DISABLED=false
    printf '\n' >&2
  fi
}

rollback_install(){
  local profile="$1"
  [ -n "$profile" ] || return 0
  case "$profile" in
    *[!a-z0-9-]*|'') return 0;;
  esac
  local profile_home="$HERMES_ROOT/profiles/$profile"
  printf '\nInstallation failed. Rolling back newly created profile: %s\n' "$profile" >&2
  if [ -d "$profile_home" ]; then
    hermes profile delete "$profile" --yes >/dev/null 2>&1 || rm -rf -- "$profile_home"
  fi
  # Hermes 0.21.x may leave a deletion tombstone. This target did not exist
  # before this installer run, so removing this exact marker is safe rollback.
  if hermes profile --help 2>&1 | grep -q 'purge-identity'; then
    hermes profile purge-identity "$profile" >/dev/null 2>&1 || true
  fi
  rm -f -- "$HERMES_ROOT/profiles/.deleted/$profile" 2>/dev/null || true
  hermes profile alias "$profile" --remove >/dev/null 2>&1 || true
}

cleanup_on_exit(){
  local code=$?
  restore_terminal
  if [ "$code" -ne 0 ] && [ "$ROLLBACK_ACTIVE" = true ] && [ -n "$OWNED_PROFILE" ]; then
    rollback_install "$OWNED_PROFILE"
  fi
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

read_required(){
  local label="$1" var="$2" v=""
  while [ -z "$v" ]; do
    printf '%s: ' "$label"
    IFS= read -r v
  done
  printf -v "$var" '%s' "$v"
}

read_optional(){
  local label="$1" def="$2" var="$3" v=""
  [ -n "$def" ] && printf '%s [%s]: ' "$label" "$def" || printf '%s: ' "$label"
  IFS= read -r v
  [ -n "$v" ] || v="$def"
  printf -v "$var" '%s' "$v"
}

read_secret(){
  local label="$1" var="$2" v=""
  while [ -z "$v" ]; do
    printf '%s: ' "$label"
    if [ -t 0 ]; then
      stty -echo
      TERMINAL_ECHO_DISABLED=true
      IFS= read -r v
      stty echo
      TERMINAL_ECHO_DISABLED=false
      printf '\n'
    else
      IFS= read -r v
    fi
  done
  printf -v "$var" '%s' "$v"
}

normalize_code(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]_]+/-/g; s/[^a-z0-9-]+//g; s/^-+//; s/-+$//; s/-+/-/g'; }
validate_code(){ [[ "$2" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "$1 must use lowercase letters, numbers, and single hyphens only."; }
check_single_line(){ case "$2" in *$'\n'*|*$'\r'*) die "$1 must be a single line";; esac; }

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

find_hermes_install_dir(){
  local raw dir
  raw="$(hermes --version 2>/dev/null || true)"
  dir="$(printf '%s\n' "$raw" | sed -n 's/^Install directory:[[:space:]]*//p' | head -n 1)"
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    printf '%s\n' "$dir"
    return 0
  fi
  if [ -d "$HERMES_ROOT/hermes-agent" ]; then
    printf '%s\n' "$HERMES_ROOT/hermes-agent"
    return 0
  fi
  return 1
}

find_hermes_python(){
  local install_dir="$1" candidate
  for candidate in "$install_dir/venv/bin/python" "$install_dir/.venv/bin/python"; do
    if [ -x "$candidate" ] && "$candidate" -c 'import yaml' >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  return 1
}

has_named_gateway_processes(){
  ps -eo args= 2>/dev/null | awk '
    /gateway[[:space:]]+run/ {
      for (i = 1; i <= NF; i++) {
        if (($i == "-p" || $i == "--profile") && (i + 1) <= NF && $(i + 1) != "default") found = 1
        if ($i ~ /^--profile=/) { split($i, p, "="); if (p[2] != "default") found = 1 }
      }
    }
    END { exit found ? 0 : 1 }
  '
}

has_named_gateway_services(){
  # Check service definitions directly instead of invoking a service manager;
  # this remains fast on headless hosts without a user systemd session.
  local f
  for f in \
    "$HOME"/.config/systemd/user/hermes-gateway-*.service \
    /etc/systemd/system/hermes-gateway-*.service \
    "$HOME"/Library/LaunchAgents/ai.hermes.gateway-*.plist
  do
    [ -e "$f" ] && return 0
  done
  return 1
}

detect_gateway_topology(){
  if hermes gateway migrate --help 2>&1 | grep -q -- '--multiplex'; then
    # Do not silently migrate or assume that a newer Hermes checkout is already
    # multiplexing. Existing per-profile fleets stay isolated, and otherwise
    # multiplex is used only when the default profile explicitly configures it
    # or the running host gateway records served named profiles.
    if has_named_gateway_processes || has_named_gateway_services; then
      printf '%s\n' 'standalone-compat'
    elif "$HERMES_PYTHON" "$HELPER" multiplex-active --hermes-root "$HERMES_ROOT" >/dev/null 2>&1; then
      printf '%s\n' 'multiplex'
    else
      printf '%s\n' 'standalone-compat'
    fi
  else
    printf '%s\n' 'standalone'
  fi
}


has_profile_gateway_process(){
  local profile="$1"
  ps -eo args= 2>/dev/null | awk -v target="$profile" '
    /gateway[[:space:]]+run/ {
      for (i = 1; i <= NF; i++) {
        if (($i == "-p" || $i == "--profile") && (i + 1) <= NF && $(i + 1) == target) found = 1
        if ($i ~ /^--profile=/) { split($i, p, "="); if (p[2] == target) found = 1 }
      }
    }
    END { exit found ? 0 : 1 }
  '
}

has_default_gateway_process(){
  ps -eo args= 2>/dev/null | awk '
    /gateway[[:space:]]+run/ {
      named = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "-p" || $i == "--profile" || $i ~ /^--profile=/) named = 1
      }
      if (!named) found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

wait_for_gateway_process(){
  local profile="$1"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    : "$attempt"
    if [ "$profile" = "default" ]; then
      has_default_gateway_process && return 0
    else
      has_profile_gateway_process "$profile" && return 0
    fi
    sleep 1
  done
  return 1
}

ensure_gateway_service(){
  local topology="$1" target_profile retry_cmd
  local -a install_cmd

  if [ "$topology" = "multiplex" ]; then
    target_profile="default"
    if has_default_gateway_process; then
      say "Host multiplex gateway is already running; leaving it in place."
      return 0
    fi
    install_cmd=(hermes gateway install --start-now --start-on-login)
    retry_cmd="hermes gateway install --start-now --start-on-login"
    say "Installing and starting the host multiplex gateway service..."
  else
    target_profile="$AGENT_ID"
    if has_profile_gateway_process "$AGENT_ID"; then
      say "Gateway for $AGENT_ID is already running; leaving the existing process in place."
      return 0
    fi
    install_cmd=(hermes -p "$AGENT_ID" gateway install --start-now --start-on-login)
    if [ "$topology" = "standalone-compat" ]; then
      install_cmd+=(--force)
    fi
    retry_cmd="hermes -p $AGENT_ID gateway install --start-now --start-on-login"
    say "Installing and starting the gateway service for $AGENT_ID..."
  fi

  if ! "${install_cmd[@]}"; then
    say "WARNING: Gateway service installation/start failed. The First Agent profile was kept."
    say "Retry manually: $retry_cmd"
    VERIFY_WARNINGS=$((VERIFY_WARNINGS+1))
    return 1
  fi

  if ! wait_for_gateway_process "$target_profile"; then
    say "WARNING: Gateway service command completed, but no running gateway process was detected."
    say "Check manually: ${retry_cmd% install*} status"
    VERIFY_WARNINGS=$((VERIFY_WARNINGS+1))
    return 1
  fi

  say "Gateway is installed and running."
  return 0
}

[ -f "$SCRIPT_DIR/check-environment.sh" ] || die "check-environment.sh not found"
[ -f "$SCRIPT_DIR/scripts/first-agent-helper.py" ] || die "scripts/first-agent-helper.py not found"
say "Running environment preflight..."
bash "$SCRIPT_DIR/check-environment.sh" || die "Environment preflight failed"
VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
HERMES_INSTALL_DIR="$(find_hermes_install_dir)" || die "Cannot determine Hermes install directory"
HERMES_PYTHON="$(find_hermes_python "$HERMES_INSTALL_DIR")" || die "Cannot find Python with PyYAML for Hermes"
HELPER="$SCRIPT_DIR/scripts/first-agent-helper.py"
GATEWAY_TOPOLOGY="$(detect_gateway_topology)"

say ""
say "Hermes First Agent Setup v$VERSION"
say "--------------------------------"
say "Gateway topology detected: $GATEWAY_TOPOLOGY"
read_required "Tenant display name (company/group name)" TENANT_DISPLAY_NAME
read_required "Tenant code (example: skg, acme)" TENANT_CODE_RAW
TENANT_CODE="$(normalize_code "$TENANT_CODE_RAW")"; validate_code "Tenant code" "$TENANT_CODE"
printf 'Does this tenant have multiple businesses/products? [y/N]: '; IFS= read -r MULTI
BUSINESS_CODE=""; BUSINESS_DISPLAY_NAME="$TENANT_DISPLAY_NAME"
case "$MULTI" in
  y|Y|yes|YES)
    read_required "Business/product display name" BUSINESS_DISPLAY_NAME
    read_required "Business code (example: soocker, nextoa)" BUSINESS_CODE_RAW
    BUSINESS_CODE="$(normalize_code "$BUSINESS_CODE_RAW")"; validate_code "Business code" "$BUSINESS_CODE";;
esac
read_optional "Company/business website (optional)" "" COMPANY_WEBSITE
read_optional "Your department / role (optional)" "" USER_ROLE
if [ -n "$BUSINESS_CODE" ]; then AGENT_ID="${TENANT_CODE}-${BUSINESS_CODE}-ai-advisor"; else AGENT_ID="${TENANT_CODE}-ai-advisor"; fi
AGENT_DISPLAY_NAME="${BUSINESS_DISPLAY_NAME} AI Advisor"
PROFILE_HOME="$HERMES_ROOT/profiles/$AGENT_ID"
TOMBSTONE="$HERMES_ROOT/profiles/.deleted/$AGENT_ID"
[ ! -e "$PROFILE_HOME" ] || die "Profile already exists: $AGENT_ID. Use update.sh, or uninstall it first."
if [ -e "$TOMBSTONE" ]; then
  printf 'A Hermes deletion marker exists for %s. Type REINSTALL to clear it and reinstall: ' "$AGENT_ID"
  IFS= read -r REINSTALL_CONFIRM
  [ "$REINSTALL_CONFIRM" = "REINSTALL" ] || die "Reinstall cancelled."
  if hermes profile --help 2>&1 | grep -q 'purge-identity'; then
    hermes profile purge-identity "$AGENT_ID" >/dev/null 2>&1 || true
  fi
  rm -f -- "$TOMBSTONE"
fi

say ""
say "Choose one or more messaging platforms:"
say "  1) LINE"
say "  2) Telegram"
say "  3) WeChat / Weixin"
read_required "Selection (example: 1,2)" PLATFORM_SELECTION
SELECT_LINE=false; SELECT_TELEGRAM=false; SELECT_WEIXIN=false
IFS=',' read -r -a PLATFORM_ITEMS <<< "$PLATFORM_SELECTION"
for item in "${PLATFORM_ITEMS[@]}"; do
  item="$(printf '%s' "$item" | tr -d '[:space:]')"
  case "$item" in
    1) SELECT_LINE=true;;
    2) SELECT_TELEGRAM=true;;
    3) SELECT_WEIXIN=true;;
    *) die "Invalid platform selection: $item";;
  esac
done
if [ "$SELECT_LINE" = false ] && [ "$SELECT_TELEGRAM" = false ] && [ "$SELECT_WEIXIN" = false ]; then die "Select at least one messaging platform"; fi

ACCESS_MODE=""
ACCESS_ALLOW_ALL=false
ACCESS_PASSCODE_SALT=""
ACCESS_PASSCODE_HASH=""
ACCESS_PASSCODE_ITERATIONS=""

say ""
say "Access Control"
say "  1) Company passcode (Recommended)"
say "     Users enter the passcode on first use; successful accounts are remembered for this Agent."
say "  2) Allow all users (Testing only)"
say "     Anyone who can reach the bot can use this Agent."
read_optional "Selection" "1" ACCESS_SELECTION
case "$ACCESS_SELECTION" in
  1)
    ACCESS_MODE="passcode"
    read_secret "Create company access passcode (8-128 characters)" COMPANY_PASSCODE
    [ "${#COMPANY_PASSCODE}" -ge 8 ] && [ "${#COMPANY_PASSCODE}" -le 128 ] || die "Company passcode must be 8-128 characters."
    check_single_line "Company passcode" "$COMPANY_PASSCODE"
    read_secret "Confirm company access passcode" COMPANY_PASSCODE_CONFIRM
    [ "$COMPANY_PASSCODE" = "$COMPANY_PASSCODE_CONFIRM" ] || die "Company passcode confirmation did not match."
    PASSCODE_META="$(printf '%s' "$COMPANY_PASSCODE" | "$HERMES_PYTHON" "$HELPER" hash-passcode)"
    IFS=: read -r ACCESS_PASSCODE_SALT ACCESS_PASSCODE_HASH ACCESS_PASSCODE_ITERATIONS <<< "$PASSCODE_META"
    [ -n "$ACCESS_PASSCODE_SALT" ] && [ -n "$ACCESS_PASSCODE_HASH" ] && [ -n "$ACCESS_PASSCODE_ITERATIONS" ] || die "Could not derive company passcode hash."
    unset COMPANY_PASSCODE COMPANY_PASSCODE_CONFIRM PASSCODE_META
    ;;
  2)
    ACCESS_MODE="allow_all"
    ACCESS_ALLOW_ALL=true
    ;;
  *) die "Invalid access-control selection";;
esac

SHARED_LISTENER_PORT=""
if [ "$SELECT_LINE" = true ] && [ "$GATEWAY_TOPOLOGY" = "multiplex" ]; then
  if SHARED_LISTENER_PORT="$("$HERMES_PYTHON" "$HELPER" shared-listener-port --hermes-root "$HERMES_ROOT" 2>/dev/null)"; then
    say "Multiplex shared HTTP listener detected on port $SHARED_LISTENER_PORT."
  else
    say "No default-profile shared HTTP listener is configured for multiplex LINE ingress."
    say "Using Hermes standalone compatibility mode for this First Agent instead of modifying the default profile."
    GATEWAY_TOPOLOGY="standalone-compat"
  fi
fi

LINE_CHANNEL_ACCESS_TOKEN=""; LINE_CHANNEL_SECRET=""; LINE_PUBLIC_URL=""; LINE_PORT=""
TELEGRAM_BOT_TOKEN=""

if [ "$SELECT_LINE" = true ]; then
  say ""; say "Configure LINE"
  read_secret "LINE Channel Access Token" LINE_CHANNEL_ACCESS_TOKEN
  read_secret "LINE Channel Secret" LINE_CHANNEL_SECRET
  read_optional "Public HTTPS base URL (optional; may be added after install)" "" LINE_PUBLIC_URL
  if [ -n "$LINE_PUBLIC_URL" ]; then
    case "$LINE_PUBLIC_URL" in https://*) ;; *) die "LINE Public URL must start with https://";; esac
  fi
  say "Validating LINE Channel Access Token..."
  if ! printf 'url = "https://api.line.me/v2/bot/info"\nheader = "Authorization: Bearer %s"\nsilent\nshow-error\nfail\nconnect-timeout = 10\nmax-time = 20\n' "$LINE_CHANNEL_ACCESS_TOKEN" \
    | curl --config - >/dev/null; then
    die "LINE Channel Access Token validation failed"
  fi
  case "$GATEWAY_TOPOLOGY" in
    standalone|standalone-compat)
      LINE_PORT="$("$HERMES_PYTHON" "$HELPER" find-free-port --start 8646 --end 8999)"
      say "LINE local port selected: $LINE_PORT"
      ;;
  esac
fi

if [ "$SELECT_TELEGRAM" = true ]; then
  say ""; say "Configure Telegram"
  read_secret "Telegram Bot Token" TELEGRAM_BOT_TOKEN
  say "Validating Telegram Bot Token..."
  TG_RESPONSE="$(
    printf 'url = "https://api.telegram.org/bot%s/getMe"\nsilent\nshow-error\nfail\nconnect-timeout = 10\nmax-time = 20\n' "$TELEGRAM_BOT_TOKEN" \
      | curl --config - || true
  )"
  printf '%s' "$TG_RESPONSE" | grep -q '"ok"[[:space:]]*:[[:space:]]*true' || die "Telegram Bot Token validation failed"
fi

if [ "$SELECT_WEIXIN" = true ]; then
  say ""; say "Configure WeChat / Weixin"
  say "Hermes Weixin uses Tencent iLink bot identity. It is not WeCom."
  printf 'Do you have the WeChat mobile app available now to scan a QR code? [y/N]: '; IFS= read -r WX_READY
  case "$WX_READY" in y|Y|yes|YES) ;; *) die "Weixin setup requires QR login. Prepare the phone before installation.";; esac
fi

say ""
say "Installation Plan"
say "-----------------"
say "Agent ID:          $AGENT_ID"
say "Display Name:      $AGENT_DISPLAY_NAME"
say "Gateway topology:  $GATEWAY_TOPOLOGY"
if [ "$ACCESS_MODE" = "passcode" ]; then
  say "Access control:    Company passcode"
else
  say "Access control:    Allow all users (TESTING ONLY)"
fi
say "Messaging platforms:"
[ "$SELECT_LINE" = true ] && say "  - LINE${LINE_PORT:+ (local port $LINE_PORT)}"
[ "$SELECT_TELEGRAM" = true ] && say "  - Telegram (long polling)"
[ "$SELECT_WEIXIN" = true ] && say "  - WeChat / Weixin (long polling)"
say "LLM: inherit current default profile configuration at install time"
say "Profile path: $PROFILE_HOME"
printf 'Proceed with installation? [y/N]: '; IFS= read -r GO
case "$GO" in y|Y|yes|YES) ;; *) say "Installation cancelled. No profile was created."; exit 0;; esac

INSTALL_SOURCE="$SCRIPT_DIR"
if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REMOTE_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  [ -n "$REMOTE_URL" ] && INSTALL_SOURCE="$REMOTE_URL"
fi

# From here through manifest creation, failures are transactional and rollback
# the brand-new profile. Post-install verification is deliberately non-destructive.
OWNED_PROFILE="$AGENT_ID"
ROLLBACK_ACTIVE=true
say "Creating Hermes profile..."
hermes profile install "$INSTALL_SOURCE" --name "$AGENT_ID" --alias --yes
mkdir -p "$PROFILE_HOME/memories"
umask 077

cat > "$PROFILE_HOME/config.yaml" <<EOF_CONFIG
gateway:
EOF_CONFIG
if [ "$GATEWAY_TOPOLOGY" = "standalone-compat" ]; then
  cat >> "$PROFILE_HOME/config.yaml" <<'EOF_CONFIG'
  standalone: true
EOF_CONFIG
fi
cat >> "$PROFILE_HOME/config.yaml" <<EOF_CONFIG
  platforms:
    line:
      enabled: $SELECT_LINE
    telegram:
      enabled: $SELECT_TELEGRAM
    weixin:
      enabled: $SELECT_WEIXIN
plugins:
  enabled:
    - first-agent-access
memory:
  memory_enabled: true
  user_profile_enabled: true
display:
  interim_assistant_messages: false
  platforms:
    line:
      tool_progress: "off"
EOF_CONFIG
chmod 600 "$PROFILE_HOME/config.yaml"

say "Inheriting LLM configuration from Hermes default profile..."
"$HERMES_PYTHON" "$HELPER" inherit-llm \
  --hermes-root "$HERMES_ROOT" \
  --hermes-install-dir "$HERMES_INSTALL_DIR" \
  --target-profile "$PROFILE_HOME"

ENV_FILE="$PROFILE_HOME/.env"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
upsert_env_line "$ENV_FILE" FIRST_AGENT_ACCESS_MODE "$ACCESS_MODE"
if [ "$ACCESS_MODE" = "passcode" ]; then
  upsert_env_line "$ENV_FILE" FIRST_AGENT_PASSCODE_SALT "$ACCESS_PASSCODE_SALT"
  upsert_env_line "$ENV_FILE" FIRST_AGENT_PASSCODE_HASH "$ACCESS_PASSCODE_HASH"
  upsert_env_line "$ENV_FILE" FIRST_AGENT_PASSCODE_ITERATIONS "$ACCESS_PASSCODE_ITERATIONS"
fi
if [ "$SELECT_LINE" = true ]; then
  upsert_env_line "$ENV_FILE" LINE_CHANNEL_ACCESS_TOKEN "$LINE_CHANNEL_ACCESS_TOKEN"
  upsert_env_line "$ENV_FILE" LINE_CHANNEL_SECRET "$LINE_CHANNEL_SECRET"
  upsert_env_line "$ENV_FILE" LINE_ALLOW_ALL_USERS "$ACCESS_ALLOW_ALL"
  [ -n "$LINE_PUBLIC_URL" ] && upsert_env_line "$ENV_FILE" LINE_PUBLIC_URL "$LINE_PUBLIC_URL"
  [ -n "$LINE_PORT" ] && upsert_env_line "$ENV_FILE" LINE_PORT "$LINE_PORT"
fi
if [ "$SELECT_TELEGRAM" = true ]; then
  upsert_env_line "$ENV_FILE" TELEGRAM_BOT_TOKEN "$TELEGRAM_BOT_TOKEN"
  upsert_env_line "$ENV_FILE" TELEGRAM_ALLOW_ALL_USERS "$ACCESS_ALLOW_ALL"
fi
if [ "$SELECT_WEIXIN" = true ]; then
  upsert_env_line "$ENV_FILE" WEIXIN_ALLOW_ALL_USERS "$ACCESS_ALLOW_ALL"
  if [ "$ACCESS_MODE" = "allow_all" ]; then
    upsert_env_line "$ENV_FILE" WEIXIN_DM_POLICY "open"
  else
    upsert_env_line "$ENV_FILE" WEIXIN_DM_POLICY "pairing"
  fi
fi
chmod 600 "$ENV_FILE"

cat > "$PROFILE_HOME/memories/USER.md" <<EOF_USER
User context from First Agent onboarding:
- Department or role: ${USER_ROLE:-Not provided}
- This advisor is limited to company context, work-related prompt guidance, AI work structuring, Tool/MCP recommendations, and planning advice for future specialist agents.
EOF_USER
cat > "$PROFILE_HOME/memories/MEMORY.md" <<EOF_MEMORY
Organization seed context from First Agent onboarding:
- Tenant display name: $TENANT_DISPLAY_NAME
- Tenant code: $TENANT_CODE
- Business/product display name: ${BUSINESS_DISPLAY_NAME:-Not applicable}
- Business code: ${BUSINESS_CODE:-Not applicable}
- Company/business website: ${COMPANY_WEBSITE:-Not provided}
- Agent ID: $AGENT_ID
- Agent display name: $AGENT_DISPLAY_NAME
- Agent role: Company AI Advisor
- This is seed context only. Verify public company facts from official sources when tools are available; never invent internal facts.
EOF_MEMORY
chmod 600 "$PROFILE_HOME/memories/USER.md" "$PROFILE_HOME/memories/MEMORY.md"

INSTALLED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
MANIFEST_ARGS=(
  write-manifest
  --path "$PROFILE_HOME/FIRST_AGENT.yaml"
  --version "$VERSION"
  --agent-id "$AGENT_ID"
  --display-name "$AGENT_DISPLAY_NAME"
  --tenant-code "$TENANT_CODE"
  --business-code "$BUSINESS_CODE"
  --installed-at "$INSTALLED_AT"
  --topology "$GATEWAY_TOPOLOGY"
)
[ "$SELECT_LINE" = true ] && MANIFEST_ARGS+=(--platform line)
[ "$SELECT_TELEGRAM" = true ] && MANIFEST_ARGS+=(--platform telegram)
[ "$SELECT_WEIXIN" = true ] && MANIFEST_ARGS+=(--platform weixin)
[ -n "$LINE_PORT" ] && MANIFEST_ARGS+=(--line-port "$LINE_PORT")
"$HERMES_PYTHON" "$HELPER" "${MANIFEST_ARGS[@]}"
chmod 600 "$PROFILE_HOME/FIRST_AGENT.yaml"

# Core installation is now durable. Verification/setup failures below do not
# delete the profile or credentials the user just configured.
ROLLBACK_ACTIVE=false

if [ "$SELECT_WEIXIN" = true ]; then
  say ""; say "Starting Hermes native Weixin QR setup for profile $AGENT_ID..."
  say "When Hermes asks for a platform, select Weixin."
  if ! hermes -p "$AGENT_ID" gateway setup; then
    say "WARNING: Weixin QR setup did not complete. The First Agent profile was kept."
    VERIFY_WARNINGS=$((VERIFY_WARNINGS+1))
  fi
  # Re-apply the First Agent access policy in case native setup writes its own DM policy.
  upsert_env_line "$ENV_FILE" WEIXIN_ALLOW_ALL_USERS "$ACCESS_ALLOW_ALL"
  if [ "$ACCESS_MODE" = "allow_all" ]; then
    upsert_env_line "$ENV_FILE" WEIXIN_DM_POLICY "open"
  else
    upsert_env_line "$ENV_FILE" WEIXIN_DM_POLICY "pairing"
  fi
fi

say ""; say "Running post-install health check..."
if ! hermes -p "$AGENT_ID" doctor; then
  say "WARNING: Hermes doctor reported unresolved items. The profile was kept."
  VERIFY_WARNINGS=$((VERIFY_WARNINGS+1))
fi
say "Running First Agent LLM smoke test..."
if ! hermes -p "$AGENT_ID" chat -q "請用一句話說明你的職責範圍。" >/dev/null; then
  say "WARNING: First Agent could not complete the LLM smoke test."
  say "The profile was kept. Check the inherited model/provider configuration, then retry."
  VERIFY_WARNINGS=$((VERIFY_WARNINGS+1))
fi

say ""
say "Ensuring messaging gateway is installed and running..."
ensure_gateway_service "$GATEWAY_TOPOLOGY" || true

say ""
if [ "$VERIFY_WARNINGS" -eq 0 ]; then
  say "Installation complete and verified."
else
  say "Installation complete with $VERIFY_WARNINGS verification warning(s)."
fi
say "Agent ID: $AGENT_ID"
case "$GATEWAY_TOPOLOGY" in
  multiplex)
    say "Gateway mode: shared host multiplexer"
    say "Gateway lifecycle: managed automatically by the installer"
    say "Check host gateway: hermes gateway status"
    if [ "$SELECT_LINE" = true ]; then
      LINE_PATH="/p/$AGENT_ID/line/webhook"
      [ -n "$SHARED_LISTENER_PORT" ] && say "Shared local listener port: $SHARED_LISTENER_PORT"
      say "LINE webhook path: $LINE_PATH"
      [ -n "$LINE_PUBLIC_URL" ] && say "LINE webhook: ${LINE_PUBLIC_URL%/}$LINE_PATH"
    fi
    ;;
  *)
    say "Gateway mode: per-profile standalone"
    say "Gateway lifecycle: persistent service installed/started automatically when supported"
    say "Check gateway: hermes -p $AGENT_ID gateway status"
    if [ "$SELECT_LINE" = true ]; then
      say "LINE local port: $LINE_PORT"
      say "LINE webhook path: /line/webhook"
      [ -n "$LINE_PUBLIC_URL" ] && say "LINE webhook: ${LINE_PUBLIC_URL%/}/line/webhook"
      if [ -z "$LINE_PUBLIC_URL" ]; then
        say "Testing without a domain: cloudflared tunnel --url http://localhost:$LINE_PORT"
      fi
    fi
    ;;
esac
say "One Agent Profile, Many Messaging Platforms, Many Sessions."
