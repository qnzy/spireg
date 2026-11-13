//=============================================================================
// tb_spireg.v -- self-checking testbench for the generated SPI register
//                interface (spireg.py + registers.csv).
//
// Verilog-2005. No SystemVerilog constructs.
//
// Structure:
//   1. Behavioural SPI mode-0 master (bit-banged tasks).
//   2. A reference model of the protocol, independent of the RTL:
//        - m_store[]  : the RW storage the DUT should hold
//        - rw_mask()  : which bits of each address are writable
//        - ro_mask()  : which bits are read-only (driven from TB inputs)
//        - the address progression + addr_sat saturation rule
//   3. Directed tests for the edge cases that have historically been wrong.
//   4. A randomised stress loop checked against the model every transaction.
//
// Both DUT paths are checked independently:
//   - the WRITE path via the RW output ports (does not use the read mux)
//   - the READ path via MISO data compared against the model
//
// Exit: prints "RESULT: PASS" only if error_count==0. The Makefile greps for
// that string, so an early $finish or a simulator crash also counts as a
// failure. ($fatal would give a non-zero exit directly but is SystemVerilog.)
//=============================================================================

`timescale 1ns / 1ps

module tb_spireg;

    //-------------------------------------------------------------------------
    // Map description -- must match registers.csv
    //-------------------------------------------------------------------------
    localparam [6:0] LAST_ADDR = 7'h06;

    localparam [6:0] A_CONTROL  = 7'h00;   // rw  [7:0]
    localparam [6:0] A_STATUS   = 7'h01;   // ro  [7:0]
    localparam [6:0] A_DATA_IN  = 7'h02;   // rw  [7:0]
    localparam [6:0] A_DATA_OUT = 7'h03;   // ro  [7:0]
    localparam [6:0] A_CONFIG   = 7'h04;   // rw  [7:0]
    localparam [6:0] A_ID       = 7'h05;   // ro  [7:0]
    localparam [6:0] A_MIXED    = 7'h06;   // rw  [3:0] / ro [7:4]

    // Reset values of the RW storage (from the CSV reset column)
    localparam [7:0] RST_CONTROL = 8'h00;
    localparam [7:0] RST_DATA_IN = 8'h00;
    localparam [7:0] RST_CONFIG  = 8'h35;  // gain=3, threshold=5
    localparam [7:0] RST_MIXED   = 8'h03;  // rw_lo=3

    localparam SCLK_HALF = 50;             // ns -> 10 MHz
    localparam T_CSS     = 100;            // CS setup / hold guard band

    localparam NUM_RANDOM = 400;           // stress iterations

    //-------------------------------------------------------------------------
    // DUT connections
    //-------------------------------------------------------------------------
    reg  sclk, mosi, cs_n, rst_n;
    wire miso;

    // RO field drivers (TB owns these; changed only while cs_n is high)
    reg        ro_ready, ro_error, ro_busy;
    reg  [4:0] ro_status_res;
    reg  [7:0] ro_data_out;
    reg  [7:0] ro_id;
    reg  [3:0] ro_mixed_hi;

    // RW field outputs
    wire       CONTROL_enable_o;
    wire [1:0] CONTROL_mode_o;
    wire [4:0] CONTROL_reserved_o;
    wire [7:0] DATA_IN_data_o;
    wire [3:0] CONFIG_threshold_o;
    wire [2:0] CONFIG_gain_o;
    wire       CONFIG_invert_o;
    wire [3:0] MIXED_rw_lo_o;

    spi_reg_interface dut (
        .sclk               (sclk),
        .mosi               (mosi),
        .miso               (miso),
        .cs_n               (cs_n),
        .rst_n              (rst_n),
        .STATUS_ready_i     (ro_ready),
        .STATUS_error_i     (ro_error),
        .STATUS_busy_i      (ro_busy),
        .STATUS_reserved_i  (ro_status_res),
        .DATA_OUT_data_i    (ro_data_out),
        .ID_chip_id_i       (ro_id),
        .MIXED_ro_hi_i      (ro_mixed_hi),
        .CONTROL_enable_o   (CONTROL_enable_o),
        .CONTROL_mode_o     (CONTROL_mode_o),
        .CONTROL_reserved_o (CONTROL_reserved_o),
        .DATA_IN_data_o     (DATA_IN_data_o),
        .CONFIG_threshold_o (CONFIG_threshold_o),
        .CONFIG_gain_o      (CONFIG_gain_o),
        .CONFIG_invert_o    (CONFIG_invert_o),
        .MIXED_rw_lo_o      (MIXED_rw_lo_o)
    );

    //-------------------------------------------------------------------------
    // Scoreboard
    //-------------------------------------------------------------------------
    integer error_count;
    integer check_count;
    integer seed;

    reg [7:0] txb  [0:255];   // bytes to send
    reg [7:0] rxb  [0:255];   // bytes received from MISO
    reg [7:0] expb [0:255];   // bytes the model says we should receive

    reg [7:0] m_store [0:127];   // model of the DUT's RW storage

    task chk;
        input [511:0] msg;
        input [7:0]   got;
        input [7:0]   exp;
        begin
            check_count = check_count + 1;
            if (got !== exp) begin
                error_count = error_count + 1;
                $display("  [FAIL] %0s: got 0x%02h expected 0x%02h  (t=%0t)",
                         msg, got, exp, $time);
            end
        end
    endtask

    task banner;
        input [511:0] msg;
        begin
            $display("");
            $display("--- %0s", msg);
        end
    endtask

    //-------------------------------------------------------------------------
    // Reference model
    //-------------------------------------------------------------------------

    // Bits that are writable at a given address (0 for unimplemented addresses)
    function [7:0] rw_mask;
        input [6:0] a;
        begin
            case (a)
                A_CONTROL : rw_mask = 8'hFF;
                A_DATA_IN : rw_mask = 8'hFF;
                A_CONFIG  : rw_mask = 8'hFF;
                A_MIXED   : rw_mask = 8'h0F;
                default   : rw_mask = 8'h00;
            endcase
        end
    endfunction

    // Bits sourced from the RO inputs at a given address
    function [7:0] ro_mask;
        input [6:0] a;
        begin
            case (a)
                A_STATUS  : ro_mask = 8'hFF;
                A_DATA_OUT: ro_mask = 8'hFF;
                A_ID      : ro_mask = 8'hFF;
                A_MIXED   : ro_mask = 8'hF0;
                default   : ro_mask = 8'h00;
            endcase
        end
    endfunction

    // Current value of the RO bits at a given address
    function [7:0] ro_value;
        input [6:0] a;
        begin
            case (a)
                A_STATUS  : ro_value = {ro_status_res, ro_busy, ro_error, ro_ready};
                A_DATA_OUT: ro_value = ro_data_out;
                A_ID      : ro_value = ro_id;
                A_MIXED   : ro_value = {ro_mixed_hi, 4'h0};
                default   : ro_value = 8'h00;
            endcase
        end
    endfunction

    // What a read of this address must return
    function [7:0] exp_read;
        input [6:0] a;
        begin
            if (a > LAST_ADDR)
                exp_read = 8'h00;                       // unimplemented
            else
                exp_read = (m_store[a] & rw_mask(a)) |
                           (ro_value(a) & ro_mask(a));
        end
    endfunction

    // Apply a write burst to the model, mirroring the RTL address rule:
    //   byte k lands at the current address; afterwards the address either
    //   increments or, once it is at/past LAST_ADDR, saturates and every
    //   further byte in the transfer is discarded.
    task model_write;
        input [6:0]  a;
        input integer n;
        integer k;
        reg [6:0] cur;
        reg       sat;
        begin
            cur = a;
            sat = 1'b0;
            for (k = 0; k < n; k = k + 1) begin
                if (!sat) begin
                    if (cur <= LAST_ADDR)
                        m_store[cur] = (m_store[cur] & ~rw_mask(cur)) |
                                       (txb[k]       &  rw_mask(cur));
                    if (cur >= LAST_ADDR) sat = 1'b1;
                    else                  cur = cur + 7'd1;
                end
            end
        end
    endtask

    // Predict the bytes a read burst must return
    task model_read;
        input [6:0]  a;
        input integer n;
        integer k;
        reg [6:0] cur;
        reg       sat;
        begin
            cur = a;
            sat = 1'b0;
            for (k = 0; k < n; k = k + 1) begin
                if (!sat) begin
                    expb[k] = exp_read(cur);
                    if (cur >= LAST_ADDR) sat = 1'b1;
                    else                  cur = cur + 7'd1;
                end
                else expb[k] = 8'h00;
            end
        end
    endtask

    task model_reset;
        integer k;
        begin
            for (k = 0; k < 128; k = k + 1) m_store[k] = 8'h00;
            m_store[A_CONTROL] = RST_CONTROL;
            m_store[A_DATA_IN] = RST_DATA_IN;
            m_store[A_CONFIG]  = RST_CONFIG;
            m_store[A_MIXED]   = RST_MIXED;
        end
    endtask

    //-------------------------------------------------------------------------
    // Behavioural SPI mode-0 master
    //-------------------------------------------------------------------------

    task sclk_pulse;                     // one full SCLK period, sample MISO
        output sampled;
        begin
            #SCLK_HALF sclk = 1'b1;
            #1         sampled = miso;   // master samples on the rising edge
            #(SCLK_HALF-1) sclk = 1'b0;
        end
    endtask

    // Full transfer. rw=1 write (txb[] sent), rw=0 read (rxb[] captured).
    task spi_xfer;
        input        rw;
        input [6:0]  a;
        input integer n;
        integer k, j;
        reg     s;
        begin
            cs_n = 1'b0;
            #T_CSS;
            mosi = rw;                   // command byte: RW then addr[6:0]
            sclk_pulse(s);
            for (j = 6; j >= 0; j = j - 1) begin
                mosi = a[j];
                sclk_pulse(s);
            end
            for (k = 0; k < n; k = k + 1) begin
                rxb[k] = 8'h00;
                for (j = 7; j >= 0; j = j - 1) begin
                    mosi = rw ? txb[k][j] : 1'b0;
                    sclk_pulse(s);
                    rxb[k][j] = s;
                end
            end
            #SCLK_HALF;
            cs_n = 1'b1;
            #T_CSS;
        end
    endtask

    // Send one byte inside an already-open frame (cs_n low), capture MISO.
    task spi_byte;
        input  [7:0] b;
        output [7:0] r;
        integer j;
        reg     s;
        begin
            for (j = 7; j >= 0; j = j - 1) begin
                mosi = b[j];
                sclk_pulse(s);
                r[j] = s;
            end
        end
    endtask

    // Transfer aborted after exactly nbits clocks (counted from the RW bit).
    task spi_abort;
        input        rw;
        input [6:0]  a;
        input [7:0]  data;
        input integer nbits;
        integer j, sent;
        reg     s;
        begin
            sent = 0;
            cs_n = 1'b0;
            #T_CSS;
            if (sent < nbits) begin mosi = rw; sclk_pulse(s); sent = sent + 1; end
            for (j = 6; j >= 0; j = j - 1)
                if (sent < nbits) begin mosi = a[j]; sclk_pulse(s); sent = sent + 1; end
            for (j = 7; j >= 0; j = j - 1)
                if (sent < nbits) begin mosi = data[j]; sclk_pulse(s); sent = sent + 1; end
            #SCLK_HALF;
            cs_n = 1'b1;
            #T_CSS;
        end
    endtask

    task sclk_idle_burst;                // toggle SCLK while deselected
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                #SCLK_HALF sclk = 1'b1;
                #SCLK_HALF sclk = 1'b0;
            end
        end
    endtask

    task do_reset;
        begin
            rst_n = 1'b0;
            #(4*SCLK_HALF);
            rst_n = 1'b1;
            #(2*SCLK_HALF);
            model_reset;
        end
    endtask

    //-------------------------------------------------------------------------
    // Checkers
    //-------------------------------------------------------------------------

    // Check the WRITE path only, via the RW output ports. Does not touch the
    // read mux, so a broken read path cannot mask a broken write path.
    task check_outputs;
        input [511:0] msg;
        begin
            chk({msg, " CONTROL"},
                {CONTROL_reserved_o, CONTROL_mode_o, CONTROL_enable_o},
                m_store[A_CONTROL]);
            chk({msg, " DATA_IN"}, DATA_IN_data_o, m_store[A_DATA_IN]);
            chk({msg, " CONFIG"},
                {CONFIG_invert_o, CONFIG_gain_o, CONFIG_threshold_o},
                m_store[A_CONFIG]);
            chk({msg, " MIXED"},
                {4'h0, MIXED_rw_lo_o}, m_store[A_MIXED] & 8'h0F);
        end
    endtask

    // Check the READ path: read every implemented register and compare.
    task check_readback;
        input [511:0] msg;
        integer k;
        begin
            model_read(7'h00, LAST_ADDR + 1);
            spi_xfer(1'b0, 7'h00, LAST_ADDR + 1);
            for (k = 0; k <= LAST_ADDR; k = k + 1)
                chk({msg, " readback"}, rxb[k], expb[k]);
        end
    endtask

    task compare_rx;                     // compare a read burst against expb[]
        input [511:0] msg;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                chk(msg, rxb[k], expb[k]);
        end
    endtask

    task randomise_ro;                   // only legal while cs_n is high
        begin
            ro_ready      = $random(seed);
            ro_error      = $random(seed);
            ro_busy       = $random(seed);
            ro_status_res = $random(seed);
            ro_data_out   = $random(seed);
            ro_mixed_hi   = $random(seed);
        end
    endtask

    //-------------------------------------------------------------------------
    // Test sequence
    //-------------------------------------------------------------------------
    integer i, k, n;
    integer rw_sel;
    reg [6:0] a;
    reg [7:0] tmp;

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("tb_spireg.vcd");
            $dumpvars(0, tb_spireg);
        end
        // %h accepts both "0x1234abcd" and "1234abcd" (iverilog)
        if (!$value$plusargs("seed=%h", seed)) seed = 32'h1234_5678;

        error_count = 0;
        check_count = 0;

        sclk = 1'b0; mosi = 1'b0; cs_n = 1'b1; rst_n = 1'b1;
        ro_ready = 0; ro_error = 0; ro_busy = 0; ro_status_res = 5'h00;
        ro_data_out = 8'h99; ro_id = 8'hA5; ro_mixed_hi = 4'hB;

        $display("=== spireg self-checking testbench ===");
        $display("    seed = 0x%08h", seed);

        do_reset;

        //--------------------------------------------------------------
        banner("T1  reset values readable");
        check_readback("T1");
        check_outputs("T1");

        //--------------------------------------------------------------
        banner("T2  single write/read of each RW register");
        for (k = 0; k <= LAST_ADDR; k = k + 1) begin
            if (rw_mask(k[6:0]) != 8'h00) begin
                txb[0] = 8'h5A ^ k[7:0];
                model_write(k[6:0], 1);
                spi_xfer(1'b1, k[6:0], 1);
                check_outputs("T2");
                model_read(k[6:0], 1);
                spi_xfer(1'b0, k[6:0], 1);
                compare_rx("T2", 1);
            end
        end

        //--------------------------------------------------------------
        banner("T3  write to RO-only registers has no effect");
        txb[0] = 8'hFF;
        model_write(A_STATUS, 1);        // model: no writable bits
        spi_xfer(1'b1, A_STATUS, 1);
        check_outputs("T3 status");
        txb[0] = 8'hFF;
        model_write(A_ID, 1);
        spi_xfer(1'b1, A_ID, 1);
        check_outputs("T3 id");
        check_readback("T3");

        //--------------------------------------------------------------
        banner("T4  mixed register: RO bits survive a write, read merges");
        txb[0] = 8'hFF;
        model_write(A_MIXED, 1);
        spi_xfer(1'b1, A_MIXED, 1);
        check_outputs("T4");
        model_read(A_MIXED, 1);
        spi_xfer(1'b0, A_MIXED, 1);
        compare_rx("T4 merge", 1);

        //--------------------------------------------------------------
        banner("T5  bulk write then bulk read across the whole map");
        for (k = 0; k <= LAST_ADDR; k = k + 1) txb[k] = 8'hC3 + k[7:0];
        model_write(7'h00, LAST_ADDR + 1);
        spi_xfer(1'b1, 7'h00, LAST_ADDR + 1);
        check_outputs("T5");
        check_readback("T5");

        //--------------------------------------------------------------
        banner("T6  overrun write: burst starts inside the map, runs past the end");
        for (k = 0; k < 16; k = k + 1) txb[k] = 8'hEE;
        model_write(A_ID, 16);           // 0x05 -> 0x06 -> saturate
        spi_xfer(1'b1, A_ID, 16);
        check_outputs("T6");
        check_readback("T6");

        //--------------------------------------------------------------
        banner("T7  overrun read: must return 0x00 past the last register");
        model_read(A_ID, 8);
        spi_xfer(1'b0, A_ID, 8);
        compare_rx("T7", 8);

        //--------------------------------------------------------------
        banner("T8  no-wrap: 80-byte burst starting above the map (0x40)");
        for (k = 0; k < 80; k = k + 1) txb[k] = 8'hEE;
        model_write(7'h40, 80);          // model: nothing must change
        spi_xfer(1'b1, 7'h40, 80);
        check_outputs("T8");
        check_readback("T8");

        //--------------------------------------------------------------
        banner("T9  no-wrap: 200-byte burst from 0x7F (top of address space)");
        for (k = 0; k < 200; k = k + 1) txb[k] = 8'h77;
        model_write(7'h7F, 200);
        spi_xfer(1'b1, 7'h7F, 200);
        check_outputs("T9");
        check_readback("T9");

        //--------------------------------------------------------------
        banner("T10 read starting above the map returns all zeros");
        model_read(7'h55, 12);
        spi_xfer(1'b0, 7'h55, 12);
        compare_rx("T10", 12);

        //--------------------------------------------------------------
        banner("T11 burst starting exactly at LAST_ADDR: one byte, then stop");
        for (k = 0; k < 6; k = k + 1) txb[k] = 8'h09 + k[7:0];
        model_write(LAST_ADDR, 6);
        spi_xfer(1'b1, LAST_ADDR, 6);
        check_outputs("T11");
        check_readback("T11");

        //--------------------------------------------------------------
        banner("T12 aborted transfers: 15 bits discarded, 16 bits committed");
        txb[0] = 8'h00;
        spi_abort(1'b1, A_DATA_IN, 8'hA7, 15);      // one bit short
        check_outputs("T12 abort@15");               // model unchanged
        txb[0] = 8'hA7;
        model_write(A_DATA_IN, 1);
        spi_abort(1'b1, A_DATA_IN, 8'hA7, 16);      // exactly one data byte
        check_outputs("T12 abort@16");
        // abort during the command byte
        spi_abort(1'b1, A_CONTROL, 8'h5C, 4);
        check_outputs("T12 abort@4");
        check_readback("T12");

        //--------------------------------------------------------------
        banner("T13 SCLK toggling while deselected must be ignored");
        mosi = 1'b1;
        sclk_idle_burst(200);
        mosi = 1'b0;
        check_outputs("T13");
        check_readback("T13");

        //--------------------------------------------------------------
        banner("T14 back-to-back transactions with minimal CS-high time");
        txb[0] = 8'h11; model_write(A_CONTROL, 1); spi_xfer(1'b1, A_CONTROL, 1);
        txb[0] = 8'h22; model_write(A_DATA_IN, 1); spi_xfer(1'b1, A_DATA_IN, 1);
        txb[0] = 8'h33; model_write(A_CONFIG,  1); spi_xfer(1'b1, A_CONFIG,  1);
        check_outputs("T14");
        check_readback("T14");

        //--------------------------------------------------------------
        banner("T15 async reset mid-transaction (cs_n held low)");
        // rst_n is released between the rising edges of bits 9 and 10 of the
        // frame (release time chosen so it never coincides with an SCLK edge).
        // 0xA0 is chosen so that a slave which re-parses the remaining bits
        // as a new frame would decode them as "write 0x82 to 0x02" -- i.e.
        // this test fails unless the rest of the interrupted frame is ignored.
        fork
            begin
                for (k = 0; k < 8; k = k + 1) txb[k] = 8'hA0;
                spi_xfer(1'b1, A_CONTROL, 8);
            end
            begin
                #(20*SCLK_HALF);
                rst_n = 1'b0;
                #(2*SCLK_HALF);
                rst_n = 1'b1;
            end
        join
        model_reset;
        check_outputs("T15 after reset");
        check_readback("T15");

        //--------------------------------------------------------------
        banner("T15b reset between bytes, cs_n held low: rest of frame ignored");
        // Master intends: burst write CONTROL=0x82, STATUS=0x42. A reset
        // after the command byte must not let the slave re-parse 0x82 as a
        // new command byte (= write 0x42 to DATA_IN).
        cs_n = 1'b0;
        #T_CSS;
        spi_byte(8'h80, tmp);                    // write @ CONTROL
        rst_n = 1'b0;
        #(2*SCLK_HALF);
        rst_n = 1'b1;
        #(2*SCLK_HALF);
        spi_byte(8'h82, tmp);
        spi_byte(8'h42, tmp);
        #SCLK_HALF;
        cs_n = 1'b1;
        #T_CSS;
        model_reset;
        check_outputs("T15b write frame");

        // Same for a read frame: after the reset MISO must stay low and the
        // remaining bits must not be executed, even if they look like a write.
        cs_n = 1'b0;
        #T_CSS;
        spi_byte({1'b0, A_ID}, tmp);             // read @ ID
        rst_n = 1'b0;
        #(2*SCLK_HALF);
        rst_n = 1'b1;
        #(2*SCLK_HALF);
        spi_byte(8'h82, tmp);
        chk("T15b read frame byte 1", tmp, 8'h00);
        spi_byte(8'h5A, tmp);
        chk("T15b read frame byte 2", tmp, 8'h00);
        #SCLK_HALF;
        cs_n = 1'b1;
        #T_CSS;
        model_reset;
        check_outputs("T15b read frame");
        check_readback("T15b");               // next frame works normally

        //--------------------------------------------------------------
        banner("T16 RO inputs change between transactions and are observed");
        for (k = 0; k < 8; k = k + 1) begin
            randomise_ro;                        // cs_n is high here
            model_read(7'h00, LAST_ADDR + 1);
            spi_xfer(1'b0, 7'h00, LAST_ADDR + 1);
            compare_rx("T16", LAST_ADDR + 1);
        end

        //--------------------------------------------------------------
        banner("T17 randomised stress");
        for (i = 0; i < NUM_RANDOM; i = i + 1) begin
            rw_sel = $random(seed) & 1;
            a      = $random(seed) & 7'h7F;
            n      = 1 + ({$random(seed)} % 24);

            if (($random(seed) & 7) == 0) randomise_ro;

            if (($random(seed) & 31) == 0) begin
                do_reset;
                check_outputs("T17 post-reset");
            end

            if (rw_sel) begin
                for (k = 0; k < n; k = k + 1) txb[k] = $random(seed);
                model_write(a, n);
                spi_xfer(1'b1, a, n);
                check_outputs("T17 write");
            end
            else begin
                model_read(a, n);
                spi_xfer(1'b0, a, n);
                compare_rx("T17 read", n);
            end

            if ((i % 50) == 0) check_readback("T17 sweep");
        end
        check_readback("T17 final");

        //--------------------------------------------------------------
        $display("");
        $display("=====================================================");
        $display(" checks : %0d", check_count);
        $display(" errors : %0d", error_count);
        if (error_count == 0)
            $display(" RESULT: PASS");
        else
            $display(" RESULT: FAIL");
        $display("=====================================================");
        $finish;
    end

    // Watchdog
    initial begin
        #50_000_000;
        $display(" RESULT: FAIL (watchdog timeout)");
        $finish;
    end

endmodule
