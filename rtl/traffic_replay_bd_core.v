`timescale 1ns/1ps

module traffic_replay_bd_core #(
  parameter AXIL_ADDR_W = 16,
  parameter AXI_ADDR_W_P = 64,
  parameter AXI_ID_W_P = 4,
  parameter AXIS_DATA_W_P = 512,
  parameter AXIS_KEEP_W_P = 64
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIL:M_AXI:M_TX_AXIS, ASSOCIATED_RESET resetn, FREQ_HZ 300000000" *)
  input  wire                       clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                       resetn,
  input  wire                       link_up,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWADDR" *)
  input  wire [AXIL_ADDR_W-1:0]     s_axil_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWVALID" *)
  input  wire                       s_axil_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWREADY" *)
  output wire                       s_axil_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WDATA" *)
  input  wire [31:0]                s_axil_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WSTRB" *)
  input  wire [3:0]                 s_axil_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WVALID" *)
  input  wire                       s_axil_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WREADY" *)
  output wire                       s_axil_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BRESP" *)
  output wire [1:0]                 s_axil_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BVALID" *)
  output wire                       s_axil_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BREADY" *)
  input  wire                       s_axil_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARADDR" *)
  input  wire [AXIL_ADDR_W-1:0]     s_axil_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARVALID" *)
  input  wire                       s_axil_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARREADY" *)
  output wire                       s_axil_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RDATA" *)
  output wire [31:0]                s_axil_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RRESP" *)
  output wire [1:0]                 s_axil_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RVALID" *)
  output wire                       s_axil_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RREADY" *)
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 16, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, SUPPORTS_NARROW_BURST 0" *)
  input  wire                       s_axil_rready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID" *)
  output wire [AXI_ID_W_P-1:0]      m_axi_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *)
  output wire [AXI_ADDR_W_P-1:0]    m_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *)
  output wire [7:0]                 m_axi_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *)
  output wire [2:0]                 m_axi_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *)
  output wire [1:0]                 m_axi_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *)
  output wire                       m_axi_awlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *)
  output wire [3:0]                 m_axi_awcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *)
  output wire [2:0]                 m_axi_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWQOS" *)
  output wire [3:0]                 m_axi_awqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *)
  output wire                       m_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)
  input  wire                       m_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)
  output wire [AXIS_DATA_W_P-1:0]   m_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
  output wire [AXIS_KEEP_W_P-1:0]   m_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *)
  output wire                       m_axi_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)
  output wire                       m_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)
  input  wire                       m_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID" *)
  input  wire [AXI_ID_W_P-1:0]      m_axi_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)
  input  wire [1:0]                 m_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)
  input  wire                       m_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)
  output wire                       m_axi_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID" *)
  output wire [AXI_ID_W_P-1:0]      m_axi_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *)
  output wire [AXI_ADDR_W_P-1:0]    m_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *)
  output wire [7:0]                 m_axi_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *)
  output wire [2:0]                 m_axi_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *)
  output wire [1:0]                 m_axi_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *)
  output wire                       m_axi_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *)
  output wire [3:0]                 m_axi_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *)
  output wire [2:0]                 m_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARQOS" *)
  output wire [3:0]                 m_axi_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)
  output wire                       m_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)
  input  wire                       m_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RID" *)
  input  wire [AXI_ID_W_P-1:0]      m_axi_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)
  input  wire [AXIS_DATA_W_P-1:0]   m_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)
  input  wire [1:0]                 m_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *)
  input  wire                       m_axi_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)
  input  wire                       m_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4, DATA_WIDTH 512, ADDR_WIDTH 64, ID_WIDTH 4, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 0, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 256" *)
  output wire                       m_axi_rready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_TX_AXIS TDATA" *)
  output wire [AXIS_DATA_W_P-1:0]   m_tx_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_TX_AXIS TKEEP" *)
  output wire [AXIS_KEEP_W_P-1:0]   m_tx_axis_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_TX_AXIS TVALID" *)
  output wire                       m_tx_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_TX_AXIS TREADY" *)
  input  wire                       m_tx_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_TX_AXIS TLAST" *)
  output wire                       m_tx_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_TX_AXIS TUSER" *)
  (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 64, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1" *)
  output wire                       m_tx_axis_tuser
);
  wire unused_host_axis_tready;

  assign m_axi_awid    = {AXI_ID_W_P{1'b0}};
  assign m_axi_awaddr  = {AXI_ADDR_W_P{1'b0}};
  assign m_axi_awlen   = 8'd0;
  assign m_axi_awsize  = 3'd6;
  assign m_axi_awburst = 2'b01;
  assign m_axi_awlock  = 1'b0;
  assign m_axi_awcache = 4'b0011;
  assign m_axi_awprot  = 3'b000;
  assign m_axi_awqos   = 4'd0;
  assign m_axi_awvalid = 1'b0;
  assign m_axi_wdata   = {AXIS_DATA_W_P{1'b0}};
  assign m_axi_wstrb   = {AXIS_KEEP_W_P{1'b0}};
  assign m_axi_wlast   = 1'b0;
  assign m_axi_wvalid  = 1'b0;
  assign m_axi_bready  = 1'b1;
  assign m_axi_arlock  = 1'b0;
  assign m_axi_arcache = 4'b0011;
  assign m_axi_arprot  = 3'b000;
  assign m_axi_arqos   = 4'd0;

  trace_replay_core #(
    .AXIL_ADDR_W(AXIL_ADDR_W),
    .AXI_ADDR_W_P(AXI_ADDR_W_P),
    .AXI_ID_W_P(AXI_ID_W_P)
  ) core_i (
    .clk(clk),
    .rstn(resetn),
    .link_up(link_up),
    .s_axil_awaddr(s_axil_awaddr),
    .s_axil_awvalid(s_axil_awvalid),
    .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata),
    .s_axil_wstrb(s_axil_wstrb),
    .s_axil_wvalid(s_axil_wvalid),
    .s_axil_wready(s_axil_wready),
    .s_axil_bresp(s_axil_bresp),
    .s_axil_bvalid(s_axil_bvalid),
    .s_axil_bready(s_axil_bready),
    .s_axil_araddr(s_axil_araddr),
    .s_axil_arvalid(s_axil_arvalid),
    .s_axil_arready(s_axil_arready),
    .s_axil_rdata(s_axil_rdata),
    .s_axil_rresp(s_axil_rresp),
    .s_axil_rvalid(s_axil_rvalid),
    .s_axil_rready(s_axil_rready),
    .s_host_axis_tdata({AXIS_DATA_W_P{1'b0}}),
    .s_host_axis_tkeep({AXIS_KEEP_W_P{1'b0}}),
    .s_host_axis_tvalid(1'b0),
    .s_host_axis_tready(unused_host_axis_tready),
    .s_host_axis_tlast(1'b0),
    .m_axi_arid(m_axi_arid),
    .m_axi_araddr(m_axi_araddr),
    .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize),
    .m_axi_arburst(m_axi_arburst),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp),
    .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid),
    .m_axi_rready(m_axi_rready),
    .m_tx_axis_tdata(m_tx_axis_tdata),
    .m_tx_axis_tkeep(m_tx_axis_tkeep),
    .m_tx_axis_tvalid(m_tx_axis_tvalid),
    .m_tx_axis_tready(m_tx_axis_tready),
    .m_tx_axis_tlast(m_tx_axis_tlast),
    .m_tx_axis_tuser(m_tx_axis_tuser)
  );
endmodule
