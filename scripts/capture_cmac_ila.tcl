set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]

set hw_server_url 172.22.5.106:3121
set ltxfile ""
set outfile [file join $repo_dir reports cmac_tx_ila_capture.csv]

if {$argc >= 1} {
  set ltxfile [file normalize [lindex $argv 0]]
}
if {$argc >= 2} {
  set outfile [file normalize [lindex $argv 1]]
}
if {$ltxfile eq ""} {
  puts "ERROR: probes .ltx file argument is required"
  puts "Usage: vivado -mode batch -source scripts/capture_cmac_ila.tcl -tclargs path/to/design.ltx ?out.csv?"
  exit 1
}
if {![file exists $ltxfile]} {
  puts "ERROR: probes file not found: $ltxfile"
  exit 1
}

file mkdir [file dirname $outfile]

open_hw_manager
connect_hw_server -url $hw_server_url
set targets [get_hw_targets *]
if {[llength $targets] == 0} {
  puts "ERROR: no hardware target found on $hw_server_url"
  exit 1
}
open_hw_target [lindex $targets 0]

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
set_property PROBES.FILE $ltxfile $dev
refresh_hw_device $dev

set ilas [get_hw_ilas]
if {[llength $ilas] == 0} {
  puts "ERROR: no ILA cores found"
  exit 1
}

set ila [lindex $ilas 0]
current_hw_ila $ila
reset_hw_ila $ila
catch {set_property CONTROL.DATA_DEPTH 1024 $ila}
catch {set_property CONTROL.TRIGGER_POSITION 128 $ila}
catch {set_property CONTROL.TRIGGER_CONDITION OR $ila}

set tvalid_probe [get_hw_probes traffic_replay_bd_i/tx_axis_fifo_m_axis_tvalid -of_objects $ila]
if {[llength $tvalid_probe] == 0} {
  puts "ERROR: CMAC TX tvalid probe not found"
  exit 1
}

set_property TRIGGER_COMPARE_VALUE {eq1'b1} $tvalid_probe
run_hw_ila $ila
wait_on_hw_ila $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $outfile $data
puts "Wrote ILA capture CSV: $outfile"
exit
