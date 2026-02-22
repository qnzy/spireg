// Testbench for SPI Register Interface with Bulk Transfer Support
// Works with generated design (field-level I/O)
`timescale 1ns / 1ps

module tb_spi_reg_interface;

    reg        rst_n;
    reg        sclk;
    reg        mosi;
    wire       miso;
    reg        cs_n;

    // RO field inputs (based on registers.csv)
    reg        STATUS_ready_i, STATUS_error_i, STATUS_busy_i;
    reg  [4:0] STATUS_reserved_i;
    reg  [7:0] DATA_OUT_data_i;
    reg  [7:0] ID_chip_id_i;
    reg  [3:0] MIXED_ro_hi_i;

    // RW field outputs (based on registers.csv)
    wire       CONTROL_enable_o;
    wire [1:0] CONTROL_mode_o;
    wire [4:0] CONTROL_reserved_o;
    wire [7:0] DATA_IN_data_o;
    wire [3:0] CONFIG_threshold_o;
    wire [2:0] CONFIG_gain_o;
    wire       CONFIG_invert_o;
    wire [3:0] MIXED_rw_lo_o;

    integer    i;
    reg  [7:0] read_data;

    // Bulk transfer data arrays (outside tasks for Verilog-2005 compat)
    reg [7:0] wr_data [0:15];
    reg [7:0] rd_data [0:15];
    reg test_pass;

    // Combine field outputs into register values for checking
    wire [7:0] CONTROL_o = {CONTROL_reserved_o, CONTROL_mode_o, CONTROL_enable_o};
    wire [7:0] DATA_IN_o = DATA_IN_data_o;
    wire [7:0] CONFIG_o  = {CONFIG_invert_o, CONFIG_gain_o, CONFIG_threshold_o};

    // Register addresses from CSV
    localparam ADDR_CONTROL  = 7'h00;
    localparam ADDR_STATUS   = 7'h01;
    localparam ADDR_DATA_IN  = 7'h02;
    localparam ADDR_DATA_OUT = 7'h03;
    localparam ADDR_CONFIG   = 7'h04;
    localparam ADDR_ID       = 7'h05;
    localparam ADDR_MIXED    = 7'h06;

    // Reset values from CSV
    localparam RESET_CONTROL = 8'h00;
    // CONFIG: threshold=0x5 [3:0], gain=0x3 [6:4], invert=0 [7] -> 0x35
    localparam RESET_CONFIG  = 8'h35;

    spi_reg_interface dut (
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n), .rst_n(rst_n),
        // RO inputs
        .STATUS_ready_i    (STATUS_ready_i),
        .STATUS_error_i    (STATUS_error_i),
        .STATUS_busy_i     (STATUS_busy_i),
        .STATUS_reserved_i (STATUS_reserved_i),
        .DATA_OUT_data_i   (DATA_OUT_data_i),
        .ID_chip_id_i      (ID_chip_id_i),
        .MIXED_ro_hi_i     (MIXED_ro_hi_i),
        // RW outputs
        .CONTROL_enable_o  (CONTROL_enable_o),
        .CONTROL_mode_o    (CONTROL_mode_o),
        .CONTROL_reserved_o(CONTROL_reserved_o),
        .DATA_IN_data_o    (DATA_IN_data_o),
        .CONFIG_threshold_o(CONFIG_threshold_o),
        .CONFIG_gain_o     (CONFIG_gain_o),
        .CONFIG_invert_o   (CONFIG_invert_o),
        .MIXED_rw_lo_o     (MIXED_rw_lo_o)
    );

    //==========================================================================
    // Tasks
    //==========================================================================

    task spi_write;
        input [6:0] addr;
        input [7:0] data;
        integer j;
        begin
            cs_n = 0; #100;
            mosi = 1; #50 sclk = 1; #50 sclk = 0;  // RW=1
            for (j = 6; j >= 0; j = j - 1) begin
                mosi = addr[j]; #50 sclk = 1; #50 sclk = 0;
            end
            for (j = 7; j >= 0; j = j - 1) begin
                mosi = data[j]; #50 sclk = 1; #50 sclk = 0;
            end
            #50 cs_n = 1; #200;
        end
    endtask

    task spi_read;
        input  [6:0] addr;
        output [7:0] data;
        integer j;
        begin
            data = 8'h00; cs_n = 0; #100;
            mosi = 0; #50 sclk = 1; #50 sclk = 0;  // RW=0
            for (j = 6; j >= 0; j = j - 1) begin
                mosi = addr[j]; #50 sclk = 1; #50 sclk = 0;
            end
            for (j = 7; j >= 0; j = j - 1) begin
                #50 sclk = 1; #1 data[j] = miso; #49 sclk = 0;
            end
            #50 cs_n = 1; #200;
        end
    endtask

    // Bulk write: write N consecutive bytes starting at addr
    // Uses module-level wr_data array
    task spi_bulk_write;
        input [6:0] start_addr;
        input [7:0] num_bytes;
        integer j, k;
        begin
            cs_n = 0; #100;
            mosi = 1; #50 sclk = 1; #50 sclk = 0;  // RW=1
            for (j = 6; j >= 0; j = j - 1) begin
                mosi = start_addr[j]; #50 sclk = 1; #50 sclk = 0;
            end
            for (k = 0; k < num_bytes; k = k + 1) begin
                for (j = 7; j >= 0; j = j - 1) begin
                    mosi = wr_data[k][j]; #50 sclk = 1; #50 sclk = 0;
                end
            end
            #50 cs_n = 1; #200;
        end
    endtask

    // Bulk read: read N consecutive bytes starting at addr
    // Uses module-level rd_data array
    task spi_bulk_read;
        input [6:0] start_addr;
        input [7:0] num_bytes;
        integer j, k;
        begin
            cs_n = 0; #100;
            mosi = 0; #50 sclk = 1; #50 sclk = 0;  // RW=0
            for (j = 6; j >= 0; j = j - 1) begin
                mosi = start_addr[j]; #50 sclk = 1; #50 sclk = 0;
            end
            for (k = 0; k < num_bytes; k = k + 1) begin
                rd_data[k] = 8'h00;
                for (j = 7; j >= 0; j = j - 1) begin
                    #50 sclk = 1; #1 rd_data[k][j] = miso; #49 sclk = 0;
                end
            end
            #50 cs_n = 1; #200;
        end
    endtask

    // Abort after sending num_bits total bits (CS deasserted mid-frame).
    // num_bits counts from the RW bit onward: 1=just RW, 8=full addr byte, 16=addr+data.
    task spi_write_abort;
        input [6:0] addr;
        input [7:0] data;
        input [4:0] num_bits;
        integer j, bits_sent;
        begin
            bits_sent = 0;
            cs_n = 0; #100;
            // RW bit
            if (bits_sent < num_bits) begin
                mosi = 1; #50 sclk = 1; #50 sclk = 0;
                bits_sent = bits_sent + 1;
            end
            // Address bits [6:0]
            for (j = 6; j >= 0; j = j - 1) begin
                if (bits_sent < num_bits) begin
                    mosi = addr[j]; #50 sclk = 1; #50 sclk = 0;
                    bits_sent = bits_sent + 1;
                end
            end
            // Data bits [7:0]
            for (j = 7; j >= 0; j = j - 1) begin
                if (bits_sent < num_bits) begin
                    mosi = data[j]; #50 sclk = 1; #50 sclk = 0;
                    bits_sent = bits_sent + 1;
                end
            end
            // Abort: deassert CS before completing the transaction
            #50 cs_n = 1; #200;
        end
    endtask

    //==========================================================================
    // Stimulus
    //==========================================================================

    initial begin
        sclk = 0; mosi = 0; cs_n = 1; rst_n = 0;
        STATUS_ready_i    = 0;
        STATUS_error_i    = 0;
        STATUS_busy_i     = 0;
        STATUS_reserved_i = 5'h00;
        DATA_OUT_data_i   = 8'h00;
        ID_chip_id_i      = 8'hA5;
        MIXED_ro_hi_i     = 4'h0;

        $dumpfile("tb_spi_reg_interface.vcd");
        $dumpvars(0, tb_spi_reg_interface);

        #100 rst_n = 1; #100;

        $display("=== SPI Register Interface Testbench ===\n");

        //----------------------------------------------------------------------
        // Test 1: Reset values
        // CONTROL reset=0x00, CONFIG reset=0x35, MIXED rw_lo reset=0x3
        //----------------------------------------------------------------------
        $display("Test 1: Reset values");
        spi_read(ADDR_CONTROL, read_data);
        $display("  CONTROL = 0x%02h (expected 0x00) %s",
            read_data, (read_data == RESET_CONTROL) ? "PASS" : "FAIL");
        spi_read(ADDR_CONFIG, read_data);
        $display("  CONFIG  = 0x%02h (expected 0x35) %s",
            read_data, (read_data == RESET_CONFIG) ? "PASS" : "FAIL");
        // MIXED: rw_lo=0x3, ro_hi=0x0 (input) -> 0x03
        spi_read(ADDR_MIXED, read_data);
        $display("  MIXED   = 0x%02h (expected 0x03) %s",
            read_data, (read_data == 8'h03) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 2: Write and read back CONTROL
        //----------------------------------------------------------------------
        $display("\nTest 2: Write CONTROL = 0x07 (enable=1, mode=3)");
        spi_write(ADDR_CONTROL, 8'h07); #200;
        $display("  CONTROL_o = 0x%02h %s",
            CONTROL_o, (CONTROL_o == 8'h07) ? "PASS" : "FAIL");
        spi_read(ADDR_CONTROL, read_data);
        $display("  Readback  = 0x%02h %s",
            read_data, (read_data == 8'h07) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 3: Write and read back CONFIG
        //----------------------------------------------------------------------
        $display("\nTest 3: Write CONFIG = 0xB5 (threshold=5, gain=6, invert=1)");
        spi_write(ADDR_CONFIG, 8'hB5); #200;
        $display("  CONFIG_o  = 0x%02h %s",
            CONFIG_o, (CONFIG_o == 8'hB5) ? "PASS" : "FAIL");
        $display("  threshold=%h gain=%h invert=%b",
            CONFIG_threshold_o, CONFIG_gain_o, CONFIG_invert_o);
        spi_read(ADDR_CONFIG, read_data);
        $display("  Readback  = 0x%02h %s",
            read_data, (read_data == 8'hB5) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 4: Write and read back DATA_IN
        //----------------------------------------------------------------------
        $display("\nTest 4: Write DATA_IN = 0x42");
        spi_write(ADDR_DATA_IN, 8'h42); #200;
        $display("  DATA_IN_o = 0x%02h %s",
            DATA_IN_o, (DATA_IN_o == 8'h42) ? "PASS" : "FAIL");
        spi_read(ADDR_DATA_IN, read_data);
        $display("  Readback  = 0x%02h %s",
            read_data, (read_data == 8'h42) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 5: Read pure RO register STATUS
        // ready=1, error=0, busy=1, reserved=0x02
        // bits: [0]=1 [1]=0 [2]=1 [7:3]=0x02 -> 0b00010_1_0_1 = 0x15
        //----------------------------------------------------------------------
        $display("\nTest 5: Read STATUS (pure RO)");
        STATUS_ready_i = 1; STATUS_error_i = 0; STATUS_busy_i = 1;
        STATUS_reserved_i = 5'h02; #50;
        spi_read(ADDR_STATUS, read_data); #200;
        $display("  Read = 0x%02h (expected 0x15) %s",
            read_data, (read_data == 8'h15) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 6: Read pure RO register DATA_OUT
        //----------------------------------------------------------------------
        $display("\nTest 6: Read DATA_OUT (pure RO)");
        DATA_OUT_data_i = 8'h87; #50;
        spi_read(ADDR_DATA_OUT, read_data); #200;
        $display("  Read = 0x%02h %s",
            read_data, (read_data == 8'h87) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 7: Read pure RO register ID
        //----------------------------------------------------------------------
        $display("\nTest 7: Read ID (pure RO)");
        spi_read(ADDR_ID, read_data); #200;
        $display("  Read = 0x%02h %s",
            read_data, (read_data == 8'hA5) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 8: Mixed RO/RW - write only affects RW bits [3:0]
        // MIXED[3:0] = rw_lo (RW, reset=0x3)
        // MIXED[7:4] = ro_hi (RO, from MIXED_ro_hi_i)
        // Write 0xFF: rw_lo -> 0xF, ro_hi bits in storage unaffected
        // Readback: {ro_hi_input=0xA, rw_lo=0xF} = 0xAF
        //----------------------------------------------------------------------
        $display("\nTest 8: Mixed RO/RW - write only affects RW bits");
        MIXED_ro_hi_i = 4'hA; #50;
        spi_write(ADDR_MIXED, 8'hFF); #200;
        $display("  MIXED_rw_lo_o = 0x%h (expected 0xF) %s",
            MIXED_rw_lo_o, (MIXED_rw_lo_o == 4'hF) ? "PASS" : "FAIL");
        spi_read(ADDR_MIXED, read_data);
        $display("  Readback = 0x%02h (expected 0xAF) %s",
            read_data, (read_data == 8'hAF) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 9: Mixed RO/RW - RO bits track input, RW bits stable
        // Change ro_hi input -> readback changes, rw_lo output unchanged
        //----------------------------------------------------------------------
        $display("\nTest 9: Mixed RO/RW - RO bits track input independently");
        MIXED_ro_hi_i = 4'h5; #50;
        $display("  MIXED_rw_lo_o = 0x%h (expected 0xF, unchanged) %s",
            MIXED_rw_lo_o, (MIXED_rw_lo_o == 4'hF) ? "PASS" : "FAIL");
        spi_read(ADDR_MIXED, read_data);
        // {0x5, 0xF} = 0x5F
        $display("  Readback = 0x%02h (expected 0x5F) %s",
            read_data, (read_data == 8'h5F) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 10: Write to pure RO register is silently ignored
        //----------------------------------------------------------------------
        $display("\nTest 10: Write to pure RO register is ignored");
        STATUS_ready_i = 0; STATUS_error_i = 0; STATUS_busy_i = 0;
        STATUS_reserved_i = 5'h00; #50;
        spi_write(ADDR_STATUS,   8'hFF); #200;
        spi_write(ADDR_DATA_OUT, 8'hFF); #200;
        spi_write(ADDR_ID,       8'hFF); #200;
        spi_read(ADDR_STATUS, read_data);
        $display("  STATUS after write 0xFF = 0x%02h (expected 0x00) %s",
            read_data, (read_data == 8'h00) ? "PASS" : "FAIL");
        // DATA_OUT: still driven by DATA_OUT_data_i = 0x87 from test 6
        spi_read(ADDR_DATA_OUT, read_data);
        $display("  DATA_OUT after write 0xFF = 0x%02h (expected 0x87) %s",
            read_data, (read_data == 8'h87) ? "PASS" : "FAIL");
        spi_read(ADDR_ID, read_data);
        $display("  ID after write 0xFF = 0x%02h (expected 0xA5) %s",
            read_data, (read_data == 8'hA5) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 11: CS abort mid-address-phase - no write should commit
        // Send 4 bits (RW + 3 addr bits) then abort.
        //----------------------------------------------------------------------
        $display("\nTest 11: CS abort mid-address-phase - no write committed");
        spi_write(ADDR_CONTROL, 8'h00); #200;  // known value
        spi_write_abort(ADDR_CONTROL, 8'hFF, 5'd4);
        spi_read(ADDR_CONTROL, read_data);
        $display("  CONTROL after mid-addr abort = 0x%02h (expected 0x00) %s",
            read_data, (read_data == 8'h00) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 12: CS abort mid-data-phase - no write should commit
        // Send full addr byte (8 bits) + 4 data bits, then abort.
        //----------------------------------------------------------------------
        $display("\nTest 12: CS abort mid-data-phase - no write committed");
        spi_write_abort(ADDR_CONTROL, 8'hFF, 5'd12);
        spi_read(ADDR_CONTROL, read_data);
        $display("  CONTROL after mid-data abort = 0x%02h (expected 0x00) %s",
            read_data, (read_data == 8'h00) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 13: FSM recovers cleanly after abort
        //----------------------------------------------------------------------
        $display("\nTest 13: FSM recovers after abort");
        spi_write(ADDR_CONTROL, 8'h55); #200;
        spi_read(ADDR_CONTROL, read_data);
        $display("  CONTROL = 0x%02h (expected 0x55) %s",
            read_data, (read_data == 8'h55) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 14: Rapid sequential writes
        //----------------------------------------------------------------------
        $display("\nTest 14: Rapid sequential writes");
        spi_write(ADDR_CONTROL, 8'hAA);
        spi_write(ADDR_DATA_IN, 8'h55);
        spi_write(ADDR_CONFIG,  8'hCC); #200;
        $display("  CONTROL=%02h DATA_IN=%02h CONFIG=%02h %s",
            CONTROL_o, DATA_IN_o, CONFIG_o,
            (CONTROL_o==8'hAA && DATA_IN_o==8'h55 && CONFIG_o==8'hCC) ? "PASS" : "FAIL");
        spi_read(ADDR_CONTROL, read_data);
        $display("  CONTROL readback = 0x%02h %s",
            read_data, (read_data == 8'hAA) ? "PASS" : "FAIL");
        spi_read(ADDR_DATA_IN, read_data);
        $display("  DATA_IN readback = 0x%02h %s",
            read_data, (read_data == 8'h55) ? "PASS" : "FAIL");
        spi_read(ADDR_CONFIG, read_data);
        $display("  CONFIG  readback = 0x%02h %s",
            read_data, (read_data == 8'hCC) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 15: Bulk write 3 bytes (CONTROL, STATUS[ignored], DATA_IN)
        //----------------------------------------------------------------------
        $display("\n=== BULK TRANSFER TESTS ===");
        $display("\nTest 15: Bulk write 3 bytes");
        wr_data[0] = 8'h11;  // CONTROL
        wr_data[1] = 8'h22;  // STATUS  (ignored - RO)
        wr_data[2] = 8'h33;  // DATA_IN
        spi_bulk_write(ADDR_CONTROL, 3); #200;
        $display("  CONTROL = 0x%02h (expected 0x11) %s",
            CONTROL_o, (CONTROL_o == 8'h11) ? "PASS" : "FAIL");
        $display("  DATA_IN = 0x%02h (expected 0x33) %s",
            DATA_IN_o, (DATA_IN_o == 8'h33) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 16: Bulk read 3 bytes (CONTROL, STATUS, DATA_IN)
        // STATUS: ready=1,error=1,busy=0,reserved=0x0A -> 0b01010_0_1_1 = 0x53
        //----------------------------------------------------------------------
        $display("\nTest 16: Bulk read 3 bytes");
        STATUS_ready_i = 1; STATUS_error_i = 1; STATUS_busy_i = 0;
        STATUS_reserved_i = 5'h0A; #50;
        spi_bulk_read(ADDR_CONTROL, 3); #200;
        test_pass = (rd_data[0] == 8'h11) && (rd_data[1] == 8'h53) && (rd_data[2] == 8'h33);
        $display("  [0] CONTROL = 0x%02h (expected 0x11) %s",
            rd_data[0], (rd_data[0] == 8'h11) ? "PASS" : "FAIL");
        $display("  [1] STATUS  = 0x%02h (expected 0x53) %s",
            rd_data[1], (rd_data[1] == 8'h53) ? "PASS" : "FAIL");
        $display("  [2] DATA_IN = 0x%02h (expected 0x33) %s",
            rd_data[2], (rd_data[2] == 8'h33) ? "PASS" : "FAIL");
        $display("  Overall: %s", test_pass ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 17: Bulk write spanning the mixed RO/RW register
        // Start at DATA_IN (0x02), write 5 bytes:
        //   0x02 DATA_IN  -> 0xF0
        //   0x03 DATA_OUT -> 0xFF (ignored, RO)
        //   0x04 CONFIG   -> 0xCC
        //   0x05 ID       -> 0xDD (ignored, RO)
        //   0x06 MIXED    -> 0x77: rw_lo=0x7, ro_hi from input (ignored in storage)
        //----------------------------------------------------------------------
        $display("\nTest 17: Bulk write spanning mixed RO/RW register");
        MIXED_ro_hi_i = 4'hB; #50;
        wr_data[0] = 8'hF0;  // DATA_IN
        wr_data[1] = 8'hFF;  // DATA_OUT (RO - ignored)
        wr_data[2] = 8'hCC;  // CONFIG
        wr_data[3] = 8'hDD;  // ID       (RO - ignored)
        wr_data[4] = 8'h77;  // MIXED: rw_lo=0x7
        spi_bulk_write(ADDR_DATA_IN, 5); #200;
        $display("  DATA_IN     = 0x%02h (expected 0xF0) %s",
            DATA_IN_o, (DATA_IN_o == 8'hF0) ? "PASS" : "FAIL");
        $display("  CONFIG      = 0x%02h (expected 0xCC) %s",
            CONFIG_o,  (CONFIG_o  == 8'hCC) ? "PASS" : "FAIL");
        $display("  MIXED_rw_lo = 0x%h  (expected 0x7)  %s",
            MIXED_rw_lo_o, (MIXED_rw_lo_o == 4'h7) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 18: Bulk read spanning mixed RO/RW register
        // MIXED readback = {ro_hi_input=0xB, rw_lo=0x7} = 0xB7
        //----------------------------------------------------------------------
        $display("\nTest 18: Bulk read spanning mixed RO/RW register");
        DATA_OUT_data_i = 8'h99; #50;
        spi_bulk_read(ADDR_DATA_IN, 5); #200;
        test_pass = (rd_data[0] == 8'hF0) && (rd_data[1] == 8'h99) &&
                    (rd_data[2] == 8'hCC) && (rd_data[3] == 8'hA5) &&
                    (rd_data[4] == 8'hB7);
        $display("  [0] DATA_IN  = 0x%02h (expected 0xF0) %s",
            rd_data[0], (rd_data[0] == 8'hF0) ? "PASS" : "FAIL");
        $display("  [1] DATA_OUT = 0x%02h (expected 0x99) %s",
            rd_data[1], (rd_data[1] == 8'h99) ? "PASS" : "FAIL");
        $display("  [2] CONFIG   = 0x%02h (expected 0xCC) %s",
            rd_data[2], (rd_data[2] == 8'hCC) ? "PASS" : "FAIL");
        $display("  [3] ID       = 0x%02h (expected 0xA5) %s",
            rd_data[3], (rd_data[3] == 8'hA5) ? "PASS" : "FAIL");
        $display("  [4] MIXED    = 0x%02h (expected 0xB7) %s",
            rd_data[4], (rd_data[4] == 8'hB7) ? "PASS" : "FAIL");
        $display("  Overall: %s", test_pass ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 19: Bulk write all 7 registers
        //----------------------------------------------------------------------
        $display("\nTest 19: Bulk write all 7 registers");
        wr_data[0] = 8'h01;  // CONTROL
        wr_data[1] = 8'h02;  // STATUS   (ignored)
        wr_data[2] = 8'h03;  // DATA_IN
        wr_data[3] = 8'h04;  // DATA_OUT (ignored)
        wr_data[4] = 8'h05;  // CONFIG
        wr_data[5] = 8'h06;  // ID       (ignored)
        wr_data[6] = 8'hE9;  // MIXED: rw_lo=0x9
        spi_bulk_write(ADDR_CONTROL, 7); #200;
        $display("  CONTROL     = 0x%02h (expected 0x01) %s",
            CONTROL_o, (CONTROL_o == 8'h01) ? "PASS" : "FAIL");
        $display("  DATA_IN     = 0x%02h (expected 0x03) %s",
            DATA_IN_o, (DATA_IN_o == 8'h03) ? "PASS" : "FAIL");
        $display("  CONFIG      = 0x%02h (expected 0x05) %s",
            CONFIG_o,  (CONFIG_o  == 8'h05) ? "PASS" : "FAIL");
        $display("  MIXED_rw_lo = 0x%h  (expected 0x9)  %s",
            MIXED_rw_lo_o, (MIXED_rw_lo_o == 4'h9) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 20: Bulk read all 7 registers
        // MIXED: {ro_hi=0xC, rw_lo=0x9} = 0xC9
        //----------------------------------------------------------------------
        $display("\nTest 20: Bulk read all 7 registers");
        STATUS_ready_i = 0; STATUS_error_i = 0; STATUS_busy_i = 0;
        STATUS_reserved_i = 5'h00;
        MIXED_ro_hi_i = 4'hC; #50;
        spi_bulk_read(ADDR_CONTROL, 7); #200;
        test_pass = (rd_data[0] == 8'h01) && (rd_data[1] == 8'h00) &&
                    (rd_data[2] == 8'h03) && (rd_data[3] == 8'h99) &&
                    (rd_data[4] == 8'h05) && (rd_data[5] == 8'hA5) &&
                    (rd_data[6] == 8'hC9);
        $display("  [0] CONTROL  = 0x%02h (expected 0x01) %s",
            rd_data[0], (rd_data[0] == 8'h01) ? "PASS" : "FAIL");
        $display("  [1] STATUS   = 0x%02h (expected 0x00) %s",
            rd_data[1], (rd_data[1] == 8'h00) ? "PASS" : "FAIL");
        $display("  [2] DATA_IN  = 0x%02h (expected 0x03) %s",
            rd_data[2], (rd_data[2] == 8'h03) ? "PASS" : "FAIL");
        $display("  [3] DATA_OUT = 0x%02h (expected 0x99) %s",
            rd_data[3], (rd_data[3] == 8'h99) ? "PASS" : "FAIL");
        $display("  [4] CONFIG   = 0x%02h (expected 0x05) %s",
            rd_data[4], (rd_data[4] == 8'h05) ? "PASS" : "FAIL");
        $display("  [5] ID       = 0x%02h (expected 0xA5) %s",
            rd_data[5], (rd_data[5] == 8'hA5) ? "PASS" : "FAIL");
        $display("  [6] MIXED    = 0x%02h (expected 0xC9) %s",
            rd_data[6], (rd_data[6] == 8'hC9) ? "PASS" : "FAIL");
        $display("  Overall: %s", test_pass ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 21: Address saturation at 0x7F - no wrap to 0x00
        // Start at ID (0x05), write 4 bytes:
        //   0x05 ID    -> 0xEE (ignored, RO)
        //   0x06 MIXED -> 0xEE (rw_lo=0xE)
        //   0x7F       -> 0xEE (undefined, ignored - addr saturated)
        //   0x7F       -> 0xEE (still saturated)
        // CONTROL (0x00) must remain 0x01 from test 19.
        //----------------------------------------------------------------------
        $display("\nTest 21: Address saturation at 0x7F (no wrap)");
        wr_data[0] = 8'hEE;
        wr_data[1] = 8'hEE;
        wr_data[2] = 8'hEE;
        wr_data[3] = 8'hEE;
        spi_bulk_write(ADDR_ID, 4); #200;
        spi_read(ADDR_CONTROL, read_data);
        $display("  CONTROL after saturation write = 0x%02h (expected 0x01, no wrap) %s",
            read_data, (read_data == 8'h01) ? "PASS" : "FAIL");
        $display("  MIXED_rw_lo = 0x%h (expected 0xE) %s",
            MIXED_rw_lo_o, (MIXED_rw_lo_o == 4'hE) ? "PASS" : "FAIL");

        //----------------------------------------------------------------------
        // Test 22: Back-to-back transactions - CS resets framing correctly
        //----------------------------------------------------------------------
        $display("\nTest 22: Back-to-back transactions");
        spi_write(ADDR_CONTROL, 8'h12);
        spi_write(ADDR_DATA_IN, 8'h34);
        spi_write(ADDR_CONFIG,  8'h56);
        test_pass = (CONTROL_o == 8'h12) && (DATA_IN_o == 8'h34) && (CONFIG_o == 8'h56);
        $display("  CONTROL=%02h DATA_IN=%02h CONFIG=%02h %s",
            CONTROL_o, DATA_IN_o, CONFIG_o, test_pass ? "PASS" : "FAIL");

        $display("\n=== Test Complete ===");
        #1000 $finish;
    end

endmodule
