# Arago Task 2: reconfigurable vector max ALU

One 64-bit input, read as 8 x INT8, 4 x INT16 or 4 x BF16, gives the 16-bit maximum.
Throughput is one vector per cycle.

## Layout
- `rtl/cmp_slice.sv`: the single comparator block used for all seven slices (S0..S6)
- `rtl/vec_max_alu.sv`: top level, 3-level comparator tree, NaN side path, `PIPE` parameter (0, 1, 2)
- `tb/tb_vec_max_alu.sv`: self-checking testbench (golden vectors + independent SV reference model)
- `tb/vectors.hex`: 160,684 golden vectors (`{mode, in_vec, expected}`)
- `scripts/gen_vectors.py`: regenerates `tb/vectors.hex`
- `scripts/run_sim.sh`: compiles and runs the testbench for PIPE = 0, 1, 2
- `rtl_verilog/`: plain Verilog-2001 port of the RTL (same ports, `PIPE`, slice reuse); header comments map each SV construct to Verilog
- `scripts/run_sim_verilog.sh`: runs the same testbench on the Verilog port (also compiles it alone with `-g2001`)
- `scripts/check_equiv.sh` + `tb/tb_equiv_sv_vs_v.sv`: runs SV and Verilog side by side and checks outputs match every cycle
- `model/`: bit-accurate Python models used to validate the architecture before RTL (NumPy). `validate_signflip_slice.py` matches the RTL; the others are the alternatives evaluated (XOR-key, dual-polarity select, unified slice)

## Status
Audit-fix revision (see below). Icarus Verilog 12: TEST PASSED for PIPE = 0, 1 and 2 (260,734 to 260,735 results each, 0 errors, 0 golden/reference mismatches, no coverage holes). Verilator 5.020 `-Wall` lint and full build: clean for PIPE = 0, 1, 2. Yosys 0.33 `check` (hierarchical and flattened): 0 problems; generic synthesis gives 586, 588 and 573 cells (84, 103 and 139 flops) for PIPE = 0, 1 and 2. PIPE outside 0..2 stops elaboration. The `$readmemh` "Not enough words" warning is expected: the vector memory is sized larger than the file.

## Run (Icarus Verilog 12 or newer)
```
./scripts/run_sim.sh          # all three PIPE values
./scripts/run_sim.sh 1        # one PIPE value
VCD=1 ./scripts/run_sim.sh 1  # also writes build/wave.vcd (first 2000 cycles)
```
Each run ends with `TEST PASSED (PIPE=n)` or `TEST FAILED (PIPE=n)`. Logs are in `build/`.

## Interface
| Port | Width | Meaning |
|---|---|---|
| `clk`, `rst_n` | 1 | Clock, active-low async reset (resets valid bits only) |
| `in_valid` | 1 | Input vector valid |
| `mode` | 2 | 00 INT8, 01 INT16, 10 BF16 (11 behaves as INT16) |
| `in_vec` | 64 | INT8 byte i = `in_vec[8i+7:8i]`, 16-bit lane j = `in_vec[16j+15:16j]` |
| `out_valid` | 1 | Result valid, PIPE + 2 clock edges after the input is sampled |
| `result` | 16 | Max. INT8: max in `result[7:0]`, upper byte zero (the spec discards it). BF16: any NaN gives 16'h7FC0, -0 < +0 |

## Changes after the external audit
Adopted:
- NaN flag gated by BF16 mode before the first register, so the `bf` flop after L2 is gone and the NaN flops stay quiet in INT8/INT16.
- INT8 result zero-extended instead of sign-extended (spec discards the upper byte): fewer loads on the INT8 path, less toggling.
- Elaboration-time guard on `PIPE`; unused `pk6` removed; named mode constants; byte and lane array views instead of `-:` part-selects; stage-indexed signal names (`s0_*`, `s1_*`, `s2_*`, `l1_*`, `l2_*`, `l3_*`); one-line proofs in `cmp_slice` for the tie case and -0/+0; comment explaining why a slice pair is not a combinational loop.
- `timescale removed from the RTL; the build sets it (the testbench is compiled first).
- Testbench: extra directed BF16/INT16/INT8 cases from the audit, unknown (X) values driven on `in_vec`/`mode` during idle cycles, and an assertion that `result` is never unknown when `out_valid` is high.

Kept, with reasons in the RTL header: the PIPE = 1 cut after L2 (same fmax as after L1, fewer flops), the input register (clean timing boundary at the start of the critical path), and the comparator mux inside `cmp_slice` (Verilator and Yosys find no loop). Not adopted: operand isolation on S6 (it would put a gate on the last stage's INT8 path) and an assertion on mode 11 (a legal input, defined as INT16).
