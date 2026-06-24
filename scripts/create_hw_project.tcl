set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]

set_param general.maxThreads 1

proc source_vivado_init {subdir} {
  if {![info exists ::env(XILINX_VIVADO)] || $::env(XILINX_VIVADO) eq ""} {
    return
  }
  set init_dir [file normalize [file join $::env(XILINX_VIVADO) scripts $subdir]]
  set init_file [file join $init_dir init.tcl]
  if {![file exists $init_file]} {
    return
  }
  set old_dir [pwd]
  cd $init_dir
  source -notrace $init_file
  cd $old_dir
}

source_vivado_init ipintegrator
source_vivado_init xguifrmwork

if {[info exists ::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)] && $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT) ne ""} {
  set hw_build_root [file normalize $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)]
} elseif {[file exists D:/]} {
  set hw_build_root [file normalize D:/tr_build]
} else {
  set hw_build_root [file join $repo_dir build]
}
set build_dir [file join $hw_build_root vivado_hw]
file mkdir $build_dir

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

set rtl_files [list \
  [file join $repo_dir rtl traffic_replay_pkg.sv] \
  [file join $repo_dir rtl axi_lite_regs.sv] \
  [file join $repo_dir rtl replay_scheduler.sv] \
  [file join $repo_dir rtl replay_tx_engine.sv] \
  [file join $repo_dir rtl host_stream_parser.sv] \
  [file join $repo_dir rtl ddr_trace_reader.sv] \
  [file join $repo_dir rtl trace_replay_core.sv] \
  [file join $repo_dir rtl traffic_replay_bd_core.v] \
  [file join $repo_dir rtl axis_async_fifo.v] \
]
add_files -fileset sources_1 $rtl_files
set sv_files [lsearch -all -inline $rtl_files *.sv]
if {[llength $sv_files] > 0} {
  set_property file_type SystemVerilog [get_files $sv_files]
}
update_compile_order -fileset sources_1

create_bd_design $bd_name
current_bd_design $bd_name

set const_idx 0

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

create_bd_cell -type module -reference traffic_replay_bd_core replay_core

create_bd_cell -type ip -vlnv xilinx.com:ip:xdma xdma_0
set_property -dict [list \
  CONFIG.PCIE_BOARD_INTERFACE {pci_express_x16} \
  CONFIG.SYS_RST_N_BOARD_INTERFACE {pcie_perstn} \
  CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
  CONFIG.pl_link_cap_max_link_width {X16} \
  CONFIG.mode_selection {Advanced} \
  CONFIG.en_gt_selection {true} \
  CONFIG.select_quad {GTY_Quad_227} \
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

create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4 ddr4_0
set_property -dict [list \
  CONFIG.C0_DDR4_BOARD_INTERFACE {ddr4_sdram_c0} \
  CONFIG.C0_CLOCK_BOARD_INTERFACE {default_300mhz_clk0} \
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
] [get_bd_cells ddr4_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect host_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells host_smc]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect ddr_smc
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells ddr_smc]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect ctrl_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] [get_bd_cells ctrl_smc]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter xdma_to_ddr_cc
set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.DATA_WIDTH {512} CONFIG.ADDR_WIDTH {64} CONFIG.ID_WIDTH {4}] [get_bd_cells xdma_to_ddr_cc]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter axil_ctrl_cc
set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.DATA_WIDTH {32}] [get_bd_cells axil_ctrl_cc]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice ctrl_ddr_regslice
set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.DATA_WIDTH {32}] [get_bd_cells ctrl_ddr_regslice]

create_bd_cell -type module -reference axis_async_fifo tx_axis_fifo

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz cmac_init_clk_wiz
set_property -dict [list \
  CONFIG.PRIM_IN_FREQ {300.000} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {125.000} \
  CONFIG.CLKOUT1_USED {true} \
  CONFIG.RESET_TYPE {ACTIVE_HIGH} \
] [get_bd_cells cmac_init_clk_wiz]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ddr
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_cmac_init
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic cmac_tx_resetn_inv
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] [get_bd_cells cmac_tx_resetn_inv]

create_bd_cell -type ip -vlnv xilinx.com:ip:cmac_usplus cmac_0
set_property -dict [list \
  CONFIG.ETHERNET_BOARD_INTERFACE {qsfp0_4x} \
  CONFIG.DIFFCLK_BOARD_INTERFACE {qsfp0_161mhz} \
  CONFIG.GT_TYPE {GTY} \
  CONFIG.CMAC_CAUI4_MODE {1} \
  CONFIG.NUM_LANES {4x25} \
  CONFIG.CMAC_CORE_SELECT {CMACE4_X0Y6} \
  CONFIG.GT_GROUP_SELECT {X1Y48~X1Y51} \
  CONFIG.GT_REF_CLK_FREQ {161.1328125} \
  CONFIG.USER_INTERFACE {AXIS} \
  CONFIG.INCLUDE_SHARED_LOGIC {2} \
  CONFIG.INCLUDE_RS_FEC {0} \
  CONFIG.TX_FLOW_CONTROL {0} \
  CONFIG.RX_FLOW_CONTROL {0} \
  CONFIG.TX_FRAME_CRC_CHECKING {Enable FCS Insertion} \
  CONFIG.RX_FRAME_CRC_CHECKING {Enable FCS Stripping} \
  CONFIG.TX_IPG_VALUE {12} \
] [get_bd_cells cmac_0]

try_board_intf xdma_0/pcie_mgt pci_express_x16
try_board_intf pcie_refclk_buf/CLK_IN_D pcie_refclk
try_board_pin xdma_0/sys_rst_n pcie_perstn

try_board_intf ddr4_0/C0_DDR4 ddr4_sdram_c0
try_board_intf ddr4_0/C0_SYS_CLK default_300mhz_clk0

try_board_intf cmac_0/gt_serial_port qsfp0_4x
try_board_intf cmac_0/gt_ref_clk qsfp0_161mhz

create_const_port qsfp0_modsell 1 0
create_const_port qsfp0_resetl 1 1
create_const_port qsfp0_lpmode 1 0
create_const_port qsfp0_refclk_reset 1 0
create_const_port qsfp0_fs 2 2

connect_bd_net [get_bd_pins pcie_refclk_buf/IBUF_DS_ODIV2] [get_bd_pins xdma_0/sys_clk]
connect_bd_net [get_bd_pins pcie_refclk_buf/IBUF_OUT] [get_bd_pins xdma_0/sys_clk_gt]

connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_pins host_smc/aclk] [get_bd_pins xdma_to_ddr_cc/s_axi_aclk] [get_bd_pins axil_ctrl_cc/s_axi_aclk]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_pins host_smc/aresetn] [get_bd_pins xdma_to_ddr_cc/s_axi_aresetn] [get_bd_pins axil_ctrl_cc/s_axi_aresetn]

connect_bd_net [get_bd_pins ddr4_0/c0_ddr4_ui_clk] \
  [get_bd_pins ddr_smc/aclk] \
  [get_bd_pins ctrl_smc/aclk] \
  [get_bd_pins ctrl_ddr_regslice/aclk] \
  [get_bd_pins xdma_to_ddr_cc/m_axi_aclk] \
  [get_bd_pins axil_ctrl_cc/m_axi_aclk] \
  [get_bd_pins replay_core/clk] \
  [get_bd_pins tx_axis_fifo/s_clk] \
  [get_bd_pins cmac_init_clk_wiz/clk_in1] \
  [get_bd_pins rst_ddr/slowest_sync_clk]

connect_bd_net [get_bd_pins ddr4_0/c0_ddr4_ui_clk_sync_rst] [get_bd_pins rst_ddr/ext_reset_in] [get_bd_pins cmac_init_clk_wiz/reset]
connect_bd_net [get_bd_pins rst_ddr/peripheral_aresetn] \
  [get_bd_pins ddr_smc/aresetn] \
  [get_bd_pins ctrl_smc/aresetn] \
  [get_bd_pins ctrl_ddr_regslice/aresetn] \
  [get_bd_pins xdma_to_ddr_cc/m_axi_aresetn] \
  [get_bd_pins axil_ctrl_cc/m_axi_aresetn] \
  [get_bd_pins replay_core/resetn] \
  [get_bd_pins tx_axis_fifo/s_resetn] \
  [get_bd_pins ddr4_0/c0_ddr4_aresetn]

connect_bd_net [get_bd_pins cmac_0/gt_txusrclk2] [get_bd_pins tx_axis_fifo/m_clk]
connect_bd_net [get_bd_pins cmac_0/usr_tx_reset] [get_bd_pins cmac_tx_resetn_inv/Op1]
connect_bd_net [get_bd_pins cmac_tx_resetn_inv/Res] [get_bd_pins tx_axis_fifo/m_resetn]
connect_bd_net [get_bd_pins cmac_init_clk_wiz/clk_out1] [get_bd_pins cmac_0/init_clk] [get_bd_pins cmac_0/drp_clk] [get_bd_pins rst_cmac_init/slowest_sync_clk]
connect_bd_net [get_bd_pins cmac_init_clk_wiz/locked] [get_bd_pins rst_cmac_init/dcm_locked]
connect_bd_net [get_bd_pins rst_ddr/peripheral_reset] [get_bd_pins rst_cmac_init/ext_reset_in]
connect_bd_net [get_bd_pins cmac_0/gt_txusrclk2] [get_bd_pins cmac_0/rx_clk]
connect_bd_net [get_bd_pins rst_cmac_init/peripheral_reset] [get_bd_pins cmac_0/sys_reset] [get_bd_pins cmac_0/core_tx_reset] [get_bd_pins cmac_0/core_rx_reset] [get_bd_pins cmac_0/core_drp_reset]
connect_bd_net [get_bd_pins cmac_0/stat_rx_aligned] [get_bd_pins replay_core/link_up]

connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI] [get_bd_intf_pins host_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins host_smc/M00_AXI] [get_bd_intf_pins xdma_to_ddr_cc/S_AXI]
connect_bd_intf_net [get_bd_intf_pins xdma_to_ddr_cc/M_AXI] [get_bd_intf_pins ddr_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins replay_core/M_AXI] [get_bd_intf_pins ddr_smc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins ddr_smc/M00_AXI] [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI]

connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI_LITE] [get_bd_intf_pins axil_ctrl_cc/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axil_ctrl_cc/M_AXI] [get_bd_intf_pins ctrl_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M00_AXI] [get_bd_intf_pins replay_core/S_AXIL]
connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M01_AXI] [get_bd_intf_pins ctrl_ddr_regslice/S_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_ddr_regslice/M_AXI] [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI_CTRL]

connect_bd_intf_net [get_bd_intf_pins replay_core/M_TX_AXIS] [get_bd_intf_pins tx_axis_fifo/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins tx_axis_fifo/M_AXIS] [get_bd_intf_pins cmac_0/axis_tx]

connect_const ddr4_0/sys_rst 1 0
connect_const xdma_0/usr_irq_req 1 0
connect_const cmac_0/gtwiz_reset_tx_datapath 1 0
connect_const cmac_0/gtwiz_reset_rx_datapath 1 0
connect_const cmac_0/gt_loopback_in 12 0
connect_const cmac_0/ctl_tx_enable 1 1
connect_const cmac_0/ctl_rx_enable 1 1
connect_const cmac_0/ctl_tx_send_idle 1 0
connect_const cmac_0/ctl_tx_send_lfi 1 0
connect_const cmac_0/ctl_tx_send_rfi 1 0
connect_const cmac_0/ctl_tx_test_pattern 1 0
connect_const cmac_0/ctl_rx_force_resync 1 0
connect_const cmac_0/ctl_rx_test_pattern 1 0
connect_const cmac_0/tx_preamblein 56 0
connect_const cmac_0/drp_addr 10 0
connect_const cmac_0/drp_di 16 0
connect_const cmac_0/drp_en 1 0
connect_const cmac_0/drp_we 1 0

foreach pin [list \
  ctl_tx_pause_enable ctl_tx_pause_req ctl_tx_resend_pause \
  ctl_rx_pause_ack ctl_rx_pause_enable \
] {
  connect_const cmac_0/$pin 9 0
}

foreach pin [list \
  ctl_tx_pause_quanta0 ctl_tx_pause_quanta1 ctl_tx_pause_quanta2 \
  ctl_tx_pause_quanta3 ctl_tx_pause_quanta4 ctl_tx_pause_quanta5 \
  ctl_tx_pause_quanta6 ctl_tx_pause_quanta7 ctl_tx_pause_quanta8 \
  ctl_tx_pause_refresh_timer0 ctl_tx_pause_refresh_timer1 ctl_tx_pause_refresh_timer2 \
  ctl_tx_pause_refresh_timer3 ctl_tx_pause_refresh_timer4 ctl_tx_pause_refresh_timer5 \
  ctl_tx_pause_refresh_timer6 ctl_tx_pause_refresh_timer7 ctl_tx_pause_refresh_timer8 \
] {
  connect_const cmac_0/$pin 16 0
}

assign_bd_address

set ctrl_segs [get_bd_addr_segs -quiet xdma_0/M_AXI_LITE/*]
foreach seg $ctrl_segs {
  if {[string match *replay_core* $seg]} {
    set_property range 64K $seg
    set_property offset 0x00000000 $seg
  } elseif {[string match *ddr4_0* $seg]} {
    set_property range 64K $seg
    set_property offset 0x00010000 $seg
  }
}

set ddr_host_segs [get_bd_addr_segs -quiet xdma_0/M_AXI/*]
foreach seg $ddr_host_segs {
  if {[string match *ddr4_0* $seg]} {
    set_property offset 0x0000000000000000 $seg
    set_property range 16G $seg
  }
}

set ddr_core_segs [get_bd_addr_segs -quiet replay_core/M_AXI/*]
foreach seg $ddr_core_segs {
  if {[string match *ddr4_0* $seg]} {
    set_property offset 0x0000000000000000 $seg
    set_property range 16G $seg
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
