set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]

foreach required_var {TRAFFIC_REPLAY_INPUT_DCP TRAFFIC_REPLAY_OUTPUT_DCP} {
  if {![info exists ::env($required_var)] || $::env($required_var) eq ""} {
    puts "ERROR: $required_var is required"
    exit 1
  }
}

set input_dcp [file normalize $::env(TRAFFIC_REPLAY_INPUT_DCP)]
set output_dcp [file normalize $::env(TRAFFIC_REPLAY_OUTPUT_DCP)]
if {![file exists $input_dcp]} {
  puts "ERROR: input checkpoint does not exist: $input_dcp"
  exit 1
}

set report_dir [file join $repo_dir reports route_checkpoint]
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

set route_directive Default
if {[info exists ::env(TRAFFIC_REPLAY_ROUTE_DIRECTIVE)] &&
    $::env(TRAFFIC_REPLAY_ROUTE_DIRECTIVE) ne ""} {
  set route_directive $::env(TRAFFIC_REPLAY_ROUTE_DIRECTIVE)
}
set valid_route_directives {
  Default Explore AggressiveExplore NoTimingRelaxation MoreGlobalIterations
  HigherDelayCost AdvancedSkewModeling AlternateCLBRouting RuntimeOptimized Quick
}
if {[lsearch -exact $valid_route_directives $route_directive] < 0} {
  puts "ERROR: unsupported route directive: $route_directive"
  exit 1
}

puts "Opening post-placement checkpoint: $input_dcp"
open_checkpoint $input_dcp
report_timing_summary -file [file join $report_dir timing_before_route.rpt]

puts "Running route_design -directive $route_directive -tns_cleanup"
route_design -directive $route_directive -tns_cleanup

write_checkpoint -force $output_dcp
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_timing_summary -file [file join $report_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 100 -nworst 2 \
  -file [file join $report_dir setup_paths.rpt]
report_timing -delay_type min -max_paths 100 -nworst 2 \
  -file [file join $report_dir hold_paths.rpt]
report_bus_skew -warn_on_violation -file [file join $report_dir bus_skew.rpt]

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
puts "ROUTE_CHECKPOINT_RESULT directive=$route_directive WNS=$wns WHS=$whs"
puts "Routed checkpoint: $output_dcp"
exit
