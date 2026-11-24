#!/usr/bin/env python3
"""Generate golden test vectors for vec_max_alu from the validated bit-accurate model.

Each output line is 21 hex digits: {4'mode, 64'in_vec, 16'expected}.
Expected values come from validate_shared_tree.ref() (plain Python max with
IEEE 754-2019 'maximum' semantics), which is independent of the hardware algorithm.
Usage: python3 scripts/gen_vectors.py [out_file]
"""
import sys, os, itertools, random, struct

def bf_val(h):
    return struct.unpack('>f', struct.pack('>I', h << 16))[0]

def ref(mode, v):
    if mode == 0:
        lanes = [(v >> 8*i) & 0xFF for i in range(8)]
        lanes = [x - 256 if x > 127 else x for x in lanes]
        return max(lanes) & 0xFF          # INT8: upper byte discarded by spec, driven to zero
    lanes = [(v >> 16*i) & 0xFFFF for i in range(4)]
    if mode in (1, 3):
        s = [x - 65536 if x > 32767 else x for x in lanes]
        return max(s) & 0xFFFF
    fs = [bf_val(x) for x in lanes]
    if any(f != f for f in fs):
        return 0x7FC0
    best = 0
    for i in range(1, 4):
        if fs[i] > fs[best] or (fs[i] == fs[best] and (lanes[best] & 0x8000) and not (lanes[i] & 0x8000)):
            best = i
    return lanes[best]

def pack(lanes, w):
    v = 0
    for i, x in enumerate(lanes):
        v |= (x & ((1 << w) - 1)) << (w * i)
    return v

rng = random.Random(2026)
vecs = []   # (mode, v)

# 1. Lane-unique max in every position (catches pairing / wiring errors)
for lo, hi in [(0x00, 0x7F), (0x80, 0x01), (0xFF, 0x00), (0x80, 0xFF), (0x10, 0x11)]:
    for i in range(8):
        vecs.append((0, pack([hi if k == i else lo for k in range(8)], 8)))
for lo, hi in [(0x8000, 0x7FFF), (0x00FF, 0x0100), (0xFFFF, 0x0000), (0x8000, 0xFFFF), (0x1234, 0x1235)]:
    for i in range(4):
        vecs.append((1, pack([hi if k == i else lo for k in range(4)], 16)))
for lo, hi in [(0xFF80, 0x7F80), (0xBF80, 0x3F80), (0xBFC0, 0xBF80), (0x8000, 0x0000), (0x8001, 0x8000), (0x4020, 0x4021)]:
    for i in range(4):
        vecs.append((2, pack([hi if k == i else lo for k in range(4)], 16)))

# 2. NaN in each lane, each sign, with various companions
for nan in (0x7FC0, 0xFFC0, 0x7F81, 0xFF81, 0x7FFF):
    for i in range(4):
        for other in (0x7F80, 0xFF80, 0x3F80, 0x0000):
            vecs.append((2, pack([nan if k == i else other for k in range(4)], 16)))
vecs.append((2, pack([0x7FC0, 0xFFC0, 0x7F81, 0xFFFF], 16)))

# 2b. Directed cases from the external audit (also covered by the exhaustive sets, listed for traceability)
audit_bf = [
    [0xC120, 0xC000, 0xC120, 0xC000],   # -10.0 vs -2.0: negatives, different high bytes
    [0xC080, 0xC040, 0xC080, 0xC040],   # -4.0 vs -3.0: same high byte, chain under inv_neg
    [0xC000, 0xC000, 0xC000, 0xC000],   # equal negatives: tie under the flip
    [0x8000, 0x8000, 0x8000, 0x8000],   # all -0 -> -0
    [0x0001, 0x0000, 0x0001, 0x0000],   # smallest positive subnormal vs +0
    [0x7F80, 0x7F7F, 0xFF80, 0xFF7F],   # +Inf vs +max, -Inf vs -max
]
for t in audit_bf:
    vecs.append((2, pack(t, 16)))
for perm in set(itertools.permutations([0x8000, 0x8000, 0x8000, 0x0000])):   # +0 in each lane wins
    vecs.append((2, pack(perm, 16)))
for perm in itertools.permutations([0x8001, 0x8000, 0x807F, 0x80FF]):        # negative subnormals vs -0
    vecs.append((2, pack(perm, 16)))
for nan in (0x7FC0, 0x7F81, 0xFFC0, 0xFF81):                                   # every NaN with +-Inf, every lane
    for inf in (0x7F80, 0xFF80):
        for i in range(4):
            vecs.append((2, pack([nan if k == i else inf for k in range(4)], 16)))
audit_i16 = [[0x0180, 0x0101, 0x0180, 0x0101],   # +384 vs +257: low byte has bit 7 set
             [0xFF80, 0xFF01, 0xFF80, 0xFF01],   # -128 vs -255: low byte must compare unsigned
             [0x8000, 0x7FFF, 0x8000, 0x7FFF]]   # -32768 vs +32767
for t in audit_i16:
    vecs.append((1, pack(t, 16)))
for t in ([0x80] * 8, [0x80, 0x7F] * 4, [0xFF, 0x00] * 4):                     # INT8 extremes
    vecs.append((0, pack(t, 8)))

# 3. Same bit pattern in every mode on consecutive cycles (mode travels with data)
for _ in range(50):
    v = rng.getrandbits(64)
    for m in (0, 2, 1, 3, 0):
        vecs.append((m, v))

# 4. Exhaustive corner combinations (sampled where too large)
c8 = [0x00, 0x01, 0x7F, 0x80, 0x81, 0xFF]
c16 = [0x0000, 0x0001, 0x00FF, 0x0100, 0x7FFF, 0x8000, 0x8001, 0xFF00, 0xFFFF, 0x7F00, 0x80FF]
cbf = [0x0000, 0x8000, 0x0001, 0x8001, 0x007F, 0x0080, 0x3F80, 0xBF80, 0xBFC0, 0x7F7F, 0xFF7F,
       0x7F80, 0xFF80, 0x7FC0, 0xFFC0, 0x7F81]
all8 = list(itertools.product(c8, repeat=8))
vecs += [(0, pack(t, 8)) for t in rng.sample(all8, 20000)]
vecs += [(1, pack(t, 16)) for t in itertools.product(c16, repeat=4)]          # 14,641
vecs += [(2, pack(t, 16)) for t in itertools.product(cbf, repeat=4)]          # 65,536

# 5. Random, biased toward corner bytes
def biased(w):
    corners = c8 if w == 8 else cbf + c16
    return rng.choice(corners) if rng.random() < 0.25 else rng.getrandbits(w)
for _ in range(40000):
    m = rng.choice((0, 1, 2))
    vecs.append((m, pack([biased(8) for _ in range(8)], 8) if m == 0 else pack([biased(16) for _ in range(4)], 16)))
for _ in range(20000):
    vecs.append((rng.choice((0, 1, 2)), rng.getrandbits(64)))

# Mode 11 (undefined): a few, expected to behave as INT16
for _ in range(20):
    vecs.append((3, rng.getrandbits(64)))

# Keep the directed block first, shuffle the rest so modes change every cycle
head, tail = vecs[:400], vecs[400:]
rng.shuffle(tail)
vecs = head + tail

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', 'tb', 'vectors.hex')
with open(out, 'w') as f:
    for m, v in vecs:
        f.write(f"{m:01X}{v:016X}{ref(m, v):04X}\n")
print(f"wrote {len(vecs)} vectors to {out}")
