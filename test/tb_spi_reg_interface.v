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
    
    // RW field outputs (based on registers.csv)
    wire       CONTROL_enable_o;
    wire [1:0] CONTROL_mode_o;
    wire [4:0] CONTROL_reserved_o;
    wire [7:0] DATA_IN_data_o;
    wire [3:0] CONFIG_threshold_o;
    wire [2:0] CONFIG_gain_o;
    wire       CONFIG_invert_o;
    
    integer    i;
    reg  [7:0] read_data;
    
    // Bulk transfer data arrays (outside tasks for Verilog-2005 compat)
    reg [7:0] wr_data [0:15];
    reg [7:0] rd_data [0:15];
    reg test_pass;
    
    spi_reg_interface dut (
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n), .rst_n(rst_n),
        // RO inputs
        .STATUS_ready_i(STATUS_ready_i), 
        .STATUS_error_i(STATUS_error_i), 
        .STATUS_busy_i(STATUS_busy_i),
        .STATUS_reserved_i(STATUS_reserved_i),
        .DATA_OUT_data_i(DATA_OUT_data_i),
        .ID_chip_id_i(ID_chip_id_i),
        // RW outputs
        .CONTROL_enable_o(CONTROL_enable_o), 
        .CONTROL_mode_o(CONTROL_mode_o), 
        .CONTROL_reserved_o(CONTROL_reserved_o),
        .DATA_IN_data_o(DATA_IN_data_o),
        .CONFIG_threshold_o(CONFIG_threshold_o), 
        .CONFIG_gain_o(CONFIG_gain_o), 
        .CONFIG_invert_o(CONFIG_invert_o)
    );
    
    // Combine field outputs into register values for checking
    wire [7:0] CONTROL_o = {CONTROL_reserved_o, CONTROL_mode_o, CONTROL_enable_o};
    wire [7:0] DATA_IN_o = DATA_IN_data_o;
    wire [7:0] CONFIG_o = {CONFIG_invert_o, CONFIG_gain_o, CONFIG_threshold_o};
    
    task spi_write(input [6:0] addr, input [7:0] data);
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
    
    task spi_read(input [6:0] addr, output [7:0] data);
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
            // Send address byte with RW=1
            mosi = 1; #50 sclk = 1; #50 sclk = 0;
            for (j = 6; j >= 0; j = j - 1) begin
                mosi = start_addr[j]; #50 sclk = 1; #50 sclk = 0;
            end
            // Send data bytes (address auto-increments)
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
            // Send address byte with RW=0
            mosi = 0; #50 sclk = 1; #50 sclk = 0;
            for (j = 6; j >= 0; j = j - 1) begin
                mosi = start_addr[j]; #50 sclk = 1; #50 sclk = 0;
            end
            // Read data bytes (address auto-increments)
            for (k = 0; k < num_bytes; k = k + 1) begin
                rd_data[k] = 8'h00;
                for (j = 7; j >= 0; j = j - 1) begin
                    #50 sclk = 1; #1 rd_data[k][j] = miso; #49 sclk = 0;
                end
            end
            #50 cs_n = 1; #200;
        end
    endtask
    
    initial begin
        sclk = 0; mosi = 0; cs_n = 1; rst_n = 0;
        // Initialize RO inputs
        STATUS_ready_i = 0; STATUS_error_i = 0; STATUS_busy_i = 0; STATUS_reserved_i = 5'h00;
        DATA_OUT_data_i = 8'h00;
        ID_chip_id_i = 8'hA5;
        
        $dumpfile("tb_spi_reg_interface.vcd");
        $dumpvars(0, tb_spi_reg_interface);
        
        #100 rst_n = 1; #100;
        
        $display("=== SPI Register Interface Test (with Auto-Increment) ===\n");
        
        $display("Test 1: Write CONTROL = 0x07 (enable=1, mode=3)");
        spi_write(7'h00, 8'h07); #200;
        $display("CONTROL_o = 0x%02h %s", CONTROL_o, (CONTROL_o == 8'h07) ? "PASS" : "FAIL");
        $display("  enable=%b, mode=%b", CONTROL_enable_o, CONTROL_mode_o);
        
        $display("\nTest 2: Read CONTROL");
        spi_read(7'h00, read_data); #200;
        $display("Read = 0x%02h %s", read_data, (read_data == 8'h07) ? "PASS" : "FAIL");
        
        $display("\nTest 3: Write CONFIG = 0xB5 (threshold=5, gain=6, invert=1)");
        spi_write(7'h04, 8'hB5); #200;
        $display("CONFIG_o = 0x%02h %s", CONFIG_o, (CONFIG_o == 8'hB5) ? "PASS" : "FAIL");
        $display("  threshold=%h, gain=%h, invert=%b", CONFIG_threshold_o, CONFIG_gain_o, CONFIG_invert_o);
        
        $display("\nTest 4: Write DATA_IN = 0x42");
        spi_write(7'h02, 8'h42); #200;
        $display("DATA_IN_o = 0x%02h %s", DATA_IN_o, (DATA_IN_o == 8'h42) ? "PASS" : "FAIL");
        
        $display("\nTest 5: Read STATUS (RO) - ready=1, error=0, busy=1");
        STATUS_ready_i = 1; STATUS_error_i = 0; STATUS_busy_i = 1; STATUS_reserved_i = 5'h02; #50;
        spi_read(7'h01, read_data); #200;
        $display("Read = 0x%02h (expected 0x15) %s", read_data, (read_data == 8'h15) ? "PASS" : "FAIL");
        
        $display("\nTest 6: Read DATA_OUT (RO)");
        DATA_OUT_data_i = 8'h87; #50;
        spi_read(7'h03, read_data); #200;
        $display("Read = 0x%02h %s", read_data, (read_data == 8'h87) ? "PASS" : "FAIL");
        
        $display("\nTest 7: Read ID (RO)");
        spi_read(7'h05, read_data); #200;
        $display("Read = 0x%02h %s", read_data, (read_data == 8'hA5) ? "PASS" : "FAIL");
        
        $display("\nTest 8: Rapid sequential writes");
        spi_write(7'h00, 8'hAA);
        spi_write(7'h02, 8'h55);
        spi_write(7'h04, 8'hCC); #200;
        $display("CONTROL=%02h DATA_IN=%02h CONFIG=%02h %s", 
                 CONTROL_o, DATA_IN_o, CONFIG_o,
                 (CONTROL_o==8'hAA && DATA_IN_o==8'h55 && CONFIG_o==8'hCC) ? "PASS" : "FAIL");
        
        $display("\n=== BULK TRANSFER TESTS (Auto-Increment) ===");
        
        $display("\nTest 9: Bulk write 3 bytes (CONTROL, STATUS, DATA_IN)");
        wr_data[0] = 8'h11;  // CONTROL
        wr_data[1] = 8'h22;  // STATUS (ignored - RO)
        wr_data[2] = 8'h33;  // DATA_IN
        spi_bulk_write(7'h00, 3); #200;
        $display("After bulk write from addr 0x00:");
        $display("  CONTROL = 0x%02h (expected 0x11) %s", CONTROL_o, (CONTROL_o == 8'h11) ? "PASS" : "FAIL");
        $display("  DATA_IN = 0x%02h (expected 0x33) %s", DATA_IN_o, (DATA_IN_o == 8'h33) ? "PASS" : "FAIL");
        
        $display("\nTest 10: Bulk read 3 bytes (CONTROL, STATUS, DATA_IN)");
        STATUS_ready_i = 1; STATUS_error_i = 1; STATUS_busy_i = 0; STATUS_reserved_i = 5'h0A;
        #50;
        spi_bulk_read(7'h00, 3); #200;
        test_pass = (rd_data[0] == 8'h11) && (rd_data[1] == 8'h53) && (rd_data[2] == 8'h33);
        $display("Bulk read from addr 0x00:");
        $display("  [0] CONTROL  = 0x%02h (expected 0x11) %s", rd_data[0], (rd_data[0] == 8'h11) ? "PASS" : "FAIL");
        $display("  [1] STATUS   = 0x%02h (expected 0x53) %s", rd_data[1], (rd_data[1] == 8'h53) ? "PASS" : "FAIL");
        $display("  [2] DATA_IN  = 0x%02h (expected 0x33) %s", rd_data[2], (rd_data[2] == 8'h33) ? "PASS" : "FAIL");
        $display("  Overall: %s", test_pass ? "PASS" : "FAIL");
        
        $display("\nTest 11: Bulk write 4 bytes starting at DATA_IN");
        wr_data[0] = 8'hAA;  // DATA_IN
        wr_data[1] = 8'hBB;  // DATA_OUT (ignored - RO)
        wr_data[2] = 8'hCC;  // CONFIG
        wr_data[3] = 8'hDD;  // ID (ignored - RO)
        spi_bulk_write(7'h02, 4); #200;
        $display("After bulk write from addr 0x02:");
        $display("  DATA_IN = 0x%02h (expected 0xAA) %s", DATA_IN_o, (DATA_IN_o == 8'hAA) ? "PASS" : "FAIL");
        $display("  CONFIG  = 0x%02h (expected 0xCC) %s", CONFIG_o, (CONFIG_o == 8'hCC) ? "PASS" : "FAIL");
        
        $display("\nTest 12: Bulk read 4 bytes starting at DATA_IN");
        DATA_OUT_data_i = 8'h99;
        #50;
        spi_bulk_read(7'h02, 4); #200;
        test_pass = (rd_data[0] == 8'hAA) && (rd_data[1] == 8'h99) && 
                    (rd_data[2] == 8'hCC) && (rd_data[3] == 8'hA5);
        $display("Bulk read from addr 0x02:");
        $display("  [0] DATA_IN  = 0x%02h (expected 0xAA) %s", rd_data[0], (rd_data[0] == 8'hAA) ? "PASS" : "FAIL");
        $display("  [1] DATA_OUT = 0x%02h (expected 0x99) %s", rd_data[1], (rd_data[1] == 8'h99) ? "PASS" : "FAIL");
        $display("  [2] CONFIG   = 0x%02h (expected 0xCC) %s", rd_data[2], (rd_data[2] == 8'hCC) ? "PASS" : "FAIL");
        $display("  [3] ID       = 0x%02h (expected 0xA5) %s", rd_data[3], (rd_data[3] == 8'hA5) ? "PASS" : "FAIL");
        $display("  Overall: %s", test_pass ? "PASS" : "FAIL");
        
        $display("\nTest 13: Bulk write all 6 registers at once");
        wr_data[0] = 8'h01;  // CONTROL
        wr_data[1] = 8'h02;  // STATUS (ignored)
        wr_data[2] = 8'h03;  // DATA_IN
        wr_data[3] = 8'h04;  // DATA_OUT (ignored)
        wr_data[4] = 8'h05;  // CONFIG
        wr_data[5] = 8'h06;  // ID (ignored)
        spi_bulk_write(7'h00, 6); #200;
        $display("After bulk write of all registers:");
        $display("  CONTROL = 0x%02h (expected 0x01) %s", CONTROL_o, (CONTROL_o == 8'h01) ? "PASS" : "FAIL");
        $display("  DATA_IN = 0x%02h (expected 0x03) %s", DATA_IN_o, (DATA_IN_o == 8'h03) ? "PASS" : "FAIL");
        $display("  CONFIG  = 0x%02h (expected 0x05) %s", CONFIG_o, (CONFIG_o == 8'h05) ? "PASS" : "FAIL");
        
        $display("\nTest 14: Bulk read all 6 registers at once");
        spi_bulk_read(7'h00, 6); #200;
        test_pass = (rd_data[0] == 8'h01) && (rd_data[2] == 8'h03) && 
                    (rd_data[4] == 8'h05) && (rd_data[5] == 8'hA5);
        $display("Bulk read of all registers:");
        $display("  [0] CONTROL  = 0x%02h (expected 0x01) %s", rd_data[0], (rd_data[0] == 8'h01) ? "PASS" : "FAIL");
        $display("  [1] STATUS   = 0x%02h (RO)", rd_data[1]);
        $display("  [2] DATA_IN  = 0x%02h (expected 0x03) %s", rd_data[2], (rd_data[2] == 8'h03) ? "PASS" : "FAIL");
        $display("  [3] DATA_OUT = 0x%02h (RO)", rd_data[3]);
        $display("  [4] CONFIG   = 0x%02h (expected 0x05) %s", rd_data[4], (rd_data[4] == 8'h05) ? "PASS" : "FAIL");
        $display("  [5] ID       = 0x%02h (expected 0xA5) %s", rd_data[5], (rd_data[5] == 8'hA5) ? "PASS" : "FAIL");
        $display("  Overall: %s", test_pass ? "PASS" : "FAIL");
        
        $display("\nTest 15: Address wrap-around (write beyond last register)");
        // Our registers go 0x00-0x05, writing 8 bytes should wrap
        wr_data[0] = 8'hF0;  // 0x00 CONTROL
        wr_data[1] = 8'hF1;  // 0x01 STATUS (ignored)
        wr_data[2] = 8'hF2;  // 0x02 DATA_IN
        wr_data[3] = 8'hF3;  // 0x03 DATA_OUT (ignored)
        wr_data[4] = 8'hF4;  // 0x04 CONFIG
        wr_data[5] = 8'hF5;  // 0x05 ID (ignored)
        wr_data[6] = 8'hF6;  // 0x06 (undefined register)
        wr_data[7] = 8'hF7;  // 0x07 (undefined register)
        spi_bulk_write(7'h00, 8); #200;
        test_pass = (CONTROL_o == 8'hF0) && (DATA_IN_o == 8'hF2) && (CONFIG_o == 8'hF4);
        $display("After 8-byte write starting at 0x00 (testing wrap):");
        $display("  CONTROL = 0x%02h (expected 0xF0) %s", CONTROL_o, (CONTROL_o == 8'hF0) ? "PASS" : "FAIL");
        $display("  DATA_IN = 0x%02h (expected 0xF2) %s", DATA_IN_o, (DATA_IN_o == 8'hF2) ? "PASS" : "FAIL");
        $display("  CONFIG  = 0x%02h (expected 0xF4) %s", CONFIG_o, (CONFIG_o == 8'hF4) ? "PASS" : "FAIL");
        $display("  Overall: %s", test_pass ? "PASS" : "FAIL");
        
        $display("\n=== Test Complete ===");
        #1000 $finish;
    end

endmodule
