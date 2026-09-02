#!/usr/bin/env bash
# Full-shim testbench. Requires Verilator >= 5 (Vortex's own simulator) —
# Icarus 11 has no SystemVerilog interface-port support, so the shim (and the
# real VX_result_if) will not compile there.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p sim_out

if ! command -v verilator >/dev/null 2>&1; then
    echo "verilator not found — this TB needs Verilator >= 5." >&2
    echo "(the bit-exact conversion TB, run_convert_tb.sh, runs under Icarus.)" >&2
    exit 127
fi

verilator --binary --timing -j 0 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE \
    +define+SIMULATION \
    -I stubs \
    --top-module tb_VX_tcu_shim_q1714 \
    --Mdir sim_out/obj_shimtb \
    ../VX_tcu_q1714_convert_pkg.sv \
    stubs/vx_stubs.sv \
    ../VX_tcu_shim_q1714.sv \
    tb_VX_tcu_shim_q1714.sv

exec sim_out/obj_shimtb/Vtb_VX_tcu_shim_q1714
