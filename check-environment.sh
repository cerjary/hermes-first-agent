#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
MIN_HERMES_VERSION="0.12.0"
PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0
pass(){ printf '✓ PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
warn(){ printf '! WARN  %s\n' "$1"; WARN_COUNT=$((WARN_COUNT+1)); }
fail(){ printf '✗ FAIL  %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
check_command(){ if command -v "$1" >/dev/null 2>&1; then pass "$2"; else fail "$2 — command not found: $1"; fi; }
version_ge(){
  local a b c x y z
  IFS=. read -r a b c <<EOFV
$1
EOFV
  IFS=. read -r x y z <<EOFV
$2
EOFV
  a=${a:-0}; b=${b:-0}; c=${c:-0}; x=${x:-0}; y=${y:-0}; z=${z:-0}
  (( a > x )) || { (( a == x && b > y )) || { (( a == x && b == y && c >= z )); }; }
}

echo "Hermes First Agent — Environment Check"
echo "--------------------------------------"
check_command bash "Bash is available"
check_command git "Git is installed"
check_command curl "curl is installed"
check_command hermes "Hermes Agent is installed"

if command -v hermes >/dev/null 2>&1; then
  RAW_VERSION="$(hermes --version 2>/dev/null | head -n 1 || true)"
  DETECTED_VERSION="$(printf '%s' "$RAW_VERSION" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  if [ -n "$DETECTED_VERSION" ]; then
    if version_ge "$DETECTED_VERSION" "$MIN_HERMES_VERSION"; then
      pass "Hermes version $DETECTED_VERSION satisfies >= $MIN_HERMES_VERSION"
    else
      fail "Hermes $DETECTED_VERSION is too old; require >= $MIN_HERMES_VERSION"
    fi
  else
    warn "Could not determine Hermes semantic version from: ${RAW_VERSION:-unknown}"
  fi

  DOCTOR_TMP="$(mktemp "${TMPDIR:-/tmp}/hermes-first-agent-doctor.XXXXXX")"
  CHAT_TMP="$(mktemp "${TMPDIR:-/tmp}/hermes-first-agent-chat.XXXXXX")"
  chmod 600 "$DOCTOR_TMP" "$CHAT_TMP"
  cleanup_tmp() {
    rm -f "$DOCTOR_TMP" "$CHAT_TMP"
  }
  trap cleanup_tmp EXIT INT TERM

  if hermes doctor >"$DOCTOR_TMP" 2>&1; then
    pass "Hermes doctor passed"
  else
    fail "Hermes doctor reported a problem"
    sed 's/^/        /' "$DOCTOR_TMP" 2>/dev/null || true
  fi

  if hermes chat -q "Reply only: OK" >"$CHAT_TMP" 2>&1; then
    pass "Hermes can reach the configured LLM"
  else
    fail "Hermes could not complete a minimal LLM test call"
    sed 's/^/        /' "$CHAT_TMP" 2>/dev/null || true
  fi

  cleanup_tmp
  trap - EXIT INT TERM
fi

if [ -d "$HERMES_ROOT" ]; then
  [ -w "$HERMES_ROOT" ] && pass "Hermes home is writable: $HERMES_ROOT" || fail "Hermes home is not writable: $HERMES_ROOT"
else
  [ -w "$HOME" ] && pass "Hermes home can be created: $HERMES_ROOT" || fail "Cannot create Hermes home under: $HOME"
fi

REQUIRED_FILES="SOUL.md config.yaml distribution.yaml VERSION install.sh skills/company-context/SKILL.md skills/prompt-advisor/SKILL.md skills/ai-work-advisor/SKILL.md skills/agent-planning-advisor/SKILL.md"
MISSING=0
for f in $REQUIRED_FILES; do
  if [ ! -f "$SCRIPT_DIR/$f" ]; then fail "Missing package file: $f"; MISSING=$((MISSING+1)); fi
done
[ "$MISSING" -eq 0 ] && pass "First Agent package is complete"

if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "Repository is a valid Git working tree"
  REMOTE_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  if [ -n "$REMOTE_URL" ]; then
    pass "Git remote is configured"
    if GIT_TERMINAL_PROMPT=0 git -C "$SCRIPT_DIR" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
      pass "Private repository access verified"
    else
      warn "Cannot verify remote repository access; future updates may fail"
    fi
  else
    warn "No Git remote named origin is configured"
  fi
else
  warn "This package is not running from a Git working tree"
fi

echo ""
echo "Summary: PASS=$PASS_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "Environment is NOT ready. Fix all FAIL items before installation."
  exit 1
fi
echo "Environment is ready."
exit 0
