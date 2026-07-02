`timescale 1ns/1ps

import traffic_replay_pkg::*;

module trace_replay_core #(
  parameter int AXIL_ADDR_W = 16,
  parameter int AXI_ADDR_W_P = AXI_ADDR_W,
  parameter int AXI_ID_W_P   = AXI_ID_W,
  parameter int TX_STALL_WATCHDOG_CYCLES_P = 4096
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
  logic [63:0] cfg_stream_ring_size;
  logic [63:0] cfg_stream_write_count;
  logic        cfg_stream_eof;
  logic        cfg_force_link_up;
  logic        cfg_force_tx_ready;
  logic        cfg_auto_tx_drop;

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
  logic [63:0] drop_pkts;
  logic [63:0] drop_beats;
  logic [63:0] stall_events;
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

  logic [AXI_ID_W_P-1:0]    ddr_m_axi_arid;
  logic [AXI_ADDR_W_P-1:0]  ddr_m_axi_araddr;
  logic [7:0]               ddr_m_axi_arlen;
  logic [2:0]               ddr_m_axi_arsize;
  logic [1:0]               ddr_m_axi_arburst;
  logic                     ddr_m_axi_arvalid;
  logic                     ddr_m_axi_arready;
  logic                     ddr_m_axi_rvalid;
  logic                     ddr_m_axi_rready;

  logic [AXI_ID_W_P-1:0]    stream_m_axi_arid;
  logic [AXI_ADDR_W_P-1:0]  stream_m_axi_araddr;
  logic [7:0]               stream_m_axi_arlen;
  logic [2:0]               stream_m_axi_arsize;
  logic [1:0]               stream_m_axi_arburst;
  logic                     stream_m_axi_arvalid;
  logic                     stream_m_axi_arready;
  logic                     stream_m_axi_rvalid;
  logic                     stream_m_axi_rready;

  logic [AXIS_DATA_W-1:0] stream_ddr_axis_tdata;
  logic [AXIS_KEEP_W-1:0] stream_ddr_axis_tkeep;
  logic                   stream_ddr_axis_tvalid;
  logic                   stream_ddr_axis_tready;
  logic                   stream_ddr_axis_tlast;
  logic                   stream_ddr_busy;
  logic                   stream_ddr_done;
  logic                   stream_ddr_error;
  logic [63:0]            stream_ddr_read_count;
  logic [63:0]            stream_ddr_level;
  logic [31:0]            stream_ddr_status;
  logic [3:0]             stream_ddr_state;
  logic                   stream_ddr_mode;
  logic                   stream_reader_start;

  localparam int STREAM_FIFO_DEPTH = 8192;
  localparam int STREAM_FIFO_COUNT_W = $clog2(STREAM_FIFO_DEPTH + 1);
  localparam logic [STREAM_FIFO_COUNT_W-1:0] STREAM_FIFO_DEPTH_LEVEL = STREAM_FIFO_DEPTH;
  localparam logic [STREAM_FIFO_COUNT_W-1:0] STREAM_FIFO_LEVEL_ONE = 1;
  localparam int PRELOAD_WARMUP_CYCLES = 4096;
  localparam int PRELOAD_WARMUP_CNT_W = $clog2(PRELOAD_WARMUP_CYCLES + 1);
  localparam logic [PRELOAD_WARMUP_CNT_W-1:0] PRELOAD_WARMUP_CYCLES_LEVEL = PRELOAD_WARMUP_CYCLES;
  localparam int TX_STALL_WATCHDOG_CYCLES = (TX_STALL_WATCHDOG_CYCLES_P < 2) ? 2 : TX_STALL_WATCHDOG_CYCLES_P;
  localparam int TX_STALL_CNT_W = $clog2(TX_STALL_WATCHDOG_CYCLES + 1);
  localparam logic [TX_STALL_CNT_W-1:0] TX_STALL_WATCHDOG_LEVEL = TX_STALL_WATCHDOG_CYCLES;

  logic [AXIS_DATA_W-1:0] stream_fifo_axis_tdata;
  logic [AXIS_KEEP_W-1:0] stream_fifo_axis_tkeep;
  logic                   stream_fifo_axis_tvalid;
  logic                   stream_fifo_axis_tready;
  logic                   stream_fifo_axis_tlast;
  logic [STREAM_FIFO_COUNT_W-1:0] stream_fifo_level;
  logic [STREAM_FIFO_COUNT_W-1:0] stream_fifo_watermark_beats;
  logic                   stream_prefetch_ready;
  logic                   stream_prefetch_active;
  logic                   parser_enable;

  logic [AXIS_DATA_W-1:0] parser_axis_tdata;
  logic [AXIS_KEEP_W-1:0] parser_axis_tkeep;
  logic                   parser_axis_tvalid;
  logic                   parser_axis_tready;
  logic                   parser_axis_tlast;

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

  logic        sel_stream_mode_comb;
  logic        sel_ddr_mode_comb;
  logic        stream_ddr_mode_comb;
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
  logic [PRELOAD_WARMUP_CNT_W-1:0] preload_warmup_count;
  logic        preload_warmup_done;
  logic        effective_link_up;
  logic        tx_ready_effective;
  logic        tx_backpressured;
  logic        auto_tx_drop_active;
  logic        auto_tx_drop_start;
  logic        auto_tx_drop_fire;
  logic [TX_STALL_CNT_W-1:0] tx_stall_count;
  logic        ddr_reader_start;
  logic        source_busy;
  logic        source_done;
  logic        source_error;
  logic        replay_done;
  logic [3:0]  ddr_reader_state;
  logic [3:0]  active_reader_state;
  logic [31:0] debug_status;
  logic [31:0] debug_axi;

  assign sel_stream_mode_comb = (cfg_mode == MODE_STREAM);
  assign sel_ddr_mode_comb    = (cfg_mode == MODE_PRELOAD) || (cfg_mode == MODE_LOOP);
  assign stream_ddr_mode_comb = sel_stream_mode_comb && ((cfg_trace_bytes != 64'd0) || (cfg_stream_ring_size != 64'd0));
  assign core_clear      = clear_pulse || stop_pulse;
  assign effective_link_up = link_up || cfg_force_link_up;
  assign core_enable     = replay_running && !pause && effective_link_up &&
                           (!sel_ddr_mode || preload_warmup_done);
  assign tx_backpressured = core_enable && m_tx_axis_tvalid && !m_tx_axis_tready &&
                            !cfg_force_tx_ready;
  assign auto_tx_drop_start = cfg_auto_tx_drop && tx_backpressured &&
                              (tx_stall_count >= TX_STALL_WATCHDOG_LEVEL);
  assign auto_tx_drop_fire = auto_tx_drop_active && m_tx_axis_tvalid &&
                             !m_tx_axis_tready;
  assign tx_ready_effective = m_tx_axis_tready || cfg_force_tx_ready ||
                              auto_tx_drop_active;
  assign ddr_reader_start = sel_ddr_mode && start_pulse;
  assign stream_reader_start = stream_ddr_mode && start_pulse;
  assign source_busy = sel_ddr_mode ? ddr_busy : (stream_ddr_mode ? stream_ddr_busy : 1'b0);
  assign source_done = sel_ddr_mode ? ddr_done : (stream_ddr_mode ? stream_ddr_done : 1'b0);
  assign source_error = sel_ddr_mode ? ddr_error : (stream_ddr_mode ? stream_ddr_error : 1'b0);
  assign active_reader_state = stream_ddr_mode ? stream_ddr_state : ddr_reader_state;
  assign replay_done = sel_ddr_mode ? ddr_done :
                       (stream_ddr_mode ? (stream_ddr_done && (cfg_pkt_count != 64'd0) && (tx_pkts >= cfg_pkt_count)) : 1'b0);

  assign m_axi_arid     = stream_ddr_mode ? stream_m_axi_arid     : ddr_m_axi_arid;
  assign m_axi_araddr   = stream_ddr_mode ? stream_m_axi_araddr   : ddr_m_axi_araddr;
  assign m_axi_arlen    = stream_ddr_mode ? stream_m_axi_arlen    : ddr_m_axi_arlen;
  assign m_axi_arsize   = stream_ddr_mode ? stream_m_axi_arsize   : ddr_m_axi_arsize;
  assign m_axi_arburst  = stream_ddr_mode ? stream_m_axi_arburst  : ddr_m_axi_arburst;
  assign m_axi_arvalid  = stream_ddr_mode ? stream_m_axi_arvalid  : ddr_m_axi_arvalid;
  assign m_axi_rready   = stream_ddr_mode ? stream_m_axi_rready   : ddr_m_axi_rready;

  assign ddr_m_axi_arready    = !stream_ddr_mode ? m_axi_arready : 1'b0;
  assign stream_m_axi_arready =  stream_ddr_mode ? m_axi_arready : 1'b0;
  assign ddr_m_axi_rvalid     = !stream_ddr_mode ? m_axi_rvalid  : 1'b0;
  assign stream_m_axi_rvalid  =  stream_ddr_mode ? m_axi_rvalid  : 1'b0;

  assign parser_axis_tdata  = stream_ddr_mode ? stream_fifo_axis_tdata  : s_host_axis_tdata;
  assign parser_axis_tkeep  = stream_ddr_mode ? stream_fifo_axis_tkeep  : s_host_axis_tkeep;
  assign parser_axis_tvalid = stream_ddr_mode ? stream_fifo_axis_tvalid : s_host_axis_tvalid;
  assign parser_axis_tlast  = stream_ddr_mode ? stream_fifo_axis_tlast  : s_host_axis_tlast;
  assign stream_fifo_axis_tready = stream_ddr_mode ? parser_axis_tready : 1'b0;
  assign s_host_axis_tready     = stream_ddr_mode ? 1'b0 : parser_axis_tready;
  assign stream_prefetch_ready  = !stream_ddr_mode || stream_ddr_done || stream_prefetch_active;
  assign parser_enable          = core_enable && sel_stream_mode && stream_prefetch_ready;

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

  assign debug_status = {
    7'd0,
    cfg_auto_tx_drop,
    auto_tx_drop_active,
    cfg_force_tx_ready,
    ddr_reader_start,
    m_tx_axis_tready,
    m_tx_axis_tvalid,
    src_axis_tready,
    src_axis_tvalid,
    pkt_ready,
    pkt_valid,
    ddr_axis_tready,
    ddr_axis_tvalid,
    ddr_meta_ready,
    ddr_meta_valid,
    source_error,
    source_done,
    source_busy,
    core_enable,
    pause,
    sel_ddr_mode,
    sel_stream_mode,
    active_reader_state
  };

  assign debug_axi = {
    13'd0,
    m_axi_arlen,
    m_axi_rresp,
    m_axi_rlast,
    m_axi_rready,
    m_axi_rvalid,
    m_axi_arready,
    m_axi_arvalid
  };

  always_comb begin
    if (cfg_watermark[31:6] == 26'd0) begin
      stream_fifo_watermark_beats = STREAM_FIFO_LEVEL_ONE;
    end else if (cfg_watermark[31:6] >= STREAM_FIFO_DEPTH) begin
      stream_fifo_watermark_beats = STREAM_FIFO_DEPTH_LEVEL;
    end else begin
      stream_fifo_watermark_beats = cfg_watermark[6 +: STREAM_FIFO_COUNT_W];
    end
  end

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
    .cfg_stream_ring_size(cfg_stream_ring_size),
    .cfg_stream_write_count(cfg_stream_write_count),
    .cfg_stream_eof(cfg_stream_eof),
    .cfg_force_link_up(cfg_force_link_up),
    .cfg_force_tx_ready(cfg_force_tx_ready),
    .cfg_auto_tx_drop(cfg_auto_tx_drop),
    .stat_running(replay_running),
    .stat_done(replay_done),
    .stat_late(|late_pkts),
    .stat_underrun(|underrun_pkts),
    .stat_link_up(link_up),
    .stat_effective_link_up(effective_link_up),
    .stat_fifo_level({{(32-STREAM_FIFO_COUNT_W){1'b0}}, stream_fifo_level}),
    .stat_tx_pkts(tx_pkts),
    .stat_tx_bytes(tx_bytes),
    .stat_late_pkts(late_pkts),
    .stat_underrun_pkts(underrun_pkts),
    .stat_drop_pkts(drop_pkts),
    .stat_drop_beats(drop_beats),
    .stat_stall_events(stall_events),
    .stat_debug_status(debug_status),
    .stat_debug_axi(debug_axi),
    .stat_debug_araddr(m_axi_araddr[63:0]),
    .stat_debug_rdata_low(m_axi_rdata[31:0]),
    .stat_debug_ticks(now_ticks),
    .stat_stream_read_count(stream_ddr_read_count),
    .stat_stream_level(stream_ddr_level),
    .stat_stream_status(stream_ddr_status)
  );

  ddr_trace_reader #(
    .AXI_ADDR_W_P(AXI_ADDR_W_P),
    .AXI_ID_W_P(AXI_ID_W_P)
  ) ddr_reader_i (
    .clk(clk),
    .rstn(rstn),
    .start(ddr_reader_start),
    .stop(stop_pulse),
    .clear(clear_pulse),
    .loop_mode(cfg_mode == MODE_LOOP),
    .cfg_desc_base(cfg_desc_base),
    .cfg_data_base(cfg_data_base),
    .cfg_pkt_count(cfg_pkt_count),
    .cfg_loop_count(cfg_loop_count),
    .cfg_loop_gap_ticks(cfg_loop_gap_ticks),
    .m_axi_arid(ddr_m_axi_arid),
    .m_axi_araddr(ddr_m_axi_araddr),
    .m_axi_arlen(ddr_m_axi_arlen),
    .m_axi_arsize(ddr_m_axi_arsize),
    .m_axi_arburst(ddr_m_axi_arburst),
    .m_axi_arvalid(ddr_m_axi_arvalid),
    .m_axi_arready(ddr_m_axi_arready),
    .m_axi_rid(m_axi_rid),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp),
    .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(ddr_m_axi_rvalid),
    .m_axi_rready(ddr_m_axi_rready),
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
    .error(ddr_error),
    .debug_state(ddr_reader_state)
  );

  ddr_stream_reader #(
    .AXI_ADDR_W_P(AXI_ADDR_W_P),
    .AXI_ID_W_P(AXI_ID_W_P),
    .MAX_BURST_BEATS(128)
  ) stream_reader_i (
    .clk(clk),
    .rstn(rstn),
    .start(stream_reader_start),
    .stop(stop_pulse),
    .clear(clear_pulse),
    .cfg_stream_base(cfg_desc_base),
    .cfg_stream_bytes(cfg_trace_bytes),
    .cfg_ring_size(cfg_stream_ring_size),
    .cfg_ring_write_count(cfg_stream_write_count),
    .cfg_ring_eof(cfg_stream_eof),
    .m_axi_arid(stream_m_axi_arid),
    .m_axi_araddr(stream_m_axi_araddr),
    .m_axi_arlen(stream_m_axi_arlen),
    .m_axi_arsize(stream_m_axi_arsize),
    .m_axi_arburst(stream_m_axi_arburst),
    .m_axi_arvalid(stream_m_axi_arvalid),
    .m_axi_arready(stream_m_axi_arready),
    .m_axi_rid(m_axi_rid),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp),
    .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(stream_m_axi_rvalid),
    .m_axi_rready(stream_m_axi_rready),
    .m_axis_tdata(stream_ddr_axis_tdata),
    .m_axis_tkeep(stream_ddr_axis_tkeep),
    .m_axis_tvalid(stream_ddr_axis_tvalid),
    .m_axis_tready(stream_ddr_axis_tready),
    .m_axis_tlast(stream_ddr_axis_tlast),
    .busy(stream_ddr_busy),
    .done(stream_ddr_done),
    .error(stream_ddr_error),
    .read_count(stream_ddr_read_count),
    .ring_level(stream_ddr_level),
    .stream_status(stream_ddr_status),
    .debug_state(stream_ddr_state)
  );

  axis_sync_fifo #(
    .DATA_W(AXIS_DATA_W),
    .KEEP_W(AXIS_KEEP_W),
    .DEPTH(STREAM_FIFO_DEPTH)
  ) stream_prefetch_fifo_i (
    .clk(clk),
    .rstn(rstn),
    .clear(core_clear || start_pulse),
    .s_axis_tdata(stream_ddr_axis_tdata),
    .s_axis_tkeep(stream_ddr_axis_tkeep),
    .s_axis_tvalid(stream_ddr_axis_tvalid),
    .s_axis_tready(stream_ddr_axis_tready),
    .s_axis_tlast(stream_ddr_axis_tlast),
    .m_axis_tdata(stream_fifo_axis_tdata),
    .m_axis_tkeep(stream_fifo_axis_tkeep),
    .m_axis_tvalid(stream_fifo_axis_tvalid),
    .m_axis_tready(stream_fifo_axis_tready),
    .m_axis_tlast(stream_fifo_axis_tlast),
    .level(stream_fifo_level)
  );

  host_stream_parser host_parser_i (
    .clk(clk),
    .rstn(rstn),
    .enable(parser_enable),
    .clear(core_clear),
    .s_axis_tdata(parser_axis_tdata),
    .s_axis_tkeep(parser_axis_tkeep),
    .s_axis_tvalid(parser_axis_tvalid),
    .s_axis_tready(parser_axis_tready),
    .s_axis_tlast(parser_axis_tlast),
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
    .start(start_pulse),
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
    .m_axis_tready(tx_ready_effective),
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
      drop_pkts      <= '0;
      drop_beats     <= '0;
      stall_events   <= '0;
      tx_stall_count <= '0;
      auto_tx_drop_active <= 1'b0;
      stream_prefetch_active <= 1'b0;
      sel_stream_mode <= 1'b0;
      sel_ddr_mode <= 1'b0;
      stream_ddr_mode <= 1'b0;
      preload_warmup_count <= '0;
      preload_warmup_done <= 1'b0;
    end else begin
      sel_stream_mode <= sel_stream_mode_comb;
      sel_ddr_mode <= sel_ddr_mode_comb;
      stream_ddr_mode <= stream_ddr_mode_comb;

      if (clear_pulse) begin
        late_pkts     <= '0;
        underrun_pkts <= '0;
        drop_pkts     <= '0;
        drop_beats    <= '0;
        stall_events  <= '0;
      end

      if (core_clear || start_pulse || !cfg_auto_tx_drop || !tx_backpressured) begin
        tx_stall_count <= '0;
      end else if (tx_stall_count < TX_STALL_WATCHDOG_LEVEL) begin
        tx_stall_count <= tx_stall_count + {{(TX_STALL_CNT_W-1){1'b0}}, 1'b1};
      end

      if (core_clear || start_pulse || !cfg_auto_tx_drop) begin
        auto_tx_drop_active <= 1'b0;
      end else if (auto_tx_drop_start) begin
        auto_tx_drop_active <= 1'b1;
      end else if (m_tx_axis_tready || !m_tx_axis_tvalid) begin
        auto_tx_drop_active <= 1'b0;
      end

      if (auto_tx_drop_start && !auto_tx_drop_active) begin
        stall_events <= stall_events + 64'd1;
      end
      if (auto_tx_drop_fire) begin
        drop_beats <= drop_beats + 64'd1;
        if (m_tx_axis_tlast) begin
          drop_pkts <= drop_pkts + 64'd1;
        end
      end

      if (core_clear || start_pulse || !stream_ddr_mode) begin
        stream_prefetch_active <= 1'b0;
      end else if (core_enable &&
                   (stream_fifo_level >= stream_fifo_watermark_beats ||
                    stream_ddr_done)) begin
        stream_prefetch_active <= 1'b1;
      end

      if (start_pulse) begin
        replay_running <= 1'b1;
      end else if (clear_pulse || stop_pulse || replay_done) begin
        replay_running <= 1'b0;
      end

      if (core_clear || start_pulse || !sel_ddr_mode_comb) begin
        preload_warmup_count <= '0;
        preload_warmup_done  <= !sel_ddr_mode_comb;
      end else if (replay_running && sel_ddr_mode && !preload_warmup_done &&
                   !pause && effective_link_up) begin
        if (preload_warmup_count >= PRELOAD_WARMUP_CYCLES_LEVEL) begin
          preload_warmup_done <= 1'b1;
        end else begin
          preload_warmup_count <= preload_warmup_count + {{(PRELOAD_WARMUP_CNT_W-1){1'b0}}, 1'b1};
        end
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
