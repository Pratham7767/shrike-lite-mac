// -----------------------------------------------------------------------------
// top.v  --  Shrike Lite signed MAC with SPI host interface.
//
// Board:   Vicharak Shrike Lite (RP2040 + Renesas ForgeFPGA SLG47910V)
// Clock:   on-chip 50 MHz oscillator (OSC_CLK), enabled by clk_en (OSC_EN)
//
// I/O map (set in Go Configure "IO Planner"; see README section 6):
//   port         dir  FPGA resource         RP2040 pin   role
//   clk          in   OSC_CLK               -            50 MHz system clock
//   clk_en       out  OSC_EN                -            tie high -> oscillator on
//   spi_sck      in   GPIO3_IN              GPIO2        SPI SCK
//   spi_ss_n     in   GPIO4_IN              GPIO1        SPI CS (active low)
//   spi_mosi     in   GPIO5_IN              GPIO3        SPI MOSI (RP2040 -> FPGA)
//   spi_miso     out  GPIO6_OUT             GPIO0        SPI MISO (FPGA -> RP2040)
//   spi_miso_en  out  GPIO6_OE              -            MISO output enable
//   rst_n        in   GPIO18_IN             GPIO14       logic reset, active low
//   led          out  GPIO16_OUT            -            FPGA user LED
//   led_en       out  GPIO16_OE             -            LED output enable (tie high)
//
// SPI protocol (mode 0: CPOL=0 CPHA=0, MSB first, 8-bit bytes, CS framed):
//   Every frame's first MISO byte is SYNC = 0xA5.
//
//   CLEAR  MOSI: 01                       MISO: A5
//          -> acc = 0, ovf = 0, all error flags = 0, INIT = 1
//   MAC    MOSI: 02 AA BB                 MISO: A5 00 00
//          -> acc = acc + AA*BB  (AA, BB signed 8-bit two's complement)
//             rejected (ERR_UNINIT) if CLEAR has not been done since reset
//   READ   MOSI: 03 00 00 00 00 00        MISO: A5 A3 A2 A1 A0 ST
//          -> A3..A0 = acc, big-endian (A3 = bits 31:24), ST = status
//
//   A command takes effect only if its frame has exactly the right length
//   (CLEAR 1, MAC 3, READ 6 bytes); otherwise it is dropped and ERR_FRAME set.
//   Unknown command byte -> ERR_CMD.
//
//   Status byte ST = { 3'b010, ERR_CMD, ERR_FRAME, ERR_UNINIT, OVF, INIT }
//     bit 0 INIT       accumulator cleared since reset/configuration
//     bit 1 OVF        sticky 32-bit signed overflow since last CLEAR
//     bit 2 ERR_UNINIT a MAC was sent before CLEAR (it was ignored)
//     bit 3 ERR_FRAME  a frame had the wrong length (it was ignored)
//     bit 4 ERR_CMD    unknown command byte
//     bits 7:5         constant 3'b010 (lets the host spot a stuck MISO line)
//   After reset ST = 0x40, after CLEAR ST = 0x41.
//
//   LED on  = INIT and no OVF / error flags.
// -----------------------------------------------------------------------------
(* top *) module top (
    (* iopad_external_pin, clkbuf_inhibit *) input  clk,
    (* iopad_external_pin *)                 output clk_en,
    (* iopad_external_pin *)                 input  rst_n,

    (* iopad_external_pin *)                 input  spi_sck,
    (* iopad_external_pin *)                 input  spi_ss_n,
    (* iopad_external_pin *)                 input  spi_mosi,
    (* iopad_external_pin *)                 output spi_miso,
    (* iopad_external_pin *)                 output spi_miso_en,

    (* iopad_external_pin *)                 output led,
    (* iopad_external_pin *)                 output led_en
);

    localparam [7:0] CMD_CLEAR = 8'h01;
    localparam [7:0] CMD_MAC   = 8'h02;
    localparam [7:0] CMD_READ  = 8'h03;

    assign clk_en = 1'b1;
    assign led_en = 1'b1;

    // ---- reset synchroniser (async assert, sync deassert) --------------------
    reg [1:0] rst_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};
    end
    wire rst_n_i = rst_sync[1];

    // ---- SPI target ------------------------------------------------------------
    wire       frame_start, frame_end, rx_valid;
    wire [7:0] rx_byte;
    wire [2:0] rx_index, byte_count;
    reg  [7:0] tx_next;

    spi_byte_target #(.SYNC(8'hA5)) u_spi (
        .clk         (clk),
        .rst_n       (rst_n_i),
        .spi_sck     (spi_sck),
        .spi_ss_n    (spi_ss_n),
        .spi_mosi    (spi_mosi),
        .spi_miso    (spi_miso),
        .spi_miso_oe (spi_miso_en),
        .frame_start (frame_start),
        .frame_end   (frame_end),
        .rx_valid    (rx_valid),
        .rx_byte     (rx_byte),
        .rx_index    (rx_index),
        .byte_count  (byte_count),
        .tx_byte     (tx_next)
    );

    // ---- MAC core ----------------------------------------------------------------
    reg         clear_p, mac_p;
    reg  [7:0]  a_reg, b_reg;
    wire [31:0] acc;
    wire        ovf, busy;

    mac_core u_mac (
        .clk    (clk),
        .rst_n  (rst_n_i),
        .clear  (clear_p),
        .mac_go (mac_p),
        .a      (a_reg),
        .b      (b_reg),
        .acc    (acc),
        .ovf    (ovf),
        .busy   (busy)
    );

    // ---- command decoder -----------------------------------------------------------
    reg  [7:0]  cmd;
    reg         init, err_uninit, err_frame, err_cmd;
    reg  [31:0] snap_acc;
    reg  [7:0]  snap_st;

    wire [7:0] status = {3'b010, err_cmd, err_frame, err_uninit, ovf, init};

    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) begin
            cmd        <= 8'h00;
            a_reg      <= 8'h00;
            b_reg      <= 8'h00;
            init       <= 1'b0;
            err_uninit <= 1'b0;
            err_frame  <= 1'b0;
            err_cmd    <= 1'b0;
            snap_acc   <= 32'h0;
            snap_st    <= 8'h00;
            tx_next    <= 8'h00;
            clear_p    <= 1'b0;
            mac_p      <= 1'b0;
        end else begin
            clear_p <= 1'b0;
            mac_p   <= 1'b0;

            if (frame_start) begin
                cmd     <= 8'h00;
                tx_next <= 8'h00;
            end

            if (rx_valid) begin
                tx_next <= 8'h00;
                case (rx_index)
                    3'd0: begin
                        cmd <= rx_byte;
                        if (rx_byte == CMD_READ) begin
                            snap_acc <= acc;
                            snap_st  <= status;
                            tx_next  <= acc[31:24];
                        end else if (rx_byte != CMD_CLEAR && rx_byte != CMD_MAC) begin
                            err_cmd  <= 1'b1;
                        end
                    end
                    3'd1: begin
                        if (cmd == CMD_MAC)  a_reg   <= rx_byte;
                        if (cmd == CMD_READ) tx_next <= snap_acc[23:16];
                    end
                    3'd2: begin
                        if (cmd == CMD_MAC)  b_reg   <= rx_byte;
                        if (cmd == CMD_READ) tx_next <= snap_acc[15:8];
                    end
                    3'd3: if (cmd == CMD_READ) tx_next <= snap_acc[7:0];
                    3'd4: if (cmd == CMD_READ) tx_next <= snap_st;
                    default: ;
                endcase
            end

            // Commands are executed when CS goes high, only if the length is right.
            if (frame_end && byte_count != 3'd0) begin
                case (cmd)
                    CMD_CLEAR: begin
                        if (byte_count == 3'd1) begin
                            clear_p    <= 1'b1;
                            init       <= 1'b1;
                            err_uninit <= 1'b0;
                            err_frame  <= 1'b0;
                            err_cmd    <= 1'b0;
                        end else begin
                            err_frame  <= 1'b1;
                        end
                    end
                    CMD_MAC: begin
                        if (byte_count != 3'd3)
                            err_frame  <= 1'b1;
                        else if (!init)
                            err_uninit <= 1'b1;
                        else
                            mac_p      <= 1'b1;
                    end
                    CMD_READ: begin
                        if (byte_count != 3'd6)
                            err_frame  <= 1'b1;
                    end
                    default: ;   // ERR_CMD already flagged
                endcase
            end
        end
    end

    assign led = init & ~(ovf | err_uninit | err_frame | err_cmd);

endmodule
