#!/usr/bin/env bash
# Runs the SV RTL and the Verilog-2001 port side by side (tb/tb_equiv_sv_vs_v.sv)
# and checks that their outputs match on every clock edge, for PIPE = 0, 1, 2.
# The SV modules are copied into build/ with an _sv suffix so both can coexist.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sed -e 's/\bcmp_slice\b/cmp_slice_sv/g' rtl/cmp_slice.sv   > build/cmp_slice_sv.sv
sed -e 's/\bcmp_slice\b/cmp_slice_sv/g' -e 's/\bvec_max_alu\b/vec_max_alu_sv/g' \
    rtl/vec_max_alu.sv > build/vec_max_alu_sv.sv
PIPES=${1:-"0 1 2"}
status=0
for P in $PIPES; do
    iverilog -g2012 -Wall -o "build/equiv_p$P" -P "tb_equiv_sv_vs_v.PIPE=$P" \
        build/cmp_slice_sv.sv build/vec_max_alu_sv.sv \
        rtl_verilog/cmp_slice.v rtl_verilog/vec_max_alu.v tb/tb_equiv_sv_vs_v.sv
    vvp -n "build/equiv_p$P" | tee "build/equiv_p$P.log"
    grep -q "^EQUIVALENT" "build/equiv_p$P.log" || status=1
done
exit $status
