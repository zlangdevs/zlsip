#!/bin/sh
set -e
cd "$(dirname "$0")"
zig build-lib -dynamic -OReleaseSafe -fPIC -lc src/plugin.zig -femit-bin=zlisp.so
zlang module pack . -o zlisp.zlx
echo "Built zlisp.zlx"
