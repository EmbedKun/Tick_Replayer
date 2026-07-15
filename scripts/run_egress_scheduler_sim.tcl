set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set build_dir [file join $repo_dir build egress_scheduler_sim]

create_project -force egress_scheduler_sim $build_dir -part xcu200-fsgd2104-2-e
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
add_files -fileset sources_1 [list \
  [file join $repo_dir rtl replay_global_timebase.sv] \
  [file join $repo_dir rtl replay_time_sync.sv] \
  [file join $repo_dir rtl axis_async_fifo.v] \
  [file join $repo_dir rtl scheduled_axis_async_fifo.sv] \
  [file join $repo_dir rtl axis_to_lbus_512.sv] \
]
add_files -fileset sim_1 [file join $repo_dir sim tb_egress_scheduler_pipeline.sv]
set_property file_type SystemVerilog [get_files *.sv]
set_property top tb_egress_scheduler_pipeline [get_filesets sim_1]
set_property xsim.simulate.runtime {all} [get_filesets sim_1]
launch_simulation
close_sim

set sim_log [file join $build_dir egress_scheduler_sim.sim sim_1 behav xsim simulate.log]
if {![file exists $sim_log]} {
  puts "ERROR: egress scheduler simulation log was not generated"
  exit 1
}
set fh [open $sim_log r]
set sim_text [read $fh]
close $fh
if {[string first "PASS: egress 64B fractional 2/3-tick cadence" $sim_text] < 0 ||
    [string first "Fatal:" $sim_text] >= 0} {
  puts "ERROR: egress scheduler simulation did not reach a clean PASS marker"
  exit 1
}
