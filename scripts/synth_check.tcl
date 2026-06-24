set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir create_project.tcl]

launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "Synthesis status: $synth_status"
if {[string first "synth_design Complete" $synth_status] < 0} {
  puts "ERROR: synthesis did not complete cleanly"
  exit 1
}

open_run synth_1
report_utilization -file [file join [file dirname [file normalize [info script]]] .. reports synth_utilization.rpt]
report_timing_summary -file [file join [file dirname [file normalize [info script]]] .. reports synth_timing_summary.rpt]
exit
