#!/bin/zsh
# Set up on-device transcription: builds whisper.cpp (Metal) and downloads one
# model into data/local-asr/ (gitignored). Nothing is installed system-wide;
# CMake runs through uv if it isn't installed.
#
#   npm run setup:local-asr        # ~550 MB model, a few minutes to build
#
# Then either set THREADLINE_TRANSCRIBE=local (audio never leaves the laptop)
# or leave it unset and the local engine becomes the first fallback when the
# speech API fails.
set -euo pipefail

WHISPER_TAG="v1.9.1"
MODEL="ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
# Voice-activity detection, so silence isn't "transcribed" into stock phrases.
VAD="ggml-silero-v5.1.2.bin"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/$VAD"
DIR="data/local-asr"

cd "$(dirname "$0")/.."
mkdir -p "$DIR"

if command -v cmake >/dev/null; then CMAKE=(cmake)
elif command -v uvx >/dev/null; then CMAKE=(uvx cmake)
else echo "Needs CMake: install it, or install uv (https://docs.astral.sh/uv/) and rerun."; exit 1
fi

if [[ ! -x "$DIR/whisper-cli" ]]; then
  echo "→ building whisper.cpp $WHISPER_TAG with Metal"
  rm -rf "$DIR/src"
  git clone --quiet --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$DIR/src"
  "${CMAKE[@]}" -S "$DIR/src" -B "$DIR/src/build" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF >/dev/null
  "${CMAKE[@]}" --build "$DIR/src/build" --config Release -j --target whisper-cli >/dev/null
  cp "$DIR/src/build/bin/whisper-cli" "$DIR/whisper-cli"
  rm -rf "$DIR/src"
fi

if [[ ! -s "$DIR/$MODEL" ]]; then
  echo "→ downloading $MODEL"
  curl -fL --progress-bar -o "$DIR/$MODEL.part" "$MODEL_URL"
  mv "$DIR/$MODEL.part" "$DIR/$MODEL"
fi

if [[ ! -s "$DIR/$VAD" ]]; then
  echo "→ downloading $VAD"
  curl -fsSL -o "$DIR/$VAD.part" "$VAD_URL"
  mv "$DIR/$VAD.part" "$DIR/$VAD"
fi

"$DIR/whisper-cli" --help >/dev/null 2>&1 || { echo "whisper-cli failed to run"; exit 1; }
echo "✓ local transcription ready: $DIR/whisper-cli + $MODEL + $VAD"
