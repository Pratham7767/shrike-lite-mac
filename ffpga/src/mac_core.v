// -----------------------------------------------------------------------------
// mac_core.v  --  signed 8x8 multiply, 32-bit accumulate.
//
//   acc <= acc + (a * b)        a, b : signed 8-bit  (-128 .. 127)
//                               a*b  : signed 16-bit (-16256 .. 16384), exact
//                               acc  : signed 32-bit two's complement
//
// Overflow policy: WRAP + STICKY FLAG.
//   The 32-bit accumulator wraps modulo 2^32 (normal two's-complement
//   behaviour).  If the mathematically exact sum leaves the range
//   [-2^31, 2^31-1], 'ovf' is set and stays set until 'clear'.
//   From a cleared state at least 131071 MACs are needed before overflow is
//   possible (2^31 / 16384 = 131072).
//
// Pipeline: mac_go -> (1 clk) product register -> (1 clk) accumulator.
// 'clear' has priority and cancels a product that is still in flight.
// The multiplier is plain LUT logic (the SLG47910 has no DSP blocks).
// -----------------------------------------------------------------------------
module mac_core (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               clear,     // 1-clk pulse
    input  wire               mac_go,    // 1-clk pulse
    input  wire signed [7:0]  a,
    input  wire signed [7:0]  b,
    output reg  signed [31:0] acc,
    output reg                ovf,       // sticky signed-overflow flag
    output wire               busy
);

    reg signed [15:0] prod;
    reg               prod_v;

    wire [31:0] prod_ext = {{16{prod[15]}}, prod};
    wire [31:0] sum      = acc + prod_ext;
    // signed overflow: both operands same sign, result sign differs
    wire        sum_ovf  = (acc[31] == prod_ext[31]) && (sum[31] != acc[31]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod   <= 16'sd0;
            prod_v <= 1'b0;
            acc    <= 32'sd0;
            ovf    <= 1'b0;
        end else begin
            prod_v <= 1'b0;
            if (clear) begin
                acc <= 32'sd0;
                ovf <= 1'b0;
            end else begin
                if (mac_go) begin
                    prod   <= $signed(a) * $signed(b);
                    prod_v <= 1'b1;
                end
                if (prod_v) begin
                    acc <= sum;
                    if (sum_ovf)
                        ovf <= 1'b1;
                end
            end
        end
    end

    assign busy = prod_v;

endmodule
