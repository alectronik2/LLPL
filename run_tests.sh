#!/bin/bash
# Run the LLPL test suite.
# Each test/*.llpl file is compiled, linked against the runtime, and executed.
# If a matching test/<name>.expected file exists, stdout is compared to it.
# The macro_quote demo is skipped because it intentionally has no main().

set -uo pipefail

cd "$(dirname "$0")"

COMPILER=./llpl
RUNTIME_DIR=runtime
TMP_C=$(mktemp /tmp/llpl_test_XXXXXX.c)
TMP_BIN=$(mktemp /tmp/llpl_test_XXXXXX)
TMP_OUT=$(mktemp /tmp/llpl_test_XXXXXX.out)

PASSED=0
FAILED=0

if [ ! -x "$COMPILER" ]; then
    echo "Compiler not found; building..."
    if ! dub build >/dev/null 2>&1; then
        echo "ERROR: failed to build compiler"
        exit 1
    fi
fi

for src in test/*.llpl; do
    base=$(basename "$src" .llpl)

    if [ "$base" = "macro_quote" ]; then
        echo "[SKIP] $src  (no main)"
        continue
    fi

    expected="test/$base.expected"
    expected_fail="test/$base.expected_fail"

    # Optional per-test compiler flags (e.g. --safe for bounds-check tests)
    extra_flags=()
    if [ -f "test/$base.flags" ]; then
        extra_flags=($(<"test/$base.flags"))
    fi

    if ! "$COMPILER" "${extra_flags[@]}" "$src" -o "$TMP_C" >/dev/null 2>&1; then
        echo "[FAIL] $src  (compiler error)"
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! gcc "$TMP_C" "$RUNTIME_DIR"/runtime.c -I "$RUNTIME_DIR" -o "$TMP_BIN" >/dev/null 2>&1; then
        echo "[FAIL] $src  (C backend error)"
        FAILED=$((FAILED + 1))
        continue
    fi

    rc=0
    "$TMP_BIN" > "$TMP_OUT" 2>&1 || rc=$?

    if [ -f "$expected_fail" ]; then
        if [ $rc -eq 0 ]; then
            echo "[FAIL] $src  (expected runtime failure but exited 0)"
            FAILED=$((FAILED + 1))
            continue
        fi
        if [ -f "$expected" ]; then
            if diff -u "$expected" "$TMP_OUT" >/dev/null 2>&1; then
                echo "[PASS] $src  (expected failure)"
                PASSED=$((PASSED + 1))
            else
                echo "[FAIL] $src  (expected failure output differs)"
                diff -u "$expected" "$TMP_OUT" | sed 's/^/    /' | head -40
                FAILED=$((FAILED + 1))
            fi
        else
            echo "[PASS] $src  (expected failure, no output check)"
            PASSED=$((PASSED + 1))
        fi
        continue
    fi

    if [ $rc -ne 0 ]; then
        echo "[FAIL] $src  (runtime exit code $rc)"
        FAILED=$((FAILED + 1))
        continue
    fi

    if [ -f "$expected" ]; then
        if diff -u "$expected" "$TMP_OUT" >/dev/null 2>&1; then
            echo "[PASS] $src"
            PASSED=$((PASSED + 1))
        else
            echo "[FAIL] $src  (output differs from $expected)"
            diff -u "$expected" "$TMP_OUT" | sed 's/^/    /' | head -40
            FAILED=$((FAILED + 1))
        fi
    else
        echo "[PASS] $src  (no expected output)"
        PASSED=$((PASSED + 1))
    fi
done

rm -f "$TMP_C" "$TMP_BIN" "$TMP_OUT"

echo ""
echo "Passed: $PASSED  Failed: $FAILED"

if [ $FAILED -ne 0 ]; then
    exit 1
fi
