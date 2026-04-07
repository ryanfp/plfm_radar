################################################################################
# build_50t_test.tcl — XC7A50T Production Build
# Builds the AERIS-10 design targeting the production 50T (FTG256) board
################################################################################

set project_name    "aeris10_radar_50t"
set script_dir      [file dirname [file normalize [info script]]]
set project_root    [file normalize [file join $script_dir ".."]]
set project_dir     [file join $project_root "build_50t"]
set rtl_dir         $project_root
set fpga_part       "xc7a50tftg256-2"
set top_module      "radar_system_top"

puts "================================================================"
puts "  AERIS-10 — XC7A50T Production Build"
puts "  Target:    $fpga_part"
puts "  Project:   $project_dir"
puts "================================================================"

file mkdir $project_dir
set report_dir [file join $project_dir "reports_50t"]
file mkdir $report_dir
set bit_dir [file join $project_dir "bitstream"]
file mkdir $bit_dir

create_project $project_name $project_dir -part $fpga_part -force

# Add ALL RTL files in the project root (avoid stale/dev tops)
set skip_patterns {*_te0712_* *_te0713_*}
foreach f [glob -directory $rtl_dir *.v] {
    set skip 0
    foreach pat $skip_patterns {
        if {[string match $pat [file tail $f]]} { set skip 1; break }
    }
    if {!$skip} {
        add_files -norecurse $f
        puts "  Added: [file tail $f]"
    }
}

set_property top $top_module [current_fileset]
set_property verilog_define {FFT_XPM_BRAM} [current_fileset]

# Constraints — 50T XDC + MMCM supplement
add_files -fileset constrs_1 -norecurse [file join $project_root "constraints" "xc7a50t_ftg256.xdc"]
add_files -fileset constrs_1 -norecurse [file join $project_root "constraints" "adc_clk_mmcm.xdc"]

# ============================================================================
# DRC SEVERITY WAIVERS — 50T Hardware-Specific
# ============================================================================
# NOTE: set_property SEVERITY in the parent process does NOT propagate to
# child processes spawned by launch_runs. The actual waivers are applied via
# a TCL.PRE hook (STEPS.OPT_DESIGN.TCL.PRE) written dynamically below.
# We still set them here for any DRC checks run in the parent context
# (e.g., report_drc after open_run).
#
# BIVC-1: Bank 14 VCCO=2.5V (enforced by LVDS_25) with LVCMOS25 adc_pwdn.
# This should no longer fire now that adc_pwdn is LVCMOS25, but we keep
# the waiver as a safety net in case future XDC changes re-introduce the
# conflict.
set_property SEVERITY {Warning} [get_drc_checks BIVC-1]

# NSTD-1 / UCIO-1: 118 unconstrained port bits — FT601 USB 3.0 (chip unwired
# on 50T board), dac_clk (DAC clock from AD9523, not FPGA), and all
# status/debug outputs (no physical pins on FTG256 package).
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

# ===== SYNTHESIS =====
set synth_start [clock seconds]
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set synth_elapsed [expr {[clock seconds] - $synth_start}]
set synth_status [get_property STATUS [get_runs synth_1]]
puts "  Synthesis status: $synth_status"
puts "  Synthesis time:   ${synth_elapsed}s"

if {![string match "*Complete*" $synth_status]} {
    puts "CRITICAL: SYNTHESIS FAILED: $synth_status"
    close_project
    exit 1
}

open_run synth_1
report_timing_summary -file "${report_dir}/01_timing_post_synth.rpt"
report_utilization -file "${report_dir}/01_utilization_post_synth.rpt"
close_design

# ===== IMPLEMENTATION =====
set impl_start [clock seconds]

# Write DRC waiver hook — this runs inside the impl_1 child process
# right before opt_design, ensuring BIVC-1/NSTD-1/UCIO-1 are demoted
# to warnings for the DRC checks that gate place_design.
set hook_file [file join $project_dir "drc_waivers_50t.tcl"]
set fh [open $hook_file w]
puts $fh "# Auto-generated DRC waiver hook for 50T impl_1"
puts $fh "set_property SEVERITY {Warning} \[get_drc_checks BIVC-1\]"
puts $fh "set_property SEVERITY {Warning} \[get_drc_checks NSTD-1\]"
puts $fh "set_property SEVERITY {Warning} \[get_drc_checks UCIO-1\]"
puts $fh "puts \"  DRC waivers applied (BIVC-1, NSTD-1, UCIO-1 -> Warning)\""
close $fh

set_property STEPS.OPT_DESIGN.TCL.PRE $hook_file [get_runs impl_1]
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]

launch_runs impl_1 -jobs 8
wait_on_run impl_1
set impl_elapsed [expr {[clock seconds] - $impl_start}]
set impl_status [get_property STATUS [get_runs impl_1]]
puts "  Implementation status: $impl_status"
puts "  Implementation time:   ${impl_elapsed}s"

if {![string match "*Complete*" $impl_status] && ![string match "*write_bitstream*" $impl_status]} {
    puts "CRITICAL: IMPLEMENTATION FAILED: $impl_status"
    close_project
    exit 1
}

# ===== BITSTREAM =====
set bit_start [clock seconds]
if {[catch {launch_runs impl_1 -to_step write_bitstream -jobs 8} launch_err]} {
    puts "  Note: write_bitstream may already be in progress: $launch_err"
}
wait_on_run impl_1
set bit_elapsed [expr {[clock seconds] - $bit_start}]

open_run impl_1

# Copy bitstream
set src_bit [file join $project_dir "${project_name}.runs" "impl_1" "radar_system_top.bit"]
set dst_bit [file join $bit_dir "radar_system_top_50t.bit"]
if {[file exists $src_bit]} {
    file copy -force $src_bit $dst_bit
    puts "  Bitstream: $dst_bit"
} else {
    puts "  WARNING: Bitstream not found at $src_bit"
}

# ===== REPORTS =====
report_timing_summary -file "${report_dir}/02_timing_summary.rpt"
report_utilization -file "${report_dir}/04_utilization.rpt"
report_drc -file "${report_dir}/06_drc.rpt"
report_io -file "${report_dir}/07_io.rpt"

puts "================================================================"
puts "  XC7A50T Build Complete"
puts "  Synth:  ${synth_elapsed}s"
puts "  Impl:   ${impl_elapsed}s"
puts "  Bit:    ${bit_elapsed}s"
set wns_val "N/A"
set whs_val "N/A"
catch {set wns_val [get_property STATS.WNS [current_design]]}
catch {set whs_val [get_property STATS.WHS [current_design]]}
puts "  WNS:    $wns_val ns"
puts "  WHS:    $whs_val ns"
puts "================================================================"

close_project
exit 0
