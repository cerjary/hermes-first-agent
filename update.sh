#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
HELPER="$SCRIPT_DIR/scripts/first-agent-helper.py"

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
validate_agent_id(){ [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "Agent ID must use lowercase letters, numbers, and single hyphens only."; }

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

# Distribution updates intentionally preserve user-owned config/.env/memory.
# LLM inheritance is install-time only; an update does not silently follow
# later changes made to the default profile.
"$HERMES_PYTHON" "$HELPER" set-manifest-version --path "$MANIFEST" --version "$TARGET_VERSION"
chmod 600 "$MANIFEST"

GATEWAY_TOPOLOGY="$(manifest_gateway_topology)"
GATEWAY_WARNING=0
reconcile_gateway_service "$GATEWAY_TOPOLOGY" || GATEWAY_WARNING=1

if [ "$GATEWAY_WARNING" -eq 0 ]; then
  echo "Update complete. Gateway is running or already managed."
else
  echo "Update complete with a gateway warning; the Agent profile was kept."
fi
echo "Preserved: config.yaml, .env, LLM selection, memories, sessions, and credentials."
echo "Updated: distribution-owned SOUL/Skills and First Agent release metadata."
