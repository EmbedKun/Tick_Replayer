set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set build_dir [file join $repo_dir build scheduled_axis_fifo_sim]

create_project -force scheduled_axis_fifo_sim $build_dir -part xcu200-fsgd2104-2-e
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
add_files -fileset sources_1 [list \
  [file join $repo_dir rtl axis_async_fifo.v] \
  [file join $repo_dir rtl scheduled_axis_async_fifo.sv] \
]
add_files -fileset sim_1 [file join $repo_dir sim tb_scheduled_axis_async_fifo.sv]
set_property file_type SystemVerilog [get_files *.sv]
set_property top tb_scheduled_axis_async_fifo [get_filesets sim_1]
set_property xsim.simulate.runtime {all} [get_filesets sim_1]
launch_simulation
