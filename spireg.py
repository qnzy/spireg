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
- Maximum transfer: 127 bytes (1 command + 126 data bytes)
- Mode 0: CPOL=0, CPHA=0

CSV format:
- First line must contain (in any order): reg_name,field_name,lsb,msb,type,reset
- Following lines define register fields.
- reg_name can be empty to reuse from the previous line.
- type can be rw (read/write) or ro (read only)
- rw creates output from the regmap, ro generates input to the regmap

Synthesizability notes:
- All always blocks use at most one clock edge plus one async reset.
- A combined reset wire (spi_arst = cs_n | ~rst_n) is used on receive and TX blocks,
  giving a true 2-edge sensitivity list (one clock + one async).
- No 3-edge sensitivity lists are generated.
- 2-FF synchronizers are clocked by SCLK. This limits metastability settling time to
  one SCLK half-period when SCLK is toggling; use with care for very fast SCLK rates.
  If RO inputs change only between transactions this is a non-issue.
"""

import csv
import re
import sys
from datetime import datetime
from pathlib import Path

# Valid Verilog-2005 identifier: starts with letter or underscore, rest alphanumeric/_
_IDENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')

MAX_REGS = 128   # 7-bit address space
ADDR_WIDTH = 7
DATA_WIDTH = 8
BCW = 10         # bit_count width: 0..1023, covers 1 cmd byte + 126 data bytes
MAX_ADDR = 127   # saturate here, no wrap


# =============================================================================
# Helpers
# =============================================================================

def _check_identifier(name: str, context: str) -> None:
    if not _IDENT_RE.match(name):
        raise ValueError(f"'{name}' in {context} is not a valid Verilog identifier")


def _parse_int(s: str) -> int:
    """Parse decimal, hex (0x), or binary (0b) integer string."""
    s = s.strip()
    if not s:
        return 0
    if s.startswith(("0x", "0X")):
        return int(s, 16)
    if s.startswith(("0b", "0B")):
        return int(s, 2)
    return int(s, 10)


def _reg_reset_byte(reg: dict) -> int:
    """Compute the reset value byte for the RW portion of a register."""
    value = 0
    for f in reg["fields"]:
        if f["type"] == "rw":
            mask = (1 << f["width"]) - 1
            value |= (_parse_int(f["reset"]) & mask) << f["lsb"]
    return value


def _zero_literal(width: int) -> str:
    return "1'b0" if width == 1 else f"{width}'d0"


def _port_width(width: int) -> str:
    """Return the port width specifier string (with trailing space for alignment)."""
    return f"[{width - 1}:0] " if width > 1 else "      "


# =============================================================================
# CSV parsing
# =============================================================================

def parse_csv(csv_file: str) -> list:
    """
    Parse CSV and return a list of register dicts:
      {name, addr, fields: [{name, lsb, msb, width, type, reset, reg_name, reg_addr}]}
    """
    registers = []

    with open(csv_file, "r") as fh:
        reader = csv.DictReader(fh)

        required = {"reg_name", "field_name", "lsb", "msb", "type", "reset"}
        if not required.issubset(set(reader.fieldnames or [])):
            raise ValueError(f"CSV must contain columns: {required}")

        current_reg = None
        last_reg_name = None
        seen_reg_names = {}

        for row in reader:
            reg_name, current_reg, last_reg_name = _resolve_reg_name(
                row, current_reg, last_reg_name, seen_reg_names, registers
            )
            field = _parse_field(row, reg_name)
            current_reg["fields"].append(field)

        if current_reg is not None:
            registers.append(current_reg)

    if len(registers) > MAX_REGS:
        raise ValueError(
            f"CSV defines {len(registers)} registers but the 7-bit address space "
            f"supports at most {MAX_REGS}."
        )

    _validate_field_overlaps(registers)
    _assign_addresses(registers)
    return registers


def _resolve_reg_name(row, current_reg, last_reg_name, seen_reg_names, registers):
    """Determine the current register name, creating a new register dict if needed."""
    reg_name = (row.get("reg_name") or "").strip()
    if not reg_name:
        if last_reg_name is None:
            raise ValueError("First row must have a reg_name")
        reg_name = last_reg_name
    else:
        last_reg_name = reg_name

    _check_identifier(reg_name, "reg_name column")

    if current_reg is None or current_reg["name"] != reg_name:
        if reg_name in seen_reg_names:
            print(
                f"Warning: register '{reg_name}' appears non-contiguously in CSV; "
                "it will be assigned a new address (not merged with earlier occurrence).",
                file=sys.stderr,
            )
        if current_reg is not None:
            registers.append(current_reg)
        current_reg = {"name": reg_name, "fields": []}
        seen_reg_names[reg_name] = True

    return reg_name, current_reg, last_reg_name


def _parse_field(row: dict, reg_name: str) -> dict:
    """Parse and validate a single field row."""
    field_name = (row.get("field_name") or "").strip()
    if not field_name:
        raise ValueError(f"field_name is empty in register '{reg_name}'")
    _check_identifier(field_name, f"register '{reg_name}'")

    lsb = int(row["lsb"])
    msb = int(row["msb"])
    field_type = (row.get("type") or "").strip().lower()
    reset_str = (row.get("reset") or "").strip()

    if field_type not in ("rw", "ro"):
        raise ValueError(
            f"Invalid type '{field_type}' for {reg_name}.{field_name}. Must be 'rw' or 'ro'"
        )
    if lsb > msb or msb > 7 or lsb < 0:
        raise ValueError(f"Invalid bit range [{msb}:{lsb}] for {reg_name}.{field_name}")

    width = msb - lsb + 1
    reset_int = _parse_int(reset_str)
    field_max = (1 << width) - 1
    if reset_int > field_max:
        print(
            f"Warning: reset value {reset_str!r} for {reg_name}.{field_name} "
            f"exceeds field width ({width} bits, max {field_max}); value will be truncated.",
            file=sys.stderr,
        )

    return {
        "name": field_name,
        "lsb": lsb,
        "msb": msb,
        "width": width,
        "type": field_type,
        "reset": reset_str,
    }


def _validate_field_overlaps(registers: list) -> None:
    for reg in registers:
        used = [False] * 8
        for f in reg["fields"]:
            for bit in range(f["lsb"], f["msb"] + 1):
                if used[bit]:
                    raise ValueError(
                        f"Bit {bit} in register '{reg['name']}' is used by multiple fields"
                    )
                used[bit] = True


def _assign_addresses(registers: list) -> None:
    """Assign sequential addresses and annotate reg_name/reg_addr onto each field."""
    for idx, reg in enumerate(registers):
        reg["addr"] = idx
        for f in reg["fields"]:
            f["reg_name"] = reg["name"]
            f["reg_addr"] = reg["addr"]


# =============================================================================
# Verilog generation helpers
# =============================================================================

def _build_port_list(ro_fields: list, rw_fields: list) -> list:
    """
    Return list of (kind, line) tuples where kind is 'port', 'comment', or 'blank'.
    """
    items = []

    def comment(s):  items.append(("comment", s))
    def port(s):     items.append(("port",    s))
    def blank():     items.append(("blank",   ""))

    comment("    // SPI interface")
    port(   "    input  wire       sclk")
    port(   "    input  wire       mosi")
    port(   "    output reg        miso")
    port(   "    input  wire       cs_n")
    blank()
    comment("    // System reset (active low, async)")
    port(   "    input  wire       rst_n")

    if ro_fields:
        blank()
        comment("    // Read-only field inputs (from chip internals)")
        for f in ro_fields:
            sig = f"{f['reg_name']}_{f['name']}_i"
            port(f"    input  wire {_port_width(f['width'])}{sig}")

    if rw_fields:
        blank()
        comment("    // Read-write field outputs (to chip internals)")
        for f in rw_fields:
            sig = f"{f['reg_name']}_{f['name']}_o"
            port(f"    output wire {_port_width(f['width'])}{sig}")

    return items


def _emit_module_header(ro_fields: list, rw_fields: list) -> list:
    """Return lines for the module declaration."""
    items = _build_port_list(ro_fields, rw_fields)
    last_port_idx = max(i for i, (k, _) in enumerate(items) if k == "port")

    lines = ["module spi_reg_interface ("]
    for i, (kind, line) in enumerate(items):
        if kind == "port":
            lines.append(line + ("," if i != last_port_idx else ""))
        else:
            lines.append(line)
    lines += [");", "", ""]
    return lines


def _emit_declarations(registers: list, ro_fields: list) -> list:
    lines = [
        "    //====================================================================",
        "    // Internal Declarations",
        "    //====================================================================",
        "",
        "    // SPI framing state",
        "    reg [7:0]           rx_shift;   // 1-byte shift register",
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
        "    wire [7:0] rx_next = {rx_shift[6:0], mosi};",
        "",
        "    // Combined async reset: cs_n deassert OR system reset (true 2-edge FF)",
        "    wire spi_arst = cs_n | ~rst_n;",
        "",
    ]

    lines.append("    // RW register storage")
    for reg in registers:
        if any(f["type"] == "rw" for f in reg["fields"]):
            lines.append(f"    reg [7:0] {reg['name']}_reg;")
    lines.append("")

    if ro_fields:
        lines += [
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
            lines.append(f"    reg {w}{sig}_sync1, {sig}_sync2;")
        lines.append("")

        lines.append("    always @(posedge sclk or negedge rst_n) begin")
        lines.append("        if (!rst_n) begin")
        for f in ro_fields:
            sig = f"{f['reg_name']}_{f['name']}"
            lines.append(f"            {sig}_sync1 <= {_zero_literal(f['width'])};")
            lines.append(f"            {sig}_sync2 <= {_zero_literal(f['width'])};")
        lines.append("        end")
        lines.append("        else begin")
        for f in ro_fields:
            sig = f"{f['reg_name']}_{f['name']}"
            lines.append(f"            {sig}_sync1 <= {sig}_i;")
            lines.append(f"            {sig}_sync2 <= {sig}_sync1;")
        lines.append("        end")
        lines.append("    end")
        lines.append("")

    return lines


def _build_read_mux_segments(reg: dict) -> list:
    """
    For a register, compute the list of Verilog slice/literal segments
    that make up read_byte, MSB-first, for use in a concatenation.
    """
    # Build per-bit owner table
    # RW bits  -> "REGNAME_reg:N"   (N = register bit index)
    # RO 1-bit -> "signame"          (bare, no index)
    # RO N-bit -> "signame:N"        (N = field-relative bit index)
    # Unused   -> "1'b0"
    bit_owner = ["1'b0"] * 8
    for f in reg["fields"]:
        for bit in range(f["lsb"], f["msb"] + 1):
            if f["type"] == "ro":
                sig = f"{reg['name']}_{f['name']}_sync2"
                bit_owner[bit] = sig if f["width"] == 1 else f"{sig}:{bit - f['lsb']}"
            else:
                bit_owner[bit] = f"{reg['name']}_reg:{bit}"

    # Collapse runs of identical base signal into slices (scan MSB-first)
    segments = []
    b = 7
    while b >= 0:
        owner = bit_owner[b]

        if owner == "1'b0":
            run_msb = b
            while b >= 0 and bit_owner[b] == "1'b0":
                b -= 1
            width = run_msb - (b + 1) + 1
            segments.append(f"{width}'b0" if width > 1 else "1'b0")

        elif ":" in owner:
            base, idx_str = owner.rsplit(":", 1)
            top_idx = int(idx_str)
            run_msb = b
            while b >= 0 and ":" in bit_owner[b]:
                cur_base, cur_idx = bit_owner[b].rsplit(":", 1)
                if cur_base != base or int(cur_idx) != top_idx - (run_msb - b):
                    break
                b -= 1
            run_lsb = b + 1
            sig_hi = top_idx
            sig_lo = top_idx - (run_msb - run_lsb)
            segments.append(
                f"{base}[{sig_hi}]" if sig_hi == sig_lo else f"{base}[{sig_hi}:{sig_lo}]"
            )

        else:
            # Bare 1-bit RO signal
            segments.append(owner)
            b -= 1

    return segments


def _emit_read_mux(registers: list) -> list:
    lines = [
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
        segments = _build_read_mux_segments(reg)
        joined = ", ".join(segments)
        prefix = f"            7'h{reg['addr']:02x}: read_byte = {{"
        if len(prefix) + len(joined) + 2 <= 80:
            lines.append(f"{prefix}{joined}}};")
        else:
            lines.append(prefix)
            for i, seg in enumerate(segments):
                comma = "," if i < len(segments) - 1 else ""
                lines.append(f"                {seg}{comma}")
            lines.append("            };")

    lines += [
        "            default: read_byte = 8'h00;",
        "        endcase",
        "    end",
        "",
    ]
    return lines


def _emit_receive_block() -> list:
    return [
        "    //====================================================================",
        "    // SPI Receive Block (Mode 0: sample MOSI on rising SCLK)",
        "    // Async reset: spi_arst (cs_n | ~rst_n) — true 2-edge FF.",
        "    // Resets framing state when CS deasserts so the next transaction",
        "    // always starts from a known state.",
        "    //====================================================================",
        "",
        "    always @(posedge sclk or posedge spi_arst) begin",
        "        if (spi_arst) begin",
        "            rx_shift  <= 8'd0;",
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
        "            // Exclude bit_count==1023 (saturated): last valid increment is at",
        "            // bit_count==1015 (126th data byte boundary).",
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


def _emit_write_block(registers: list) -> list:
    lines = [
        "    //====================================================================",
        "    // Register Write Block",
        "    // Sensitivity: posedge sclk + negedge rst_n only (synthesizable 2-edge FF).",
        "    // CS gated by level: writes only occur while cs_n is asserted.",
        "    // Write commits at every data byte boundary: bit_count==15, 23, 31, ..., 1015",
        "    // (up to 126 data bytes; the 127th is not committed due to counter saturation).",
        "    //====================================================================",
        "",
        "    always @(posedge sclk or negedge rst_n) begin",
        "        if (!rst_n) begin",
    ]

    for reg in registers:
        if any(f["type"] == "rw" for f in reg["fields"]):
            lines.append(f"            {reg['name']}_reg <= 8'h{_reg_reset_byte(reg):02x};")

    lines += [
        "        end",
        "        else if (!cs_n) begin",
        f"            if (rw_bit && bit_count >= {BCW}'d15 && bit_count < {BCW}'d1023 &&",
        "                bit_count[2:0] == 3'd7) begin",
        "                case (addr)",
    ]

    for reg in registers:
        if not any(f["type"] == "rw" for f in reg["fields"]):
            continue
        has_ro = any(f["type"] == "ro" for f in reg["fields"])
        if has_ro:
            lines.append(f"                    7'h{reg['addr']:02x}: begin")
            lines.append( "                        // Mixed RO/RW: only update RW bits")
            for bit in range(8):
                for f in reg["fields"]:
                    if f["type"] == "rw" and f["lsb"] <= bit <= f["msb"]:
                        lines.append(
                            f"                        {reg['name']}_reg[{bit}] <= rx_next[{bit}];"
                        )
                        break
            lines.append("                    end")
        else:
            lines.append(
                f"                    7'h{reg['addr']:02x}: {reg['name']}_reg <= rx_next;"
            )

    lines += [
        "                    default: ;",
        "                endcase",
        "            end",
        "        end",
        "    end",
        "",
    ]
    return lines


def _emit_tx_block() -> list:
    return [
        "    //====================================================================",
        "    // SPI Transmit Block (Mode 0: change MISO on falling SCLK)",
        "    // Async reset: spi_arst (cs_n | ~rst_n) — true 2-edge FF.",
        "    // Safe: MISO is output, master captures last bit before CS rises.",
        "    //====================================================================",
        "",
        "    always @(negedge sclk or posedge spi_arst) begin",
        "        if (spi_arst) begin",
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


def _emit_output_assignments(rw_fields: list) -> list:
    lines = [
        "    //====================================================================",
        "    // Output Assignments",
        "    //====================================================================",
        "",
    ]
    for f in rw_fields:
        sig_o = f"{f['reg_name']}_{f['name']}_o"
        if f["width"] == 1:
            lines.append(f"    assign {sig_o} = {f['reg_name']}_reg[{f['lsb']}];")
        else:
            lines.append(f"    assign {sig_o} = {f['reg_name']}_reg[{f['msb']}:{f['lsb']}];")
    lines += ["", "endmodule"]
    return lines


# =============================================================================
# Top-level Verilog generation
# =============================================================================

def generate_verilog(registers: list, output_file: str) -> None:
    """
    Generate synthesizable SPI register interface.

    Synthesizability strategy:
      - Combined async reset: spi_arst = cs_n | ~rst_n (single gate).
        All blocks needing both resets use this one signal → true 2-edge FF.
      - Receive block:  clock=posedge sclk, async-reset=posedge spi_arst.
                        Resets on CS deassert (end of transaction) or system reset.
      - Write block:    clock=posedge sclk, async-reset=negedge rst_n only.
                        CS gated by level (!cs_n) in body. Standard 2-edge FF.
      - TX block:       clock=negedge sclk, async-reset=posedge spi_arst.
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
    ro_fields = [f for reg in registers for f in reg["fields"] if f["type"] == "ro"]
    rw_fields = [f for reg in registers for f in reg["fields"] if f["type"] == "rw"]

    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    sections = [
        # File header
        [
            "// Auto-generated SPI Register Interface",
            f"// Generated by spireg.py on {timestamp}",
            "// Verilog-2005 compatible, synthesizable (single clock + single async per block)",
            "//",
            "// Protocol: Variable-length transfers",
            "//   Byte 0 : 1 RW bit + 7-bit address",
            "//   Byte 1+: 8-bit data (address auto-increments after each byte)",
            "//   Address saturates at 0x7F (no wrap); up to 126 data bytes per transfer",
            "// Mode 0: CPOL=0, CPHA=0",
            "//",
            "// Reset / CS strategy:",
            "//   rst_n    : async system reset, resets everything",
            "//   spi_arst : combined async reset (cs_n | ~rst_n), used by receive and TX",
            "//              blocks as a single async-reset edge (true 2-edge FF)",
            "//   cs_n     : Write block uses cs_n as level gate only (not in sensitivity list)",
            "//",
            "// MISO: core drives MISO at all times; pad-ring should tri-state when cs_n=1",
            "`timescale 1ns / 1ps",
            "",
        ],
        _emit_module_header(ro_fields, rw_fields),
        _emit_declarations(registers, ro_fields),
        _emit_read_mux(registers),
        _emit_receive_block(),
        _emit_write_block(registers),
        _emit_tx_block(),
        _emit_output_assignments(rw_fields),
    ]

    lines = [line for section in sections for line in section]

    with open(output_file, "w") as fh:
        fh.write("\n".join(lines) + "\n")

    num_regs = len(registers)
    print(f"Generated: {output_file}")
    print(f"  Registers : {num_regs}")
    print(f"  RW fields : {len(rw_fields)}")
    print(f"  RO fields : {len(ro_fields)}")
    print(f"  Addr width: {ADDR_WIDTH} bits (0x00-0x{MAX_ADDR:02X})")
    print(f"  Data width: {DATA_WIDTH} bits")
    print(f"  bit_count : {BCW} bits, max {(1 << BCW) // 8 - 2} data bytes per transfer")


# =============================================================================
# Entry point
# =============================================================================

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {Path(sys.argv[0]).name} <input.csv> <output.v>")
        sys.exit(1)

    csv_file, output_file = sys.argv[1], sys.argv[2]

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
