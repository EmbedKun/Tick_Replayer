`timescale 1ns/1ps

import traffic_replay_pkg::*;

module ddr_stream_reader #(
  parameter int AXI_ADDR_W_P = AXI_ADDR_W,
  parameter int AXI_ID_W_P   = AXI_ID_W,
  parameter int MAX_BURST_BEATS = 256,
  parameter int MAX_OUTSTANDING_BURSTS = 16
) (
  input  logic                     clk,
  input  logic                     rstn,
  input  logic                     start,
  input  logic                     stop,
  input  logic                     clear,
  input  logic [63:0]              cfg_stream_base,
  input  logic [63:0]              cfg_stream_base1,
  input  logic [63:0]              cfg_stream_bytes,
  input  logic [63:0]              cfg_ring_size,
  input  logic [63:0]              cfg_ring_write_count,
  input  logic                     cfg_ring_eof,
  input  logic                     cfg_pingpong_enable,

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

  output logic [AXIS_DATA_W-1:0]   m_axis_tdata,
  output logic [AXIS_KEEP_W-1:0]   m_axis_tkeep,
  output logic                     m_axis_tvalid,
  input  logic                     m_axis_tready,
  output logic                     m_axis_tlast,

  output logic                     busy,
  output logic                     done,
  output logic                     error,
  output logic [63:0]              read_count,
  output logic [63:0]              ring_level,
  output logic [31:0]              stream_status,
  output logic [3:0]               debug_state
);
  typedef enum logic [3:0] {
    ST_IDLE = 4'd0,
    ST_RUN  = 4'd1,
    ST_DONE = 4'd2
  } state_t;

  localparam int CMD_DEPTH = (MAX_OUTSTANDING_BURSTS < 2) ? 2 : MAX_OUTSTANDING_BURSTS;
  localparam int CMD_PTR_W = (CMD_DEPTH <= 2) ? 1 : $clog2(CMD_DEPTH);
  localparam int CMD_CNT_W = $clog2(CMD_DEPTH + 1);

  localparam logic [63:0] BEAT_BYTES_U64 = AXIS_KEEP_BYTES;
  localparam logic [63:0] MAX_BURST_BEATS_U64 = 64'(MAX_BURST_BEATS);
  localparam logic [CMD_CNT_W-1:0] CMD_DEPTH_LEVEL = CMD_CNT_W'(CMD_DEPTH);

  state_t state;

  logic [63:0] issue_count;
  logic [63:0] issue_offset;
  logic        issue_bank_select;
  logic [AXI_ADDR_W_P-1:0] ar_addr_q;
  logic [8:0] ar_beats_q;
  logic       ar_stage_valid;
  logic       ar_fire;

  logic [8:0] cmd_beats_mem [CMD_DEPTH];
  logic [CMD_PTR_W-1:0] cmd_wr_ptr;
  logic [CMD_PTR_W-1:0] cmd_rd_ptr;
  logic [CMD_CNT_W-1:0] cmd_count;
  logic [CMD_CNT_W:0]   cmd_total_occupied;
  logic                 cmd_accept_ready;
  logic                 cmd_push;
  logic                 cmd_pop;

  logic       rsp_valid;
  logic       rsp_active;
  logic [8:0] rsp_beats_left;
  logic [8:0] rsp_beats_left_eff;
  logic       rsp_last_beat;
  logic       rsp_fire;
  logic       rsp_error;

  logic        ring_mode_cfg;
  logic        ring_size_valid_cfg;
  logic        ring_size_aligned_cfg;
  logic        ring_size_power_of_two_cfg;
  logic        pingpong_mode_cfg;
  logic [63:0] cfg_stream_base_q;
  logic [63:0] cfg_stream_base1_q;
  logic [63:0] cfg_ring_size_q;
  logic [63:0] ring_capacity_bytes_q;
  logic        ring_mode_q;
  logic        ring_size_valid_q;
  logic        pingpong_mode_q;
  logic        ring_mode_status;
  logic        ring_size_valid_status;
  logic        pingpong_mode_status;
  logic [63:0] ring_write_aligned;
  logic        ring_write_behind;
  logic        issue_write_behind;
  logic [63:0] ring_available_bytes_raw;
  logic [63:0] issue_available_bytes_raw;
  logic [63:0] issue_available_beats_raw;
  logic [63:0] ring_capacity_bytes;
  logic [63:0] ring_bytes_to_wrap;
  logic [63:0] ring_beats_to_wrap;
  logic        ring_overrun;
  logic        ring_empty_wait;
  logic        fatal_ring_error;
  logic        issue_metrics_valid;
  logic        issue_metrics_ok;
  logic        issue_window_valid;
  logic        issue_window_ok;
  logic [AXI_ADDR_W_P-1:0] issue_window_addr_q;
  logic [8:0]  issue_window_available_beats_q;
  logic [8:0]  issue_window_wrap_beats_q;
  logic [AXI_ADDR_W_P-1:0] issue_addr_q;
  logic [8:0]  issue_burst_beats_q;
  logic [8:0]  issue_burst_beats;
  logic [63:0] ar_burst_bytes;
  logic [63:0] ar_offset_after_burst;
  logic        ar_wraps_ring;
  logic        issue_req;
  logic [63:0] issue_offset_eff;
  logic        issue_pingpong_bank1;
  logic [63:0] issue_base_eff;
  logic [63:0] next_issue_count;
  logic [63:0] next_issue_offset;
  logic        input_consumed;
  logic        pending_empty;
  logic [63:0] ring_level_next;
  logic [31:0] stream_status_next;

  function automatic logic [CMD_PTR_W-1:0] inc_cmd_ptr(input logic [CMD_PTR_W-1:0] ptr);
    begin
      if (ptr == CMD_PTR_W'(CMD_DEPTH - 1)) begin
        inc_cmd_ptr = '0;
      end else begin
        inc_cmd_ptr = ptr + {{(CMD_PTR_W-1){1'b0}}, 1'b1};
      end
    end
  endfunction

  function automatic logic [8:0] sat_burst_beats(input logic [63:0] beats);
    begin
      if (beats > MAX_BURST_BEATS_U64) begin
        sat_burst_beats = MAX_BURST_BEATS_U64[8:0];
      end else begin
        sat_burst_beats = beats[8:0];
      end
    end
  endfunction

  function automatic logic [8:0] min_burst_beats_sat(
    input logic [8:0] available_beats,
    input logic [8:0] beats_to_wrap
  );
    logic [8:0] n;
    begin
      n = available_beats;
      if ((beats_to_wrap != 9'd0) && (beats_to_wrap < n)) begin
        n = beats_to_wrap;
      end
      min_burst_beats_sat = n;
    end
  endfunction

  function automatic logic [7:0] arlen_from_beats(input logic [8:0] beats);
    begin
      arlen_from_beats = (beats == 9'd256) ? 8'hff : (beats[7:0] - 8'd1);
    end
  endfunction

  assign ring_mode_cfg          = (cfg_ring_size != 64'd0);
  assign ring_size_aligned_cfg  = ring_mode_cfg && (cfg_ring_size[5:0] == 6'd0);
  assign ring_size_power_of_two_cfg =
    ring_mode_cfg && ((cfg_ring_size & (cfg_ring_size - 64'd1)) == 64'd0);
  assign pingpong_mode_cfg      = cfg_pingpong_enable;
  assign ring_size_valid_cfg    =
    ring_size_aligned_cfg && (!pingpong_mode_cfg || ring_size_power_of_two_cfg);
  assign ring_mode_status       = (state == ST_IDLE) ? ring_mode_cfg : ring_mode_q;
  assign ring_size_valid_status = (state == ST_IDLE) ? ring_size_valid_cfg : ring_size_valid_q;
  assign pingpong_mode_status   = (state == ST_IDLE) ? pingpong_mode_cfg : pingpong_mode_q;

  assign ring_write_aligned = {cfg_ring_write_count[63:6], 6'd0};
  assign ring_write_behind  = ring_write_aligned < read_count;
  assign issue_write_behind = ring_write_aligned < issue_count;
  assign ring_available_bytes_raw =
    ring_write_behind ? 64'd0 : (ring_write_aligned - read_count);
  assign issue_available_bytes_raw =
    issue_write_behind ? 64'd0 : (ring_write_aligned - issue_count);
  assign issue_available_beats_raw = issue_available_bytes_raw[63:6];
  assign ring_capacity_bytes = ring_capacity_bytes_q;
  assign ring_overrun =
    ring_size_valid_q && (ring_available_bytes_raw > ring_capacity_bytes_q);
  assign issue_offset_eff = issue_offset;
  assign issue_pingpong_bank1 = pingpong_mode_q && issue_bank_select;
  assign issue_base_eff = issue_pingpong_bank1 ? cfg_stream_base1_q : cfg_stream_base_q;
  assign ring_bytes_to_wrap = (ring_size_valid_q && (cfg_ring_size_q > issue_offset_eff)) ?
                              (cfg_ring_size_q - issue_offset_eff) : 64'd0;
  assign ring_beats_to_wrap = ring_bytes_to_wrap[63:6];
  assign fatal_ring_error = !ring_size_valid_q || ring_write_behind ||
                            issue_write_behind || ring_overrun;

  assign ar_burst_bytes = {55'd0, ar_beats_q} << 6;
  assign ar_offset_after_burst =
    (issue_offset_eff + ar_burst_bytes >= cfg_ring_size_q) ?
      (issue_offset_eff + ar_burst_bytes - cfg_ring_size_q) :
      (issue_offset_eff + ar_burst_bytes);
  assign ar_wraps_ring = ring_size_valid_q &&
                         ((issue_offset_eff + ar_burst_bytes) >= cfg_ring_size_q);
  assign next_issue_count = ar_fire ? (issue_count + ar_burst_bytes) : issue_count;
  assign next_issue_offset =
    ar_fire ? ar_offset_after_burst : issue_offset;
  assign issue_burst_beats = issue_burst_beats_q;

  assign cmd_total_occupied = {1'b0, cmd_count} +
                              {{CMD_CNT_W{1'b0}}, ar_stage_valid};
  assign cmd_accept_ready = (cmd_total_occupied < {1'b0, CMD_DEPTH_LEVEL});
  assign issue_req =
    (state == ST_RUN) &&
    !error &&
    !fatal_ring_error &&
    issue_metrics_valid &&
    issue_metrics_ok &&
    !ar_stage_valid &&
    cmd_accept_ready &&
    (issue_burst_beats != 9'd0);

  assign input_consumed =
    cfg_ring_eof &&
    (issue_count >= ring_write_aligned);
  assign pending_empty =
    !ar_stage_valid &&
    (cmd_count == '0) &&
    !rsp_active;
  assign ring_empty_wait =
    (state == ST_RUN) &&
    !done &&
    ring_size_valid_q &&
    !ring_write_behind &&
    !issue_write_behind &&
    !ring_overrun &&
    (issue_available_beats_raw == 64'd0) &&
    !cfg_ring_eof &&
    pending_empty;

  assign ring_level_next = ring_available_bytes_raw;
  assign stream_status_next = {
    18'd0,
    pingpong_mode_status,
    ring_write_behind,
    ring_empty_wait,
    ring_overrun,
    ring_size_valid_status,
    cfg_ring_eof,
    ring_mode_status,
    error,
    done,
    busy,
    state
  };

  assign m_axi_arid    = '0;
  assign m_axi_araddr  = ar_addr_q;
  assign m_axi_arsize  = 3'd6;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arvalid = ar_stage_valid;
  assign m_axi_arlen   = arlen_from_beats(ar_beats_q);
  assign ar_fire       = m_axi_arvalid && m_axi_arready;

  assign rsp_valid          = (cmd_count != '0);
  assign rsp_beats_left_eff = rsp_active ? rsp_beats_left : cmd_beats_mem[cmd_rd_ptr];
  assign rsp_last_beat      = rsp_valid && (rsp_beats_left_eff <= 9'd1);
  assign m_axi_rready       = rsp_valid && m_axis_tready;
  assign rsp_fire           = m_axi_rvalid && m_axi_rready;
  assign rsp_error          = rsp_fire &&
                              ((m_axi_rresp != 2'b00) ||
                               (m_axi_rlast != rsp_last_beat));

  assign m_axis_tdata  = m_axi_rdata;
  assign m_axis_tvalid = rsp_valid && m_axi_rvalid;
  assign m_axis_tkeep  = {AXIS_KEEP_W{1'b1}};
  assign m_axis_tlast  = 1'b0;
  assign debug_state   = state;
  assign cmd_push      = ar_fire;
  assign cmd_pop       = rsp_fire && rsp_last_beat;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      state             <= ST_IDLE;
      ar_addr_q         <= '0;
      ar_beats_q        <= '0;
      ar_stage_valid    <= 1'b0;
      issue_count       <= '0;
      issue_offset      <= '0;
      issue_bank_select <= 1'b0;
      issue_metrics_valid <= 1'b0;
      issue_metrics_ok    <= 1'b0;
      issue_window_valid <= 1'b0;
      issue_window_ok    <= 1'b0;
      issue_window_addr_q <= '0;
      issue_window_available_beats_q <= '0;
      issue_window_wrap_beats_q <= '0;
      issue_addr_q        <= '0;
      issue_burst_beats_q <= '0;
      cfg_stream_base_q  <= '0;
      cfg_stream_base1_q <= '0;
      cfg_ring_size_q    <= '0;
      ring_capacity_bytes_q <= '0;
      ring_mode_q        <= 1'b0;
      ring_size_valid_q  <= 1'b0;
      pingpong_mode_q    <= 1'b0;
      cmd_wr_ptr        <= '0;
      cmd_rd_ptr        <= '0;
      cmd_count         <= '0;
      rsp_active        <= 1'b0;
      rsp_beats_left    <= '0;
      read_count        <= '0;
      ring_level        <= '0;
      stream_status     <= '0;
      busy              <= 1'b0;
      done              <= 1'b0;
      error             <= 1'b0;
    end else begin
      ring_level    <= ring_level_next;
      stream_status <= stream_status_next;

      if (clear || stop) begin
        state             <= ST_IDLE;
        ar_addr_q         <= '0;
        ar_beats_q        <= '0;
        ar_stage_valid    <= 1'b0;
        issue_count       <= '0;
        issue_offset      <= '0;
        issue_bank_select <= 1'b0;
        issue_metrics_valid <= 1'b0;
        issue_metrics_ok    <= 1'b0;
        issue_window_valid <= 1'b0;
        issue_window_ok    <= 1'b0;
        issue_window_addr_q <= '0;
        issue_window_available_beats_q <= '0;
        issue_window_wrap_beats_q <= '0;
        issue_addr_q        <= '0;
        issue_burst_beats_q <= '0;
        cfg_stream_base_q  <= '0;
        cfg_stream_base1_q <= '0;
        cfg_ring_size_q    <= '0;
        ring_capacity_bytes_q <= '0;
        ring_mode_q        <= 1'b0;
        ring_size_valid_q  <= 1'b0;
        pingpong_mode_q    <= 1'b0;
        cmd_wr_ptr        <= '0;
        cmd_rd_ptr        <= '0;
        cmd_count         <= '0;
        rsp_active        <= 1'b0;
        rsp_beats_left    <= '0;
        read_count        <= '0;
        ring_level        <= '0;
        stream_status     <= '0;
        busy              <= 1'b0;
        done              <= 1'b0;
        error             <= 1'b0;
      end else if (start) begin
        ar_addr_q         <= '0;
        ar_beats_q        <= '0;
        ar_stage_valid    <= 1'b0;
        issue_count       <= '0;
        issue_offset      <= '0;
        issue_bank_select <= 1'b0;
        issue_metrics_valid <= 1'b0;
        issue_metrics_ok    <= 1'b0;
        issue_window_valid <= 1'b0;
        issue_window_ok    <= 1'b0;
        issue_window_addr_q <= '0;
        issue_window_available_beats_q <= '0;
        issue_window_wrap_beats_q <= '0;
        issue_addr_q        <= '0;
        issue_burst_beats_q <= '0;
        cfg_stream_base_q  <= cfg_stream_base;
        cfg_stream_base1_q <= cfg_stream_base1;
        cfg_ring_size_q    <= cfg_ring_size;
        ring_capacity_bytes_q <= pingpong_mode_cfg ? (cfg_ring_size << 1) : cfg_ring_size;
        ring_mode_q        <= ring_mode_cfg;
        ring_size_valid_q  <= ring_size_valid_cfg;
        pingpong_mode_q    <= pingpong_mode_cfg;
        cmd_wr_ptr        <= '0;
        cmd_rd_ptr        <= '0;
        cmd_count         <= '0;
        rsp_active        <= 1'b0;
        rsp_beats_left    <= '0;
        read_count        <= '0;
        error             <= !ring_size_valid_cfg;
        if (ring_size_valid_cfg) begin
          state <= ST_RUN;
          busy  <= 1'b1;
          done  <= 1'b0;
        end else begin
          state <= ST_DONE;
          busy  <= 1'b0;
          done  <= 1'b1;
        end
      end else begin
        if (state == ST_RUN) begin
          if (fatal_ring_error || rsp_error) begin
            error <= 1'b1;
          end

          if (ar_fire) begin
            issue_count  <= next_issue_count;
            issue_offset <= next_issue_offset;
            if (pingpong_mode_q && ar_wraps_ring) begin
              issue_bank_select <= ~issue_bank_select;
            end
            issue_metrics_valid <= 1'b0;
            issue_window_valid <= 1'b0;
          end

          if (issue_req) begin
            ar_stage_valid <= 1'b1;
            ar_addr_q      <= issue_addr_q;
            ar_beats_q     <= issue_burst_beats;
            issue_metrics_valid <= 1'b0;
            issue_window_valid <= 1'b0;
          end else if (ar_fire) begin
            ar_stage_valid <= 1'b0;
          end else if (!ar_stage_valid && !issue_metrics_valid) begin
            if (issue_window_valid) begin
              issue_window_valid <= 1'b0;
              issue_metrics_ok    <= issue_window_ok;
              issue_addr_q        <= issue_window_addr_q;
              issue_burst_beats_q <= min_burst_beats_sat(issue_window_available_beats_q,
                                                         issue_window_wrap_beats_q);
              issue_metrics_valid <= issue_window_ok &&
                                     (min_burst_beats_sat(issue_window_available_beats_q,
                                                          issue_window_wrap_beats_q) != 9'd0);
            end else begin
              issue_window_valid <= 1'b1;
              issue_window_ok    <= !fatal_ring_error;
              issue_window_addr_q <= AXI_ADDR_W_P'(issue_base_eff + issue_offset_eff);
              issue_window_available_beats_q <= sat_burst_beats(issue_available_beats_raw);
              issue_window_wrap_beats_q      <= sat_burst_beats(ring_beats_to_wrap);
            end
          end

          if (cmd_push) begin
            cmd_beats_mem[cmd_wr_ptr] <= ar_beats_q;
            cmd_wr_ptr <= inc_cmd_ptr(cmd_wr_ptr);
          end
          if (cmd_pop) begin
            cmd_rd_ptr <= inc_cmd_ptr(cmd_rd_ptr);
          end

          unique case ({cmd_push, cmd_pop})
            2'b10: cmd_count <= cmd_count + {{(CMD_CNT_W-1){1'b0}}, 1'b1};
            2'b01: cmd_count <= cmd_count - {{(CMD_CNT_W-1){1'b0}}, 1'b1};
            default: begin
            end
          endcase

          if (rsp_fire) begin
            read_count <= read_count + BEAT_BYTES_U64;
            if (rsp_last_beat) begin
              rsp_active     <= 1'b0;
              rsp_beats_left <= '0;
            end else if (rsp_active) begin
              rsp_beats_left <= rsp_beats_left - 9'd1;
            end else begin
              rsp_active     <= 1'b1;
              rsp_beats_left <= cmd_beats_mem[cmd_rd_ptr] - 9'd1;
            end
          end

          if ((fatal_ring_error || error || input_consumed) && pending_empty) begin
            state <= ST_DONE;
            busy  <= 1'b0;
            done  <= 1'b1;
          end
        end else if (state == ST_DONE) begin
          busy <= 1'b0;
          done <= 1'b1;
        end else begin
          busy <= 1'b0;
          done <= 1'b0;
        end
      end
    end
  end

  // cfg_stream_bytes is intentionally ignored in the ring-only STREAM mode.
  // Keep the port for register-map compatibility with older software.
  logic unused_cfg_stream_bytes;
  assign unused_cfg_stream_bytes = ^cfg_stream_bytes;
  logic unused_m_axi_rid;
  assign unused_m_axi_rid = ^m_axi_rid;
endmodule
