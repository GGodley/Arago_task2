import numpy as np, itertools, struct
rng = np.random.default_rng(1)

# ---------- 1. BF16 order-preserving key: exhaustive over all 65536 patterns ----------
def bf16_to_f(x):  # bf16 bit pattern -> float value (via float32 upper half)
    return np.frombuffer((x.astype(np.uint32) << 16).astype(np.uint32).tobytes(), dtype=np.float32)
def key(x):        # signed-int key: negatives get magnitude bits inverted
    x = x.astype(np.uint16)
    return np.where(x & 0x8000, x ^ 0x7FFF, x).astype(np.uint16).view(np.int16)
allp = np.arange(65536, dtype=np.uint16)
vals = bf16_to_f(allp); k = key(allp)
isnan = np.isnan(vals)
order = np.argsort(k[~isnan], kind='stable')
v_sorted = vals[~isnan][order]
assert np.all(np.diff(v_sorted) >= 0), "key not monotonic"
# strictness: equal keys never map distinct floats; distinct floats -> distinct keys
assert len(np.unique(k)) == 65536
print("key monotonic over", (~isnan).sum(), "non-NaN bf16 patterns; only tie is +0/-0 ->",
      "key(-0)=%d < key(+0)=%d" % (k[0x8000], k[0x0000]))
assert np.all((key(key(allp).view(np.uint16)).view(np.uint16)) == allp), "inverse != forward"
print("key transform is an involution (same XOR undoes it)")

# ---------- 2. Byte-sliced shared tree model ----------
def slice_cmp(a, b, signed):
    """8-bit comparator slice: returns (gt, eq). signed: bool array or scalar."""
    a = a.astype(np.int32); b = b.astype(np.int32)
    sa = np.where(signed, (a ^ 0x80), a); sb = np.where(signed, (b ^ 0x80), b)  # signed via MSB flip
    return sa > sb, a == b

def shared_tree(v64, mode):
    """mode 0=INT8, 1=INT16, 2=BF16. v64: uint64 array. returns uint16 array."""
    by = [((v64 >> np.uint64(8*i)) & np.uint64(0xFF)).astype(np.int32) for i in range(8)]
    if mode == 2:   # pre-transform each 16-bit lane: negatives XOR 0x7FFF
        for l in range(4):
            neg = (by[2*l+1] & 0x80) != 0
            by[2*l]   = np.where(neg, by[2*l]   ^ 0xFF, by[2*l])
            by[2*l+1] = np.where(neg, by[2*l+1] ^ 0x7F, by[2*l+1])
    m16 = mode != 0
    def level(lo_a, lo_b, hi_a, hi_b):
        # lo slice signed only in INT8 mode; hi slice always signed
        glo, elo = slice_cmp(lo_a, lo_b, not m16)
        ghi, ehi = slice_cmp(hi_a, hi_b, True)
        if m16:
            g = ghi | (ehi & glo); sel_lo = sel_hi = g
        else:
            sel_lo, sel_hi = glo, ghi
        return np.where(sel_lo, lo_a, lo_b), np.where(sel_hi, hi_a, hi_b)
    s0, s1 = level(by[0], by[2], by[1], by[3])     # L1, slices 0,1
    s4, s5 = level(by[4], by[6], by[5], by[7])     # L1, slices 2,3
    t0, t1 = level(s0, s4, s1, s5)                 # L2, slices 4,5
    if mode == 0:
        g, _ = slice_cmp(t0, t1, True)             # L3, slice 6 (INT8 only)
        r = np.where(g, t0, t1)
        r = np.where(r & 0x80, r | 0xFF00, r)      # sign-extend (upper byte is don't-care per spec)
    else:
        r = (t1 << 8) | t0
        if mode == 2:
            neg = (r & 0x8000) != 0
            r = np.where(neg, r ^ 0x7FFF, r)
            # NaN override: any lane NaN -> canonical qNaN 0x7FC0 (computed from raw input, parallel path)
            anynan = np.zeros_like(r, dtype=bool)
            for l in range(4):
                lane = (v64 >> np.uint64(16*l)) & np.uint64(0xFFFF)
                anynan |= ((lane & np.uint64(0x7F80)) == np.uint64(0x7F80)) & ((lane & np.uint64(0x7F)) != 0)
            r = np.where(anynan, 0x7FC0, r)
    return r.astype(np.uint16)

def ref(v64, mode):
    out = []
    for v in v64.tolist():
        if mode == 0:
            lanes = [((v >> 8*i) & 0xFF) for i in range(8)]; lanes = [x-256 if x>127 else x for x in lanes]
            out.append(max(lanes) & 0xFFFF)
        elif mode == 1:
            lanes = [((v >> 16*i) & 0xFFFF) for i in range(4)]; lanes = [x-65536 if x>32767 else x for x in lanes]
            out.append(max(lanes) & 0xFFFF)
        else:
            lanes = [((v >> 16*i) & 0xFFFF) for i in range(4)]
            fs = [struct.unpack('>f', struct.pack('>I', x << 16))[0] for x in lanes]
            if any(f != f for f in fs): out.append(0x7FC0); continue
            # IEEE 754-2019 maximum: -0 < +0
            best = max(range(4), key=lambda i: (fs[i], 0 if lanes[i] & 0x8000 else 1))
            out.append(lanes[best])
    return np.array(out, dtype=np.uint16)

def pack(lanes, w):
    v = np.zeros(lanes.shape[0], dtype=np.uint64)
    for i in range(lanes.shape[1]): v |= (lanes[:, i].astype(np.uint64) & np.uint64((1<<w)-1)) << np.uint64(w*i)
    return v

total = 0
# random
for mode in range(3):
    v = rng.integers(0, 2**63, size=200000, dtype=np.uint64) * np.uint64(2) + rng.integers(0, 2, 200000, dtype=np.uint64)
    assert np.array_equal(shared_tree(v, mode), ref(v, mode)), mode; total += len(v)
# exhaustive over corner sets
c8  = np.array([0x00,0x01,0x7F,0x80,0x81,0xFF], dtype=np.uint64)
c16 = np.array([0x0000,0x0001,0x00FF,0x0100,0x7FFF,0x8000,0x8001,0xFF00,0xFFFF,0x7F00,0x80FF], dtype=np.uint64)
cbf = np.array([0x0000,0x8000,0x0001,0x8001,0x007F,0x0080,0x3F80,0xBF80,0x7F7F,0xFF7F,0x7F80,0xFF80,0x7FC0,0xFFC0,0x7F81], dtype=np.uint64)
for mode, cs, n, w in [(0, c8, 8, 8), (1, c16, 4, 16), (2, cbf, 4, 16)]:
    lanes = np.array(list(itertools.product(cs, repeat=n)), dtype=np.uint64)
    v = pack(lanes, w)
    assert np.array_equal(shared_tree(v, mode), ref(v, mode)), mode; total += len(v)
    print("mode", ["INT8","INT16","BF16"][mode], "exhaustive corner combos:", len(v), "OK")
print("total vectors checked:", total)
