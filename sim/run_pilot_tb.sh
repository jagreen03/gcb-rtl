#!/usr/bin/env bash
# Pilot data-plane + register-block testbench (greencoyote_tb.sv).
# Functional sim under Icarus Verilog >= 11 (-g2012). The Vivado OOC timing
# check in scripts/build.tcl is a separate step and is NOT run here.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p sim_out

RTL=..
SRC=(
    "$RTL/rtl/generated/greencoyote_regmap_pkg.sv"   # package first
    "$RTL/rtl/greencoyote_axi_lite_wrapper.sv"
    "$RTL/rtl/greencoyote_pilot_regs.sv"
    "$RTL/rtl/greencoyote_photonic_sequencer.sv"
    "$RTL/rtl/greencoyote_dac_if.sv"
    "$RTL/rtl/greencoyote_adc_if.sv"
    "$RTL/rtl/greencoyote_top.sv"
    "greencoyote_tb.sv"
)

iverilog -g2012 -Wall -gassertions \
    -s greencoyote_tb \
    -o sim_out/greencoyote_tb.vvp \
    "${SRC[@]}"

vvp sim_out/greencoyote_tb.vvp | tee sim_out/greencoyote_tb.log

# Fail the run if any checker printed FAIL or the watchdog fired.
if grep -qE "FAIL|TIMEOUT" sim_out/greencoyote_tb.log; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
