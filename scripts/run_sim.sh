#!/usr/bin/env bash
# Compile and run the testbench for PIPE = 0, 1 and 2 with Icarus Verilog (>= 12).
# Usage: ./scripts/run_sim.sh            (all three)
#        ./scripts/run_sim.sh 1          (one PIPE value)
#        VCD=1 ./scripts/run_sim.sh 1    (also dump build/wave.vcd, first 2000 cycles)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
PIPES=${1:-"0 1 2"}
EXTRA=""
[ "${VCD:-0}" = "1" ] && EXTRA="+VCD"
status=0
for P in $PIPES; do
    echo "=== PIPE=$P ==="
    # The testbench is listed first: its `timescale applies to the RTL files that follow,
    # so the timescale is owned by the build, not hard-coded in the RTL.
    iverilog -g2012 -Wall -Wno-timescale -o "build/sim_p$P" -P "tb_vec_max_alu.PIPE=$P" \
        tb/tb_vec_max_alu.sv rtl/cmp_slice.sv rtl/vec_max_alu.sv
    vvp -n "build/sim_p$P" +VECTORS=tb/vectors.hex $EXTRA | tee "build/sim_p$P.log"
    if ! grep -q "TEST PASSED" "build/sim_p$P.log"; then status=1; fi
done
if [ $status -eq 0 ]; then echo "ALL CONFIGURATIONS PASSED"; else echo "SOME CONFIGURATIONS FAILED"; fi
exit $status
