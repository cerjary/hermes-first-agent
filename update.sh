#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
read -r -p "Agent ID to update: " AGENT_ID
[ -n "$AGENT_ID" ] || die "Agent ID is required"
PROFILE_HOME="$HERMES_ROOT/profiles/$AGENT_ID"
MANIFEST="$PROFILE_HOME/FIRST_AGENT.yaml"
[ -f "$MANIFEST" ] || die "FIRST_AGENT.yaml not found; refusing to update a non-First-Agent profile"
grep -q '^source: cerjary/hermes-first-agent$' "$MANIFEST" || die "Profile source does not match hermes-first-agent"
bash "$SCRIPT_DIR/check-environment.sh"
if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Updating local repository..."
  git -C "$SCRIPT_DIR" pull --ff-only
fi
TARGET_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
echo "Updating $AGENT_ID to First Agent v$TARGET_VERSION..."
hermes profile update "$AGENT_ID" --yes
TMP="$MANIFEST.tmp"
awk -v v="$TARGET_VERSION" '{ if ($1=="version:") print "version: " v; else print }' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"
chmod 600 "$MANIFEST"
echo "Update complete. User state, .env, memories, sessions, and credentials were preserved."
