#!/usr/bin/env bash
# Split a raw recording into individual "Hey Aira" utterances on silence
# boundaries. Normalizes volume, drops clips that are too short (likely
# noise) or too long (likely the user said something other than the wake
# phrase), and reports a count.
#
# Output: training/voice/clips/clip_NNN.wav, one file per utterance.
#
# Usage:
#   ./training/voice/split.sh                    # processes ALL raw takes
#   ./training/voice/split.sh path/to/raw.wav    # specific take(s)
#
# Tuning via env vars (defaults err on the side of catching quiet voices):
#   SILENCE_THRESHOLD  Below this % RMS counts as silence. Default 0.3%.
#                      Raise toward 1.0% if background noise produces too
#                      many micro-clips; lower toward 0.1% if the splitter
#                      is dropping your quietest utterances.
#   SILENCE_DURATION   Seconds of silence that end a segment. Default 0.5.
#                      Raise if clips get chopped mid-phrase.
#   MIN_CLIP_SEC       Minimum clip duration to keep. Default 0.25.
#   MAX_CLIP_SEC       Maximum clip duration to keep. Default 3.0.

set -euo pipefail

SILENCE_THRESHOLD="${SILENCE_THRESHOLD:-0.3%}"
SILENCE_DURATION="${SILENCE_DURATION:-0.5}"
MIN_CLIP_SEC="${MIN_CLIP_SEC:-0.25}"
MAX_CLIP_SEC="${MAX_CLIP_SEC:-3.0}"

# -- Guards
if ! command -v sox &> /dev/null; then
    echo "✗ sox is not installed. brew install sox"
    exit 1
fi

# -- Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_DIR="$SCRIPT_DIR/raw"
CLIPS_DIR="$SCRIPT_DIR/clips"

# Collect input files. Default: ALL *.wav under raw/ (sorted oldest→newest
# so clip numbering matches recording order). Explicit args override.
if [[ $# -ge 1 ]]; then
    RAW_FILES=("$@")
else
    # Bash-portable "sorted list of *.wav in raw/, or empty if none".
    RAW_FILES=()
    while IFS= read -r -d $'\0' f; do
        RAW_FILES+=("$f")
    done < <(find "$RAW_DIR" -maxdepth 1 -name '*.wav' -print0 2>/dev/null | sort -z)
    if [[ ${#RAW_FILES[@]} -eq 0 ]]; then
        echo "✗ No raw recordings found in $RAW_DIR"
        echo "  Run ./training/voice/record.sh first."
        exit 1
    fi
fi

# Validate all inputs exist
for f in "${RAW_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "✗ Raw file not found: $f"
        exit 1
    fi
done

echo "→ Splitting ${#RAW_FILES[@]} file(s):"
for f in "${RAW_FILES[@]}"; do
    echo "    $f"
done
echo "  Output dir:        $CLIPS_DIR"
echo "  Silence threshold: $SILENCE_THRESHOLD (quieter voices need smaller %)"
echo "  Silence duration:  ${SILENCE_DURATION}s"
echo "  Keep clips in:     [${MIN_CLIP_SEC}s, ${MAX_CLIP_SEC}s]"
echo

# -- Clean the output dir to avoid mixing old runs. We always rebuild
#    clips/ from scratch so the final numbering is deterministic.
if [[ -d "$CLIPS_DIR" ]] && compgen -G "$CLIPS_DIR/clip_*.wav" > /dev/null; then
    read -rp "Clips dir already has files. Rebuild from scratch? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 1
    fi
    rm -f "$CLIPS_DIR"/clip_*.wav
fi
mkdir -p "$CLIPS_DIR"

# -- Split each take into a per-take staging dir first, then merge.
# Using a staging dir per take keeps sox's numeric suffix from colliding
# when we process multiple takes (each sox invocation restarts at 001).
STAGE_ROOT=$(mktemp -d)
trap 'rm -rf "$STAGE_ROOT"' EXIT

take_num=0
for raw in "${RAW_FILES[@]}"; do
    take_num=$((take_num + 1))
    stage="$STAGE_ROOT/take_$(printf '%02d' $take_num)"
    mkdir -p "$stage"

    echo "  [$take_num/${#RAW_FILES[@]}] $(basename "$raw")"
    # silence filter in split mode — thresholds come from env vars at top:
    #   1 0.1 $SILENCE_THRESHOLD    → trim leading silence on each segment
    #   1 $SILENCE_DURATION $SILENCE_THRESHOLD → end segment after that much silence
    #   : newfile   → each segment goes to a new file
    #   : restart   → keep looping through the whole input
    sox "$raw" "$stage/clip_.wav" \
        silence 1 0.1 "$SILENCE_THRESHOLD" 1 "$SILENCE_DURATION" "$SILENCE_THRESHOLD" \
        : newfile : restart 2>/dev/null || true

    count=$(ls "$stage"/clip_*.wav 2>/dev/null | wc -l | tr -d ' ')
    echo "      → $count raw segments"
done

# Flatten all staging dirs into clips/ — numbering will be re-done after
# filtering, so interim collision-prone names are fine.
mv_i=0
for stage in "$STAGE_ROOT"/take_*; do
    [[ -d "$stage" ]] || continue
    for f in "$stage"/clip_*.wav; do
        [[ -f "$f" ]] || continue
        mv_i=$((mv_i + 1))
        mv "$f" "$CLIPS_DIR/raw_$(printf '%05d' $mv_i).wav"
    done
done

# -- Filter by duration: drop clips outside [MIN_CLIP_SEC, MAX_CLIP_SEC].
# Also normalize amplitude so quiet clips don't get lost in training.
echo
echo "→ Filtering and normalizing clips (drop < ${MIN_CLIP_SEC}s or > ${MAX_CLIP_SEC}s)…"
kept=0
dropped_short=0
dropped_long=0
for f in "$CLIPS_DIR"/raw_*.wav; do
    [[ -f "$f" ]] || continue
    dur=$(sox "$f" -n stat 2>&1 | awk '/Length \(seconds\)/ {print $3}')
    # bash can't do floats, so use awk for the comparison
    too_short=$(awk -v d="$dur" -v m="$MIN_CLIP_SEC" 'BEGIN{print (d < m) ? 1 : 0}')
    too_long=$(awk -v d="$dur" -v m="$MAX_CLIP_SEC" 'BEGIN{print (d > m) ? 1 : 0}')
    if [[ "$too_short" == "1" ]]; then
        rm "$f"
        dropped_short=$((dropped_short + 1))
        continue
    fi
    if [[ "$too_long" == "1" ]]; then
        rm "$f"
        dropped_long=$((dropped_long + 1))
        continue
    fi
    # Peak-normalize to -3 dB AND force 16 kHz mono int16 so clips match
    # the training pipeline's expected format regardless of what the mic
    # recorded at natively (some Macs force 44.1 / 48 kHz input even when
    # rec was invoked with -r 16000).
    sox "$f" -r 16000 -c 1 -b 16 "$f.norm.wav" norm -3
    mv "$f.norm.wav" "$f"
    kept=$((kept + 1))
done

# -- Renumber sequentially: raw_XXXXX.wav → clip_NNN.wav, cross-take order
# preserved (takes processed oldest-first, segments numbered in sequence).
echo
echo "→ Renumbering…"
i=1
tmp_dir=$(mktemp -d)
for f in "$CLIPS_DIR"/raw_*.wav; do
    [[ -f "$f" ]] || continue
    n=$(printf "%03d" "$i")
    mv "$f" "$tmp_dir/clip_$n.wav"
    i=$((i + 1))
done
mv "$tmp_dir"/clip_*.wav "$CLIPS_DIR"/
rmdir "$tmp_dir"

# -- Summary
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Split + filter complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Kept:     $kept clips"
echo "  Dropped:  $dropped_short (< 0.3s) + $dropped_long (> 3.0s)"
echo "  Location: $CLIPS_DIR"
echo
if [[ $kept -lt 40 ]]; then
    echo "  ⚠ Fewer than 40 clips. Consider recording another take"
    echo "    with clearer pauses between utterances."
elif [[ $kept -gt 130 ]]; then
    echo "  ⚠ More than 130 clips — split may have been too aggressive."
    echo "    If clips sound chopped mid-phrase, increase the silence"
    echo "    threshold (0.6s) in this script."
else
    echo "  ✓ Nice count. Good to move to fine-tuning."
fi
echo
echo "Next:"
echo "  1. Listen to a sample:  afplay $CLIPS_DIR/clip_001.wav"
echo "  2. Listen to all:       for f in $CLIPS_DIR/clip_*.wav; do afplay \"\$f\"; done"
echo "  3. Delete bad ones manually if needed: rm $CLIPS_DIR/clip_XXX.wav"
echo "  4. When happy, we'll upload them to Modal and fine-tune."
