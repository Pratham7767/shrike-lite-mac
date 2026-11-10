// -----------------------------------------------------------------------------
// spi_byte_target.v  --  SPI target (slave), mode 0, MSB first, 8-bit bytes.
//
// All SPI inputs are asynchronous to clk (50 MHz on-chip oscillator) and are
// oversampled through 2/3-flop synchronisers.  Rule of thumb: SCK must be
// slower than clk/10 (<= 5 MHz).  This project uses 1 MHz (default) and is
// simulated at 1, 2 and 4 MHz.
//
// MISO behaviour:
//   * The first byte of every frame (CS low ... CS high) returns SYNC = 0xA5.
//   * At every byte boundary (the SCK falling edge right after the 8th rising
//     edge) the byte presented on tx_byte is loaded and shifted out next.
//   * spi_miso_oe is high only while CS is low, so the pin is released
//     (high-Z) between frames.
// -----------------------------------------------------------------------------
module spi_byte_target #(
    parameter [7:0] SYNC = 8'hA5
) (
    input  wire       clk,
    input  wire       rst_n,          // synchronous-deassert reset, active low

    input  wire       spi_sck,
    input  wire       spi_ss_n,
    input  wire       spi_mosi,
    output wire       spi_miso,
    output wire       spi_miso_oe,

    output reg        frame_start,    // 1-clk pulse: CS went low
    output reg        frame_end,      // 1-clk pulse: CS went high
    output reg        rx_valid,       // 1-clk pulse: a full byte arrived
    output reg  [7:0] rx_byte,
    output reg  [2:0] rx_index,       // 0-based byte index in frame (saturates at 7)
    output reg  [2:0] byte_count,     // complete bytes in this frame (saturates at 7)
    input  wire [7:0] tx_byte         // next byte to send (sampled at byte boundary)
);

    // ---- synchronisers -------------------------------------------------------
    reg [2:0] sck_s;
    reg [2:0] ss_s;
    reg [1:0] mosi_s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_s  <= 3'b000;     // mode 0: SCK idles low
            ss_s   <= 3'b111;     // CS idles high
            mosi_s <= 2'b00;
        end else begin
            sck_s  <= {sck_s[1:0], spi_sck};
            ss_s   <= {ss_s[1:0],  spi_ss_n};
            mosi_s <= {mosi_s[0],  spi_mosi};
        end
    end

    wire ss_active = ~ss_s[1];
    wire ss_fall   =  ss_s[2] & ~ss_s[1];
    wire ss_rise   = ~ss_s[2] &  ss_s[1];
    wire sck_rise  = ~sck_s[2] &  sck_s[1];
    wire sck_fall  =  sck_s[2] & ~sck_s[1];
    wire mosi_bit  =  mosi_s[1];          // same latency as sck_s[1]

    // ---- shift registers -----------------------------------------------------
    reg [2:0] bit_cnt;
    reg [6:0] shift_in;
    reg [7:0] tx_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt     <= 3'd0;
            shift_in    <= 7'd0;
            tx_shift    <= SYNC;
            rx_byte     <= 8'd0;
            rx_index    <= 3'd0;
            byte_count  <= 3'd0;
            rx_valid    <= 1'b0;
            frame_start <= 1'b0;
            frame_end   <= 1'b0;
        end else begin
            rx_valid    <= 1'b0;
            frame_start <= 1'b0;
            frame_end   <= 1'b0;

            if (ss_fall) begin
                bit_cnt     <= 3'd0;
                byte_count  <= 3'd0;
                tx_shift    <= SYNC;
                frame_start <= 1'b1;
            end else if (ss_rise) begin
                frame_end   <= 1'b1;
            end else if (ss_active) begin
                if (sck_rise) begin
                    shift_in <= {shift_in[5:0], mosi_bit};
                    if (bit_cnt == 3'd7) begin
                        rx_byte    <= {shift_in, mosi_bit};
                        rx_valid   <= 1'b1;
                        rx_index   <= byte_count;
                        if (byte_count != 3'd7)
                            byte_count <= byte_count + 3'd1;
                        bit_cnt    <= 3'd0;
                    end else begin
                        bit_cnt    <= bit_cnt + 3'd1;
                    end
                end
                if (sck_fall) begin
                    if (bit_cnt == 3'd0)
                        tx_shift <= tx_byte;              // byte boundary
                    else
                        tx_shift <= {tx_shift[6:0], 1'b0};
                end
            end
        end
    end

    assign spi_miso    = tx_shift[7];
    assign spi_miso_oe = ss_active;

endmodule
