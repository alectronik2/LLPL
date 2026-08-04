#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BIN="${SELFHOST_BIN:-${TMPDIR:-/tmp}/llpl-selfhost-parse-all}"
MAX_LINES="${SELFHOST_MAX_LINES:-15000}"
TIMEOUT="${SELFHOST_TIMEOUT:-10s}"

"$ROOT/llpl" -b "$ROOT/tools/selfhost/lexer.llpl" -o "$BIN"

checked=0
for src in $(cd "$ROOT" && rg --files -g'*.llpl'); do
  checked=$((checked + 1))
  label=$(printf '%s' "$src" | tr '/ ' '__')
  out="${TMPDIR:-/tmp}/llpl-selfhost-all-$label.out"

  if ! timeout "$TIMEOUT" "$BIN" --parse "$ROOT/$src" > "$out"; then
    printf 'selfhost parse failed: %s\n' "$src" >&2
    exit 1
  fi

  if grep -q '^parse error:' "$out"; then
    printf 'selfhost parse emitted diagnostics: %s\n' "$src" >&2
    grep -n '^parse error:' "$out" | head >&2
    exit 1
  fi

  if [ "$(wc -l < "$out")" -gt "$MAX_LINES" ]; then
    printf 'selfhost parse produced unexpectedly large output: %s\n' "$src" >&2
    exit 1
  fi
done

printf 'selfhost parse-all: checked %s files\n' "$checked"
