# =============================================================================
# GreenCoyote-Bay — Out-of-Context Synthesis Constraints
# Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
# =============================================================================
# Timing-only constraints for a headless OOC synthesis baseline
# (scripts/build.tcl). This file deliberately contains NO PACKAGE_PIN /
# IOSTANDARD / SLR / BITSTREAM properties:
#
#   * OOC synthesis inserts no I/O buffers, so pin/IOSTANDARD constraints are
#     meaningless here and the placeholder pins in greencoyote_bay.xdc
#     (REPLACE_WITH_LA02_P ...) would hard-error the run.
#   * Physical constraints belong to the implementation / Vitis-platform stage,
#     once real U55C package pins have been filled into greencoyote_bay.xdc.
#
# Keep this in sync with the primary clock definition in greencoyote_bay.xdc.
# =============================================================================

# Primary user clock from the Alveo U55C shell — 300 MHz (3.333 ns)
create_clock -period 3.333 -name user_clk [get_ports user_clk]

# adc_miso returns from the SPI SAR ADC (greencoyote_adc_if is the SPI master).
# It is clocked out by our own adc_sclk but sampled in the user_clk domain with
# no board delay model in OOC; cut it so it is not timed as a real path. The
# adc_if -> sequencer path (adc_data/adc_valid/conv_fault) is fully synchronous
# and the sequencer still 2-flops it (adc_*_sync_meta -> adc_*_sync).
set_false_path -from [get_ports adc_miso]

# Register-driven slow I/O — give the tool a loose budget rather than leaving
# these unconstrained in the summary.
set_output_delay -clock user_clk 0.000 [get_ports interrupt]
set_output_delay -clock user_clk 0.000 [get_ports {dac_p_data[*] dac_p_chan[*] dac_p_clk dac_p_wr_n}]
set_output_delay -clock user_clk 0.000 [get_ports {adc_sclk adc_cs_n adc_mosi}]
