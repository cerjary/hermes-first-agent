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

echo "Update complete."
echo "Preserved: config.yaml, .env, LLM selection, memories, sessions, and credentials."
echo "Updated: distribution-owned SOUL/Skills and First Agent release metadata."
