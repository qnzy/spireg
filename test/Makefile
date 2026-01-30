# Makefile for SPI Register Interface
# Supports Icarus Verilog simulation

# Tools
IVERILOG = iverilog
VVP = vvp
GTKWAVE = gtkwave
PYTHON = python3

# Verilog standard
VERILOG_STD = -g2005

# Source files
CSV_FILE = registers.csv
GENERATOR = ../spireg.py
GENERATED_RTL = spi_reg_interface_generated.v
TB = tb_spi_reg_interface.v

# Output files
GEN_SIM = spi_gen_sim.out
VCD_FILE = tb_spi_reg_interface.vcd

# Phony targets
.PHONY: all test_gen generate clean waves help

# Default target - test generated design
all: test_gen

# Help target
help:
	@echo "SPI Register Interface Makefile"
	@echo "================================"
	@echo ""
	@echo "Design Options:"
	@echo "  REFERENCE - Hand-written spi_reg_interface.v (for comparison)"
	@echo "  GENERATED - Auto-generated from CSV by gen_regfile.py"
	@echo ""
	@echo "Targets:"
	@echo "  all        - Generate and test design from CSV (default)"
	@echo "  test_gen   - Test generated design"
	@echo "  generate   - Generate Verilog from CSV"
	@echo "  waves      - Open waveform viewer (GTKWave)"
	@echo "  clean      - Remove generated files"
	@echo "  help       - Show this help message"
	@echo ""
	@echo "Examples:"
	@echo "  make              # Generate from CSV and test"
	@echo "  make generate     # Only generate Verilog"
	@echo ""

# Generate Verilog from CSV
generate: $(GENERATED_RTL)

$(GENERATED_RTL): $(CSV_FILE) $(GENERATOR)
	@echo "Generating SPI register interface from $(CSV_FILE)..."
	$(PYTHON) $(GENERATOR) $(CSV_FILE) $(GENERATED_RTL)
	@echo ""

# Test generated design
test_gen: $(GEN_SIM)
	@echo "=========================================="
	@echo "Testing GENERATED design"
	@echo "=========================================="
	@echo ""
	$(VVP) $(GEN_SIM)
	@echo ""
	@echo "Simulation complete. Waveform: $(VCD_FILE)"

$(GEN_SIM): $(GENERATED_RTL) $(TB)
	@echo "Compiling generated design..."
	$(IVERILOG) $(VERILOG_STD) -o $(GEN_SIM) $(GENERATED_RTL) $(TB)


# Open waveform viewer
waves:
	@echo "Opening waveform viewer..."
	@if [ -f "$(VCD_FILE)" ]; then \
		if command -v $(GTKWAVE) >/dev/null 2>&1; then \
			$(GTKWAVE) $(VCD_FILE) & \
		else \
			echo "GTKWave not found. VCD file: $(VCD_FILE)"; \
		fi \
	else \
		echo "No VCD file found. Run 'make' first."; \
	fi

# Clean generated files
clean:
	@echo "Cleaning generated files..."
	rm -f $(GEN_SIM)
	rm -f $(GENERATED_RTL)
	rm -f $(VCD_FILE)
	rm -f *.vcd
	@echo "Clean complete."

# Check if tools are available
check-tools:
	@echo "Checking for required tools..."
	@command -v $(IVERILOG) >/dev/null 2>&1 || { echo "ERROR: Icarus Verilog not found."; exit 1; }
	@command -v $(VVP) >/dev/null 2>&1 || { echo "ERROR: VVP not found."; exit 1; }
	@command -v $(PYTHON) >/dev/null 2>&1 || { echo "ERROR: Python3 not found."; exit 1; }
	@echo "All required tools found."
	@echo ""
	@command -v $(GTKWAVE) >/dev/null 2>&1 && echo "Optional: GTKWave FOUND" || echo "Optional: GTKWave NOT FOUND"
	@echo ""
