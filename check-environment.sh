#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
MIN_HERMES_VERSION="0.21.0"
PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0
DOCTOR_TMP=""; CHAT_TMP=""

pass(){ printf 'вњ“ PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
warn(){ printf '! WARN  %s\n' "$1"; WARN_COUNT=$((WARN_COUNT+1)); }
fail(){ printf 'вњ— FAIL  %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
check_command(){ if command -v "$1" >/dev/null 2>&1; then pass "$2"; else fail "$2 вЂ” command not found: $1"; fi; }

cleanup_tmp(){
  if [ -n "$DOCTOR_TMP" ]; then rm -f "$DOCTOR_TMP" 2>/dev/null || true; fi
  if [ -n "$CHAT_TMP" ]; then rm -f "$CHAT_TMP" 2>/dev/null || true; fi
}
trap cleanup_tmp EXIT INT TERM

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

find_hermes_install_dir(){
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

find_hermes_python(){
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

echo "Hermes First Agent вЂ” Environment Check"
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
        0.21.*) pass "Hermes $DETECTED_VERSION is in the v0.5 supported 0.21.x compatibility line";;
        *) warn "Hermes $DETECTED_VERSION is newer than the v0.5 tested 0.21.x compatibility line; verify gateway topology during install";;
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
    HERMES_PYTHON="$(find_hermes_python "$HERMES_INSTALWСT€€ќYJH‚€Y€И[€‰T“QTЧФUУ€€NИ[‚€\ЬИ”]Ы€Ъ]VPSS\И]Z[X›H›Ь€љ\њЭYЩ[ќY™XЮXЫH[\њИ‚€[ЩB€Z[ђШ[››Эљ[™]Ы€Ъ]VPSS›Ь€љ\њЭYЩ[ќY™XЮXЫH[\њИ‚€љB€[ЩB€Z[ђШ[››Э]\›Z[™H\›Y\И[њЭ[\™XЭЬћH‚€љB‚€РХФ—ХTH‰
ZЭ[\‰ХTTЋ‹KЭ\KЪ\›Y\ЛYљ\њЭXYЩ[ќYШЭЬ‹–ЉH‚€ТUХTH‰
ZЭ[\‰ХTTЋ‹KЭ\KЪ\›Y\ЛYљ\њЭXYЩ[ќXЪ]–ЉH‚€Ъ[ЩЊ‰РХФ—ХT€‰ТUХT‚‚€Y€\›Y\И\Y][ШЭЬ€€‰РХФ—ХT€Џ‰ЊNИ[‚€\ЬИ’\›Y\ИШЭЬ€\ЬЩY‚€[ЩB€Ш\›€’\›Y\ИШЭЬ€™\ЬќY[њ™\ЫЫ™Y][\ОИ™]љY]И™Y›Ь™HЭ\ЭЫY\€\Ю[Y[ќ‚€ЩY	ЬЛЧ‹ИЙИ‰РХФ—ХT€Џ‹Щ]‹Ыќ[ќYB€љB‚€Y€\›Y\И\Y][Ъ]\H”™\HЫ›N€ТИ€€‰ТUХT€Џ‰ЊNИ[‚€\ЬИ‘Y][\›Y\И›Щљ[HШ[€™XXЪ]ИЫЫ™љYЭ\™YH‚€[ЩB€Z[‘Y][\›Y\И›Щљ[HЫЭ[›ЭЫЫ\]HHZ[љ[X[H\ЭШ[‚€ЩY	ЬЛЧ‹ИЙИ‰ТUХT€Џ‹Щ]‹Ыќ[ќYB€љB™љB‚љY€ИY‰T“QTЧФ“УХ€NИ[‚€И]И‰T“QTЧФ“УХ€H	‰€\ЬИ’\›Y\ИЫYH\ИЬљ]X›N€	T“QTЧФ“УХ€Z[’\›Y\ИЫYH\И›ЭЬљ]X›N€	T“QTЧФ“УХ‚™[ЩB€И]И‰УQH€H	‰€\ЬИ’\›Y\ИЫYHШ[€™HЬ™X]Y€	T“QTЧФ“УХ€Z[ђШ[››ЭЬ™X]H\›Y\ИЫYH[™\Ћ€	УQH‚™љB‚”‘TURT‘QС’STПH”УХS›YЫЫ™љYЛћX[[\ЭљXќ][Ы‹ћX[[‘T”ТSУ€[њЭ[њЪ\]KњЪ[љ[њЭ[њЪШЬљ\ЛЩљ\њЭXYЩ[ќZ[\‹њHЪЪ[ЛШЫЫ\[ћKXЫЫќ^ФТТS›YЪЪ[ЛЬ›Ы\XYљ\ЫЬ‹ФТТS›YЪЪ[ЛШZK]ЫЬљЛXYљ\ЫЬ‹ФТТS›YЪЪ[ЛШYЩ[ќ\[›љ[™ЛXYљ\ЫЬ‹ФТТS›Y‚“RTФТS‘ПL™›Ь€€[€	‘TURT‘QС’STОИВ€Y€ИHY€‰РФ’TСT‹Й€€NИ[‚€Z[“Z\ЬЪ[™ИXЪШYЩHљ[N€	€‚€RTФТS‘ПI

RTФТS‘КМJJB€љB™Ы™B–И‰RTФТS‘И€Y\HH	‰€\ЬИ‘љ\њЭYЩ[ќXЪШYЩH\ИЫЫ\]H‚‚љY€Ъ]PИ‰РФ’TСT€€™]‹\\њЩHKZ\ЛZ[њЪYK]ЫЬљЛ]™YH‹Щ]‹Ыќ[Џ‰ЊNИ[‚€\ЬИ”™\ЬЪ]ЬћH\ИH[YЪ]ЫЬљЪ[™И™YH‚€‘SSХWХT“H‰
Ъ]PИ‰РФ’TСT€€™[[ЭHЩ]]\›ЬљYЪ[€Џ‹Щ]‹Ыќ[ќYJH‚€Y€И[€‰‘SSХWХT“€NИ[‚€\ЬИ‘Ъ]™[[ЭH\ИЫЫ™љYЭ\™Y‚€Y€ТUХT“RSђSФ“УTLЪ]PИ‰РФ’TСT€€Л\™[[ЭHKY^]XЫЩHЬљYЪ[€PQ‹Щ]‹Ыќ[Џ‰ЊNИ[‚€\ЬИ”љ]]H™\ЬЪ]ЬћHXШЩ\ЬИ™\љYљYY‚€[ЩB€Ш\›€ђШ[››Э™\љYћH™[[ЭH™\ЬЪ]ЬћHXШЩ\ЬИ›Щљ[H[њЭ[Э\]Hњ›ЫHHљ]]H™[[ЭHX^HZ[‚€љB€[ЩB€Ш\›€“›ИЪ]™[[ЭH[YYЬљYЪ[€\ИЫЫ™љYЭ\™YИ[њЭ[\€Ъ[\ЩHHШШ[ЪXЪЫЭ]\И\ЭљXќ][Ы€ЫЭ\ЩH‚€љB™[ЩB€Ш\›€•\ИXЪШYЩH\И›Эќ[›љ[™Ињ›ЫHHЪ]ЫЬљЪ[™И™YH‚™љB‚™XЪИ€‚™XЪИ”Э[[X\ћN€TФПITФЧРУХS•РT“ЏIРT“—РУХS•ђRSIђRSРУХS•‚љY€И‰ђRSРУХS•€YЭNИ[‚€XЪИ‘[ќљ\›Ы›Y[ќ\И“Х™XYK€љ^[ђRS][\И™Y›Ь™H[њЭ[][Ы‹€‚€^]B™љB™XЪИ‘[ќљ\›Ы›Y[ќ\И™XYK€РT“€][\ИЪЭ[™H™]љY]ЩY™Y›Ь™HЭ\ЭЫY\€\Ю[Y[ќ€‚™^]