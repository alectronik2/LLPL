#!/bin/bash
# Thin wrapper around `tools/llplbuild/llplbuild test` - the actual
# compile/run/diff logic for the LLPL test suite lives there now
# (source/testrunner.d), not here, so there's exactly one implementation
# instead of two drifting apart. Kept so CI/muscle-memory `./run_tests.sh`
# keeps working unchanged.

set -euo pipefail

cd "$(dirname "$0")"

if [ ! -x ./llpl ]; then
    echo "Compiler not found; building..."
    dub build
fi

if [ ! -x tools/llplbuild/llplbuild ]; then
    echo "llplbuild not found; building..."
    (cd tools/llplbuild && dub build)
fi

exec tools/llplbuild/llplbuild test "$@"
