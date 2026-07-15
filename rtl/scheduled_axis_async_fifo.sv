`timescale 1ns/1ps

module scheduled_axis_async_fifo #(
  parameter int DATA_W = 512,
  parameter int KEEP_W = DATA_W / 8,
  parameter int DEPTH_LOG2 = 10
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS, ASSOCIATED_RESET s_resetn" *)
  input  logic                 s_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  logic                 s_resetn,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 m_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXIS, ASSOCIATED_RESET m_resetn" *)
  input  logic                 m_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 m_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  logic                 m_resetn,
  input  logic                 clear,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
  input  logic [DATA_W-1:0]    s_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *)
  input  logic [KEEP_W-1:0]    s_axis_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
  input  logic                 s_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
  output logic                 s_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
  input  logic                 s_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TUSER" *)
  (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 64, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1" *)
  input  logic                 s_axis_tuser,
  input  logic [63:0]          s_axis_target,
  input  logic                 s_axis_target_valid,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
  output logic [DATA_W-1:0]    m_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TKEEP" *)
  output logic [KEEP_W-1:0]    m_axis_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
  output logic                 m_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
  input  logic                 m_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
  output logic                 m_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TUSER" *)
  (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 64, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1" *)
  output logic                 m_axis_tuser,
  output logic [63:0]          m_axis_target,
  output logic                 m_axis_target_valid
);
  logic s_in_packet;
  logic m_in_packet;
  logic data_s_ready;
  logic data_m_valid;
  logic data_m_ready;
  logic target_s_ready;
  logic target_m_valid;
  logic target_m_ready;
  logic [63:0] target_m_data;
  logic target_m_user;
  logic unused_target_last;
  logic [7:0] unused_target_keep;
  logic s_first;
  logic m_first;
  logic s_fire;
  logic m_fire;
  (* ASYNC_REG = "TRUE" *) logic clear_m_sync1;
  (* ASYNC_REG = "TRUE" *) logic clear_m_sync2;

  assign s_first = !s_in_packet;
  assign m_first = !m_in_packet;
  assign s_axis_tready = data_s_ready && (!s_first || target_s_ready);
  assign s_fire = s_axis_tvalid && s_axis_tready;

  assign m_axis_tvalid = data_m_valid && (!m_first || target_m_valid);
  assign data_m_ready = m_axis_tready && (!m_first || target_m_valid);
  assign target_m_ready = m_first && data_m_valid && m_axis_tready;
  assign m_axis_target = target_m_data;
  assign m_axis_target_valid = m_first && target_m_valid && target_m_user;
  assign m_fire = m_axis_tvalid && m_axis_tready;

  axis_async_fifo #(
    .DATA_W(DATA_W),
    .KEEP_W(KEEP_W),
    .USER_W(1),
    .DEPTH_LOG2(DEPTH_LOG2)
  ) data_fifo_i (
    .s_clk(s_clk),
    .s_resetn(s_resetn),
    .m_clk(m_clk),
    .m_resetn(m_resetn),
    .clear(clear),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid && (!s_first || target_s_ready)),
    .s_axis_tready(data_s_ready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(data_m_valid),
    .m_axis_tready(data_m_ready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser)
  );

  axis_async_fifo #(
    .DATA_W(64),
    .KEEP_W(8),
    .USER_W(1),
    .DEPTH_LOG2(DEPTH_LOG2)
  ) target_fifo_i (
    .s_clk(s_clk),
    .s_resetn(s_resetn),
    .m_clk(m_clk),
    .m_resetn(m_resetn),
    .clear(clear),
    .s_axis_tdata(s_axis_target),
    .s_axis_tkeep(8'hff),
    .s_axis_tvalid(s_axis_tvalid && s_first && data_s_ready),
    .s_axis_tready(target_s_ready),
    .s_axis_tlast(1'b1),
    .s_axis_tuser(s_axis_target_valid),
    .m_axis_tdata(target_m_data),
    .m_axis_tkeep(unused_target_keep),
    .m_axis_tvalid(target_m_valid),
    .m_axis_tready(target_m_ready),
    .m_axis_tlast(unused_target_last),
    .m_axis_tuser(target_m_user)
  );

  always_ff @(posedge s_clk or negedge s_resetn) begin
    if (!s_resetn) begin
      s_in_packet <= 1'b0;
    end else if (clear) begin
      s_in_packet <= 1'b0;
    end else if (s_fire) begin
      s_in_packet <= !s_axis_tlast;
    end
  end

  always_ff @(posedge m_clk or negedge m_resetn) begin
    if (!m_resetn) begin
      clear_m_sync1 <= 1'b0;
      clear_m_sync2 <= 1'b0;
      m_in_packet <= 1'b0;
    end else begin
      clear_m_sync1 <= clear;
      clear_m_sync2 <= clear_m_sync1;
      if (clear_m_sync2) begin
        m_in_packet <= 1'b0;
      end else if (m_fire) begin
        m_in_packet <= !m_axis_tlast;
      end
    end
  end
endmodule
