`timescale 1ns/1ps

module scheduled_axis_async_fifo_bd #(
  parameter DATA_W = 512,
  parameter KEEP_W = DATA_W / 8,
  parameter DEPTH_LOG2 = 10
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS, ASSOCIATED_RESET s_resetn" *)
  input  wire                s_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                s_resetn,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 m_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXIS, ASSOCIATED_RESET m_resetn" *)
  input  wire                m_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 m_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                m_resetn,
  input  wire                clear,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
  input  wire [DATA_W-1:0]   s_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *)
  input  wire [KEEP_W-1:0]   s_axis_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
  input  wire                s_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
  output wire                s_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
  input  wire                s_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TUSER" *)
  (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 64, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1" *)
  input  wire                s_axis_tuser,
  input  wire [63:0]         s_axis_target,
  input  wire                s_axis_target_valid,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
  output wire [DATA_W-1:0]   m_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TKEEP" *)
  output wire [KEEP_W-1:0]   m_axis_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
  output wire                m_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
  input  wire                m_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
  output wire                m_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TUSER" *)
  (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 64, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1" *)
  output wire                m_axis_tuser,
  output wire [63:0]         m_axis_target,
  output wire                m_axis_target_valid
);
  scheduled_axis_async_fifo #(
    .DATA_W(DATA_W),
    .KEEP_W(KEEP_W),
    .DEPTH_LOG2(DEPTH_LOG2)
  ) core_i (
    .s_clk(s_clk),
    .s_resetn(s_resetn),
    .m_clk(m_clk),
    .m_resetn(m_resetn),
    .clear(clear),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .s_axis_target(s_axis_target),
    .s_axis_target_valid(s_axis_target_valid),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser),
    .m_axis_target(m_axis_target),
    .m_axis_target_valid(m_axis_target_valid)
  );
endmodule
