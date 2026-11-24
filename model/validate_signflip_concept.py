# Concept: invert the sign bit (comparator inputs only), then do a plain unsigned compare.
import numpy as np, struct
rng = np.random.default_rng(3)
def flip_cmp(a, b, w):            # pick A if (a ^ MSB) > (b ^ MSB), unsigned
    m = 1 << (w - 1); return (a ^ m) > (b ^ m)

# INT8: exhaustive, all 65,536 pairs
a, b = np.meshgrid(np.arange(256), np.arange(256)); a, b = a.ravel(), b.ravel()
sa, sb = np.where(a > 127, a - 256, a), np.where(b > 127, b - 256, b)
print("INT8 exhaustive pairs:", a.size, "wrong:", int(np.sum(flip_cmp(a, b, 8) != (sa > sb))))

# INT16: all pairs where one operand sweeps all 65,536 values against 2,000 random others (131M pairs)
x = np.arange(65536, dtype=np.int64); sx = np.where(x > 32767, x - 65536, x); wrong = 0; n = 0
for y in rng.integers(0, 65536, 2000):
    sy = y - 65536 if y > 32767 else y
    wrong += int(np.sum(flip_cmp(x, y, 16) != (sx > sy))); n += x.size
print("INT16 pairs:", n, "wrong:", wrong)

# BF16: all 65,536 patterns vs 2,000 random others, NaNs excluded
f = np.frombuffer((np.arange(65536, dtype=np.uint32) << 16).tobytes(), np.float32)
ok = ~np.isnan(f); wrong = 0; n = 0; cats = {"both positive": [0, 0], "signs differ": [0, 0], "both negative": [0, 0]}
for y in rng.integers(0, 65536, 2000):
    if np.isnan(f[y]): continue
    pick = flip_cmp(x, y, 16)
    truth = f > f[y]; eq = f == f[y]
    bad = (pick != truth) & ~eq & ok                      # ties (incl. +0/-0) value-identical or excluded
    neg_x = x >= 0x8000; neg_y = y >= 0x8000
    for k, m in [("both positive", ~neg_x & (not neg_y)), ("signs differ", neg_x != neg_y), ("both negative", neg_x & neg_y)]:
        cats[k][0] += int(np.sum(m & ok & ~eq)); cats[k][1] += int(np.sum(bad & m))
for k, (tot, bd) in cats.items(): print(f"BF16 {k}: pairs {tot}, wrong {bd} ({100*bd/max(tot,1):.1f}%)")
