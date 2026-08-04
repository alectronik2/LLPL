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
MODERN_PARSE_OUT="${TMPDIR:-/tmp}/llpl-selfhost-modern-parser-sample.out"
FOR_PARSE_OUT="${TMPDIR:-/tmp}/llpl-selfhost-for-parser-sample.out"

smoke_parse() {
  src="$1"
  label="$2"
  out="${TMPDIR:-/tmp}/llpl-selfhost-smoke-$label.out"
  if ! timeout 10s "$BIN" --parse "$src" > "$out"; then
    printf '%s\n' "$label parse failed or timed out" >&2
    exit 1
  fi
  if grep -q '^parse error:' "$out"; then
    printf '%s\n' "$label parse emitted parser diagnostics" >&2
    exit 1
  fi
  if [ "$(wc -l < "$out")" -gt 10000 ]; then
    printf '%s\n' "$label parse produced unexpectedly large output" >&2
    exit 1
  fi
}

sweep_parse_all() {
  count=0
  for src in $(cd "$ROOT" && rg --files -g'*.llpl'); do
    count=$((count + 1))
    label=$(printf '%s' "$src" | tr '/ ' '__')
    out="${TMPDIR:-/tmp}/llpl-selfhost-sweep-$label.out"
    if ! timeout 10s "$BIN" --parse "$ROOT/$src" > "$out"; then
      printf 'sweep parse failed or timed out: %s\n' "$src" >&2
      exit 1
    fi
    if grep -q '^parse error:' "$out"; then
      printf 'sweep parse emitted parser diagnostics: %s\n' "$src" >&2
      grep '^parse error:' "$out" | head >&2
      exit 1
    fi
    if [ "$(wc -l < "$out")" -gt 15000 ]; then
      printf 'sweep parse produced unexpectedly large output: %s\n' "$src" >&2
      exit 1
    fi
  done
  printf 'selfhost full sweep parsed %s files\n' "$count"
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
"$BIN" --parse "$ROOT/test/fixtures/selfhost_modern_syntax_sample.input" > "$MODERN_PARSE_OUT"
diff -u "$ROOT/test/selfhost_modern_syntax_parser_sample.expected" "$MODERN_PARSE_OUT"
"$BIN" --parse "$ROOT/test/fixtures/selfhost_for_sample.input" > "$FOR_PARSE_OUT"
diff -u "$ROOT/test/selfhost_for_parser_for_sample.expected" "$FOR_PARSE_OUT"

smoke_parse "$ROOT/prelude.llpl" prelude
smoke_parse "$ROOT/stdlib/text/string_utils.llpl" string-utils
smoke_parse "$ROOT/stdlib/collections/heap.llpl" heap
smoke_parse "$ROOT/stdlib/yaml/yaml_parser.llpl" yaml-parser
smoke_parse "$ROOT/examples/limine_baremetal_demo/hal/idt.llpl" limine-idt
smoke_parse "$ROOT/examples/limine_baremetal_demo/mm/vmm.llpl" limine-vmm
smoke_parse "$ROOT/test/test_tuples.llpl" tuples
smoke_parse "$ROOT/test/contextual_interrupt_name.llpl" contextual-interrupt
smoke_parse "$ROOT/tools/llpl-bindgen.llpl" llpl-bindgen
smoke_parse "$ROOT/tools/selfhost/lexer.llpl" selfhost-lexer

if [ "${SELFHOST_FULL_SWEEP:-0}" = "1" ]; then
  sweep_parse_all
fi
