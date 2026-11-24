#!/usr/bin/env bash
# Verilog-2001 flow: compile verilog/rtl + verilog/tb with Icarus in strict
# Verilog-2001 mode (-g2001) and run for PIPE = 0, 1 and 2.
# Also re-runs the original SystemVerilog testbench against the Verilog RTL, so
# the Verilog design is checked by exactly the same testbench as the SV design.
# Finally runs both designs side by side (verilog/tb/tb_equiv.v) and compares
# out_valid and result on every clock edge.
# Usage: ./scripts/run_sim_verilog.sh       (all three)
#        ./scripts/run_sim_verilog.sh 1     (one PIPE value)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
PIPES=${1:-"0 1 2"}
status=0
for P in $PIPES; do
    echo "=== Verilog RTL + Verilog TB (-g2001), PIPE=$P ==="
    iverilog -g2001 -Wall -o "build/vsim_p$P" -P "tb_vec_max_alu.PIPE=$P" \
        verilog/rtl/cmp_slice.v verilog/rtl/vec_max_alu.v verilog/tb/tb_vec_max_alu.v
    vvp -n "build/vsim_p$P" +VECTORS=tb/vectors.hex | tee "build/vsim_p$P.log"
    grep -q "TEST PASSED" "build/vsim_p$P.log" || status=1

    echo "=== Verilog RTL + original SV TB (-g2012), PIPE=$P ==="
    iverilog -g2012 -Wall -o "build/vsim_svtb_p$P" -P "tb_vec_max_alu.PIPE=$P" \
        verilog/rtl/cmp_slice.v verilog/rtl/vec_max_alu.v tb/tb_vec_max_alu.sv
    vvp -n "build/vsim_svtb_p$P" +VECTORS=tb/vectors.hex | tee "build/vsim_svtb_p$P.log"
    grep -q "TEST PASSED" "build/vsim_svtb_p$P.log" || status=1

    echo "=== Lockstep SV vs Verilog equivalence, PIPE=$P ==="
    sed 's/\bcmp_slice\b/cmp_slice_sv/; s/\bvec_max_alu\b/vec_max_alu_sv/' rtl/cmp_slice.sv rtl/vec_max_alu.sv > build/sv_renamed.sv
    iverilog -g2012 -Wall -o "build/equiv_p$P" -P "tb_equiv.PIPE=$P" \
        build/sv_renamed.sv verilog/rtl/cmp_slice.v verilog/rtl/vec_max_alu.v verilog/tb/tb_equiv.v
    vvp -n "build/equiv_p$P" | tee "build/equiv_p$P.log"
    grep -q "EQUIV PASSED" "build/equiv_p$P.log" || status=1
done
if [ $status -eq 0 ]; then echo "ALL VERILOG CONFIGURATIONS PASSED"; else echo "SOME VERILOG CONFIGURATIONS FAILED"; fi
exit $status
