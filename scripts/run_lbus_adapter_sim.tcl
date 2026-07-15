set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set build_dir [file join $repo_dir build sim_lbus_adapters]

create_project -force traffic_replay_lbus_adapter_sim $build_dir -part xcu200-fsgd2104-2-e
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -fileset sim_1 [list \
  [file join $repo_dir rtl replay_time_sync.sv] \
  [file join $repo_dir rtl axis_to_lbus_512.sv] \
  [file join $repo_dir rtl lbus_to_axis_512.sv] \
  [file join $repo_dir sim tb_lbus_adapters.sv] \
]
set_property file_type SystemVerilog [get_files [list \
  [file join $repo_dir rtl replay_time_sync.sv] \
  [file join $repo_dir rtl axis_to_lbus_512.sv] \
  [file join $repo_dir rtl lbus_to_axis_512.sv] \
  [file join $repo_dir sim tb_lbus_adapters.sv] \
]]
set_property top tb_lbus_adapters [get_filesets sim_1]
set_property xsim.simulate.runtime {all} [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
close_sim

set sim_log [file join $build_dir traffic_replay_lbus_adapter_sim.sim sim_1 behav xsim simulate.log]
if {![file exists $sim_log]} {
  puts "ERROR: LBUS adapter simulation log was not generated"
  exit 1
}
set fh [open $sim_log r]
set sim_text [read $fh]
close $fh
if {[string first "PASS: LBUS adapter full-rate 64B burst" $sim_text] < 0 ||
    [string first "PASS: CMAC-domain egress scheduler" $sim_text] < 0 ||
    [string first "Fatal:" $sim_text] >= 0} {
  puts "ERROR: LBUS adapter simulation did not reach all clean PASS markers"
  exit 1
}
