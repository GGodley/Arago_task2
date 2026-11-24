# Arago Task 2: reconfigurable vector max ALU

One 64-bit input, read as 8 x INT8, 4 x INT16 or 4 x BF16, gives the 16-bit maximum.
Throughput is one vector per cycle.

## Layout
- `rtl/cmp_slice.sv`: the single comparator block used for all seven slices (S0..S6)
- `rtl/vec_max_alu.sv`: top level, 3-level comparator tree, NaN side path, `PIPE` parameter (0, 1, 2)
- `tb/tb_vec_max_alu.sv`: self-checking testbench (golden vectors + independent SV reference model)
- `tb/vectors.hex`: 160,612 golden vectors (`{mode, in_vec, expected}`)
- `scripts/gen_vectors.py`: regenerates `tb/vectors.hex`
- `scripts/run_sim.sh`: compiles and runs the testbench for PIPE = 0, 1, 2
- `model/`: bit-accurate Python models used to validate the architecture before RTL (NumPy). `validate_signflip_slice.py` matches the RTL; the others are the alternatives evaluated (XOR-key, dual-polarity select, unified slice)

## Status
First RTL version. Python models pass 4.34M vectors; the RTL testbench has not been run yet.

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
| `result` | 16 | Max. INT8 result sign-extended. BF16: any NaN gives 16'h7FC0, -0 < +0 |
