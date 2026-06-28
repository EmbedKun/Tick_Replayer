set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set reports_dir [file join $repo_dir reports]
file mkdir $reports_dir

set_param general.maxThreads 1

if {[info exists ::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)] && $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT) ne ""} {
  set hw_build_root [file normalize $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)]
} else {
  set hw_build_root [file join $repo_dir build]
}

set build_dir [file join $hw_build_root vivado_hw]
set project_name traffic_replay_hw
set bd_name traffic_replay_bd
set project_file [file join $build_dir ${project_name}.xpr]

if {![file exists $project_file]} {
  puts "ERROR: hardware Vivado project not found at $project_file"
  puts "Run bash scripts/run_vivado.sh hwbd first."
  exit 1
}

set vivado_jobs 1
if {[info exists ::env(TRAFFIC_REPLAY_VIVADO_JOBS)] && $::env(TRAFFIC_REPLAY_VIVADO_JOBS) ne ""} {
  set vivado_jobs $::env(TRAFFIC_REPLAY_VIVADO_JOBS)
}

open_project $project_file
set impl_strategy "Performance_ExplorePostRoutePhysOpt"
if {[info exists ::env(TRAFFIC_REPLAY_IMPL_STRATEGY)] && $::env(TRAFFIC_REPLAY_IMPL_STRATEGY) ne ""} {
  set impl_strategy $::env(TRAFFIC_REPLAY_IMPL_STRATEGY)
}
if {[catch {set_property strategy $impl_strategy [get_runs impl_1]} strategy_err]} {
  puts "WARNING: failed to set implementation strategy $impl_strategy: $strategy_err"
}
set wrapper_file [file join $build_dir $project_name.gen sources_1 bd $bd_name hdl ${bd_name}_wrapper.v]
if {[file exists $wrapper_file] && [llength [get_files -quiet $wrapper_file]] == 0} {
  add_files -norecurse $wrapper_file
}
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs $vivado_jobs
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "Hardware synthesis status: $synth_status"
if {[string first "synth_design Complete" $synth_status] < 0} {
  puts "ERROR: hardware synthesis did not complete cleanly"
  exit 1
}

open_run synth_1
report_utilization -file [file join $reports_dir hw_synth_utilization.rpt]
report_timing_summary -file [file join $reports_dir hw_synth_timing_summary.rpt]
close_design

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs $vivado_jobs
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "Hardware implementation status: $impl_status"
if {[string first "write_bitstream Complete" $impl_status] < 0} {
  puts "ERROR: hardware implementation/bitstream did not complete cleanly"
  exit 1
}

open_run impl_1
report_utilization -file [file join $reports_dir hw_impl_utilization.rpt]
report_timing_summary -file [file join $reports_dir hw_impl_timing_summary.rpt]
set bitfiles [glob -nocomplain [file join $build_dir ${project_name}.runs impl_1 *.bit]]
if {[llength $bitfiles] > 0} {
  puts "Bitstream: [lindex $bitfiles 0]"
}
exit
