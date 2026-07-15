if {$argc != 1} {
  puts "Usage: vivado -mode batch -source scripts/report_pcie_placement.tcl -tclargs design.dcp"
  exit 1
}

set dcp [file normalize [lindex $argv 0]]
if {![file exists $dcp]} {
  puts "ERROR: checkpoint not found: $dcp"
  exit 1
}

open_checkpoint $dcp
puts "Checkpoint: $dcp"

set patterns [list \
  {.*core_rc_tdata_reg_upper_reg\[[0-9]+\]$} \
  {.*core_rc_tdata_reg_upper_user_clk_reg\[[0-9]+\]$} \
  {.*core_rc_tdata_reg_lower_reg\[[0-9]+\]$} \
  {.*core_rc_tdata_reg_lower_user_clk_reg\[[0-9]+\]$} \
]

foreach pattern $patterns {
  set cells [lsort [get_cells -hier -regexp $pattern]]
  puts "Pattern: $pattern count=[llength $cells]"
  foreach cell [lrange $cells 0 7] {
    set loc [get_property LOC $cell]
    set bel [get_property BEL $cell]
    set site [get_sites -quiet $loc]
    set clock_region ""
    set slr ""
    if {[llength $site] > 0} {
      set clock_region [get_property CLOCK_REGION [lindex $site 0]]
      set slr_objects [get_slrs -quiet -of_objects [lindex $site 0]]
      if {[llength $slr_objects] > 0} {
        set slr [lindex $slr_objects 0]
      }
    }
    puts "  $cell LOC=$loc BEL=$bel CLOCK_REGION=$clock_region SLR=$slr"
  }
}
exit
