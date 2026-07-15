set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]

source [file join $script_dir create_project.tcl]

set sim_files [list \
  [file join $repo_dir sim tb_dual_trace_replay_core_perf.sv] \
]
add_files -fileset sim_1 $sim_files
set_property file_type SystemVerilog [get_files $sim_files]
set_property top tb_dual_trace_replay_core_perf [get_filesets sim_1]
set_property xsim.simulate.runtime {all} [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
close_sim

set sim_log [file join $repo_dir build vivado traffic_replay.sim sim_1 behav xsim simulate.log]
if {![file exists $sim_log]} {
  puts "ERROR: dual-core performance simulation log was not generated"
  exit 1
}
set fh [open $sim_log r]
set sim_text [read $fh]
close $fh
if {[string first "PASS: staggered host ARM commands produced synchronized first TX" $sim_text] < 0 ||
    [string first "PASS: dual trace_replay_core concurrent preload correctness and throughput" $sim_text] < 0 ||
    [string first "Fatal:" $sim_text] >= 0} {
  puts "ERROR: dual-core performance simulation did not reach all clean PASS markers"
  exit 1
}
