# Verilog-2001 version of the vector max ALU

This folder is a Verilog-2001 port of the SystemVerilog design in `rtl/` and `tb/`.
It behaves the same, cycle for cycle. File names, module names, ports, the `PIPE`
parameter, signal names and the comments all follow the SV originals, so the two can
be read side by side. The SV files are unchanged.

| SystemVerilog | Verilog-2001 |
|---|---|
| `rtl/cmp_slice.sv` | `verilog/rtl/cmp_slice.v` |
| `rtl/vec_max_alu.sv` | `verilog/rtl/vec_max_alu.v` |
| `tb/tb_vec_max_alu.sv` | `verilog/tb/tb_vec_max_alu.v` |
| (none) | `verilog/tb/tb_equiv.v`: runs SV and Verilog side by side and compares them |

## What changed in the translation

The design uses only a few SystemVerilog features. Each one is marked `[SV]` in
`vec_max_alu.v`.

| SystemVerilog | Verilog-2001 | Where |
|---|---|---|
| `logic` driven by `assign` or a module output | `wire` | everywhere |
| `logic` assigned in an `always` block | `reg` | flops, `nan_0` |
| `output logic` that is a flop | `output reg` | `out_valid`, `result` |
| `parameter int PIPE = 1` | `parameter PIPE = 1` | top |
| `always_ff @(posedge clk ...)` | `always @(posedge clk ...)`, still with `<=` | all flops |
| `always_comb` | `always @(*)`, still with `=` | NaN side path |
| `for (int j = 0; j < 4; j++)` | `integer j;` declared outside, `j = j + 1` | NaN loop |
| `for (p = 0; p < 2; p++)` in a generate | `p = p + 1` | level 1 generate |
| one `logic` driven by a flop in one generate branch and by `assign` in the other | the signal is a `wire`; the flop branch has local `reg`s (`v1_r`, `m1_r`, ...) that drive it | the optional `PIPE` registers after L1 and L2 |
| `$urandom` (testbench) | `{$random}` (braces make the signed result unsigned, so `% N` is never negative) | testbench only |

The last RTL row is the only one that needs any thought. In SystemVerilog, `logic`
does not care whether it is driven procedurally or continuously, so `v1` can be a
flop when `PIPE >= 2` and a plain wire otherwise. In Verilog a signal is either a
`reg` or a `wire`. The stage outputs (`v1, i8_1, bf_1, nan_1, m1` and
`v2, i8_2, bf_2, nan_2, t0_2, t1_2`) are wires, and inside the `PIPE` branch a set of
`*_r` regs holds the flops and drives those wires. The hardware is the same.

`-:` and `+:` part selects, `genvar`/`generate`, ANSI port lists, `localparam`,
automatic functions and tasks, `$value$plusargs` and `**` are all Verilog-2001, so
they are unchanged.

## How it was checked

`./scripts/run_sim_verilog.sh` (Icarus Verilog 12 or newer) runs, for PIPE = 0, 1 and 2:

1. **Verilog RTL + Verilog testbench**, compiled with `iverilog -g2001` (strict
   Verilog-2001). This proves the port contains no SystemVerilog.
2. **Verilog RTL + the original SV testbench**, compiled with `-g2012`. The Verilog
   design passes exactly the same testbench as the SV design: 160,612 golden vectors,
   100,000 random vectors, latency, throughput, valid gaps and mid-stream reset.
3. **Lockstep equivalence** (`tb_equiv.v`): the SV design (modules renamed to `*_sv`)
   and the Verilog design get the same random stimulus for 2,000,000 cycles, across
   all four modes, random valid gaps and random resets, with NaN, ±0, infinity and
   tie values made common. `out_valid` and `result` must match on every edge, bit
   for bit including X (`!==`).

Results (Icarus Verilog 12.0): all three checks pass for every PIPE value with 0
errors. The lockstep check compares about 1.75 million valid outputs per PIPE value.
As a sanity check, changing the NaN constant in the Verilog copy by one bit makes the
lockstep check fail.
