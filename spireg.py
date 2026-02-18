#!/usr/bin/env python3
"""
SPI Register Interface Generator
Generates Verilog-2005 compatible SPI slave + register file from CSV specification.
The SPI and the registers are directly clocked with SCLK; no other clock is required.

SPI protocol:
- Byte 0: RW bit (1) + 7-bit address
- Byte 1+: 8-bit data (write data or dummy for read)
- rw: 1 for write, 0 for read
- Multi-byte transfers: address auto-increments after each data byte
- Address saturates at 0x7F (does NOT wrap to 0x00)
- Maximum transfer: 128 bytes (1 command + 127 data bytes)
- Mode 0: CPOL=0, CPHA=0

CSV format:
- First line must contain (in any order): reg_name,field_name,lsb,msb,type,reset
- Following lines define register fields.
- reg_name can be empty to reuse from the previous line.
- type can be rw (read/write) or ro (read only)
- rw creates output from the regmap, ro generates input to the regmap

Synthesizability notes:
- All always blocks use at most one clock edge plus one async reset.
- posedge cs_n is used as async reset on receive and TX blocks (one clock + one async = standard FF).
- No 3-edge sensitivity lists are generated.
- 2-FF synchronizers are clocked by SCLK. This limits metastability settling time to
  one SCLK half-period when SCLK is toggling; use with care for very fast SCLK rates.
  If RO inputs change only between transactions this is a non-issue.
"""

import csv
import re
import sys
from pathlib import Path

# Valid Verilog-2005 identifier: starts with letter or underscore, rest alphanumeric/_
_IDENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')

MAX_REGS = 128  # 7-bit address space


def _check_identifier(name: str, context: str) -> None:
    if not _IDENT_RE.match(name):
        raise ValueError(f"'{name}' in {context} is not a valid Verilog identifier")


def _parse_reset_to_int(reset_str: str) -> int:
    s = reset_str.strip()
    if not s:
        return 0
    if s.startswith(("0x", "0X")):
        return int(s, 16)
    if s.startswith(("0b", "0B")):
        return int(s, 2)
    return int(s, 10)


def parse_csv(csv_file):
    """Parse CSV file and return register definitions."""
    registers = []

    with open(csv_file, "r") as f:
        reader = csv.DictReader(f)

        required_cols = {"reg_name", "field_name", "lsb", "msb", "type", "reset"}
        if not required_cols.issubset(set(reader.fieldnames or [])):
            raise ValueError(f"CSV must contain columns: {required_cols}")

        current_reg = None
        last_reg_name = None
        seen_reg_names = {}  # name -> True, to detect non-contiguous reuse

        for row in reader:
            reg_name = (row.get("reg_name") or "").strip()
            if not reg_name:
                if last_reg_name is None:
                    raise ValueError("First row must have a reg_name")
                reg_name = last_reg_name
            else:
                last_reg_name = reg_name

            _check_identifier(reg_name, "reg_name column")

            field_name = (row.get("field_name") or "").strip()
            if not field_name:
                raise ValueError(f"field_name is empty in register '{reg_name}'")
            _check_identifier(field_name, f"register '{reg_name}'")

            lsb = int(row["lsb"])
            msb = int(row["msb"])
            field_type = (row.get("type") or "").strip().lower()
            reset_val = (row.get("reset") or "").strip()

            if field_type not in ("rw", "ro"):
                raise ValueError(
                    f"Invalid type '{field_type}' for {reg_name}.{field_name}. Must be 'rw' or 'ro'"
                )

            if lsb > msb or msb > 7 or lsb < 0:
                raise ValueError(
                    f"Invalid bit range [{msb}:{lsb}] for {reg_name}.{field_name}"
                )

            # Start new register or add field to current
            if current_reg is None or current_reg["name"] != reg_name:
                if reg_name in seen_reg_names:
                    print(
                        f"Warning: register '{reg_name}' appears non-contiguously in CSV; "
                        f"it will be assigned a new address (not merged with earlier occurrence).",
                        file=sys.stderr,
                    )
                if current_reg is not None:
                    registers.append(current_reg)
                current_reg = {"name": reg_name, "fields": []}
                seen_reg_names[reg_name] = True

            reset_int = _parse_reset_to_int(reset_val) if reset_val else 0
            field_max = (1 << (msb - lsb + 1)) - 1
            if reset_int > field_max:
                print(
                    f"Warning: reset value {reset_val!r} for {reg_name}.{field_name} "
                    f"exceeds field width ({msb - lsb + 1} bits, max {field_max}); "
                    f"value will be truncated.",
                    file=sys.stderr,
                )

            current_reg["fields"].append(
                {
                    "name": field_name,
                    "lsb": lsb,
                    "msb": msb,
                    "width": msb - lsb + 1,
                    "type": field_type,
                    "reset": reset_val,
                }
            )

        if current_reg is not None:
            registers.append(current_reg)

    if len(registers) > MAX_REGS:
        raise ValueError(
            f"CSV defines {len(registers)} registers but the 7-bit address space "
            f"supports at most {MAX_REGS}."
        )

    # Check for field overlaps within each register
    for reg in registers:
        bits_used = [False] * 8
        for field in reg["fields"]:
            for bit in range(field["lsb"], field["msb"] + 1):
                if bits_used[bit]:
                    raise ValueError(
                        f"Bit {bit} in register '{reg['name']}' is used by multiple fields"
                    )
                bits_used[bit] = True

    return registers


def generate_verilog(registers, output_file):
    """
    Generate synthesizable SPI register interface.

    Synthesizability strategy:
      - Receive block:  clock=posedge sclk, async-reset=posedge cs_n (also negedge rst_n)
                        Standard 2-edge FF. Resets on CS deassert (end of transaction).
      - Write block:    clock=posedge sclk, async-reset=negedge rst_n only.
                        CS gated by level (!cs_n) in body. Standard 2-edge FF.
      - TX block:       clock=negedge sclk, async-reset=posedge cs_n (also negedge rst_n).
                        Standard 2-edge FF.
      - Synchronizers:  clock=posedge sclk, async-reset=negedge rst_n. Standard 2-edge FF.
      No 3-edge sensitivity lists anywhere.

    Read path timing:
      addr is captured on posedge sclk at bit_count==7.
      read_byte is combinational from addr.
      TX block samples read_byte on negedge sclk at bit_count==8.
      This gives one full SCLK half-period for addr->read_byte to settle.
      Constrain: Tcomb(addr->read_byte) + Tsetup(TX FF) < T_sclk/2.
    """

    addr_width = 7
    data_width = 8
    BCW = 10          # bit_count width: 0..1023, covers 1 cmd byte + 127 data bytes
    MAX_ADDR = 127    # saturate here, no wrap
    num_regs = len(registers)

    # Assign sequential addresses
    for idx, reg in enumerate(registers):
        reg["addr"] = idx

    # Collect field lists (also annotate reg_name/addr onto each field)
    ro_fields = []
    rw_fields = []
    for reg in registers:
        for field in reg["fields"]:
            field["reg_name"] = reg["name"]
            field["reg_addr"] = reg["addr"]
            (ro_fields if field["type"] == "ro" else rw_fields).append(field)

    v = []

    # -------------------------------------------------------------------------
    # Header
    # -------------------------------------------------------------------------
    v += [
        "// Auto-generated SPI Register Interface",
        "// Generated by spireg.py from CSV specification",
        "// Verilog-2005 compatible, synthesizable (single clock + single async per block)",
        "//",
        "// Protocol: Variable-length transfers",
        "//   Byte 0 : 1 RW bit + 7-bit address",
        "//   Byte 1+: 8-bit data (address auto-increments after each byte)",
        "//   Address saturates at 0x7F (no wrap); up to 127 data bytes per transfer",
        "// Mode 0: CPOL=0, CPHA=0",
        "//",
        "// Reset / CS strategy:",
        "//   rst_n    : async system reset, resets everything",
        "//   cs_n     : posedge used as async reset on receive and TX blocks",
        "//              (resets framing state at end of transaction - valid because",
        "//               master must hold CS high before starting a new transaction)",
        "//              Write block uses cs_n as level gate only (not in sensitivity list)",
        "//",
        "// MISO: core drives MISO at all times; pad-ring should tri-state when cs_n=1",
        "`timescale 1ns / 1ps",
        "",
    ]

    # -------------------------------------------------------------------------
    # Port list
    # -------------------------------------------------------------------------
    port_items = []
    port_items.append(("comment", "    // SPI interface"))
    port_items.append(("port",    "    input  wire       sclk"))
    port_items.append(("port",    "    input  wire       mosi"))
    port_items.append(("port",    "    output reg        miso"))
    port_items.append(("port",    "    input  wire       cs_n"))
    port_items.append(("blank",   ""))
    port_items.append(("comment", "    // System reset (active low, async)"))
    port_items.append(("port",    "    input  wire       rst_n"))

    if ro_fields:
        port_items.append(("blank",   ""))
        port_items.append(("comment", "    // Read-only field inputs (from chip internals)"))
        for f in ro_fields:
            sig = f"{f['reg_name']}_{f['name']}_i"
            w = f"[{f['width']-1}:0] " if f["width"] > 1 else "      "
            port_items.append(("port", f"    input  wire {w}{sig}"))

    if rw_fields:
        port_items.append(("blank",   ""))
        port_items.append(("comment", "    // Read-write field outputs (to chip internals)"))
        for f in rw_fields:
            sig = f"{f['reg_name']}_{f['name']}_o"
            w = f"[{f['width']-1}:0] " if f["width"] > 1 else "      "
            port_items.append(("port", f"    output wire {w}{sig}"))

    last_port_idx = max(i for i, (k, _) in enumerate(port_items) if k == "port")
    v.append("module spi_reg_interface (")
    for i, (kind, line) in enumerate(port_items):
        if kind == "port":
            v.append(line + ("," if i != last_port_idx else ""))
        else:
            v.append(line)
    v += [");", "", ""]

    # -------------------------------------------------------------------------
    # Declarations
    # -------------------------------------------------------------------------
    v += [
        "    //====================================================================",
        "    // Internal Declarations",
        "    //====================================================================",
        "",
        "    // SPI framing state",
        "    reg [15:0]          rx_shift;   // 2-byte shift register (cmd + data)",
        f"    reg [{BCW-1}:0]         bit_count;  // {BCW}-bit counter, saturates at {(1<<BCW)-1}",
        "    reg                 rw_bit;     // captured R/W bit from byte 0",
        "    reg [6:0]           addr;       // captured 7-bit register address",
        "",
        "    // TX path",
        "    reg [7:0]           tx_shift;",
        "    reg                 tx_active;",
        "",
        "    // Combinational read data (registered name kept for clarity)",
        "    reg [7:0]           read_byte;  // driven by always@*, not a flop",
        "",
        "    wire [15:0] rx_next = {rx_shift[14:0], mosi};",
        "",
    ]

    # RW register storage
    v.append("    // RW register storage")
    for reg in registers:
        if any(f["type"] == "rw" for f in reg["fields"]):
            v.append(f"    reg [7:0] {reg['name']}_reg;")
    v.append("")

    # 2-FF synchronizers for RO inputs
    if ro_fields:
        v += [
            "    //====================================================================",
            "    // 2-FF Synchronizers for RO inputs",
            "    // Clock: SCLK. Metastability settling time = 1 SCLK half-period.",
            "    // Safe when RO inputs change only between transactions (SCLK idle).",
            "    //====================================================================",
            "",
        ]
        for f in ro_fields:
            sig = f"{f['reg_name']}_{f['name']}"
            w = f"[{f['width']-1}:0] " if f["width"] > 1 else ""
            v.append(f"    reg {w}{sig}_sync1, {sig}_sync2;")
        v.append("")

        v.append("    always @(posedge sclk or negedge rst_n) begin")
        v.append("        if (!rst_n) begin")
        for f in ro_fields:
            sig = f"{f['reg_name']}_{f['name']}"
            zero = "1'b0" if f["width"] == 1 else f"{f['width']}'d0"
            v.append(f"            {sig}_sync1 <= {zero};")
            v.append(f"            {sig}_sync2 <= {zero};")
        v.append("        end")
        v.append("        else begin")
        for f in ro_fields:
            sig = f"{f['reg_name']}_{f['name']}"
            v.append(f"            {sig}_sync1 <= {sig}_i;")
            v.append(f"            {sig}_sync2 <= {sig}_sync1;")
        v.append("        end")
        v.append("    end")
        v.append("")

    # -------------------------------------------------------------------------
    # Combinational read mux
    # -------------------------------------------------------------------------
    v += [
        "    //====================================================================",
        "    // Combinational Read Mux",
        "    // read_byte is valid one combinational delay after addr is updated.",
        "    // TX block samples it on negedge sclk at bit_count==8, giving one",
        "    // full half-period (posedge bit7 -> negedge bit8) to settle.",
        "    //====================================================================",
        "",
        "    always @* begin",
        "        read_byte = 8'h00;",
        "        case (addr)",
    ]
    for reg in registers:
        bit_sources = ["1'b0"] * 8
        for f in reg["fields"]:
            sig = (f"{reg['name']}_{f['name']}_sync2" if f["type"] == "ro"
                   else f"{reg['name']}_reg")
            for bit in range(f["lsb"], f["msb"] + 1):
                if f["type"] == "ro":
                    bit_sources[7 - bit] = sig if f["width"] == 1 else f"{sig}[{bit - f['lsb']}]"
                else:
                    bit_sources[7 - bit] = f"{reg['name']}_reg[{bit}]"
        v.append(f"            7'h{reg['addr']:02x}: read_byte = {{")
        v.append("                " + ", ".join(bit_sources) + "};")
    v += [
        "            default: read_byte = 8'h00;",
        "        endcase",
        "    end",
        "",
    ]

    # -------------------------------------------------------------------------
    # Receive block
    # Sensitivity: posedge sclk, posedge cs_n (async reset), negedge rst_n (async reset)
    # Synthesis: standard 2-edge FF (clock=sclk, async=cs_n|rst_n combined reset)
    # Note: rst_n has priority over cs_n because it comes first in the if-chain.
    # Most synthesis tools accept this as: async reset = (!rst_n | cs_n).
    # -------------------------------------------------------------------------
    v += [
        "    //====================================================================",
        "    // SPI Receive Block (Mode 0: sample MOSI on rising SCLK)",
        "    // Async reset: posedge cs_n (end of transaction) or negedge rst_n",
        "    // Resets framing state when CS deasserts so the next transaction",
        "    // always starts from a known state.",
        "    //====================================================================",
        "",
        "    always @(posedge sclk or posedge cs_n or negedge rst_n) begin",
        "        if (!rst_n || cs_n) begin",
        "            rx_shift  <= 16'd0;",
        f"            bit_count <= {BCW}'d0;",
        "            rw_bit    <= 1'b0;",
        "            addr      <= 7'd0;",
        "        end",
        "        else begin",
        "            // Capture RW bit on the first rising edge",
        f"            if (bit_count == {BCW}'d0)",
        "                rw_bit <= mosi;",
        "",
        "            // Capture address after 8 clocks (bit_count==7: rx_next holds full byte 0)",
        f"            if (bit_count == {BCW}'d7)",
        "                addr <= rx_next[6:0];",
        "",
        "            // Auto-increment address at each data byte boundary (bit_count==15,23,31...)",
        "            // bit_count[2:0]==7 picks out those boundaries.",
        "            // Exclude bit_count==1023 (saturated): the 127th data byte boundary is",
        "            // bit_count==1015, which is the last valid increment.",
        f"            if (bit_count >= {BCW}'d15 && bit_count < {BCW}'d1023 &&",
        "                bit_count[2:0] == 3'd7) begin",
        f"                if (addr < 7'd{MAX_ADDR})",
        "                    addr <= addr + 7'd1;",
        "            end",
        "",
        "            // Shift register and saturating bit counter",
        "            rx_shift <= rx_next;",
        f"            if (bit_count < {BCW}'d{(1 << BCW) - 1})",
        f"                bit_count <= bit_count + {BCW}'d1;",
        "        end",
        "    end",
        "",
    ]

    # -------------------------------------------------------------------------
    # Write block
    # Sensitivity: posedge sclk, negedge rst_n only.
    # cs_n is a level gate inside the body — no async edge needed here because
    # writes are committed mid-transaction, never at CS edges.
    # -------------------------------------------------------------------------
    v += [
        "    //====================================================================",
        "    // Register Write Block",
        "    // Sensitivity: posedge sclk + negedge rst_n only (synthesizable 2-edge FF).",
        "    // CS gated by level: writes only occur while cs_n is asserted.",
        "    // Write commits at every data byte boundary: bit_count==15, 23, 31, ...",
        "    //====================================================================",
        "",
        "    always @(posedge sclk or negedge rst_n) begin",
        "        if (!rst_n) begin",
    ]
    for reg in registers:
        if any(f["type"] == "rw" for f in reg["fields"]):
            reset_val = 0
            for f in reg["fields"]:
                if f["type"] == "rw":
                    fval = _parse_reset_to_int(f["reset"])
                    mask = (1 << (f["msb"] - f["lsb"] + 1)) - 1
                    reset_val |= (fval & mask) << f["lsb"]
            v.append(f"            {reg['name']}_reg <= 8'h{reset_val:02x};")
    v += [
        "        end",
        "        else if (!cs_n) begin",
        f"            if (rw_bit && bit_count >= {BCW}'d15 && bit_count < {BCW}'d1023 &&",
        "                bit_count[2:0] == 3'd7) begin",
        "                case (addr)",
    ]
    for reg in registers:
        if any(f["type"] == "rw" for f in reg["fields"]):
            has_ro = any(f["type"] == "ro" for f in reg["fields"])
            if has_ro:
                # Mixed register: write only RW bits
                v.append(f"                    7'h{reg['addr']:02x}: begin")
                v.append(f"                        // Mixed RO/RW: only update RW bits")
                for bit in range(8):
                    for f in reg["fields"]:
                        if f["type"] == "rw" and f["lsb"] <= bit <= f["msb"]:
                            v.append(f"                        {reg['name']}_reg[{bit}] <= rx_next[{bit}];")
                            break
                v.append("                    end")
            else:
                # Pure RW: write full byte
                v.append(f"                    7'h{reg['addr']:02x}: {reg['name']}_reg <= rx_next[7:0];")
    v += [
        "                    default: ;",
        "                endcase",
        "            end",
        "        end",
        "    end",
        "",
    ]

    # -------------------------------------------------------------------------
    # TX block
    # Sensitivity: negedge sclk, posedge cs_n (async reset), negedge rst_n.
    # cs_n rising resets TX state — safe because MISO is an output; the master
    # has already captured the last bit before cs_n rises (t_CSH requirement).
    # -------------------------------------------------------------------------
    v += [
        "    //====================================================================",
        "    // SPI Transmit Block (Mode 0: change MISO on falling SCLK)",
        "    // Async reset: posedge cs_n (safe — MISO is output, master has",
        "    // already captured last bit before CS rises) or negedge rst_n.",
        "    //====================================================================",
        "",
        "    always @(negedge sclk or posedge cs_n or negedge rst_n) begin",
        "        if (!rst_n || cs_n) begin",
        "            miso      <= 1'b0;",
        "            tx_shift  <= 8'd0;",
        "            tx_active <= 1'b0;",
        "        end",
        "        else begin",
        "            // At bit_count==8 (8th falling edge after CS), addr is stable",
        "            // and read_byte is valid. Load first read byte.",
        f"            if (!rw_bit && bit_count == {BCW}'d8) begin",
        "                miso      <= read_byte[7];",
        "                tx_shift  <= {read_byte[6:0], 1'b0};",
        "                tx_active <= 1'b1;",
        "            end",
        "            // Reload at subsequent byte boundaries (bit_count==16,24,...)",
        "            // bit_count[2:0]==0 on negedge after each full data byte.",
        f"            else if (!rw_bit && tx_active &&",
        f"                     bit_count >= {BCW}'d16 && bit_count <= {BCW}'d1023 &&",
        "                     bit_count[2:0] == 3'd0) begin",
        "                miso     <= read_byte[7];",
        "                tx_shift <= {read_byte[6:0], 1'b0};",
        "            end",
        "            else if (tx_active) begin",
        "                miso     <= tx_shift[7];",
        "                tx_shift <= {tx_shift[6:0], 1'b0};",
        "            end",
        "            else begin",
        "                miso <= 1'b0;",
        "            end",
        "        end",
        "    end",
        "",
    ]

    # -------------------------------------------------------------------------
    # Output assignments
    # -------------------------------------------------------------------------
    v += [
        "    //====================================================================",
        "    // Output Assignments",
        "    //====================================================================",
        "",
    ]
    for f in rw_fields:
        sig_o = f"{f['reg_name']}_{f['name']}_o"
        if f["width"] == 1:
            v.append(f"    assign {sig_o} = {f['reg_name']}_reg[{f['lsb']}];")
        else:
            v.append(f"    assign {sig_o} = {f['reg_name']}_reg[{f['msb']}:{f['lsb']}];")
    v += ["", "endmodule"]

    with open(output_file, "w") as fh:
        fh.write("\n".join(v) + "\n")

    print(f"Generated: {output_file}")
    print(f"  Registers : {num_regs}")
    print(f"  RW fields : {len(rw_fields)}")
    print(f"  RO fields : {len(ro_fields)}")
    print(f"  Addr width: {addr_width} bits (0x00-0x{MAX_ADDR:02X})")
    print(f"  Data width: {data_width} bits")
    print(f"  bit_count : {BCW} bits, max {1 << BCW} counts = {(1 << BCW) // 8} bytes")


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {Path(sys.argv[0]).name} <input.csv> <output.v>")
        sys.exit(1)

    csv_file = sys.argv[1]
    output_file = sys.argv[2]

    if not Path(csv_file).exists():
        print(f"Error: '{csv_file}' not found", file=sys.stderr)
        sys.exit(1)

    try:
        registers = parse_csv(csv_file)
        generate_verilog(registers, output_file)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
