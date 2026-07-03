set repo_dir [file normalize [file join [file dirname [info script]] ..]]
set build_root [expr {[info exists ::env(TR_BUILD_ROOT)] ? $::env(TR_BUILD_ROOT) : [file join $repo_dir build_sim]}]
set build_dir [file join $build_root axis_async_fifo_clear_sim]

create_project -force traffic_replay_axis_async_fifo_clear $build_dir -part xcu200-fsgd2104-2-e
set_property target_language Verilog [current_project]
add_files -fileset sources_1 [list \
  [file join $repo_dir rtl axis_async_fifo.v] \
]
add_files -fileset sim_1 [list \
  [file join $repo_dir sim tb_axis_async_fifo_clear.sv] \
]
set_property top tb_axis_async_fifo_clear [get_filesets sim_1]
set_property xsim.simulate.runtime {all} [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation
quit
