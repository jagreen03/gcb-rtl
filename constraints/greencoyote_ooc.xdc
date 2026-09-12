# =============================================================================
# GreenCoyote-Bay — Out-of-Context Synthesis Constraints
# Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
# =============================================================================

# 1. Define Primary Clocks
create_clock -name user_clk -period 3.333 [get_ports user_clk]
create_clock -name core_clk -period 2.500 [get_ports core_clk]
create_clock -name opt_clk  -period 0.500 [get_ports opt_clk]

# 2. Tell Vivado to treat them as Global Clocks (OOC auto-buffer bypass)
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports user_clk]
set_property HD.CLK_SRC BUFGCTRL_X0Y1 [get_ports core_clk]
set_property HD.CLK_SRC BUFGCTRL_X0Y2 [get_ports opt_clk]

# 3. Sever Cross-Domain Timing Paths
set_clock_groups -asynchronous -group [get_clocks user_clk] \
                               -group [get_clocks core_clk] \
                               -group [get_clocks opt_clk]

# 4. I/O Budgets and Exceptions
set_false_path -from [get_ports adc_miso]
set_output_delay -clock user_clk 0.000 [get_ports interrupt]
set_output_delay -clock user_clk 0.000 [get_ports {dac_p_data[*] dac_p_chan[*] dac_p_clk dac_p_wr_n}]
set_output_delay -clock user_clk 0.000 [get_ports {adc_sclk adc_cs_n adc_mosi}]
