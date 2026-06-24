set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set build_dir [file join $repo_dir build vivado]
file mkdir $build_dir

set project_name traffic_replay
set part_name xcu200-fsgd2104-2-e
set board_part xilinx.com:au200:part0:1.3

create_project -force $project_name $build_dir -part $part_name
set_property board_part $board_part [current_project]
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [list \
  [file join $repo_dir rtl traffic_replay_pkg.sv] \
  [file join $repo_dir rtl axi_lite_regs.sv] \
  [file join $repo_dir rtl replay_scheduler.sv] \
  [file join $repo_dir rtl replay_tx_engine.sv] \
  [file join $repo_dir rtl host_stream_parser.sv] \
  [file join $repo_dir rtl ddr_trace_reader.sv] \
  [file join $repo_dir rtl trace_replay_core.sv] \
  [file join $repo_dir rtl traffic_replay_bd_core.v] \
  [file join $repo_dir rtl traffic_replay_top_stub.sv] \
]

add_files -fileset sources_1 $rtl_files
set sv_files [lsearch -all -inline $rtl_files *.sv]
if {[llength $sv_files] > 0} {
  set_property file_type SystemVerilog [get_files $sv_files]
}
set_property top traffic_replay_top_stub [current_fileset]
update_compile_order -fileset sources_1

if {[file isdirectory [file join $repo_dir constraints]]} {
  set xdc_files [glob -nocomplain [file join $repo_dir constraints *.xdc]]
  if {[llength $xdc_files] > 0} {
    add_files -fileset constrs_1 $xdc_files
  }
}

puts "Project created at $build_dir"
