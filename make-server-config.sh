#!/bin/bash
# Rebuild audio.cpp's server.json from whatever is in the models folder.
#
# The WebUI downloads models but declares nothing to the API, so /v1/models stays
# empty and Vox sees no models. This scans the folder, works out each package's
# family and task, and writes a config declaring the lot.
#
# Run it on the Unraid box after downloading anything new, then restart the container:
#
#   bash make-server-config.sh
#   docker restart Audio.cpp
#
# Overrides:
#   MODELS=/path/to/models  CONTAINER=Audio.cpp  BACKEND=cuda  MAX_LOADED=2  bash make-server-config.sh
#   DRY=1 bash make-server-config.sh     # show what it would write, change nothing

set -u

MODELS="${MODELS:-/mnt/user/appdata/Audio-cpp/models}"
CONTAINER="${CONTAINER:-Audio.cpp}"
BACKEND="${BACKEND:-cuda}"
DEVICE="${DEVICE:-0}"
# 2 keeps an ASR and a TTS model resident together. The Talk screen alternates
# between them every turn, and at 1 each turn would evict and reload both.
MAX_LOADED="${MAX_LOADED:-2}"
IDLE_UNLOAD_MS="${IDLE_UNLOAD_MS:-900000}"
CONTAINER_MODELS="${CONTAINER_MODELS:-/app/models}"
DRY="${DRY:-0}"

OUT="$MODELS/server.json"
SPECDUMP="$MODELS/specs-dump.txt"

[ -d "$MODELS" ] || { echo "No such folder: $MODELS" >&2; exit 1; }

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "No container called \"$CONTAINER\". Find it with:  docker ps | grep -i audio" >&2
    exit 1
fi

# The families this build actually knows about. A family not in here would be
# rejected, so it is the authority for the mapping below.
SPECS="$(docker exec "$CONTAINER" sh -c 'ls -1 /app/model_specs 2>/dev/null' | sed 's/\.json$//' | tr -d '\r')"
[ -n "$SPECS" ] || { echo "Couldn't read /app/model_specs inside $CONTAINER." >&2; exit 1; }

# Longest spec name that prefixes the package id. The package id comes from the
# sidecar filename, e.g. .audiocpp-package-higgs_audio_tts_4b_q8_0.json -> family
# higgs_audio_tts (beating the shorter, wrong match higgs_audio_stt would never make).
family_for() {
    local pkg="$1" best=""
    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        case "$pkg" in
            "$spec"*) [ ${#spec} -gt ${#best} ] && best="$spec" ;;
        esac
    done <<< "$SPECS"
    printf '%s' "$best"
}

# Ask the spec what the model does. Falling back to the family name is a guess, so
# anything still unknown is declared without a task and the server's own spec decides.
task_for() {
    local family="$1" t
    t="$(docker exec "$CONTAINER" sh -c "cat /app/model_specs/$family.json 2>/dev/null" \
         | grep -o '"task"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
         | sed 's/.*"\([^"]*\)"$/\1/')"
    if [ -n "$t" ]; then printf '%s' "$t"; return; fi
    case "$family" in
        *_tts|tts_*|*tts)   printf 'tts' ;;
        *_asr|*_stt|*asr|*stt) printf 'asr' ;;
        *)                  printf '' ;;
    esac
}

# The id IS the family name. That is what lets the phone app look up the model's
# own spec — which options it accepts, their ranges and defaults — without any
# endpoint to ask. It also reads well and already carries tts/asr in most names.

declare -a ENTRIES=()
declare -a SKIPPED=()
declare -a USED_IDS=()
declare -a USED_FAMILIES=()

printf '%-34s %-22s %-6s %s\n' "FOLDER" "FAMILY" "TASK" "ID"
printf '%-34s %-22s %-6s %s\n' "------" "------" "----" "--"

for dir in "$MODELS"/*/; do
    [ -d "$dir" ] || continue
    folder="$(basename "$dir")"

    sidecar="$(ls -1 "$dir".audiocpp-package-*.json 2>/dev/null | head -1)"
    if [ -z "$sidecar" ]; then
        SKIPPED+=("$folder — no .audiocpp-package-*.json sidecar, so its family is unknown")
        printf '%-34s %s\n' "$folder" "(skipped: no package sidecar)"
        continue
    fi

    pkg="$(basename "$sidecar" .json)"
    pkg="${pkg#.audiocpp-package-}"

    family="$(family_for "$pkg")"
    if [ -z "$family" ]; then
        SKIPPED+=("$folder — package \"$pkg\" matches no family in /app/model_specs")
        printf '%-34s %s\n' "$folder" "(skipped: unknown family for $pkg)"
        continue
    fi

    task="$(task_for "$family")"

    id="$family"
    n=2
    # Two packages of one family (DotTTS SOAR and MeanFlow, say) need distinct ids.
    while printf '%s\n' "${USED_IDS[@]:-}" | grep -qx "$id"; do
        id="$family-$n"; n=$((n + 1))
    done
    USED_IDS+=("$id")
    printf '%s\n' "${USED_FAMILIES[@]:-}" | grep -qx "$family" || USED_FAMILIES+=("$family")

    if [ -n "$task" ]; then
        ENTRIES+=("    {
      \"id\": \"$id\",
      \"family\": \"$family\",
      \"path\": \"$CONTAINER_MODELS/$folder\",
      \"task\": \"$task\",
      \"mode\": \"offline\"
    }")
    else
        # No task claimed anywhere: let the model spec decide rather than assert a
        # wrong one, which the config parser can reject outright.
        ENTRIES+=("    {
      \"id\": \"$id\",
      \"family\": \"$family\",
      \"path\": \"$CONTAINER_MODELS/$folder\",
      \"mode\": \"offline\"
    }")
    fi

    printf '%-34s %-22s %-6s %s\n' "$folder" "$family" "${task:-?}" "$id"
done

if [ ${#ENTRIES[@]} -eq 0 ]; then
    echo >&2
    echo "Nothing to declare — no usable model folders found in $MODELS" >&2
    exit 1
fi

body="{
  \"backend\": \"$BACKEND\",
  \"device\": $DEVICE,
  \"lazy_load\": true,
  \"max_loaded_models\": $MAX_LOADED,
  \"idle_unload_ms\": $IDLE_UNLOAD_MS,
  \"busy_timeout_ms\": 300000,

  \"models\": [
$(IFS=$'\n'; printf '%s' "$(printf '%s,\n' "${ENTRIES[@]}" | sed '$ s/,$//')")
  ]
}"

echo
if [ "$DRY" = "1" ]; then
    echo "--- would write $OUT ---"
    printf '%s\n' "$body"
else
    [ -f "$OUT" ] && cp "$OUT" "$OUT.bak"
    printf '%s\n' "$body" > "$OUT"
    echo "Wrote $OUT (${#ENTRIES[@]} models)${OUT:+, previous kept as server.json.bak}"

    # Everything needed to work out per-model request options later.
    : > "$SPECDUMP"
    for f in "${USED_FAMILIES[@]}"; do
        {
            echo "===== $f ====="
            docker exec "$CONTAINER" sh -c "cat /app/model_specs/$f.json 2>/dev/null"
            echo
        } >> "$SPECDUMP"
    done
    echo "Wrote $SPECDUMP (the specs for the families in use)"
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo
    echo "Left out:"
    for s in "${SKIPPED[@]}"; do echo "  - $s"; done
fi

echo
echo "Now restart the container:  docker restart $CONTAINER"
echo "Then check:                 curl -s http://localhost:8586/v1/models"
