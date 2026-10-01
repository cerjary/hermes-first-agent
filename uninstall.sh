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

[ -f "$HELPER" ] || die "First Agent lifecycle helper not found: $HELPER"

HERMES_INSTALL_DIR="$(find_hermes_install_dir)" || die "Cannot determine Hermes install directory"
HERMES_PYTHON="$(find_hermes_python "$HERMES_INSTALL_DIR")" || die "Cannot find Python with PyYAML"

mapfile -t FIRST_AGENT_ROWS < <("$HERMES_PYTHON" "$HELPER" list-first-agents --hermes-root "$HERMES_ROOT")
[ "${#FIRST_AGENT_ROWS[@]}" -gt 0 ] || die "No installed Hermes First Agents were found."

echo ""
echo "Installed Hermes First Agents:"
echo ""
for idx in "${!FIRST_AGENT_ROWS[@]}"; do
  IFS=$'\t' read -r row_agent_id row_display_name row_version <<< "${FIRST_AGENT_ROWS[$idx]}"
  printf '  %d) %s  [%s]  v%s\n' "$((idx + 1))" "$row_display_name" "$row_agent_id" "$row_version"
done
echo ""

while true; do
  read -r -p "Select Agent to uninstall [1-${#FIRST_AGENT_ROWS[@]}]: " SELECTION
  if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "${#FIRST_AGENT_ROWS[@]}" ]; then
    break
  fi
  echo "Invalid selection."
done

IFS=$'\t' read -r AGENT_ID DISPLAY_NAME INSTALLED_VERSION <<< "${FIRST_AGENT_ROWS[$((SELECTION - 1))]}"
validate_agent_id "$AGENT_ID"
PROFILE_HOME="$HERMES_ROOT/profiles/$AGENT_ID"
MANIFEST="$PROFILE_HOME/FIRST_AGENT.yaml"
[ -f "$MANIFEST" ] || die "FIRST_AGENT.yaml disappeared; refusing to continue"
"$HERMES_PYTHON" "$HELPER" verify-manifest --path "$MANIFEST" --agent-id "$AGENT_ID" >/dev/null

echo ""
echo "Selected First Agent:"
echo "  Display Name: $DISPLAY_NAME"
echo "  Agent ID:     $AGENT_ID"
echo "  Version:      $INSTALLED_VERSION"
echo ""
echo "This will permanently remove:"
echo "  - First Agent profile: $AGENT_ID"
echo "  - SOUL / Skills / config"
echo "  - memories and sessions"
echo "  - profile messaging credentials and data"
echo "  - gateway service/routing managed by Hermes for this profile"
echo ""
echo "Hermes itself, the default profile, and other profiles will NOT be removed."
echo ""
echo "Backup options:"
echo "  1) Delete without profile export"
echo "  2) Export profile first, then delete"
echo "  3) Cancel"
read -r -p "Selection [1/2/3]: " CHOICE
case "$CHOICE" in
  1) ;;
  2)
    umask 077
    BACKUP_DIR="$HERMES_ROOT/backups/first-agent"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    TS="$(date -u +'%Y%m%dT%H%M%SZ')"
    BACKUP="$BACKUP_DIR/${AGENT_ID}-${TS}.tar.gz"
    hermes profile export "$AGENT_ID" -o "$BACKUP"
    chmod 600 "$BACKUP"
    echo "Profile export created: $BACKUP"
    echo "The export excludes .env and auth.json, but can contain memories, sessions, and other sensitive profile data."
    ;;
  3) echo "Cancelled."; exit 0;;
  *) die "Invalid selection";;
esac

read -r -p "Permanently delete '$DISPLAY_NAME' [$AGENT_ID]? [y/N]: " CONFIRM
case "${CONFIRM,,}" in
  y|yes) ;;
  *) echo "Cancelled."; exit 0;;
esac

hermes profile delete "$AGENT_ID" --yes

# Keep a deterministic First Agent reinstall marker even when Hermes versions
# differ in whether profile delete leaves their internal tombstone behind.
DELETED_DIR="$HERMES_ROOT/profiles/.deleted"
mkdir -p "$DELETED_DIR"
chmod 700 "$DELETED_DIR"
: > "$DELETED_DIR/$AGENT_ID"
chmod 600 "$DELETED_DIR/$AGENT_ID"

echo "First Agent $AGENT_ID has been removed."
if [ -e "$HERMES_ROOT/profiles/.deleted/$AGENT_ID" ]; then
  echo "Hermes kept an internal deletion marker for this profile."
  echo "The installer detects this marker and requires explicit REINSTALL confirmation before reusing the same Agent ID."
fi
