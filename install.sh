#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
CREATED_PROFILE=""
say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup_failed_install(){
  local code=$?
  if [ -n "$CREATED_PROFILE" ] && [ -d "$HERMES_ROOT/profiles/$CREATED_PROFILE" ]; then
    printf '\nInstallation failed. Rolling back newly created profile: %s\n' "$CREATED_PROFILE" >&2
    hermes profile delete "$CREATED_PROFILE" --yes >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap cleanup_failed_install ERR INT TERM
read_required(){ local label="$1" var="$2" v=""; while [ -z "$v" ]; do printf '%s: ' "$label"; IFS= read -r v; done; printf -v "$var" '%s' "$v"; }
read_optional(){ local label="$1" def="$2" var="$3" v=""; [ -n "$def" ] && printf '%s [%s]: ' "$label" "$def" || printf '%s: ' "$label"; IFS= read -r v; [ -n "$v" ] || v="$def"; printf -v "$var" '%s' "$v"; }
read_secret(){ local label="$1" var="$2" v=""; while [ -z "$v" ]; do printf '%s: ' "$label"; if [ -t 0 ]; then stty -echo; IFS= read -r v; stty echo; printf '\n'; else IFS= read -r v; fi; done; printf -v "$var" '%s' "$v"; }
normalize_code(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]_]+/-/g; s/[^a-z0-9-]+//g; s/^-+//; s/-+$//; s/-+/-/g'; }
validate_code(){ [[ "$2" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "$1 must use lowercase letters, numbers, and single hyphens only."; }
check_single_line(){ case "$2" in *$'\n'*|*$'\r'*) die "$1 must be a single line";; esac; }
write_env_line(){ check_single_line "$2" "$3"; printf '%s=%s\n' "$2" "$3" >> "$1"; }
ask_allow_all(){ local label="$1" var="$2" a=""; printf 'No %s allowlist supplied. Allow all users temporarily? [y/N]: ' "$label"; IFS= read -r a; case "$a" in y|Y|yes|YES) printf -v "$var" 'true';; *) die "Provide an allowlist or explicitly allow all users.";; esac; }

[ -f "$SCRIPT_DIR/check-environment.sh" ] || die "check-environment.sh not found"
say "Running environment preflight..."
bash "$SCRIPT_DIR/check-environment.sh" || die "Environment preflight failed"

say ""
say "Hermes First Agent Setup v$VERSION"
say "--------------------------------"
read_required "Tenant display name (company/group name)" TENANT_DISPLAY_NAME
read_required "Tenant code (example: skg, acme)" TENANT_CODE_RAW
TENANT_CODE="$(normalize_code "$TENANT_CODE_RAW")"; validate_code "Tenant code" "$TENANT_CODE"
printf 'Does this tenant have multiple businesses/products? [y/N]: '; IFS= read -r MULTI
BUSINESS_CODE=""; BUSINESS_DISPLAY_NAME="$TENANT_DISPLAY_NAME"
case "$MULTI" in y|Y|yes|YES)
  read_required "Business/product display name" BUSINESS_DISPLAY_NAME
  read_required "Business code (example: soocker, nextoa)" BUSINESS_CODE_RAW
  BUSINESS_CODE="$(normalize_code "$BUSINESS_CODE_RAW")"; validate_code "Business code" "$BUSINESS_CODE";; esac
read_optional "Company/business website (optional)" "" COMPANY_WEBSITE
read_optional "Your department / role (optional)" "" USER_ROLE
if [ -n "$BUSINESS_CODE" ]; then AGENT_ID="${TENANT_CODE}-${BUSINESS_CODE}-ai-advisor"; else AGENT_ID="${TENANT_CODE}-ai-advisor"; fi
AGENT_DISPLAY_NAME="${BUSINESS_DISPLAY_NAME} AI Advisor"
PROFILE_HOME="$HERMES_ROOT/profiles/$AGENT_ID"
[ ! -e "$PROFILE_HOME" ] || die "Profile already exists: $AGENT_ID. Use update.sh, or uninstall it first."

say ""
say "Choose one or more messaging gateways:"
say "  1) LINE"
say "  2) Telegram"
say "  3) WeChat / Weixin"
read_required "Selection (example: 1,2)" GATEWAY_SELECTION
SELECT_LINE=false; SELECT_TELEGRAM=false; SELECT_WEIXIN=false
OLDIFS="$IFS"; IFS=','; for item in $GATEWAY_SELECTION; do item="$(printf '%s' "$item" | tr -d '[:space:]')"; case "$item" in 1) SELECT_LINE=true;; 2) SELECT_TELEGRAM=true;; 3) SELECT_WEIXIN=true;; *) die "Invalid gateway selection: $item";; esac; done; IFS="$OLDIFS"
if [ "$SELECT_LINE" = false ] && [ "$SELECT_TELEGRAM" = false ] && [ "$SELECT_WEIXIN" = false ]; then die "Select at least one gateway"; fi

LINE_CHANNEL_ACCESS_TOKEN=""; LINE_CHANNEL_SECRET=""; LINE_ALLOWED_USERS=""; LINE_ALLOW_ALL_USERS=false; LINE_PUBLIC_URL=""
TELEGRAM_BOT_TOKEN=""; TELEGRAM_ALLOWED_USERS=""; TELEGRAM_ALLOW_ALL_USERS=false

if [ "$SELECT_LINE" = true ]; then
  say ""; say "Configure LINE"
  read_secret "LINE Channel Access Token" LINE_CHANNEL_ACCESS_TOKEN
  read_secret "LINE Channel Secret" LINE_CHANNEL_SECRET
  read_optional "Allowed LINE user IDs, comma-separated" "" LINE_ALLOWED_USERS
  [ -n "$LINE_ALLOWED_USERS" ] || ask_allow_all "LINE" LINE_ALLOW_ALL_USERS
  read_required "Public HTTPS base URL (example: https://agent.example.com)" LINE_PUBLIC_URL
  case "$LINE_PUBLIC_URL" in https://*) ;; *) die "LINE Public URL must start with https://";; esac
  say "Validating LINE Channel Access Token..."
  curl -fsS -H "Authorization: Bearer $LINE_CHANNEL_ACCESS_TOKEN" https://api.line.me/v2/bot/info >/dev/null || die "LINE Channel Access Token validation failed"
fi

if [ "$SELECT_TELEGRAM" = true ]; then
  say ""; say "Configure Telegram"
  read_secret "Telegram Bot Token" TELEGRAM_BOT_TOKEN
  read_optional "Allowed Telegram user IDs, comma-separated" "" TELEGRAM_ALLOWED_USERS
  [ -n "$TELEGRAM_ALLOWED_USERS" ] || ask_allow_all "Telegram" TELEGRAM_ALLOW_ALL_USERS
  say "Validating Telegram Bot Token..."
  TG_RESPONSE="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" || true)"
  printf '%s' "$TG_RESPONSE" | grep -q '"ok"[[:space:]]*:[[:space:]]*true' || die "Telegram Bot Token validation failed"
fi

if [ "$SELECT_WEIXIN" = true ]; then
  say ""; say "Configure WeChat / Weixin"
  printf 'Do you have the WeChat mobile app available now to scan a QR code? [y/N]: '; IFS= read -r WX_READY
  case "$WX_READY" in y|Y|yes|YES) ;; *) die "Weixin setup requires QR login. Prepare the phone before installation.";; esac
fi

say ""
say "Installation Plan"
say "-----------------"
say "Agent ID:     $AGENT_ID"
say "Display Name: $AGENT_DISPLAY_NAME"
say "Gateways:"
[ "$SELECT_LINE" = true ] && say "  - LINE"
[ "$SELECT_TELEGRAM" = true ] && say "  - Telegram"
[ "$SELECT_WEIXIN" = true ] && say "  - WeChat / Weixin"
say "Profile path: $PROFILE_HOME"
printf 'Proceed with installation? [y/N]: '; IFS= read -r GO
case "$GO" in y|Y|yes|YES) ;; *) say "Installation cancelled. No profile was created."; exit 0;; esac

say "Creating Hermes profile..."
hermes profile install "$SCRIPT_DIR" --name "$AGENT_ID" --alias --yes
CREATED_PROFILE="$AGENT_ID"
mkdir -p "$PROFILE_HOME/memories"
umask 077
ENV_FILE="$PROFILE_HOME/.env"
: > "$ENV_FILE"
if [ "$SELECT_LINE" = true ]; then
  write_env_line "$ENV_FILE" LINE_CHANNEL_ACCESS_TOKEN "$LINE_CHANNEL_ACCESS_TOKEN"
  write_env_line "$ENV_FILE" LINE_CHANNEL_SECRET "$LINE_CHANNEL_SECRET"
  [ -n "$LINE_ALLOWED_USERS" ] && write_env_line "$ENV_FILE" LINE_ALLOWED_USERS "$LINE_ALLOWED_USERS"
  write_env_line "$ENV_FILE" LINE_ALLOW_ALL_USERS "$LINE_ALLOW_ALL_USERS"
  write_env_line "$ENV_FILE" LINE_PUBLIC_URL "$LINE_PUBLIC_URL"
fi
if [ "$SELECT_TELEGRAM" = true ]; then
  write_env_line "$ENV_FILE" TELEGRAM_BOT_TOKEN "$TELEGRAM_BOT_TOKEN"
  [ -n "$TELEGRAM_ALLOWED_USERS" ] && write_env_line "$ENV_FILE" TELEGRAM_ALLOWED_USERS "$TELEGRAM_ALLOWED_USERS"
  write_env_line "$ENV_FILE" TELEGRAM_ALLOW_ALL_USERS "$TELEGRAM_ALLOW_ALL_USERS"
fi
chmod 600 "$ENV_FILE"

cat > "$PROFILE_HOME/config.yaml" <<EOF_CONFIG
gateway:
  platforms:
    line:
      enabled: $SELECT_LINE
    telegram:
      enabled: $SELECT_TELEGRAM
    weixin:
      enabled: $SELECT_WEIXIN
memory:
  memory_enabled: true
  user_profile_enabled: true
display:
  interim_assistant_messages: false
  platforms:
    line:
      tool_progress: off
EOF_CONFIG

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
cat > "$PROFILE_HOME/FIRST_AGENT.yaml" <<EOF_MANIFEST
source: cerjary/hermes-first-agent
version: $VERSION
agent_id: $AGENT_ID
display_name: "$AGENT_DISPLAY_NAME"
tenant_code: $TENANT_CODE
business_code: ${BUSINESS_CODE:-none}
installed_at: $INSTALLED_AT
gateways:
EOF_MANIFEST
[ "$SELECT_LINE" = true ] && printf '  - line\n' >> "$PROFILE_HOME/FIRST_AGENT.yaml"
[ "$SELECT_TELEGRAM" = true ] && printf '  - telegram\n' >> "$PROFILE_HOME/FIRST_AGENT.yaml"
[ "$SELECT_WEIXIN" = true ] && printf '  - weixin\n' >> "$PROFILE_HOME/FIRST_AGENT.yaml"
chmod 600 "$PROFILE_HOME/FIRST_AGENT.yaml"

if [ "$SELECT_WEIXIN" = true ]; then
  say ""; say "Starting Hermes native Weixin QR setup for profile $AGENT_ID..."
  say "When Hermes asks for a platform, select Weixin."
  hermes -p "$AGENT_ID" gateway setup
fi

say ""; say "Running post-install health check..."
hermes -p "$AGENT_ID" doctor
say "Running Agent smoke test..."
hermes -p "$AGENT_ID" chat -q "請用一句話說明你的職責範圍。" >/dev/null

CREATED_PROFILE=""
trap - ERR INT TERM
say ""
say "Installation complete."
say "Agent ID: $AGENT_ID"
say "Start gateway: hermes -p $AGENT_ID gateway"
say "Install persistent gateway service: hermes -p $AGENT_ID gateway install"
if [ "$SELECT_LINE" = true ]; then say "LINE webhook: ${LINE_PUBLIC_URL%/}/line/webhook"; fi
say "Same Agent, multiple Gateways, separate Sessions."
