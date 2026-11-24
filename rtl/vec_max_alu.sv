// vec_max_alu: reconfigurable vector max unit (Arago Task 2).
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
    // ------------------------------------------------------------------
    // Input register. The mode is decoded before the register so the
    // high-fanout control bits start from a flop.
    // ------------------------------------------------------------------
    logic        v0, i8_0, bf_0;
    logic [63:0] x0;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) v0 <= 1'b0;
        else        v0 <= in_valid;

    always_ff @(posedge clk)
        if (in_valid) begin
            x0   <= in_vec;
            i8_0 <= (mode == 2'b00);
            bf_0 <= (mode == 2'b10);
        end

    // ------------------------------------------------------------------
    // NaN side path (computed on raw lanes, never on the critical path)
    // ------------------------------------------------------------------
    logic nan_0;
    always_comb begin
        nan_0 = 1'b0;
        for (int j = 0; j < 4; j++)
            nan_0 = nan_0 | ((x0[16*j+14 -: 8] == 8'hFF) && (x0[16*j+6 -: 7] != 7'd0));
    end

    // ------------------------------------------------------------------
    // Level 1: two pairs. Pair p compares lanes 2p and 2p+1.
    // ------------------------------------------------------------------
    // l1 bytes: [7:0]=S0 (low, pair 0), [15:8]=S1 (high, pair 0), [23:16]=S2, [31:24]=S3
    logic [31:0] l1;
    logic [1:0]  pk_lo1, pk_hi1;

    genvar p;
    generate
        for (p = 0; p < 2; p++) begin : g_l1
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
    logic       v1, i8_1, bf_1, nan_1;
    logic [31:0] m1;

    generate
        if (PIPE >= 2) begin : g_reg1
            always_ff @(posedge clk or negedge rst_n)
                if (!rst_n) v1 <= 1'b0;
                else        v1 <= v0;
            always_ff @(posedge clk)
                if (v0) begin
                    m1    <= l1;
                    i8_1  <= i8_0;  bf_1  <= bf_0;  nan_1 <= nan_0;
                end
        end else begin : g_wire1
            assign v1 = v0;  assign i8_1 = i8_0;  assign bf_1 = bf_0;  assign nan_1 = nan_0;
            assign m1 = l1;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Level 2: one pair (S4 low bytes, S5 high bytes). INT16/BF16 finish here.
    // ------------------------------------------------------------------
    logic [7:0] t0, t1;
    logic       pk_lo2, pk_hi2;

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
    logic       v2, i8_2, bf_2, nan_2;
    logic [7:0] t0_2, t1_2;

    generate
        if (PIPE >= 1) begin : g_reg2
            always_ff @(posedge clk or negedge rst_n)
                if (!rst_n) v2 <= 1'b0;
                else        v2 <= v1;
            always_ff @(posedge clk)
                if (v1) begin
                    t0_2 <= t0;  t1_2 <= t1;
                    i8_2 <= i8_1; bf_2 <= bf_1; nan_2 <= nan_1;
                end
        end else begin : g_wire2
            assign v2 = v1;  assign i8_2 = i8_1;  assign bf_2 = bf_1;  assign nan_2 = nan_1;
            assign t0_2 = t0; assign t1_2 = t1;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Level 3 (S6, INT8 only) and output select
    // ------------------------------------------------------------------
    logic [7:0]  y6;
    logic        pk6;
    logic [15:0] result_d;

    cmp_slice u_s6 (
        .a(t0_2), .b(t1_2),
        .is_signed(1'b1), .chain_en(1'b0), .gt_in(1'b0), .inv_neg(1'b0),
        .use_ext_sel(1'b0), .ext_sel(1'b0),
        .pick(pk6), .y(y6)
    );

    always_comb begin
        if (bf_2 && nan_2)  result_d = 16'h7FC0;
        else if (i8_2)      result_d = {{8{y6[7]}}, y6};
        else                result_d = {t1_2, t0_2};
    end

    // ------------------------------------------------------------------
    // Output register
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) out_valid <= 1'b0;
        else        out_valid <= v2;

    always_ff @(posedge clk)
        if (v2) result <= result_d;
endmodule
