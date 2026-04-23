#!/usr/bin/env bash
# Clean voice-training artifacts so you can start a take fresh.
#
# Usage:
#   ./training/voice/clean.sh            # wipes clips/ only (keeps raw takes)
#   ./training/voice/clean.sh --all      # wipes clips/ AND raw/  (destructive)
#   ./training/voice/clean.sh --raw      # wipes raw/ only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_DIR="$SCRIPT_DIR/raw"
CLIPS_DIR="$SCRIPT_DIR/clips"

MODE="clips"
case "${1:-}" in
    "")       MODE="clips" ;;
    --all)    MODE="all" ;;
    --raw)    MODE="raw" ;;
    --help|-h)
        sed -n '2,10p' "$0"
        exit 0
        ;;
    *)
        echo "Unknown flag: $1"
        echo "Use --all or --raw; no flag = clips only."
        exit 2
        ;;
esac

wipe_clips() {
    local n
    n=$(find "$CLIPS_DIR" -maxdepth 1 -name 'clip_*.wav' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$n" -eq 0 ]]; then
        echo "  clips/: already empty"
    else
        rm -f "$CLIPS_DIR"/clip_*.wav "$CLIPS_DIR"/raw_*.wav
        echo "  clips/: removed $n clips"
    fi
}

wipe_raw() {
    local n
    n=$(find "$RAW_DIR" -maxdepth 1 -name '*.wav' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$n" -eq 0 ]]; then
        echo "  raw/:   already empty"
    else
        echo "  raw/:   about to delete $n take(s) in $RAW_DIR"
        read -rp "  Confirm? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "  raw/:   skipped"
            return
        fi
        rm -f "$RAW_DIR"/*.wav
        echo "  raw/:   removed $n take(s)"
    fi
}

echo "Cleaning voice artifacts (mode: $MODE)"
case "$MODE" in
    clips) wipe_clips ;;
    raw)   wipe_raw ;;
    all)   wipe_clips; wipe_raw ;;
esac
echo "Done."
