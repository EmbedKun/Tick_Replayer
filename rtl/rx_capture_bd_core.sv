`timescale 1ns/1ps

module rx_capture_core #(
  parameter int AXIL_ADDR_W = 16,
  parameter int AXI_ADDR_W_P = 64,
  parameter int AXI_ID_W_P = 4,
  parameter int AXIS_DATA_W_P = 512,
  parameter int AXIS_KEEP_W_P = 64
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
  output logic                      s_axil_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WDATA" *)
  input  wire [31:0]                s_axil_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WSTRB" *)
  input  wire [3:0]                 s_axil_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WVALID" *)
  input  wire                       s_axil_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WREADY" *)
  output logic                      s_axil_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BRESP" *)
  output wire [1:0]                 s_axil_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BVALID" *)
  output logic                      s_axil_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BREADY" *)
  input  wire                       s_axil_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARADDR" *)
  input  wire [AXIL_ADDR_W-1:0]     s_axil_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARVALID" *)
  input  wire                       s_axil_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARREADY" *)
  output wire                       s_axil_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RDATA" *)
  output logic [31:0]               s_axil_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RRESP" *)
  output wire [1:0]                 s_axil_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RVALID" *)
  output logic                      s_axil_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RREADY" *)
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 16, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, SUPPORTS_NARROW_BURST 0" *)
  input  wire                       s_axil_rready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID" *)
  output wire [AXI_ID_W_P-1:0]      m_axi_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *)
  output logic [AXI_ADDR_W_P-1:0]   m_axi_awaddr,
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
  output logic                      m_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)
  input  wire                       m_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)
  output logic [AXIS_DATA_W_P-1:0]  m_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
  output logic [AXIS_KEEP_W_P-1:0]  m_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *)
  output wire                       m_axi_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)
  output logic                      m_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)
  input  wire                       m_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID" *)
  input  wire [AXI_ID_W_P-1:0]      m_axi_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)
  input  wire [1:0]                 m_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)
  input  wire                       m_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)
  output logic                      m_axi_bready,
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
  localparam logic [AXIL_ADDR_W-1:0] REG_CONTROL       = 16'h0000;
  localparam logic [AXIL_ADDR_W-1:0] REG_STATUS        = 16'h0004;
  localparam logic [AXIL_ADDR_W-1:0] REG_RING_BASE_LO  = 16'h0010;
  localparam logic [AXIL_ADDR_W-1:0] REG_RING_BASE_HI  = 16'h0014;
  localparam logic [AXIL_ADDR_W-1:0] REG_RING_SIZE     = 16'h0018;
  localparam logic [AXIL_ADDR_W-1:0] REG_TRUNC_BYTES   = 16'h001c;
  localparam logic [AXIL_ADDR_W-1:0] REG_WRITE_PTR     = 16'h0020;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_PKTS_LO    = 16'h0030;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_PKTS_HI    = 16'h0034;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_BYTES_LO   = 16'h0038;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_BYTES_HI   = 16'h003c;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_ERRS_LO    = 16'h0040;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_ERRS_HI    = 16'h0044;
  localparam logic [AXIL_ADDR_W-1:0] REG_CAP_BYTES_LO  = 16'h0048;
  localparam logic [AXIL_ADDR_W-1:0] REG_CAP_BYTES_HI  = 16'h004c;
  localparam logic [AXIL_ADDR_W-1:0] REG_AXI_WR_LO     = 16'h0050;
  localparam logic [AXIL_ADDR_W-1:0] REG_AXI_WR_HI     = 16'h0054;
  localparam logic [AXIL_ADDR_W-1:0] REG_AXI_ERR_LO    = 16'h0058;
  localparam logic [AXIL_ADDR_W-1:0] REG_AXI_ERR_HI    = 16'h005c;
  localparam logic [AXIL_ADDR_W-1:0] REG_DEBUG         = 16'h0060;

  logic [AXIL_ADDR_W-1:0] awaddr_q;
  logic aw_hold;
  logic w_hold;
  logic [31:0] wdata_q;
  logic [3:0] wstrb_q;
  logic do_write;

  logic cfg_enable;
  logic cfg_capture_enable;
  logic [63:0] cfg_ring_base;
  logic [31:0] cfg_ring_size;
  logic [31:0] cfg_trunc_bytes;
  (* ASYNC_REG = "TRUE" *) logic cfg_enable_rx_meta;
  (* ASYNC_REG = "TRUE" *) logic cfg_enable_rx_sync;

  wire fifo_s_ready;
  wire fifo_tvalid;
  wire fifo_tready;
  wire [AXIS_DATA_W_P-1:0] fifo_tdata;
  wire [AXIS_KEEP_W_P-1:0] fifo_tkeep;
  wire fifo_tlast;
  wire fifo_tuser;

  logic rx_overflow_seen;
  (* ASYNC_REG = "TRUE" *) logic rx_overflow_meta;
  (* ASYNC_REG = "TRUE" *) logic rx_overflow_sync;

  logic [31:0] write_ptr_q;
  logic [31:0] capture_remaining_q;
  logic in_packet_q;
  logic [63:0] stat_rx_pkts_q;
  logic [63:0] stat_rx_bytes_q;
  logic [63:0] stat_rx_errs_q;
  logic [63:0] stat_cap_bytes_q;
  logic [63:0] stat_axi_writes_q;
  logic [63:0] stat_axi_errors_q;

  logic [1:0] writer_state_q;
  logic aw_done_q;
  logic w_done_q;

  assign s_axil_bresp   = 2'b00;
  assign s_axil_rresp   = 2'b00;
  assign s_axil_arready = !s_axil_rvalid;
  assign do_write       = aw_hold && w_hold && !s_axil_bvalid;

  assign m_axi_awid    = {AXI_ID_W_P{1'b0}};
  assign m_axi_awlen   = 8'd0;
  assign m_axi_awsize  = 3'd6;
  assign m_axi_awburst = 2'b01;
  assign m_axi_awlock  = 1'b0;
  assign m_axi_awcache = 4'b0011;
  assign m_axi_awprot  = 3'b000;
  assign m_axi_awqos   = 4'd0;
  assign m_axi_wlast   = 1'b1;

  assign m_axi_arid    = {AXI_ID_W_P{1'b0}};
  assign m_axi_araddr  = {AXI_ADDR_W_P{1'b0}};
  assign m_axi_arlen   = 8'd0;
  assign m_axi_arsize  = 3'd6;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arlock  = 1'b0;
  assign m_axi_arcache = 4'b0011;
  assign m_axi_arprot  = 3'b000;
  assign m_axi_arqos   = 4'd0;
  assign m_axi_arvalid = 1'b0;
  assign m_axi_rready  = 1'b1;

  assign fifo_tready = cfg_enable && (writer_state_q == 2'd0);

  function automatic [31:0] apply_wstrb(
    input [31:0] old_value,
    input [31:0] new_value,
    input [3:0]  strobe
  );
    begin
      apply_wstrb = old_value;
      for (int i = 0; i < 4; i++) begin
        if (strobe[i]) begin
          apply_wstrb[i*8 +: 8] = new_value[i*8 +: 8];
        end
      end
    end
  endfunction

  function automatic [6:0] popcount_keep(input logic [AXIS_KEEP_W_P-1:0] keep);
    automatic logic [6:0] count;
    begin
      count = 7'd0;
      for (int i = 0; i < AXIS_KEEP_W_P; i++) begin
        count = count + {6'd0, keep[i]};
      end
      popcount_keep = count;
    end
  endfunction

  function automatic logic [AXIS_KEEP_W_P-1:0] limit_keep(
    input logic [AXIS_KEEP_W_P-1:0] keep,
    input logic [31:0] byte_limit
  );
    automatic logic [AXIS_KEEP_W_P-1:0] out_keep;
    begin
      out_keep = '0;
      for (int i = 0; i < AXIS_KEEP_W_P; i++) begin
        if (i < byte_limit) begin
          out_keep[i] = keep[i];
        end
      end
      limit_keep = out_keep;
    end
  endfunction

  wire rx_fifo_push = cfg_enable_rx_sync && s_rx_axis_tvalid && fifo_s_ready;

  axis_async_fifo #(
    .DATA_W(AXIS_DATA_W_P),
    .KEEP_W(AXIS_KEEP_W_P),
    .USER_W(1),
    .DEPTH_LOG2(5)
  ) rx_fifo_i (
    .s_clk(rx_clk),
    .s_resetn(rx_resetn),
    .m_clk(clk),
    .m_resetn(resetn),
    .s_axis_tdata(s_rx_axis_tdata),
    .s_axis_tkeep(s_rx_axis_tkeep),
    .s_axis_tvalid(rx_fifo_push),
    .s_axis_tready(fifo_s_ready),
    .s_axis_tlast(s_rx_axis_tlast),
    .s_axis_tuser(s_rx_axis_tuser),
    .m_axis_tdata(fifo_tdata),
    .m_axis_tkeep(fifo_tkeep),
    .m_axis_tvalid(fifo_tvalid),
    .m_axis_tready(fifo_tready),
    .m_axis_tlast(fifo_tlast),
    .m_axis_tuser(fifo_tuser)
  );

  always_ff @(posedge rx_clk or negedge rx_resetn) begin
    if (!rx_resetn) begin
      cfg_enable_rx_meta <= 1'b0;
      cfg_enable_rx_sync <= 1'b0;
      rx_overflow_seen <= 1'b0;
    end else begin
      cfg_enable_rx_meta <= cfg_enable;
      cfg_enable_rx_sync <= cfg_enable_rx_meta;
      if (!cfg_enable_rx_sync) begin
        rx_overflow_seen <= 1'b0;
      end else if (s_rx_axis_tvalid && !fifo_s_ready) begin
        rx_overflow_seen <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      rx_overflow_meta <= 1'b0;
      rx_overflow_sync <= 1'b0;
    end else begin
      rx_overflow_meta <= rx_overflow_seen;
      rx_overflow_sync <= rx_overflow_meta;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      s_axil_awready     <= 1'b0;
      s_axil_wready      <= 1'b0;
      s_axil_bvalid      <= 1'b0;
      s_axil_rvalid      <= 1'b0;
      s_axil_rdata       <= 32'd0;
      awaddr_q           <= '0;
      aw_hold            <= 1'b0;
      w_hold             <= 1'b0;
      wdata_q            <= 32'd0;
      wstrb_q            <= 4'd0;
      cfg_enable         <= 1'b0;
      cfg_capture_enable <= 1'b0;
      cfg_ring_base      <= 64'd0;
      cfg_ring_size      <= 32'd0;
      cfg_trunc_bytes    <= 32'd256;
      write_ptr_q        <= 32'd0;
      capture_remaining_q <= 32'd0;
      in_packet_q        <= 1'b0;
      stat_rx_pkts_q     <= 64'd0;
      stat_rx_bytes_q    <= 64'd0;
      stat_rx_errs_q     <= 64'd0;
      stat_cap_bytes_q   <= 64'd0;
      stat_axi_writes_q  <= 64'd0;
      stat_axi_errors_q  <= 64'd0;
      writer_state_q     <= 2'd0;
      aw_done_q          <= 1'b0;
      w_done_q           <= 1'b0;
      m_axi_awaddr       <= '0;
      m_axi_awvalid      <= 1'b0;
      m_axi_wdata        <= '0;
      m_axi_wstrb        <= '0;
      m_axi_wvalid       <= 1'b0;
      m_axi_bready       <= 1'b0;
    end else begin
      s_axil_awready <= !aw_hold && !s_axil_bvalid;
      s_axil_wready  <= !w_hold && !s_axil_bvalid;

      if (s_axil_awready && s_axil_awvalid) begin
        aw_hold  <= 1'b1;
        awaddr_q <= s_axil_awaddr;
      end

      if (s_axil_wready && s_axil_wvalid) begin
        w_hold  <= 1'b1;
        wdata_q <= s_axil_wdata;
        wstrb_q <= s_axil_wstrb;
      end

      if (do_write) begin
        unique case (awaddr_q)
          REG_CONTROL: begin
            if (wstrb_q[0]) begin
              cfg_enable         <= wdata_q[0];
              cfg_capture_enable <= wdata_q[2];
              if (wdata_q[1]) begin
                write_ptr_q         <= 32'd0;
                capture_remaining_q <= 32'd0;
                in_packet_q         <= 1'b0;
                stat_rx_pkts_q      <= 64'd0;
                stat_rx_bytes_q     <= 64'd0;
                stat_rx_errs_q      <= 64'd0;
                stat_cap_bytes_q    <= 64'd0;
                stat_axi_writes_q   <= 64'd0;
                stat_axi_errors_q   <= 64'd0;
              end
            end
          end
          REG_RING_BASE_LO: cfg_ring_base[31:0]  <= apply_wstrb(cfg_ring_base[31:0], wdata_q, wstrb_q);
          REG_RING_BASE_HI: cfg_ring_base[63:32] <= apply_wstrb(cfg_ring_base[63:32], wdata_q, wstrb_q);
          REG_RING_SIZE:    cfg_ring_size        <= apply_wstrb(cfg_ring_size, wdata_q, wstrb_q);
          REG_TRUNC_BYTES:  cfg_trunc_bytes      <= apply_wstrb(cfg_trunc_bytes, wdata_q, wstrb_q);
          REG_WRITE_PTR:    write_ptr_q          <= apply_wstrb(write_ptr_q, wdata_q, wstrb_q);
          default: begin
          end
        endcase
        aw_hold       <= 1'b0;
        w_hold        <= 1'b0;
        s_axil_bvalid <= 1'b1;
      end else if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end

      if (s_axil_arready && s_axil_arvalid) begin
        s_axil_rvalid <= 1'b1;
        unique case (s_axil_araddr)
          REG_CONTROL:      s_axil_rdata <= {29'd0, cfg_capture_enable, 1'b0, cfg_enable};
          REG_STATUS:       s_axil_rdata <= {24'd0, writer_state_q, rx_overflow_sync, link_up, fifo_tvalid, fifo_s_ready, m_axi_bvalid, m_axi_wvalid, m_axi_awvalid};
          REG_RING_BASE_LO: s_axil_rdata <= cfg_ring_base[31:0];
          REG_RING_BASE_HI: s_axil_rdata <= cfg_ring_base[63:32];
          REG_RING_SIZE:    s_axil_rdata <= cfg_ring_size;
          REG_TRUNC_BYTES:  s_axil_rdata <= cfg_trunc_bytes;
          REG_WRITE_PTR:    s_axil_rdata <= write_ptr_q;
          REG_RX_PKTS_LO:   s_axil_rdata <= stat_rx_pkts_q[31:0];
          REG_RX_PKTS_HI:   s_axil_rdata <= stat_rx_pkts_q[63:32];
          REG_RX_BYTES_LO:  s_axil_rdata <= stat_rx_bytes_q[31:0];
          REG_RX_BYTES_HI:  s_axil_rdata <= stat_rx_bytes_q[63:32];
          REG_RX_ERRS_LO:   s_axil_rdata <= stat_rx_errs_q[31:0];
          REG_RX_ERRS_HI:   s_axil_rdata <= stat_rx_errs_q[63:32];
          REG_CAP_BYTES_LO: s_axil_rdata <= stat_cap_bytes_q[31:0];
          REG_CAP_BYTES_HI: s_axil_rdata <= stat_cap_bytes_q[63:32];
          REG_AXI_WR_LO:    s_axil_rdata <= stat_axi_writes_q[31:0];
          REG_AXI_WR_HI:    s_axil_rdata <= stat_axi_writes_q[63:32];
          REG_AXI_ERR_LO:   s_axil_rdata <= stat_axi_errors_q[31:0];
          REG_AXI_ERR_HI:   s_axil_rdata <= stat_axi_errors_q[63:32];
          REG_DEBUG:        s_axil_rdata <= {8'd0, capture_remaining_q[15:0], 5'd0, in_packet_q, writer_state_q};
          default:          s_axil_rdata <= 32'h0;
        endcase
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end

      case (writer_state_q)
        2'd0: begin
          if (fifo_tvalid && fifo_tready) begin
            automatic logic [31:0] rem_before;
            automatic logic [AXIS_KEEP_W_P-1:0] cap_keep;
            automatic logic [6:0] beat_bytes;
            automatic logic [6:0] cap_bytes;
            automatic logic do_capture;

            rem_before = in_packet_q ? capture_remaining_q : cfg_trunc_bytes;
            cap_keep = limit_keep(fifo_tkeep, rem_before);
            beat_bytes = popcount_keep(fifo_tkeep);
            cap_bytes = popcount_keep(cap_keep);
            do_capture = cfg_capture_enable && (cfg_ring_size != 32'd0) && (cap_bytes != 7'd0);

            stat_rx_bytes_q <= stat_rx_bytes_q + {57'd0, beat_bytes};
            if (fifo_tlast) begin
              stat_rx_pkts_q <= stat_rx_pkts_q + 64'd1;
              if (fifo_tuser) begin
                stat_rx_errs_q <= stat_rx_errs_q + 64'd1;
              end
              in_packet_q <= 1'b0;
              capture_remaining_q <= 32'd0;
            end else begin
              in_packet_q <= 1'b1;
              capture_remaining_q <= (rem_before > beat_bytes) ? (rem_before - beat_bytes) : 32'd0;
            end

            if (do_capture) begin
              m_axi_awaddr  <= cfg_ring_base + {32'd0, write_ptr_q};
              m_axi_awvalid <= 1'b1;
              m_axi_wdata   <= fifo_tdata;
              m_axi_wstrb   <= cap_keep;
              m_axi_wvalid  <= 1'b1;
              m_axi_bready  <= 1'b1;
              aw_done_q     <= 1'b0;
              w_done_q      <= 1'b0;
              writer_state_q <= 2'd1;
              stat_cap_bytes_q <= stat_cap_bytes_q + {57'd0, cap_bytes};
              if (write_ptr_q + AXIS_KEEP_W_P >= cfg_ring_size) begin
                write_ptr_q <= 32'd0;
              end else begin
                write_ptr_q <= write_ptr_q + AXIS_KEEP_W_P;
              end
            end
          end
        end
        2'd1: begin
          if (m_axi_awvalid && m_axi_awready) begin
            m_axi_awvalid <= 1'b0;
            aw_done_q <= 1'b1;
          end
          if (m_axi_wvalid && m_axi_wready) begin
            m_axi_wvalid <= 1'b0;
            w_done_q <= 1'b1;
          end
          if ((aw_done_q || (m_axi_awvalid && m_axi_awready)) &&
              (w_done_q || (m_axi_wvalid && m_axi_wready))) begin
            writer_state_q <= 2'd2;
          end
        end
        2'd2: begin
          if (m_axi_bvalid) begin
            stat_axi_writes_q <= stat_axi_writes_q + 64'd1;
            if (m_axi_bresp != 2'b00) begin
              stat_axi_errors_q <= stat_axi_errors_q + 64'd1;
            end
            m_axi_bready <= 1'b0;
            writer_state_q <= 2'd0;
          end
        end
        default: writer_state_q <= 2'd0;
      endcase
    end
  end
endmodule
