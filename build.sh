#!/bin/bash
# Build script for LLPL compiler and examples

set -e

echo "Building LLPL compiler..."
dub build

echo ""
echo "LLPL compiler built successfully!"
echo ""
echo "Usage:"
echo "  ./llpl <input.llpl> -o <output.c>      # Compile LLPL to C"
echo "  ./llpl <input.llpl> -o <output.c> -v   # Verbose compilation"
echo ""
echo "To build the example kernel:"
echo "  cd examples && make"
echo ""
echo "To run the kernel in QEMU:"
echo "  cd examples && make run"
echo ""
