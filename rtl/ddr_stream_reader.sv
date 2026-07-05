`timescale 1ns/1ps

import traffic_replay_pkg::*;

module ddr_stream_reader #(
  parameter int AXI_ADDR_W_P = AXI_ADDR_W,
  parameter int AXI_ID_W_P   = AXI_ID_W,
  parameter int MAX_BURST_BEATS = 256
) (
  input  logic                     clk,
  input  logic                     rstn,
  input  logic                     start,
  input  logic                     stop,
  input  logic                     clear,
  input  logic [63:0]              cfg_stream_base,
  input  logic [63:0]              cfg_stream_bytes,
  input  logic [63:0]              cfg_ring_size,
  input  logic [63:0]              cfg_ring_write_count,
  input  logic                     cfg_ring_eof,

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
    ST_IDLE,
    ST_PREP0,
    ST_PREP1,
    ST_AR,
    ST_R,
    ST_DONE
  } state_t;

  localparam logic [63:0] BEAT_BYTES_U64 = AXIS_KEEP_BYTES;
  localparam logic [63:0] MAX_BURST_BEATS_U64 = MAX_BURST_BEATS;
  localparam logic [AXI_ADDR_W_P-1:0] BEAT_BYTES_ADDR = AXIS_KEEP_BYTES;

  state_t state;

  logic [8:0]  burst_beats_left;
  logic [8:0]  burst_beats_issue;
  logic [63:0] ring_offset;

  logic        ring_mode;
  logic        ring_size_valid;
  logic [63:0] ring_write_aligned;
  logic        ring_write_behind;
  logic [63:0] ring_available_bytes_raw;
  logic [63:0] ring_available_beats_raw;
  logic [63:0] ring_bytes_to_wrap;
  logic [63:0] ring_beats_to_wrap;
  logic        ring_overrun;
  logic        ring_empty_wait;
  logic        next_beat_wrap;
  logic [63:0] next_ring_offset;
  logic [AXI_ADDR_W_P-1:0] next_stream_addr;
  logic [63:0] ring_level_next;
  logic [31:0] stream_status_next;

  logic [63:0] prep_available_beats;
  logic [63:0] prep_beats_to_wrap;
  logic        prep_eof;
  logic        prep_size_valid;
  logic        prep_write_behind;
  logic        prep_overrun;

  function automatic logic [8:0] min_burst_beats(
    input logic [63:0] available_beats,
    input logic [63:0] beats_to_wrap
  );
    logic [63:0] n;
    begin
      n = available_beats;
      if ((beats_to_wrap != 64'd0) && (beats_to_wrap < n)) begin
        n = beats_to_wrap;
      end
      if (n > MAX_BURST_BEATS_U64) begin
        n = MAX_BURST_BEATS_U64;
      end
      min_burst_beats = n[8:0];
    end
  endfunction

  function automatic logic [7:0] arlen_from_beats(input logic [8:0] beats);
    begin
      arlen_from_beats = (beats == 9'd256) ? 8'hff : (beats[7:0] - 8'd1);
    end
  endfunction

  assign ring_mode          = (cfg_ring_size != 64'd0);
  assign ring_size_valid    = ring_mode && (cfg_ring_size[5:0] == 6'd0);
  assign ring_write_aligned = {cfg_ring_write_count[63:6], 6'd0};
  assign ring_write_behind  = ring_write_aligned < read_count;
  assign ring_available_bytes_raw = ring_write_behind ? 64'd0 : (ring_write_aligned - read_count);
  assign ring_available_beats_raw = ring_available_bytes_raw[63:6];
  assign ring_overrun = ring_size_valid && (ring_available_bytes_raw > cfg_ring_size);
  assign ring_empty_wait = busy && !done && ring_size_valid && !ring_write_behind &&
                           !ring_overrun && (ring_available_beats_raw == 64'd0) &&
                           !cfg_ring_eof;
  assign ring_bytes_to_wrap = (ring_size_valid && (cfg_ring_size > ring_offset)) ?
                              (cfg_ring_size - ring_offset) : 64'd0;
  assign ring_beats_to_wrap = ring_bytes_to_wrap[63:6];
  assign next_beat_wrap = (ring_offset + BEAT_BYTES_U64 >= cfg_ring_size);
  assign next_ring_offset = next_beat_wrap ? 64'd0 : (ring_offset + BEAT_BYTES_U64);
  assign next_stream_addr = next_beat_wrap ? cfg_stream_base[AXI_ADDR_W_P-1:0] :
                            (m_axi_araddr + BEAT_BYTES_ADDR);
  assign ring_level_next = ring_available_bytes_raw;
  assign stream_status_next = {
    19'd0,
    ring_write_behind,
    ring_empty_wait,
    ring_overrun,
    ring_size_valid,
    cfg_ring_eof,
    ring_mode,
    error,
    done,
    busy,
    state
  };

  assign m_axi_arid    = '0;
  assign m_axi_arsize  = 3'd6;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arvalid = (state == ST_AR) && (burst_beats_issue != 9'd0);
  assign m_axi_arlen   = (burst_beats_issue == 9'd0) ? 8'd0 : arlen_from_beats(burst_beats_issue);

  assign m_axi_rready  = (state == ST_R) && m_axis_tready;

  assign m_axis_tdata  = m_axi_rdata;
  assign m_axis_tvalid = (state == ST_R) && m_axi_rvalid;
  assign m_axis_tkeep  = {AXIS_KEEP_W{1'b1}};
  assign m_axis_tlast  = 1'b0;
  assign debug_state   = state;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      state             <= ST_IDLE;
      m_axi_araddr      <= '0;
      burst_beats_left  <= '0;
      burst_beats_issue <= '0;
      read_count        <= '0;
      ring_offset       <= '0;
      prep_available_beats <= '0;
      prep_beats_to_wrap   <= '0;
      prep_eof             <= 1'b0;
      prep_size_valid      <= 1'b0;
      prep_write_behind    <= 1'b0;
      prep_overrun         <= 1'b0;
      ring_level        <= '0;
      stream_status     <= '0;
      busy              <= 1'b0;
      done              <= 1'b0;
      error             <= 1'b0;
    end else begin
      // Register host-visible status.  This keeps the AXI-Lite read path away
      // from ring pointer arithmetic and also makes status sampling stable.
      ring_level    <= ring_level_next;
      stream_status <= stream_status_next;

      if (clear || stop) begin
        state             <= ST_IDLE;
        m_axi_araddr      <= '0;
        burst_beats_left  <= '0;
        burst_beats_issue <= '0;
        read_count        <= '0;
        ring_offset       <= '0;
        prep_available_beats <= '0;
        prep_beats_to_wrap   <= '0;
        prep_eof             <= 1'b0;
        prep_size_valid      <= 1'b0;
        prep_write_behind    <= 1'b0;
        prep_overrun         <= 1'b0;
        ring_level        <= '0;
        stream_status     <= '0;
        busy              <= 1'b0;
        done              <= 1'b0;
        error             <= 1'b0;
      end else begin
        unique case (state)
          ST_IDLE: begin
            done <= 1'b0;
            if (start) begin
              m_axi_araddr      <= cfg_stream_base[AXI_ADDR_W_P-1:0];
              burst_beats_left  <= '0;
              burst_beats_issue <= '0;
              read_count        <= 64'd0;
              ring_offset       <= 64'd0;
              error             <= !ring_size_valid;
              if (ring_size_valid) begin
                busy  <= 1'b1;
                done  <= 1'b0;
                state <= ST_PREP0;
              end else begin
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= ST_DONE;
              end
            end
          end

          ST_PREP0: begin
            prep_available_beats <= ring_available_beats_raw;
            prep_beats_to_wrap   <= ring_beats_to_wrap;
            prep_eof             <= cfg_ring_eof;
            prep_size_valid      <= ring_size_valid;
            prep_write_behind    <= ring_write_behind;
            prep_overrun         <= ring_overrun;
            state                <= ST_PREP1;
          end

          ST_PREP1: begin
            error <= error | !prep_size_valid | prep_write_behind | prep_overrun;
            if (!prep_size_valid || prep_write_behind || prep_overrun) begin
              burst_beats_issue <= 9'd0;
              busy              <= 1'b0;
              done              <= 1'b1;
              state             <= ST_DONE;
            end else if ((prep_available_beats == 64'd0) && prep_eof) begin
              burst_beats_issue <= 9'd0;
              busy              <= 1'b0;
              done              <= 1'b1;
              state             <= ST_DONE;
            end else if (prep_available_beats == 64'd0) begin
              burst_beats_issue <= 9'd0;
              state             <= ST_PREP0;
            end else begin
              burst_beats_issue <= min_burst_beats(prep_available_beats, prep_beats_to_wrap);
              state             <= ST_AR;
            end
          end

          ST_AR: begin
            if (burst_beats_issue == 9'd0) begin
              state <= ST_PREP0;
            end else if (m_axi_arvalid && m_axi_arready) begin
              burst_beats_left <= burst_beats_issue;
              state            <= ST_R;
            end
          end

          ST_R: begin
            if (m_axis_tvalid && m_axis_tready) begin
              error      <= error | (m_axi_rresp != 2'b00) |
                            (m_axi_rlast != (burst_beats_left <= 9'd1));
              read_count <= read_count + BEAT_BYTES_U64;
              ring_offset <= next_ring_offset;
              m_axi_araddr <= next_stream_addr;

              if (burst_beats_left <= 9'd1) begin
                state <= ST_PREP0;
              end else begin
                burst_beats_left <= burst_beats_left - 9'd1;
              end
            end
          end

          ST_DONE: begin
            busy <= 1'b0;
            done <= 1'b1;
            if (start) begin
              m_axi_araddr      <= cfg_stream_base[AXI_ADDR_W_P-1:0];
              burst_beats_left  <= '0;
              burst_beats_issue <= '0;
              read_count        <= 64'd0;
              ring_offset       <= 64'd0;
              error             <= !ring_size_valid;
              if (ring_size_valid) begin
                busy  <= 1'b1;
                done  <= 1'b0;
                state <= ST_PREP0;
              end else begin
                busy  <= 1'b0;
                done  <= 1'b1;
              end
            end
          end

          default: begin
            state <= ST_IDLE;
          end
        endcase
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
