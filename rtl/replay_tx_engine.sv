`timescale 1ns/1ps

import traffic_replay_pkg::*;

module replay_tx_engine (
  input  logic                   clk,
  input  logic                   rstn,
  input  logic                   enable,
  input  logic                   clear,

  input  logic                   s_pkt_valid,
  output logic                   s_pkt_ready,
  input  logic [15:0]            s_pkt_len,
  input  logic [15:0]            s_pkt_flags,

  input  logic [AXIS_DATA_W-1:0] s_axis_tdata,
  input  logic [AXIS_KEEP_W-1:0] s_axis_tkeep,
  input  logic                   s_axis_tvalid,
  output logic                   s_axis_tready,
  input  logic                   s_axis_tlast,

  output logic [AXIS_DATA_W-1:0] m_axis_tdata,
  output logic [AXIS_KEEP_W-1:0] m_axis_tkeep,
  output logic                   m_axis_tvalid,
  input  logic                   m_axis_tready,
  output logic                   m_axis_tlast,
  output logic                   m_axis_tuser,

  output logic                   underrun_pulse,
  output logic [63:0]            tx_pkts,
  output logic [63:0]            tx_bytes
);
  logic        active;
  logic [15:0] bytes_left;
  logic [15:0] pkt_len_q;
  logic [15:0] beat_bytes;
  logic        last_beat;

  assign s_pkt_ready   = enable && !active;
  assign beat_bytes    = bytes_this_beat(bytes_left);
  assign last_beat     = active && (bytes_left <= AXIS_KEEP_BYTES);
  assign s_axis_tready = enable && active && m_axis_tready;
  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tvalid = enable && active && s_axis_tvalid;
  assign m_axis_tlast  = last_beat;
  assign m_axis_tkeep  = last_beat ? keep_from_len(bytes_left) : {AXIS_KEEP_W{1'b1}};
  assign m_axis_tuser  = 1'b0;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      active          <= 1'b0;
      bytes_left      <= '0;
      pkt_len_q       <= '0;
      underrun_pulse  <= 1'b0;
      tx_pkts         <= '0;
      tx_bytes        <= '0;
    end else begin
      underrun_pulse <= 1'b0;

      if (clear) begin
        active     <= 1'b0;
        bytes_left <= '0;
        pkt_len_q  <= '0;
        tx_pkts    <= '0;
        tx_bytes   <= '0;
      end else begin
        if (s_pkt_valid && s_pkt_ready) begin
          active     <= 1'b1;
          bytes_left <= s_pkt_len;
          pkt_len_q  <= s_pkt_len;
        end

        if (enable && active && m_axis_tready && !s_axis_tvalid) begin
          underrun_pulse <= 1'b1;
        end

        if (m_axis_tvalid && m_axis_tready) begin
          if (last_beat) begin
            active     <= 1'b0;
            bytes_left <= '0;
            tx_pkts    <= tx_pkts + 64'd1;
            tx_bytes   <= tx_bytes + {48'd0, pkt_len_q};
          end else begin
            bytes_left <= bytes_left - AXIS_KEEP_BYTES;
          end
        end
      end
    end
  end
endmodule
