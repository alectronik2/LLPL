#!/usr/bin/env bash
set -euo pipefail

out="${TMPDIR:-/tmp}/llpl_png_decode_host"
clang -x c -Dstatic= -O0 -g userapp/tests/png_decode_host.stub userapp/png_decode.c -o "$out"

fixtures=(
  media/terminal.png
  media/files.png
  media/tasks.png
  media/editor.png
  media/images.png
  media/ping.png
  media/tetris.png
  media/settings.png
  media/crashviewer.png
)

if command -v magick >/dev/null 2>&1; then
  magick media/terminal.png -colors 16 "PNG8:${TMPDIR:-/tmp}/llpl_png8_terminal.png"
  fixtures+=("${TMPDIR:-/tmp}/llpl_png8_terminal.png")
fi

"$out" "${fixtures[@]}"
