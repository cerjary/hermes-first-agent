#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
MIN_HERMES_VERSION="0.21.0"
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
DOCTOR_TMP=""
CHAT_TMP=""

pass() {
  printf '✓ PASS  %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

warn() {
  printf '! WARN  %s\n' "$1"
  WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
  printf '✗ FAIL  %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

check_command() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "$2"
  else
    fail "$2 — command not found: $1"
  fi
}

# cleanup_tmp is invoked only through trap handlers; ShellCheck cannot infer that call path.
# shellcheck disable=SC2317
cleanup_tmp() {
  if [ -n "$DOCTOR_TMP" ]; then
    rm -f -- "$DOCTOR_TMP" 2>/dev/null || true
  fi
  if [ -n "$CHAT_TMP" ]; then
    rm -f -- "$CHAT_TMP" 2>/dev/null || true
  fi
}
trap cleanup_tmp EXIT INT TERM

version_ge() {
  local a b c x y z
  IFS=. read -r a b c <<EOFV
$1
EOFV
  IFS=. read -r x y z <<EOFV
$2
EOFV
  a=${a:-0}; b=${b:-0}; c=${c:-0}
  x=${x:-0}; y=${y:-0}; z=${z:-0}
  (( a > x )) || {
    (( a == x && b > y )) || {
      (( a == x && b == y && c >= z ))
    }
  }
}

find_hermes_install_dir() {
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

find_hermes_python() {
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

origin_matches_expected_repo() {
  local remote="$1"
  case "$remote" in
    git@github.com:cerjary/hermes-first-agent.git|\
    git@github.com:cerjary/hermes-first-agent|\
    https://github.com/cerjary/hermes-first-agent.git|\
    https://github.com/cerjary/hermes-first-agent)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

echo "Hermes First Agent — Environment Check"
echo "--------------------------------------"

check_command bash "Bash is available"
check_command git "Git is installed"
check_command curl "curl is installed"
check_command mktemp "mktemp is available"
check_command hermes "Hermes Agent is installed"

if command -v hermes >/dev/null 2>&1; then
  RAW_VERSION="$(hermes --version 2>/dev/null | head -n 1 || true)"
  DETECTED_VERSION="$(printf '%s' "$RAW_VERSION" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"

  if [ -n "$DETECTED_VERSION" ]; then
    if version_ge "$DETECTED_VERSION" "$MIN_HERMES_VERSION"; then
      pass "Hermes version $DETECTED_VERSION satisfies >= $MIN_HERMES_VERSION"
      case "$DETECTED_VERSION" in
        0.21.*)
          pass "Hermes $DETECTED_VERSION is in the v0.5 tested 0.21.x compatibility line"
          ;;
        *)
          warn "Hermes $DETECTED_VERSION is newer than the v0.5 tested 0.21.x compatibility line; installer must rely on runtime gateway topology detection"
          ;;
      esac
    else
      fail "Hermes $DETECTED_VERSION is too old; require >= $MIN_HERMES_VERSION"
    fi
  else
    fail "Could not determine Hermes semantic version from: ${RAW_VERSION:-unknown}"
  fi

  HERMES_INSTALL_DIR="$(find_hermes_install_dir || true)"
  if [ -n "$HERMES_INSTALL_DIR" ]; then
    pass "Hermes install directory detected: $HERMES_INSTALL_DIR"
    HERMES_PYTHON="$(find_hermes_python "$HERMES_INSTALL_DIR" || true)"
    if [ -n "$HERMES_PYTHON" ]; then
      pass "Python with PyYAML is available: $HERMES_PYTHON"
    else
      fail "Cannot find Hermes Python or python3 with PyYAML"
    fi
  else
    fail "Could not determine Hermes install directory"
  fi

  if command -v mktemp >/dev/null 2>&1; then
    DOCTOR_TMP="$(mktemp "${TMPDIR:-/tmp}/hermes-first-agent-doctor.XXXXXX")"
    CHAT_TMP="$(mktemp "${TMPDIR:-/tmp}/hermes-first-agent-chat.XXXXXX")"
    chmod 600 "$DOCTOR_TMP" "$CHAT_TMP"

    if hermes -p default doctor >"$DOCTOR_TMP" 2>&1; then
      pass "Default profile Hermes doctor passed"
    else
      warn "Default profile Hermes doctor reported unresolved items"
      sed 's/^/        /' "$DOCTOR_TMP" 2>/dev/null || true
    fi

    if hermes -p default chat -q "Reply only: OK" >"$CHAT_TMP" 2>&1; then
      pass "Default profile can reach its configured LLM"
    else
      fail "Default profile could not complete the LLM prerequisite test"
      sed 's/^/        /' "$CHAT_TMP" 2>/dev/null || true
    fi
  else
    fail "Cannot create secure temporary files because mktemp is unavailable"
  fi
fi

if [ -d "$HERMES_ROOT" ]; then
  if [ -w "$HERMES_ROOT" ]; then
    pass "Hermes home is writable: $HERMES_ROOT"
  else
    fail "Hermes home is not writable: $HERMES_ROOT"
  fi
else
  HERMES_PARENT="$(dirname "$HERMES_ROOT")"
  if [ -d "$HERMES_PARENT" ] && [ -w "$HERMES_PARENT" ]; then
    pass "Hermes home can be created: $HERMES_ROOT"
  else
    fail "Cannot create Hermes home: $HERMES_ROOT"
  fi
fi

REQUIRED_FILES=(
  "SOUL.md"
  "config.yaml"
  "distribution.yaml"
  "VERSION"
  "check-environment.sh"
  "install.sh"
  "update.sh"
  "uninstall.sh"
  "scripts/first-agent-helper.py"
  "plugins/first-agent-access/plugin.yaml"
  "plugins/first-agent-access/__init__.py"
  "skills/company-context/SKILL.md"
  "skills/prompt-advisor/SKILL.md"
  "skills/ai-work-advisor/SKILL.md"
  "skills/agent-planning-advisor/SKILL.md"
)
MISSING=0
for file in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "$SCRIPT_DIR/$file" ]; then
    fail "Missing package file: $file"
    MISSING=$((MISSING + 1))
  fi
done
if [ "$MISSING" -eq 0 ]; then
  pass "First Agent package is complete"
fi

if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "Repository is a valid Git working tree"

  REMOTE_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  if [ -n "$REMOTE_URL" ]; then
    if origin_matches_expected_repo "$REMOTE_URL"; then
      pass "Git origin points to cerjary/hermes-first-agent"
    else
      fail "Git origin does not point to cerjary/hermes-first-agent: $REMOTE_URL"
    fi

    if GIT_TERMINAL_PROMPT=0 git -C "$SCRIPT_DIR" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
      pass "Repository remote access verified"
    else
      warn "Cannot verify repository remote access; future updates may fail"
    fi
  else
    warn "No Git remote named origin is configured; update.sh will not be able to pull releases"
  fi

  if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null || true)" ]; then
    warn "Git working tree has local changes; review them before install/update"
  else
    pass "Git working tree is clean"
  fi
else
  warn "This package is not running from a Git working tree; repository remote access and future git-based updates cannot be verified"
fi

echo ""
echo "Summary: PASS=$PASS_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "Environment is NOT ready. Fix all FAIL items before installation."
  exit 1
fi

echo "Environment is ready."
exit 0
