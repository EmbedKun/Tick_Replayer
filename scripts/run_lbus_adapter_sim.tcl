set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]

create_project -force traffic_replay_lbus_adapter_sim [file join $repo_dir build sim_lbus_adapters] -part xcu200-fsgd2104-2-e
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -fileset sim_1 [list \
  [file join $repo_dir rtl axis_to_lbus_512.sv] \
  [file join $repo_dir rtl lbus_to_axis_512.sv] \
  [file join $repo_dir sim tb_lbus_adapters.sv] \
]
set_property file_type SystemVerilog [get_files [list \
  [file join $repo_dir rtl axis_to_lbus_512.sv] \
  [file join $repo_dir rtl lbus_to_axis_512.sv] \
  [file join $repo_dir sim tb_lbus_adapters.sv] \
]]
set_property top tb_lbus_adapters [get_filesets sim_1]
set_property xsim.simulate.runtime {all} [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
close_sim
