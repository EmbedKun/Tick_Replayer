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
  localparam int DESC_FIFO_DEPTH    = 128;
  localparam int META_FIFO_DEPTH    = 128;
  localparam int PAYLOAD_FIFO_DEPTH = 8192;
  // The run detector intentionally stays small while the descriptor FIFO is
  // still implemented as a multi-read local queue.  The deeper 8192-beat
  // payload FIFO absorbs DDR latency; keeping this scan window modest makes
  // the 300 MHz replay clock practical on U200.
  localparam int MAX_PAYLOAD_RUN_PKTS = 4;
  localparam logic [7:0] MAX_PAYLOAD_RUN_PKTS_U8 = 8'(MAX_PAYLOAD_RUN_PKTS);

  localparam int DESC_PTR_W = $clog2(DESC_FIFO_DEPTH);
  localparam int META_PTR_W = $clog2(META_FIFO_DEPTH);
  localparam int DESC_CNT_W = $clog2(DESC_FIFO_DEPTH + 1);
  localparam int META_CNT_W = $clog2(META_FIFO_DEPTH + 1);
  localparam int PAYLOAD_CNT_W = $clog2(PAYLOAD_FIFO_DEPTH + 1);

  localparam logic [DESC_CNT_W-1:0] DESC_FIFO_DEPTH_LEVEL = DESC_FIFO_DEPTH;
  localparam logic [META_CNT_W-1:0] META_FIFO_DEPTH_LEVEL = META_FIFO_DEPTH;
  localparam logic [DESC_CNT_W-1:0] DESC_REFILL_LEVEL     = 32;
  localparam logic [PAYLOAD_CNT_W-1:0] PAYLOAD_FIFO_DEPTH_LEVEL = PAYLOAD_FIFO_DEPTH;

  typedef enum logic [1:0] {
    RD_NONE,
    RD_DESC,
    RD_PAYLOAD
  } rd_owner_t;

  typedef enum logic [1:0] {
    PL_IDLE,
    PL_SCAN,
    PL_AR,
    PL_R
  } payload_state_t;

  typedef enum logic [1:0] {
    AR_NONE,
    AR_DESC,
    AR_PAYLOAD
  } ar_kind_t;

  function automatic logic [15:0] beats_from_len(input logic [15:0] byte_count);
    begin
      beats_from_len = (byte_count[5:0] == 6'd0) ? (byte_count >> 6) : ((byte_count >> 6) + 16'd1);
    end
  endfunction

  function automatic logic [8:0] cap_burst(input logic [63:0] remaining, input int unsigned free_slots);
    int unsigned n;
    begin
      n = free_slots;
      if (n > 256) begin
        n = 256;
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

  rd_owner_t rd_owner;
  ar_kind_t  ar_kind;
  payload_state_t payload_state;

  logic desc_fetch_done;
  logic desc_loop_gap_next;
  logic infinite_loop;
  logic [63:0] desc_fetch_index;
  logic [63:0] desc_fetch_loops_done;
  logic [63:0] desc_rsp_index;
  logic        desc_rsp_loop_gap;
  logic [8:0]  desc_burst_beats;
  logic [8:0]  desc_rsp_beats_left;

  logic [DESC_PTR_W-1:0] desc_wr_ptr;
  logic [DESC_PTR_W-1:0] desc_rd_ptr;
  logic [DESC_CNT_W-1:0] desc_count;
  logic [DESC_CNT_W-1:0] desc_free;
  logic [63:0] desc_gap_mem [DESC_FIFO_DEPTH];
  logic [31:0] desc_word_mem [DESC_FIFO_DEPTH];
  logic [15:0] desc_len_mem [DESC_FIFO_DEPTH];
  logic [15:0] desc_flags_mem [DESC_FIFO_DEPTH];

  logic [META_PTR_W-1:0] meta_wr_ptr;
  logic [META_PTR_W-1:0] meta_rd_ptr;
  logic [META_CNT_W-1:0] meta_count;
  logic [63:0] meta_gap_mem [META_FIFO_DEPTH];
  logic [15:0] meta_len_mem [META_FIFO_DEPTH];
  logic [15:0] meta_flags_mem [META_FIFO_DEPTH];

  logic [63:0] cur_gap;
  logic [31:0] cur_word_offset;
  logic [15:0] cur_len;
  logic [15:0] cur_flags;
  logic [15:0] cur_bytes_left;
  logic [15:0] cur_beats_left;
  logic [7:0]  payload_run_packets_left;
  logic [15:0] payload_run_beats_left;
  logic [63:0] payload_ar_addr;
  logic [8:0]  payload_burst_beats;
  logic [8:0]  payload_burst_left;
  logic [DESC_PTR_W-1:0] scan_ptr;
  logic [7:0]  scan_count;
  logic [15:0] scan_beats;
  logic [31:0] scan_expected_word;

  logic [15:0] desc_head_beats;
  logic [15:0] desc_head_len;
  logic [15:0] scan_candidate_len;
  logic [15:0] scan_candidate_beats;
  logic [16:0] scan_total_beats;
  logic [8:0]  scan_total_count;
  logic [DESC_CNT_W-1:0] scan_count_desc;
  logic [DESC_CNT_W-1:0] scan_total_count_desc;
  logic [META_CNT_W-1:0] scan_total_count_meta;
  logic        scan_has_descriptor;
  logic        scan_accept;
  logic        scan_finish;
  logic [7:0]  scan_final_count;
  logic [15:0] scan_final_beats;
  logic [META_CNT_W-1:0] meta_free;
  logic        start_payload_scan;
  logic        start_payload_run;
  logic        payload_packet_complete;
  logic        output_active;

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
  logic [PAYLOAD_CNT_W-1:0] payload_fifo_free;

  logic desc_issue_req;
  logic payload_issue_req;
  logic desc_push;
  logic desc_pop;
  logic meta_push;
  logic meta_pop;
  logic payload_r_fire;
  logic last_payload_beat;
  logic last_payload_burst_beat;
  logic all_payload_beats_done;
  logic replay_complete;
  logic running;

  assign infinite_loop = loop_mode && (cfg_loop_count == 64'd0);
  assign desc_free = DESC_FIFO_DEPTH_LEVEL - desc_count;
  assign meta_free = META_FIFO_DEPTH_LEVEL - meta_count;
  assign payload_fifo_free = PAYLOAD_FIFO_DEPTH_LEVEL - payload_fifo_level;
  assign desc_head_len = desc_len_mem[desc_rd_ptr];
  assign desc_head_beats = beats_from_len(desc_head_len);
  assign scan_candidate_len = desc_len_mem[scan_ptr];
  assign scan_candidate_beats = beats_from_len(scan_candidate_len);
  assign scan_total_beats = {1'b0, scan_beats} + {1'b0, scan_candidate_beats};
  assign scan_total_count = {1'b0, scan_count} + 9'd1;
  assign scan_count_desc       = DESC_CNT_W'(scan_count);
  assign scan_total_count_desc = DESC_CNT_W'(scan_total_count);
  assign scan_total_count_meta = META_CNT_W'(scan_total_count);
  assign scan_has_descriptor =
    (payload_state == PL_SCAN) &&
    (scan_count < MAX_PAYLOAD_RUN_PKTS_U8) &&
    (scan_count_desc < desc_count);
  assign scan_accept =
    scan_has_descriptor &&
    (scan_candidate_beats != 16'd0) &&
    (desc_word_mem[scan_ptr] == scan_expected_word) &&
    (scan_total_beats <= 17'd256) &&
    ({2'b00, payload_fifo_free} >= scan_total_beats) &&
    (meta_free >= scan_total_count_meta);
  assign scan_finish =
    (payload_state == PL_SCAN) &&
    ((scan_accept &&
      ((scan_total_count[7:0] == MAX_PAYLOAD_RUN_PKTS_U8) ||
       (scan_total_count_desc == desc_count) ||
       (scan_total_beats == 17'd256))) ||
     (!scan_accept && (scan_count != 8'd0)));
  assign scan_final_count = scan_accept ? scan_total_count[7:0] : scan_count;
  assign scan_final_beats = scan_accept ? scan_total_beats[15:0] : scan_beats;

  assign m_axi_arid    = '0;
  assign m_axi_arsize  = 3'd6;
  assign m_axi_arburst = 2'b01;

  always_comb begin
    desc_burst_beats = cap_burst(cfg_pkt_count - desc_fetch_index, desc_free);
    payload_burst_beats = cap_burst({48'd0, payload_run_beats_left}, 256);
  end

  assign desc_issue_req =
    running &&
    !desc_fetch_done &&
    (rd_owner == RD_NONE) &&
    (desc_burst_beats != 9'd0) &&
    ((desc_count <= DESC_REFILL_LEVEL) || (payload_state == PL_IDLE));

  assign payload_issue_req =
    running &&
    (rd_owner == RD_NONE) &&
    (payload_state == PL_AR) &&
    (payload_burst_beats != 9'd0);

  always_comb begin
    ar_kind = AR_NONE;
    if (desc_issue_req && ((desc_count <= DESC_REFILL_LEVEL) || !payload_issue_req)) begin
      ar_kind = AR_DESC;
    end else if (payload_issue_req) begin
      ar_kind = AR_PAYLOAD;
    end else if (desc_issue_req) begin
      ar_kind = AR_DESC;
    end
  end

  always_comb begin
    m_axi_arvalid = 1'b0;
    m_axi_araddr  = '0;
    m_axi_arlen   = 8'd0;

    unique case (ar_kind)
      AR_DESC: begin
        m_axi_arvalid = 1'b1;
        m_axi_araddr  = cfg_desc_base + (desc_fetch_index << DESC_WORD_SHIFT);
        m_axi_arlen   = arlen_from_beats(desc_burst_beats);
      end
      AR_PAYLOAD: begin
        m_axi_arvalid = 1'b1;
        m_axi_araddr  = payload_ar_addr[AXI_ADDR_W_P-1:0];
        m_axi_arlen   = arlen_from_beats(payload_burst_beats);
      end
      default: begin
      end
    endcase
  end

  assign m_axi_rready = (rd_owner == RD_DESC)    ? (desc_count != DESC_FIFO_DEPTH_LEVEL) :
                        (rd_owner == RD_PAYLOAD) ? payload_fifo_s_tready :
                        1'b0;

  assign desc_push = (rd_owner == RD_DESC) && m_axi_rvalid && m_axi_rready;
  assign payload_r_fire = (rd_owner == RD_PAYLOAD) && m_axi_rvalid && m_axi_rready;
  assign last_payload_beat = (cur_bytes_left <= AXIS_KEEP_BYTES);
  assign last_payload_burst_beat = (payload_burst_left == 9'd1);
  assign all_payload_beats_done = (cur_beats_left == 16'd1);
  assign payload_packet_complete = payload_r_fire && all_payload_beats_done;

  assign payload_fifo_s_tdata  = m_axi_rdata;
  assign payload_fifo_s_tkeep  = last_payload_beat ? keep_from_len(cur_bytes_left) : {AXIS_KEEP_W{1'b1}};
  assign payload_fifo_s_tlast  = all_payload_beats_done;
  assign payload_fifo_s_tvalid = (rd_owner == RD_PAYLOAD) && (payload_state == PL_R) && m_axi_rvalid;

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

  assign start_payload_scan =
    running &&
    (payload_state == PL_IDLE) &&
    (desc_count != '0);
  assign start_payload_run =
    running &&
    scan_finish &&
    (scan_final_count != 8'd0);

  assign desc_pop = start_payload_run ||
                    (payload_r_fire && all_payload_beats_done && (payload_run_packets_left > 8'd1));
  assign meta_push = payload_packet_complete;
  assign meta_pop = m_meta_valid && m_meta_ready;

  assign m_meta_valid     = running && !output_active && (meta_count != '0);
  assign m_meta_gap_ticks = meta_gap_mem[meta_rd_ptr];
  assign m_meta_len       = meta_len_mem[meta_rd_ptr];
  assign m_meta_flags     = meta_flags_mem[meta_rd_ptr];

  assign payload_fifo_m_tready = output_active && m_axis_tready;
  assign m_axis_tdata  = payload_fifo_m_tdata;
  assign m_axis_tkeep  = payload_fifo_m_tkeep;
  assign m_axis_tvalid = output_active && payload_fifo_m_tvalid;
  assign m_axis_tlast  = payload_fifo_m_tlast;

  assign replay_complete =
    running &&
    desc_fetch_done &&
    (desc_count == '0) &&
    (payload_state == PL_IDLE) &&
    (meta_count == '0) &&
    !output_active &&
    (payload_fifo_level == '0) &&
    (rd_owner == RD_NONE);

  assign busy = running && !done;
  assign debug_state = {payload_state, rd_owner};

  always_ff @(posedge clk) begin
    if (!rstn) begin
      running               <= 1'b0;
      done                  <= 1'b0;
      error                 <= 1'b0;
      rd_owner              <= RD_NONE;
      desc_fetch_done       <= 1'b0;
      desc_loop_gap_next    <= 1'b0;
      desc_fetch_index      <= '0;
      desc_fetch_loops_done <= '0;
      desc_rsp_index        <= '0;
      desc_rsp_loop_gap     <= 1'b0;
      desc_rsp_beats_left   <= '0;
      desc_wr_ptr           <= '0;
      desc_rd_ptr           <= '0;
      desc_count            <= '0;
      meta_wr_ptr           <= '0;
      meta_rd_ptr           <= '0;
      meta_count            <= '0;
      payload_state         <= PL_IDLE;
      cur_gap               <= '0;
      cur_word_offset       <= '0;
      cur_len               <= '0;
      cur_flags             <= '0;
      cur_bytes_left        <= '0;
      cur_beats_left        <= '0;
      payload_run_packets_left <= '0;
      payload_run_beats_left   <= '0;
      payload_ar_addr       <= '0;
      payload_burst_left    <= '0;
      scan_ptr              <= '0;
      scan_count            <= '0;
      scan_beats            <= '0;
      scan_expected_word    <= '0;
      output_active         <= 1'b0;
    end else begin
      if (clear || stop) begin
        running               <= 1'b0;
        done                  <= 1'b0;
        rd_owner              <= RD_NONE;
        desc_fetch_done       <= 1'b0;
        desc_loop_gap_next    <= 1'b0;
        desc_fetch_index      <= '0;
        desc_fetch_loops_done <= '0;
        desc_rsp_index        <= '0;
        desc_rsp_loop_gap     <= 1'b0;
        desc_rsp_beats_left   <= '0;
        desc_wr_ptr           <= '0;
        desc_rd_ptr           <= '0;
        desc_count            <= '0;
        meta_wr_ptr           <= '0;
        meta_rd_ptr           <= '0;
        meta_count            <= '0;
        payload_state         <= PL_IDLE;
        cur_bytes_left        <= '0;
        cur_beats_left        <= '0;
        payload_run_packets_left <= '0;
        payload_run_beats_left   <= '0;
        payload_burst_left    <= '0;
        scan_ptr              <= '0;
        scan_count            <= '0;
        scan_beats            <= '0;
        scan_expected_word    <= '0;
        output_active         <= 1'b0;
      end else begin
        if (start && (cfg_pkt_count != 64'd0)) begin
          running               <= 1'b1;
          done                  <= 1'b0;
          error                 <= 1'b0;
          rd_owner              <= RD_NONE;
          desc_fetch_done       <= 1'b0;
          desc_loop_gap_next    <= 1'b0;
          desc_fetch_index      <= '0;
          desc_fetch_loops_done <= '0;
          desc_rsp_index        <= '0;
          desc_rsp_loop_gap     <= 1'b0;
          desc_rsp_beats_left   <= '0;
          desc_wr_ptr           <= '0;
          desc_rd_ptr           <= '0;
          desc_count            <= '0;
          meta_wr_ptr           <= '0;
          meta_rd_ptr           <= '0;
          meta_count            <= '0;
          payload_state         <= PL_IDLE;
          cur_bytes_left        <= '0;
          cur_beats_left        <= '0;
          payload_run_packets_left <= '0;
          payload_run_beats_left   <= '0;
          payload_burst_left    <= '0;
          scan_ptr              <= '0;
          scan_count            <= '0;
          scan_beats            <= '0;
          scan_expected_word    <= '0;
          output_active         <= 1'b0;
        end

        if (m_axi_arvalid && m_axi_arready) begin
          unique case (ar_kind)
            AR_DESC: begin
              rd_owner            <= RD_DESC;
              desc_rsp_index      <= desc_fetch_index;
              desc_rsp_loop_gap   <= desc_loop_gap_next;
              desc_rsp_beats_left <= desc_burst_beats;
              desc_loop_gap_next  <= 1'b0;
            end
            AR_PAYLOAD: begin
              rd_owner            <= RD_PAYLOAD;
              payload_burst_left  <= payload_burst_beats;
              payload_ar_addr     <= payload_ar_addr + ({55'd0, payload_burst_beats} << DESC_WORD_SHIFT);
              payload_state       <= PL_R;
            end
            default: begin
            end
          endcase
        end

        if (desc_push) begin
          desc_gap_mem[desc_wr_ptr]   <= (desc_rsp_loop_gap && (desc_rsp_index == 64'd0)) ? cfg_loop_gap_ticks : m_axi_rdata[63:0];
          desc_word_mem[desc_wr_ptr]  <= m_axi_rdata[95:64];
          desc_len_mem[desc_wr_ptr]   <= m_axi_rdata[111:96];
          desc_flags_mem[desc_wr_ptr] <= m_axi_rdata[127:112];
          desc_wr_ptr                 <= desc_wr_ptr + {{(DESC_PTR_W-1){1'b0}}, 1'b1};
          error                       <= error | (m_axi_rresp != 2'b00);

          if (desc_rsp_beats_left == 9'd1) begin
            rd_owner <= RD_NONE;
          end

          if (desc_rsp_beats_left != 9'd0) begin
            desc_rsp_beats_left <= desc_rsp_beats_left - 9'd1;
          end

          if (desc_rsp_index + 64'd1 >= cfg_pkt_count) begin
            if (loop_mode && (infinite_loop || (desc_fetch_loops_done + 64'd1 < cfg_loop_count))) begin
              desc_fetch_index      <= '0;
              desc_fetch_loops_done <= desc_fetch_loops_done + 64'd1;
              desc_loop_gap_next    <= 1'b1;
              desc_rsp_index        <= '0;
            end else begin
              desc_fetch_done  <= 1'b1;
              desc_fetch_index <= cfg_pkt_count;
              desc_rsp_index   <= desc_rsp_index + 64'd1;
            end
          end else begin
            desc_fetch_index <= desc_rsp_index + 64'd1;
            desc_rsp_index   <= desc_rsp_index + 64'd1;
          end

          error <= error | (m_axi_rresp != 2'b00) | (m_axi_rlast != (desc_rsp_beats_left == 9'd1));
        end

        if (start_payload_scan) begin
          payload_state      <= PL_SCAN;
          scan_ptr           <= desc_rd_ptr;
          scan_count         <= '0;
          scan_beats         <= '0;
          scan_expected_word <= desc_word_mem[desc_rd_ptr];
        end

        if ((payload_state == PL_SCAN) && scan_accept) begin
          scan_ptr           <= scan_ptr + {{(DESC_PTR_W-1){1'b0}}, 1'b1};
          scan_count         <= scan_total_count[7:0];
          scan_beats         <= scan_total_beats[15:0];
          scan_expected_word <= scan_expected_word + {16'd0, scan_candidate_beats};
        end

        if (start_payload_run) begin
          cur_gap         <= desc_gap_mem[desc_rd_ptr];
          cur_word_offset <= desc_word_mem[desc_rd_ptr];
          cur_len         <= desc_len_mem[desc_rd_ptr];
          cur_flags       <= desc_flags_mem[desc_rd_ptr];
          cur_bytes_left  <= desc_len_mem[desc_rd_ptr];
          cur_beats_left  <= desc_head_beats;
          payload_run_packets_left <= scan_final_count;
          payload_run_beats_left   <= scan_final_beats;
          payload_ar_addr <= cfg_data_base + ({32'd0, desc_word_mem[desc_rd_ptr]} << DESC_WORD_SHIFT);
          payload_state   <= PL_AR;
          scan_count      <= '0;
          scan_beats      <= '0;
          desc_rd_ptr     <= desc_rd_ptr + {{(DESC_PTR_W-1){1'b0}}, 1'b1};
        end

        if (payload_r_fire) begin
          error <= error | (m_axi_rresp != 2'b00) | (m_axi_rlast != last_payload_burst_beat);

          if (cur_beats_left > 16'd0) begin
            cur_beats_left <= cur_beats_left - 16'd1;
          end

          if (payload_run_beats_left > 16'd0) begin
            payload_run_beats_left <= payload_run_beats_left - 16'd1;
          end

          if (!last_payload_beat) begin
            cur_bytes_left <= cur_bytes_left - AXIS_KEEP_BYTES;
          end else begin
            cur_bytes_left <= '0;
          end

          if (payload_burst_left != 9'd0) begin
            payload_burst_left <= payload_burst_left - 9'd1;
          end

          if (all_payload_beats_done) begin
            meta_gap_mem[meta_wr_ptr]   <= cur_gap;
            meta_len_mem[meta_wr_ptr]   <= cur_len;
            meta_flags_mem[meta_wr_ptr] <= cur_flags;
            meta_wr_ptr                 <= meta_wr_ptr + {{(META_PTR_W-1){1'b0}}, 1'b1};
            if (payload_run_packets_left > 8'd1) begin
              payload_run_packets_left <= payload_run_packets_left - 8'd1;
              cur_gap         <= desc_gap_mem[desc_rd_ptr];
              cur_word_offset <= desc_word_mem[desc_rd_ptr];
              cur_len         <= desc_len_mem[desc_rd_ptr];
              cur_flags       <= desc_flags_mem[desc_rd_ptr];
              cur_bytes_left  <= desc_len_mem[desc_rd_ptr];
              cur_beats_left  <= beats_from_len(desc_len_mem[desc_rd_ptr]);
              desc_rd_ptr     <= desc_rd_ptr + {{(DESC_PTR_W-1){1'b0}}, 1'b1};
            end else begin
              payload_run_packets_left <= '0;
            end

            if (payload_run_beats_left == 16'd1) begin
              rd_owner      <= RD_NONE;
              payload_state <= PL_IDLE;
            end else if (last_payload_burst_beat) begin
              rd_owner      <= RD_NONE;
              payload_state <= PL_AR;
            end
          end else if (last_payload_burst_beat) begin
            rd_owner      <= RD_NONE;
            payload_state <= PL_AR;
          end
        end

        if (meta_pop) begin
          meta_rd_ptr   <= meta_rd_ptr + {{(META_PTR_W-1){1'b0}}, 1'b1};
          output_active <= 1'b1;
        end

        if (output_active && payload_fifo_m_tvalid && m_axis_tready && payload_fifo_m_tlast) begin
          output_active <= 1'b0;
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

        if (replay_complete) begin
          running <= 1'b0;
          done    <= 1'b1;
        end
      end
    end
  end
endmodule
