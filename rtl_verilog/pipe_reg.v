// pipe_reg: one pipeline register stage (valid bit + data), or a bypass.
// Verilog-2001 version of rtl/pipe_reg.sv (same ports, same behaviour).
//
//   EN = 1: out_valid is a flop with async active-low reset. q is WIDTH data flops
//           with no reset that load only when in_valid is high, so they hold their
//           value (and can be clock-gated) between vectors. out_valid qualifies q.
//   EN = 0: the stage is removed: out_valid = in_valid and q = d (plain wires).
//
// Same ports either way, so the parent describes every stage with one instance
// and never needs its own generate block. The outputs are wires; the flops are
// declared inside the EN = 1 branch.

`default_nettype none

module pipe_reg #(
    parameter integer WIDTH = 1,
    parameter [0:0]   EN    = 1'b1
) (
    /* verilator lint_off UNUSEDSIGNAL */   // clk and rst_n are unused when EN = 0
    input  wire             clk,
    input  wire             rst_n,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire             in_valid,
    input  wire [WIDTH-1:0] d,
    output wire             out_valid,
    output wire [WIDTH-1:0] q
);
    generate
        if (EN) begin : g_reg
            reg             valid_q;
            reg [WIDTH-1:0] data_q;

            always @(posedge clk or negedge rst_n)
                if (!rst_n) valid_q <= 1'b0;
                else        valid_q <= in_valid;

            always @(posedge clk)
                if (in_valid) data_q <= d;

            assign out_valid = valid_q;
            assign q         = data_q;
        end else begin : g_bypass
            assign out_valid = in_valid;
            assign q         = d;
        end
    endgenerate
endmodule

`default_nettype wire
