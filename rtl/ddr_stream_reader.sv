`timescale 1ns/1ps

import traffic_replay_pkg::*;

module ddr_stream_reader #(
  parameter int AXI_ADDR_W_P = AXI_ADDR_W,
  parameter int AXI_ID_W_P   = AXI_ID_W,
  parameter int MAX_BURST_BEATS = 16
) (
  input  logic                     clk,
  input  logic                     rstn,
  input  logic                     start,
  input  logic                     stop,
  input  logic                     clear,
  input  logic [63:0]              cfg_stream_base,
  input  logic [63:0]              cfg_stream_bytes,

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
  output logic [3:0]               debug_state
);
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_AR,
    ST_R,
    ST_DONE
  } state_t;

  state_t state;
  localparam logic [63:0] MAX_BURST_BEATS_U64 = MAX_BURST_BEATS;
  localparam logic [8:0]  MAX_BURST_BEATS_U9  = MAX_BURST_BEATS;
  logic [63:0] beats_remaining;
  logic [7:0]  burst_beats_left;
  logic [8:0]  burst_beats_next;
  logic [15:0] final_keep_bytes;
  logic        final_partial_beat;
  logic        last_stream_beat;

  assign final_partial_beat = (cfg_stream_bytes[5:0] != 6'd0);
  assign final_keep_bytes   = final_partial_beat ? {10'd0, cfg_stream_bytes[5:0]} : AXIS_KEEP_BYTES;
  assign last_stream_beat   = (beats_remaining == 64'd1);

  always_comb begin
    if (beats_remaining > MAX_BURST_BEATS_U64) begin
      burst_beats_next = MAX_BURST_BEATS_U9;
    end else begin
      burst_beats_next = beats_remaining[8:0];
    end
  end

  assign m_axi_arid    = '0;
  assign m_axi_arsize  = 3'd6;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arvalid = (state == ST_AR);
  assign m_axi_arlen   = (burst_beats_next == 9'd0) ? 8'd0 : burst_beats_next[7:0] - 8'd1;

  assign m_axi_rready  = (state == ST_R) && m_axis_tready;

  assign m_axis_tdata  = m_axi_rdata;
  assign m_axis_tvalid = (state == ST_R) && m_axi_rvalid;
  assign m_axis_tkeep  = (last_stream_beat && final_partial_beat) ? keep_from_len(final_keep_bytes) : {AXIS_KEEP_W{1'b1}};
  assign m_axis_tlast  = last_stream_beat;
  assign debug_state   = state;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      state            <= ST_IDLE;
      m_axi_araddr     <= '0;
      beats_remaining  <= '0;
      burst_beats_left <= '0;
      busy             <= 1'b0;
      done             <= 1'b0;
      error            <= 1'b0;
    end else begin
      if (clear || stop) begin
        state            <= ST_IDLE;
        m_axi_araddr     <= '0;
        beats_remaining  <= '0;
        burst_beats_left <= '0;
        busy             <= 1'b0;
        done             <= 1'b0;
        error            <= 1'b0;
      end else begin
        unique case (state)
          ST_IDLE: begin
            done <= 1'b0;
            if (start && (cfg_stream_bytes != 64'd0)) begin
              m_axi_araddr    <= cfg_stream_base[AXI_ADDR_W_P-1:0];
              beats_remaining <= cfg_stream_bytes[63:6] + {63'd0, |cfg_stream_bytes[5:0]};
              busy            <= 1'b1;
              error           <= final_partial_beat;
              state           <= ST_AR;
            end
          end
          ST_AR: begin
            if (m_axi_arvalid && m_axi_arready) begin
              burst_beats_left <= burst_beats_next[7:0];
              state            <= ST_R;
            end
          end
          ST_R: begin
            if (m_axis_tvalid && m_axis_tready) begin
              error           <= error | (m_axi_rresp != 2'b00);
              m_axi_araddr    <= m_axi_araddr + AXIS_KEEP_BYTES;
              beats_remaining <= beats_remaining - 64'd1;

              if (burst_beats_left <= 8'd1) begin
                if (beats_remaining <= 64'd1) begin
                  busy  <= 1'b0;
                  done  <= 1'b1;
                  state <= ST_DONE;
                end else begin
                  state <= ST_AR;
                end
              end else begin
                burst_beats_left <= burst_beats_left - 8'd1;
              end
            end
          end
          ST_DONE: begin
            done <= 1'b1;
            if (start && (cfg_stream_bytes != 64'd0)) begin
              m_axi_araddr    <= cfg_stream_base[AXI_ADDR_W_P-1:0];
              beats_remaining <= cfg_stream_bytes[63:6] + {63'd0, |cfg_stream_bytes[5:0]};
              burst_beats_left <= '0;
              busy            <= 1'b1;
              done            <= 1'b0;
              error           <= final_partial_beat;
              state           <= ST_AR;
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
