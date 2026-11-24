# One identical cmp_slice used for S0..S6. Validated against the same reference as the other models.
import sys, os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, itertools
import validate_shared_tree as M


EQ = {}
def cmp_slice(a, b, is_signed, chain_en, gt_in, inv_neg, use_ext_sel, ext_sel, eq_in=None):
    f = 0x80 if is_signed else 0
    gt8 = (a ^ f) > (b ^ f); eq8 = a == b
    full = gt8 | (eq8 & (gt_in & chain_en))
    eqf = eq8 & (eq_in if (chain_en is True or (isinstance(chain_en,bool) and chain_en)) and eq_in is not None else True)
    both_neg = (((a >> 7) & 1) == 1) & (((b >> 7) & 1) == 1)
    lt = ~full & ~eqf
    pick = np.where(inv_neg & both_neg, lt, full)
    sel = np.where(use_ext_sel, ext_sel, pick)
    return np.where(sel, a, b), pick

def tree(v64, mode):
    i8, bf = mode == 0, mode == 2
    by = [((v64 >> np.uint64(8*i)) & np.uint64(0xFF)).astype(np.int32) for i in range(8)]
    z = np.zeros(v64.shape, bool)
    def pair(la, lb, ha, hb):
        # low-position slice: compare first (its pick feeds the high slice's chain input)
        _, plo = cmp_slice(la, lb, int(i8), False, z, False, False, z)
        yh, phi = cmp_slice(ha, hb, 1, not i8, plo, bf, False, z, eq_in=(la == lb))
        yl, _ = cmp_slice(la, lb, int(i8), False, z, False, not i8, phi)   # same instance; its mux takes ext_sel in 16-bit modes
        return yl, yh
    s0, s1 = pair(by[0], by[2], by[1], by[3])
    s4, s5 = pair(by[4], by[6], by[5], by[7])
    t0, t1 = pair(s0, s4, s1, s5)
    if i8:
        r, _ = cmp_slice(t0, t1, 1, False, z, False, False, z)   # S6
        r = np.where(r & 0x80, r | 0xFF00, r)
    else:
        r = (t1 << 8) | t0
        if bf:
            nan = np.zeros(r.shape, bool)
            for l in range(4):
                lane = (v64 >> np.uint64(16*l)) & np.uint64(0xFFFF)
                nan |= ((lane & np.uint64(0x7F80)) == np.uint64(0x7F80)) & ((lane & np.uint64(0x7F)) != 0)
            r = np.where(nan, 0x7FC0, r)
    return r.astype(np.uint16)

rng = np.random.default_rng(11); total = 0
for mode in range(3):
    v = rng.integers(0, 2**63, 200000, dtype=np.uint64)*np.uint64(2) + rng.integers(0, 2, 200000, dtype=np.uint64)
    assert np.array_equal(tree(v, mode), M.ref(v, mode)), mode; total += len(v)
for mode, cs, n, w in [(0, M.c8, 8, 8), (1, M.c16, 4, 16), (2, M.cbf, 4, 16)]:
    v = M.pack(np.array(list(itertools.product(cs, repeat=n)), dtype=np.uint64), w)
    assert np.array_equal(tree(v, mode), M.ref(v, mode)), mode; total += len(v)
a = rng.integers(0, 65536, 2_000_000, dtype=np.uint64); b = rng.integers(0, 65536, 2_000_000, dtype=np.uint64)
v = a | (b << np.uint64(16)) | (np.uint64(0xFF80) << np.uint64(32)) | (np.uint64(0xFF80) << np.uint64(48))
assert np.array_equal(tree(v, 2), M.shared_tree(v, 2)); total += len(v)
print("OPTION C dual-polarity select: all checks pass, vectors:", total)
