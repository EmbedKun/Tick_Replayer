`timescale 1ns/1ps

import traffic_replay_pkg::*;

module host_stream_parser (
  input  logic                   clk,
  input  logic                   rstn,
  input  logic                   enable,
  input  logic                   clear,

  input  logic [AXIS_DATA_W-1:0] s_axis_tdata,
  input  logic [AXIS_KEEP_W-1:0] s_axis_tkeep,
  input  logic                   s_axis_tvalid,
  output logic                   s_axis_tready,
  input  logic                   s_axis_tlast,

  output logic                   m_meta_valid,
  input  logic                   m_meta_ready,
  output logic [63:0]            m_meta_gap_ticks,
  output logic [15:0]            m_meta_len,
  output logic [15:0]            m_meta_flags,

  output logic [AXIS_DATA_W-1:0] m_axis_tdata,
  output logic [AXIS_KEEP_W-1:0] m_axis_tkeep,
  output logic                   m_axis_tvalid,
  input  logic                   m_axis_tready,
  output logic                   m_axis_tlast
);
  typedef enum logic [1:0] {
    ST_HEADER,
    ST_META,
    ST_PAYLOAD
  } state_t;

  state_t state;
  logic [15:0] bytes_left;
  logic [15:0] header_len;
  logic [15:0] beat_bytes;
  logic        last_payload_beat;

  assign beat_bytes        = bytes_this_beat(bytes_left);
  assign last_payload_beat = (bytes_left <= AXIS_KEEP_BYTES);

  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tkeep  = last_payload_beat ? keep_from_len(bytes_left) : {AXIS_KEEP_W{1'b1}};
  assign m_axis_tvalid = enable && (state == ST_PAYLOAD) && s_axis_tvalid;
  assign m_axis_tlast  = last_payload_beat;

  assign m_meta_valid = enable && (state == ST_META);
  assign m_meta_len   = header_len;

  always_comb begin
    s_axis_tready = 1'b0;
    if (enable) begin
      unique case (state)
        ST_HEADER:  s_axis_tready = 1'b1;
        ST_META:    s_axis_tready = 1'b0;
        ST_PAYLOAD: s_axis_tready = m_axis_tready;
        default:    s_axis_tready = 1'b0;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      state            <= ST_HEADER;
      bytes_left       <= '0;
      header_len       <= '0;
      m_meta_gap_ticks <= '0;
      m_meta_flags     <= '0;
    end else begin
      if (clear) begin
        state      <= ST_HEADER;
        bytes_left <= '0;
      end else if (enable) begin
        unique case (state)
          ST_HEADER: begin
            if (s_axis_tvalid && s_axis_tready) begin
              m_meta_gap_ticks <= s_axis_tdata[63:0];
              header_len       <= s_axis_tdata[111:96];
              m_meta_flags     <= s_axis_tdata[127:112];
              bytes_left       <= s_axis_tdata[111:96];
              state            <= ST_META;
            end
          end
          ST_META: begin
            if (m_meta_ready) begin
              state <= (header_len == 16'd0) ? ST_HEADER : ST_PAYLOAD;
            end
          end
          ST_PAYLOAD: begin
            if (m_axis_tvalid && m_axis_tready) begin
              if (last_payload_beat) begin
                bytes_left <= '0;
                state      <= ST_HEADER;
              end else begin
                bytes_left <= bytes_left - AXIS_KEEP_BYTES;
              end
            end
          end
          default: begin
            state <= ST_HEADER;
          end
        endcase
      end
    end
  end
endmodule
