#!/usr/bin/env bash
# Runs the SV RTL and the Verilog-2001 version side by side (tb/tb_equiv_sv_vs_v.sv)
# and checks that their outputs match on every clock edge, for PIPE = 0, 1, 2.
# The SV modules are copied into build/ with an _sv suffix so both can coexist.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
MODS="cmp_slice cmp_pair pipe_reg vec_max_alu"
SED=""
for m in $MODS; do SED="$SED -e s/\\b$m\\b/${m}_sv/g"; done
SV=""
for m in $MODS; do sed $SED "rtl/$m.sv" > "build/${m}_sv.sv"; SV="$SV build/${m}_sv.sv"; done
V=""
for m in $MODS; do V="$V rtl_verilog/$m.v"; done
PIPES=${1:-"0 1 2"}
status=0
for P in $PIPES; do
    iverilog -g2012 -Wall -Wno-timescale -o "build/equiv_p$P" -P "tb_equiv_sv_vs_v.PIPE=$P" \
        tb/tb_equiv_sv_vs_v.sv $SV $V
    vvp -n "build/equiv_p$P" | tee "build/equiv_p$P.log"
    grep -q "^EQUIVALENT" "build/equiv_p$P.log" || status=1
done
exit $status
