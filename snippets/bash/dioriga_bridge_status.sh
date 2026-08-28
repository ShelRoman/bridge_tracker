#!/usr/bin/env bash
# Poll Corinth Canal bridge status from topvision.gr/dioriga
# (header -> img pairs inside div.container-fluid), OCR the status images,
# translate Greek -> Ukrainian and post to Telegram as text.
#
# Loops forever: checks every INTERVAL seconds (arg 1 or $INTERVAL, default
# 300 — the page's own refresh rate) and posts when the status changes.
# The last sent message is persisted to STATE_FILE, so a restart only
# posts if the status changed while the script was down.
#   ALWAYS_POST=1  post every check even if nothing changed
#   DRY_RUN=1      single check, print the message, exit (no Telegram needed)
#   ONE_SHOT=1     single check-and-post, then exit (for CI/cron schedulers;
#                  exit 1 on fetch/send failure)
#
# Self-sufficient: installs tesseract itself if missing (apt-get on
# Debian/Ubuntu incl. GitHub runners, brew on macOS) and downloads Greek/
# English traineddata to ~/.local/share/tessdata when the system lacks them.
set -euo pipefail

BASE_URL="https://www.topvision.gr/dioriga/"
DT_RE='[0-9]{2}/[0-9]{2}/[0-9]{4} [0-9]{2}[:.-][0-9]{2}'
INTERVAL="${1:-${INTERVAL:-300}}"
STATE_FILE="${STATE_FILE:-${HOME}/.cache/dioriga_bridge_status.last}"

# renovate: datasource=github-tags depName=tesseract-ocr/tessdata_fast
TESSDATA_VERSION="4.1.0"

SUDO=""
[ "$(id -u)" != "0" ] && command -v sudo > /dev/null && SUDO="sudo"

fetch_traineddata() {
    mkdir -p "$HOME/.local/share/tessdata"
    curl -fsSL "https://github.com/tesseract-ocr/tessdata_fast/raw/${TESSDATA_VERSION}/$1.traineddata" \
        -o "$HOME/.local/share/tessdata/$1.traineddata"
    export TESSDATA_PREFIX="$HOME/.local/share/tessdata"
}

if ! command -v tesseract > /dev/null || ! command -v curl > /dev/null; then
    if command -v apt-get > /dev/null; then
        $SUDO apt-get update -qq
        # engine floats with the distro (pinned apt versions rot off Ubuntu
        # mirrors); language models are pinned via TESSDATA_VERSION below
        $SUDO apt-get install -y -qq curl ca-certificates tesseract-ocr > /dev/null
    elif command -v brew > /dev/null; then
        brew install tesseract
    else
        echo "tesseract not found and no apt-get/brew to install it" >&2
        exit 1
    fi
fi
for lang in ell eng; do
    tesseract --list-langs 2> /dev/null | grep -qx "$lang" || fetch_traineddata "$lang"
done

translate_header() {
    case "$1" in
        ΠΟΣΕΙΔΩΝΙΑ) echo "Посейдонія" ;;
        ΙΣΘΜΙΑ)     echo "Істмія" ;;
        *)          echo "$1" ;;
    esac
}

# The page only ever shows a few fixed phrases, so match keywords instead of
# calling a translation API; unrecognized text passes through in Greek.
translate_status() {
    local text="$1" from to
    case "$text" in
        *ανοιχτ* | *ανοικτ*)
            echo "Міст відкритий" ;;
        *πληροφορ*)
            echo "Немає інформації про наступне заплановане закриття мосту" ;;
        *κλειστ*)
            from="$(grep -oE "$DT_RE" <<< "$text" | sed -n 1p || true)"
            to="$(grep -oE "$DT_RE" <<< "$text" | sed -n 2p || true)"
            if [ -n "$from" ] && [ -n "$to" ]; then
                echo "Міст буде закритий з $from до $to"
            else
                echo "Міст закритий"
            fi ;;
        *)
            echo "$text" ;;
    esac
}

build_message() {
    local pairs header src status_gr current_header message

    # header<TAB>img_src pairs from the panels inside container-fluid
    pairs="$(curl -fsSL "$BASE_URL" | awk '
        /class="container-fluid"/ { inside = 1 }
        /class="footer"/          { inside = 0 }
        !inside { next }
        {
            if (match($0, /<h4><b>[^<]*<\/b><\/h4>/))
                header = substr($0, RSTART + 7, RLENGTH - 16)
            line = $0
            while (match(line, /<img[^>]*src="[^"]*"/)) {
                tag = substr(line, RSTART, RLENGTH)
                sub(/.*src="/, "", tag)
                sub(/"$/, "", tag)
                print header "\t" tag
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ')" || return 1
    [ -n "$pairs" ] || { echo "No header/img pairs found — page layout changed?" >&2; return 1; }

    message="🌉 Коринфський канал — стан мостів (https://www.topvision.gr/dioriga/)"
    current_header=""
    while IFS=$'\t' read -r header src; do
        status_gr="$(curl -fsSL "${BASE_URL}${src}" \
            | tesseract stdin stdout -l ell+eng --psm 6 2> /dev/null \
            | tr '\n\f' '  ' | sed -E 's/ +/ /g; s/ $//')" || continue
        [ -n "$status_gr" ] || continue
        if [ "$header" != "$current_header" ]; then
            message+=$'\n\n'"$(translate_header "$header"):"
            current_header="$header"
        fi
        message+=$'\n'"• $(translate_status "$status_gr")"
    done <<< "$pairs"
    printf '%s' "$message"
}

if [ -n "${DRY_RUN:-}" ]; then
    build_message
    echo
    exit 0
fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?Set TELEGRAM_BOT_TOKEN}"
CHAT_ID="${TELEGRAM_CHAT_ID:?Set TELEGRAM_CHAT_ID}"

mkdir -p "$(dirname "$STATE_FILE")"
last_message="$(cat "$STATE_FILE" 2> /dev/null || true)"

run_check() {
    local message
    message="$(build_message)" || { echo "$(date '+%F %T') fetch failed" >&2; return 1; }
    if [ -z "${ALWAYS_POST:-}" ] && [ "$message" = "$last_message" ]; then
        echo "$(date '+%F %T') no change"
        return 0
    fi
    if curl -fsS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${message}" > /dev/null; then
        last_message="$message"
        printf '%s' "$message" > "$STATE_FILE"
        echo "$(date '+%F %T') sent"
        return 0
    fi
    echo "$(date '+%F %T') telegram send failed" >&2
    return 1
}

if [ -n "${ONE_SHOT:-}" ]; then
    run_check
    exit
fi

while :; do
    run_check || true
    sleep "$INTERVAL"
done
