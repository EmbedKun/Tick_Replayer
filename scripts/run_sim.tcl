set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]

source [file join $script_dir create_project.tcl]

set sim_files [list \
  [file join $repo_dir sim tb_trace_replay_core.sv] \
]
add_files -fileset sim_1 $sim_files
set_property file_type SystemVerilog [get_files $sim_files]
set_property top tb_trace_replay_core [get_filesets sim_1]
set_property xsim.simulate.runtime {20us} [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
quit
