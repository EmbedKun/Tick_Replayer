set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]

set traffic_replay_vivado_threads 1
if {[info exists ::env(TRAFFIC_REPLAY_VIVADO_THREADS)] && $::env(TRAFFIC_REPLAY_VIVADO_THREADS) ne ""} {
  set traffic_replay_vivado_threads $::env(TRAFFIC_REPLAY_VIVADO_THREADS)
}
if {![string is integer -strict $traffic_replay_vivado_threads] || $traffic_replay_vivado_threads < 1} {
  puts "ERROR: TRAFFIC_REPLAY_VIVADO_THREADS must be a positive integer"
  exit 1
}
set_param general.maxThreads $traffic_replay_vivado_threads
puts "Traffic replay Vivado maxThreads: $traffic_replay_vivado_threads"

proc source_vivado_init {subdir} {
  if {![info exists ::env(XILINX_VIVADO)] || $::env(XILINX_VIVADO) eq ""} {
    return
  }
  set init_dir [file normalize [file join $::env(XILINX_VIVADO) scripts $subdir]]
  set init_file [file join $init_dir init.tcl]
  if {![file exists $init_file]} {
    return
  }
  set init_files [list]
  if {$subdir eq "ipintegrator"} {
    set init_files [list \
      utils.tcl mig_utils.tcl board_utils.tcl utils_dbg.tcl clkrst.tcl \
      replace_bd_cell.tcl addr.tcl testbench.tcl sc_cosim_util.tcl \
      utils_timing.tcl sdsoc_pfm.tcl gt_utils.tcl \
    ]
  } elseif {$subdir eq "xguifrmwork"} {
    set init_files [list utils.tcl]
  }
  if {[llength $init_files] > 0} {
    foreach rel_file $init_files {
      set abs_file [file join $init_dir $rel_file]
      if {[file exists $abs_file]} {
        if {[catch {source -notrace $abs_file} init_err]} {
          puts "WARNING: failed to source Vivado init file $abs_file: $init_err"
        }
      }
    }
    return
  }
  set old_dir [pwd]
  cd $init_dir
  if {[catch {source -notrace $init_file} init_err]} {
    puts "WARNING: failed to source Vivado init file $init_file: $init_err"
  }
  cd $old_dir
}

source_vivado_init ipintegrator
source_vivado_init xguifrmwork

if {[info exists ::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)] && $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT) ne ""} {
  set hw_build_root [file normalize $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)]
} else {
  set hw_build_root [file join $repo_dir build]
}
set build_dir [file join $hw_build_root vivado_hw]
file mkdir $build_dir

set traffic_replay_port_count 2
if {[info exists ::env(TRAFFIC_REPLAY_PORT_COUNT)] && $::env(TRAFFIC_REPLAY_PORT_COUNT) ne ""} {
  set traffic_replay_port_count $::env(TRAFFIC_REPLAY_PORT_COUNT)
}
if {![string is integer -strict $traffic_replay_port_count] || $traffic_replay_port_count < 1 || $traffic_replay_port_count > 2} {
  puts "ERROR: TRAFFIC_REPLAY_PORT_COUNT must be 1 or 2"
  exit 1
}
set enable_port1 [expr {$traffic_replay_port_count >= 2}]
puts "Traffic replay hardware port count: $traffic_replay_port_count"

set traffic_replay_ddr_banks 1
if {[info exists ::env(TRAFFIC_REPLAY_DDR_BANKS)] && $::env(TRAFFIC_REPLAY_DDR_BANKS) ne ""} {
  set traffic_replay_ddr_banks $::env(TRAFFIC_REPLAY_DDR_BANKS)
}
if {![string is integer -strict $traffic_replay_ddr_banks] || ($traffic_replay_ddr_banks != 1 && $traffic_replay_ddr_banks != 2 && $traffic_replay_ddr_banks != 4)} {
  puts "ERROR: TRAFFIC_REPLAY_DDR_BANKS must be 1, 2, or 4"
  exit 1
}
set ddr_bank_ids [list]
for {set ddr_bank_idx 0} {$ddr_bank_idx < $traffic_replay_ddr_banks} {incr ddr_bank_idx} {
  lappend ddr_bank_ids $ddr_bank_idx
}
puts "Traffic replay DDR bank count: $traffic_replay_ddr_banks"

set traffic_replay_port0_multi_ddr 0
if {[info exists ::env(TRAFFIC_REPLAY_PORT0_MULTI_DDR)] && $::env(TRAFFIC_REPLAY_PORT0_MULTI_DDR) ne ""} {
  set traffic_replay_port0_multi_ddr $::env(TRAFFIC_REPLAY_PORT0_MULTI_DDR)
}
if {![string is integer -strict $traffic_replay_port0_multi_ddr] || ($traffic_replay_port0_multi_ddr != 0 && $traffic_replay_port0_multi_ddr != 1)} {
  puts "ERROR: TRAFFIC_REPLAY_PORT0_MULTI_DDR must be 0 or 1"
  exit 1
}
if {$traffic_replay_ddr_banks == 1 && $traffic_replay_port0_multi_ddr} {
  puts "ERROR: TRAFFIC_REPLAY_PORT0_MULTI_DDR requires TRAFFIC_REPLAY_DDR_BANKS=2 or 4"
  exit 1
}
puts "Traffic replay port0 multi-DDR read access: $traffic_replay_port0_multi_ddr"

set enable_rs_fec 1
if {[info exists ::env(TRAFFIC_REPLAY_ENABLE_RS_FEC)] && $::env(TRAFFIC_REPLAY_ENABLE_RS_FEC) ne ""} {
  set enable_rs_fec $::env(TRAFFIC_REPLAY_ENABLE_RS_FEC)
}
if {![string is integer -strict $enable_rs_fec] || ($enable_rs_fec != 0 && $enable_rs_fec != 1)} {
  puts "ERROR: TRAFFIC_REPLAY_ENABLE_RS_FEC must be 0 or 1"
  exit 1
}
puts "Traffic replay CMAC RS-FEC: $enable_rs_fec"

set project_name traffic_replay_hw
set bd_name traffic_replay_bd
set part_name xcu200-fsgd2104-2-e
set board_part xilinx.com:au200:part0:1.3

create_project -force $project_name $build_dir -part $part_name
set_property board_part $board_part [current_project]
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]

set hw_xdc [file join $repo_dir constraints traffic_replay_u200.xdc]
if {[file exists $hw_xdc]} {
  add_files -fileset constrs_1 $hw_xdc
  set_property used_in_synthesis false [get_files $hw_xdc]
  set_property used_in_implementation true [get_files $hw_xdc]
}

set hw_qsfp1_xdc [file join $repo_dir constraints traffic_replay_u200_qsfp1.xdc]
if {$enable_port1 && [file exists $hw_qsfp1_xdc]} {
  add_files -fileset constrs_1 $hw_qsfp1_xdc
  set_property used_in_synthesis false [get_files $hw_qsfp1_xdc]
  set_property used_in_implementation true [get_files $hw_qsfp1_xdc]
}

set hw_floorplan_xdc [file join $repo_dir constraints traffic_replay_u200_floorplan.xdc]
if {[file exists $hw_floorplan_xdc]} {
  add_files -fileset constrs_1 $hw_floorplan_xdc
  set_property used_in_synthesis false [get_files $hw_floorplan_xdc]
  set_property used_in_implementation true [get_files $hw_floorplan_xdc]
}

set rtl_files [list \
  [file join $repo_dir rtl traffic_replay_pkg.sv] \
  [file join $repo_dir rtl axi_lite_regs.sv] \
  [file join $repo_dir rtl replay_scheduler.sv] \
  [file join $repo_dir rtl replay_tx_engine.sv] \
  [file join $repo_dir rtl host_stream_parser.sv] \
  [file join $repo_dir rtl axis_sync_fifo.sv] \
  [file join $repo_dir rtl axis_to_lbus_512.sv] \
  [file join $repo_dir rtl axis_to_lbus_512_bd.v] \
  [file join $repo_dir rtl lbus_to_axis_512.sv] \
  [file join $repo_dir rtl ddr_trace_reader.sv] \
  [file join $repo_dir rtl ddr_stream_reader.sv] \
  [file join $repo_dir rtl trace_replay_core.sv] \
  [file join $repo_dir rtl traffic_replay_bd_core.v] \
  [file join $repo_dir rtl rx_capture_bd_core.sv] \
  [file join $repo_dir rtl rx_capture_bd_core.v] \
  [file join $repo_dir rtl rx_capture_lbus_bd_core.v] \
  [file join $repo_dir rtl axis_async_fifo.v] \
]
add_files -fileset sources_1 $rtl_files
set sv_files [lsearch -all -inline $rtl_files *.sv]
if {[llength $sv_files] > 0} {
  set_property file_type SystemVerilog [get_files $sv_files]
}
update_compile_order -fileset sources_1

set old_dir_for_bd_init [pwd]
if {[info exists ::env(XILINX_VIVADO)] && $::env(XILINX_VIVADO) ne ""} {
  set xilinx_bd_init_dir [file normalize [file join $::env(XILINX_VIVADO) scripts ipintegrator]]
  set bd_init_dir [file join $build_dir ipintegrator_init_wrapper]
  file mkdir $bd_init_dir
  set bd_init_file [file join $bd_init_dir init.tcl]
  set fh [open $bd_init_file w]
  puts $fh "set xilinx_bd_init_dir {[string map {\\ /} $xilinx_bd_init_dir]}"
  foreach rel_file [list \
    utils.tcl mig_utils.tcl board_utils.tcl utils_dbg.tcl clkrst.tcl \
    replace_bd_cell.tcl addr.tcl testbench.tcl sc_cosim_util.tcl \
    utils_timing.tcl sdsoc_pfm.tcl gt_utils.tcl \
  ] {
    puts $fh "source -notrace \[file join \$xilinx_bd_init_dir {$rel_file}\]"
  }
  close $fh
  if {[file isdirectory $bd_init_dir]} {
    cd $bd_init_dir
  }
}
set create_bd_rc [catch {create_bd_design $bd_name} create_bd_msg]
cd $old_dir_for_bd_init
if {$create_bd_rc != 0} {
  puts "ERROR: create_bd_design failed: $create_bd_msg"
  exit 1
}
current_bd_design $bd_name

set const_idx 0
set enable_debug_ila 0
if {[info exists ::env(TRAFFIC_REPLAY_ENABLE_ILA)] && $::env(TRAFFIC_REPLAY_ENABLE_ILA) ne ""} {
  set enable_debug_ila $::env(TRAFFIC_REPLAY_ENABLE_ILA)
}

proc bd_pin_list {names} {
  set pins [list]
  foreach name $names {
    lappend pins [get_bd_pins $name]
  }
  return $pins
}

proc ddr_bank_offset_hex {bank} {
  set offset [expr {$bank * 0x400000000}]
  return [format "0x%016x" $offset]
}

proc add_const {name width value} {
  if {[llength [get_bd_cells -quiet $name]] == 0} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant $name
    set_property -dict [list CONFIG.CONST_WIDTH $width CONFIG.CONST_VAL $value] [get_bd_cells $name]
  }
  return [get_bd_pins $name/dout]
}

proc connect_const {pin width value} {
  if {[llength [get_bd_pins -quiet $pin]] == 0} {
    return
  }
  global const_idx
  set cname [format "c%03d" $const_idx]
  incr const_idx
  connect_bd_net [add_const $cname $width $value] [get_bd_pins $pin]
}

proc create_const_port {port_name width value} {
  if {[llength [get_bd_ports -quiet $port_name]] == 0} {
    if {$width == 1} {
      create_bd_port -dir O $port_name
    } else {
      create_bd_port -dir O -from [expr {$width - 1}] -to 0 $port_name
    }
  }
  set cname ${port_name}_const
  connect_bd_net [add_const $cname $width $value] [get_bd_ports $port_name]
}

proc try_board_intf {ip_intf board_intf} {
  set rc [catch {apply_board_connection -board_interface $board_intf -ip_intf $ip_intf -diagram [current_bd_design]} msg]
  if {$rc != 0} {
    puts "WARN: apply_board_connection failed for $ip_intf -> $board_intf: $msg"
    if {[llength [get_bd_intf_pins -quiet $ip_intf]] > 0} {
      make_bd_intf_pins_external [get_bd_intf_pins $ip_intf]
    }
  }
}

proc try_board_pin {pin board_intf} {
  if {[llength [get_bd_pins -quiet $pin]] == 0} {
    return
  }
  set rc [catch {
    apply_bd_automation -rule xilinx.com:bd_rule:board \
      -config [list Board_Interface $board_intf Manual_Source Auto] \
      [get_bd_pins $pin]
  } msg]
  if {$rc != 0} {
    puts "WARN: apply_bd_automation failed for $pin -> $board_intf: $msg"
    try_make_pin_external $pin $board_intf
  }
}

proc try_make_pin_external {pin name} {
  if {[llength [get_bd_pins -quiet $pin]] == 0} {
    return
  }
  set bd_pin [get_bd_pins $pin]
  set port_name $name
  if {$port_name eq ""} {
    set port_name [string map {/ _ . _} $pin]
  }
  set pin_dir [get_property DIR $bd_pin]
  set port_dir I
  if {$pin_dir eq "O"} {
    set port_dir O
  } elseif {$pin_dir eq "IO"} {
    set port_dir IO
  }
  set pin_type [get_property TYPE $bd_pin]
  set args [list -dir $port_dir]
  if {$pin_type eq "clk"} {
    lappend args -type clk -freq_hz 100000000
  } elseif {$pin_type eq "rst"} {
    lappend args -type rst
  }
  set port [create_bd_port {*}$args $port_name]
  connect_bd_net $port $bd_pin
}

proc configure_cmac_cell {cell eth_board refclk_board core_select gt_group} {
  global enable_rs_fec
  set_property -dict [list \
    CONFIG.ETHERNET_BOARD_INTERFACE $eth_board \
    CONFIG.DIFFCLK_BOARD_INTERFACE $refclk_board \
    CONFIG.GT_TYPE {GTY} \
    CONFIG.CMAC_CAUI4_MODE {1} \
    CONFIG.NUM_LANES {4x25} \
    CONFIG.CMAC_CORE_SELECT $core_select \
    CONFIG.GT_GROUP_SELECT $gt_group \
    CONFIG.GT_REF_CLK_FREQ {161.1328125} \
    CONFIG.USER_INTERFACE {LBUS} \
    CONFIG.INCLUDE_SHARED_LOGIC {2} \
    CONFIG.INCLUDE_RS_FEC $enable_rs_fec \
    CONFIG.TX_FLOW_CONTROL {0} \
    CONFIG.RX_FLOW_CONTROL {0} \
    CONFIG.TX_FRAME_CRC_CHECKING {Enable FCS Insertion} \
    CONFIG.RX_FRAME_CRC_CHECKING {Enable FCS Stripping} \
    CONFIG.TX_IPG_VALUE {12} \
  ] [get_bd_cells $cell]
}

proc connect_cmac_const_pins {cell} {
  global enable_rs_fec
  connect_const $cell/gtwiz_reset_tx_datapath 1 0
  connect_const $cell/gtwiz_reset_rx_datapath 1 0
  connect_const $cell/gt_loopback_in 12 0
  connect_const $cell/ctl_tx_enable 1 1
  connect_const $cell/ctl_rx_enable 1 1
  connect_const $cell/ctl_tx_send_idle 1 0
  connect_const $cell/ctl_tx_send_lfi 1 0
  connect_const $cell/ctl_tx_send_rfi 1 0
  connect_const $cell/ctl_tx_test_pattern 1 0
  connect_const $cell/ctl_rx_force_resync 1 0
  connect_const $cell/ctl_rx_test_pattern 1 0
  connect_const $cell/ctl_tx_rsfec_enable 1 $enable_rs_fec
  connect_const $cell/ctl_rx_rsfec_enable 1 $enable_rs_fec
  connect_const $cell/ctl_rx_rsfec_enable_correction 1 $enable_rs_fec
  connect_const $cell/ctl_rx_rsfec_enable_indication 1 $enable_rs_fec
  connect_const $cell/ctl_rsfec_ieee_error_indication_mode 1 1
  connect_const $cell/tx_preamblein 56 0
  connect_const $cell/drp_addr 10 0
  connect_const $cell/drp_di 16 0
  connect_const $cell/drp_en 1 0
  connect_const $cell/drp_we 1 0

  foreach pin [list \
    ctl_tx_pause_enable ctl_tx_pause_req ctl_tx_resend_pause \
    ctl_rx_pause_ack ctl_rx_pause_enable \
  ] {
    connect_const $cell/$pin 9 0
  }

  foreach pin [list \
    ctl_tx_pause_quanta0 ctl_tx_pause_quanta1 ctl_tx_pause_quanta2 \
    ctl_tx_pause_quanta3 ctl_tx_pause_quanta4 ctl_tx_pause_quanta5 \
    ctl_tx_pause_quanta6 ctl_tx_pause_quanta7 ctl_tx_pause_quanta8 \
    ctl_tx_pause_refresh_timer0 ctl_tx_pause_refresh_timer1 ctl_tx_pause_refresh_timer2 \
    ctl_tx_pause_refresh_timer3 ctl_tx_pause_refresh_timer4 ctl_tx_pause_refresh_timer5 \
    ctl_tx_pause_refresh_timer6 ctl_tx_pause_refresh_timer7 ctl_tx_pause_refresh_timer8 \
  ] {
    connect_const $cell/$pin 16 0
  }
}

proc connect_tx_lbus_bridge {bridge cmac} {
  foreach seg {0 1 2 3} {
    foreach sig {tx_datain tx_enain tx_sopin tx_eopin tx_mtyin tx_errin} {
      connect_bd_net [get_bd_pins ${bridge}/${sig}${seg}] [get_bd_pins ${cmac}/${sig}${seg}]
    }
  }
  connect_bd_net [get_bd_pins ${cmac}/tx_rdyout] [get_bd_pins ${bridge}/tx_rdyout]
  connect_bd_net [get_bd_pins ${cmac}/tx_ovfout] [get_bd_pins ${bridge}/tx_ovfout]
  connect_bd_net [get_bd_pins ${cmac}/tx_unfout] [get_bd_pins ${bridge}/tx_unfout]
}

proc connect_rx_lbus_capture {cmac cap} {
  foreach seg {0 1 2 3} {
    foreach sig {rx_dataout rx_enaout rx_sopout rx_eopout rx_mtyout rx_errout} {
      connect_bd_net [get_bd_pins ${cmac}/${sig}${seg}] [get_bd_pins ${cap}/${sig}${seg}]
    }
  }
}

create_bd_cell -type module -reference traffic_replay_bd_core replay_core_0
create_bd_cell -type module -reference rx_capture_lbus_bd_core rx_cap_0
if {$enable_port1} {
  create_bd_cell -type module -reference traffic_replay_bd_core replay_core_1
  create_bd_cell -type module -reference rx_capture_lbus_bd_core rx_cap_1
}

create_bd_cell -type ip -vlnv xilinx.com:ip:xdma xdma_0
set_property -dict [list \
  CONFIG.PCIE_BOARD_INTERFACE {pci_express_x16} \
  CONFIG.SYS_RST_N_BOARD_INTERFACE {pcie_perstn} \
  CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
  CONFIG.pl_link_cap_max_link_width {X16} \
  CONFIG.mode_selection {Advanced} \
  CONFIG.en_gt_selection {true} \
  CONFIG.select_quad {GTY_Quad_227} \
  CONFIG.vendor_id {10EE} \
  CONFIG.pf0_device_id {903F} \
  CONFIG.pf0_class_code {058000} \
  CONFIG.pf0_class_code_base {05} \
  CONFIG.pf0_class_code_sub {80} \
  CONFIG.pf0_class_code_interface {00} \
  CONFIG.pf0_subsystem_vendor_id {10EE} \
  CONFIG.pf0_subsystem_id {0007} \
  CONFIG.tl_pf_enable_reg {1} \
  CONFIG.axi_data_width {512_bit} \
  CONFIG.axi_addr_width {64} \
  CONFIG.axi_id_width {4} \
  CONFIG.axisten_freq {250} \
  CONFIG.axilite_master_en {true} \
  CONFIG.axilite_master_size {1} \
  CONFIG.axilite_master_scale {Megabytes} \
  CONFIG.xdma_rnum_chnl {1} \
  CONFIG.xdma_wnum_chnl {1} \
] [get_bd_cells xdma_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf pcie_refclk_buf
set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] [get_bd_cells pcie_refclk_buf]

foreach bank $ddr_bank_ids {
  set ddr_cell ddr4_$bank
  create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4 $ddr_cell
  set_property -dict [list \
    CONFIG.C0_DDR4_BOARD_INTERFACE ddr4_sdram_c${bank} \
    CONFIG.C0_CLOCK_BOARD_INTERFACE default_300mhz_clk${bank} \
    CONFIG.ADDN_UI_CLKOUT1_FREQ_HZ {100} \
    CONFIG.C0.BANK_GROUP_WIDTH {2} \
    CONFIG.C0.CKE_WIDTH {1} \
    CONFIG.C0.CS_WIDTH {1} \
    CONFIG.C0.ODT_WIDTH {1} \
    CONFIG.C0.ControllerType {DDR4_SDRAM} \
    CONFIG.C0.DDR4_AxiAddressWidth {34} \
    CONFIG.C0.DDR4_AxiDataWidth {512} \
    CONFIG.C0.DDR4_AxiIDWidth {4} \
    CONFIG.C0.DDR4_CLKOUT0_DIVIDE {5} \
    CONFIG.C0.DDR4_CasLatency {17} \
    CONFIG.C0.DDR4_CasWriteLatency {12} \
    CONFIG.C0.DDR4_DataMask {NONE} \
    CONFIG.C0.DDR4_DataWidth {72} \
    CONFIG.C0.DDR4_Ecc {true} \
    CONFIG.C0.DDR4_InputClockPeriod {3332} \
    CONFIG.C0.DDR4_MemoryPart {MTA18ASF2G72PZ-2G3} \
    CONFIG.C0.DDR4_MemoryType {RDIMMs} \
    CONFIG.C0.DDR4_TimePeriod {833} \
    CONFIG.C0.DDR4_AUTO_AP_COL_A3 {true} \
    CONFIG.C0.DDR4_Mem_Add_Map {ROW_COLUMN_BANK_INTLV} \
  ] [get_bd_cells $ddr_cell]
}

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect host_smc
set host_smc_mi_count [expr {$traffic_replay_ddr_banks == 1 ? 1 : $traffic_replay_ddr_banks}]
set host_smc_si_count [expr {$traffic_replay_port0_multi_ddr ? 2 : 1}]
set_property -dict [list CONFIG.NUM_SI $host_smc_si_count CONFIG.NUM_MI $host_smc_mi_count] [get_bd_cells host_smc]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect ddr_smc
set ddr_smc_si_count [expr {$enable_port1 ? 5 : 3}]
if {$traffic_replay_ddr_banks == 1} {
  set_property -dict [list CONFIG.NUM_SI $ddr_smc_si_count CONFIG.NUM_MI {1}] [get_bd_cells ddr_smc]
} else {
  set ddr_smc_bank0_si_count [expr {$traffic_replay_port0_multi_ddr ? 1 : 2}]
  set_property -dict [list CONFIG.NUM_SI $ddr_smc_bank0_si_count CONFIG.NUM_MI {1}] [get_bd_cells ddr_smc]
  foreach bank $ddr_bank_ids {
    if {$bank == 0} {
      continue
    }
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect ddr_smc_$bank
    set bank_si_count 1
    if {$bank == 1 && $enable_port1} {
      set bank_si_count 2
    } elseif {$bank == 1 && !$enable_port1} {
      set bank_si_count 2
    } elseif {$bank == 2} {
      set bank_si_count 2
    } elseif {$bank == 3 && $enable_port1} {
      set bank_si_count 2
    }
    set_property -dict [list CONFIG.NUM_SI $bank_si_count CONFIG.NUM_MI {1}] [get_bd_cells ddr_smc_$bank]
  }
}

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice ddr_axi_regslice
set_property -dict [list \
  CONFIG.PROTOCOL {AXI4} \
  CONFIG.DATA_WIDTH {512} \
  CONFIG.ADDR_WIDTH {34} \
  CONFIG.ID_WIDTH {4} \
  CONFIG.MAX_BURST_LENGTH {256} \
  CONFIG.NUM_SLR_CROSSINGS {1} \
  CONFIG.PIPELINES_MASTER_AR {1} \
  CONFIG.PIPELINES_MASTER_AW {1} \
  CONFIG.PIPELINES_MASTER_B {1} \
  CONFIG.PIPELINES_MASTER_R {1} \
  CONFIG.PIPELINES_MASTER_W {1} \
  CONFIG.PIPELINES_SLAVE_AR {1} \
  CONFIG.PIPELINES_SLAVE_AW {1} \
  CONFIG.PIPELINES_SLAVE_B {1} \
  CONFIG.PIPELINES_SLAVE_R {1} \
  CONFIG.PIPELINES_SLAVE_W {1} \
] [get_bd_cells ddr_axi_regslice]

foreach bank $ddr_bank_ids {
  if {$bank == 0} {
    continue
  }
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter ddr_bank${bank}_cc
  set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.DATA_WIDTH {512} CONFIG.ADDR_WIDTH {64} CONFIG.ID_WIDTH {4}] [get_bd_cells ddr_bank${bank}_cc]
}

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect ctrl_smc
set ctrl_smc_mi_count [expr {($enable_port1 ? 4 : 2) + $traffic_replay_ddr_banks}]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI $ctrl_smc_mi_count] [get_bd_cells ctrl_smc]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter xdma_to_ddr_cc
set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.DATA_WIDTH {512} CONFIG.ADDR_WIDTH {64} CONFIG.ID_WIDTH {4}] [get_bd_cells xdma_to_ddr_cc]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter axil_ctrl_cc
set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.DATA_WIDTH {32}] [get_bd_cells axil_ctrl_cc]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice ctrl_ddr_regslice
set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.DATA_WIDTH {32}] [get_bd_cells ctrl_ddr_regslice]

foreach bank $ddr_bank_ids {
  if {$bank == 0} {
    continue
  }
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter ctrl_ddr${bank}_cc
  set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.DATA_WIDTH {32}] [get_bd_cells ctrl_ddr${bank}_cc]
}

if {$traffic_replay_ddr_banks != 1} {
  if {$enable_port1} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter ctrl_replay1_cc
    set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.DATA_WIDTH {32}] [get_bd_cells ctrl_replay1_cc]
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter ctrl_rx1_cc
    set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.DATA_WIDTH {32}] [get_bd_cells ctrl_rx1_cc]
  }
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter ctrl_rx0_cc
  set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.DATA_WIDTH {32}] [get_bd_cells ctrl_rx0_cc]
}

create_bd_cell -type module -reference axis_async_fifo tx_axis_fifo_0
create_bd_cell -type module -reference axis_to_lbus_512_bd tx_lbus_0
set_property -dict [list CONFIG.DEPTH_LOG2 {10}] [get_bd_cells tx_axis_fifo_0]
set_property -dict [list CONFIG.FIFO_DEPTH {32}] [get_bd_cells tx_lbus_0]
if {$enable_port1} {
  create_bd_cell -type module -reference axis_async_fifo tx_axis_fifo_1
  create_bd_cell -type module -reference axis_to_lbus_512_bd tx_lbus_1
  set_property -dict [list CONFIG.DEPTH_LOG2 {10}] [get_bd_cells tx_axis_fifo_1]
  set_property -dict [list CONFIG.FIFO_DEPTH {32}] [get_bd_cells tx_lbus_1]
}

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz cmac_init_clk_wiz
set_property -dict [list \
  CONFIG.PRIM_IN_FREQ {300.000} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {125.000} \
  CONFIG.CLKOUT1_USED {true} \
  CONFIG.RESET_TYPE {ACTIVE_HIGH} \
] [get_bd_cells cmac_init_clk_wiz]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ddr
foreach bank $ddr_bank_ids {
  if {$bank == 0} {
    continue
  }
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ddr_$bank
}
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_cmac_init
set cmac_reset_cells [list cmac0_tx_resetn_inv cmac0_rx_resetn_inv]
if {$enable_port1} {
  lappend cmac_reset_cells cmac1_tx_resetn_inv cmac1_rx_resetn_inv
}
foreach rst_cell $cmac_reset_cells {
  create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic $rst_cell
  set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] [get_bd_cells $rst_cell]
}

create_bd_cell -type ip -vlnv xilinx.com:ip:cmac_usplus cmac_0
configure_cmac_cell cmac_0 qsfp0_4x qsfp0_161mhz CMACE4_X0Y6 X1Y48~X1Y51

if {$enable_port1} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:cmac_usplus cmac_1
  configure_cmac_cell cmac_1 qsfp1_4x qsfp1_161mhz CMACE4_X0Y5 X1Y44~X1Y47
}

if {$enable_debug_ila} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice cmac_tx_ila_tdata_low
  set_property -dict [list \
    CONFIG.DIN_WIDTH {512} \
    CONFIG.DIN_FROM {31} \
    CONFIG.DIN_TO {0} \
    CONFIG.DOUT_WIDTH {32} \
  ] [get_bd_cells cmac_tx_ila_tdata_low]

  create_bd_cell -type ip -vlnv xilinx.com:ip:ila cmac_tx_ila
  set_property -dict [list \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_NUM_OF_PROBES {7} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {64} \
    CONFIG.C_PROBE5_WIDTH {32} \
    CONFIG.C_PROBE6_WIDTH {1} \
  ] [get_bd_cells cmac_tx_ila]
}

try_board_intf xdma_0/pcie_mgt pci_express_x16
try_board_intf pcie_refclk_buf/CLK_IN_D pcie_refclk
try_board_pin xdma_0/sys_rst_n pcie_perstn

foreach bank $ddr_bank_ids {
  try_board_intf ddr4_$bank/C0_DDR4 ddr4_sdram_c${bank}
  try_board_intf ddr4_$bank/C0_SYS_CLK default_300mhz_clk${bank}
}

try_board_intf cmac_0/gt_serial_port qsfp0_4x
try_board_intf cmac_0/gt_ref_clk qsfp0_161mhz
if {$enable_port1} {
  try_board_intf cmac_1/gt_serial_port qsfp1_4x
  try_board_intf cmac_1/gt_ref_clk qsfp1_161mhz
}

create_const_port qsfp0_modsell 1 0
create_const_port qsfp0_resetl 1 1
create_const_port qsfp0_lpmode 1 0
create_const_port qsfp0_refclk_reset 1 0
create_const_port qsfp0_fs 2 2
create_const_port qsfp1_modsell 1 0
create_const_port qsfp1_resetl 1 1
create_const_port qsfp1_lpmode 1 0
create_const_port qsfp1_refclk_reset 1 0
create_const_port qsfp1_fs 2 2

connect_bd_net [get_bd_pins pcie_refclk_buf/IBUF_DS_ODIV2] [get_bd_pins xdma_0/sys_clk]
connect_bd_net [get_bd_pins pcie_refclk_buf/IBUF_OUT] [get_bd_pins xdma_0/sys_clk_gt]

set xdma_clk_pins [list xdma_0/axi_aclk xdma_to_ddr_cc/s_axi_aclk axil_ctrl_cc/s_axi_aclk]
set xdma_resetn_pins [list xdma_0/axi_aresetn xdma_to_ddr_cc/s_axi_aresetn axil_ctrl_cc/s_axi_aresetn]
if {$traffic_replay_ddr_banks == 1} {
  lappend xdma_clk_pins host_smc/aclk
  lappend xdma_resetn_pins host_smc/aresetn
}
connect_bd_net {*}[bd_pin_list $xdma_clk_pins]
connect_bd_net {*}[bd_pin_list $xdma_resetn_pins]

set ddr_clk_pins [list \
  ddr4_0/c0_ddr4_ui_clk \
  ddr_smc/aclk \
  ddr_axi_regslice/aclk \
  ctrl_smc/aclk \
  ctrl_ddr_regslice/aclk \
  xdma_to_ddr_cc/m_axi_aclk \
  axil_ctrl_cc/m_axi_aclk \
  replay_core_0/clk \
  tx_axis_fifo_0/s_clk \
  cmac_init_clk_wiz/clk_in1 \
  rst_ddr/slowest_sync_clk \
]
if {$traffic_replay_ddr_banks != 1} {
  lappend ddr_clk_pins host_smc/aclk
  foreach bank $ddr_bank_ids {
    if {$bank == 0} {
      continue
    }
    lappend ddr_clk_pins ddr_bank${bank}_cc/s_axi_aclk ctrl_ddr${bank}_cc/s_axi_aclk
  }
  if {$enable_port1} {
    lappend ddr_clk_pins ctrl_replay1_cc/s_axi_aclk ctrl_rx1_cc/s_axi_aclk
  }
  lappend ddr_clk_pins ctrl_rx0_cc/s_axi_aclk
} else {
  lappend ddr_clk_pins rx_cap_0/clk
  if {$enable_port1} {
    lappend ddr_clk_pins replay_core_1/clk rx_cap_1/clk tx_axis_fifo_1/s_clk
  }
}
connect_bd_net {*}[bd_pin_list $ddr_clk_pins]

connect_bd_net [get_bd_pins ddr4_0/c0_ddr4_ui_clk_sync_rst] [get_bd_pins rst_ddr/ext_reset_in] [get_bd_pins cmac_init_clk_wiz/reset]
set ddr_resetn_pins [list \
  rst_ddr/peripheral_aresetn \
  ddr_smc/aresetn \
  ddr_axi_regslice/aresetn \
  ctrl_smc/aresetn \
  ctrl_ddr_regslice/aresetn \
  xdma_to_ddr_cc/m_axi_aresetn \
  axil_ctrl_cc/m_axi_aresetn \
  replay_core_0/resetn \
  tx_axis_fifo_0/s_resetn \
  ddr4_0/c0_ddr4_aresetn \
]
if {$traffic_replay_ddr_banks != 1} {
  lappend ddr_resetn_pins host_smc/aresetn
  foreach bank $ddr_bank_ids {
    if {$bank == 0} {
      continue
    }
    lappend ddr_resetn_pins ddr_bank${bank}_cc/s_axi_aresetn ctrl_ddr${bank}_cc/s_axi_aresetn
  }
  if {$enable_port1} {
    lappend ddr_resetn_pins ctrl_replay1_cc/s_axi_aresetn ctrl_rx1_cc/s_axi_aresetn
  }
  lappend ddr_resetn_pins ctrl_rx0_cc/s_axi_aresetn
} else {
  lappend ddr_resetn_pins rx_cap_0/resetn
  if {$enable_port1} {
    lappend ddr_resetn_pins replay_core_1/resetn rx_cap_1/resetn tx_axis_fifo_1/s_resetn
  }
}
connect_bd_net {*}[bd_pin_list $ddr_resetn_pins]

foreach bank $ddr_bank_ids {
  if {$bank == 0} {
    continue
  }
  set bank_clk_pins [list \
    ddr4_$bank/c0_ddr4_ui_clk \
    rst_ddr_$bank/slowest_sync_clk \
    ddr_bank${bank}_cc/m_axi_aclk \
    ctrl_ddr${bank}_cc/m_axi_aclk \
    ddr_smc_$bank/aclk \
  ]
  if {$enable_port1 && $bank == 1} {
    lappend bank_clk_pins replay_core_1/clk tx_axis_fifo_1/s_clk ctrl_replay1_cc/m_axi_aclk
  }
  if {$enable_port1 && $bank == 2} {
    lappend bank_clk_pins rx_cap_0/clk ctrl_rx0_cc/m_axi_aclk
  }
  if {$enable_port1 && $bank == 3} {
    lappend bank_clk_pins rx_cap_1/clk ctrl_rx1_cc/m_axi_aclk
  }
  if {!$enable_port1 && $bank == 1} {
    lappend bank_clk_pins rx_cap_0/clk ctrl_rx0_cc/m_axi_aclk
  }
  connect_bd_net [get_bd_pins ddr4_$bank/c0_ddr4_ui_clk] \
    {*}[bd_pin_list [lrange $bank_clk_pins 1 end]]
  connect_bd_net [get_bd_pins ddr4_$bank/c0_ddr4_ui_clk_sync_rst] \
    [get_bd_pins rst_ddr_$bank/ext_reset_in]
  set bank_resetn_pins [list \
    ddr4_$bank/c0_ddr4_aresetn \
    ddr_bank${bank}_cc/m_axi_aresetn \
    ctrl_ddr${bank}_cc/m_axi_aresetn \
    ddr_smc_$bank/aresetn \
  ]
  if {$enable_port1 && $bank == 1} {
    lappend bank_resetn_pins replay_core_1/resetn tx_axis_fifo_1/s_resetn ctrl_replay1_cc/m_axi_aresetn
  }
  if {$enable_port1 && $bank == 2} {
    lappend bank_resetn_pins rx_cap_0/resetn ctrl_rx0_cc/m_axi_aresetn
  }
  if {$enable_port1 && $bank == 3} {
    lappend bank_resetn_pins rx_cap_1/resetn ctrl_rx1_cc/m_axi_aresetn
  }
  if {!$enable_port1 && $bank == 1} {
    lappend bank_resetn_pins rx_cap_0/resetn ctrl_rx0_cc/m_axi_aresetn
  }
  connect_bd_net [get_bd_pins rst_ddr_$bank/peripheral_aresetn] \
    {*}[bd_pin_list $bank_resetn_pins]
}

connect_bd_net [get_bd_pins cmac_0/gt_txusrclk2] [get_bd_pins tx_axis_fifo_0/m_clk] [get_bd_pins tx_lbus_0/clk] [get_bd_pins rx_cap_0/rx_clk] [get_bd_pins cmac_0/rx_clk]
connect_bd_net [get_bd_pins cmac_0/usr_tx_reset] [get_bd_pins cmac0_tx_resetn_inv/Op1]
connect_bd_net [get_bd_pins cmac_0/usr_rx_reset] [get_bd_pins cmac0_rx_resetn_inv/Op1]
connect_bd_net [get_bd_pins cmac0_tx_resetn_inv/Res] [get_bd_pins tx_axis_fifo_0/m_resetn] [get_bd_pins tx_lbus_0/resetn]
connect_bd_net [get_bd_pins cmac0_rx_resetn_inv/Res] [get_bd_pins rx_cap_0/rx_resetn]
if {$enable_port1} {
  connect_bd_net [get_bd_pins cmac_1/gt_txusrclk2] [get_bd_pins tx_axis_fifo_1/m_clk] [get_bd_pins tx_lbus_1/clk] [get_bd_pins rx_cap_1/rx_clk] [get_bd_pins cmac_1/rx_clk]
  connect_bd_net [get_bd_pins cmac_1/usr_tx_reset] [get_bd_pins cmac1_tx_resetn_inv/Op1]
  connect_bd_net [get_bd_pins cmac_1/usr_rx_reset] [get_bd_pins cmac1_rx_resetn_inv/Op1]
  connect_bd_net [get_bd_pins cmac1_tx_resetn_inv/Res] [get_bd_pins tx_axis_fifo_1/m_resetn] [get_bd_pins tx_lbus_1/resetn]
  connect_bd_net [get_bd_pins cmac1_rx_resetn_inv/Res] [get_bd_pins rx_cap_1/rx_resetn]
}
set cmac_init_clk_pins [list \
  cmac_init_clk_wiz/clk_out1 \
  cmac_0/init_clk \
  cmac_0/drp_clk \
  rst_cmac_init/slowest_sync_clk \
]
if {$enable_port1} {
  lappend cmac_init_clk_pins cmac_1/init_clk cmac_1/drp_clk
}
connect_bd_net {*}[bd_pin_list $cmac_init_clk_pins]
connect_bd_net [get_bd_pins cmac_init_clk_wiz/locked] [get_bd_pins rst_cmac_init/dcm_locked]
connect_bd_net [get_bd_pins rst_ddr/peripheral_reset] [get_bd_pins rst_cmac_init/ext_reset_in]
set cmac_reset_pins [list \
  rst_cmac_init/peripheral_reset \
  cmac_0/sys_reset \
  cmac_0/core_tx_reset \
  cmac_0/core_rx_reset \
  cmac_0/core_drp_reset \
]
if {$enable_port1} {
  lappend cmac_reset_pins cmac_1/sys_reset cmac_1/core_tx_reset cmac_1/core_rx_reset cmac_1/core_drp_reset
}
connect_bd_net {*}[bd_pin_list $cmac_reset_pins]
connect_bd_net [get_bd_pins cmac_0/stat_rx_aligned] [get_bd_pins replay_core_0/link_up] [get_bd_pins rx_cap_0/link_up]
if {$enable_port1} {
  connect_bd_net [get_bd_pins cmac_1/stat_rx_aligned] [get_bd_pins replay_core_1/link_up] [get_bd_pins rx_cap_1/link_up]
}

if {$enable_debug_ila} {
  connect_bd_net [get_bd_pins cmac_0/gt_txusrclk2] [get_bd_pins cmac_tx_ila/clk]
  connect_bd_net [get_bd_pins tx_axis_fifo_0/m_axis_tvalid] [get_bd_pins cmac_tx_ila/probe0]
  connect_bd_net [get_bd_pins tx_lbus_0/s_axis_tready] [get_bd_pins cmac_tx_ila/probe1]
  connect_bd_net [get_bd_pins tx_axis_fifo_0/m_axis_tlast] [get_bd_pins cmac_tx_ila/probe2]
  connect_bd_net [get_bd_pins tx_axis_fifo_0/m_axis_tuser] [get_bd_pins cmac_tx_ila/probe3]
  connect_bd_net [get_bd_pins tx_axis_fifo_0/m_axis_tkeep] [get_bd_pins cmac_tx_ila/probe4]
  connect_bd_net [get_bd_pins tx_axis_fifo_0/m_axis_tdata] [get_bd_pins cmac_tx_ila_tdata_low/Din]
  connect_bd_net [get_bd_pins cmac_tx_ila_tdata_low/Dout] [get_bd_pins cmac_tx_ila/probe5]
  connect_bd_net [get_bd_pins cmac_0/stat_rx_aligned] [get_bd_pins cmac_tx_ila/probe6]
}

if {$traffic_replay_ddr_banks == 1} {
  connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI] [get_bd_intf_pins host_smc/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins host_smc/M00_AXI] [get_bd_intf_pins xdma_to_ddr_cc/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins xdma_to_ddr_cc/M_AXI] [get_bd_intf_pins ddr_smc/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins replay_core_0/M_AXI] [get_bd_intf_pins ddr_smc/S01_AXI]
  if {$enable_port1} {
    connect_bd_intf_net [get_bd_intf_pins replay_core_1/M_AXI] [get_bd_intf_pins ddr_smc/S02_AXI]
    connect_bd_intf_net [get_bd_intf_pins rx_cap_0/M_AXI] [get_bd_intf_pins ddr_smc/S03_AXI]
    connect_bd_intf_net [get_bd_intf_pins rx_cap_1/M_AXI] [get_bd_intf_pins ddr_smc/S04_AXI]
  } else {
    connect_bd_intf_net [get_bd_intf_pins rx_cap_0/M_AXI] [get_bd_intf_pins ddr_smc/S02_AXI]
  }
} else {
  connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI] [get_bd_intf_pins xdma_to_ddr_cc/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins xdma_to_ddr_cc/M_AXI] [get_bd_intf_pins host_smc/S00_AXI]
  foreach bank $ddr_bank_ids {
    set mi_pin [format "M%02d_AXI" $bank]
    if {$bank == 0} {
      set bank_smc ddr_smc
      connect_bd_intf_net [get_bd_intf_pins host_smc/$mi_pin] [get_bd_intf_pins $bank_smc/S00_AXI]
    } else {
      set bank_smc ddr_smc_$bank
      connect_bd_intf_net [get_bd_intf_pins host_smc/$mi_pin] [get_bd_intf_pins ddr_bank${bank}_cc/S_AXI]
      connect_bd_intf_net [get_bd_intf_pins ddr_bank${bank}_cc/M_AXI] [get_bd_intf_pins $bank_smc/S00_AXI]
    }
  }
  if {$traffic_replay_port0_multi_ddr} {
    connect_bd_intf_net [get_bd_intf_pins replay_core_0/M_AXI] [get_bd_intf_pins host_smc/S01_AXI]
  } else {
    connect_bd_intf_net [get_bd_intf_pins replay_core_0/M_AXI] [get_bd_intf_pins ddr_smc/S01_AXI]
  }
  if {$enable_port1} {
    connect_bd_intf_net [get_bd_intf_pins replay_core_1/M_AXI] [get_bd_intf_pins ddr_smc_1/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins rx_cap_0/M_AXI] [get_bd_intf_pins ddr_smc_2/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins rx_cap_1/M_AXI] [get_bd_intf_pins ddr_smc_3/S01_AXI]
  } else {
    connect_bd_intf_net [get_bd_intf_pins rx_cap_0/M_AXI] [get_bd_intf_pins ddr_smc_1/S01_AXI]
  }
}
connect_bd_intf_net [get_bd_intf_pins ddr_smc/M00_AXI] [get_bd_intf_pins ddr_axi_regslice/S_AXI]
connect_bd_intf_net [get_bd_intf_pins ddr_axi_regslice/M_AXI] [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI]
foreach bank $ddr_bank_ids {
  if {$bank == 0} {
    continue
  }
  connect_bd_intf_net [get_bd_intf_pins ddr_smc_$bank/M00_AXI] [get_bd_intf_pins ddr4_$bank/C0_DDR4_S_AXI]
}

connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI_LITE] [get_bd_intf_pins axil_ctrl_cc/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axil_ctrl_cc/M_AXI] [get_bd_intf_pins ctrl_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M00_AXI] [get_bd_intf_pins replay_core_0/S_AXIL]
if {$enable_port1} {
  if {$traffic_replay_ddr_banks == 1} {
    connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M01_AXI] [get_bd_intf_pins replay_core_1/S_AXIL]
    connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M02_AXI] [get_bd_intf_pins rx_cap_0/S_AXIL]
    connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M03_AXI] [get_bd_intf_pins rx_cap_1/S_AXIL]
  } else {
    connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M01_AXI] [get_bd_intf_pins ctrl_replay1_cc/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins ctrl_replay1_cc/M_AXI] [get_bd_intf_pins replay_core_1/S_AXIL]
    connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M02_AXI] [get_bd_intf_pins ctrl_rx0_cc/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins ctrl_rx0_cc/M_AXI] [get_bd_intf_pins rx_cap_0/S_AXIL]
    connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M03_AXI] [get_bd_intf_pins ctrl_rx1_cc/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins ctrl_rx1_cc/M_AXI] [get_bd_intf_pins rx_cap_1/S_AXIL]
  }
  connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M04_AXI] [get_bd_intf_pins ctrl_ddr_regslice/S_AXI]
  set ctrl_ddr_mi_start 4
} else {
  if {$traffic_replay_ddr_banks == 1} {
    connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M01_AXI] [get_bd_intf_pins rx_cap_0/S_AXIL]
  } else {
    connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M01_AXI] [get_bd_intf_pins ctrl_rx0_cc/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins ctrl_rx0_cc/M_AXI] [get_bd_intf_pins rx_cap_0/S_AXIL]
  }
  connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M02_AXI] [get_bd_intf_pins ctrl_ddr_regslice/S_AXI]
  set ctrl_ddr_mi_start 2
}
connect_bd_intf_net [get_bd_intf_pins ctrl_ddr_regslice/M_AXI] [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI_CTRL]
foreach bank $ddr_bank_ids {
  if {$bank == 0} {
    continue
  }
  set mi_pin [format "M%02d_AXI" [expr {$ctrl_ddr_mi_start + $bank}]]
  connect_bd_intf_net [get_bd_intf_pins ctrl_smc/$mi_pin] [get_bd_intf_pins ctrl_ddr${bank}_cc/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins ctrl_ddr${bank}_cc/M_AXI] [get_bd_intf_pins ddr4_$bank/C0_DDR4_S_AXI_CTRL]
}

connect_bd_intf_net [get_bd_intf_pins replay_core_0/M_TX_AXIS] [get_bd_intf_pins tx_axis_fifo_0/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins tx_axis_fifo_0/M_AXIS] [get_bd_intf_pins tx_lbus_0/S_AXIS]
connect_bd_net [get_bd_pins replay_core_0/tx_path_clear] [get_bd_pins tx_axis_fifo_0/clear] [get_bd_pins tx_lbus_0/clear]
connect_tx_lbus_bridge tx_lbus_0 cmac_0
if {$enable_port1} {
  connect_bd_intf_net [get_bd_intf_pins replay_core_1/M_TX_AXIS] [get_bd_intf_pins tx_axis_fifo_1/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins tx_axis_fifo_1/M_AXIS] [get_bd_intf_pins tx_lbus_1/S_AXIS]
  connect_bd_net [get_bd_pins replay_core_1/tx_path_clear] [get_bd_pins tx_axis_fifo_1/clear] [get_bd_pins tx_lbus_1/clear]
  connect_tx_lbus_bridge tx_lbus_1 cmac_1
}

connect_rx_lbus_capture cmac_0 rx_cap_0
if {$enable_port1} {
  connect_rx_lbus_capture cmac_1 rx_cap_1
}

foreach bank $ddr_bank_ids {
  connect_const ddr4_$bank/sys_rst 1 0
}
connect_const xdma_0/usr_irq_req 1 0
connect_cmac_const_pins cmac_0
if {$enable_port1} {
  connect_cmac_const_pins cmac_1
}

assign_bd_address

set ctrl_segs [get_bd_addr_segs -quiet xdma_0/M_AXI_LITE/*]
foreach seg $ctrl_segs {
  if {[string match *replay_core_0* $seg]} {
    set_property range 64K $seg
    set_property offset 0x00000000 $seg
  } elseif {[string match *replay_core_1* $seg]} {
    set_property range 64K $seg
    set_property offset 0x00010000 $seg
  } elseif {[string match *rx_cap_0* $seg]} {
    set_property range 64K $seg
    set_property offset 0x00020000 $seg
  } elseif {[string match *rx_cap_1* $seg]} {
    set_property range 64K $seg
    set_property offset 0x00030000 $seg
  } else {
    foreach bank $ddr_bank_ids {
      if {[string match *ddr4_$bank* $seg]} {
        set_property range 64K $seg
        set_property offset [format "0x%08x" [expr {0x00040000 + ($bank * 0x00010000)}]] $seg
      }
    }
  }
}

set ddr_host_segs [get_bd_addr_segs -quiet xdma_0/M_AXI/*]
foreach seg $ddr_host_segs {
  foreach bank $ddr_bank_ids {
    if {[string match *ddr4_$bank* $seg]} {
      set_property offset [ddr_bank_offset_hex $bank] $seg
      set_property range 16G $seg
    }
  }
}

set ddr_core_masters [list replay_core_0 rx_cap_0]
if {$enable_port1} {
  lappend ddr_core_masters replay_core_1 rx_cap_1
}
foreach master $ddr_core_masters {
  set ddr_core_segs [get_bd_addr_segs -quiet $master/M_AXI/*]
  foreach seg $ddr_core_segs {
    foreach bank $ddr_bank_ids {
      if {[string match *ddr4_$bank* $seg]} {
        set_property offset [ddr_bank_offset_hex $bank] $seg
        set_property range 16G $seg
      }
    }
  }
}

validate_bd_design
save_bd_design

set bd_file [get_files [file join $build_dir $project_name.srcs sources_1 bd $bd_name $bd_name.bd]]
set_property synth_checkpoint_mode None $bd_file
set_property generate_synth_checkpoint false $bd_file

make_wrapper -files [get_files [file join $build_dir $project_name.srcs sources_1 bd $bd_name $bd_name.bd]] -top
add_files -norecurse [file join $build_dir $project_name.gen sources_1 bd $bd_name hdl ${bd_name}_wrapper.v]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "Hardware BD project created at $build_dir"
