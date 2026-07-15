set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]

if {![info exists ::env(TRAFFIC_REPLAY_INPUT_DCP)] ||
    $::env(TRAFFIC_REPLAY_INPUT_DCP) eq ""} {
  puts "ERROR: TRAFFIC_REPLAY_INPUT_DCP is required"
  exit 1
}
if {![info exists ::env(TRAFFIC_REPLAY_OUTPUT_DCP)] ||
    $::env(TRAFFIC_REPLAY_OUTPUT_DCP) eq ""} {
  puts "ERROR: TRAFFIC_REPLAY_OUTPUT_DCP is required"
  exit 1
}

set input_dcp [file normalize $::env(TRAFFIC_REPLAY_INPUT_DCP)]
set output_dcp [file normalize $::env(TRAFFIC_REPLAY_OUTPUT_DCP)]
if {![file exists $input_dcp]} {
  puts "ERROR: input checkpoint does not exist: $input_dcp"
  exit 1
}

set report_dir [file join $repo_dir reports postroute_timing_repair]
if {[info exists ::env(TRAFFIC_REPLAY_REPORT_DIR)] &&
    $::env(TRAFFIC_REPLAY_REPORT_DIR) ne ""} {
  set report_dir [file normalize $::env(TRAFFIC_REPLAY_REPORT_DIR)]
}
file mkdir $report_dir
file mkdir [file dirname $output_dcp]

set threads 8
if {[info exists ::env(TRAFFIC_REPLAY_VIVADO_THREADS)] &&
    $::env(TRAFFIC_REPLAY_VIVADO_THREADS) ne ""} {
  set threads $::env(TRAFFIC_REPLAY_VIVADO_THREADS)
}
if {![string is integer -strict $threads] || $threads < 1} {
  puts "ERROR: TRAFFIC_REPLAY_VIVADO_THREADS must be a positive integer"
  exit 1
}
set_param general.maxThreads $threads

set repair_mode "hold"
if {[info exists ::env(TRAFFIC_REPLAY_TIMING_REPAIR_MODE)] &&
    $::env(TRAFFIC_REPLAY_TIMING_REPAIR_MODE) ne ""} {
  set repair_mode $::env(TRAFFIC_REPLAY_TIMING_REPAIR_MODE)
}
if {[lsearch -exact {hold aggressive_hold explore aggressive_explore setup aggressive_setup explicit_setup clock} $repair_mode] < 0} {
  puts "ERROR: TRAFFIC_REPLAY_TIMING_REPAIR_MODE must be hold, aggressive_hold, explore, aggressive_explore, setup, aggressive_setup, explicit_setup, or clock"
  exit 1
}

puts "Opening routed checkpoint: $input_dcp"
open_checkpoint $input_dcp
report_timing_summary -file [file join $report_dir timing_before.rpt]

switch $repair_mode {
  hold {
    puts "Running post-route physical optimization: hold_fix"
    phys_opt_design -hold_fix
  }
  aggressive_hold {
    puts "Running post-route physical optimization: aggressive_hold_fix"
    phys_opt_design -aggressive_hold_fix
  }
  explore {
    puts "Running post-route physical optimization: ExploreWithHoldFix"
    phys_opt_design -directive ExploreWithHoldFix
  }
  aggressive_explore {
    puts "Running post-route physical optimization: ExploreWithAggressiveHoldFix"
    phys_opt_design -directive ExploreWithAggressiveHoldFix
  }
  setup {
    puts "Running post-route physical optimization: Explore"
    phys_opt_design -directive Explore
  }
  aggressive_setup {
    puts "Running post-route physical optimization: AggressiveExplore"
    phys_opt_design -directive AggressiveExplore
  }
  explicit_setup {
    puts "Running explicit post-route setup optimizations"
    phys_opt_design -placement_opt -routing_opt -rewire \
      -critical_cell_opt -critical_pin_opt
  }
  clock {
    puts "Running post-route physical optimization: clock_opt"
    phys_opt_design -clock_opt
  }
}

write_checkpoint -force $output_dcp
report_route_status -file [file join $report_dir route_status_after.rpt]
report_drc -file [file join $report_dir drc_after.rpt]
report_timing_summary -file [file join $report_dir timing_after.rpt]
report_timing -delay_type min -max_paths 30 -nworst 1 \
  -file [file join $report_dir hold_paths_after.rpt]
report_timing -delay_type max -max_paths 30 -nworst 1 \
  -file [file join $report_dir setup_paths_after.rpt]

set setup_paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
set wns 0.0
set whs 0.0
if {[llength $setup_paths] > 0} {
  set wns [get_property SLACK [lindex $setup_paths 0]]
}
if {[llength $hold_paths] > 0} {
  set whs [get_property SLACK [lindex $hold_paths 0]]
}
puts "POSTROUTE_TIMING_RESULT WNS=$wns WHS=$whs"
puts "Post-route checkpoint: $output_dcp"
exit
