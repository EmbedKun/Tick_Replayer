`timescale 1ns/1ps

module tb_rx_capture_core_clear;
  localparam int AXIL_ADDR_W = 16;
  localparam int AXI_ADDR_W = 64;
  localparam int AXI_ID_W = 4;
  localparam int AXIS_DATA_W = 512;
  localparam int AXIS_KEEP_W = 64;
  localparam logic [63:0] RING_BASE = 64'h0000_0000_0000_1000;
  localparam int RING_SIZE = 4096;
  localparam int MEM_WORDS = 512;

  localparam logic [15:0] REG_CONTROL       = 16'h0000;
  localparam logic [15:0] REG_STATUS        = 16'h0004;
  localparam logic [15:0] REG_RING_BASE_LO  = 16'h0010;
  localparam logic [15:0] REG_RING_BASE_HI  = 16'h0014;
  localparam logic [15:0] REG_RING_SIZE     = 16'h0018;
  localparam logic [15:0] REG_TRUNC_BYTES   = 16'h001c;
  localparam logic [15:0] REG_WRITE_PTR     = 16'h0020;
  localparam logic [15:0] REG_RX_PKTS_LO    = 16'h0030;
  localparam logic [15:0] REG_RX_BYTES_LO   = 16'h0038;
  localparam logic [15:0] REG_RX_ERRS_LO    = 16'h0040;
  localparam logic [15:0] REG_CAP_BYTES_LO  = 16'h0048;
  localparam logic [15:0] REG_AXI_WR_LO     = 16'h0050;
  localparam logic [15:0] REG_AXI_ERR_LO    = 16'h0058;
  localparam logic [15:0] REG_DEBUG         = 16'h0060;

  logic clk = 1'b0;
  logic rx_clk = 1'b0;
  logic resetn = 1'b0;
  logic rx_resetn = 1'b0;

  always #1.666 clk = ~clk;
  always #1.553 rx_clk = ~rx_clk;

  logic [AXIL_ADDR_W-1:0] s_axil_awaddr;
  logic                  s_axil_awvalid;
  wire                   s_axil_awready;
  logic [31:0]           s_axil_wdata;
  logic [3:0]            s_axil_wstrb;
  logic                  s_axil_wvalid;
  wire                   s_axil_wready;
  wire [1:0]             s_axil_bresp;
  wire                   s_axil_bvalid;
  logic                  s_axil_bready;
  logic [AXIL_ADDR_W-1:0] s_axil_araddr;
  logic                  s_axil_arvalid;
  wire                   s_axil_arready;
  wire [31:0]            s_axil_rdata;
  wire [1:0]             s_axil_rresp;
  wire                   s_axil_rvalid;
  logic                  s_axil_rready;

  wire [AXI_ID_W-1:0]    m_axi_awid;
  wire [AXI_ADDR_W-1:0]  m_axi_awaddr;
  wire [7:0]             m_axi_awlen;
  wire [2:0]             m_axi_awsize;
  wire [1:0]             m_axi_awburst;
  wire                   m_axi_awlock;
  wire [3:0]             m_axi_awcache;
  wire [2:0]             m_axi_awprot;
  wire [3:0]             m_axi_awqos;
  wire                   m_axi_awvalid;
  logic                  m_axi_awready;
  wire [AXIS_DATA_W-1:0] m_axi_wdata;
  wire [AXIS_KEEP_W-1:0] m_axi_wstrb;
  wire                   m_axi_wlast;
  wire                   m_axi_wvalid;
  logic                  m_axi_wready;
  logic [AXI_ID_W-1:0]   m_axi_bid;
  logic [1:0]            m_axi_bresp;
  logic                  m_axi_bvalid;
  wire                   m_axi_bready;
  wire [AXI_ID_W-1:0]    m_axi_arid;
  wire [AXI_ADDR_W-1:0]  m_axi_araddr;
  wire [7:0]             m_axi_arlen;
  wire [2:0]             m_axi_arsize;
  wire [1:0]             m_axi_arburst;
  wire                   m_axi_arlock;
  wire [3:0]             m_axi_arcache;
  wire [2:0]             m_axi_arprot;
  wire [3:0]             m_axi_arqos;
  wire                   m_axi_arvalid;
  logic                  m_axi_arready;
  logic [AXI_ID_W-1:0]   m_axi_rid;
  logic [AXIS_DATA_W-1:0] m_axi_rdata;
  logic [1:0]            m_axi_rresp;
  logic                  m_axi_rlast;
  logic                  m_axi_rvalid;
  wire                   m_axi_rready;

  logic [AXIS_DATA_W-1:0] s_rx_axis_tdata;
  logic [AXIS_KEEP_W-1:0] s_rx_axis_tkeep;
  logic                  s_rx_axis_tvalid;
  logic                  s_rx_axis_tstart;
  logic                  s_rx_axis_tlast;
  logic                  s_rx_axis_tuser;

  logic [AXIS_DATA_W-1:0] mem [0:MEM_WORDS-1];
  logic aw_seen;
  logic w_seen;
  logic [AXI_ADDR_W-1:0] awaddr_q;
  logic [AXIS_DATA_W-1:0] wdata_q;

  rx_capture_core #(
    .AXIL_ADDR_W(AXIL_ADDR_W),
    .AXI_ADDR_W_P(AXI_ADDR_W),
    .AXI_ID_W_P(AXI_ID_W),
    .AXIS_DATA_W_P(AXIS_DATA_W),
    .AXIS_KEEP_W_P(AXIS_KEEP_W)
  ) dut (
    .clk(clk),
    .resetn(resetn),
    .rx_clk(rx_clk),
    .rx_resetn(rx_resetn),
    .link_up(1'b1),
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
    .s_rx_axis_tstart(s_rx_axis_tstart),
    .s_rx_axis_tlast(s_rx_axis_tlast),
    .s_rx_axis_tuser(s_rx_axis_tuser)
  );

  task automatic axil_write(input logic [15:0] addr, input logic [31:0] data);
    begin
      @(posedge clk);
      s_axil_awaddr <= addr;
      s_axil_wdata <= data;
      s_axil_wstrb <= 4'hf;
      s_axil_awvalid <= 1'b1;
      s_axil_wvalid <= 1'b1;
      while (!(s_axil_awready && s_axil_wready)) begin
        @(posedge clk);
      end
      @(posedge clk);
      s_axil_awvalid <= 1'b0;
      s_axil_wvalid <= 1'b0;
      s_axil_bready <= 1'b1;
      while (!s_axil_bvalid) begin
        @(posedge clk);
      end
      @(posedge clk);
      s_axil_bready <= 1'b0;
    end
  endtask

  task automatic axil_read(input logic [15:0] addr, output logic [31:0] data);
    begin
      @(posedge clk);
      s_axil_araddr <= addr;
      s_axil_arvalid <= 1'b1;
      while (!s_axil_arready) begin
        @(posedge clk);
      end
      @(posedge clk);
      s_axil_arvalid <= 1'b0;
      s_axil_rready <= 1'b1;
      while (!s_axil_rvalid) begin
        @(posedge clk);
      end
      data = s_axil_rdata;
      @(posedge clk);
      s_axil_rready <= 1'b0;
    end
  endtask

  task automatic wait_rx_clear_settled;
    logic [31:0] status;
    logic [31:0] write_ptr;
    logic [31:0] rx_pkts;
    logic [31:0] rx_bytes;
    logic [31:0] rx_errs;
    logic [31:0] cap_bytes;
    logic [31:0] axi_writes;
    logic [31:0] axi_errors;
    logic [31:0] debug;
    begin
      repeat (260) @(posedge clk);
      axil_read(REG_STATUS, status);
      axil_read(REG_WRITE_PTR, write_ptr);
      axil_read(REG_RX_PKTS_LO, rx_pkts);
      axil_read(REG_RX_BYTES_LO, rx_bytes);
      axil_read(REG_RX_ERRS_LO, rx_errs);
      axil_read(REG_CAP_BYTES_LO, cap_bytes);
      axil_read(REG_AXI_WR_LO, axi_writes);
      axil_read(REG_AXI_ERR_LO, axi_errors);
      axil_read(REG_DEBUG, debug);
      if (((status >> 7) & 32'h3) != 0) begin
        $fatal(1, "RX writer state not idle after clear status=0x%08x debug=0x%08x", status, debug);
      end
      if ((status & 32'h17) != 0) begin
        $fatal(1, "RX busy bits set after clear status=0x%08x debug=0x%08x", status, debug);
      end
      if (write_ptr != 0 || rx_pkts != 0 || rx_bytes != 0 || rx_errs != 0 ||
          cap_bytes != 0 || axi_writes != 0 || axi_errors != 0) begin
        $fatal(1, "RX clear did not reset regs wp=%0d pkts=%0d bytes=%0d errs=%0d cap=%0d wr=%0d axierr=%0d",
               write_ptr, rx_pkts, rx_bytes, rx_errs, cap_bytes, axi_writes, axi_errors);
      end
    end
  endtask

  function automatic logic [AXIS_DATA_W-1:0] make_beat(input int pkt, input int beat, input byte seed);
    logic [AXIS_DATA_W-1:0] data;
    begin
      for (int i = 0; i < AXIS_KEEP_W; i++) begin
        data[i*8 +: 8] = byte'((seed + pkt * 17 + beat * 31 + i * 3 + (pkt >> 4)) & 8'hff);
      end
      make_beat = data;
    end
  endfunction

  task automatic send_packet(input int pkt, input byte seed);
    begin
      @(posedge rx_clk);
      s_rx_axis_tdata <= make_beat(pkt, 0, seed);
      s_rx_axis_tkeep <= {AXIS_KEEP_W{1'b1}};
      s_rx_axis_tstart <= 1'b1;
      s_rx_axis_tlast <= 1'b0;
      s_rx_axis_tuser <= 1'b0;
      s_rx_axis_tvalid <= 1'b1;
      @(posedge rx_clk);
      s_rx_axis_tdata <= make_beat(pkt, 1, seed);
      s_rx_axis_tstart <= 1'b0;
      s_rx_axis_tlast <= 1'b1;
      @(posedge rx_clk);
      s_rx_axis_tvalid <= 1'b0;
      s_rx_axis_tstart <= 1'b0;
      s_rx_axis_tlast <= 1'b0;
      repeat (24) @(posedge rx_clk);
    end
  endtask

  task automatic configure_capture;
    begin
      axil_write(REG_RING_BASE_LO, RING_BASE[31:0]);
      axil_write(REG_RING_BASE_HI, RING_BASE[63:32]);
      axil_write(REG_RING_SIZE, RING_SIZE);
      axil_write(REG_TRUNC_BYTES, 32'd64);
      axil_write(REG_CONTROL, 32'h5);
      repeat (8) @(posedge clk);
    end
  endtask

  task automatic clear_capture;
    begin
      axil_write(REG_CONTROL, 32'h0);
      axil_write(REG_CONTROL, 32'h2);
      wait_rx_clear_settled();
    end
  endtask

  always_ff @(posedge clk) begin
    if (!resetn) begin
      m_axi_awready <= 1'b0;
      m_axi_wready <= 1'b0;
      m_axi_bvalid <= 1'b0;
      m_axi_bresp <= 2'b00;
      m_axi_bid <= '0;
      m_axi_arready <= 1'b1;
      m_axi_rvalid <= 1'b0;
      m_axi_rdata <= '0;
      m_axi_rresp <= 2'b00;
      m_axi_rlast <= 1'b1;
      m_axi_rid <= '0;
      aw_seen <= 1'b0;
      w_seen <= 1'b0;
      awaddr_q <= '0;
      wdata_q <= '0;
    end else begin
      m_axi_awready <= 1'b1;
      m_axi_wready <= 1'b1;
      if (m_axi_awvalid && m_axi_awready) begin
        aw_seen <= 1'b1;
        awaddr_q <= m_axi_awaddr;
      end
      if (m_axi_wvalid && m_axi_wready) begin
        w_seen <= 1'b1;
        wdata_q <= m_axi_wdata;
      end
      if ((aw_seen || (m_axi_awvalid && m_axi_awready)) &&
          (w_seen || (m_axi_wvalid && m_axi_wready)) &&
          !m_axi_bvalid) begin
        logic [AXI_ADDR_W-1:0] wr_addr;
        logic [AXIS_DATA_W-1:0] wr_data;
        wr_addr = (m_axi_awvalid && m_axi_awready) ? m_axi_awaddr : awaddr_q;
        wr_data = (m_axi_wvalid && m_axi_wready) ? m_axi_wdata : wdata_q;
        mem[(wr_addr - RING_BASE) >> 6] <= wr_data;
        m_axi_bvalid <= 1'b1;
        aw_seen <= 1'b0;
        w_seen <= 1'b0;
      end
      if (m_axi_bvalid && m_axi_bready) begin
        m_axi_bvalid <= 1'b0;
      end
    end
  end

  initial begin
    for (int i = 0; i < MEM_WORDS; i++) begin
      mem[i] = {AXIS_DATA_W{1'b1}};
    end
    s_axil_awaddr = '0;
    s_axil_awvalid = 1'b0;
    s_axil_wdata = '0;
    s_axil_wstrb = '0;
    s_axil_wvalid = 1'b0;
    s_axil_bready = 1'b0;
    s_axil_araddr = '0;
    s_axil_arvalid = 1'b0;
    s_axil_rready = 1'b0;
    s_rx_axis_tdata = '0;
    s_rx_axis_tkeep = '0;
    s_rx_axis_tvalid = 1'b0;
    s_rx_axis_tstart = 1'b0;
    s_rx_axis_tlast = 1'b0;
    s_rx_axis_tuser = 1'b0;

    repeat (20) @(posedge clk);
    resetn = 1'b1;
    rx_resetn = 1'b1;
    repeat (20) @(posedge clk);

    configure_capture();
    send_packet(0, 8'h80);
    send_packet(1, 8'h80);
    repeat (200) @(posedge clk);

    clear_capture();
    configure_capture();
    for (int pkt = 0; pkt < 8; pkt++) begin
      send_packet(pkt, 8'h20);
    end
    repeat (600) @(posedge clk);

    begin
      logic [31:0] write_ptr;
      logic [31:0] rx_pkts;
      logic [31:0] rx_bytes;
      logic [31:0] rx_errs;
      logic [31:0] cap_bytes;
      logic [31:0] axi_writes;
      axil_read(REG_WRITE_PTR, write_ptr);
      axil_read(REG_RX_PKTS_LO, rx_pkts);
      axil_read(REG_RX_BYTES_LO, rx_bytes);
      axil_read(REG_RX_ERRS_LO, rx_errs);
      axil_read(REG_CAP_BYTES_LO, cap_bytes);
      axil_read(REG_AXI_WR_LO, axi_writes);
      if (write_ptr != 32'd512 || rx_pkts != 32'd8 || rx_bytes != 32'd1024 ||
          rx_errs != 32'd0 || cap_bytes != 32'd512 || axi_writes != 32'd8) begin
        $fatal(1, "unexpected RX stats wp=%0d pkts=%0d bytes=%0d errs=%0d cap=%0d axiwr=%0d",
               write_ptr, rx_pkts, rx_bytes, rx_errs, cap_bytes, axi_writes);
      end
    end

    for (int pkt = 0; pkt < 8; pkt++) begin
      if (mem[pkt] !== make_beat(pkt, 0, 8'h20)) begin
        $fatal(1, "RX sample mismatch pkt=%0d got=%h expected=%h",
               pkt, mem[pkt], make_beat(pkt, 0, 8'h20));
      end
    end

    $display("PASS: rx_capture_core clear resets state and sample ring captures fresh packet starts");
    $finish;
  end

  initial begin
    repeat (20000) @(posedge clk);
    $fatal(1, "rx_capture_core clear simulation watchdog timeout");
  end

  wire unused = ^{
    s_axil_bresp,
    s_axil_rresp,
    m_axi_awid,
    m_axi_awlen,
    m_axi_awsize,
    m_axi_awburst,
    m_axi_awlock,
    m_axi_awcache,
    m_axi_awprot,
    m_axi_awqos,
    m_axi_wstrb,
    m_axi_wlast,
    m_axi_arid,
    m_axi_araddr,
    m_axi_arlen,
    m_axi_arsize,
    m_axi_arburst,
    m_axi_arlock,
    m_axi_arcache,
    m_axi_arprot,
    m_axi_arqos,
    m_axi_arvalid,
    m_axi_rready
  };
endmodule
