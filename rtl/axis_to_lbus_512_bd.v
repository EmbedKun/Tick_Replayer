`timescale 1ns/1ps

module axis_to_lbus_512_bd #(
  parameter DATA_W = 512,
  parameter KEEP_W = DATA_W / 8,
  parameter SEG_COUNT = 4,
  parameter SEG_DATA_W = DATA_W / SEG_COUNT,
  parameter SEG_KEEP_W = KEEP_W / SEG_COUNT
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS, ASSOCIATED_RESET resetn" *)
  input  wire                  clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                  resetn,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
  input  wire [DATA_W-1:0]     s_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *)
  input  wire [KEEP_W-1:0]     s_axis_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
  input  wire                  s_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
  output wire                  s_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
  input  wire                  s_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TUSER" *)
  (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 64, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1" *)
  input  wire                  s_axis_tuser,

  output wire [SEG_DATA_W-1:0] tx_datain0,
  output wire [SEG_DATA_W-1:0] tx_datain1,
  output wire [SEG_DATA_W-1:0] tx_datain2,
  output wire [SEG_DATA_W-1:0] tx_datain3,
  output wire                  tx_enain0,
  output wire                  tx_enain1,
  output wire                  tx_enain2,
  output wire                  tx_enain3,
  output wire                  tx_sopin0,
  output wire                  tx_sopin1,
  output wire                  tx_sopin2,
  output wire                  tx_sopin3,
  output wire                  tx_eopin0,
  output wire                  tx_eopin1,
  output wire                  tx_eopin2,
  output wire                  tx_eopin3,
  output wire [3:0]            tx_mtyin0,
  output wire [3:0]            tx_mtyin1,
  output wire [3:0]            tx_mtyin2,
  output wire [3:0]            tx_mtyin3,
  output wire                  tx_errin0,
  output wire                  tx_errin1,
  output wire                  tx_errin2,
  output wire                  tx_errin3,
  input  wire                  tx_rdyout,
  input  wire                  tx_ovfout,
  input  wire                  tx_unfout
);
  axis_to_lbus_512 #(
    .DATA_W(DATA_W),
    .KEEP_W(KEEP_W),
    .SEG_COUNT(SEG_COUNT),
    .SEG_DATA_W(SEG_DATA_W),
    .SEG_KEEP_W(SEG_KEEP_W)
  ) core_i (
    .clk(clk),
    .resetn(resetn),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .tx_datain0(tx_datain0),
    .tx_datain1(tx_datain1),
    .tx_datain2(tx_datain2),
    .tx_datain3(tx_datain3),
    .tx_enain0(tx_enain0),
    .tx_enain1(tx_enain1),
    .tx_enain2(tx_enain2),
    .tx_enain3(tx_enain3),
    .tx_sopin0(tx_sopin0),
    .tx_sopin1(tx_sopin1),
    .tx_sopin2(tx_sopin2),
    .tx_sopin3(tx_sopin3),
    .tx_eopin0(tx_eopin0),
    .tx_eopin1(tx_eopin1),
    .tx_eopin2(tx_eopin2),
    .tx_eopin3(tx_eopin3),
    .tx_mtyin0(tx_mtyin0),
    .tx_mtyin1(tx_mtyin1),
    .tx_mtyin2(tx_mtyin2),
    .tx_mtyin3(tx_mtyin3),
    .tx_errin0(tx_errin0),
    .tx_errin1(tx_errin1),
    .tx_errin2(tx_errin2),
    .tx_errin3(tx_errin3),
    .tx_rdyout(tx_rdyout),
    .tx_ovfout(tx_ovfout),
    .tx_unfout(tx_unfout)
  );
endmodule
