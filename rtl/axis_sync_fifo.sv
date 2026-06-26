`timescale 1ns/1ps

module axis_sync_fifo #(
  parameter int DATA_W = 512,
  parameter int KEEP_W = DATA_W / 8,
  parameter int DEPTH  = 1024
) (
  input  logic                         clk,
  input  logic                         rstn,
  input  logic                         clear,

  input  logic [DATA_W-1:0]            s_axis_tdata,
  input  logic [KEEP_W-1:0]            s_axis_tkeep,
  input  logic                         s_axis_tvalid,
  output logic                         s_axis_tready,
  input  logic                         s_axis_tlast,

  output logic [DATA_W-1:0]            m_axis_tdata,
  output logic [KEEP_W-1:0]            m_axis_tkeep,
  output logic                         m_axis_tvalid,
  input  logic                         m_axis_tready,
  output logic                         m_axis_tlast,

  output logic [$clog2(DEPTH+1)-1:0]   level
);
  localparam int ADDR_W = $clog2(DEPTH);
  localparam int COUNT_W = $clog2(DEPTH + 1);
  localparam logic [COUNT_W-1:0] DEPTH_LEVEL = DEPTH;
  localparam logic [COUNT_W-1:0] LEVEL_ONE = 1;

  logic [DATA_W-1:0] data_mem [DEPTH];
  logic [KEEP_W-1:0] keep_mem [DEPTH];
  logic              last_mem [DEPTH];
  logic [ADDR_W-1:0] wr_ptr;
  logic [ADDR_W-1:0] rd_ptr;
  logic              write_en;
  logic              read_en;

  assign s_axis_tready = (level != DEPTH_LEVEL);
  assign m_axis_tvalid = (level != '0);
  assign write_en      = s_axis_tvalid && s_axis_tready;
  assign read_en       = m_axis_tvalid && m_axis_tready;

  assign m_axis_tdata = data_mem[rd_ptr];
  assign m_axis_tkeep = keep_mem[rd_ptr];
  assign m_axis_tlast = last_mem[rd_ptr];

  always_ff @(posedge clk) begin
    if (!rstn) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      level  <= '0;
    end else begin
      if (clear) begin
        wr_ptr <= '0;
        rd_ptr <= '0;
        level  <= '0;
      end else begin
        if (write_en) begin
          data_mem[wr_ptr] <= s_axis_tdata;
          keep_mem[wr_ptr] <= s_axis_tkeep;
          last_mem[wr_ptr] <= s_axis_tlast;
          wr_ptr           <= wr_ptr + {{(ADDR_W-1){1'b0}}, 1'b1};
        end

        if (read_en) begin
          rd_ptr <= rd_ptr + {{(ADDR_W-1){1'b0}}, 1'b1};
        end

        unique case ({write_en, read_en})
          2'b10: level <= level + LEVEL_ONE;
          2'b01: level <= level - LEVEL_ONE;
          default: level <= level;
        endcase
      end
    end
  end
endmodule
