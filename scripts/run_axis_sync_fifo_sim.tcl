set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set build_dir [file join $repo_dir build sim_axis_sync_fifo]
file mkdir $build_dir

create_project -force sim_axis_sync_fifo $build_dir -part xcu200-fsgd2104-2-e
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]

add_files -fileset sources_1 [list \
  [file join $repo_dir rtl axis_sync_fifo.sv] \
  [file join $repo_dir sim tb_axis_sync_fifo.sv] \
]
set_property file_type SystemVerilog [get_files [list \
  [file join $repo_dir rtl axis_sync_fifo.sv] \
  [file join $repo_dir sim tb_axis_sync_fifo.sv] \
]]

set_property top tb_axis_sync_fifo [get_filesets sim_1]
launch_simulation
run all
