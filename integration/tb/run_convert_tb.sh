#!/usr/bin/env bash
# Bit-exact conversion test for VX_tcu_q1714_convert_pkg (Icarus Verilog >= 11).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p sim_out
iverilog -g2012 -Wall -o sim_out/convtb \
    ../VX_tcu_q1714_convert_pkg.sv \
    tb_VX_tcu_q1714_convert.sv
vvp sim_out/convtb
