#!/usr/bin/env bash
# Record a single long WAV of you saying "Hey Aira" many times with natural
# pauses. Stops automatically after 5 seconds of silence at the end.
#
# Output: training/voice/raw/my_voice_raw.wav (16 kHz mono int16, matches the
# training pipeline's expected format exactly — no resampling needed).
#
# Usage:
#   ./training/voice/record.sh           # default 16 kHz mono, auto-stop on 5s silence
#   ./training/voice/record.sh quiet     # tag the take (recommended for multiple sessions)
#
# Recording recipe — aim for ~100 utterances across these variations:
#   - 20x normal speaking voice
#   - 15x faster than normal
#   - 10x slow / emphasized ("Heyyyy AIRA")
#   - 10x quiet / murmured (just barely audible)
#   - 10x excited / loud
#   - 10x tired / groggy / low-energy
#   - 15x varied distance (close / arm's length / across room)
#   - 10x while moving (turning head, walking past mic)
#
# Leave ~2 seconds of silence between each utterance so the splitter can
# cleanly separate them. Background noise is fine — include some ambient
# variation (fan, typing, TV on low) for realism.

set -euo pipefail

# -- Guard: sox installed?
if ! command -v rec &> /dev/null; then
    echo "✗ sox is not installed."
    echo "  Install it with: brew install sox"
    exit 1
fi

# -- Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_DIR="$SCRIPT_DIR/raw"
mkdir -p "$RAW_DIR"

TAG="${1:-take}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$RAW_DIR/${TAG}_${TIMESTAMP}.wav"

# -- Instructions
cat <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Recording "Hey Aira" — training clips for voice fine-tune
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • Leave ~2 seconds of silence between each "Hey Aira" utterance.
  • Recording auto-stops after 5 seconds of silence.
  • Ctrl-C to stop manually.
  • Mix up speed / volume / tone — the more variation the better.

  Goal: 100 utterances (~5 minutes of audio).

EOF

read -rp "Press Enter when ready to start recording…"
echo
echo "🔴 Recording → $OUT"
echo "   (say 'Hey Aira' with pauses; 5s silence ends recording)"
echo

# -- Record
# 16 kHz mono 16-bit — matches training pipeline exactly.
# silence filter:
#   1 0.1 1%  → trim leading silence (wait for 0.1s above 1% to start)
#   1 5.0 1%  → stop after 5s of silence below 1%
rec -q -r 16000 -c 1 -b 16 "$OUT" silence 1 0.1 1% 1 5.0 1%

# -- Report
DURATION=$(sox "$OUT" -n stat 2>&1 | awk '/Length \(seconds\)/ {print $3}')
SIZE_KB=$(du -k "$OUT" | awk '{print $1}')

echo
echo "✓ Saved: $OUT"
echo "  Duration: ${DURATION}s"
echo "  Size:     ${SIZE_KB} KB"
echo
echo "Next: split it into individual clips:"
echo "  ./training/voice/split.sh $OUT"
