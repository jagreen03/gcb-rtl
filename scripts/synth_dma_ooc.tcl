# =============================================================================
# synth_dma_ooc.tcl
# Out-of-context synthesis + timing for the Streaming Tensor DMA on Alveo U55C.
#
# Top:   greencoyote_streaming_dma   (registers.yaml map_version 0.6.0;
#        gcb-spec/docs/optical_geometry_spec.md v1.0.0 localparams)
# Run:   from the gcb-rtl repo root --
#          vivado -mode batch -source scripts/synth_dma_ooc.tcl -nojournal -notrace
#        or via the "RTL: Vivado OOC Synthesis (DMA)" workspace task.
# =============================================================================

set part   xcu55c-fsvh2892-2L-e
set top    greencoyote_streaming_dma
set outdir ./reports
file mkdir $outdir

set_part $part

# ---- SystemVerilog sources -------------------------------------------------
# Package first, then the DMA hierarchy. The DMA modules live flat in rtl/,
# not rtl/dma/. greencoyote_streaming_dma instantiates the walker, the AXI
# master, and greencoyote_cs_lane_fifo (the CDC token FIFO).
set srcs [list \
    ./rtl/generated/greencoyote_regmap_pkg.sv \
    ./rtl/greencoyote_cs_lane_fifo.sv \
    ./rtl/greencoyote_dma_walker.sv \
    ./rtl/greencoyote_dma_axi_master.sv \
    ./rtl/greencoyote_streaming_dma.sv \
]
foreach f $srcs {
    if {![file exists $f]} { error "synth_dma_ooc: missing source $f" }
    puts "read_verilog -sv $f"
    read_verilog -sv $f
}

# ---- out-of-context synthesis (no I/O buffers inserted) ------------------
set_param synth.elaboration.rodinMoreOptions "rt::set_parameter max_array_size 10000000"
synth_design -top $top -mode out_of_context

# ---- timing constraints --------------------------------------------------
# Two asynchronous clock domains crossed only by Gray-pointer FIFOs:
#   user_clk : 300 MHz  (AXI read master, descriptor walker, MMIO)
#   opt_clk  : 2.0 GHz  (operand read ports = optical T_fire cadence)
create_clock -name user_clk -period 3.333 [get_ports user_clk]
create_clock -name opt_clk  -period 0.500 [get_ports opt_clk]
set_clock_groups -asynchronous \
    -group [get_clocks user_clk] \
    -group [get_clocks opt_clk]

# ---- reports ------------------------------------------------------------
report_timing_summary -delay_type min_max -max_paths 25 -input_pins \
    -file $outdir/dma_timing_summary.rpt
report_utilization       -file $outdir/dma_utilization.rpt
report_clock_interaction -file $outdir/dma_clock_interaction.rpt

# ---- WNS gate (informational; batch still exits 0 unless synth errored) --
if {[catch {
    set p   [get_timing_paths -delay_type max -nworst 1 -max_paths 1]
    set wns [get_property SLACK $p]
    puts "OOC setup WNS = $wns ns  ([expr {$wns < 0 ? "TIMING FAIL" : "TIMING OK"}])"
} err]} {
    puts "WNS query skipped: $err"
}

puts "synth_dma_ooc: reports in $outdir/"
