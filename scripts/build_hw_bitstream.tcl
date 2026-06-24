set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set reports_dir [file join $repo_dir reports]
file mkdir $reports_dir

source [file join $script_dir create_hw_project.tcl]

launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "Hardware synthesis status: $synth_status"
if {[string first "synth_design Complete" $synth_status] < 0} {
  puts "ERROR: hardware synthesis did not complete cleanly"
  exit 1
}

open_run synth_1
report_utilization -file [file join $reports_dir hw_synth_utilization.rpt]
report_timing_summary -file [file join $reports_dir hw_synth_timing_summary.rpt]
close_design

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "Hardware implementation status: $impl_status"
if {[string first "write_bitstream Complete" $impl_status] < 0} {
  puts "ERROR: hardware implementation/bitstream did not complete cleanly"
  exit 1
}

open_run impl_1
report_utilization -file [file join $reports_dir hw_impl_utilization.rpt]
report_timing_summary -file [file join $reports_dir hw_impl_timing_summary.rpt]
set bitfiles [glob -nocomplain [file join $repo_dir build vivado_hw ${project_name}.runs impl_1 *.bit]]
if {[llength $bitfiles] > 0} {
  puts "Bitstream: [lindex $bitfiles 0]"
}
exit
