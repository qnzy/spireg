**spireg**

This is a small python script that generates an integrated SPI slave
and register map in Verilog. The register map is generated based on a CSV file.
The SPI and the registers are clocked by SCLK only; no system clock is needed.

See the script for basic documentation or the test case in the *test*
folder (`make test`, `make stress`, `make lint`, `make waves`).

Requirements and limitations (details in the script's docstring):

- CS framing is mandatory; `cs_n` tied low is not supported. A frame
  interrupted by `rst_n` is ignored until `cs_n` deasserts and reasserts.
- No frame-length check or CRC: SCLK must be glitch-free. Verify critical
  writes by reading them back.
- Registers are written one byte at a time, so values spread over several
  registers pass through intermediate states.
- RW outputs and RO inputs cross into/out of the SCLK domain; multi-bit
  fields must be handled with that in mind.
- Only `rw` and `ro` field types.

This script has been created using an LLM.

Public domain / CC0.
