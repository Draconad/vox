#!/bin/bash
# Fill in the prompt_text file for audio.cpp's voice_dir, using audio.cpp's own ASR.
#
# A voice_dir clip clones better when the server can inject a reference_text, and it
# gets that from a `prompt_text` file sitting next to the wavs: one
#   <basename-without-extension>|<transcript>
# line per voice. This transcribes each clip through the server itself and writes it.
#
# Run it on the Unraid box, after the models are declared in server.json:
#
#   bash make-prompt-text.sh
#
# Override anything with environment variables:
#   MODEL=asr-higgs bash make-prompt-text.sh      # a different ASR model
#   FORCE=1 bash make-prompt-text.sh              # redo voices already in the file
#   LANGUAGE=en bash make-prompt-text.sh          # pin the language
#   VOICES=/some/other/dir SERVER=http://tower.local:8586 bash make-prompt-text.sh

set -u

VOICES="${VOICES:-/mnt/user/appdata/Audio-cpp/voices}"
SERVER="${SERVER:-http://localhost:8586}"
MODEL="${MODEL:-asr-qwen3}"
LANGUAGE="${LANGUAGE:-}"
FORCE="${FORCE:-0}"

OUT="$VOICES/prompt_text"

if [ ! -d "$VOICES" ]; then
    echo "No such folder: $VOICES" >&2
    exit 1
fi

# Fail early and clearly rather than writing a file full of empty transcripts.
if ! curl -fsS "$SERVER/v1/models" >/dev/null 2>&1; then
    echo "Can't reach $SERVER — is the container running, and is the port right?" >&2
    exit 1
fi
if ! curl -fsS "$SERVER/v1/models" 2>/dev/null | grep -q "\"$MODEL\""; then
    echo "The server doesn't list a model called \"$MODEL\"." >&2
    echo "It knows about:" >&2
    curl -fsS "$SERVER/v1/models" 2>/dev/null \
        | tr ',' '\n' | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/  \1/p' >&2
    echo >&2
    echo "Pick one with:  MODEL=<id> bash $0" >&2
    exit 1
fi

# Pull .text out of the JSON with whatever this box has. python3 and jq both handle
# escaped quotes and \uXXXX properly; the sed fallback is a last resort.
extract_text() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(" ".join(str(d.get("text", "")).split()))'
    elif command -v jq >/dev/null 2>&1; then
        jq -r '.text // ""' 2>/dev/null | tr '\n' ' '
    else
        sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | head -1
    fi
}

already_done() {
    [ "$FORCE" = "1" ] && return 1
    [ -f "$OUT" ] || return 1
    grep -qF "$1|" "$OUT"
}

cd "$VOICES" || exit 1
touch "$OUT"

shopt -s nullglob nocaseglob
clips=(*.wav)
shopt -u nocaseglob

if [ ${#clips[@]} -eq 0 ]; then
    echo "No .wav files in $VOICES" >&2
    exit 1
fi

echo "Voices : $VOICES"
echo "Server : $SERVER"
echo "Model  : $MODEL"
echo "Clips  : ${#clips[@]}"
echo

done_count=0
skipped=0
failed=0
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for f in "${clips[@]}"; do
    name="${f%.*}"

    if already_done "$name"; then
        echo "  = $name (already in prompt_text)"
        skipped=$((skipped + 1))
        continue
    fi

    # The filename is wrapped in quotes inside the -F value so spaces and commas
    # in names like "Angela White 2.wav" reach curl intact.
    if [ -n "$LANGUAGE" ]; then
        curl -fsS "$SERVER/v1/audio/transcriptions" \
            -F "model=$MODEL" -F "language=$LANGUAGE" -F "file=@\"$f\"" > "$tmp" 2>/dev/null
    else
        curl -fsS "$SERVER/v1/audio/transcriptions" \
            -F "model=$MODEL" -F "file=@\"$f\"" > "$tmp" 2>/dev/null
    fi

    if [ $? -ne 0 ] || [ ! -s "$tmp" ]; then
        echo "  ! $name — the server didn't answer"
        failed=$((failed + 1))
        continue
    fi

    text="$(extract_text < "$tmp")"
    # A pipe in the transcript would split the line; a newline would break the format.
    text="$(printf '%s' "$text" | tr '|\n\r' '   ' | sed 's/^ *//; s/ *$//')"

    if [ -z "$text" ]; then
        echo "  ! $name — came back empty (noisy clip, or the wrong ASR model)"
        failed=$((failed + 1))
        continue
    fi

    # Replacing an existing line rather than appending a duplicate, for FORCE runs.
    if grep -qF "$name|" "$OUT" 2>/dev/null; then
        grep -vF "$name|" "$OUT" > "$OUT.new" && mv "$OUT.new" "$OUT"
    fi
    printf '%s|%s\n' "$name" "$text" >> "$OUT"

    echo "  + $name"
    echo "      $text"
    done_count=$((done_count + 1))
done

echo
echo "Wrote $done_count, skipped $skipped, failed $failed  ->  $OUT"
echo
echo "Read it before trusting it. A wrong transcript clones worse than none at all,"
echo "so fix anything the ASR fumbled — then restart the container to pick it up."
