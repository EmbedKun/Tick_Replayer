`timescale 1ns/1ps

import traffic_replay_pkg::*;

module ddr_trace_reader #(
  parameter int AXI_ADDR_W_P = AXI_ADDR_W,
  parameter int AXI_ID_W_P   = AXI_ID_W
) (
  input  logic                     clk,
  input  logic                     rstn,
  input  logic                     start,
  input  logic                     stop,
  input  logic                     clear,
  input  logic                     loop_mode,
  input  logic [63:0]              cfg_desc_base,
  input  logic [63:0]              cfg_data_base,
  input  logic [63:0]              cfg_pkt_count,
  input  logic [63:0]              cfg_loop_count,
  input  logic [63:0]              cfg_loop_gap_ticks,

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

  output logic                     m_meta_valid,
  input  logic                     m_meta_ready,
  output logic [63:0]              m_meta_gap_ticks,
  output logic [15:0]              m_meta_len,
  output logic [15:0]              m_meta_flags,

  output logic [AXIS_DATA_W-1:0]   m_axis_tdata,
  output logic [AXIS_KEEP_W-1:0]   m_axis_tkeep,
  output logic                     m_axis_tvalid,
  input  logic                     m_axis_tready,
  output logic                     m_axis_tlast,

  output logic                     busy,
  output logic                     done,
  output logic                     error,
  output logic [3:0]               debug_state
);
  localparam int DESC_FIFO_DEPTH        = 256;
  localparam int META_FIFO_DEPTH        = 256;
  localparam int PLAN_FIFO_DEPTH        = 512;
  localparam int PAYLOAD_CMD_DEPTH      = 32;
  localparam int AXI_CMD_DEPTH          = 32;
  localparam int PAYLOAD_FIFO_DEPTH     = 4096;
  localparam int MAX_PAYLOAD_RUN_PKTS   = 255;
  localparam int MAX_AXI_BURST_BEATS    = 256;
  localparam int DESC_SCAN_START_LEVEL  = 128;

  localparam int DESC_PTR_W        = $clog2(DESC_FIFO_DEPTH);
  localparam int META_PTR_W        = $clog2(META_FIFO_DEPTH);
  localparam int PLAN_PTR_W        = $clog2(PLAN_FIFO_DEPTH);
  localparam int PAYLOAD_CMD_PTR_W = $clog2(PAYLOAD_CMD_DEPTH);
  localparam int AXI_CMD_PTR_W     = $clog2(AXI_CMD_DEPTH);
  localparam int DESC_CNT_W        = $clog2(DESC_FIFO_DEPTH + 1);
  localparam int META_CNT_W        = $clog2(META_FIFO_DEPTH + 1);
  localparam int PLAN_CNT_W        = $clog2(PLAN_FIFO_DEPTH + 1);
  localparam int PAYLOAD_CMD_CNT_W = $clog2(PAYLOAD_CMD_DEPTH + 1);
  localparam int AXI_CMD_CNT_W     = $clog2(AXI_CMD_DEPTH + 1);
  localparam int PAYLOAD_CNT_W     = $clog2(PAYLOAD_FIFO_DEPTH + 1);
  localparam int RESERVE_CNT_W     = PAYLOAD_CNT_W + 1;

  localparam logic [DESC_CNT_W-1:0]        DESC_FIFO_DEPTH_LEVEL        = DESC_FIFO_DEPTH;
  localparam logic [DESC_CNT_W-1:0]        DESC_REFILL_LEVEL            = 128;
  localparam logic [DESC_CNT_W-1:0]        DESC_SERVICE_LEVEL           = 64;
  localparam logic [DESC_CNT_W-1:0]        DESC_SCAN_START_LEVEL_U      = DESC_SCAN_START_LEVEL;
  localparam logic [META_CNT_W-1:0]        META_FIFO_DEPTH_LEVEL        = META_FIFO_DEPTH;
  localparam logic [PLAN_CNT_W-1:0]        PLAN_FIFO_DEPTH_LEVEL        = PLAN_FIFO_DEPTH;
  localparam logic [PAYLOAD_CMD_CNT_W-1:0] PAYLOAD_CMD_DEPTH_LEVEL      = PAYLOAD_CMD_DEPTH;
  localparam logic [AXI_CMD_CNT_W-1:0]     AXI_CMD_DEPTH_LEVEL          = AXI_CMD_DEPTH;
  localparam logic [PAYLOAD_CNT_W-1:0]     PAYLOAD_FIFO_DEPTH_LEVEL     = PAYLOAD_FIFO_DEPTH;
  localparam logic [RESERVE_CNT_W-1:0]     PAYLOAD_DESC_SERVICE_LEVEL   = 1024;
  localparam logic [7:0]                   MAX_PAYLOAD_RUN_PKTS_U8      = 8'(MAX_PAYLOAD_RUN_PKTS);
  localparam logic [16:0]                  MAX_AXI_BURST_BEATS_U17      = 17'(MAX_AXI_BURST_BEATS);

  typedef enum logic [1:0] {
    CMD_NONE,
    CMD_DESC,
    CMD_PAYLOAD
  } cmd_kind_t;

  typedef enum logic [1:0] {
    SC_IDLE,
    SC_RUN
  } scan_state_t;

  function automatic logic [15:0] beats_from_len(input logic [15:0] byte_count);
    begin
      beats_from_len = (byte_count[5:0] == 6'd0) ? (byte_count >> 6) : ((byte_count >> 6) + 16'd1);
    end
  endfunction

  function automatic logic [8:0] cap_burst(input logic [63:0] remaining, input int unsigned free_slots);
    int unsigned n;
    begin
      n = free_slots;
      if (n > MAX_AXI_BURST_BEATS) begin
        n = MAX_AXI_BURST_BEATS;
      end
      if (remaining < n) begin
        n = remaining[8:0];
      end
      cap_burst = n[8:0];
    end
  endfunction

  function automatic logic [7:0] arlen_from_beats(input logic [8:0] beats);
    begin
      arlen_from_beats = (beats == 9'd256) ? 8'hff : (beats[7:0] - 8'd1);
    end
  endfunction

  logic running;
  logic desc_fetch_done;
  logic desc_loop_gap_next;
  logic infinite_loop;

  logic [63:0] desc_issue_index;
  logic [63:0] desc_issue_remaining;
  logic [63:0] desc_issue_loops_done;
  logic [8:0]  desc_burst_beats;
  logic [DESC_CNT_W-1:0] desc_free;
  logic [DESC_CNT_W:0] desc_reserved;
  logic [DESC_CNT_W:0] desc_total_occupied;
  logic desc_refill_ready;
  logic desc_plan_valid;
  logic [63:0] desc_plan_addr;
  logic [8:0]  desc_plan_beats;
  logic [63:0] desc_plan_index;
  logic        desc_plan_loop_gap;
  logic        desc_plan_done;
  logic        desc_plan_loop_again;
  logic        desc_plan_load;
  logic        desc_plan_pop;

  logic [DESC_PTR_W-1:0] desc_wr_ptr;
  logic [DESC_PTR_W-1:0] desc_rd_ptr;
  logic [DESC_PTR_W-1:0] desc_rd_ptr_next;
  logic [DESC_CNT_W-1:0] desc_count;
  logic [63:0] desc_gap_mem [DESC_FIFO_DEPTH];
  logic [31:0] desc_word_mem [DESC_FIFO_DEPTH];
  logic [15:0] desc_len_mem [DESC_FIFO_DEPTH];
  logic [15:0] desc_flags_mem [DESC_FIFO_DEPTH];
  logic        desc_head_valid;
  logic [63:0] desc_head_gap_q;
  logic [31:0] desc_head_word_q;
  logic [15:0] desc_head_len_q;
  logic [15:0] desc_head_flags_q;
  logic [15:0] desc_head_beats_q;

  logic [META_PTR_W-1:0] meta_wr_ptr;
  logic [META_PTR_W-1:0] meta_rd_ptr;
  logic [META_CNT_W-1:0] meta_count;
  logic [META_CNT_W:0]   meta_reserved;
  logic [META_CNT_W:0]   meta_total_occupied;
  logic [63:0] meta_gap_mem [META_FIFO_DEPTH];
  logic [15:0] meta_len_mem [META_FIFO_DEPTH];
  logic [15:0] meta_flags_mem [META_FIFO_DEPTH];

  logic [PLAN_PTR_W-1:0] plan_wr_ptr;
  logic [PLAN_PTR_W-1:0] plan_rd_ptr;
  logic [PLAN_CNT_W-1:0] plan_count;
  logic [63:0] plan_gap_mem [PLAN_FIFO_DEPTH];
  logic [15:0] plan_len_mem [PLAN_FIFO_DEPTH];
  logic [15:0] plan_flags_mem [PLAN_FIFO_DEPTH];
  logic [15:0] plan_beats_mem [PLAN_FIFO_DEPTH];

  logic [PAYLOAD_CMD_PTR_W-1:0] payload_cmd_wr_ptr;
  logic [PAYLOAD_CMD_PTR_W-1:0] payload_cmd_rd_ptr;
  logic [PAYLOAD_CMD_CNT_W-1:0] payload_cmd_count;
  logic [63:0] payload_cmd_addr_mem [PAYLOAD_CMD_DEPTH];
  logic [8:0]  payload_cmd_beats_mem [PAYLOAD_CMD_DEPTH];

  logic [AXI_CMD_PTR_W-1:0] axi_cmd_wr_ptr;
  logic [AXI_CMD_PTR_W-1:0] axi_cmd_rd_ptr;
  logic [AXI_CMD_CNT_W-1:0] axi_cmd_count;
  cmd_kind_t axi_cmd_kind_mem [AXI_CMD_DEPTH];
  logic [8:0] axi_cmd_beats_mem [AXI_CMD_DEPTH];
  logic [63:0] axi_cmd_desc_index_mem [AXI_CMD_DEPTH];
  logic        axi_cmd_desc_loop_gap_mem [AXI_CMD_DEPTH];

  scan_state_t scan_state;
  logic [7:0]  scan_count;
  logic [15:0] scan_beats;
  logic [31:0] scan_expected_word;
  logic [63:0] scan_run_addr;

  logic [15:0] desc_head_len;
  logic [15:0] desc_head_beats;
  logic [31:0] desc_head_word;
  logic [15:0] scan_total_beats;
  logic [8:0]  scan_total_count;
  logic [DESC_CNT_W-1:0] scan_total_count_desc;
  logic [META_CNT_W:0] scan_meta_need_next;
  logic [PLAN_CNT_W:0] plan_count_next;
  logic [RESERVE_CNT_W-1:0] payload_buffered_beats;
  logic [RESERVE_CNT_W:0] payload_need_next;
  logic scan_has_descriptor;
  logic scan_start_ok;
  logic scan_space_ok;
  logic scan_accept;
  logic scan_wait_for_more_desc;
  logic scan_forced_finish;
  logic scan_command_push;
  logic [8:0] scan_command_beats;
  logic [63:0] scan_command_addr;

  logic [AXIS_DATA_W-1:0] payload_fifo_s_tdata;
  logic [AXIS_KEEP_W-1:0] payload_fifo_s_tkeep;
  logic                   payload_fifo_s_tvalid;
  logic                   payload_fifo_s_tready;
  logic                   payload_fifo_s_tlast;
  logic [AXIS_DATA_W-1:0] payload_fifo_m_tdata;
  logic [AXIS_KEEP_W-1:0] payload_fifo_m_tkeep;
  logic                   payload_fifo_m_tvalid;
  logic                   payload_fifo_m_tready;
  logic                   payload_fifo_m_tlast;
  logic [PAYLOAD_CNT_W-1:0] payload_fifo_level;
  logic [RESERVE_CNT_W-1:0] payload_reserved;

  cmd_kind_t ar_sel_kind;
  logic [63:0] ar_sel_addr;
  logic [8:0]  ar_sel_beats;
  logic [63:0] ar_sel_desc_index;
  logic        ar_sel_desc_loop_gap;
  logic        ar_load;
  logic        ar_stage_valid;
  cmd_kind_t   ar_kind_q;
  logic [63:0] ar_addr_q;
  logic [8:0]  ar_beats_q;
  logic [63:0] ar_desc_index_q;
  logic        ar_desc_loop_gap_q;
  logic        ar_desc_done_q;
  logic        ar_desc_loop_again_q;
  logic        desc_issue_end;
  logic        desc_issue_loop_more;
  logic        ar_fire;
  logic        desc_issue_req;
  logic        payload_issue_req;
  logic        issue_desc_selected;

  cmd_kind_t rsp_kind;
  logic [8:0] rsp_beats_left_eff;
  logic       rsp_active;
  logic [8:0] rsp_beats_left;
  logic       rsp_valid;
  logic       rsp_last_beat;
  logic       rsp_cmd_pop;
  logic       desc_r_fire;
  logic       payload_r_fire;
  logic [63:0] desc_rsp_index;
  logic        desc_loop_gap_for_beat;

  logic cur_plan_valid;
  logic [63:0] cur_gap;
  logic [15:0] cur_len;
  logic [15:0] cur_flags;
  logic [15:0] cur_bytes_left;
  logic [15:0] cur_beats_left;
  logic [63:0] eff_gap;
  logic [15:0] eff_len;
  logic [15:0] eff_flags;
  logic [15:0] eff_bytes_left;
  logic [15:0] eff_beats_left;
  logic        payload_packet_complete;
  logic        plan_pop;
  logic        meta_push;
  logic        meta_pop;
  logic        desc_push;
  logic        desc_pop;
  logic        payload_cmd_push;
  logic        payload_cmd_pop;
  logic        axi_cmd_push;
  logic        replay_complete;

  assign infinite_loop = loop_mode && (cfg_loop_count == 64'd0);
  assign desc_total_occupied = {1'b0, desc_count} + desc_reserved;
  assign desc_free = (desc_total_occupied >= {1'b0, DESC_FIFO_DEPTH_LEVEL}) ?
                     '0 : DESC_CNT_W'({1'b0, DESC_FIFO_DEPTH_LEVEL} - desc_total_occupied);
  assign meta_total_occupied = {1'b0, meta_count} + meta_reserved;
  assign payload_buffered_beats = {1'b0, payload_fifo_level} + payload_reserved;

  assign desc_rd_ptr_next = desc_rd_ptr + {{(DESC_PTR_W-1){1'b0}}, 1'b1};
  assign desc_head_len   = desc_head_len_q;
  assign desc_head_beats = desc_head_beats_q;
  assign desc_head_word  = desc_head_word_q;
  assign scan_total_beats = scan_beats + desc_head_beats;
  assign scan_total_count = {1'b0, scan_count} + 9'd1;
  assign scan_total_count_desc = DESC_CNT_W'(scan_total_count);
  assign scan_meta_need_next = meta_total_occupied + {{META_CNT_W{1'b0}}, 1'b1};
  assign plan_count_next = {1'b0, plan_count} + {{PLAN_CNT_W{1'b0}}, 1'b1};
  assign payload_need_next = {1'b0, payload_buffered_beats} + {1'b0, desc_head_beats};

  assign scan_has_descriptor =
    running &&
    (scan_state == SC_RUN) &&
    desc_head_valid &&
    (scan_count < MAX_PAYLOAD_RUN_PKTS_U8);

  assign scan_start_ok =
    running &&
    (desc_count != '0) &&
    ((desc_count >= DESC_SCAN_START_LEVEL_U) || desc_fetch_done);

  assign scan_space_ok =
    (plan_count_next <= {1'b0, PLAN_FIFO_DEPTH_LEVEL}) &&
    (scan_meta_need_next <= {1'b0, META_FIFO_DEPTH_LEVEL}) &&
    (payload_need_next <= {1'b0, PAYLOAD_FIFO_DEPTH_LEVEL});

  assign scan_accept =
    scan_has_descriptor &&
    scan_space_ok &&
    (payload_cmd_count != PAYLOAD_CMD_DEPTH_LEVEL) &&
    (desc_head_beats != 16'd0) &&
    (desc_head_word == scan_expected_word) &&
    ({1'b0, scan_total_beats} <= MAX_AXI_BURST_BEATS_U17);

  assign scan_forced_finish =
    scan_accept &&
    ((scan_total_count[7:0] == MAX_PAYLOAD_RUN_PKTS_U8) ||
     (scan_total_count_desc == desc_count) ||
     ({1'b0, scan_total_beats} == MAX_AXI_BURST_BEATS_U17));

  assign scan_wait_for_more_desc =
    running &&
    (scan_state == SC_RUN) &&
    (scan_count != 8'd0) &&
    !desc_head_valid &&
    !desc_fetch_done;

  assign scan_command_push =
    (payload_cmd_count != PAYLOAD_CMD_DEPTH_LEVEL) &&
    (scan_state == SC_RUN) &&
    ((scan_forced_finish && (scan_total_count != 9'd0)) ||
     (!scan_accept && (scan_count != 8'd0) && !scan_wait_for_more_desc));

  assign scan_command_beats = scan_accept ? scan_total_beats[8:0] : {1'b0, scan_beats};
  assign scan_command_addr =
    (scan_accept && (scan_count == 8'd0)) ?
      (cfg_data_base + ({32'd0, desc_head_word} << DESC_WORD_SHIFT)) :
      scan_run_addr;

  assign desc_refill_ready =
    (desc_free >= DESC_REFILL_LEVEL) ||
    (desc_issue_remaining <= {55'd0, desc_free});
  assign desc_burst_beats = cap_burst(desc_issue_remaining, desc_free);

  assign payload_issue_req =
    running &&
    (payload_cmd_count != '0) &&
    (axi_cmd_count != AXI_CMD_DEPTH_LEVEL);

  assign desc_issue_req =
    desc_plan_valid &&
    (axi_cmd_count != AXI_CMD_DEPTH_LEVEL);

  assign desc_plan_load =
    !desc_plan_valid &&
    !(ar_stage_valid && (ar_kind_q == CMD_DESC)) &&
    running &&
    !desc_fetch_done &&
    desc_refill_ready &&
    (desc_burst_beats != 9'd0);

  assign issue_desc_selected =
    desc_issue_req &&
    (!payload_issue_req ||
     ((desc_count <= DESC_SERVICE_LEVEL) && (payload_buffered_beats >= PAYLOAD_DESC_SERVICE_LEVEL)) ||
     (payload_cmd_count == '0));

  assign desc_issue_end = desc_issue_remaining <= {55'd0, desc_burst_beats};
  assign desc_issue_loop_more =
    loop_mode &&
    (infinite_loop || (desc_issue_loops_done + 64'd1 < cfg_loop_count));

  always_comb begin
    ar_sel_kind          = CMD_NONE;
    ar_sel_addr          = '0;
    ar_sel_beats         = '0;
    ar_sel_desc_index    = '0;
    ar_sel_desc_loop_gap = 1'b0;

    if (issue_desc_selected) begin
      ar_sel_kind          = CMD_DESC;
      ar_sel_addr          = desc_plan_addr;
      ar_sel_beats         = desc_plan_beats;
      ar_sel_desc_index    = desc_plan_index;
      ar_sel_desc_loop_gap = desc_plan_loop_gap;
    end else if (payload_issue_req) begin
      ar_sel_kind  = CMD_PAYLOAD;
      ar_sel_addr  = payload_cmd_addr_mem[payload_cmd_rd_ptr];
      ar_sel_beats = payload_cmd_beats_mem[payload_cmd_rd_ptr];
    end else if (desc_issue_req) begin
      ar_sel_kind          = CMD_DESC;
      ar_sel_addr          = desc_plan_addr;
      ar_sel_beats         = desc_plan_beats;
      ar_sel_desc_index    = desc_plan_index;
      ar_sel_desc_loop_gap = desc_plan_loop_gap;
    end
  end

  assign ar_load       = !ar_stage_valid && (ar_sel_kind != CMD_NONE) && (ar_sel_beats != 9'd0);
  assign m_axi_arid    = '0;
  assign m_axi_araddr  = ar_addr_q[AXI_ADDR_W_P-1:0];
  assign m_axi_arlen   = arlen_from_beats(ar_beats_q);
  assign m_axi_arsize  = 3'd6;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arvalid = ar_stage_valid;
  assign ar_fire       = m_axi_arvalid && m_axi_arready;

  assign rsp_valid          = (axi_cmd_count != '0);
  assign rsp_kind           = rsp_valid ? axi_cmd_kind_mem[axi_cmd_rd_ptr] : CMD_NONE;
  assign rsp_beats_left_eff = rsp_active ? rsp_beats_left : axi_cmd_beats_mem[axi_cmd_rd_ptr];
  assign rsp_last_beat      = (rsp_beats_left_eff == 9'd1);
  assign desc_loop_gap_for_beat = axi_cmd_desc_loop_gap_mem[axi_cmd_rd_ptr] && !rsp_active;
  assign desc_rsp_index     = axi_cmd_desc_index_mem[axi_cmd_rd_ptr] +
                              {55'd0, (axi_cmd_beats_mem[axi_cmd_rd_ptr] - rsp_beats_left_eff)};

  assign eff_gap        = cur_plan_valid ? cur_gap        : plan_gap_mem[plan_rd_ptr];
  assign eff_len        = cur_plan_valid ? cur_len        : plan_len_mem[plan_rd_ptr];
  assign eff_flags      = cur_plan_valid ? cur_flags      : plan_flags_mem[plan_rd_ptr];
  assign eff_bytes_left = cur_plan_valid ? cur_bytes_left : plan_len_mem[plan_rd_ptr];
  assign eff_beats_left = cur_plan_valid ? cur_beats_left : plan_beats_mem[plan_rd_ptr];

  assign m_axi_rready =
    rsp_valid &&
    ((rsp_kind == CMD_DESC) ?
      (desc_count != DESC_FIFO_DEPTH_LEVEL) :
      ((rsp_kind == CMD_PAYLOAD) &&
       payload_fifo_s_tready &&
       (cur_plan_valid || (plan_count != '0))));

  assign desc_r_fire    = m_axi_rvalid && m_axi_rready && (rsp_kind == CMD_DESC);
  assign payload_r_fire = m_axi_rvalid && m_axi_rready && (rsp_kind == CMD_PAYLOAD);
  assign rsp_cmd_pop    = m_axi_rvalid && m_axi_rready && rsp_last_beat;

  assign payload_fifo_s_tdata  = m_axi_rdata;
  assign payload_fifo_s_tkeep  = (eff_bytes_left <= AXIS_KEEP_BYTES) ?
                                 keep_from_len(eff_bytes_left) : {AXIS_KEEP_W{1'b1}};
  assign payload_fifo_s_tvalid = payload_r_fire;
  assign payload_fifo_s_tlast  = (eff_beats_left == 16'd1);
  assign payload_packet_complete = payload_r_fire && (eff_beats_left == 16'd1);
  assign plan_pop = payload_r_fire && !cur_plan_valid;

  axis_sync_fifo #(
    .DATA_W(AXIS_DATA_W),
    .KEEP_W(AXIS_KEEP_W),
    .DEPTH(PAYLOAD_FIFO_DEPTH)
  ) payload_fifo_i (
    .clk(clk),
    .rstn(rstn),
    .clear(clear || stop || start),
    .s_axis_tdata(payload_fifo_s_tdata),
    .s_axis_tkeep(payload_fifo_s_tkeep),
    .s_axis_tvalid(payload_fifo_s_tvalid),
    .s_axis_tready(payload_fifo_s_tready),
    .s_axis_tlast(payload_fifo_s_tlast),
    .m_axis_tdata(payload_fifo_m_tdata),
    .m_axis_tkeep(payload_fifo_m_tkeep),
    .m_axis_tvalid(payload_fifo_m_tvalid),
    .m_axis_tready(payload_fifo_m_tready),
    .m_axis_tlast(payload_fifo_m_tlast),
    .level(payload_fifo_level)
  );

  assign meta_push = payload_packet_complete;
  assign meta_pop  = m_meta_valid && m_meta_ready;
  assign desc_push = desc_r_fire;
  assign desc_pop  = scan_accept;
  assign payload_cmd_push = scan_command_push;
  assign payload_cmd_pop  = ar_fire && (ar_kind_q == CMD_PAYLOAD);
  assign desc_plan_pop    = ar_load && (ar_sel_kind == CMD_DESC);
  assign axi_cmd_push     = ar_fire;

  assign m_meta_valid     = running && (meta_count != '0);
  assign m_meta_gap_ticks = meta_gap_mem[meta_rd_ptr];
  assign m_meta_len       = meta_len_mem[meta_rd_ptr];
  assign m_meta_flags     = meta_flags_mem[meta_rd_ptr];

  assign payload_fifo_m_tready = running && m_axis_tready;
  assign m_axis_tdata  = payload_fifo_m_tdata;
  assign m_axis_tkeep  = payload_fifo_m_tkeep;
  assign m_axis_tvalid = running && payload_fifo_m_tvalid;
  assign m_axis_tlast  = payload_fifo_m_tlast;

  assign replay_complete =
    running &&
    desc_fetch_done &&
    (desc_count == '0) &&
    (desc_reserved == '0) &&
    (scan_state == SC_IDLE) &&
    (payload_cmd_count == '0) &&
    (axi_cmd_count == '0) &&
    !rsp_active &&
    (plan_count == '0) &&
    !cur_plan_valid &&
    (meta_count == '0) &&
    (meta_reserved == '0) &&
    (payload_fifo_level == '0) &&
    (payload_reserved == '0);

  assign busy = running && !done;
  assign debug_state = {scan_state, rsp_kind};

  always_ff @(posedge clk) begin
    if (!rstn) begin
      running               <= 1'b0;
      done                  <= 1'b0;
      error                 <= 1'b0;
      desc_fetch_done       <= 1'b0;
      desc_loop_gap_next    <= 1'b0;
      desc_issue_index      <= '0;
      desc_issue_remaining  <= '0;
      desc_issue_loops_done <= '0;
      desc_plan_valid       <= 1'b0;
      desc_plan_addr        <= '0;
      desc_plan_beats       <= '0;
      desc_plan_index       <= '0;
      desc_plan_loop_gap    <= 1'b0;
      desc_plan_done        <= 1'b0;
      desc_plan_loop_again  <= 1'b0;
      desc_wr_ptr           <= '0;
      desc_rd_ptr           <= '0;
      desc_count            <= '0;
      desc_head_valid       <= 1'b0;
      desc_head_gap_q       <= '0;
      desc_head_word_q      <= '0;
      desc_head_len_q       <= '0;
      desc_head_flags_q     <= '0;
      desc_head_beats_q     <= '0;
      desc_reserved         <= '0;
      meta_wr_ptr           <= '0;
      meta_rd_ptr           <= '0;
      meta_count            <= '0;
      meta_reserved         <= '0;
      plan_wr_ptr           <= '0;
      plan_rd_ptr           <= '0;
      plan_count            <= '0;
      payload_cmd_wr_ptr    <= '0;
      payload_cmd_rd_ptr    <= '0;
      payload_cmd_count     <= '0;
      axi_cmd_wr_ptr        <= '0;
      axi_cmd_rd_ptr        <= '0;
      axi_cmd_count         <= '0;
      ar_stage_valid        <= 1'b0;
      ar_kind_q             <= CMD_NONE;
      ar_addr_q             <= '0;
      ar_beats_q            <= '0;
      ar_desc_index_q       <= '0;
      ar_desc_loop_gap_q    <= 1'b0;
      ar_desc_done_q        <= 1'b0;
      ar_desc_loop_again_q  <= 1'b0;
      rsp_active            <= 1'b0;
      rsp_beats_left        <= '0;
      scan_state            <= SC_IDLE;
      scan_count            <= '0;
      scan_beats            <= '0;
      scan_expected_word    <= '0;
      scan_run_addr         <= '0;
      cur_plan_valid        <= 1'b0;
      cur_gap               <= '0;
      cur_len               <= '0;
      cur_flags             <= '0;
      cur_bytes_left        <= '0;
      cur_beats_left        <= '0;
      payload_reserved      <= '0;
    end else begin
      if (clear || stop) begin
        running               <= 1'b0;
        done                  <= 1'b0;
        desc_fetch_done       <= 1'b0;
        desc_loop_gap_next    <= 1'b0;
        desc_issue_index      <= '0;
        desc_issue_remaining  <= '0;
        desc_issue_loops_done <= '0;
        desc_plan_valid       <= 1'b0;
        desc_wr_ptr           <= '0;
        desc_rd_ptr           <= '0;
        desc_count            <= '0;
        desc_head_valid       <= 1'b0;
        desc_head_gap_q       <= '0;
        desc_head_word_q      <= '0;
        desc_head_len_q       <= '0;
        desc_head_flags_q     <= '0;
        desc_head_beats_q     <= '0;
        desc_reserved         <= '0;
        meta_wr_ptr           <= '0;
        meta_rd_ptr           <= '0;
        meta_count            <= '0;
        meta_reserved         <= '0;
        plan_wr_ptr           <= '0;
        plan_rd_ptr           <= '0;
        plan_count            <= '0;
        payload_cmd_wr_ptr    <= '0;
        payload_cmd_rd_ptr    <= '0;
        payload_cmd_count     <= '0;
        axi_cmd_wr_ptr        <= '0;
        axi_cmd_rd_ptr        <= '0;
        axi_cmd_count         <= '0;
        ar_stage_valid        <= 1'b0;
        ar_kind_q             <= CMD_NONE;
        ar_addr_q             <= '0;
        ar_beats_q            <= '0;
        ar_desc_index_q       <= '0;
        ar_desc_loop_gap_q    <= 1'b0;
        ar_desc_done_q        <= 1'b0;
        ar_desc_loop_again_q  <= 1'b0;
        rsp_active            <= 1'b0;
        rsp_beats_left        <= '0;
        scan_state            <= SC_IDLE;
        scan_count            <= '0;
        scan_beats            <= '0;
        scan_expected_word    <= '0;
        scan_run_addr         <= '0;
        cur_plan_valid        <= 1'b0;
        cur_bytes_left        <= '0;
        cur_beats_left        <= '0;
        payload_reserved      <= '0;
      end else begin
        if (start && (cfg_pkt_count != 64'd0)) begin
          running               <= 1'b1;
          done                  <= 1'b0;
          error                 <= 1'b0;
          desc_fetch_done       <= 1'b0;
          desc_loop_gap_next    <= 1'b0;
          desc_issue_index      <= '0;
          desc_issue_remaining  <= cfg_pkt_count;
          desc_issue_loops_done <= '0;
          desc_plan_valid       <= 1'b0;
          desc_wr_ptr           <= '0;
          desc_rd_ptr           <= '0;
          desc_count            <= '0;
          desc_head_valid       <= 1'b0;
          desc_head_gap_q       <= '0;
          desc_head_word_q      <= '0;
          desc_head_len_q       <= '0;
          desc_head_flags_q     <= '0;
          desc_head_beats_q     <= '0;
          desc_reserved         <= '0;
          meta_wr_ptr           <= '0;
          meta_rd_ptr           <= '0;
          meta_count            <= '0;
          meta_reserved         <= '0;
          plan_wr_ptr           <= '0;
          plan_rd_ptr           <= '0;
          plan_count            <= '0;
          payload_cmd_wr_ptr    <= '0;
          payload_cmd_rd_ptr    <= '0;
          payload_cmd_count     <= '0;
          axi_cmd_wr_ptr        <= '0;
          axi_cmd_rd_ptr        <= '0;
          axi_cmd_count         <= '0;
          ar_stage_valid        <= 1'b0;
          ar_kind_q             <= CMD_NONE;
          ar_addr_q             <= '0;
          ar_beats_q            <= '0;
          ar_desc_index_q       <= '0;
          ar_desc_loop_gap_q    <= 1'b0;
          ar_desc_done_q        <= 1'b0;
          ar_desc_loop_again_q  <= 1'b0;
          rsp_active            <= 1'b0;
          rsp_beats_left        <= '0;
          scan_state            <= SC_IDLE;
          scan_count            <= '0;
          scan_beats            <= '0;
          scan_expected_word    <= '0;
          scan_run_addr         <= '0;
          cur_plan_valid        <= 1'b0;
          cur_bytes_left        <= '0;
          cur_beats_left        <= '0;
          payload_reserved      <= '0;
        end

        if (ar_fire) begin
          ar_stage_valid <= 1'b0;
        end

        if (desc_plan_pop) begin
          desc_plan_valid <= 1'b0;
        end

        if (desc_plan_load) begin
          desc_plan_valid      <= 1'b1;
          desc_plan_addr       <= cfg_desc_base + (desc_issue_index << DESC_WORD_SHIFT);
          desc_plan_beats      <= desc_burst_beats;
          desc_plan_index      <= desc_issue_index;
          desc_plan_loop_gap   <= desc_loop_gap_next;
          desc_plan_done       <= desc_issue_end && !desc_issue_loop_more;
          desc_plan_loop_again <= desc_issue_end && desc_issue_loop_more;
        end

        if (ar_load) begin
          ar_stage_valid       <= 1'b1;
          ar_kind_q            <= ar_sel_kind;
          ar_addr_q            <= ar_sel_addr;
          ar_beats_q           <= ar_sel_beats;
          ar_desc_index_q      <= ar_sel_desc_index;
          ar_desc_loop_gap_q   <= ar_sel_desc_loop_gap;
          ar_desc_done_q       <= desc_plan_done;
          ar_desc_loop_again_q <= desc_plan_loop_again;
        end

        if (ar_fire) begin
          axi_cmd_kind_mem[axi_cmd_wr_ptr]          <= ar_kind_q;
          axi_cmd_beats_mem[axi_cmd_wr_ptr]         <= ar_beats_q;
          axi_cmd_desc_index_mem[axi_cmd_wr_ptr]    <= ar_desc_index_q;
          axi_cmd_desc_loop_gap_mem[axi_cmd_wr_ptr] <= ar_desc_loop_gap_q;
          axi_cmd_wr_ptr <= axi_cmd_wr_ptr + {{(AXI_CMD_PTR_W-1){1'b0}}, 1'b1};

          if (ar_kind_q == CMD_DESC) begin
            desc_loop_gap_next <= 1'b0;
            if (ar_desc_loop_again_q) begin
              desc_issue_index      <= '0;
              desc_issue_remaining  <= cfg_pkt_count;
              desc_issue_loops_done <= desc_issue_loops_done + 64'd1;
              desc_loop_gap_next    <= 1'b1;
            end else if (ar_desc_done_q) begin
              desc_issue_index     <= cfg_pkt_count;
              desc_issue_remaining <= '0;
              desc_fetch_done      <= 1'b1;
            end else begin
              desc_issue_index     <= desc_issue_index + {55'd0, ar_beats_q};
              desc_issue_remaining <= desc_issue_remaining - {55'd0, ar_beats_q};
            end
          end
        end

        if (desc_push) begin
          desc_gap_mem[desc_wr_ptr]   <= desc_loop_gap_for_beat ? cfg_loop_gap_ticks : m_axi_rdata[63:0];
          desc_word_mem[desc_wr_ptr]  <= m_axi_rdata[95:64];
          desc_len_mem[desc_wr_ptr]   <= m_axi_rdata[111:96];
          desc_flags_mem[desc_wr_ptr] <= m_axi_rdata[127:112];
          desc_wr_ptr                 <= desc_wr_ptr + {{(DESC_PTR_W-1){1'b0}}, 1'b1};
        end

        if ((scan_state == SC_IDLE) && scan_start_ok) begin
          scan_state         <= SC_RUN;
          scan_count         <= '0;
          scan_beats         <= '0;
          scan_expected_word <= desc_word_mem[desc_rd_ptr];
          scan_run_addr      <= cfg_data_base + ({32'd0, desc_word_mem[desc_rd_ptr]} << DESC_WORD_SHIFT);
          desc_head_valid    <= 1'b1;
          desc_head_gap_q    <= desc_gap_mem[desc_rd_ptr];
          desc_head_word_q   <= desc_word_mem[desc_rd_ptr];
          desc_head_len_q    <= desc_len_mem[desc_rd_ptr];
          desc_head_flags_q  <= desc_flags_mem[desc_rd_ptr];
          desc_head_beats_q  <= beats_from_len(desc_len_mem[desc_rd_ptr]);
        end else if ((scan_state == SC_RUN) && !desc_head_valid && (desc_count != '0)) begin
          desc_head_valid    <= 1'b1;
          desc_head_gap_q    <= desc_gap_mem[desc_rd_ptr];
          desc_head_word_q   <= desc_word_mem[desc_rd_ptr];
          desc_head_len_q    <= desc_len_mem[desc_rd_ptr];
          desc_head_flags_q  <= desc_flags_mem[desc_rd_ptr];
          desc_head_beats_q  <= beats_from_len(desc_len_mem[desc_rd_ptr]);
        end

        if (scan_accept) begin
          plan_gap_mem[plan_wr_ptr]   <= desc_head_gap_q;
          plan_len_mem[plan_wr_ptr]   <= desc_head_len_q;
          plan_flags_mem[plan_wr_ptr] <= desc_head_flags_q;
          plan_beats_mem[plan_wr_ptr] <= desc_head_beats;
          plan_wr_ptr                 <= plan_wr_ptr + {{(PLAN_PTR_W-1){1'b0}}, 1'b1};
          desc_rd_ptr                 <= desc_rd_ptr_next;
          scan_count                  <= scan_total_count[7:0];
          scan_beats                  <= scan_total_beats;
          scan_expected_word          <= scan_expected_word + {16'd0, desc_head_beats};

          if (desc_count > DESC_CNT_W'(1)) begin
            desc_head_valid  <= 1'b1;
            desc_head_gap_q  <= desc_gap_mem[desc_rd_ptr_next];
            desc_head_word_q <= desc_word_mem[desc_rd_ptr_next];
            desc_head_len_q  <= desc_len_mem[desc_rd_ptr_next];
            desc_head_flags_q <= desc_flags_mem[desc_rd_ptr_next];
            desc_head_beats_q <= beats_from_len(desc_len_mem[desc_rd_ptr_next]);
          end else begin
            desc_head_valid <= 1'b0;
          end
        end

        if (payload_cmd_push) begin
          payload_cmd_addr_mem[payload_cmd_wr_ptr]  <= scan_command_addr;
          payload_cmd_beats_mem[payload_cmd_wr_ptr] <= scan_command_beats;
          payload_cmd_wr_ptr <= payload_cmd_wr_ptr + {{(PAYLOAD_CMD_PTR_W-1){1'b0}}, 1'b1};
          scan_state         <= SC_IDLE;
          scan_count         <= '0;
          scan_beats         <= '0;
          desc_head_valid    <= 1'b0;
        end

        if (payload_cmd_pop) begin
          payload_cmd_rd_ptr <= payload_cmd_rd_ptr + {{(PAYLOAD_CMD_PTR_W-1){1'b0}}, 1'b1};
        end

        if (m_axi_rvalid && m_axi_rready) begin
          error <= error | (m_axi_rresp != 2'b00) | (m_axi_rlast != rsp_last_beat);
          if (rsp_last_beat) begin
            axi_cmd_rd_ptr <= axi_cmd_rd_ptr + {{(AXI_CMD_PTR_W-1){1'b0}}, 1'b1};
            rsp_active     <= 1'b0;
            rsp_beats_left <= '0;
          end else begin
            rsp_active     <= 1'b1;
            rsp_beats_left <= rsp_beats_left_eff - 9'd1;
          end
        end

        if (payload_r_fire) begin
          if (!cur_plan_valid) begin
            plan_rd_ptr <= plan_rd_ptr + {{(PLAN_PTR_W-1){1'b0}}, 1'b1};
            cur_gap     <= plan_gap_mem[plan_rd_ptr];
            cur_len     <= plan_len_mem[plan_rd_ptr];
            cur_flags   <= plan_flags_mem[plan_rd_ptr];
            if (plan_beats_mem[plan_rd_ptr] > 16'd1) begin
              cur_plan_valid <= 1'b1;
              cur_bytes_left <= (plan_len_mem[plan_rd_ptr] > AXIS_KEEP_BYTES) ?
                                (plan_len_mem[plan_rd_ptr] - AXIS_KEEP_BYTES) :
                                16'd0;
              cur_beats_left <= plan_beats_mem[plan_rd_ptr] - 16'd1;
            end else begin
              cur_plan_valid <= 1'b0;
              cur_bytes_left <= '0;
              cur_beats_left <= '0;
            end
          end else if (cur_beats_left > 16'd1) begin
            cur_bytes_left <= cur_bytes_left - AXIS_KEEP_BYTES;
            cur_beats_left <= cur_beats_left - 16'd1;
          end else begin
            cur_plan_valid <= 1'b0;
            cur_bytes_left <= '0;
            cur_beats_left <= '0;
          end
        end

        if (meta_push) begin
          meta_gap_mem[meta_wr_ptr]   <= eff_gap;
          meta_len_mem[meta_wr_ptr]   <= eff_len;
          meta_flags_mem[meta_wr_ptr] <= eff_flags;
          meta_wr_ptr                 <= meta_wr_ptr + {{(META_PTR_W-1){1'b0}}, 1'b1};
        end

        if (meta_pop) begin
          meta_rd_ptr   <= meta_rd_ptr + {{(META_PTR_W-1){1'b0}}, 1'b1};
        end

        unique case ({desc_push, desc_pop})
          2'b10: desc_count <= desc_count + {{(DESC_CNT_W-1){1'b0}}, 1'b1};
          2'b01: desc_count <= desc_count - {{(DESC_CNT_W-1){1'b0}}, 1'b1};
          default: begin
          end
        endcase

        unique case ({meta_push, meta_pop})
          2'b10: meta_count <= meta_count + {{(META_CNT_W-1){1'b0}}, 1'b1};
          2'b01: meta_count <= meta_count - {{(META_CNT_W-1){1'b0}}, 1'b1};
          default: begin
          end
        endcase

        unique case ({scan_accept, plan_pop})
          2'b10: plan_count <= plan_count + {{(PLAN_CNT_W-1){1'b0}}, 1'b1};
          2'b01: plan_count <= plan_count - {{(PLAN_CNT_W-1){1'b0}}, 1'b1};
          default: begin
          end
        endcase

        unique case ({payload_cmd_push, payload_cmd_pop})
          2'b10: payload_cmd_count <= payload_cmd_count + {{(PAYLOAD_CMD_CNT_W-1){1'b0}}, 1'b1};
          2'b01: payload_cmd_count <= payload_cmd_count - {{(PAYLOAD_CMD_CNT_W-1){1'b0}}, 1'b1};
          default: begin
          end
        endcase

        unique case ({axi_cmd_push, rsp_cmd_pop})
          2'b10: axi_cmd_count <= axi_cmd_count + {{(AXI_CMD_CNT_W-1){1'b0}}, 1'b1};
          2'b01: axi_cmd_count <= axi_cmd_count - {{(AXI_CMD_CNT_W-1){1'b0}}, 1'b1};
          default: begin
          end
        endcase

        unique case ({ar_fire && (ar_kind_q == CMD_DESC), desc_push})
          2'b10: desc_reserved <= desc_reserved + {1'b0, ar_beats_q};
          2'b01: desc_reserved <= desc_reserved - {{DESC_CNT_W{1'b0}}, 1'b1};
          2'b11: desc_reserved <= desc_reserved + {1'b0, ar_beats_q} - {{DESC_CNT_W{1'b0}}, 1'b1};
          default: begin
          end
        endcase

        unique case ({scan_accept, payload_r_fire})
          2'b10: payload_reserved <= payload_reserved + RESERVE_CNT_W'(desc_head_beats);
          2'b01: payload_reserved <= payload_reserved - RESERVE_CNT_W'(1);
          2'b11: payload_reserved <= payload_reserved + RESERVE_CNT_W'(desc_head_beats) - RESERVE_CNT_W'(1);
          default: begin
          end
        endcase

        unique case ({scan_accept, meta_push})
          2'b10: meta_reserved <= meta_reserved + {{META_CNT_W{1'b0}}, 1'b1};
          2'b01: meta_reserved <= meta_reserved - {{META_CNT_W{1'b0}}, 1'b1};
          default: begin
          end
        endcase

        if (replay_complete) begin
          running <= 1'b0;
          done    <= 1'b1;
        end
      end
    end
  end
endmodule
