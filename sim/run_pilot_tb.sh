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
    "$RTL/rtl/greencoyote_cs_lane_fifo.sv"
    "$RTL/rtl/greencoyote_dac_if.sv"
    "$RTL/rtl/greencoyote_adc_if.sv"
    "$RTL/rtl/greencoyote_dma_walker.sv"
    "$RTL/rtl/greencoyote_dma_axi_master.sv"
    "$RTL/rtl/greencoyote_streaming_dma.sv"
    "$RTL/rtl/greencoyote_top.sv"
    "greencoyote_tb.sv"
)

RTL_SRC=( "${SRC[@]:0:${#SRC[@]}-1}" )   # SRC without the trailing tb file

# ---- 1. pilot data-plane + register-block TB (legacy buf_* path) -------------
iverilog -g2012 -Wall -gassertions \
    -s greencoyote_tb \
    -o sim_out/greencoyote_tb.vvp \
    "${RTL_SRC[@]}" greencoyote_tb.sv

vvp sim_out/greencoyote_tb.vvp | tee sim_out/greencoyote_tb.log

# ---- 2. M_AXIS_CS FIFO-path TB (CS_FIFO_PATH=1, async core_clk) --------------
iverilog -g2012 -Wall -gassertions \
    -s tb_cs_fifo_path \
    -o sim_out/tb_cs_fifo_path.vvp \
    "${RTL_SRC[@]}" tb_cs_fifo_path.sv

vvp sim_out/tb_cs_fifo_path.vvp | tee sim_out/tb_cs_fifo_path.log

# Fail the run if any checker printed FAIL or a watchdog fired.
if grep -qE "FAIL|TIMEOUT|FAILURE" sim_out/greencoyote_tb.log sim_out/tb_cs_fifo_path.log; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
