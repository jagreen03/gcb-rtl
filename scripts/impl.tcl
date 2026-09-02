# =============================================================================
# GreenCoyote-Bay — headless out-of-context implementation (place & route)
# Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
# =============================================================================
# Consumes the post-synth checkpoint from scripts/build.tcl and runs
# opt_design -> place_design -> phys_opt_design -> route_design in OOC mode,
# then writes a post-route checkpoint and reports so you can read real
# post-route slack on the 300 MHz user_clk path.
#
#   Run after build.tcl, from anywhere (paths self-locate):
#     vivado -mode batch -source scripts/impl.tcl \
#            -log build/logs/impl.log -journal build/logs/impl.jou
#
#   Optional overrides (positional Tcl args, or environment variables):
#     vivado -mode batch -source scripts/impl.tcl -tclargs <input.dcp>
#     GCB_SYNTH_DCP
#
# Outputs (under build/ , git-ignored):
#     build/checkpoints/post_route.dcp
#     build/reports/utilization_route.rpt
#     build/reports/timing_route.rpt
#     build/reports/timing_route_worst_paths.rpt
#     build/reports/clock_utilization_route.rpt
#     build/reports/drc_route.rpt
#     build/reports/power_route.rpt
#
# Exit status: 0 ok · 1 an impl step failed · 2 setup error ·
#              3 negative post-route setup WNS · 4 negative post-route hold WHS.
# =============================================================================

# ----------------------------------------------------------------------------
# 0. Locate the repo + resolve knobs
# ----------------------------------------------------------------------------
set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]

proc _knob {argv idx envname default} {
    if {[llength $argv] > $idx} { return [lindex $argv $idx] }
    if {[info exists ::env($envname)] && $::env($envname) ne ""} { return $::env($envname) }
    return $default
}

set build_dir [file join $repo_root build]
set rpt_dir   [file join $build_dir reports]
set dcp_dir   [file join $build_dir checkpoints]
set SYNTH_DCP [_knob $argv 0 GCB_SYNTH_DCP [file join $dcp_dir post_synth.dcp]]

file mkdir $rpt_dir $dcp_dir [file join $build_dir logs]

if {![file exists $SYNTH_DCP]} {
    puts "ERROR: post-synth checkpoint not found: $SYNTH_DCP"
    puts "       run  vivado -mode batch -source scripts/build.tcl  first."
    exit 2
}

puts "============================================================"
puts " GreenCoyote-Bay OOC implementation (place & route)"
puts "   repo   : $repo_root"
puts "   in dcp : $SYNTH_DCP"
puts "============================================================"

# ----------------------------------------------------------------------------
# 1. Open the synthesized checkpoint (keeps the out-of-context mode)
# ----------------------------------------------------------------------------
if {[catch { open_checkpoint $SYNTH_DCP } err]} {
    puts "ERROR: open_checkpoint failed: $err"
    exit 2
}

# ----------------------------------------------------------------------------
# 2. Implementation flow
# ----------------------------------------------------------------------------
proc _step {name body} {
    puts "\n-- $name ..."
    if {[catch { uplevel 1 $body } err]} {
        puts "ERROR: $name failed: $err"
        exit 1
    }
}

_step "opt_design"        { opt_design }
_step "place_design"      { place_design }
_step "phys_opt_design"   { phys_opt_design }
_step "route_design"      { route_design }
_step "post-route phys_opt" { phys_opt_design }

# ----------------------------------------------------------------------------
# 3. Artifacts
# ----------------------------------------------------------------------------
puts "\n-- writing checkpoint + reports ..."
write_checkpoint -force [file join $dcp_dir post_route.dcp]

report_utilization       -file [file join $rpt_dir utilization_route.rpt]
report_clock_utilization -file [file join $rpt_dir clock_utilization_route.rpt]
report_timing_summary    -delay_type min_max -report_unconstrained -check_timing_verbose \
                         -max_paths 10 -file [file join $rpt_dir timing_route.rpt]
report_timing            -sort_by group -max_paths 20 -path_type full_clock_expanded \
                         -file [file join $rpt_dir timing_route_worst_paths.rpt]
report_drc               -file [file join $rpt_dir drc_route.rpt]
catch { report_power     -file [file join $rpt_dir power_route.rpt] }

# ----------------------------------------------------------------------------
# 4. Console digest + timing gate
# ----------------------------------------------------------------------------
proc _count {pattern} {
    return [llength [get_cells -hier -quiet -filter "REF_NAME =~ $pattern"]]
}
proc _slack {args} {
    set p [get_timing_paths {*}$args -max_paths 1 -nworst 1 -quiet]
    if {[llength $p] == 0} { return "n/a" }
    return [get_property SLACK [lindex $p 0]]
}

set wns [_slack -setup]
set whs [_slack -hold]

puts "\n============================================================"
puts " Post-route  (greencoyote_top @ [get_property PART [current_design]])"
puts "------------------------------------------------------------"
puts [format "   %-14s %d" "LUT"    [_count "LUT*"]]
puts [format "   %-14s %d" "FF"     [_count "FD*"]]
puts [format "   %-14s %d" "CARRY8" [_count "CARRY*"]]
puts [format "   %-14s %d" "DSP"    [_count "DSP*"]]
puts [format "   %-14s %d" "RAMB36" [_count "RAMB36*"]]
puts "------------------------------------------------------------"
puts "   setup WNS : $wns ns"
puts "   hold  WHS : $whs ns"
puts "   checkpoint: [file join $dcp_dir post_route.dcp]"
puts "   reports   : $rpt_dir"
puts "============================================================"

set rc 0
if {$wns ne "n/a" && $wns < 0} {
    puts "\nRESULT: SETUP NOT MET  (WNS = $wns ns) -> reports/timing_route.rpt"
    set rc 3
} elseif {$whs ne "n/a" && $whs < 0} {
    puts "\nRESULT: HOLD NOT MET  (WHS = $whs ns) -> reports/timing_route.rpt"
    set rc 4
} else {
    puts "\nRESULT: OK  (setup WNS = $wns ns, hold WHS = $whs ns)"
}
exit $rc
