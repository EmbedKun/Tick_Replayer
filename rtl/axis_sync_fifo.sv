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
  localparam int ADDR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
  localparam int COUNT_W = $clog2(DEPTH + 1);
  localparam int PAYLOAD_W = DATA_W + KEEP_W + 1;
  localparam int RAM_READ_LATENCY = 2;
  localparam int OUT_DEPTH = 4;
  localparam int OUT_PTR_W = 2;
  localparam int OUT_COUNT_W = 3;
  localparam int READY_MARGIN_RAW = OUT_DEPTH + RAM_READ_LATENCY + 4;
  localparam int READY_MARGIN = (DEPTH > READY_MARGIN_RAW) ? READY_MARGIN_RAW : 1;

  localparam logic [COUNT_W-1:0] DEPTH_LEVEL = DEPTH;
  localparam logic [COUNT_W-1:0] ONE_LEVEL = {{(COUNT_W-1){1'b0}}, 1'b1};
  localparam logic [COUNT_W-1:0] READY_LEVEL = DEPTH - READY_MARGIN;
  localparam logic [ADDR_W-1:0] LAST_ADDR = DEPTH - 1;
  localparam logic [OUT_COUNT_W-1:0] OUT_DEPTH_LEVEL = OUT_DEPTH;

  logic [ADDR_W-1:0] wr_ptr;
  logic [ADDR_W-1:0] rd_ptr;
  logic [COUNT_W-1:0] ram_count;
  logic [RAM_READ_LATENCY-1:0] rd_valid_pipe;
  logic [OUT_PTR_W-1:0] out_wr_ptr;
  logic [OUT_PTR_W-1:0] out_rd_ptr;
  logic [OUT_COUNT_W-1:0] out_count;
  logic [PAYLOAD_W-1:0] out_mem [0:OUT_DEPTH-1];
  logic [PAYLOAD_W-1:0] out_payload_reg;
  logic                 out_valid_reg;
  logic                 s_axis_tready_q;
  logic [PAYLOAD_W-1:0] ram_dout;

  logic [OUT_COUNT_W-1:0] outstanding_count;
  logic [OUT_COUNT_W-1:0] buffered_count;
  logic [COUNT_W-1:0] total_level;
  logic wr_fire;
  logic rd_issue;
  logic ram_return_valid;
  logic out_reg_ready;
  logic out_pop;
  logic out_fire;

  function automatic logic [ADDR_W-1:0] inc_ptr(input logic [ADDR_W-1:0] ptr);
    if (ptr == LAST_ADDR) begin
      inc_ptr = '0;
    end else begin
      inc_ptr = ptr + {{(ADDR_W-1){1'b0}}, 1'b1};
    end
  endfunction

  assign outstanding_count =
    {{(OUT_COUNT_W-1){1'b0}}, rd_valid_pipe[0]} +
    {{(OUT_COUNT_W-1){1'b0}}, rd_valid_pipe[1]};
  assign buffered_count = outstanding_count + out_count;
  assign total_level = ram_count +
                       {{(COUNT_W-OUT_COUNT_W){1'b0}}, buffered_count} +
                       {{(COUNT_W-1){1'b0}}, out_valid_reg};

  assign s_axis_tready = s_axis_tready_q;
  assign wr_fire = s_axis_tvalid && s_axis_tready;
  assign rd_issue = (ram_count != '0) && (buffered_count < OUT_DEPTH_LEVEL);
  assign ram_return_valid = rd_valid_pipe[RAM_READ_LATENCY-1];

  assign out_reg_ready = !out_valid_reg || m_axis_tready;
  assign out_pop = (out_count != '0) && out_reg_ready;
  assign out_fire = out_valid_reg && m_axis_tready;

  assign m_axis_tvalid = out_valid_reg;
  assign {m_axis_tlast, m_axis_tkeep, m_axis_tdata} = out_payload_reg;
  assign level = total_level;

  xpm_memory_sdpram #(
    .ADDR_WIDTH_A(ADDR_W),
    .ADDR_WIDTH_B(ADDR_W),
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(PAYLOAD_W),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("common_clock"),
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("true"),
    .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(PAYLOAD_W * DEPTH),
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_B(PAYLOAD_W),
    .READ_LATENCY_B(RAM_READ_LATENCY),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_A("SYNC"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(0),
    .USE_MEM_INIT_MMI(0),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(PAYLOAD_W),
    .WRITE_MODE_B("no_change"),
    .WRITE_PROTECT(1)
  ) payload_ram (
    .sleep(1'b0),
    .clka(clk),
    .ena(1'b1),
    .wea(wr_fire),
    .addra(wr_ptr),
    .dina({s_axis_tlast, s_axis_tkeep, s_axis_tdata}),
    .injectsbiterra(1'b0),
    .injectdbiterra(1'b0),
    .clkb(clk),
    .rstb(1'b0),
    .enb(1'b1),
    .regceb(1'b1),
    .addrb(rd_ptr),
    .doutb(ram_dout),
    .sbiterrb(),
    .dbiterrb()
  );

  always_ff @(posedge clk) begin
    if (!rstn) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      ram_count <= '0;
      rd_valid_pipe <= '0;
      out_wr_ptr <= '0;
      out_rd_ptr <= '0;
      out_count <= '0;
      out_payload_reg <= '0;
      out_valid_reg <= 1'b0;
      s_axis_tready_q <= 1'b0;
    end else begin
      if (clear) begin
        wr_ptr <= '0;
        rd_ptr <= '0;
        ram_count <= '0;
        rd_valid_pipe <= '0;
        out_wr_ptr <= '0;
        out_rd_ptr <= '0;
        out_count <= '0;
        out_payload_reg <= '0;
        out_valid_reg <= 1'b0;
        s_axis_tready_q <= 1'b0;
      end else begin
        rd_valid_pipe <= {rd_valid_pipe[RAM_READ_LATENCY-2:0], rd_issue};
        s_axis_tready_q <= (total_level <= READY_LEVEL);

        if (wr_fire) begin
          wr_ptr <= inc_ptr(wr_ptr);
        end
        if (rd_issue) begin
          rd_ptr <= inc_ptr(rd_ptr);
        end

        unique case ({wr_fire, rd_issue})
          2'b10: ram_count <= ram_count + ONE_LEVEL;
          2'b01: ram_count <= ram_count - ONE_LEVEL;
          default: ram_count <= ram_count;
        endcase

        if (out_pop) begin
          out_payload_reg <= out_mem[out_rd_ptr];
          out_valid_reg <= 1'b1;
          out_rd_ptr <= out_rd_ptr + {{(OUT_PTR_W-1){1'b0}}, 1'b1};
        end else if (out_fire) begin
          out_valid_reg <= 1'b0;
        end

        if (ram_return_valid) begin
          out_mem[out_wr_ptr] <= ram_dout;
          out_wr_ptr <= out_wr_ptr + {{(OUT_PTR_W-1){1'b0}}, 1'b1};
        end

        unique case ({ram_return_valid, out_pop})
          2'b10: out_count <= out_count + {{(OUT_COUNT_W-1){1'b0}}, 1'b1};
          2'b01: out_count <= out_count - {{(OUT_COUNT_W-1){1'b0}}, 1'b1};
          default: out_count <= out_count;
        endcase
      end
    end
  end
endmodule
