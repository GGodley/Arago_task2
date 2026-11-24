import sys; import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, itertools
import validate_shared_tree as M   # reuses ref(), pack(), corner sets; re-runs model checks on import

def raw_tree(v64, mode):
    is8, is16, isbf = mode==0, mode!=0, mode==2
    by = [((v64 >> np.uint64(8*i)) & np.uint64(0xFF)).astype(np.int32) for i in range(8)]
    def hi_slice(a, b):   # 7-bit unsigned magnitude on bits [6:0] of the byte + sign rule
        return (a & 0x7F) > (b & 0x7F), (a & 0x7F) == (b & 0x7F)
    def lo_slice(a, b):   # 8-bit unsigned, MSB xored with is_int8 (comparator input only)
        f = 0x80 if is8 else 0
        return (a ^ f) > (b ^ f)
    def node(lo_a, lo_b, hi_a, hi_b):
        sa, sb = (hi_a >> 7) & 1, (hi_b >> 7) & 1
        ghi7, ehi7 = hi_slice(hi_a, hi_b)
        glo = lo_slice(lo_a, lo_b)
        if is16:
            mag = ghi7 | (ehi7 & glo)
            same = np.where(isbf & (sa == 1), ~mag, mag)
            pick = np.where(sa != sb, sa == 0, same)
            sel_lo = sel_hi = pick
        else:                       # INT8: hi byte is its own lane -> sign rule on 7-bit compare
            sel_hi = np.where(sa != sb, sa == 0, ghi7)
            sel_lo = glo
        return np.where(sel_lo, lo_a, lo_b), np.where(sel_hi, hi_a, hi_b)
    s0, s1 = node(by[0], by[2], by[1], by[3])
    s4, s5 = node(by[4], by[6], by[5], by[7])
    t0, t1 = node(s0, s4, s1, s5)
    if is8:
        g = (t0 ^ 0x80) > (t1 ^ 0x80)
        r = np.where(g, t0, t1); r = np.where(r & 0x80, r | 0xFF00, r)
    else:
        r = (t1 << 8) | t0
        if isbf:
            anynan = np.zeros(r.shape, bool)
            for l in range(4):
                lane = (v64 >> np.uint64(16*l)) & np.uint64(0xFFFF)
                anynan |= ((lane & np.uint64(0x7F80)) == np.uint64(0x7F80)) & ((lane & np.uint64(0x7F)) != 0)
            r = np.where(anynan, 0x7FC0, r)
    return r.astype(np.uint16)

rng = np.random.default_rng(7); total = 0
for mode in range(3):
    v = rng.integers(0, 2**63, size=200000, dtype=np.uint64)*np.uint64(2) + rng.integers(0,2,200000,dtype=np.uint64)
    assert np.array_equal(raw_tree(v, mode), M.ref(v, mode)), mode; total += len(v)
for mode, cs, n, w in [(0, M.c8, 8, 8), (1, M.c16, 4, 16), (2, M.cbf, 4, 16)]:
    v = M.pack(np.array(list(itertools.product(cs, repeat=n)), dtype=np.uint64), w)
    assert np.array_equal(raw_tree(v, mode), M.ref(v, mode)), mode; total += len(v)
# also: every BF16 non-NaN pair, 2 lanes varying (others = -inf), sampled 2M pairs
a = rng.integers(0, 65536, 2_000_000, dtype=np.uint64); b = rng.integers(0, 65536, 2_000_000, dtype=np.uint64)
fill = np.uint64(0xFF80)
v = a | (b << np.uint64(16)) | (fill << np.uint64(32)) | (fill << np.uint64(48))
# compare with key-based model (already validated against ref) to avoid slow python ref
assert np.array_equal(raw_tree(v, 2), M.shared_tree(v, 2)); total += len(v)
print("RAW-BITS design: all checks pass, vectors:", total)
# without NaN override, does it still need one?
