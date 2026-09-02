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

# adc_data / adc_valid arrive on the ADC conversion clock, asynchronous to
# user_clk. greencoyote_photonic_sequencer brings them across with a 2-flop
# synchronizer (adc_*_sync_meta -> adc_*_sync). Cut the async arc into that
# first stage so the crossing is not timed as a real path.
set_false_path -from [get_ports {adc_data[*] adc_valid}]

# Register-driven slow output — give the tool a loose budget rather than
# leaving it unconstrained in the summary.
set_output_delay -clock user_clk 0.000 [get_ports interrupt]
