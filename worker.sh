#!/bin/bash
# macOS counterpart of compress.ps1 + ask-upload.ps1.
# obs-autocompress.lua drops the recording path into queue/ and starts this worker. For each recording:
# extract the audio (./extract-audio, stream copy, seconds), then ask whether to send it to Whisperwise.
# A queue item is removed only once answered, so unanswered questions survive a reboot.
# By hand: ./worker.sh ~/Movies/rec.mkv ...   (no args = drain the queue; retry a failure: mv failed/*.txt queue/)
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # OBS started from Finder has a bare PATH

BASE_URL=https://ww.nextgensoft.co
ROOT="$(cd "$(dirname "$0")" && pwd)"
QUEUE="$ROOT/queue"; FAILED="$ROOT/failed"; LOG="$ROOT/worker.log"; LOCK="$ROOT/.lock"
mkdir -p "$QUEUE" "$FAILED"

log() { echo "$(date '+%F %T')  $*" >> "$LOG"; }
notify() { osascript -e 'on run a' -e 'display notification (item 2 of a) with title (item 1 of a)' -e 'end run' "$1" "$2"; }

# Ask about one file. Prints "send<TAB>title", "no", or "again" (left unanswered for a minute: re-ask, beep).
# No Cancel button, so Esc does nothing: only an explicit answer closes it.
ask() {
    osascript - "$1" "$2" <<'EOF'
on run a
    activate
    beep
    set r to display dialog (item 1 of a) default answer (item 2 of a) with title "Whisperwise" ¬
        buttons {"Нет, оставить себе", "Отправить"} default button "Отправить" giving up after 60
    if gave up of r then return "again"
    if button returned of r is "Отправить" then return "send" & tab & (text returned of r)
    return "no"
end run
EOF
}

# Prints the chosen item or "" on Cancel. Args: prompt, items...
choose() {
    osascript - "$@" <<'EOF'
on run a
    activate
    set r to choose from list (items 2 thru -1 of a) with title "Whisperwise" with prompt (item 1 of a)
    if r is false then return ""
    return item 1 of r
end run
EOF
}

# "name<TAB>id" lines sorted by name; team prefix only when there are several teams.
# Response shape: { teams: [ { name, projects: [ { id, name, state } ] } ] }
projects() {
    curl -sf -m 30 -H "Authorization: Bearer $1" "$BASE_URL/api/projects" | jq -r '
        (.teams | length > 1) as $multi
        | [.teams[] | .name as $t | .projects[]
           | [(if $multi then "\($t) / " else "" end) + (.name | gsub("^\\s+|\\s+$"; "")), (.id | tostring)]]
        | sort[] | @tsv'
}

ask_upload() {
    local file=$1 title=$2 err="" token="" list="" ans pid name resp url names
    local mb=$(( $(stat -f %z "$file") / 1048576 ))
    while true; do
        if [[ -z $list ]]; then   # (re)fetch until it works; a broken token/network must not fail silently
            err=""
            token=$(security find-generic-password -s whisperwise -w 2>/dev/null) \
                || err="Нет токена в Keychain (см. README, раздел macOS)."
            [[ -z $err ]] && { list=$(projects "$token") && [[ -n $list ]] \
                || err="Не удалось получить проекты Whisperwise (токен? сеть?)."; }
        fi
        ans=$(ask "${err:+$err$'\n\n'}Запись: $(basename "$file") ($mb МБ). Отправить в Whisperwise? Проект — на следующем шаге."$'\n\n'"Название:" "$title")
        case $ans in
            again) continue ;;
            no) log "не отправлять (выбор): $file"; return ;;
        esac
        title=${ans#send$'\t'}
        [[ -n $list ]] || continue

        if [[ $(wc -l <<<"$list") -eq 1 ]]; then
            pid=$(cut -f2 <<<"$list")
        else
            names=(); while IFS=$'\t' read -r name _; do names+=("$name"); done <<<"$list"
            name=$(choose "Проект для «${title}»:" "${names[@]}")
            [[ -n $name ]] || continue   # Cancel: back to the first question
            pid=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' <<<"$list")
        fi

        resp=$(curl -sS -m 3600 -H "Authorization: Bearer $token" -F "audio=@\"$file\";type=audio/mp4" \
            --form-string "external_project_id=$pid" --form-string "title=$title" "$BASE_URL/upload" 2>&1)
        log "ответ сервера: ${resp:0:300}"
        url=$(jq -r '.shareUrl // empty' <<<"$resp" 2>/dev/null)
        if [[ -n $url ]]; then
            log "отправлено: $file -> $url"
            notify Whisperwise "Отправлено: $url"
            return
        fi
        err="Ошибка отправки: $(jq -r '"\(.error) \(.message // "")"' <<<"$resp" 2>/dev/null || echo "${resp:0:200}")"
        log "ОШИБКА отправки $file: $err"
    done
}

# OBS may still be flushing the file right after the stop event: wait until its size stops changing.
wait_stable() {
    local last=-1 size i
    for ((i = 0; i < 720; i++)); do
        size=$(stat -f %z "$1" 2>/dev/null || echo -1)
        [[ $size -gt 0 && $size == "$last" ]] && return 0
        last=$size; sleep 5
    done
    return 1
}

process() {
    local src=$1 m4a="${1%.*}.m4a" out
    if [[ ! -f $m4a ]]; then
        [[ -f $src ]] || { log "FAIL  $src : файла нет"; return 1; }
        wait_stable "$src" || { log "FAIL  $src : файл не перестал расти за 60 мин"; return 1; }
        log "extract $src"
        out=$("$ROOT/extract-audio" "$src" 2>&1) || { log "FAIL  $src : $out"; return 1; }
    fi
    ask_upload "$m4a" "$(basename "${src%.*}")"
}

# Manual run: queue the given files.
for f in "$@"; do
    [[ -f $f ]] || { echo "нет файла: $f" >&2; continue; }
    printf '%s' "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" > "$QUEUE/$(date +%Y%m%d-%H%M%S)-$RANDOM.txt"
done

# One worker at a time; a second one waits, then drains whatever is left. A dead holder's lock is reclaimed.
until mkdir "$LOCK" 2>/dev/null; do
    holder=$(cat "$LOCK/pid" 2>/dev/null)
    if [[ -n $holder ]] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
    sleep 5
done
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

while q=$(ls "$QUEUE"/*.txt 2>/dev/null | head -1); [[ -n $q ]]; do
    src=$(<"$q")
    if process "$src"; then
        rm -f "$q"
    else
        mv "$q" "$FAILED/"
        notify 'Извлечение аудио не удалось' "$(basename "$src"), см. worker.log"
    fi
done
