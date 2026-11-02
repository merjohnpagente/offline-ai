#!/usr/bin/env bash
# One-time model download for the on-device Flutter app.
# The app itself never downloads anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/flutter_app/assets/models"
OUT="$OUT_DIR/model.gguf"
URL="https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf?download=true"
EXPECTED="1d9614638d18024d0fbb36575a15f1302a3adf044df10345688ec4f6e1c4ff32"

mkdir -p "$OUT_DIR"

if [ -f "$OUT" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$OUT" | awk '{print $1}')"
  else
    ACTUAL="$(shasum -a 256 "$OUT" | awk '{print $1}')"
  fi
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    echo "Model already present and verified: $OUT"
    exit 0
  fi
  echo "Existing file does not match; replacing it."
  rm -f "$OUT"
fi

echo "Downloading Qwen2.5-Coder-0.5B-Instruct Q4_K_M (~470 MB)..."
curl -L --fail --retry 3 -o "$OUT" "$URL"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$OUT" | awk '{print $1}')"
else
  ACTUAL="$(shasum -a 256 "$OUT" | awk '{print $1}')"
fi

if [ "$ACTUAL" != "$EXPECTED" ]; then
  rm -f "$OUT"
  echo "SHA-256 mismatch. Expected $EXPECTED, got $ACTUAL" >&2
  exit 1
fi

echo "Saved and verified: $OUT"
