`timescale 1ns/1ps

module rx_capture_bd_core #(
  parameter AXIL_ADDR_W = 16,
  parameter AXI_ADDR_W_P = 64,
  parameter AXI_ID_W_P = 4,
  parameter AXIS_DATA_W_P = 512,
  parameter AXIS_KEEP_W_P = 64
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIL:M_AXI, ASSOCIATED_RESET resetn, FREQ_HZ 300000000" *)
  input  wire                       clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                       resetn,

  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_RX_AXIS, ASSOCIATED_RESET rx_resetn" *)
  input  wire                       rx_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                       rx_resetn,
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

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_RX_AXIS TDATA" *)
  input  wire [AXIS_DATA_W_P-1:0]   s_rx_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_RX_AXIS TKEEP" *)
  input  wire [AXIS_KEEP_W_P-1:0]   s_rx_axis_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_RX_AXIS TVALID" *)
  input  wire                       s_rx_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_RX_AXIS TLAST" *)
  input  wire                       s_rx_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_RX_AXIS TUSER" *)
  (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 64, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 0" *)
  input  wire                       s_rx_axis_tuser
);

  rx_capture_core #(
    .AXIL_ADDR_W(AXIL_ADDR_W),
    .AXI_ADDR_W_P(AXI_ADDR_W_P),
    .AXI_ID_W_P(AXI_ID_W_P),
    .AXIS_DATA_W_P(AXIS_DATA_W_P),
    .AXIS_KEEP_W_P(AXIS_KEEP_W_P)
  ) core_i (
    .clk(clk),
    .resetn(resetn),
    .rx_clk(rx_clk),
    .rx_resetn(rx_resetn),
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
    .m_axi_awid(m_axi_awid),
    .m_axi_awaddr(m_axi_awaddr),
    .m_axi_awlen(m_axi_awlen),
    .m_axi_awsize(m_axi_awsize),
    .m_axi_awburst(m_axi_awburst),
    .m_axi_awlock(m_axi_awlock),
    .m_axi_awcache(m_axi_awcache),
    .m_axi_awprot(m_axi_awprot),
    .m_axi_awqos(m_axi_awqos),
    .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata),
    .m_axi_wstrb(m_axi_wstrb),
    .m_axi_wlast(m_axi_wlast),
    .m_axi_wvalid(m_axi_wvalid),
    .m_axi_wready(m_axi_wready),
    .m_axi_bid(m_axi_bid),
    .m_axi_bresp(m_axi_bresp),
    .m_axi_bvalid(m_axi_bvalid),
    .m_axi_bready(m_axi_bready),
    .m_axi_arid(m_axi_arid),
    .m_axi_araddr(m_axi_araddr),
    .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize),
    .m_axi_arburst(m_axi_arburst),
    .m_axi_arlock(m_axi_arlock),
    .m_axi_arcache(m_axi_arcache),
    .m_axi_arprot(m_axi_arprot),
    .m_axi_arqos(m_axi_arqos),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp),
    .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid),
    .m_axi_rready(m_axi_rready),
    .s_rx_axis_tdata(s_rx_axis_tdata),
    .s_rx_axis_tkeep(s_rx_axis_tkeep),
    .s_rx_axis_tvalid(s_rx_axis_tvalid),
    .s_rx_axis_tlast(s_rx_axis_tlast),
    .s_rx_axis_tuser(s_rx_axis_tuser)
  );
endmodule
