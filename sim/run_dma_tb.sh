#!/usr/bin/env bash
# Streaming Tensor DMA directed integration testbench (tb_dma_integration.sv).
# Functional sim under Icarus Verilog >= 11 (-g2012). Drives greencoyote_top end
# to end: MMIO descriptor + doorbell -> mock AXI memory -> line buffers ->
# dma_armed -> sequencer seq_fire consumes operands in order.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p sim_out

RTL=../rtl
SRC=(
    "$RTL/generated/greencoyote_regmap_pkg.sv"
    "$RTL/greencoyote_axi_lite_wrapper.sv"
    "$RTL/greencoyote_pilot_regs.sv"
    "$RTL/greencoyote_cs_lane_fifo.sv"
    "$RTL/greencoyote_dac_if.sv"
    "$RTL/greencoyote_adc_if.sv"
    "$RTL/greencoyote_dma_walker.sv"
    "$RTL/greencoyote_dma_axi_master.sv"
    "$RTL/greencoyote_streaming_dma.sv"
    "$RTL/greencoyote_photonic_sequencer.sv"
    "$RTL/greencoyote_top.sv"
)

iverilog -g2012 -gassertions \
    -s tb_dma_integration \
    -o sim_out/tb_dma_integration.vvp \
    "${SRC[@]}" tb_dma_integration.sv

vvp sim_out/tb_dma_integration.vvp | tee sim_out/tb_dma_integration.log

if grep -qE "FAIL|TIMEOUT" sim_out/tb_dma_integration.log; then
    echo "RESULT: FAIL"; exit 1
fi
grep -q "ALL CHECKS PASS" sim_out/tb_dma_integration.log || { echo "RESULT: FAIL (no PASS sentinel)"; exit 1; }
echo "RESULT: PASS"
