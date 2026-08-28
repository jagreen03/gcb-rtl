# =============================================================================
# GreenCoyote-Bay — Vivado XDC Constraints
# Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
# Author:  John A. Green
# Date:    June 2026
# Target:  AMD Xilinx Alveo U55C — XCU55 device
# =============================================================================
#
# PIN ASSIGNMENTS REQUIRE U55C_xdc_1v00.xdc FROM AMD:
# https://www.amd.com/bin/public/amdOpenDownload?filename=U55C_xdc_1v00.xdc
#
# Procedure:
#   1. Download U55C_xdc_1v00.xdc from AMD
#   2. Search for HPC_FMC or LA0 to find FMC HPC LA bank pin assignments
#   3. Replace REPLACE_WITH_LA02_P etc. below with actual package pin IDs
#   4. Verify VADJ rail is set to 1.8V in Vitis platform settings
#
# FMC HPC LA Bank Assignment Plan:
#   DAC data[0]    → LA02_P / LA02_N  (LVDS pair)
#   DAC data[1]    → LA03_P / LA03_N
#   DAC data[2]    → LA04_P / LA04_N
#   DAC data[3]    → LA05_P / LA05_N
#   DAC data[4]    → LA06_P / LA06_N
#   DAC data[5]    → LA07_P / LA07_N
#   DAC data[6]    → LA08_P / LA08_N
#   DAC data[7]    → LA09_P / LA09_N
#   DAC sync       → LA10_P            (LVCMOS18 single-ended)
#   DAC valid[7:0] → LA11_P..LA18_P   (LVCMOS18 single-ended)
#   ADC data[11:0] → LA19_P..LA24_P   (LVCMOS18 single-ended)
#   ADC valid      → LA25_P            (LVCMOS18 single-ended)
#   IRQ out        → LA26_P            (LVCMOS18 single-ended)
#
# Note: LA00_CC and LA01_CC are clock-capable pairs — reserved for future use
# =============================================================================

# =============================================================================
# Clock constraints
# =============================================================================

# Primary user clock from Alveo U55C shell — 300 MHz
# The shell provides this clock; do not add PACKAGE_PIN for this
create_clock -period 3.333 -name user_clk [get_ports user_clk]

# FMC reference clock if external oscillator used on mezzanine
# Uncomment and set period if using external mezzanine clock
# create_clock -period 10.000 -name fmc_clk [get_ports fmc_ref_clk]

# =============================================================================
# I/O Standards
# =============================================================================

# DAC data lines — LVDS differential pairs on FMC HPC LA02-LA09
# LVDS_25 requires VADJ = 2.5V — USE LVCMOS18 if VADJ = 1.8V
# Confirm VADJ setting in Vitis platform before selecting standard

# Option A: VADJ = 1.8V (default U55C setting)
set_property IOSTANDARD LVCMOS18 [get_ports {dac_data[*]}]

# Option B: VADJ = 2.5V (requires platform reconfiguration)
# set_property IOSTANDARD LVDS_25  [get_ports {dac_data[*]}]
# set_property DIFF_TERM_ADV TERM_100 [get_ports {dac_data[*]}]

# Control signals — LVCMOS18 single-ended
set_property IOSTANDARD LVCMOS18 [get_ports dac_sync]
set_property IOSTANDARD LVCMOS18 [get_ports {dac_valid[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports {adc_data[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports adc_valid]
set_property IOSTANDARD LVCMOS18 [get_ports interrupt]

# =============================================================================
# PIN ASSIGNMENTS — REPLACE WITH ACTUAL U55C PACKAGE PINS
# Source: U55C_xdc_1v00.xdc from AMD download page
# =============================================================================

# DAC data channels 0-7 (LVDS or LVCMOS18 depending on VADJ)
set_property PACKAGE_PIN REPLACE_WITH_LA02_P [get_ports {dac_data[0]}]
set_property PACKAGE_PIN REPLACE_WITH_LA03_P [get_ports {dac_data[1]}]
set_property PACKAGE_PIN REPLACE_WITH_LA04_P [get_ports {dac_data[2]}]
set_property PACKAGE_PIN REPLACE_WITH_LA05_P [get_ports {dac_data[3]}]
set_property PACKAGE_PIN REPLACE_WITH_LA06_P [get_ports {dac_data[4]}]
set_property PACKAGE_PIN REPLACE_WITH_LA07_P [get_ports {dac_data[5]}]
set_property PACKAGE_PIN REPLACE_WITH_LA08_P [get_ports {dac_data[6]}]
set_property PACKAGE_PIN REPLACE_WITH_LA09_P [get_ports {dac_data[7]}]

# DAC sync strobe — single-ended control
set_property PACKAGE_PIN REPLACE_WITH_LA10_P [get_ports dac_sync]

# DAC valid per channel 0-7
set_property PACKAGE_PIN REPLACE_WITH_LA11_P [get_ports {dac_valid[0]}]
set_property PACKAGE_PIN REPLACE_WITH_LA12_P [get_ports {dac_valid[1]}]
set_property PACKAGE_PIN REPLACE_WITH_LA13_P [get_ports {dac_valid[2]}]
set_property PACKAGE_PIN REPLACE_WITH_LA14_P [get_ports {dac_valid[3]}]
set_property PACKAGE_PIN REPLACE_WITH_LA15_P [get_ports {dac_valid[4]}]
set_property PACKAGE_PIN REPLACE_WITH_LA16_P [get_ports {dac_valid[5]}]
set_property PACKAGE_PIN REPLACE_WITH_LA17_P [get_ports {dac_valid[6]}]
set_property PACKAGE_PIN REPLACE_WITH_LA18_P [get_ports {dac_valid[7]}]

# ADC data 12-bit result
set_property PACKAGE_PIN REPLACE_WITH_LA19_P [get_ports {adc_data[0]}]
set_property PACKAGE_PIN REPLACE_WITH_LA20_P [get_ports {adc_data[1]}]
set_property PACKAGE_PIN REPLACE_WITH_LA21_P [get_ports {adc_data[2]}]
set_property PACKAGE_PIN REPLACE_WITH_LA22_P [get_ports {adc_data[3]}]
set_property PACKAGE_PIN REPLACE_WITH_LA23_P [get_ports {adc_data[4]}]
set_property PACKAGE_PIN REPLACE_WITH_LA24_P [get_ports {adc_data[5]}]
set_property PACKAGE_PIN REPLACE_WITH_LA25_P [get_ports {adc_data[6]}]
set_property PACKAGE_PIN REPLACE_WITH_LA26_P [get_ports {adc_data[7]}]
set_property PACKAGE_PIN REPLACE_WITH_LA27_P [get_ports {adc_data[8]}]
set_property PACKAGE_PIN REPLACE_WITH_LA28_P [get_ports {adc_data[9]}]
set_property PACKAGE_PIN REPLACE_WITH_LA29_P [get_ports {adc_data[10]}]
set_property PACKAGE_PIN REPLACE_WITH_LA30_P [get_ports {adc_data[11]}]

# ADC conversion valid
set_property PACKAGE_PIN REPLACE_WITH_LA31_P [get_ports adc_valid]

# Interrupt to host
set_property PACKAGE_PIN REPLACE_WITH_LA32_P [get_ports interrupt]

# =============================================================================
# Timing constraints
# =============================================================================

# DAC data skew constraint — all 8 channels must arrive within 200ps
# Applied as max skew between dac_data members
set_max_delay -datapath_only -from [get_cells -hier -filter {NAME =~ *u_sequencer*}] \
              -to [get_ports {dac_data[*]}] 2.000

# DAC sync high-fanout low-skew net
# Arrives at all 8 DAC channels within same clock cycle
set_max_delay -datapath_only \
              -from [get_cells -hier -filter {NAME =~ *u_sequencer*dac_sync*}] \
              -to [get_ports dac_sync] 1.000

# ADC async capture — false path from ADC valid to sequencer
# ADC conversion is asynchronous to user_clk
# Sequencer uses 2-stage synchronizer on adc_valid input
set_false_path -from [get_ports adc_valid] \
               -to [get_cells -hier -filter {NAME =~ *u_sequencer*adc_valid_sync*}]

set_false_path -from [get_ports {adc_data[*]}] \
               -to [get_cells -hier -filter {NAME =~ *u_sequencer*adc_data_sync*}]

# Interrupt output — relaxed timing, driven by register logic
set_max_delay -datapath_only \
              -from [get_cells -hier -filter {NAME =~ *u_pilot_regs*irq*}] \
              -to [get_ports interrupt] 5.000

# =============================================================================
# ODELAY constraints for DAC channel skew matching
# Requires VADJ compatible ODELAY primitives in the IO bank
# Fine-tune after hardware bring-up using oscilloscope measurements
# =============================================================================

# set_property ODELAY_VALUE 0 [get_cells -hier -filter {NAME =~ *dac_data_0_ODELAY*}]
# set_property ODELAY_VALUE 0 [get_cells -hier -filter {NAME =~ *dac_data_1_ODELAY*}]
# ... Adjust values after physical measurement to achieve 200ps skew target

# =============================================================================
# Placement constraints
# =============================================================================

# Pilot register block — place near PCIe interface in SLR0
# U55C is a 3-SLR device: SLR0 contains PCIe, SLR1/2 contain HBM
# FMC HPC connector is on SLR0 side — keep all GreenCoyote logic in SLR0
set_property SLR_ASSIGNMENT SLR0 [get_cells u_axi_lite]
set_property SLR_ASSIGNMENT SLR0 [get_cells u_pilot_regs]
set_property SLR_ASSIGNMENT SLR0 [get_cells u_sequencer]

# =============================================================================
# VADJ platform constraint — set in Vitis platform TCL not XDC
# Add to platform creation script:
#   set_property VADJ 1.8 [get_board_components fmc_hpc]
# Or if using 2.5V LVDS:
#   set_property VADJ 2.5 [get_board_components fmc_hpc]
# =============================================================================

# =============================================================================
# Bitstream properties
# =============================================================================

set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 85.0 [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property CFGBVS GND [current_design]
