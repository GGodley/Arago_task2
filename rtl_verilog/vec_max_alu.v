// vec_max_alu: reconfigurable vector max unit (Arago Task 2).
// Verilog-2001 port of rtl/vec_max_alu.sv. Same ports, same PIPE parameter,
// same seven shared cmp_slice instances (S0..S6), same register placement.
//
// in_vec[63:0] is read as 8 x INT8 (mode 00), 4 x INT16 (mode 01) or 4 x BF16 (mode 10).
// Mode 11 is undefined by the spec and behaves as INT16.
// result[15:0] = max of the vector. INT8 results are sign-extended to 16 bits.
// BF16 follows IEEE 754-2019 maximum: any NaN -> canonical qNaN 16'h7FC0, -0 < +0.
//
// Throughput: one vector per cycle. Latency: PIPE + 2 cycles (input reg, PIPE
// internal stages, output reg). PIPE = 0, 1 (cut after L2, default) or 2 (cuts
// after L1 and after L2).
//
// Lanes: INT8 byte i = in_vec[8i+7:8i]. 16-bit lane j = in_vec[16j+15:16j].
// Tree pairing pairs bytes two apart (B0/B2, B1/B3, B4/B6, B5/B7), so the
// INT16/BF16 tree is a subset of the INT8 tree and every slice is shared.
//
// SV -> Verilog mapping used in this file:
//   SV                                   Verilog-2001
//   ---------------------------------    ----------------------------------------
//   parameter int PIPE = 1               parameter integer PIPE = 1
//   logic, written in always_ff          reg
//   logic, driven by assign / port       wire
//   always_ff @(posedge clk ...)         always @(posedge clk ...)
//   always_comb                          always @(*)
//   for (int j = 0; j < 4; j++)          integer j;  for (j = 0; j < 4; j = j + 1)
//   for (p = 0; p < 2; p++) (generate)   for (p = 0; p < 2; p = p + 1)
//   output logic (written in always_ff)  output reg
//   x[hi -: 8] part selects              unchanged: "-:" is already Verilog-2001
//
// The one structural difference: in SV a "logic" signal can be a flop in one
// generate branch and a plain assign in the other. In Verilog a signal is
// either a reg or a wire, never both. So each optional pipeline stage below
// declares its flops (v1_q, m1_q, ...) locally inside the generate branch that
// uses them, and the stage outputs (v1, m1, ...) are always wires: assigned
// from the flops when the stage exists, or straight from the previous stage
// when it does not. The hardware is identical.
`timescale 1ns/1ps

module vec_max_alu #(
    parameter integer PIPE = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire [1:0]  mode,
    input  wire [63:0] in_vec,
    output reg         out_valid,
    output reg  [15:0] result
);
    // ------------------------------------------------------------------
    // Input register. The mode is decoded before the register so the
    // high-fanout control bits start from a flop.
    // ------------------------------------------------------------------
    reg        v0, i8_0, bf_0;
    reg [63:0] x0;

    // Valid bit: async active-low reset (the only reset flops in the design)
    always @(posedge clk or negedge rst_n)
        if (!rst_n) v0 <= 1'b0;
        else        v0 <= in_valid;

    // Data flops: no reset, only load when the input is valid
    always @(posedge clk)
        if (in_valid) begin
            x0   <= in_vec;
            i8_0 <= (mode == 2'b00);
            bf_0 <= (mode == 2'b10);
        end

    // ------------------------------------------------------------------
    // NaN side path (computed on raw lanes, never on the critical path)
    // A lane is NaN when exponent bits [14:7] are all ones and mantissa
    // bits [6:0] are non-zero.
    // ------------------------------------------------------------------
    reg     nan_0;   // reg because it is written in an always block; it is still combinational
    integer j;
    always @(*) begin
        nan_0 = 1'b0;
        for (j = 0; j < 4; j = j + 1)
            nan_0 = nan_0 | ((x0[16*j+14 -: 8] == 8'hFF) && (x0[16*j+6 -: 7] != 7'd0));
    end

    // ------------------------------------------------------------------
    // Level 1: two pairs. Pair p compares lanes 2p and 2p+1.
    //   u_lo = S0 (p=0) / S2 (p=1): low bytes,  B0 vs B2 / B4 vs B6
    //   u_hi = S1 (p=0) / S3 (p=1): high bytes, B1 vs B3 / B5 vs B7
    // In INT16/BF16 the high slice chains over the low one (chain_en) and
    // the low slice's mux follows the high slice's pick (use_ext_sel).
    // ------------------------------------------------------------------
    // l1 bytes: [7:0]=S0 (low, pair 0), [15:8]=S1 (high, pair 0), [23:16]=S2, [31:24]=S3
    wire [31:0] l1;
    wire [1:0]  pk_lo1, pk_hi1;

    genvar p;
    generate
        for (p = 0; p < 2; p = p + 1) begin : g_l1
            cmp_slice u_lo (
                .a(x0[32*p + 7  -: 8]), .b(x0[32*p + 23 -: 8]),
                .is_signed(i8_0), .chain_en(1'b0), .gt_in(1'b0), .inv_neg(1'b0),
                .use_ext_sel(~i8_0), .ext_sel(pk_hi1[p]),
                .pick(pk_lo1[p]), .y(l1[16*p + 7 -: 8])
            );
            cmp_slice u_hi (
                .a(x0[32*p + 15 -: 8]), .b(x0[32*p + 31 -: 8]),
                .is_signed(1'b1), .chain_en(~i8_0), .gt_in(pk_lo1[p]), .inv_neg(bf_0),
                .use_ext_sel(1'b0), .ext_sel(1'b0),
                .pick(pk_hi1[p]), .y(l1[16*p + 15 -: 8])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // Optional register after L1 (PIPE >= 2)
    // ------------------------------------------------------------------
    wire        v1, i8_1, bf_1, nan_1;   // stage outputs, always wires
    wire [31:0] m1;

    generate
        if (PIPE >= 2) begin : g_reg1
            reg        v1_q, i8_1_q, bf_1_q, nan_1_q;   // flops exist only in this branch
            reg [31:0] m1_q;
            always @(posedge clk or negedge rst_n)
                if (!rst_n) v1_q <= 1'b0;
                else        v1_q <= v0;
            always @(posedge clk)
                if (v0) begin
                    m1_q    <= l1;
                    i8_1_q  <= i8_0;  bf_1_q  <= bf_0;  nan_1_q <= nan_0;
                end
            assign v1 = v1_q;  assign i8_1 = i8_1_q;  assign bf_1 = bf_1_q;  assign nan_1 = nan_1_q;
            assign m1 = m1_q;
        end else begin : g_wire1
            assign v1 = v0;  assign i8_1 = i8_0;  assign bf_1 = bf_0;  assign nan_1 = nan_0;
            assign m1 = l1;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Level 2: one pair (S4 low bytes, S5 high bytes). INT16/BF16 finish here.
    // ------------------------------------------------------------------
    wire [7:0] t0, t1;
    wire       pk_lo2, pk_hi2;

    cmp_slice u_s4 (
        .a(m1[7:0]), .b(m1[23:16]),
        .is_signed(i8_1), .chain_en(1'b0), .gt_in(1'b0), .inv_neg(1'b0),
        .use_ext_sel(~i8_1), .ext_sel(pk_hi2),
        .pick(pk_lo2), .y(t0)
    );
    cmp_slice u_s5 (
        .a(m1[15:8]), .b(m1[31:24]),
        .is_signed(1'b1), .chain_en(~i8_1), .gt_in(pk_lo2), .inv_neg(bf_1),
        .use_ext_sel(1'b0), .ext_sel(1'b0),
        .pick(pk_hi2), .y(t1)
    );

    // ------------------------------------------------------------------
    // Register after L2 (PIPE >= 1)
    // ------------------------------------------------------------------
    wire       v2, i8_2, bf_2, nan_2;   // stage outputs, always wires
    wire [7:0] t0_2, t1_2;

    generate
        if (PIPE >= 1) begin : g_reg2
            reg       v2_q, i8_2_q, bf_2_q, nan_2_q;   // flops exist only in this branch
            reg [7:0] t0_2_q, t1_2_q;
            always @(posedge clk or negedge rst_n)
                if (!rst_n) v2_q <= 1'b0;
                else        v2_q <= v1;
            always @(posedge clk)
                if (v1) begin
                    t0_2_q <= t0;  t1_2_q <= t1;
                    i8_2_q <= i8_1; bf_2_q <= bf_1; nan_2_q <= nan_1;
                end
            assign v2 = v2_q;  assign i8_2 = i8_2_q;  assign bf_2 = bf_2_q;  assign nan_2 = nan_2_q;
            assign t0_2 = t0_2_q; assign t1_2 = t1_2_q;
        end else begin : g_wire2
            assign v2 = v1;  assign i8_2 = i8_1;  assign bf_2 = bf_1;  assign nan_2 = nan_1;
            assign t0_2 = t0; assign t1_2 = t1;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Level 3 (S6, INT8 only) and output select
    // ------------------------------------------------------------------
    wire [7:0]  y6;
    wire        pk6;   // unused: S6's mux already selects y6
    wire [15:0] result_d;

    cmp_slice u_s6 (
        .a(t0_2), .b(t1_2),
        .is_signed(1'b1), .chain_en(1'b0), .gt_in(1'b0), .inv_neg(1'b0),
        .use_ext_sel(1'b0), .ext_sel(1'b0),
        .pick(pk6), .y(y6)
    );

    wire [15:0] int8_ext;
    assign int8_ext = {{8{y6[7]}}, y6};          // INT8 result, sign-extended to 16 bits
    assign result_d = (bf_2 && nan_2) ? 16'h7FC0 :
                      i8_2            ? int8_ext  :
                                        {t1_2, t0_2};

    // ------------------------------------------------------------------
    // Output register
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n)
        if (!rst_n) out_valid <= 1'b0;
        else        out_valid <= v2;

    always @(posedge clk)
        if (v2) result <= result_d;
endmodule
