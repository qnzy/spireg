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
- Burst length is unbounded; the address stops at the last implemented
  register and further bytes in the same transfer are discarded (addr_sat):
  writes are not committed and reads return 0x00.
- Mode 0: CPOL=0, CPHA=0

CSV format:
- First line must contain (in any order): reg_name,field_name,lsb,msb,type,reset
- Following lines define register fields.
- reg_name can be empty to reuse from the previous line.
- type can be rw (read/write) or ro (read only)
- rw creates output from the regmap, ro generates input to the regmap
- reset applies to rw fields only and must fit the field width; an ro field
  is driven by its input port, so its reset column must be empty or 0

Synthesizability notes:
- All always blocks use at most one clock edge plus one async reset.
- A combined reset wire (spi_arst = cs_n | ~rst_n) is used on receive and TX blocks,
  giving a true 2-edge sensitivity list (one clock + one async).
- No 3-edge sensitivity lists are generated.
- RO inputs pass through 2-FF synchronizers clocked by SCLK. Both stages are in
  the same posedge block, so the settling budget for the first stage is one full
  SCLK period minus the setup time of the second flop. Compute MTBF at the
  maximum rated SCLK, not a typical one.
- The synchronizers protect each bit independently. They do NOT make a multi-bit
  RO field coherent: if the source changes near an SCLK edge, individual bits may
  resolve differently and the read can return a value that never existed in the
  source domain. Multi-bit RO inputs must be held stable for the duration of a
  transaction (or be gray-coded / handshaked in the source domain).
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
MAX_ADDR = 127   # top of the 7-bit address space


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


def _zero_literal(width: int) -> str:
    return "1'b0" if width == 1 else f"{width}'d0"


def _field_reg(f: dict) -> str:
    """Storage element name for a RW field."""
    return f"{f['reg_name']}_{f['name']}_reg"


def _reset_literal(f: dict) -> str:
    """Width-sized reset literal for a RW field, truncated to the field width."""
    mask = (1 << f["width"]) - 1
    value = _parse_int(f["reset"]) & mask
    if f["width"] == 1:
        return f"1'b{value}"
    return f"{f['width']}'h{value:0{(f['width'] + 3) // 4}x}"


def _bit_slice(name: str, msb: int, lsb: int) -> str:
    """Index or slice expression, collapsing a 1-bit slice to a single index."""
    return f"{name}[{msb}]" if msb == lsb else f"{name}[{msb}:{lsb}]"


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
    _check_generated_names(registers)
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
            raise ValueError(
                f"Register '{reg_name}' appears non-contiguously in the CSV. "
                "All fields of a register must be on consecutive rows (continuation "
                "rows have an empty reg_name). Merge the rows, or rename one of them."
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

    try:
        reset_int = _parse_int(reset_str)
    except ValueError:
        raise ValueError(
            f"Invalid reset value {reset_str!r} for {reg_name}.{field_name}"
        )

    if reset_int < 0:
        raise ValueError(
            f"Negative reset value {reset_str!r} for {reg_name}.{field_name}"
        )

    field_max = (1 << width) - 1
    if reset_int > field_max:
        raise ValueError(
            f"Reset value {reset_str!r} for {reg_name}.{field_name} does not fit the "
            f"field ({width} bits, max 0x{field_max:x})"
        )

    # An 'ro' field is driven by an input port, so its reset column is never
    # used. Silently ignoring a value there would let a CSV that reads as
    # "hardwire this constant" generate an input port instead.
    if field_type == "ro" and reset_int != 0:
        raise ValueError(
            f"Reset value {reset_str!r} on read-only field {reg_name}.{field_name} "
            f"has no effect: 'ro' fields are driven by the "
            f"{reg_name}_{field_name}_i input port, not by stored state. "
            f"Use 0 or leave the column empty."
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
        seen_names = set()
        for f in reg["fields"]:
            if f["name"] in seen_names:
                raise ValueError(
                    f"Duplicate field name '{f['name']}' in register '{reg['name']}'"
                )
            seen_names.add(f["name"])
            for bit in range(f["lsb"], f["msb"] + 1):
                if used[bit]:
                    raise ValueError(
                        f"Bit {bit} in register '{reg['name']}' is used by multiple fields"
                    )
                used[bit] = True


# Verilog-2005 keywords a flattened field name could collide with. The generated
# suffixes (_o/_i/_reg/_sync1/_sync2) make this unlikely, but the check is free.
_VERILOG_KEYWORDS = frozenset("""
always and assign automatic begin buf bufif0 bufif1 case casex casez cell cmos
config deassign default defparam design disable edge else end endcase endconfig
endfunction endgenerate endmodule endprimitive endspecify endtable endtask event
for force forever fork function generate genvar highz0 highz1 if ifnone incdir
include initial inout input instance integer join large liblist library localparam
macromodule medium module nand negedge nmos nor noshowcancelled not notif0 notif1
or output parameter pmos posedge primitive pull0 pull1 pulldown pullup
pulsestyle_ondetect pulsestyle_onevent rcmos real realtime reg release repeat
rnmos rpmos rtran rtranif0 rtranif1 scalared showcancelled signed small specify
specparam strong0 strong1 supply0 supply1 table task time tran tranif0 tranif1
tri tri0 tri1 triand trior trireg unsigned use uwire vectored wait wand weak0
weak1 while wire wor xnor xor
""".split())


def _check_generated_names(registers: list) -> None:
    """Reject CSVs whose flattened names collide in the generated Verilog.

    Field names are flattened to '{reg_name}_{field_name}' plus a suffix, so two
    distinct fields can produce the same identifier -- e.g. register 'A_B' field
    'C' and register 'A' field 'B_C' both give 'A_B_C'. That emits duplicate
    port and reg declarations, which does not compile.

    Every identifier the emitters produce is collected here rather than only the
    port names, so adding a new generated signal later cannot silently reopen
    this hole.
    """
    owners = {}          # identifier -> "REG.FIELD" that produced it
    collisions = []

    for reg in registers:
        for f in reg["fields"]:
            base = f"{reg['name']}_{f['name']}"
            if base.lower() in _VERILOG_KEYWORDS:
                raise ValueError(
                    f"Flattened name '{base}' for {reg['name']}.{f['name']} "
                    "is a Verilog keyword"
                )
            suffixes = ["_o", "_reg"] if f["type"] == "rw" else ["_i", "_sync1", "_sync2"]
            for suffix in suffixes:
                ident = base + suffix
                origin = f"{reg['name']}.{f['name']}"
                if ident in owners and owners[ident] != origin:
                    collisions.append((ident, owners[ident], origin))
                else:
                    owners[ident] = origin

    if collisions:
        detail = "; ".join(
            f"'{ident}' from both {a} and {b}" for ident, a, b in collisions
        )
        raise ValueError(
            f"Flattened field names collide in the generated Verilog: {detail}. "
            "Rename one of the registers or fields."
        )


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
        "    reg [6:0]           rx_shift;   // 7-bit shift register (bit 7 never needed)",
        "    reg [2:0]           bit_idx;    // free-running bit index within the byte",
        "    reg                 cmd_done;   // set at the end of byte 0 (addr captured)",
        "    reg                 rw_bit;     // captured R/W bit from byte 0",
        "    reg [6:0]           addr;       // captured 7-bit register address",
        "    reg                 addr_sat;   // increment ran past the last register",
        "",
        "    // TX path",
        "    reg [7:0]           tx_shift;",
        "    reg                 tx_active;",
        "",
        "    // Combinational read data (registered name kept for clarity)",
        "    reg [7:0]           read_byte;  // driven by always@*, not a flop",
        "",
        "    wire [7:0] rx_next = {rx_shift, mosi};",
        "",
        "    // Combined async reset: cs_n deassert OR system reset (true 2-edge FF)",
        "    wire spi_arst = cs_n | ~rst_n;",
        "",
    ]

    rw_fields = [f for reg in registers for f in reg["fields"] if f["type"] == "rw"]
    if rw_fields:
        lines.append("    // RW field storage (each reg is exactly the field width;")
        lines.append("    // RO bits of a mixed register have no storage at all)")
        for f in rw_fields:
            w = f"[{f['width'] - 1}:0] " if f["width"] > 1 else ""
            lines.append(f"    reg {w}{_field_reg(f)};")
        lines.append("")

    if ro_fields:
        lines += [
            "    //====================================================================",
            "    // 2-FF Synchronizers for RO inputs",
            "    // Clock: SCLK. Both stages sit in the same posedge block, so the",
            "    // first stage has one full SCLK period (minus the second flop's",
            "    // setup time) to settle. Evaluate MTBF at the maximum rated SCLK.",
            "    //",
            "    // These synchronize each bit independently and do NOT guarantee",
            "    // coherency across a multi-bit RO field: bits may resolve",
            "    // differently and a read can return a value that never existed in",
            "    // the source domain. Multi-bit RO inputs must be held stable for",
            "    // the duration of a transaction; holding them stable between",
            "    // transactions satisfies this trivially.",
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
    # 1-bit field -> "signame"      (bare, no index)
    # N-bit field -> "signame:N"     (N = field-relative bit index)
    # Unused bit  -> "1'b0"
    bit_owner = ["1'b0"] * 8
    for f in reg["fields"]:
        for bit in range(f["lsb"], f["msb"] + 1):
            sig = (
                f"{reg['name']}_{f['name']}_sync2"
                if f["type"] == "ro"
                else _field_reg(f)
            )
            bit_owner[bit] = sig if f["width"] == 1 else f"{sig}:{bit - f['lsb']}"

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
        "    // TX block samples it on the negedge that starts each data byte,",
        "    // giving one full SCLK half-period for addr -> read_byte to settle.",
        "    // Gated by addr_sat so a burst that runs past the last register reads",
        "    // back 0x00 rather than repeating the last register's contents.",
        "    //====================================================================",
        "",
        "    always @* begin",
        "        read_byte = 8'h00;",
        "        if (!addr_sat) begin",
        "            case (addr)",
    ]

    for reg in registers:
        segments = _build_read_mux_segments(reg)
        joined = ", ".join(segments)
        prefix = f"                7'h{reg['addr']:02x}: read_byte = {{"
        if len(prefix) + len(joined) + 2 <= 80:
            lines.append(f"{prefix}{joined}}};")
        else:
            lines.append(prefix)
            for i, seg in enumerate(segments):
                comma = "," if i < len(segments) - 1 else ""
                lines.append(f"                    {seg}{comma}")
            lines.append("                };")

    lines += [
        "                default: read_byte = 8'h00;",
        "            endcase",
        "        end",
        "    end",
        "",
    ]
    return lines


def _emit_receive_block(last_addr: int) -> list:
    return [
        "    //====================================================================",
        "    // SPI Receive Block (Mode 0: sample MOSI on rising SCLK)",
        "    // Async reset: spi_arst (cs_n | ~rst_n) - true 2-edge FF.",
        "    //====================================================================",
        "",
        "    always @(posedge sclk or posedge spi_arst) begin",
        "        if (spi_arst) begin",
        "            rx_shift <= 7'd0;",
        "            bit_idx  <= 3'd0;",
        "            cmd_done <= 1'b0;",
        "            rw_bit   <= 1'b0;",
        "            addr     <= 7'd0;",
        "            addr_sat <= 1'b0;",
        "        end",
        "        else begin",
        "            // First bit of byte 0 is the R/W bit",
        "            if (!cmd_done && bit_idx == 3'd0)",
        "                rw_bit <= mosi;",
        "",
        "            if (bit_idx == 3'd7) begin",
        "                cmd_done <= 1'b1;",
        "                if (!cmd_done)",
        "                    addr <= rx_next[6:0];     // end of command byte",
        f"                else if (addr >= 7'h{last_addr:02x})",
        "                    addr_sat <= 1'b1;          // at or past the last register;",
        "                                               // >= (not ==) so a burst starting",
        "                                               // above the map cannot step over",
        "                                               // the check and wrap to 0x00",
        "                else",
        "                    addr <= addr + 7'd1;",
        "            end",
        "",
        "            rx_shift <= rx_next[6:0];",
        "            bit_idx  <= bit_idx + 3'd1;",
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
        "    // Write commits at every data byte boundary (bit_idx==7, cmd_done set).",
        "    // addr_sat blocks commits once the address has run past the last register,",
        "    // so an overlong burst is discarded instead of repeatedly hitting the top.",
        "    // RO bits of a mixed register have no storage, so no write masking needed.",
        "    //====================================================================",
        "",
        "    always @(posedge sclk or negedge rst_n) begin",
        "        if (!rst_n) begin",
    ]

    rw_fields = [f for reg in registers for f in reg["fields"] if f["type"] == "rw"]
    pad = max((len(_field_reg(f)) for f in rw_fields), default=0)
    for f in rw_fields:
        lines.append(f"            {_field_reg(f):<{pad}} <= {_reset_literal(f)};")

    lines += [
        "        end",
        "        else if (!cs_n) begin",
        "            if (rw_bit && cmd_done && bit_idx == 3'd7 && !addr_sat) begin",
        "                case (addr)",
    ]

    for reg in registers:
        writable = [f for f in reg["fields"] if f["type"] == "rw"]
        if not writable:
            continue
        if len(writable) == 1:
            f = writable[0]
            lines.append(
                f"                    7'h{reg['addr']:02x}: {_field_reg(f)} <= "
                f"{_bit_slice('rx_next', f['msb'], f['lsb'])};"
            )
        else:
            pad = max(len(_field_reg(f)) for f in writable)
            lines.append(f"                    7'h{reg['addr']:02x}: begin")
            for f in writable:
                lines.append(
                    f"                        {_field_reg(f):<{pad}} <= "
                    f"{_bit_slice('rx_next', f['msb'], f['lsb'])};"
                )
            lines.append("                    end")

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
        "    // Loads a fresh read_byte on the falling edge that starts each data",
        "    // byte (bit_idx==0 with the command byte already consumed).",
        "    //====================================================================",
        "",
        "    always @(negedge sclk or posedge spi_arst) begin",
        "        if (spi_arst) begin",
        "            miso      <= 1'b0;",
        "            tx_shift  <= 8'd0;",
        "            tx_active <= 1'b0;",
        "        end",
        "        else if (!rw_bit && cmd_done && bit_idx == 3'd0) begin",
        "            miso      <= read_byte[7];",
        "            tx_shift  <= {read_byte[6:0], 1'b0};",
        "            tx_active <= 1'b1;",
        "        end",
        "        else if (tx_active) begin",
        "            miso     <= tx_shift[7];",
        "            tx_shift <= {tx_shift[6:0], 1'b0};",
        "        end",
        "        else begin",
        "            miso <= 1'b0;",
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
    pad = max((len(f"{f['reg_name']}_{f['name']}_o") for f in rw_fields), default=0)
    for f in rw_fields:
        sig_o = f"{f['reg_name']}_{f['name']}_o"
        lines.append(f"    assign {sig_o:<{pad}} = {_field_reg(f)};")
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
        Both stages are in one posedge block: the first stage gets a full SCLK
        period to settle, not a half period. Per-bit only; see the coherency
        note in the module header for multi-bit RO fields.
      No 3-edge sensitivity lists anywhere.

    Read path timing:
      addr is captured/incremented on posedge sclk at bit_idx==7.
      read_byte is combinational from addr.
      TX block samples read_byte on the following negedge (bit_idx==0).
      This gives one full SCLK half-period for addr->read_byte to settle.
      NOTE: this is a half-cycle path through the whole read mux; it is the
      critical path and it scales with the number of registers.
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
            "//   Burst length unbounded; past the last register writes are dropped and",
            "//   reads return 0x00 (addr_sat)",
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
        _emit_receive_block(registers[-1]["addr"]),
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
    print(f"  Burst     : unbounded; writes stop past 0x{registers[-1]['addr']:02X}")


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
