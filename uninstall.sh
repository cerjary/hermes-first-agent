#!/usr/bin/env bash
set -euo pipefail
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
read -r -p "Agent ID to uninstall: " AGENT_ID
[ -n "$AGENT_ID" ] || die "Agent ID is required"
PROFILE_HOME="$HERMES_ROOT/profiles/$AGENT_ID"
MANIFEST="$PROFILE_HOME/FIRST_AGENT.yaml"
[ -f "$MANIFEST" ] || die "FIRST_AGENT.yaml not found; refusing to delete a non-First-Agent profile"
grep -q '^source: cerjary/hermes-first-agent$' "$MANIFEST" || die "Profile source does not match hermes-first-agent"
echo ""
echo "This will permanently remove:"
echo "  - Profile: $AGENT_ID"
echo "  - SOUL / Skills / config"
echo "  - memories and sessions"
echo "  - gateway credentials and profile data"
echo "  - gateway service and shell alias managed by Hermes"
echo ""
echo "Hermes itself and other profiles will NOT be removed."
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
    echo "Note: profile export can contain memories/session data and does not include all credentials/secrets."
    ;;
  3) echo "Cancelled."; exit 0;;
  *) die "Invalid selection";;
esac
read -r -p "Type the Agent ID '$AGENT_ID' to confirm permanent deletion: " CONFIRM
[ "$CONFIRM" = "$AGENT_ID" ] || die "Confirmation did not match"
hermes profile delete "$AGENT_ID" --yes
echo "First Agent $AGENT_ID has been removed."
