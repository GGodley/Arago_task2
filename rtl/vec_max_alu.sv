// vec_max_alu: reconfigurable vector max unit (Arago Task 2).
//
// in_vec[63:0] is read as 8 x INT8 (mode 00), 4 x INT16 (mode 01) or 4 x BF16 (mode 10).
// Mode 11 is undefined by the spec and behaves as INT16 (a legal input, not an error).
// result[15:0] = max of the vector. INT8: the max is in result[7:0] and the upper byte,
// which the spec discards, is driven to zero (fewer loads on the INT8 path, less toggling).
// BF16 follows IEEE 754-2019 maximum: any NaN -> canonical qNaN 16'h7FC0, -0 < +0.
//
// Throughput: one vector per cycle. Latency: PIPE + 2 cycles (input reg, PIPE
// internal stages, output reg). PIPE = 0, 1 (cut after L2, default) or 2 (cuts
// after L1 and after L2). Any other value stops elaboration.
//
// Why the PIPE = 1 cut is after L2, not after L1: both give about the same fmax
// (34 / 19.5 FO4 vs 20 / 33.5 FO4), but after L2 only 16 data bits survive, so the
// register costs about 20 flops instead of about 36.
//
// Why the input is registered: the critical path (the 16-bit compare chain) starts at
// the input. Without this register the slowest stage would also absorb an unknown
// upstream delay, and the block would have no clean timing boundary.
//
// Lanes: INT8 byte i = in_vec[8i+7:8i]. 16-bit lane j = in_vec[16j+15:16j].
// Tree pairing pairs bytes two apart (B0/B2, B1/B3, B4/B6, B5/B7), so the
// INT16/BF16 tree is a subset of the INT8 tree and every slice is shared.
//
// Naming: sN_* is the value held in (or wired through) pipeline register N.
// s0 = input register, s1 = after L1, s2 = after L2. lN_* is the combinational
// output of tree level N.

module vec_max_alu #(
    parameter int PIPE = 1
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [1:0]  mode,
    input  logic [63:0] in_vec,
    output logic        out_valid,
    output logic [15:0] result
);
    localparam logic [1:0] MODE_INT8  = 2'b00;
    // Any other mode (2'b01 INT16, and undefined 2'b11) leaves i8 = bf = 0: 16-bit integer.
    localparam logic [1:0] MODE_BF16  = 2'b10;

    generate
        if (PIPE < 0 || PIPE > 2) begin : g_bad_pipe
            $fatal(1, "vec_max_alu: PIPE must be 0, 1 or 2 (got %0d)", PIPE);   // elaboration-time
            initial $fatal(1, "vec_max_alu: PIPE must be 0, 1 or 2 (got %0d)", PIPE); // for simulators without elaboration tasks
        end
    endgenerate

    // ------------------------------------------------------------------
    // Stage 0: input register. The mode is decoded before the register so the
    // high-fanout control bits start from a flop. Data flops have no reset and
    // load only with a valid vector (clock-gating friendly); valid qualifies them.
    // ------------------------------------------------------------------
    logic        s0_valid, s0_i8, s0_bf;
    logic [63:0] s0_vec;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) s0_valid <= 1'b0;
        else        s0_valid <= in_valid;

    always_ff @(posedge clk)
        if (in_valid) begin
            s0_vec <= in_vec;
            s0_i8  <= (mode == MODE_INT8);
            s0_bf  <= (mode == MODE_BF16);
        end

    // Typed views of the input register: bytes for the tree, lanes for NaN detect.
    // (Unpacked arrays rather than packed 2-D vectors, so Icarus 12 and Yosys 0.33 accept them.)
    logic [7:0]  s0_byte [8];
    logic [15:0] s0_lane [4];
    genvar i;
    generate
        for (i = 0; i < 8; i++) begin : g_byte assign s0_byte[i] = s0_vec[8*i +: 8];   end
        for (i = 0; i < 4; i++) begin : g_lane assign s0_lane[i] = s0_vec[16*i +: 16]; end
    endgenerate

    // ------------------------------------------------------------------
    // NaN side path, in parallel with L1 and never on the critical path.
    // Gated by BF16 mode, so the flag and its pipeline flops stay quiet in
    // INT8/INT16 and the output select needs no separate bf bit.
    // ------------------------------------------------------------------
    function automatic logic is_nan_bf16(input logic [14:0] x);   // sign bit not needed
        is_nan_bf16 = (x[14:7] == 8'hFF) && (x[6:0] != 7'd0);   // exponent all ones, mantissa non-zero
    endfunction

    logic s0_nan;
    assign s0_nan = s0_bf & (is_nan_bf16(s0_lane[0][14:0]) | is_nan_bf16(s0_lane[1][14:0]) |
                             is_nan_bf16(s0_lane[2][14:0]) | is_nan_bf16(s0_lane[3][14:0]));

    // ------------------------------------------------------------------
    // Level 1: two pairs. Pair p compares lane 2p (bytes 4p, 4p+1)
    // against lane 2p+1 (bytes 4p+2, 4p+3).
    // l1_win bytes: [0]=S0 (pair 0 low), [1]=S1 (pair 0 high), [2]=S2, [3]=S3
    // ------------------------------------------------------------------
    logic [7:0]      l1_win [4];
    logic [1:0]      l1_pk_lo, l1_pk_hi;

    genvar p;
    generate
        for (p = 0; p < 2; p++) begin : g_l1
            cmp_slice u_lo (
                .a(s0_byte[4*p + 0]), .b(s0_byte[4*p + 2]),
                .is_signed(s0_i8), .chain_en(1'b0), .gt_in(1'b0), .inv_neg(1'b0),
                .use_ext_sel(~s0_i8), .ext_sel(l1_pk_hi[p]),
                .pick(l1_pk_lo[p]), .y(l1_win[2*p + 0])
            );
            cmp_slice u_hi (
                .a(s0_byte[4*p + 1]), .b(s0_byte[4*p + 3]),
                .is_signed(1'b1), .chain_en(~s0_i8), .gt_in(l1_pk_lo[p]), .inv_neg(s0_bf),
                .use_ext_sel(1'b0), .ext_sel(1'b0),
                .pick(l1_pk_hi[p]), .y(l1_win[2*p + 1])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // Optional register after L1 (PIPE >= 2)
    // ------------------------------------------------------------------
    logic            s1_valid, s1_i8, s1_bf, s1_nan;
    logic [7:0]      s1_win [4];

    generate
        if (PIPE >= 2) begin : g_reg1
            always_ff @(posedge clk or negedge rst_n)
                if (!rst_n) s1_valid <= 1'b0;
                else        s1_valid <= s0_valid;
            always_ff @(posedge clk)
                if (s0_valid) begin
                    for (int k = 0; k < 4; k++) s1_win[k] <= l1_win[k];
                    s1_i8  <= s0_i8;  s1_bf <= s0_bf;  s1_nan <= s0_nan;
                end
        end else begin : g_wire1
            assign s1_valid = s0_valid;  assign s1_i8 = s0_i8;
            assign s1_bf    = s0_bf;     assign s1_nan = s0_nan;
            for (i = 0; i < 4; i++) begin : g_win assign s1_win[i] = l1_win[i]; end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Level 2: one pair (S4 low bytes, S5 high bytes). INT16/BF16 finish here.
    // ------------------------------------------------------------------
    logic [7:0] l2_lo, l2_hi;
    logic       l2_pk_lo, l2_pk_hi;

    cmp_slice u_s4 (
        .a(s1_win[0]), .b(s1_win[2]),
        .is_signed(s1_i8), .chain_en(1'b0), .gt_in(1'b0), .inv_neg(1'b0),
        .use_ext_sel(~s1_i8), .ext_sel(l2_pk_hi),
        .pick(l2_pk_lo), .y(l2_lo)
    );
    cmp_slice u_s5 (
        .a(s1_win[1]), .b(s1_win[3]),
        .is_signed(1'b1), .chain_en(~s1_i8), .gt_in(l2_pk_lo), .inv_neg(s1_bf),
        .use_ext_sel(1'b0), .ext_sel(1'b0),
        .pick(l2_pk_hi), .y(l2_hi)
    );

    // ------------------------------------------------------------------
    // Register after L2 (PIPE >= 1). No bf bit is needed from here on:
    // s2_nan is already gated by BF16 mode.
    // ------------------------------------------------------------------
    logic       s2_valid, s2_i8, s2_nan;
    logic [7:0] s2_lo, s2_hi;

    generate
        if (PIPE >= 1) begin : g_reg2
            always_ff @(posedge clk or negedge rst_n)
                if (!rst_n) s2_valid <= 1'b0;
                else        s2_valid <= s1_valid;
            always_ff @(posedge clk)
                if (s1_valid) begin
                    s2_lo <= l2_lo;  s2_hi <= l2_hi;
                    s2_i8 <= s1_i8;  s2_nan <= s1_nan;
                end
        end else begin : g_wire2
            assign s2_valid = s1_valid;  assign s2_i8 = s1_i8;  assign s2_nan = s1_nan;
            assign s2_lo    = l2_lo;     assign s2_hi = l2_hi;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Level 3 (S6, INT8 only) and output select
    // ------------------------------------------------------------------
    logic [7:0]  l3_win;
    logic [15:0] result_d;

    /* verilator lint_off PINCONNECTEMPTY */
    cmp_slice u_s6 (
        .a(s2_lo), .b(s2_hi),
        .is_signed(1'b1), .chain_en(1'b0), .gt_in(1'b0), .inv_neg(1'b0),
        .use_ext_sel(1'b0), .ext_sel(1'b0),
        .pick(), .y(l3_win)                       // pick is not needed at the last level
    );
    /* verilator lint_on PINCONNECTEMPTY */

    assign result_d = s2_nan ? 16'h7FC0         :
                      s2_i8  ? {8'h00, l3_win}  :   // INT8: upper byte discarded by spec
                               {s2_hi, s2_lo};

    // ------------------------------------------------------------------
    // Output register
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) out_valid <= 1'b0;
        else        out_valid <= s2_valid;

    always_ff @(posedge clk)
        if (s2_valid) result <= result_d;
endmodule
