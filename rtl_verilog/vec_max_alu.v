// vec_max_alu: reconfigurable vector max unit (Arago Task 2).
// Verilog-2001 version of rtl/vec_max_alu.sv (same ports, same behaviour).
//
// in_vec[63:0] is read as 8 x INT8 (mode 00), 4 x INT16 (mode 01) or 4 x BF16 (mode 10).
// Mode 11 is undefined by the spec and behaves as INT16 (a legal input, not an error).
// result[15:0] = max of the vector. INT8: the max is in result[7:0] and the upper byte,
// which the spec discards, is driven to zero (fewer loads on the INT8 path, less toggling).
// BF16 follows IEEE 754-2019 maximum: any NaN -> canonical qNaN 16'h7FC0, -0 < +0.
//
// Throughput: one vector per cycle. Latency: if the input register captures a vector
// at clock edge k, result and out_valid are registered at edge k + PIPE + 1 (PIPE + 2
// edges counting both ends). PIPE = 0, 1 (cut after L2, default) or 2 (cuts after L1
// and after L2). Any other value stops elaboration.
//
// Structure (seven cmp_slice instances, all shared by every mode):
//   stage 0  input register (mode decoded before it)
//   L1       u_l1_p0 = S0/S1: lane 0 vs lane 1    u_l1_p1 = S2/S3: lane 2 vs lane 3
//   stage 1  optional register (PIPE >= 2)
//   L2       u_l2    = S4/S5: winner of L1 pair 0 vs winner of L1 pair 1
//            INT16/BF16 are finished here.
//   stage 2  optional register (PIPE >= 1)
//   L3       u_l3    = S6: low byte vs high byte of the L2 winner (INT8 only)
//   output   output register
// A NaN detector runs beside L1, gated by BF16 mode.
//
// Why the PIPE = 1 cut is after L2, not after L1: both give about the same fmax,
// but after L2 only 16 data bits survive, so the register is about 20 flops
// instead of about 36.
//
// Why the input is registered: the 16-bit compare chain starts at the input.
// Without this register the slowest stage would also absorb an unknown upstream
// delay, and the block would have no clean timing boundary.
//
// Reset: only the valid bits are reset. Data flops load only with a valid vector.
//
// Naming: sN_* is the output of pipeline stage N (s0 = input register,
// s1 = after L1, s2 = after L2). lN_* is the combinational output of tree level N.
// Lanes: 16-bit lane j = in_vec[16j+15:16j], INT8 byte i = in_vec[8i+7:8i].
//
// Timescale is set by the simulation build (see scripts/run_sim_verilog.sh), not here.

`default_nettype none

module vec_max_alu #(
    parameter integer PIPE = 1
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         in_valid,
    input  wire  [1:0]  mode,
    input  wire  [63:0] in_vec,
    output wire         out_valid,
    output wire  [15:0] result
);
    localparam [1:0]  MODE_INT8     = 2'b00;
    localparam [1:0]  MODE_BF16     = 2'b10;   // 2'b01 and 2'b11: 16-bit integer
    localparam [7:0]  BF16_EXP_ONES = 8'hFF;   // exponent of Inf and NaN
    localparam [15:0] BF16_QNAN     = 16'h7FC0;

    // PIPE guard: only 0, 1 and 2 are supported. Verilog-2001 has no elaboration-time
    // $fatal, so an illegal PIPE instantiates a module that does not exist. Every
    // simulator, linter and synthesis tool then stops with an error naming it.
    generate
        if (PIPE < 0 || PIPE > 2) begin : g_bad_pipe
            ERROR_vec_max_alu_PIPE_must_be_0_1_or_2 u_bad_pipe ();
        end
    endgenerate

    // ------------------------------------------------------------------
    // Stage 0: input register
    // ------------------------------------------------------------------
    wire        s0_valid, s0_i8, s0_bf;
    wire [63:0] s0_vec;

    pipe_reg #(.WIDTH(66), .EN(1'b1)) u_s0 (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .d        ({mode == MODE_INT8, mode == MODE_BF16, in_vec}),
        .out_valid(s0_valid),
        .q        ({s0_i8, s0_bf, s0_vec})
    );

    wire [15:0] s0_lane0, s0_lane1, s0_lane2, s0_lane3;
    assign {s0_lane3, s0_lane2, s0_lane1, s0_lane0} = s0_vec;

    // ------------------------------------------------------------------
    // NaN side path, beside L1 and never on the critical path. Gated by BF16
    // mode, so the flag and its pipeline flops stay quiet in INT8/INT16 and
    // the output select needs no separate bf bit after L2.
    // ------------------------------------------------------------------
    function is_nan;
        input [14:0] x;   // sign bit not needed
        begin
            is_nan = (x[14:7] == BF16_EXP_ONES) && (x[6:0] != 7'd0);   // exponent all ones, mantissa non-zero
        end
    endfunction

    wire s0_nan;
    assign s0_nan = s0_bf & (is_nan(s0_lane0[14:0]) | is_nan(s0_lane1[14:0]) |
                             is_nan(s0_lane2[14:0]) | is_nan(s0_lane3[14:0]));

    // ------------------------------------------------------------------
    // Level 1: lane 0 vs lane 1 (S0/S1), lane 2 vs lane 3 (S2/S3)
    // ------------------------------------------------------------------
    wire [15:0] l1_win0, l1_win1;

    cmp_pair u_l1_p0 (
        .a (s0_lane0),
        .b (s0_lane1),
        .i8(s0_i8),
        .bf(s0_bf),
        .y (l1_win0)
    );

    cmp_pair u_l1_p1 (
        .a (s0_lane2),
        .b (s0_lane3),
        .i8(s0_i8),
        .bf(s0_bf),
        .y (l1_win1)
    );

    // ------------------------------------------------------------------
    // Stage 1: optional register after L1 (PIPE >= 2)
    // ------------------------------------------------------------------
    wire        s1_valid, s1_i8, s1_bf, s1_nan;
    wire [15:0] s1_win0, s1_win1;

    pipe_reg #(.WIDTH(35), .EN(PIPE >= 2)) u_s1 (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (s0_valid),
        .d        ({s0_i8, s0_bf, s0_nan, l1_win1, l1_win0}),
        .out_valid(s1_valid),
        .q        ({s1_i8, s1_bf, s1_nan, s1_win1, s1_win0})
    );

    // ------------------------------------------------------------------
    // Level 2: L1 winner 0 vs L1 winner 1 (S4/S5). INT16/BF16 finish here.
    // ------------------------------------------------------------------
    wire [15:0] l2_win;

    cmp_pair u_l2 (
        .a (s1_win0),
        .b (s1_win1),
        .i8(s1_i8),
        .bf(s1_bf),
        .y (l2_win)
    );

    // ------------------------------------------------------------------
    // Stage 2: register after L2 (PIPE >= 1). No bf bit from here on:
    // s1_nan is already gated by BF16 mode.
    // ------------------------------------------------------------------
    wire        s2_valid, s2_i8, s2_nan;
    wire [15:0] s2_win;

    pipe_reg #(.WIDTH(18), .EN(PIPE >= 1)) u_s2 (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (s1_valid),
        .d        ({s1_i8, s1_nan, l2_win}),
        .out_valid(s2_valid),
        .q        ({s2_i8, s2_nan, s2_win})
    );

    // ------------------------------------------------------------------
    // Level 3 (S6, INT8 only): low byte vs high byte of the L2 winner
    // ------------------------------------------------------------------
    wire [7:0] l3_win;

    /* verilator lint_off PINCONNECTEMPTY */
    cmp_slice u_l3 (
        .a          (s2_win[7:0]),
        .b          (s2_win[15:8]),
        .is_signed  (1'b1),
        .chain_en   (1'b0),
        .gt_in      (1'b0),
        .inv_neg    (1'b0),
        .use_ext_sel(1'b0),
        .ext_sel    (1'b0),
        .pick       (),            // not needed at the last level
        .y          (l3_win)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ------------------------------------------------------------------
    // Output select and output register
    // ------------------------------------------------------------------
    wire [15:0] result_d;
    assign result_d = s2_nan ? BF16_QNAN        :
                      s2_i8  ? {8'h00, l3_win}  :   // INT8: upper byte discarded by spec
                               s2_win;

    pipe_reg #(.WIDTH(16), .EN(1'b1)) u_out (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (s2_valid),
        .d        (result_d),
        .out_valid(out_valid),
        .q        (result)
    );
endmodule

`default_nettype wire
