#!/bin/sh
set -e
cd "$(dirname "$0")"
ZLANG_BIN="${ZLANG_BIN:-zlang}"
"$ZLANG_BIN" module build .
echo "Built zlisp.zlx"
