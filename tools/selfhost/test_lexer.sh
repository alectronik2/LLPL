#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BIN="${TMPDIR:-/tmp}/llpl-selfhost-lexer"
OUT="${TMPDIR:-/tmp}/llpl-selfhost-lexer-sample.out"
PARSE_OUT="${TMPDIR:-/tmp}/llpl-selfhost-parser-sample.out"
DIRECTIVE_OUT="${TMPDIR:-/tmp}/llpl-selfhost-directive-sample.out"
DIRECTIVE_PARSE_OUT="${TMPDIR:-/tmp}/llpl-selfhost-directive-parser-sample.out"
DSL_OUT="${TMPDIR:-/tmp}/llpl-selfhost-dsl-sample.out"
DSL_PARSE_OUT="${TMPDIR:-/tmp}/llpl-selfhost-dsl-parser-sample.out"
RECOVERY_PARSE_OUT="${TMPDIR:-/tmp}/llpl-selfhost-recovery-parser-sample.out"

smoke_parse() {
  src="$1"
  label="$2"
  out="${TMPDIR:-/tmp}/llpl-selfhost-smoke-$label.out"
  "$BIN" --parse "$src" > "$out"
  if grep -q '^parse error:' "$out"; then
    printf '%s\n' "$label parse emitted parser diagnostics" >&2
    exit 1
  fi
  if [ "$(wc -l < "$out")" -gt 10000 ]; then
    printf '%s\n' "$label parse produced unexpectedly large output" >&2
    exit 1
  fi
}

"$ROOT/llpl" -b "$ROOT/tools/selfhost/lexer.llpl" -o "$BIN"
"$BIN" "$ROOT/test/fixtures/selfhost_lexer_sample.input" > "$OUT"
diff -u "$ROOT/test/selfhost_lexer_sample.expected" "$OUT"
"$BIN" --parse "$ROOT/test/fixtures/selfhost_lexer_sample.input" > "$PARSE_OUT"
diff -u "$ROOT/test/selfhost_parser_sample.expected" "$PARSE_OUT"
"$BIN" "$ROOT/test/fixtures/selfhost_directive_sample.input" > "$DIRECTIVE_OUT"
diff -u "$ROOT/test/selfhost_directive_sample.expected" "$DIRECTIVE_OUT"
"$BIN" --parse "$ROOT/test/fixtures/selfhost_directive_sample.input" > "$DIRECTIVE_PARSE_OUT"
diff -u "$ROOT/test/selfhost_directive_parser_sample.expected" "$DIRECTIVE_PARSE_OUT"
"$BIN" "$ROOT/test/fixtures/selfhost_dsl_sample.input" > "$DSL_OUT"
diff -u "$ROOT/test/selfhost_dsl_sample.expected" "$DSL_OUT"
"$BIN" --parse "$ROOT/test/fixtures/selfhost_dsl_sample.input" > "$DSL_PARSE_OUT"
diff -u "$ROOT/test/selfhost_dsl_parser_sample.expected" "$DSL_PARSE_OUT"
"$BIN" --parse "$ROOT/test/fixtures/selfhost_recovery_sample.input" > "$RECOVERY_PARSE_OUT"
diff -u "$ROOT/test/selfhost_recovery_parser_sample.expected" "$RECOVERY_PARSE_OUT"

smoke_parse "$ROOT/prelude.llpl" prelude
smoke_parse "$ROOT/stdlib/text/string_utils.llpl" string-utils
smoke_parse "$ROOT/stdlib/collections/heap.llpl" heap
smoke_parse "$ROOT/tools/llpl-bindgen.llpl" llpl-bindgen
smoke_parse "$ROOT/tools/selfhost/lexer.llpl" selfhost-lexer
