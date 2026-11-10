// -----------------------------------------------------------------------------
// tb_mac.v  --  self-checking testbench for the Shrike Lite MAC (top.v).
//
// Drives the real SPI pins exactly like the RP2040 does (mode 0, MSB first)
// with a 50 MHz FPGA clock, and checks:
//   reset state, init rule, CLEAR, signed arithmetic (golden vectors from
//   gen_vectors.py), READ byte order, frame-length checks, unknown commands,
//   overflow flag + wrap (backdoor preload and, with +FULL_OVF, 131072 real
//   SPI MACs), SCK at 1/2/4 MHz, logic reset, MISO tri-state, LED.
//
// Run:  see run_sim.sh / run_sim.bat
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_mac;

    reg  clk = 1'b0;
    always #10 clk = ~clk;                    // 50 MHz, like OSC_CLK

    reg  rst_n    = 1'b0;
    reg  spi_sck  = 1'b0;
    reg  spi_ss_n = 1'b1;
    reg  spi_mosi = 1'b0;
    wire spi_miso, spi_miso_en, led, led_en, clk_en;

    // MISO as the RP2040 sees it: high-Z when the FPGA does not drive it
    wire miso_pin = spi_miso_en ? spi_miso : 1'bz;

    top dut (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .spi_sck(spi_sck), .spi_ss_n(spi_ss_n), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_miso_en(spi_miso_en),
        .led(led), .led_en(led_en)
    );

    // ---- SPI master model -----------------------------------------------------
    integer half_ns = 500;                    // 1 MHz SCK by default
    integer tcss_ns = 200;                    // CS low -> first SCK edge
    integer tcsh_ns = 200;                    // last SCK edge -> CS high
    integer gap_ns  = 400;                    // CS high time between frames

    reg [7:0] txb [0:7];
    reg [7:0] rxb [0:7];
    integer errors = 0;
    integer checks = 0;

    task spi_frame(input integer nbytes);
        integer i, k;
        begin
            spi_ss_n = 1'b0;
            #(tcss_ns);
            for (i = 0; i < nbytes; i = i + 1) begin
                rxb[i] = 8'h00;
                for (k = 7; k >= 0; k = k - 1) begin
                    spi_mosi = txb[i][k];
                    #(half_ns);
                    spi_sck = 1'b1;
                    rxb[i][k] = miso_pin;     // master samples on rising edge
                    #(half_ns);
                    spi_sck = 1'b0;
                end
            end
            #(tcsh_ns);
            spi_ss_n = 1'b1;
            #(gap_ns);
        end
    endtask

    task check(input [255:0] what, input [31:0] got, input [31:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  FAIL %0s: got 0x%08h expected 0x%08h  (t=%0t)", what, got, exp, $time);
            end
        end
    endtask

    task do_clear;
        begin
            txb[0] = 8'h01;
            spi_frame(1);
            check("CLEAR sync", rxb[0], 8'hA5);
        end
    endtask

    task do_mac(input [7:0] a, input [7:0] b);
        begin
            txb[0] = 8'h02; txb[1] = a; txb[2] = b;
            spi_frame(3);
            check("MAC sync", rxb[0], 8'hA5);
            check("MAC resp1", rxb[1], 8'h00);
            check("MAC resp2", rxb[2], 8'h00);
        end
    endtask

    reg [31:0] r_acc;
    reg [7:0]  r_st;
    task do_read;
        begin
            txb[0] = 8'h03; txb[1] = 0; txb[2] = 0; txb[3] = 0; txb[4] = 0; txb[5] = 0;
            spi_frame(6);
            check("READ sync", rxb[0], 8'hA5);
            r_acc = {rxb[1], rxb[2], rxb[3], rxb[4]};
            r_st  = rxb[5];
        end
    endtask

    task expect_state(input [255:0] what, input [31:0] acc, input [7:0] st);
        begin
            do_read;
            check(what, r_acc, acc);
            check(what, {24'h0, r_st}, {24'h0, st});
        end
    endtask

    // ---- golden vectors ----------------------------------------------------------
    integer fd, n, nvec;
    reg [7:0]  va, vb;
    reg [31:0] vacc;
    integer    vovf;

    task run_vectors(input integer limit, input integer read_every);
        begin
            fd = $fopen("vectors.txt", "r");
            if (fd == 0) begin
                $display("  FAIL cannot open vectors.txt (run gen_vectors.py first)");
                errors = errors + 1;
            end else begin
                nvec = 0;
                while (!$feof(fd) && nvec < limit) begin
                    n = $fscanf(fd, "%h %h %h %d\n", va, vb, vacc, vovf);
                    if (n == 4) begin
                        do_mac(va, vb);
                        nvec = nvec + 1;
                        if (nvec <= 64 || (nvec % read_every) == 0) begin
                            do_read;
                            check("vector acc", r_acc, vacc);
                            check("vector ovf", {31'h0, r_st[1]}, vovf);
                        end
                    end
                end
                $fclose(fd);
                do_read;
                check("vector final acc", r_acc, vacc);
                $display("  %0d vectors applied, final acc = %0d", nvec, $signed(r_acc));
            end
        end
    endtask

    integer i;
    initial begin
        $display("=== Shrike Lite MAC testbench ===");
        #200 rst_n = 1'b1;
        #200;

        // 1. tri-state + reset state
        check("MISO OE idle", {31'h0, spi_miso_en}, 0);
        check("clk_en", {31'h0, clk_en}, 1);
        check("led_en", {31'h0, led_en}, 1);
        $display("[1] reset state");
        expect_state("reset", 32'h0, 8'h40);
        check("LED off before CLEAR", {31'h0, led}, 0);

        // 2. MAC before CLEAR is rejected
        $display("[2] MAC before CLEAR");
        do_mac(8'd5, 8'd7);
        expect_state("uninit MAC rejected", 32'h0, 8'h44);

        // 3. CLEAR
        $display("[3] CLEAR");
        do_clear;
        expect_state("after CLEAR", 32'h0, 8'h41);
        check("LED on after CLEAR", {31'h0, led}, 1);

        // 4. golden vectors at 1 MHz
        $display("[4] golden vectors @ 1 MHz SCK");
        run_vectors(100000, 50);

        // 5. faster SCK
        $display("[5] golden vectors @ 2 MHz and 4 MHz SCK");
        half_ns = 250; do_clear; run_vectors(300, 10);
        half_ns = 125; do_clear; run_vectors(300, 10);
        half_ns = 500;

        // 6. framing errors
        $display("[6] frame-length and command checks");
        do_clear;
        do_mac(8'd3, 8'hFE);                       // 3 * -2 = -6
        expect_state("before framing tests", 32'hFFFF_FFFA, 8'h41);
        txb[0] = 8'h02; txb[1] = 8'd10; spi_frame(2);           // short MAC
        expect_state("short MAC ignored", 32'hFFFF_FFFA, 8'h49);
        do_clear;
        txb[0] = 8'h02; txb[1] = 8'd10; txb[2] = 8'd10; txb[3] = 0; spi_frame(4); // long MAC
        expect_state("long MAC ignored", 32'h0, 8'h49);
        do_clear;
        do_mac(8'd1, 8'd1);
        txb[0] = 8'h01; txb[1] = 8'h00; spi_frame(2);           // long CLEAR
        expect_state("long CLEAR ignored", 32'h1, 8'h49);
        check("LED off on error", {31'h0, led}, 0);
        do_clear;
        txb[0] = 8'h55; spi_frame(1);                           // unknown command
        expect_state("unknown cmd", 32'h0, 8'h51);
        do_clear;
        txb[0] = 8'h03; spi_frame(3);                           // short READ
        expect_state("short READ flagged", 32'h0, 8'h49);
        do_clear;
        spi_ss_n = 1'b0; #300; spi_ss_n = 1'b1; #400;           // empty CS pulse
        expect_state("empty frame ignored", 32'h0, 8'h41);
        for (i = 0; i < 9; i = i + 1) txb[i % 8] = 8'h00;
        txb[0] = 8'h02; txb[1] = 8'd2; txb[2] = 8'd2;
        spi_frame(8);                                           // byte_count saturation
        expect_state("8-byte MAC ignored", 32'h0, 8'h49);

        // 7. overflow (backdoor preload of the accumulator to reach the edges fast)
        $display("[7] overflow boundaries (backdoor preload)");
        do_clear;
        dut.u_mac.acc = 32'h7FFF_BFFF;                // +16384 -> exactly INT32_MAX
        do_mac(8'h80, 8'h80);
        expect_state("hit INT32_MAX, no ovf", 32'h7FFF_FFFF, 8'h41);
        do_mac(8'd1, 8'd1);                           // +1 -> wraps to INT32_MIN
        expect_state("positive wrap", 32'h8000_0000, 8'h43);
        check("LED off on ovf", {31'h0, led}, 0);
        do_mac(8'hFF, 8'd1);                          // -1 -> back in range, flag sticky
        expect_state("ovf sticky", 32'h7FFF_FFFF, 8'h43);
        do_clear;
        expect_state("CLEAR clears ovf", 32'h0, 8'h41);
        dut.u_mac.acc = 32'h8000_3F80;                // -16256 -> exactly INT32_MIN
        do_mac(8'h80, 8'h7F);
        expect_state("hit INT32_MIN, no ovf", 32'h8000_0000, 8'h41);
        do_mac(8'hFF, 8'd1);                          // -1 -> wraps to INT32_MAX
        expect_state("negative wrap", 32'h7FFF_FFFF, 8'h43);

        // 8. optional: real overflow through SPI only (131072 MACs of 16384)
        if ($test$plusargs("FULL_OVF")) begin
            $display("[8] full overflow through SPI (131072 MACs @ 4 MHz)");
            half_ns = 125; tcss_ns = 100; tcsh_ns = 100; gap_ns = 200;
            do_clear;
            for (i = 0; i < 131071; i = i + 1) begin
                txb[0] = 8'h02; txb[1] = 8'h80; txb[2] = 8'h80; spi_frame(3);
            end
            expect_state("131071 x 16384, no ovf", 32'h7FFF_C000, 8'h41);
            do_mac(8'h80, 8'h80);
            expect_state("131072nd MAC overflows", 32'h8000_0000, 8'h43);
            half_ns = 500; tcss_ns = 200; tcsh_ns = 200; gap_ns = 400;
        end else begin
            $display("[8] skipped (add +FULL_OVF to run 131072 real MACs)");
        end

        // 9. logic reset from RP2040 GPIO14
        $display("[9] rst_n pulse");
        do_clear; do_mac(8'd9, 8'd9);
        rst_n = 1'b0; #200; rst_n = 1'b1; #200;
        expect_state("after rst_n", 32'h0, 8'h40);

        // 10. MISO released after frames
        check("MISO OE idle at end", {31'h0, spi_miso_en}, 0);

        $display("=== %0d checks, %0d errors ===", checks, errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

endmodule
