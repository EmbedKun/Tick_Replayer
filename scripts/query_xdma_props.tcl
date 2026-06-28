set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]

if {[info exists ::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)] && $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT) ne ""} {
  set hw_build_root [file normalize $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)]
} else {
  set hw_build_root [file join $repo_dir build]
}

set project_file [file join $hw_build_root vivado_hw traffic_replay_hw.xpr]
set bd_file [file join $hw_build_root vivado_hw traffic_replay_hw.srcs sources_1 bd traffic_replay_bd traffic_replay_bd.bd]

open_project $project_file
open_bd_design $bd_file

set cell [get_bd_cells xdma_0]
puts "XDMA property subset:"
foreach prop [lsort [list_property $cell]] {
  if {[regexp -nocase {(CONFIG\..*(vendor|device|subsystem|class|revision|pf|function|bar|id))} $prop]} {
    puts [format "%-55s %s" $prop [get_property $prop $cell]]
  }
}

puts "\nXDMA focused properties:"
foreach prop {
  CONFIG.functional_mode
  CONFIG.en_dma_and_bridge
  CONFIG.mode_selection
  CONFIG.vendor_id
  CONFIG.pf0_device_id
  CONFIG.pf0_class_code
  CONFIG.pf0_class_code_base
  CONFIG.pf0_class_code_sub
  CONFIG.pf0_class_code_interface
  CONFIG.pf0_base_class_menu
  CONFIG.pf0_sub_class_interface_menu
  CONFIG.pf0_bar0_enabled
  CONFIG.pf0_bar0_type
  CONFIG.pf0_bar0_size
  CONFIG.pf0_bar0_scale
  CONFIG.pf0_bar1_enabled
  CONFIG.pf0_bar1_type
  CONFIG.pf0_bar1_size
  CONFIG.pf0_bar1_scale
  CONFIG.bar_indicator
  CONFIG.barlite2
  CONFIG.axilite_master_en
  CONFIG.xdma_en
  CONFIG.xdma_pcie_64bit_en
  CONFIG.xdma_size
  CONFIG.xdma_scale
  CONFIG.axil_master_64bit_en
  CONFIG.axil_master_prefetchable
  CONFIG.axilite_master_size
  CONFIG.axilite_master_scale
  CONFIG.pciebar2axibar_xdma
  CONFIG.pciebar2axibar_axil_master
  CONFIG.axibar_num
  CONFIG.axibar_0
  CONFIG.axibar_highaddr_0
} {
  if {[llength [list_property $cell $prop]] > 0} {
    puts [format "%-45s %s" $prop [get_property $prop $cell]]
    set rc [catch {list_property_value $prop $cell} vals]
    if {$rc == 0 && [llength $vals] > 0} {
      puts [format "  values: %s" [join $vals {, }]]
    }
  }
}

close_project
