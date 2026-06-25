if {$argc < 1} {
  puts "Usage: vivado -mode batch -source scripts/program_remote.tcl -tclargs path/to/bitfile.bit"
  exit 1
}

set bitfile [file normalize [lindex $argv 0]]
if {![file exists $bitfile]} {
  puts "ERROR: bitfile not found: $bitfile"
  exit 1
}

set hw_server_url 172.22.5.106:3121

open_hw_manager
connect_hw_server -url $hw_server_url
set targets [get_hw_targets *]
if {[llength $targets] == 0} {
  puts "ERROR: no hardware target found on $hw_server_url"
  exit 1
}

current_hw_target [lindex $targets 0]
open_hw_target

set devices [get_hw_devices xcu200*]
if {[llength $devices] == 0} {
  set devices [get_hw_devices]
}
if {[llength $devices] == 0} {
  puts "ERROR: no FPGA devices found"
  exit 1
}

set dev [lindex $devices 0]
current_hw_device $dev
refresh_hw_device $dev
set_property PROGRAM.FILE $bitfile $dev
set ltxfile [file rootname $bitfile].ltx
if {[file exists $ltxfile]} {
  set_property PROBES.FILE $ltxfile $dev
  puts "Using probes file $ltxfile"
}
program_hw_devices $dev
refresh_hw_device $dev
puts "Programmed $dev with $bitfile"
exit
