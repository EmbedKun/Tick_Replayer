set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set reports_dir [file join $repo_dir reports]
file mkdir $reports_dir

set_param general.maxThreads 4
read_verilog [file join $repo_dir rtl axis_async_fifo.v]
read_verilog -sv [file join $repo_dir rtl rx_capture_bd_core.sv]
synth_design -top rx_capture_core -part xcu200-fsgd2104-2-e -flatten_hierarchy rebuilt

create_clock -name ctrl_clk -period 3.333 [get_ports clk]
create_clock -name rx_clk -period 3.103 [get_ports rx_clk]
set_clock_groups -asynchronous -group [get_clocks ctrl_clk] -group [get_clocks rx_clk]

report_utilization -file [file join $reports_dir rx_measurement_synth_utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 \
  -file [file join $reports_dir rx_measurement_synth_timing.rpt]

set setup_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $setup_paths] == 0} {
  puts "ERROR: RX measurement synthesis produced no setup timing paths"
  exit 1
}
set setup_wns [get_property SLACK [lindex $setup_paths 0]]
puts [format "RX measurement synthesis WNS: %.3f ns" $setup_wns]
if {$setup_wns < 0.0} {
  puts "ERROR: RX measurement standalone synthesis does not meet its clock targets"
  exit 1
}
exit
