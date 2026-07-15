if {$argc < 2} {
  puts "Usage: vivado -mode batch -source report_checkpoint_timing.tcl -tclargs <checkpoint.dcp> <report-prefix>"
  exit 1
}

set checkpoint [file normalize [lindex $argv 0]]
set report_prefix [file normalize [lindex $argv 1]]

if {![file exists $checkpoint]} {
  puts "ERROR: checkpoint does not exist: $checkpoint"
  exit 1
}

file mkdir [file dirname $report_prefix]
open_checkpoint $checkpoint

report_timing_summary -delay_type min_max -max_paths 100 \
  -file "${report_prefix}_summary.rpt"
report_timing -delay_type max -max_paths 100 -nworst 20 \
  -file "${report_prefix}_setup.rpt"
report_timing -delay_type min -max_paths 100 -nworst 20 \
  -file "${report_prefix}_hold.rpt"
report_clock_utilization -file "${report_prefix}_clocks.rpt"
report_drc -file "${report_prefix}_drc.rpt"
report_route_status -file "${report_prefix}_route_status.rpt"

set bram_report [open "${report_prefix}_stream_prefetch_bram.rpt" w]
set stream_prefetch_brams [get_cells -hier -quiet -filter {
  NAME =~ *stream_prefetch_fifo_i* && REF_NAME =~ RAMB*
}]
puts $bram_report "STREAM prefetch FIFO BRAM placement"
puts $bram_report "cell | LOC | clock region"
foreach cell [lsort $stream_prefetch_brams] {
  set loc [get_property LOC $cell]
  set sites [get_sites -quiet -of_objects $cell]
  set regions [get_clock_regions -quiet -of_objects $sites]
  puts $bram_report "$cell | $loc | $regions"
}
puts $bram_report "total BRAM cells: [llength $stream_prefetch_brams]"
close $bram_report

close_design
exit 0
