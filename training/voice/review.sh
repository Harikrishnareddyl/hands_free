#!/usr/bin/env bash
# Quick review: plays each clip in training/voice/clips/ sequentially.
# Press Ctrl-C to stop.
#
# Use this after split.sh to catch obviously-bad clips (silence, laughter,
# mouth noise, mid-phrase chops) and delete them before fine-tuning.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIPS_DIR="$SCRIPT_DIR/clips"

if ! compgen -G "$CLIPS_DIR/clip_*.wav" > /dev/null; then
    echo "✗ No clips in $CLIPS_DIR — run split.sh first."
    exit 1
fi

total=$(ls "$CLIPS_DIR"/clip_*.wav | wc -l | tr -d ' ')
echo "Playing $total clips. Ctrl-C to stop."
echo

i=1
for f in "$CLIPS_DIR"/clip_*.wav; do
    dur=$(sox "$f" -n stat 2>&1 | awk '/Length \(seconds\)/ {print $3}')
    printf "  [%d/%d] %s (%.2fs)\n" "$i" "$total" "$(basename "$f")" "$dur"
    afplay "$f"
    i=$((i + 1))
done

echo
echo "Done. To delete specific clips:"
echo "  rm $CLIPS_DIR/clip_XXX.wav"
