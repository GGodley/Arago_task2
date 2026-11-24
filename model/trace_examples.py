import struct, math
def bf(x):  # float -> bf16 (round to nearest even)
    u = struct.unpack('>I', struct.pack('>f', x))[0]
    if math.isnan(x): return 0x7FC0
    return ((u + 0x7FFF + ((u >> 16) & 1)) >> 16) & 0xFFFF
def bfv(h): return struct.unpack('>f', struct.pack('>I', h << 16))[0]
def s8(x): return x-256 if x>127 else x
def s16(x): return x-65536 if x>32767 else x

def node(name, lo_a, lo_b, hi_a, hi_b, mode, show):
    is8, isbf = mode=='INT8', mode=='BF16'
    sa, sb = hi_a>>7, hi_b>>7
    g7, e7 = (hi_a&0x7F)>(hi_b&0x7F), (hi_a&0x7F)==(hi_b&0x7F)
    f = 0x80 if is8 else 0
    glo = (lo_a^f) > (lo_b^f)
    if not is8:
        mag = g7 or (e7 and glo)
        if sa != sb: pick, why = sa==0, "signs differ -> positive"
        elif isbf and sa: pick, why = not mag, f"both negative BF16 -> invert: mag_gt={int(mag)} -> pick_A={int(not mag)}"
        else: pick, why = mag, f"same sign: gt_hi7={int(g7)} eq_hi7={int(e7)} gt_lo8={int(glo)} -> mag_gt={int(mag)}"
        A, B = (hi_a<<8)|lo_a, (hi_b<<8)|lo_b
        show(f"  {name}: A=0x{A:04X}({show.fmt(A)}) vs B=0x{B:04X}({show.fmt(B)}): {why} -> {'A' if pick else 'B'}")
        return (lo_a, hi_a) if pick else (lo_b, hi_b)
    else:
        ph = (sa==0) if sa!=sb else g7
        show(f"  {name}-lo: {s8(lo_a)} vs {s8(lo_b)}: bit7 flipped -> 0x{lo_a^0x80:02X} vs 0x{lo_b^0x80:02X} unsigned -> {s8(lo_a if glo else lo_b)}")
        show(f"  {name}-hi: {s8(hi_a)} vs {s8(hi_b)}: " + ("signs differ -> positive" if sa!=sb else f"same sign, 7-bit {hi_a&0x7F} vs {hi_b&0x7F}") + f" -> {s8(hi_a if ph else hi_b)}")
        return (lo_a if glo else lo_b), (hi_a if ph else hi_b)

def run(mode, vals, title):
    out=[]; show=lambda s: out.append(s)
    if mode=='INT8': raw=[v&0xFF for v in vals]; show.fmt=lambda x:x
    else:
        raw=[bf(v) if mode=='BF16' else v&0xFFFF for v in vals]
        show.fmt=(lambda x: f"{bfv(x):g}") if mode=='BF16' else (lambda x: s16(x))
    by=[]
    if mode=='INT8': by=raw
    else:
        for r in raw: by += [r&0xFF, r>>8]
    out.append(f"== {title} [{mode}] lanes={vals} bytes=" + " ".join(f"{b:02X}" for b in by))
    s0,s1 = node("L1 S0/S1", by[0],by[2],by[1],by[3],mode,show)
    s4,s5 = node("L1 S2/S3", by[4],by[6],by[5],by[7],mode,show)
    t0,t1 = node("L2 S4/S5", s0,s4,s1,s5,mode,show)
    if mode=='INT8':
        r = t0 if (t0^0x80)>(t1^0x80) else t1
        out.append(f"  L3 S6: {s8(t0)} vs {s8(t1)} -> {s8(r)}   result=0x{(r|0xFF00) if r&0x80 else r:04X}  python max={max(vals)}")
    else:
        r=(t1<<8)|t0
        nan = mode=='BF16' and any(((x>>7)&0xFF)==0xFF and (x&0x7F) for x in raw)
        if nan: out.append(f"  tree winner 0x{r:04X}; NaN flag set -> result=0x7FC0 (NaN)")
        else: out.append(f"  result=0x{r:04X} ({show.fmt(r)})")
    print("\n".join(out)); print()

run('INT8', [23,-5,88,-128,88,17,-1,64], "Quantized activations (tie + -128)")
run('INT8', [-7,-3,-128,-100,-64,-9,-2,-50], "All-negative INT8")
run('INT16', [4660,4848,-2,-300], "Accumulators, hi-byte tie")
run('INT16', [-32768,-1,-32767,-256], "INT16 extremes")
run('BF16', [2.5,-1.0,2.484375,-3.0], "Attention scores, close values")
run('BF16', [-0.693,-2.30,-0.105,-4.6], "Log-probabilities, all negative")
run('BF16', [-0.0,0.0,-1e-39,float('-inf')], "Signed zeros, subnormal, -inf")
run('BF16', [1.0,-float('nan'),0.5,3.0], "Negative NaN in the vector")
