`timescale 1ns/1ps

import traffic_replay_pkg::*;

module trace_replay_core #(
  parameter int AXIL_ADDR_W = 16,
  parameter int AXI_ADDR_W_P = AXI_ADDR_W,
  parameter int AXI_ID_W_P   = AXI_ID_W
) (
  input  logic                     clk,
  input  logic                     rstn,
  input  logic                     link_up,

  input  logic [AXIL_ADDR_W-1:0]   s_axil_awaddr,
  input  logic                     s_axil_awvalid,
  output logic                     s_axil_awready,
  input  logic [31:0]              s_axil_wdata,
  input  logic [3:0]               s_axil_wstrb,
  input  logic                     s_axil_wvalid,
  output logic                     s_axil_wready,
  output logic [1:0]               s_axil_bresp,
  output logic                     s_axil_bvalid,
  input  logic                     s_axil_bready,
  input  logic [AXIL_ADDR_W-1:0]   s_axil_araddr,
  input  logic                     s_axil_arvalid,
  output logic                     s_axil_arready,
  output logic [31:0]              s_axil_rdata,
  output logic [1:0]               s_axil_rresp,
  output logic                     s_axil_rvalid,
  input  logic                     s_axil_rready,

  input  logic [AXIS_DATA_W-1:0]   s_host_axis_tdata,
  input  logic [AXIS_KEEP_W-1:0]   s_host_axis_tkeep,
  input  logic                     s_host_axis_tvalid,
  output logic                     s_host_axis_tready,
  input  logic                     s_host_axis_tlast,

  output logic [AXI_ID_W_P-1:0]    m_axi_arid,
  output logic [AXI_ADDR_W_P-1:0]  m_axi_araddr,
  output logic [7:0]               m_axi_arlen,
  output logic [2:0]               m_axi_arsize,
  output logic [1:0]               m_axi_arburst,
  output logic                     m_axi_arvalid,
  input  logic                     m_axi_arready,
  input  logic [AXI_ID_W_P-1:0]    m_axi_rid,
  input  logic [AXIS_DATA_W-1:0]   m_axi_rdata,
  input  logic [1:0]               m_axi_rresp,
  input  logic                     m_axi_rlast,
  input  logic                     m_axi_rvalid,
  output logic                     m_axi_rready,

  output logic [AXIS_DATA_W-1:0]   m_tx_axis_tdata,
  output logic [AXIS_KEEP_W-1:0]   m_tx_axis_tkeep,
  output logic                     m_tx_axis_tvalid,
  input  logic                     m_tx_axis_tready,
  output logic                     m_tx_axis_tlast,
  output logic                     m_tx_axis_tuser
);
  logic        start_pulse;
  logic        stop_pulse;
  logic        clear_pulse;
  logic        pause;
  logic [1:0]  cfg_mode;
  logic [63:0] cfg_desc_base;
  logic [63:0] cfg_data_base;
  logic [63:0] cfg_trace_bytes;
  logic [63:0] cfg_pkt_count;
  logic [63:0] cfg_loop_count;
  logic [63:0] cfg_loop_gap_ticks;
  logic [63:0] cfg_start_time;
  logic [31:0] cfg_rate_q16_16;
  logic [31:0] cfg_watermark;
  logic        cfg_force_link_up;

  logic        replay_running;
  logic        ddr_busy;
  logic        ddr_done;
  logic        ddr_error;
  logic        scheduler_late;
  logic        tx_underrun;
  logic [63:0] tx_pkts;
  logic [63:0] tx_bytes;
  logic [63:0] late_pkts;
  logic [63:0] underrun_pkts;
  logic [63:0] now_ticks;

  logic        ddr_meta_valid;
  logic        ddr_meta_ready;
  logic [63:0] ddr_meta_gap;
  logic [15:0] ddr_meta_len;
  logic [15:0] ddr_meta_flags;
  logic [AXIS_DATA_W-1:0] ddr_axis_tdata;
  logic [AXIS_KEEP_W-1:0] ddr_axis_tkeep;
  logic        ddr_axis_tvalid;
  logic        ddr_axis_tready;
  logic        ddr_axis_tlast;

  logic        host_meta_valid;
  logic        host_meta_ready;
  logic [63:0] host_meta_gap;
  logic [15:0] host_meta_len;
  logic [15:0] host_meta_flags;
  logic [AXIS_DATA_W-1:0] host_axis_tdata;
  logic [AXIS_KEEP_W-1:0] host_axis_tkeep;
  logic        host_axis_tvalid;
  logic        host_axis_tready;
  logic        host_axis_tlast;

  logic        sel_stream_mode;
  logic        sel_ddr_mode;
  logic        src_meta_valid;
  logic        src_meta_ready;
  logic [63:0] src_meta_gap;
  logic [15:0] src_meta_len;
  logic [15:0] src_meta_flags;
  logic [AXIS_DATA_W-1:0] src_axis_tdata;
  logic [AXIS_KEEP_W-1:0] src_axis_tkeep;
  logic        src_axis_tvalid;
  logic        src_axis_tready;
  logic        src_axis_tlast;

  logic        pkt_valid;
  logic        pkt_ready;
  logic [15:0] pkt_len;
  logic [15:0] pkt_flags;
  logic        core_clear;
  logic        core_enable;
  logic        effective_link_up;

  assign sel_stream_mode = (cfg_mode == MODE_STREAM);
  assign sel_ddr_mode    = (cfg_mode == MODE_PRELOAD) || (cfg_mode == MODE_LOOP);
  assign core_clear      = clear_pulse || stop_pulse;
  assign effective_link_up = link_up || cfg_force_link_up;
  assign core_enable     = replay_running && !pause && effective_link_up;

  assign src_meta_valid = sel_stream_mode ? host_meta_valid : ddr_meta_valid;
  assign src_meta_gap   = sel_stream_mode ? host_meta_gap   : ddr_meta_gap;
  assign src_meta_len   = sel_stream_mode ? host_meta_len   : ddr_meta_len;
  assign src_meta_flags = sel_stream_mode ? host_meta_flags : ddr_meta_flags;
  assign host_meta_ready = sel_stream_mode ? src_meta_ready : 1'b0;
  assign ddr_meta_ready  = sel_ddr_mode    ? src_meta_ready : 1'b0;

  assign src_axis_tdata  = sel_stream_mode ? host_axis_tdata  : ddr_axis_tdata;
  assign src_axis_tkeep  = sel_stream_mode ? host_axis_tkeep  : ddr_axis_tkeep;
  assign src_axis_tvalid = sel_stream_mode ? host_axis_tvalid : ddr_axis_tvalid;
  assign src_axis_tlast  = sel_stream_mode ? host_axis_tlast  : ddr_axis_tlast;
  assign host_axis_tready = sel_stream_mode ? src_axis_tready : 1'b0;
  assign ddr_axis_tready  = sel_ddr_mode    ? src_axis_tready : 1'b0;

  axi_lite_regs #(
    .ADDR_W(AXIL_ADDR_W),
    .DATA_W(32)
  ) regs_i (
    .aclk(clk),
    .aresetn(rstn),
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
    .start_pulse(start_pulse),
    .stop_pulse(stop_pulse),
    .clear_pulse(clear_pulse),
    .pause(pause),
    .cfg_mode(cfg_mode),
    .cfg_desc_base(cfg_desc_base),
    .cfg_data_base(cfg_data_base),
    .cfg_trace_bytes(cfg_trace_bytes),
    .cfg_pkt_count(cfg_pkt_count),
    .cfg_loop_count(cfg_loop_count),
    .cfg_loop_gap_ticks(cfg_loop_gap_ticks),
    .cfg_start_time(cfg_start_time),
    .cfg_rate_q16_16(cfg_rate_q16_16),
    .cfg_watermark(cfg_watermark),
    .cfg_force_link_up(cfg_force_link_up),
    .stat_running(replay_running),
    .stat_done(ddr_done),
    .stat_late(|late_pkts),
    .stat_underrun(|underrun_pkts),
    .stat_link_up(link_up),
    .stat_effective_link_up(effective_link_up),
    .stat_fifo_level(32'd0),
    .stat_tx_pkts(tx_pkts),
    .stat_tx_bytes(tx_bytes),
    .stat_late_pkts(late_pkts),
    .stat_underrun_pkts(underrun_pkts)
  );

  ddr_trace_reader #(
    .AXI_ADDR_W_P(AXI_ADDR_W_P),
    .AXI_ID_W_P(AXI_ID_W_P)
  ) ddr_reader_i (
    .clk(clk),
    .rstn(rstn),
    .start(start_pulse && sel_ddr_mode),
    .stop(stop_pulse),
    .clear(clear_pulse),
    .loop_mode(cfg_mode == MODE_LOOP),
    .cfg_desc_base(cfg_desc_base),
    .cfg_data_base(cfg_data_base),
    .cfg_pkt_count(cfg_pkt_count),
    .cfg_loop_count(cfg_loop_count),
    .cfg_loop_gap_ticks(cfg_loop_gap_ticks),
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
    .m_meta_valid(ddr_meta_valid),
    .m_meta_ready(ddr_meta_ready),
    .m_meta_gap_ticks(ddr_meta_gap),
    .m_meta_len(ddr_meta_len),
    .m_meta_flags(ddr_meta_flags),
    .m_axis_tdata(ddr_axis_tdata),
    .m_axis_tkeep(ddr_axis_tkeep),
    .m_axis_tvalid(ddr_axis_tvalid),
    .m_axis_tready(ddr_axis_tready),
    .m_axis_tlast(ddr_axis_tlast),
    .busy(ddr_busy),
    .done(ddr_done),
    .error(ddr_error)
  );

  host_stream_parser host_parser_i (
    .clk(clk),
    .rstn(rstn),
    .enable(core_enable && sel_stream_mode),
    .clear(core_clear),
    .s_axis_tdata(s_host_axis_tdata),
    .s_axis_tkeep(s_host_axis_tkeep),
    .s_axis_tvalid(s_host_axis_tvalid),
    .s_axis_tready(s_host_axis_tready),
    .s_axis_tlast(s_host_axis_tlast),
    .m_meta_valid(host_meta_valid),
    .m_meta_ready(host_meta_ready),
    .m_meta_gap_ticks(host_meta_gap),
    .m_meta_len(host_meta_len),
    .m_meta_flags(host_meta_flags),
    .m_axis_tdata(host_axis_tdata),
    .m_axis_tkeep(host_axis_tkeep),
    .m_axis_tvalid(host_axis_tvalid),
    .m_axis_tready(host_axis_tready),
    .m_axis_tlast(host_axis_tlast)
  );

  replay_scheduler scheduler_i (
    .clk(clk),
    .rstn(rstn),
    .enable(core_enable),
    .clear(core_clear),
    .cfg_start_time(cfg_start_time),
    .cfg_rate_q16_16(cfg_rate_q16_16),
    .s_meta_valid(src_meta_valid),
    .s_meta_ready(src_meta_ready),
    .s_meta_gap_ticks(src_meta_gap),
    .s_meta_len(src_meta_len),
    .s_meta_flags(src_meta_flags),
    .m_pkt_valid(pkt_valid),
    .m_pkt_ready(pkt_ready),
    .m_pkt_len(pkt_len),
    .m_pkt_flags(pkt_flags),
    .now_ticks(now_ticks),
    .late_pulse(scheduler_late)
  );

  replay_tx_engine tx_i (
    .clk(clk),
    .rstn(rstn),
    .enable(core_enable),
    .clear(core_clear),
    .s_pkt_valid(pkt_valid),
    .s_pkt_ready(pkt_ready),
    .s_pkt_len(pkt_len),
    .s_pkt_flags(pkt_flags),
    .s_axis_tdata(src_axis_tdata),
    .s_axis_tkeep(src_axis_tkeep),
    .s_axis_tvalid(src_axis_tvalid),
    .s_axis_tready(src_axis_tready),
    .s_axis_tlast(src_axis_tlast),
    .m_axis_tdata(m_tx_axis_tdata),
    .m_axis_tkeep(m_tx_axis_tkeep),
    .m_axis_tvalid(m_tx_axis_tvalid),
    .m_axis_tready(m_tx_axis_tready),
    .m_axis_tlast(m_tx_axis_tlast),
    .m_axis_tuser(m_tx_axis_tuser),
    .underrun_pulse(tx_underrun),
    .tx_pkts(tx_pkts),
    .tx_bytes(tx_bytes)
  );

  always_ff @(posedge clk) begin
    if (!rstn) begin
      replay_running <= 1'b0;
      late_pkts      <= '0;
      underrun_pkts  <= '0;
    end else begin
      if (clear_pulse) begin
        late_pkts     <= '0;
        underrun_pkts <= '0;
      end

      if (start_pulse) begin
        replay_running <= 1'b1;
      end else if (stop_pulse || (sel_ddr_mode && ddr_done)) begin
        replay_running <= 1'b0;
      end

      if (scheduler_late) begin
        late_pkts <= late_pkts + 64'd1;
      end
      if (tx_underrun) begin
        underrun_pkts <= underrun_pkts + 64'd1;
      end
    end
  end
endmodule
