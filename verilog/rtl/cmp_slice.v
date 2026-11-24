// cmp_slice: the one comparator block used for every slice S0..S6.
// Verilog-2001 version of rtl/cmp_slice.sv. Same ports, same names, same logic.
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
// SV -> Verilog translation notes:
//   * SV "logic" becomes "wire" here, because every signal in this module is
//     driven by a continuous assign (pure combinational logic, no always blocks).
`timescale 1ns/1ps

module cmp_slice (
    input  wire [7:0] a,
    input  wire [7:0] b,
    input  wire       is_signed,   // bit 7 is a sign bit
    input  wire       chain_en,    // extend compare over lower partner
    input  wire       gt_in,       // lower partner's pick (unsigned a > b)
    input  wire       inv_neg,     // BF16: flip decision when both negative
    input  wire       use_ext_sel, // mux follows ext_sel instead of own pick
    input  wire       ext_sel,
    output wire       pick,        // 1 = a is the max
    output wire [7:0] y            // winning byte, original bits
);
    wire [7:0] ak, bk;
    wire       gt8, eq8, full, sel;

    assign ak   = {a[7] ^ is_signed, a[6:0]};
    assign bk   = {b[7] ^ is_signed, b[6:0]};
    assign gt8  = (ak > bk);                              // unsigned compare (both operands unsigned)
    assign eq8  = (a == b);
    assign full = gt8 | (eq8 & chain_en & gt_in);
    assign pick = full ^ (inv_neg & a[7] & b[7]);
    assign sel  = use_ext_sel ? ext_sel : pick;
    assign y    = sel ? a : b;
endmodule
