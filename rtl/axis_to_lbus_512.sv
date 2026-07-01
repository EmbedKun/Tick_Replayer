`timescale 1ns/1ps

module axis_to_lbus_512 #(
  parameter int DATA_W = 512,
  parameter int KEEP_W = DATA_W / 8,
  parameter int SEG_COUNT = 4,
  parameter int SEG_DATA_W = DATA_W / SEG_COUNT,
  parameter int SEG_KEEP_W = KEEP_W / SEG_COUNT,
  parameter int FIFO_DEPTH = 8
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS, ASSOCIATED_RESET resetn" *)
  input  wire                  clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                  resetn,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
  input  wire [DATA_W-1:0]     s_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *)
  input  wire [KEEP_W-1:0]     s_axis_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
  input  wire                  s_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
  output wire                  s_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
  input  wire                  s_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TUSER" *)
  (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 64, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1" *)
  input  wire                  s_axis_tuser,

  output wire [SEG_DATA_W-1:0] tx_datain0,
  output wire [SEG_DATA_W-1:0] tx_datain1,
  output wire [SEG_DATA_W-1:0] tx_datain2,
  output wire [SEG_DATA_W-1:0] tx_datain3,
  output wire                  tx_enain0,
  output wire                  tx_enain1,
  output wire                  tx_enain2,
  output wire                  tx_enain3,
  output wire                  tx_sopin0,
  output wire                  tx_sopin1,
  output wire                  tx_sopin2,
  output wire                  tx_sopin3,
  output wire                  tx_eopin0,
  output wire                  tx_eopin1,
  output wire                  tx_eopin2,
  output wire                  tx_eopin3,
  output wire [3:0]            tx_mtyin0,
  output wire [3:0]            tx_mtyin1,
  output wire [3:0]            tx_mtyin2,
  output wire [3:0]            tx_mtyin3,
  output wire                  tx_errin0,
  output wire                  tx_errin1,
  output wire                  tx_errin2,
  output wire                  tx_errin3,
  input  wire                  tx_rdyout,
  input  wire                  tx_ovfout,
  input  wire                  tx_unfout
);
  localparam int SEG_BYTE_W = SEG_DATA_W / 8;
  localparam logic [4:0] SEG_KEEP_W_5 = SEG_KEEP_W;
  localparam int FIFO_PTR_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
  localparam int FIFO_COUNT_W = $clog2(FIFO_DEPTH + 1);
  localparam logic [FIFO_COUNT_W-1:0] FIFO_DEPTH_LEVEL = FIFO_DEPTH;
  localparam logic [FIFO_PTR_W-1:0] FIFO_LAST_PTR = FIFO_DEPTH - 1;

  (* shreg_extract = "no" *) logic [SEG_DATA_W-1:0] data0_mem [0:FIFO_DEPTH-1];
  (* shreg_extract = "no" *) logic [SEG_DATA_W-1:0] data1_mem [0:FIFO_DEPTH-1];
  (* shreg_extract = "no" *) logic [SEG_DATA_W-1:0] data2_mem [0:FIFO_DEPTH-1];
  (* shreg_extract = "no" *) logic [SEG_DATA_W-1:0] data3_mem [0:FIFO_DEPTH-1];
  (* shreg_extract = "no" *) logic [SEG_COUNT-1:0]  ena_mem   [0:FIFO_DEPTH-1];
  (* shreg_extract = "no" *) logic [SEG_COUNT-1:0]  sop_mem   [0:FIFO_DEPTH-1];
  (* shreg_extract = "no" *) logic [SEG_COUNT-1:0]  eop_mem   [0:FIFO_DEPTH-1];
  (* shreg_extract = "no" *) logic [SEG_COUNT-1:0]  err_mem   [0:FIFO_DEPTH-1];
  (* shreg_extract = "no" *) logic [15:0]           mty_mem   [0:FIFO_DEPTH-1];

  logic [FIFO_PTR_W-1:0] wr_ptr_q;
  logic [FIFO_PTR_W-1:0] rd_ptr_q;
  logic [FIFO_COUNT_W-1:0] fifo_count_q;
  logic              in_packet_q;
  logic              out_valid_q;
  logic              s_axis_tready_q;

  logic [SEG_DATA_W-1:0] tx_datain0_q;
  logic [SEG_DATA_W-1:0] tx_datain1_q;
  logic [SEG_DATA_W-1:0] tx_datain2_q;
  logic [SEG_DATA_W-1:0] tx_datain3_q;
  logic [SEG_COUNT-1:0]  tx_ena_q;
  logic [SEG_COUNT-1:0]  tx_sop_q;
  logic [SEG_COUNT-1:0]  tx_eop_q;
  logic [SEG_COUNT-1:0]  tx_err_q;
  logic [3:0]            tx_mty_q [0:SEG_COUNT-1];
  logic                  resetn_pipe1 = 1'b0;
  logic                  resetn_pipe2 = 1'b0;

  wire load_fire = s_axis_tvalid && s_axis_tready;
  wire consume_fire = out_valid_q && tx_rdyout;
  wire pop_fifo = (fifo_count_q != '0) && (!out_valid_q || consume_fire);

  assign s_axis_tready = s_axis_tready_q;

  function automatic logic [FIFO_PTR_W-1:0] inc_fifo_ptr(input logic [FIFO_PTR_W-1:0] ptr);
    begin
      if (ptr == FIFO_LAST_PTR) begin
        inc_fifo_ptr = '0;
      end else begin
        inc_fifo_ptr = ptr + {{(FIFO_PTR_W-1){1'b0}}, 1'b1};
      end
    end
  endfunction

  function automatic [SEG_DATA_W-1:0] map_axis_segment(
    input logic [DATA_W-1:0] axis_data,
    input int unsigned seg
  );
    automatic logic [SEG_DATA_W-1:0] out_data;
    begin
      out_data = '0;
      for (int i = 0; i < SEG_BYTE_W; i++) begin
        out_data[i*8 +: 8] = axis_data[((seg + 1) * SEG_DATA_W - 8 - (i * 8)) +: 8];
      end
      map_axis_segment = out_data;
    end
  endfunction

  function automatic logic segment_valid(
    input logic [KEEP_W-1:0] keep,
    input int unsigned seg
  );
    begin
      segment_valid = |keep[seg*SEG_KEEP_W +: SEG_KEEP_W];
    end
  endfunction

  function automatic logic segment_eop(
    input logic [KEEP_W-1:0] keep,
    input logic last,
    input int unsigned seg
  );
    automatic logic higher_valid;
    begin
      higher_valid = 1'b0;
      for (int j = seg + 1; j < SEG_COUNT; j++) begin
        higher_valid |= segment_valid(keep, j);
      end
      segment_eop = last && segment_valid(keep, seg) && !higher_valid;
    end
  endfunction

  function automatic [3:0] segment_mty(
    input logic [KEEP_W-1:0] keep,
    input logic last,
    input int unsigned seg
  );
    automatic logic [4:0] valid_bytes;
    automatic logic [4:0] empty_bytes;
    begin
      valid_bytes = 5'd0;
      empty_bytes = 5'd0;
      for (int i = 0; i < SEG_KEEP_W; i++) begin
        valid_bytes = valid_bytes + {4'd0, keep[seg*SEG_KEEP_W + i]};
      end
      if (segment_eop(keep, last, seg)) begin
        empty_bytes = SEG_KEEP_W_5 - valid_bytes;
        segment_mty = empty_bytes[3:0];
      end else begin
        segment_mty = 4'd0;
      end
    end
  endfunction

  wire [SEG_COUNT-1:0] in_seg_valid_w;
  wire [SEG_COUNT-1:0] in_seg_eop_w;
  wire [SEG_COUNT-1:0] in_seg_sop_w;
  wire [SEG_COUNT-1:0] in_seg_err_w;
  wire [3:0] in_seg_mty_w [0:SEG_COUNT-1];

  genvar g;
  generate
    for (g = 0; g < SEG_COUNT; g = g + 1) begin : gen_seg_flags
      assign in_seg_valid_w[g] = segment_valid(s_axis_tkeep, g);
      assign in_seg_eop_w[g]   = segment_eop(s_axis_tkeep, s_axis_tlast, g);
      assign in_seg_sop_w[g]   = (g == 0) && !in_packet_q && in_seg_valid_w[g];
      assign in_seg_err_w[g]   = in_seg_eop_w[g] && s_axis_tuser;
      assign in_seg_mty_w[g]   = segment_mty(s_axis_tkeep, s_axis_tlast, g);
    end
  endgenerate

  assign tx_datain0 = tx_datain0_q;
  assign tx_datain1 = tx_datain1_q;
  assign tx_datain2 = tx_datain2_q;
  assign tx_datain3 = tx_datain3_q;

  assign tx_enain0 = out_valid_q && tx_ena_q[0];
  assign tx_enain1 = out_valid_q && tx_ena_q[1];
  assign tx_enain2 = out_valid_q && tx_ena_q[2];
  assign tx_enain3 = out_valid_q && tx_ena_q[3];

  assign tx_sopin0 = out_valid_q && tx_sop_q[0];
  assign tx_sopin1 = out_valid_q && tx_sop_q[1];
  assign tx_sopin2 = out_valid_q && tx_sop_q[2];
  assign tx_sopin3 = out_valid_q && tx_sop_q[3];

  assign tx_eopin0 = out_valid_q && tx_eop_q[0];
  assign tx_eopin1 = out_valid_q && tx_eop_q[1];
  assign tx_eopin2 = out_valid_q && tx_eop_q[2];
  assign tx_eopin3 = out_valid_q && tx_eop_q[3];

  assign tx_mtyin0 = tx_mty_q[0];
  assign tx_mtyin1 = tx_mty_q[1];
  assign tx_mtyin2 = tx_mty_q[2];
  assign tx_mtyin3 = tx_mty_q[3];

  assign tx_errin0 = out_valid_q && tx_err_q[0];
  assign tx_errin1 = out_valid_q && tx_err_q[1];
  assign tx_errin2 = out_valid_q && tx_err_q[2];
  assign tx_errin3 = out_valid_q && tx_err_q[3];

  always_ff @(posedge clk) begin
    resetn_pipe1 <= resetn;
    resetn_pipe2 <= resetn_pipe1;

    if (!resetn_pipe2) begin
      wr_ptr_q     <= '0;
      rd_ptr_q     <= '0;
      fifo_count_q <= '0;
      in_packet_q <= 1'b0;
      out_valid_q <= 1'b0;
      s_axis_tready_q <= 1'b0;
      tx_datain0_q <= '0;
      tx_datain1_q <= '0;
      tx_datain2_q <= '0;
      tx_datain3_q <= '0;
      tx_ena_q <= '0;
      tx_sop_q <= '0;
      tx_eop_q <= '0;
      tx_err_q <= '0;
      tx_mty_q[0] <= '0;
      tx_mty_q[1] <= '0;
      tx_mty_q[2] <= '0;
      tx_mty_q[3] <= '0;
    end else begin
      s_axis_tready_q <= (fifo_count_q != FIFO_DEPTH_LEVEL);

      if (load_fire) begin
        data0_mem[wr_ptr_q] <= map_axis_segment(s_axis_tdata, 0);
        data1_mem[wr_ptr_q] <= map_axis_segment(s_axis_tdata, 1);
        data2_mem[wr_ptr_q] <= map_axis_segment(s_axis_tdata, 2);
        data3_mem[wr_ptr_q] <= map_axis_segment(s_axis_tdata, 3);
        ena_mem[wr_ptr_q]   <= in_seg_valid_w;
        sop_mem[wr_ptr_q]   <= in_seg_sop_w;
        eop_mem[wr_ptr_q]   <= in_seg_eop_w;
        err_mem[wr_ptr_q]   <= in_seg_err_w;
        mty_mem[wr_ptr_q]   <= {in_seg_mty_w[3], in_seg_mty_w[2], in_seg_mty_w[1], in_seg_mty_w[0]};
        wr_ptr_q            <= inc_fifo_ptr(wr_ptr_q);
        in_packet_q         <= !s_axis_tlast;
      end

      if (pop_fifo) begin
        tx_datain0_q <= data0_mem[rd_ptr_q];
        tx_datain1_q <= data1_mem[rd_ptr_q];
        tx_datain2_q <= data2_mem[rd_ptr_q];
        tx_datain3_q <= data3_mem[rd_ptr_q];
        tx_ena_q     <= ena_mem[rd_ptr_q];
        tx_sop_q     <= sop_mem[rd_ptr_q];
        tx_eop_q     <= eop_mem[rd_ptr_q];
        tx_err_q     <= err_mem[rd_ptr_q];
        tx_mty_q[0]  <= mty_mem[rd_ptr_q][3:0];
        tx_mty_q[1]  <= mty_mem[rd_ptr_q][7:4];
        tx_mty_q[2]  <= mty_mem[rd_ptr_q][11:8];
        tx_mty_q[3]  <= mty_mem[rd_ptr_q][15:12];
        rd_ptr_q <= inc_fifo_ptr(rd_ptr_q);
        out_valid_q <= 1'b1;
      end else if (consume_fire) begin
        out_valid_q <= 1'b0;
      end

      unique case ({load_fire, pop_fifo})
        2'b10: fifo_count_q <= fifo_count_q + {{(FIFO_COUNT_W-1){1'b0}}, 1'b1};
        2'b01: fifo_count_q <= fifo_count_q - {{(FIFO_COUNT_W-1){1'b0}}, 1'b1};
        default: begin
        end
      endcase

      if (!load_fire && (fifo_count_q == '0) && !out_valid_q) begin
        in_packet_q <= 1'b0;
      end
    end
  end

  wire unused_status = tx_ovfout ^ tx_unfout;
endmodule
