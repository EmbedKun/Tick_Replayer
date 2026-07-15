set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set build_dir [file join $repo_dir build sim_replay_time_sync]

create_project -force sim_replay_time_sync $build_dir -part xcu200-fsgd2104-2-e
add_files -fileset sources_1 [list \
  [file join $repo_dir rtl replay_global_timebase.sv] \
  [file join $repo_dir rtl replay_time_sync.sv] \
]
add_files -fileset sim_1 [file join $repo_dir sim tb_replay_time_sync.sv]
set_property file_type SystemVerilog [get_files *.sv]
set_property top tb_replay_time_sync [get_filesets sim_1]
set_property xsim.simulate.runtime {all} [get_filesets sim_1]
launch_simulation
