#!/usr/bin/env bash
# Formal equivalence of the SV RTL and the Verilog-2001 version with Yosys (SAT temporal
# induction on a miter, all flops starting at zero), for PIPE = 0, 1, 2.
# Each design is elaborated and flattened on its own, then the two are compared.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
SV="rtl/cmp_slice.sv rtl/cmp_pair.sv rtl/pipe_reg.sv rtl/vec_max_alu.sv"
V="rtl_verilog/cmp_slice.v rtl_verilog/cmp_pair.v rtl_verilog/pipe_reg.v rtl_verilog/vec_max_alu.v"
status=0
for P in ${1:-0 1 2}; do
    for d in sv v; do
        if [ $d = sv ]; then F="$SV"; R="-sv"; else F="$V"; R=""; fi
        yosys -q -p "read_verilog $R $F; chparam -set PIPE $P vec_max_alu; hierarchy -check -top vec_max_alu;
                     proc; flatten; opt_clean; async2sync; rename vec_max_alu top_$d; write_rtlil build/eq_${d}_p$P.il"
    done
    if yosys -q -p "read_rtlil build/eq_sv_p$P.il; read_rtlil build/eq_v_p$P.il;
                    miter -equiv -flatten -make_assert top_sv top_v m; hierarchy -top m; opt -fast;
                    sat -verify -tempinduct -prove-asserts -set-init-zero -seq 1 -maxsteps 30 m" > "build/prove_p$P.log" 2>&1
    then echo "PROVEN EQUIVALENT (PIPE=$P)"; else echo "NOT PROVEN (PIPE=$P), see build/prove_p$P.log"; status=1; fi
done
exit $status
