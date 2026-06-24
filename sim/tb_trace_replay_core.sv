`timescale 1ns/1ps

import traffic_replay_pkg::*;

module tb_trace_replay_core;
  logic clk = 1'b0;
  logic rstn = 1'b0;

  always #1.55 clk = ~clk;

  logic [15:0] axil_awaddr;
  logic        axil_awvalid;
  logic        axil_awready;
  logic [31:0] axil_wdata;
  logic [3:0]  axil_wstrb;
  logic        axil_wvalid;
  logic        axil_wready;
  logic [1:0]  axil_bresp;
  logic        axil_bvalid;
  logic        axil_bready;
  logic [15:0] axil_araddr;
  logic        axil_arvalid;
  logic        axil_arready;
  logic [31:0] axil_rdata;
  logic [1:0]  axil_rresp;
  logic        axil_rvalid;
  logic        axil_rready;

  logic [511:0] host_tdata;
  logic [63:0]  host_tkeep;
  logic         host_tvalid;
  logic         host_tready;
  logic         host_tlast;

  logic [3:0]   arid;
  logic [63:0]  araddr;
  logic [7:0]   arlen;
  logic [2:0]   arsize;
  logic [1:0]   arburst;
  logic         arvalid;
  logic         arready;
  logic [3:0]   rid;
  logic [511:0] rdata;
  logic [1:0]   rresp;
  logic         rlast;
  logic         rvalid;
  logic         rready;

  logic [511:0] tx_tdata;
  logic [63:0]  tx_tkeep;
  logic         tx_tvalid;
  logic         tx_tready;
  logic         tx_tlast;
  logic         tx_tuser;

  int tx_pkt_count;
  int tx_beat_count;

  traffic_replay_top_stub dut (
    .clk(clk),
    .rstn(rstn),
    .link_up(1'b1),
    .s_axil_awaddr(axil_awaddr),
    .s_axil_awvalid(axil_awvalid),
    .s_axil_awready(axil_awready),
    .s_axil_wdata(axil_wdata),
    .s_axil_wstrb(axil_wstrb),
    .s_axil_wvalid(axil_wvalid),
    .s_axil_wready(axil_wready),
    .s_axil_bresp(axil_bresp),
    .s_axil_bvalid(axil_bvalid),
    .s_axil_bready(axil_bready),
    .s_axil_araddr(axil_araddr),
    .s_axil_arvalid(axil_arvalid),
    .s_axil_arready(axil_arready),
    .s_axil_rdata(axil_rdata),
    .s_axil_rresp(axil_rresp),
    .s_axil_rvalid(axil_rvalid),
    .s_axil_rready(axil_rready),
    .s_host_axis_tdata(host_tdata),
    .s_host_axis_tkeep(host_tkeep),
    .s_host_axis_tvalid(host_tvalid),
    .s_host_axis_tready(host_tready),
    .s_host_axis_tlast(host_tlast),
    .m_axi_arid(arid),
    .m_axi_araddr(araddr),
    .m_axi_arlen(arlen),
    .m_axi_arsize(arsize),
    .m_axi_arburst(arburst),
    .m_axi_arvalid(arvalid),
    .m_axi_arready(arready),
    .m_axi_rid(rid),
    .m_axi_rdata(rdata),
    .m_axi_rresp(rresp),
    .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid),
    .m_axi_rready(rready),
    .m_tx_axis_tdata(tx_tdata),
    .m_tx_axis_tkeep(tx_tkeep),
    .m_tx_axis_tvalid(tx_tvalid),
    .m_tx_axis_tready(tx_tready),
    .m_tx_axis_tlast(tx_tlast),
    .m_tx_axis_tuser(tx_tuser)
  );

  initial begin
    arready = 1'b0;
    rid     = '0;
    rdata   = '0;
    rresp   = 2'b00;
    rlast   = 1'b0;
    rvalid  = 1'b0;
  end

  task automatic axil_write(input [15:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      axil_awaddr  <= addr;
      axil_awvalid <= 1'b1;
      axil_wdata   <= data;
      axil_wstrb   <= 4'hf;
      axil_wvalid  <= 1'b1;
      axil_bready  <= 1'b1;

      wait (axil_awready && axil_wready);
      @(posedge clk);
      axil_awvalid <= 1'b0;
      axil_wvalid  <= 1'b0;

      wait (axil_bvalid);
      @(posedge clk);
      axil_bready <= 1'b0;
    end
  endtask

  task automatic send_host_packet(input [63:0] gap_ticks, input [15:0] length, input [7:0] seed);
    logic [511:0] header;
    logic [511:0] payload;
    begin
      header = '0;
      header[63:0]    = gap_ticks;
      header[111:96]  = length;
      header[127:112] = 16'd0;

      payload = '0;
      for (int i = 0; i < 64; i++) begin
        payload[i*8 +: 8] = seed + i[7:0];
      end

      @(posedge clk);
      host_tdata  <= header;
      host_tkeep  <= {64{1'b1}};
      host_tlast  <= 1'b0;
      host_tvalid <= 1'b1;
      wait (host_tready);
      @(posedge clk);
      host_tvalid <= 1'b0;

      @(posedge clk);
      host_tdata  <= payload;
      host_tkeep  <= keep_from_len(length);
      host_tlast  <= 1'b1;
      host_tvalid <= 1'b1;
      wait (host_tready);
      @(posedge clk);
      host_tvalid <= 1'b0;
      host_tlast  <= 1'b0;
    end
  endtask

  always_ff @(posedge clk) begin
    if (!rstn) begin
      tx_pkt_count  <= 0;
      tx_beat_count <= 0;
    end else if (tx_tvalid && tx_tready) begin
      tx_beat_count <= tx_beat_count + 1;
      if (tx_tlast) begin
        tx_pkt_count <= tx_pkt_count + 1;
      end
    end
  end

  initial begin
    repeat (5000) @(posedge clk);
    $fatal(1, "Simulation watchdog timeout");
  end

  initial begin
    axil_awaddr  = '0;
    axil_awvalid = 1'b0;
    axil_wdata   = '0;
    axil_wstrb   = 4'h0;
    axil_wvalid  = 1'b0;
    axil_bready  = 1'b0;
    axil_araddr  = '0;
    axil_arvalid = 1'b0;
    axil_rready  = 1'b0;
    host_tdata   = '0;
    host_tkeep   = '0;
    host_tvalid  = 1'b0;
    host_tlast   = 1'b0;
    tx_tready    = 1'b1;

    repeat (10) @(posedge clk);
    rstn = 1'b1;
    repeat (10) @(posedge clk);

    axil_write(16'h0004, 32'd1);
    axil_write(16'h0000, 32'd1);

    send_host_packet(64'd4, 16'd64, 8'h10);
    send_host_packet(64'd3, 16'd60, 8'h40);

    for (int timeout = 0; timeout < 300 && tx_pkt_count < 2; timeout++) begin
      @(posedge clk);
    end

    if (tx_pkt_count != 2) begin
      $fatal(1, "Expected 2 TX packets, got %0d", tx_pkt_count);
    end
    if (tx_beat_count != 2) begin
      $fatal(1, "Expected 2 TX beats, got %0d", tx_beat_count);
    end
    $display("PASS: host stream replay emitted %0d packets", tx_pkt_count);
    $finish;
  end
endmodule
