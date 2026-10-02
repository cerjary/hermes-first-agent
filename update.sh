#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
HELPER="$SCRIPT_DIR/scripts/first-agent-helper.py"

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
validate_agent_id(){ [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "Agent ID must use lowercase letters, numbers, and single hyphens only."; }

upsert_env_line(){
  local file="$1" key="$2" value="$3" tmp
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


wait_for_profile_gateway_process(){
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    : "$attempt"
    has_profile_gateway_process "$AGENT_ID" && return 0
    sleep 1
  done
  return 1
}

restart_updated_gateway(){
  local topology="$1"
  if [ "$topology" = "multiplex" ]; then
    echo "WARNING: This First Agent uses a shared multiplex gateway."
    echo "The profile was updated, but the shared gateway was not restarted automatically."
    echo "Restart it in a maintenance window with: hermes gateway restart"
    return 1
  fi

  if has_profile_gateway_process "$AGENT_ID"; then
    echo "Restarting gateway for $AGENT_ID so updated plugins and env are loaded..."
    if ! hermes -p "$AGENT_ID" gateway restart; then
      echo "WARNING: Gateway restart failed."
      return 1
    fi
    if ! wait_for_profile_gateway_process; then
      echo "WARNING: Gateway restart returned, but no running profile gateway was detected."
      return 1
    fi
    echo "Gateway restarted."
    return 0
  fi

  reconcile_gateway_service "$topology"
}

manifest_gateway_topology(){
  "$HERMES_PYTHON" - "$MANIFEST" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}
value = data.get("gateway_topology") or "standalone"
if value not in {"standalone", "standalone-compat", "multiplex"}:
    raise SystemExit(f"Unsupported gateway_topology in manifest: {value}")
print(value)
PY
}

reconcile_gateway_service(){
  local topology="$1"
  local -a cmd

  if [ "$topology" = "multiplex" ]; then
    if has_default_gateway_process; then
      echo "Host multiplex gateway is already running; leaving it in place."
      return 0
    fi
    cmd=(hermes gateway install --start-now --start-on-login)
  else
    if has_profile_gateway_process "$AGENT_ID"; then
      echo "Gateway for $AGENT_ID is already running; leaving the existing process in place."
      return 0
    fi
    cmd=(hermes -p "$AGENT_ID" gateway install --start-now --start-on-login)
    if [ "$topology" = "standalone-compat" ]; then
      cmd+=(--force)
    fi
  fi

  echo "Installing/starting gateway service for topology: $topology"
  if ! "${cmd[@]}"; then
    echo "WARNING: Gateway service could not be installed/started automatically."
    return 1
  fi
  return 0
}

read -r -p "Agent ID to update: " AGENT_ID
[ -n "$AGENT_ID" ] || die "Agent ID is required"
validate_agent_id "$AGENT_ID"
PROFILE_HOME="$HERMES_ROOT/profiles/$AGENT_ID"
MANIFEST="$PROFILE_HOME/FIRST_AGENT.yaml"
[ -f "$MANIFEST" ] || die "FIRST_AGENT.yaml not found; refusing to update a non-First-Agent profile"
[ -f "$HELPER" ] || die "First Agent lifecycle helper not found: $HELPER"

HERMES_INSTALL_DIR="$(find_hermes_install_dir)" || die "Cannot determine Hermes install directory"
HERMES_PYTHON="$(find_hermes_python "$HERMES_INSTALL_DIR")" || die "Cannot find Python with PyYAML"
"$HERMES_PYTHON" "$HELPER" verify-manifest --path "$MANIFEST" --agent-id "$AGENT_ID" >/dev/null

if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Updating local First Agent repository..."
  git -C "$SCRIPT_DIR" pull --ff-only
fi

# Run the preflight from the newly pulled release, so new requirements are
# checked before the installed profile is changed.
bash "$SCRIPT_DIR/check-environment.sh"
TARGET_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
echo "Updating $AGENT_ID to First Agent v$TARGET_VERSION..."
hermes profile update "$AGENT_ID" --yes

# v0.5.6 migration: Hermes LINE performs its transport allowlist check before
# pre_gateway_dispatch. Company-passcode LINE profiles therefore need adapter
# ingress enabled so unknown DMs can reach the First Agent access hook.
ENV_FILE="$PROFILE_HOME/.env"
if [ -f "$ENV_FILE" ] \
  && grep -qx 'FIRST_AGENT_ACCESS_MODE=passcode' "$ENV_FILE" \
  && grep -q '^LINE_CHANNEL_ACCESS_TOKEN=.' "$ENV_FILE"; then
  upsert_env_line "$ENV_FILE" LINE_ALLOW_ALL_USERS true
  echo "Migrated LINE passcode ingress for the existing profile."
fi

LINE_INDICATOR_MIGRATION="$(ensure_line_processing_indicator || true)"
if [ "$LINE_INDICATOR_MIGRATION" = "changed" ]; then
  chmod 600 "$PROFILE_HOME/config.yaml"
  echo "Migrated LINE processing indicator settings for the existing profile."
fi

# Distribution updates intentionally preserve user-owned config/.env/memory.
# LLM inheritance is install-time only; an update does not silently follow
# later changes made to the default profile.
"$HERMES_PYTHON" "$HELPER" set-manifest-version --path "$MANIFEST" --version "$TARGET_VERSION"
chmod 600 "$MANIFEST"

GATEWAY_TOPOLOGY="$(manifest_gateway_topology)"
GATEWAY_WARNING=0
restart_updated_gateway "$GATEWAY_TOPOLOGY" || GATEWAY_WARNING=1

if [ "$GATEWAY_WARNING" -eq 0 ]; then
  echo "Update complete. Gateway is running or already managed."
else
  echo "Update complete with a gateway warning; the Agent profile was kept."
fi
echo "Preserved: config.yaml, .env, LLM selection, memories, sessions, and credentials."
echo "Updated: distribution-owned SOUL/Skills/plugins, First Agent release metadata, and required access migrations."
