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
  generate
    if (DEPTH >= 2048) begin : gen_xpm_axis_fifo
      localparam int COUNT_W = $clog2(DEPTH + 1);

      logic [3:0]             reset_shift;
      logic                   fifo_aresetn;
      logic [KEEP_W-1:0]      unused_tstrb;
      logic                   unused_prog_full;
      logic                   unused_almost_full;
      logic                   unused_prog_empty;
      logic                   unused_almost_empty;
      logic                   unused_sbiterr;
      logic                   unused_dbiterr;
      logic [COUNT_W-1:0]     wr_data_count;
      logic [COUNT_W-1:0]     unused_rd_data_count;
      logic                   unused_tid;
      logic                   unused_tdest;
      logic                   unused_tuser;

      always_ff @(posedge clk) begin
        if (!rstn || clear) begin
          reset_shift <= 4'b0000;
        end else begin
          reset_shift <= {reset_shift[2:0], 1'b1};
        end
      end

      assign fifo_aresetn = reset_shift[3];
      assign level = wr_data_count;

      xpm_fifo_axis #(
        .CLOCKING_MODE("common_clock"),
        .FIFO_MEMORY_TYPE("block"),
        .PACKET_FIFO("false"),
        .FIFO_DEPTH(DEPTH),
        .TDATA_WIDTH(DATA_W),
        .TID_WIDTH(1),
        .TDEST_WIDTH(1),
        .TUSER_WIDTH(1),
        .SIM_ASSERT_CHK(0),
        .CASCADE_HEIGHT(0),
        .ECC_MODE("no_ecc"),
        .RELATED_CLOCKS(0),
        .USE_ADV_FEATURES("0404"),
        .WR_DATA_COUNT_WIDTH(COUNT_W),
        .RD_DATA_COUNT_WIDTH(COUNT_W),
        .PROG_FULL_THRESH(DEPTH - 8),
        .PROG_EMPTY_THRESH(8),
        .CDC_SYNC_STAGES(2)
      ) fifo_i (
        .s_aresetn(fifo_aresetn),
        .s_aclk(clk),
        .m_aclk(clk),

        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tstrb(s_axis_tkeep),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tid(1'b0),
        .s_axis_tdest(1'b0),
        .s_axis_tuser(1'b0),

        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tstrb(unused_tstrb),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tid(unused_tid),
        .m_axis_tdest(unused_tdest),
        .m_axis_tuser(unused_tuser),

        .prog_full_axis(unused_prog_full),
        .wr_data_count_axis(wr_data_count),
        .almost_full_axis(unused_almost_full),
        .prog_empty_axis(unused_prog_empty),
        .rd_data_count_axis(unused_rd_data_count),
        .almost_empty_axis(unused_almost_empty),

        .injectsbiterr_axis(1'b0),
        .injectdbiterr_axis(1'b0),
        .sbiterr_axis(unused_sbiterr),
        .dbiterr_axis(unused_dbiterr)
      );
    end else begin : gen_reg_axis_fifo
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
    end
  endgenerate
endmodule
