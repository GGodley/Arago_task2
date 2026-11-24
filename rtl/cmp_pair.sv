// cmp_pair: two cmp_slice blocks that compare two 16-bit lanes a and b.
//
//   i8 = 1 (INT8):  two independent signed byte compares.
//                   y[7:0]  = max(a[7:0],  b[7:0]),  y[15:8] = max(a[15:8], b[15:8]).
//   i8 = 0 (16-bit): one 16-bit compare. y = a or y = b, both bytes from the same lane.
//                   bf = 1 adds the BF16 sign-magnitude correction (high slice only).
//
// Because a 16-bit lane is {high byte, low byte}, comparing lane a with lane b
// automatically pairs bytes two apart in the 64-bit vector (B0/B2 and B1/B3 for
// lanes 0/1). That is what makes the INT16/BF16 tree a subset of the INT8 tree.
//
// Inside the pair the low and high slices are cross-wired:
//   low.pick -> high.gt_in   (low byte settles a tie on the high byte)
//   high.pick -> low.ext_sel (low byte's mux follows the 16-bit decision)
// This looks like a loop between the two instances but is not one at gate level.
// The real evaluation order is
//   low.a/b -> low.pick -> high.gt_in -> high.pick -> low.ext_sel -> low.y
// and ext_sel only drives low's mux, never low.pick. Keeping both slices inside
// this module means the parent sees a strictly feed-forward block with no
// cross-instance wires, so hierarchical lint and STA flows see no cycle either.

`default_nettype none

module cmp_pair (
    input  wire  [15:0] a,
    input  wire  [15:0] b,
    input  wire         i8,   // 1: two INT8 compares, 0: one 16-bit compare
    input  wire         bf,   // BF16 correction (only used when i8 = 0)
    output logic [15:0] y
);
    logic pick_lo, pick_hi;

    cmp_slice u_lo (
        .a          (a[7:0]),
        .b          (b[7:0]),
        .is_signed  (i8),        // INT8: signed byte. 16-bit: low byte is unsigned
        .chain_en   (1'b0),
        .gt_in      (1'b0),
        .inv_neg    (1'b0),
        .use_ext_sel(~i8),       // 16-bit: follow the high slice's decision
        .ext_sel    (pick_hi),
        .pick       (pick_lo),
        .y          (y[7:0])
    );

    cmp_slice u_hi (
        .a          (a[15:8]),
        .b          (b[15:8]),
        .is_signed  (1'b1),      // high byte always holds a sign bit
        .chain_en   (~i8),       // 16-bit: tie on the high byte -> low byte decides
        .gt_in      (pick_lo),
        .inv_neg    (bf),        // BF16: flip the decision when both are negative
        .use_ext_sel(1'b0),
        .ext_sel    (1'b0),
        .pick       (pick_hi),
        .y          (y[15:8])
    );
endmodule

`default_nettype wire
