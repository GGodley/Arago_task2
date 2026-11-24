// cmp_slice: the one comparator block used for every slice S0..S6.
//
// Compares two bytes and passes the larger one through a 2:1 mux, untouched.
//   * Sign handling: bit 7 is XORed with is_signed on the comparator inputs only
//     (sign-flip / offset-binary compare). Data bits are never modified.
//   * chain_en/gt_in: lets the lower partner slice settle a tie, so two slices
//     act as one 16-bit comparator (same merge rule as inside the 8-bit compare).
//   * inv_neg: BF16 only. Floats are sign-magnitude, so when both inputs are
//     negative the decision is flipped (one XOR on a 1-bit signal).
//   * use_ext_sel/ext_sel: lets this slice's mux follow the partner's decision,
//     so both bytes of a 16-bit lane always come from the same lane.
//
// Evaluation order inside a 16-bit pair (why the pair is not a loop):
//   low.a/b -> low.pick -> high.gt_in -> high.pick -> low.ext_sel -> low.y
// ext_sel only reaches the mux (y), never pick, so the gate-level graph is acyclic.
// Checked with Verilator -Wall (lint and full build) and Yosys `check`: no loops.
//
// Timescale is set by the simulation build (see scripts/run_sim.sh), not here.

module cmp_slice (
    input  logic [7:0] a,
    input  logic [7:0] b,
    input  logic       is_signed,   // bit 7 is a sign bit
    input  logic       chain_en,    // extend compare over lower partner
    input  logic       gt_in,       // lower partner's pick (unsigned a > b)
    input  logic       inv_neg,     // BF16: flip decision when both negative
    input  logic       use_ext_sel, // mux follows ext_sel instead of own pick
    input  logic       ext_sel,
    output logic       pick,        // 1 = a is the max
    output logic [7:0] y            // winning byte, original bits
);
    logic [7:0] ak, bk;
    logic       gt8, eq8, full, sel;

    assign ak   = {a[7] ^ is_signed, a[6:0]};
    assign bk   = {b[7] ^ is_signed, b[6:0]};
    assign gt8  = (ak > bk);                              // synthesizes to a log-depth gt/eq tree
    assign eq8  = (a == b);
    assign full = gt8 | (eq8 & chain_en & gt_in);

    // BF16 decision flip. Two facts make this one XOR exact:
    //   * Tie (a == b, both negative): full = 0 and the flip gives pick = 1, so a is
    //     chosen instead of b. They are identical, so the max is unchanged.
    //   * -0.0 vs +0.0: the signs differ, so a[7] & b[7] = 0 and there is no flip. The
    //     sign-flipped keys put +0 (8'h80) above -0 (8'h00), so +0 wins (IEEE 754-2019).
    assign pick = full ^ (inv_neg & a[7] & b[7]);
    assign sel  = use_ext_sel ? ext_sel : pick;
    assign y    = sel ? a : b;
endmodule
