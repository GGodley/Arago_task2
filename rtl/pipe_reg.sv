// pipe_reg: one pipeline register stage (valid bit + data), or a bypass.
//
//   EN = 1: out_valid is a flop with async active-low reset. q is WIDTH data flops
//           with no reset that load only when in_valid is high, so they hold their
//           value (and can be clock-gated) between vectors. out_valid qualifies q.
//   EN = 0: the stage is removed: out_valid = in_valid and q = d (plain wires).
//
// Same ports either way, so the parent describes every stage with one instance
// and never needs its own generate block.

`default_nettype none

module pipe_reg #(
    parameter int WIDTH = 1,
    parameter bit EN    = 1'b1
) (
    /* verilator lint_off UNUSEDSIGNAL */   // clk and rst_n are unused when EN = 0
    input  wire              clk,
    input  wire              rst_n,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire              in_valid,
    input  wire  [WIDTH-1:0] d,
    output logic             out_valid,
    output logic [WIDTH-1:0] q
);
    generate
        if (EN) begin : g_reg
            always_ff @(posedge clk or negedge rst_n)
                if (!rst_n) out_valid <= 1'b0;
                else        out_valid <= in_valid;

            always_ff @(posedge clk)
                if (in_valid) q <= d;
        end else begin : g_bypass
            assign out_valid = in_valid;
            assign q         = d;
        end
    endgenerate
endmodule

`default_nettype wire
