#!/usr/bin/env bash
# Single-slope readout digital back-end: golden-model bit-match + TDC properties.
# Icarus Verilog >= 11 (-g2012).  Run from gcb-rtl/sim/.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p sim_out

PY="${PY:-python3}"
RTL=../rtl
FAIL=0

echo "== 1. regenerate the 10 000-conversion golden vectors =="
"$PY" golden_ss_readout.py --n 10000 --seed 1 --out sim_out/ss_calib_vectors.txt

echo "== 2. calib back-end : Icarus vs Python golden (bit-exact) =="
iverilog -g2012 -o sim_out/tb_ss_calib.vvp -s tb_ss_calib \
    "$RTL/greencoyote_ss_calib.sv" tb_ss_calib.sv
vvp sim_out/tb_ss_calib.vvp | tee sim_out/tb_ss_calib.log
grep -q "ALL 10000 CHECKS PASS" sim_out/tb_ss_calib.log || FAIL=1

echo "== 3. shared TDC : Gray/4-phase/isolation properties =="
# the '-g2012 constant selects' notes are a benign Icarus 11 limitation
iverilog -g2012 -o sim_out/tb_ss_tdc.vvp -s tb_ss_tdc \
    "$RTL/greencoyote_ss_tdc.sv" tb_ss_tdc.sv 2>/dev/null
vvp sim_out/tb_ss_tdc.vvp | tee sim_out/tb_ss_tdc.log
grep -q "tb_ss_tdc: ALL CHECKS PASS" sim_out/tb_ss_tdc.log || FAIL=1

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL SS-READOUT RTL TESTS PASS"; exit 0
else echo "SS-READOUT RTL: FAILURES"; exit 1; fi
