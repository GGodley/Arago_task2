#!/usr/bin/env bash
# Same as run_sim.sh, but the DUT is the Verilog-2001 port in rtl_verilog/.
# Step 1 compiles the DUT alone with -g2001 (proves it is plain Verilog-2001).
# Step 2 runs the existing testbench (which uses SV features, so -g2012) on it.
# Usage: ./scripts/run_sim_verilog.sh       (PIPE = 0, 1, 2)
#        ./scripts/run_sim_verilog.sh 1     (one PIPE value)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
PIPES=${1:-"0 1 2"}
EXTRA=""
[ "${VCD:-0}" = "1" ] && EXTRA="+VCD"
status=0
for P in $PIPES; do
    echo "=== Verilog DUT, PIPE=$P ==="
    iverilog -g2001 -Wall -tnull -P "vec_max_alu.PIPE=$P" rtl_verilog/cmp_slice.v rtl_verilog/vec_max_alu.v
    iverilog -g2012 -Wall -o "build/simv_p$P" -P "tb_vec_max_alu.PIPE=$P" \
        rtl_verilog/cmp_slice.v rtl_verilog/vec_max_alu.v tb/tb_vec_max_alu.sv
    vvp -n "build/simv_p$P" +VECTORS=tb/vectors.hex $EXTRA | tee "build/simv_p$P.log"
    if ! grep -q "TEST PASSED" "build/simv_p$P.log"; then status=1; fi
done
if [ $status -eq 0 ]; then echo "ALL CONFIGURATIONS PASSED (Verilog DUT)"; else echo "SOME CONFIGURATIONS FAILED (Verilog DUT)"; fi
exit $status
