# Makefile for the generated SPI register interface
#
#   make test    generate RTL, build, run the self-checking testbench
#                (exits non-zero if any check fails -- safe for CI)
#   make stress  same, but sweep several random seeds
#   make waves   re-run with VCD dumping and open gtkwave
#   make lint    Verilator lint (optional; skipped if not installed)
#   make clean

IVERILOG    = iverilog
VVP         = vvp
GTKWAVE     = gtkwave
VERILATOR   = verilator
PYTHON      = python3

VERILOG_STD = -g2005

CSV         = registers.csv
GENERATOR   = ../spireg.py
RTL         = spi_reg_interface.v
TB          = tb_spireg.v
SIM         = tb_spireg.out
LOG         = tb_spireg.log
VCD         = tb_spireg.vcd

SEED       ?= 0x12345678
SEEDS      ?= 1 2 3 4 5 6 7 8

.PHONY: all test stress generate waves lint clean help

all: test

help:
	@echo "make test    - build and run the self-checking testbench"
	@echo "make stress  - run the testbench over several random seeds"
	@echo "make waves   - re-run with VCD dumping and open gtkwave"
	@echo "make lint    - Verilator lint of the generated RTL"
	@echo "make clean   - remove generated files"
	@echo ""
	@echo "make test SEED=0xdeadbeef   - run one specific seed"

# The module name must match the file name to keep Verilator's DECLFILENAME
# check quiet, so the generated RTL is written as spi_reg_interface.v.
generate: $(RTL)

$(RTL): $(CSV) $(GENERATOR)
	$(PYTHON) $(GENERATOR) $(CSV) $(RTL)

$(SIM): $(RTL) $(TB)
	$(IVERILOG) $(VERILOG_STD) -o $(SIM) $(RTL) $(TB)

# The testbench prints "RESULT: PASS" only when error_count is zero. Grepping
# for the positive string (rather than for failures) also catches a simulator
# crash or an early $finish, both of which must count as a failure.
test: $(SIM)
	@$(VVP) $(SIM) +seed=$(SEED) 2>&1 | tee $(LOG)
	@grep -q "RESULT: PASS" $(LOG) || { echo ""; echo "*** TESTS FAILED ***"; exit 1; }
	@echo "*** TESTS PASSED ***"

stress: $(SIM)
	@rc=0; \
	for s in $(SEEDS); do \
	    out=$$($(VVP) $(SIM) +seed=$$s 2>&1); \
	    if echo "$$out" | grep -q "RESULT: PASS"; then \
	        echo "seed $$s: PASS  ($$(echo "$$out" | grep -oE 'checks : [0-9]+'))"; \
	    else \
	        echo "seed $$s: FAIL"; \
	        echo "$$out" | grep '\[FAIL\]' | head -5; \
	        rc=1; \
	    fi; \
	done; \
	exit $$rc

waves: $(SIM)
	$(VVP) $(SIM) +seed=$(SEED) +dump
	@if command -v $(GTKWAVE) >/dev/null 2>&1; then $(GTKWAVE) $(VCD) & \
	 else echo "gtkwave not found; VCD written to $(VCD)"; fi

lint: $(RTL)
	@if command -v $(VERILATOR) >/dev/null 2>&1; then \
	    $(VERILATOR) --lint-only -Wall $(RTL) --top-module spi_reg_interface && \
	    echo "lint clean"; \
	 else echo "verilator not installed; skipping"; fi

clean:
	rm -f $(SIM) $(RTL) $(LOG) $(VCD) *.out *.vcd
