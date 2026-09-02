# =============================================================================
# GreenCoyote-Bay — headless out-of-context synthesis baseline
# Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
# =============================================================================
# Push-button OOC synthesis of greencoyote_top for the AMD Alveo U55C. Produces
# a post-synth checkpoint plus utilization and timing-summary reports so you can
# track the resource footprint of the full 0x00-0xA8 register map + sequencer
# and the setup slack on the 300 MHz user_clk path.
#
#   Run from anywhere (paths self-locate from this script):
#     vivado -mode batch -source scripts/build.tcl
#
#   Keep Vivado's log/journal with the other build artifacts:
#     vivado -mode batch -source scripts/build.tcl \
#            -log build/logs/vivado.log -journal build/logs/vivado.jou
#
#   Optional overrides (positional Tcl args, or environment variables):
#     vivado -mode batch -source scripts/build.tcl -tclargs <part> <top> <period_ns>
#     GCB_PART / GCB_TOP / GCB_PERIOD_NS
#
# Outputs (under build/ , git-ignored):
#     build/checkpoints/post_synth.dcp
#     build/reports/utilization_synth.rpt
#     build/reports/utilization_synth_hier.rpt
#     build/reports/timing_synth.rpt
#     build/reports/timing_worst_paths.rpt
#     build/reports/drc_synth.rpt
#
# Exit status: 0 on success, 1 on a synthesis error, 2 on a setup error,
# 3 when the post-synth setup WNS is negative. Safe to gate CI on.
# =============================================================================

# ----------------------------------------------------------------------------
# 0. Locate the repo and resolve knobs
# ----------------------------------------------------------------------------
set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]

proc _knob {argv idx envname default} {
    if {[llength $argv] > $idx} { return [lindex $argv $idx] }
    if {[info exists ::env($envname)] && $::env($envname) ne ""} { return $::env($envname) }
    return $default
}

set PART      [_knob $argv 0 GCB_PART      "xcu55c-fsvh2892-2L-e"]
set TOP       [_knob $argv 1 GCB_TOP       "greencoyote_top"]
set PERIOD_NS [_knob $argv 2 GCB_PERIOD_NS "3.333"]

set rtl_dir   [file join $repo_root rtl]
set xdc_ooc   [file join $repo_root constraints greencoyote_ooc.xdc]
set build_dir [file join $repo_root build]
set rpt_dir   [file join $build_dir reports]
set dcp_dir   [file join $build_dir checkpoints]
file mkdir $rpt_dir $dcp_dir [file join $build_dir logs]

puts "============================================================"
puts " GreenCoyote-Bay OOC synthesis"
puts "   repo  : $repo_root"
puts "   part  : $PART"
puts "   top   : $TOP"
puts "   clock : ${PERIOD_NS} ns  ([format %.1f [expr {1000.0 / $PERIOD_NS}]] MHz)"
puts "============================================================"

# ----------------------------------------------------------------------------
# 1. Read sources + timing-only OOC constraints
# ----------------------------------------------------------------------------
# Generated packages (registers.yaml -> regen.py) first, so modules that
# `import greencoyote_regmap_pkg::*` elaborate.
set pkg_files [lsort [glob -nocomplain [file join $rtl_dir generated *.sv]]]
set sv_files  [lsort [glob -nocomplain [file join $rtl_dir *.sv]]]
if {[llength $sv_files] == 0} {
    puts "ERROR: no .sv sources under $rtl_dir"
    exit 2
}
set all_sv [concat $pkg_files $sv_files]
puts "\n-- reading [llength $pkg_files] generated package(s) + [llength $sv_files] RTL source(s):"
foreach f $pkg_files { puts "     generated/[file tail $f]" }
foreach f $sv_files  { puts "     [file tail $f]" }
read_verilog -sv $all_sv

if {![file exists $xdc_ooc]} {
    puts "ERROR: OOC constraints not found: $xdc_ooc"
    exit 2
}
puts "\n-- reading OOC constraints: [file tail $xdc_ooc]"
read_xdc $xdc_ooc

# ----------------------------------------------------------------------------
# 2. Out-of-context synthesis
#    -mode out_of_context : no I/O buffer insertion, so the stubbed subsystem
#    buses can sit on top-level ports without package pins.
# ----------------------------------------------------------------------------
puts "\n-- synth_design (out_of_context) ..."
if {[catch {
    synth_design -top $TOP -part $PART -mode out_of_context -flatten_hierarchy rebuilt
} err]} {
    puts "ERROR: synth_design failed: $err"
    exit 1
}

# ----------------------------------------------------------------------------
# 3. Artifacts
# ----------------------------------------------------------------------------
puts "\n-- writing checkpoint + reports ..."
write_checkpoint -force [file join $dcp_dir post_synth.dcp]

report_utilization    -file [file join $rpt_dir utilization_synth.rpt]
report_utilization    -hierarchical -hierarchical_depth 3 \
                      -file [file join $rpt_dir utilization_synth_hier.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
                      -max_paths 10 -file [file join $rpt_dir timing_synth.rpt]
report_timing         -sort_by group -max_paths 20 -path_type full_clock_expanded \
                      -file [file join $rpt_dir timing_worst_paths.rpt]
report_drc            -file [file join $rpt_dir drc_synth.rpt]

# ----------------------------------------------------------------------------
# 4. Console digest + timing gate
# ----------------------------------------------------------------------------
proc _count {pattern} {
    return [llength [get_cells -hier -quiet -filter "REF_NAME =~ $pattern"]]
}

set wns "n/a"
if {![catch {
    set p [get_timing_paths -setup -max_paths 1 -nworst 1 -quiet]
} ] && [llength $p] > 0} {
    set wns [get_property SLACK [lindex $p 0]]
}

puts "\n============================================================"
puts " Synthesis complete   ($TOP @ $PART)"
puts "------------------------------------------------------------"
puts [format "   %-18s %d" "LUT"          [_count "LUT*"]]
puts [format "   %-18s %d" "  FF (FD*)"   [_count "FD*"]]
puts [format "   %-18s %d" "  CARRY"      [_count "CARRY*"]]
puts [format "   %-18s %d" "  MUXF7/8"    [expr {[_count "MUXF7"] + [_count "MUXF8"]}]]
puts [format "   %-18s %d" "DSP"          [_count "DSP*"]]
puts [format "   %-18s %d" "RAMB36"       [_count "RAMB36*"]]
puts [format "   %-18s %d" "RAMB18"       [_count "RAMB18*"]]
puts "------------------------------------------------------------"
puts "   setup WNS  : $wns ns"
puts "   checkpoint : [file join $dcp_dir post_synth.dcp]"
puts "   full report: [file join $rpt_dir utilization_synth.rpt]"
puts "                [file join $rpt_dir timing_synth.rpt]"
puts "============================================================"

if {$wns ne "n/a" && $wns < 0} {
    puts "\nRESULT: TIMING NOT MET  (setup WNS = $wns ns) -> reports/timing_synth.rpt"
    exit 3
}
puts "\nRESULT: OK  (setup WNS = $wns ns)"
exit 0
