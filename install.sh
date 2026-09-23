#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

read_required() {
  local label="$1" var_name="$2" value=""
  while [ -z "$value" ]; do
    printf '%s: ' "$label"
    IFS= read -r value
  done
  printf -v "$var_name" '%s' "$value"
}

read_optional() {
  local label="$1" default="$2" var_name="$3" value=""
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$label" "$default"
  else
    printf '%s: ' "$label"
  fi
  IFS= read -r value
  [ -n "$value" ] || value="$default"
  printf -v "$var_name" '%s' "$value"
}

read_secret() {
  local label="$1" var_name="$2" value=""
  while [ -z "$value" ]; do
    printf '%s: ' "$label"
    if [ -t 0 ]; then
      stty -echo
      IFS= read -r value
      stty echo
      printf '\n'
    else
      IFS= read -r value
    fi
  done
  printf -v "$var_name" '%s' "$value"
}

normalize_code() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[[:space:]_]+/-/g; s/[^a-z0-9-]+//g; s/^-+//; s/-+$//; s/-+/-/g'
}

validate_code() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "$label must use lowercase letters, numbers, and single hyphens only."
}

check_single_line() {
  case "$2" in
    *$'\n'*|*$'\r'*) die "$1 must be a single line" ;;
  esac
}

write_env_line() {
  local file="$1" key="$2" value="$3"
  check_single_line "$key" "$value"
  printf '%s=%s\n' "$key" "$value" >> "$file"
}

require_cmd hermes
require_cmd git

say "Hermes First Agent Setup v0.2.0"
say "--------------------------------"
say "This creates a Company AI Advisor. It can advise on prompts, projects, skills, tools/MCP, and future agents, but it will not create or deploy other agents."
say ""

read_required "Tenant display name (company/group name)" TENANT_DISPLAY_NAME
read_required "Tenant code (example: skg, acme)" TENANT_CODE_RAW
TENANT_CODE="$(normalize_code "$TENANT_CODE_RAW")"
validate_code "Tenant code" "$TENANT_CODE"

printf 'Does this tenant have multiple businesses/products? [y/N]: '
IFS= read -r MULTI_BUSINESS_ANSWER
BUSINESS_CODE=""
BUSINESS_DISPLAY_NAME=""
case "$MULTI_BUSINESS_ANSWER" in
  y|Y|yes|YES)
    read_required "Business/product display name" BUSINESS_DISPLAY_NAME
    read_required "Business code (example: soocker, nextoa, shopline)" BUSINESS_CODE_RAW
    BUSINESS_CODE="$(normalize_code "$BUSINESS_CODE_RAW")"
    validate_code "Business code" "$BUSINESS_CODE"
    ;;
  *)
    BUSINESS_DISPLAY_NAME="$TENANT_DISPLAY_NAME"
    ;;
esac

read_optional "Company/business website (optional)" "" COMPANY_WEBSITE
read_optional "Your department / role (optional)" "" USER_ROLE

if [ -n "$BUSINESS_CODE" ]; then
  AGENT_ID="${TENANT_CODE}-${BUSINESS_CODE}-ai-advisor"
else
  AGENT_ID="${TENANT_CODE}-ai-advisor"
fi
AGENT_DISPLAY_NAME="${BUSINESS_DISPLAY_NAME} AI Advisor"
PROFILE_NAME="$AGENT_ID"
PROFILE_HOME="$HERMES_ROOT/profiles/$PROFILE_NAME"

say ""
say "Agent naming preview"
say "  Agent ID:     $AGENT_ID"
say "  Display name: $AGENT_DISPLAY_NAME"
say ""

if [ -e "$PROFILE_HOME" ]; then
  die "Profile already exists: $PROFILE_NAME ($PROFILE_HOME). Choose another tenant/business code or remove it explicitly first."
fi

say "LINE credentials"
read_secret "LINE Channel Access Token" LINE_CHANNEL_ACCESS_TOKEN
read_secret "LINE Channel Secret" LINE_CHANNEL_SECRET
read_optional "Allowed LINE user IDs, comma-separated (recommended)" "" LINE_ALLOWED_USERS

LINE_ALLOW_ALL_USERS="false"
if [ -z "$LINE_ALLOWED_USERS" ]; then
  printf 'No allowlist supplied. Temporarily allow all LINE users? [y/N]: '
  IFS= read -r answer
  case "$answer" in
    y|Y|yes|YES) LINE_ALLOW_ALL_USERS="true" ;;
    *) die "For safety, provide LINE user IDs or explicitly choose temporary allow-all." ;;
  esac
fi

read_optional "Public HTTPS base URL (optional now)" "" LINE_PUBLIC_URL

say ""
say "Creating Hermes profile: $PROFILE_NAME"
hermes profile install "$SCRIPT_DIR" --name "$PROFILE_NAME" --alias --yes

mkdir -p "$PROFILE_HOME/memories"
umask 077
ENV_FILE="$PROFILE_HOME/.env"
: > "$ENV_FILE"
write_env_line "$ENV_FILE" "LINE_CHANNEL_ACCESS_TOKEN" "$LINE_CHANNEL_ACCESS_TOKEN"
write_env_line "$ENV_FILE" "LINE_CHANNEL_SECRET" "$LINE_CHANNEL_SECRET"
if [ -n "$LINE_ALLOWED_USERS" ]; then
  write_env_line "$ENV_FILE" "LINE_ALLOWED_USERS" "$LINE_ALLOWED_USERS"
fi
write_env_line "$ENV_FILE" "LINE_ALLOW_ALL_USERS" "$LINE_ALLOW_ALL_USERS"
if [ -n "$LINE_PUBLIC_URL" ]; then
  write_env_line "$ENV_FILE" "LINE_PUBLIC_URL" "$LINE_PUBLIC_URL"
fi
chmod 600 "$ENV_FILE"

cat > "$PROFILE_HOME/memories/USER.md" <<EOF_USER
User context from First Agent onboarding:
- Department or role: ${USER_ROLE:-Not provided}
- This user may ask for direct assistance, prompt improvement, workspace/project guidance, tool/MCP recommendations, or planning advice for future specialist agents.
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

say ""
say "Running Hermes health check..."
if hermes -p "$PROFILE_NAME" doctor; then
  HEALTH="passed"
else
  HEALTH="needs attention"
fi

say ""
say "Setup complete"
say "  Agent ID: $AGENT_ID"
say "  Profile:  $PROFILE_NAME"
say "  Home:     $PROFILE_HOME"
say "  Health:   $HEALTH"
say ""
say "Next steps:"
say "  1. Test: hermes -p $PROFILE_NAME chat -q \"請介紹你可以怎麼協助公司使用 AI\""
say "  2. Start LINE gateway: hermes -p $PROFILE_NAME gateway"
say "  3. For persistent service: hermes -p $PROFILE_NAME gateway install"
say "  4. LINE webhook path: /line/webhook (default port 8646)"
if [ -n "$LINE_PUBLIC_URL" ]; then
  say "     Set webhook URL in LINE Developers Console to: ${LINE_PUBLIC_URL%/}/line/webhook"
else
  say "     Expose port 8646 with HTTPS, then set https://YOUR-HOST/line/webhook in LINE Developers Console."
fi
if [ "$LINE_ALLOW_ALL_USERS" = "true" ]; then
  say ""
  say "SECURITY: LINE_ALLOW_ALL_USERS=true is enabled temporarily. Replace it with LINE_ALLOWED_USERS as soon as you know the permitted user IDs."
fi
