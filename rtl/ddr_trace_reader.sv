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
  output logic                     error
);
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_DESC_AR,
    ST_DESC_R,
    ST_META,
    ST_PAYLOAD_AR,
    ST_PAYLOAD_R,
    ST_NEXT,
    ST_DONE
  } state_t;

  state_t state;
  logic [63:0] pkt_index;
  logic [63:0] loops_done;
  logic [63:0] payload_word_offset;
  logic [15:0] payload_len;
  logic [15:0] payload_flags;
  logic [15:0] payload_bytes_left;
  logic [15:0] beats_needed;
  logic        loop_gap_pending;
  logic        infinite_loop;
  logic        last_payload_beat;

  assign infinite_loop     = loop_mode && (cfg_loop_count == 64'd0);
  assign beats_needed      = (payload_len[5:0] == 6'd0) ? (payload_len >> 6) : ((payload_len >> 6) + 16'd1);
  assign last_payload_beat = (payload_bytes_left <= AXIS_KEEP_BYTES);

  assign m_axi_arid    = '0;
  assign m_axi_arsize  = 3'd6;
  assign m_axi_arburst = 2'b01;

  assign m_meta_valid = (state == ST_META);
  assign m_meta_len   = payload_len;
  assign m_meta_flags = payload_flags;

  assign m_axis_tdata  = m_axi_rdata;
  assign m_axis_tvalid = (state == ST_PAYLOAD_R) && m_axi_rvalid;
  assign m_axis_tkeep  = last_payload_beat ? keep_from_len(payload_bytes_left) : {AXIS_KEEP_W{1'b1}};
  assign m_axis_tlast  = last_payload_beat;

  always_comb begin
    m_axi_arvalid = 1'b0;
    m_axi_araddr  = '0;
    m_axi_arlen   = 8'd0;
    m_axi_rready  = 1'b0;

    unique case (state)
      ST_DESC_AR: begin
        m_axi_arvalid = 1'b1;
        m_axi_araddr  = cfg_desc_base + (pkt_index << DESC_WORD_SHIFT);
        m_axi_arlen   = 8'd0;
      end
      ST_DESC_R: begin
        m_axi_rready = 1'b1;
      end
      ST_PAYLOAD_AR: begin
        m_axi_arvalid = 1'b1;
        m_axi_araddr  = cfg_data_base + (payload_word_offset << DESC_WORD_SHIFT);
        m_axi_arlen   = (beats_needed == 16'd0) ? 8'd0 : beats_needed[7:0] - 8'd1;
      end
      ST_PAYLOAD_R: begin
        m_axi_rready = m_axis_tready;
      end
      default: begin
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      state               <= ST_IDLE;
      pkt_index           <= '0;
      loops_done          <= '0;
      payload_word_offset <= '0;
      payload_len         <= '0;
      payload_flags       <= '0;
      payload_bytes_left  <= '0;
      m_meta_gap_ticks    <= '0;
      loop_gap_pending    <= 1'b0;
      busy                <= 1'b0;
      done                <= 1'b0;
      error               <= 1'b0;
    end else begin
      if (clear || stop) begin
        state            <= ST_IDLE;
        pkt_index        <= '0;
        loops_done       <= '0;
        busy             <= 1'b0;
        done             <= 1'b0;
        error            <= 1'b0;
        loop_gap_pending <= 1'b0;
      end else begin
        unique case (state)
          ST_IDLE: begin
            done <= 1'b0;
            if (start && (cfg_pkt_count != 64'd0)) begin
              busy             <= 1'b1;
              pkt_index        <= '0;
              loops_done       <= '0;
              loop_gap_pending <= 1'b0;
              state            <= ST_DESC_AR;
            end
          end
          ST_DESC_AR: begin
            if (m_axi_arvalid && m_axi_arready) begin
              state <= ST_DESC_R;
            end
          end
          ST_DESC_R: begin
            if (m_axi_rvalid && m_axi_rready) begin
              m_meta_gap_ticks    <= loop_gap_pending ? cfg_loop_gap_ticks : m_axi_rdata[63:0];
              payload_word_offset <= {32'd0, m_axi_rdata[95:64]};
              payload_len         <= m_axi_rdata[111:96];
              payload_flags       <= m_axi_rdata[127:112];
              payload_bytes_left  <= m_axi_rdata[111:96];
              loop_gap_pending    <= 1'b0;
              error               <= error | (m_axi_rresp != 2'b00);
              state               <= ST_META;
            end
          end
          ST_META: begin
            if (m_meta_ready) begin
              state <= (payload_len == 16'd0) ? ST_NEXT : ST_PAYLOAD_AR;
            end
          end
          ST_PAYLOAD_AR: begin
            if (m_axi_arvalid && m_axi_arready) begin
              state <= ST_PAYLOAD_R;
            end
          end
          ST_PAYLOAD_R: begin
            if (m_axis_tvalid && m_axis_tready) begin
              error <= error | (m_axi_rresp != 2'b00);
              if (last_payload_beat) begin
                payload_bytes_left <= '0;
                state              <= ST_NEXT;
              end else begin
                payload_bytes_left <= payload_bytes_left - AXIS_KEEP_BYTES;
              end
            end
          end
          ST_NEXT: begin
            if (pkt_index + 64'd1 < cfg_pkt_count) begin
              pkt_index <= pkt_index + 64'd1;
              state     <= ST_DESC_AR;
            end else if (loop_mode && (infinite_loop || (loops_done + 64'd1 < cfg_loop_count))) begin
              pkt_index        <= '0;
              loops_done       <= loops_done + 64'd1;
              loop_gap_pending <= 1'b1;
              state            <= ST_DESC_AR;
            end else begin
              state <= ST_DONE;
            end
          end
          ST_DONE: begin
            busy <= 1'b0;
            done <= 1'b1;
            if (start) begin
              pkt_index        <= '0;
              loops_done       <= '0;
              busy             <= 1'b1;
              done             <= 1'b0;
              loop_gap_pending <= 1'b0;
              state            <= ST_DESC_AR;
            end
          end
          default: begin
            state <= ST_IDLE;
          end
        endcase
      end
    end
  end
endmodule
