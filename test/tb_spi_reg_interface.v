// Testbench for SPI Register Interface
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
    
    initial begin
        sclk = 0; mosi = 0; cs_n = 1; rst_n = 0;
        // Initialize RO inputs
        STATUS_ready_i = 0; STATUS_error_i = 0; STATUS_busy_i = 0; STATUS_reserved_i = 5'h00;
        DATA_OUT_data_i = 8'h00;
        ID_chip_id_i = 8'hA5;
        
        $dumpfile("tb_spi_reg_interface.vcd");
        $dumpvars(0, tb_spi_reg_interface);
        
        #100 rst_n = 1; #100;
        
        $display("=== SPI Register Interface Test ===\n");
        
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
        
        $display("\n=== Test Complete ===");
        #1000 $finish;
    end

endmodule
