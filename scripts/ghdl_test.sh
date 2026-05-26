#!/usr/bin/env bash
# Quick GHDL analysis test — validates that all VHDL files parse.
# Run from project root inside the nix shell: bash scripts/ghdl_test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== GHDL analysis test ==="
echo "GHDL version: $(ghdl --version | head -1)"
echo ""

# Create work directory
WORK_DIR=$(mktemp -d /tmp/claude/ghdl_test.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

# Analyze each VHDL file in elaboration order (from vhdl.f)
while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    echo "Analyzing: $line"
    ghdl -a --std=08 -fsynopsys --workdir="$WORK_DIR" "$line"
done < vhdl.f

echo ""
echo "=== All VHDL files analyzed successfully ==="
echo ""

# Try synthesis of the top-level entity
echo "=== Attempting synthesis of c64_system ==="
ghdl --synth --std=08 -fsynopsys --workdir="$WORK_DIR" c64_system 2>&1 | head -50
echo ""
echo "=== Done ==="
