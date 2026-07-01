`timescale 1ns/1ps

module lbus_to_axis_512 #(
  parameter int DATA_W = 512,
  parameter int KEEP_W = DATA_W / 8,
  parameter int SEG_COUNT = 4,
  parameter int SEG_DATA_W = DATA_W / SEG_COUNT,
  parameter int SEG_KEEP_W = KEEP_W / SEG_COUNT
) (
  input  wire                  clk,
  input  wire                  resetn,

  input  wire [SEG_DATA_W-1:0] rx_dataout0,
  input  wire [SEG_DATA_W-1:0] rx_dataout1,
  input  wire [SEG_DATA_W-1:0] rx_dataout2,
  input  wire [SEG_DATA_W-1:0] rx_dataout3,
  input  wire                  rx_enaout0,
  input  wire                  rx_enaout1,
  input  wire                  rx_enaout2,
  input  wire                  rx_enaout3,
  input  wire                  rx_sopout0,
  input  wire                  rx_sopout1,
  input  wire                  rx_sopout2,
  input  wire                  rx_sopout3,
  input  wire                  rx_eopout0,
  input  wire                  rx_eopout1,
  input  wire                  rx_eopout2,
  input  wire                  rx_eopout3,
  input  wire [3:0]            rx_mtyout0,
  input  wire [3:0]            rx_mtyout1,
  input  wire [3:0]            rx_mtyout2,
  input  wire [3:0]            rx_mtyout3,
  input  wire                  rx_errout0,
  input  wire                  rx_errout1,
  input  wire                  rx_errout2,
  input  wire                  rx_errout3,

  output logic [DATA_W-1:0]    m_axis_tdata,
  output logic [KEEP_W-1:0]    m_axis_tkeep,
  output logic                 m_axis_tvalid,
  output logic                 m_axis_tlast,
  output logic                 m_axis_tuser
);
  localparam int SEG_BYTE_W = SEG_DATA_W / 8;
  localparam logic [4:0] SEG_KEEP_W_5 = SEG_KEEP_W;

  logic [SEG_DATA_W-1:0] seg_data [0:SEG_COUNT-1];
  logic [SEG_COUNT-1:0] seg_ena;
  logic [SEG_COUNT-1:0] seg_sop;
  logic [SEG_COUNT-1:0] seg_eop;
  logic [3:0] seg_mty [0:SEG_COUNT-1];
  logic [SEG_COUNT-1:0] seg_err;

  always_comb begin
    seg_data[0] = rx_dataout0;
    seg_data[1] = rx_dataout1;
    seg_data[2] = rx_dataout2;
    seg_data[3] = rx_dataout3;
    seg_ena = {rx_enaout3, rx_enaout2, rx_enaout1, rx_enaout0};
    seg_sop = {rx_sopout3, rx_sopout2, rx_sopout1, rx_sopout0};
    seg_eop = {rx_eopout3, rx_eopout2, rx_eopout1, rx_eopout0};
    seg_mty[0] = rx_mtyout0;
    seg_mty[1] = rx_mtyout1;
    seg_mty[2] = rx_mtyout2;
    seg_mty[3] = rx_mtyout3;
    seg_err = {rx_errout3, rx_errout2, rx_errout1, rx_errout0};
  end

  function automatic [SEG_DATA_W-1:0] map_lbus_segment(
    input logic [SEG_DATA_W-1:0] lbus_data
  );
    automatic logic [SEG_DATA_W-1:0] out_data;
    begin
      out_data = '0;
      for (int i = 0; i < SEG_BYTE_W; i++) begin
        out_data[SEG_DATA_W - 8 - (i * 8) +: 8] = lbus_data[i*8 +: 8];
      end
      map_lbus_segment = out_data;
    end
  endfunction

  function automatic [SEG_KEEP_W-1:0] keep_from_mty(
    input logic ena,
    input logic eop,
    input logic [3:0] mty
  );
    automatic logic [SEG_KEEP_W-1:0] keep;
    automatic logic [4:0] valid_bytes;
    begin
      keep = '0;
      if (ena) begin
        if (eop) begin
          valid_bytes = SEG_KEEP_W_5 - {1'b0, mty};
        end else begin
          valid_bytes = SEG_KEEP_W_5;
        end
        for (int i = 0; i < SEG_KEEP_W; i++) begin
          keep[i] = (i < valid_bytes);
        end
      end
      keep_from_mty = keep;
    end
  endfunction

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      m_axis_tdata  <= '0;
      m_axis_tkeep  <= '0;
      m_axis_tvalid <= 1'b0;
      m_axis_tlast  <= 1'b0;
      m_axis_tuser  <= 1'b0;
    end else begin
      m_axis_tvalid <= |seg_ena;
      m_axis_tlast  <= |seg_eop;
      m_axis_tuser  <= |(seg_err & seg_ena);

      for (int seg = 0; seg < SEG_COUNT; seg++) begin
        m_axis_tdata[seg*SEG_DATA_W +: SEG_DATA_W] <= map_lbus_segment(seg_data[seg]);
        m_axis_tkeep[seg*SEG_KEEP_W +: SEG_KEEP_W] <= keep_from_mty(seg_ena[seg], seg_eop[seg], seg_mty[seg]);
      end
    end
  end

  wire unused_sop = ^seg_sop;
endmodule
