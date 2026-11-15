#!/usr/bin/env bash
# Zkopíruje čtečku textu do sestaveného webu: tool/web_ocr/copy.sh build/web
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$1/ocr"
mkdir -p "$out"
nm="$here/node_modules"
cp "$nm/tesseract.js/dist/tesseract.min.js" "$nm/tesseract.js/dist/worker.min.js" "$out/"
cp "$nm/tesseract.js-core/tesseract-core-lstm.wasm.js" "$nm/tesseract.js-core/tesseract-core-simd-lstm.wasm.js" "$out/"
cp "$nm/@tesseract.js-data/ces/4.0.0_best_int/ces.traineddata.gz" "$out/"
cp "$nm/tesseract.js/LICENSE.md" "$out/LICENSE-tesseract.js.md" 2>/dev/null || cp "$nm/tesseract.js/LICENSE" "$out/LICENSE-tesseract.js" 2>/dev/null || true
cp "$nm/tesseract.js-core/LICENSE" "$out/LICENSE-tesseract-core" 2>/dev/null || true
ls -la "$out"
