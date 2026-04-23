#!/usr/bin/env bash
# Convenience wrapper around `modal run training/modal_train.py::fetch`.
# Pulls the most recent trained hey_aira.onnx out of the Modal volume,
# writes it to HandsFree/Resources/, and reminds you to flip the two
# strings in WakeWordEngine.swift.
set -euo pipefail

cd "$(dirname "$0")/.."

MODEL_NAME="${1:-hey_aira}"
DEST="HandsFree/Resources/${MODEL_NAME}.onnx"

modal run training/modal_train.py::fetch \
    --model-name "$MODEL_NAME" \
    --dest "$DEST"

echo
echo "✓ Model written to $DEST"
echo
echo "Next steps:"
echo "  1. Edit HandsFree/Core/WakeWordEngine.swift:"
echo "       static let bundledClassifierName = \"$MODEL_NAME\""
echo "       static let wakePhrase = \"Hey Aira\""
echo "  2. Rebuild: xcodegen generate && xcodebuild -scheme HandsFree build"
echo "  3. (Optional) delete Resources/hey_livekit.onnx to shrink the app."
