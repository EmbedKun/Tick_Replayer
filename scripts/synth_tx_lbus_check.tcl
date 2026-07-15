set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set reports_dir [file join $repo_dir reports]
file mkdir $reports_dir

set_param general.maxThreads 4
read_verilog -sv [file join $repo_dir rtl replay_time_sync.sv]
read_verilog -sv [file join $repo_dir rtl axis_to_lbus_512.sv]
synth_design -top axis_to_lbus_512 -part xcu200-fsgd2104-2-e -flatten_hierarchy rebuilt

create_clock -name cmac_tx_clk -period 3.103 [get_ports clk]
report_utilization -file [file join $reports_dir tx_lbus_synth_utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 \
  -file [file join $reports_dir tx_lbus_synth_timing.rpt]

set setup_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $setup_paths] == 0} {
  puts "ERROR: TX LBUS synthesis produced no setup timing paths"
  exit 1
}
set setup_wns [get_property SLACK [lindex $setup_paths 0]]
puts [format "TX LBUS synthesis WNS: %.3f ns" $setup_wns]
if {$setup_wns < 0.0} {
  puts "ERROR: TX LBUS standalone synthesis does not meet 322.265625 MHz"
  exit 1
}
exit 0
