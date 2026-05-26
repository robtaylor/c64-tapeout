#!/usr/bin/env python3
"""Convert Altera MIF (Memory Initialization File) to a Verilog ROM module.

Usage: python3 mif2rom.py <input.mif> <module_name> <addr_width> > output.sv
"""

import re
import sys
from pathlib import Path


def parse_mif(path: Path) -> dict[int, int]:
    """Parse an Altera MIF file, returning {address: data}."""
    data = {}
    in_content = False

    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("--"):
                continue

            if "CONTENT BEGIN" in line.upper():
                in_content = True
                continue

            if line.upper().startswith("END"):
                in_content = False
                continue

            if not in_content:
                continue

            line = line.rstrip(";").strip()
            if ":" not in line:
                continue

            addr_part, data_part = line.split(":", 1)
            addr_part = addr_part.strip()
            data_val = int(data_part.strip(), 16)

            range_match = re.match(r"\[([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)\]", addr_part)
            if range_match:
                start = int(range_match.group(1), 16)
                end = int(range_match.group(2), 16)
                for a in range(start, end + 1):
                    data[a] = data_val
            else:
                addr = int(addr_part, 16)
                data[addr] = data_val

    return data


def generate_rom(data: dict[int, int], module_name: str, addr_width: int):
    """Generate a Verilog ROM module from parsed MIF data."""
    depth = 1 << addr_width
    hex_digits = (addr_width + 3) // 4

    print("// SPDX-License-Identifier: Apache-2.0")
    print("// Auto-generated from MIF file — do not edit by hand")
    print(f"// {module_name}: {depth} x 8-bit ROM")
    print()
    print("`default_nettype none")
    print()
    print(f"module {module_name} (")
    print(f"    input  wire [{addr_width - 1}:0] addr,")
    print("    output reg  [7:0]  data")
    print(");")
    print()
    print("    always @* begin")
    print("        case (addr)")

    default_val = 0x00
    if data:
        from collections import Counter
        counts = Counter(data.values())
        default_val = counts.most_common(1)[0][0]

    for addr in range(depth):
        val = data.get(addr, default_val)
        if val != default_val:
            print(f"            {addr_width}'h{addr:0{hex_digits}X}: data = 8'h{val:02X};")

    print(f"            default:  data = 8'h{default_val:02X};")
    print("        endcase")
    print("    end")
    print()
    print("endmodule")
    print()
    print("`default_nettype wire")


def main():
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <input.mif> <module_name> <addr_width>",
              file=sys.stderr)
        sys.exit(1)

    mif_path = Path(sys.argv[1])
    module_name = sys.argv[2]
    addr_width = int(sys.argv[3])

    data = parse_mif(mif_path)
    generate_rom(data, module_name, addr_width)


if __name__ == "__main__":
    main()
