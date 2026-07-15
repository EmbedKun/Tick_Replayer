set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set build_root [expr {[info exists ::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)] && $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT) ne "" ? [file normalize $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)] : [file join $repo_dir build]}]
set build_dir [file join $build_root stream_ring_reader_sim]
file mkdir $build_dir

create_project -force traffic_replay_stream_ring_reader $build_dir -part xcu200-fsgd2104-2-e
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [list \
  [file join $repo_dir rtl traffic_replay_pkg.sv] \
  [file join $repo_dir rtl ddr_stream_reader.sv] \
]
set sim_files [list \
  [file join $repo_dir sim tb_ddr_stream_reader_ring.sv] \
]

add_files -fileset sources_1 $rtl_files
add_files -fileset sim_1 $sim_files
set_property file_type SystemVerilog [get_files [concat $rtl_files $sim_files]]
set_property top tb_ddr_stream_reader_ring [get_filesets sim_1]
set_property xsim.simulate.runtime {all} [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

launch_simulation
close_sim

set sim_log [file join $build_dir traffic_replay_stream_ring_reader.sim sim_1 behav xsim simulate.log]
if {![file exists $sim_log]} {
  puts "ERROR: stream ring reader simulation log was not generated"
  exit 1
}
set fh [open $sim_log r]
set sim_text [read $fh]
close $fh
if {[string first "PASS: ddr_stream_reader ring-mode robustness simulation completed" $sim_text] < 0 ||
    [string first "Fatal:" $sim_text] >= 0} {
  puts "ERROR: stream ring reader simulation did not reach a clean PASS marker"
  exit 1
}
exit 0
