`timescale 1ns/1ps

module axis_async_fifo #
(
  parameter DATA_W = 512,
  parameter KEEP_W = DATA_W / 8,
  parameter USER_W = 1,
  parameter DEPTH_LOG2 = 5
)
(
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS, ASSOCIATED_RESET s_resetn" *)
  input  wire                  s_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                  s_resetn,

  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 m_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXIS, ASSOCIATED_RESET m_resetn" *)
  input  wire                  m_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 m_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                  m_resetn,
  input  wire                  clear,

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
  input  wire [USER_W-1:0]     s_axis_tuser,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
  output wire [DATA_W-1:0]     m_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TKEEP" *)
  output wire [KEEP_W-1:0]     m_axis_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
  output wire                  m_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
  input  wire                  m_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
  output wire                  m_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TUSER" *)
  (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 64, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1" *)
  output wire [USER_W-1:0]     m_axis_tuser
);
  localparam DEPTH = 1 << DEPTH_LOG2;
  localparam PTR_W = DEPTH_LOG2 + 1;
  localparam PAYLOAD_W = DATA_W + KEEP_W + USER_W + 1;
  localparam RAM_READ_LATENCY = 2;
  localparam READ_PIPE_LEN = RAM_READ_LATENCY;
  localparam OUT_DEPTH = 4;
  localparam OUT_PTR_W = 2;
  localparam OUT_COUNT_W = 3;

  wire [PAYLOAD_W-1:0] ram_dout;

  reg [PTR_W-1:0] wr_bin = {PTR_W{1'b0}};
  reg [PTR_W-1:0] wr_gray = {PTR_W{1'b0}};
  reg [PTR_W-1:0] rd_bin = {PTR_W{1'b0}};
  reg [PTR_W-1:0] rd_gray = {PTR_W{1'b0}};

  (* ASYNC_REG = "TRUE" *) reg [PTR_W-1:0] rd_gray_wclk_1 = {PTR_W{1'b0}};
  (* ASYNC_REG = "TRUE" *) reg [PTR_W-1:0] rd_gray_wclk_2 = {PTR_W{1'b0}};
  (* ASYNC_REG = "TRUE" *) reg [PTR_W-1:0] wr_gray_rclk_1 = {PTR_W{1'b0}};
  (* ASYNC_REG = "TRUE" *) reg [PTR_W-1:0] wr_gray_rclk_2 = {PTR_W{1'b0}};
  (* ASYNC_REG = "TRUE" *) reg clear_wclk_1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) reg clear_wclk_2 = 1'b0;
  (* ASYNC_REG = "TRUE" *) reg clear_rclk_1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) reg clear_rclk_2 = 1'b0;

  reg wr_full = 1'b1;
  reg [DATA_W-1:0] wr_stage_data = {DATA_W{1'b0}};
  reg [KEEP_W-1:0] wr_stage_keep = {KEEP_W{1'b0}};
  reg [USER_W-1:0] wr_stage_user = {USER_W{1'b0}};
  reg wr_stage_last = 1'b0;
  reg wr_stage_valid = 1'b0;
  reg [READ_PIPE_LEN-1:0] rd_valid_pipe = {READ_PIPE_LEN{1'b0}};
  reg [OUT_PTR_W-1:0] out_wr_ptr = {OUT_PTR_W{1'b0}};
  reg [OUT_PTR_W-1:0] out_rd_ptr = {OUT_PTR_W{1'b0}};
  reg [OUT_COUNT_W-1:0] out_count = {OUT_COUNT_W{1'b0}};
  reg [PAYLOAD_W-1:0] out_mem [0:OUT_DEPTH-1];
  reg [PAYLOAD_W-1:0] out_payload_reg = {PAYLOAD_W{1'b0}};
  reg out_valid_reg = 1'b0;

  wire s_clear_active = clear_wclk_2;
  wire m_clear_active = clear_rclk_2;
  wire wr_fire = wr_stage_valid && !wr_full && !s_clear_active;
  wire s_fire = s_axis_tvalid && s_axis_tready;
  wire rd_empty_now = rd_gray == wr_gray_rclk_2;
  wire out_reg_ready = !out_valid_reg || m_axis_tready;
  wire out_pop = (out_count != {OUT_COUNT_W{1'b0}}) && out_reg_ready;
  wire out_fire = out_valid_reg && m_axis_tready;
  wire ram_return_valid = rd_valid_pipe[READ_PIPE_LEN-1];
  wire [OUT_COUNT_W-1:0] outstanding_count =
    {{(OUT_COUNT_W-1){1'b0}}, rd_valid_pipe[0]} +
    {{(OUT_COUNT_W-1){1'b0}}, rd_valid_pipe[1]};
  wire [OUT_COUNT_W-1:0] total_buffered = out_count + outstanding_count;
  wire rd_issue = !m_clear_active && !rd_empty_now && (total_buffered < OUT_DEPTH);

  wire [PTR_W-1:0] wr_bin_next = wr_bin + {{(PTR_W-1){1'b0}}, wr_fire};
  wire [PTR_W-1:0] wr_bin_inc = wr_bin + {{(PTR_W-1){1'b0}}, 1'b1};
  wire [PTR_W-1:0] rd_bin_next = rd_bin + {{(PTR_W-1){1'b0}}, rd_issue};
  wire [PTR_W-1:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
  wire [PTR_W-1:0] wr_gray_inc = (wr_bin_inc >> 1) ^ wr_bin_inc;
  wire [PTR_W-1:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

  wire [PTR_W-1:0] wr_full_compare = {
    ~rd_gray_wclk_2[PTR_W-1:PTR_W-2],
    rd_gray_wclk_2[PTR_W-3:0]
  };
  wire wr_full_now = wr_gray == wr_full_compare;
  wire wr_full_after_write = wr_gray_inc == wr_full_compare;

  assign s_axis_tready = !wr_full && !s_clear_active;
  assign m_axis_tvalid = out_valid_reg;

  assign {m_axis_tuser, m_axis_tlast, m_axis_tkeep, m_axis_tdata} = out_payload_reg;

  xpm_memory_sdpram #(
    .ADDR_WIDTH_A(DEPTH_LOG2),
    .ADDR_WIDTH_B(DEPTH_LOG2),
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(PAYLOAD_W),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("independent_clock"),
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
    .clka(s_clk),
    .ena(1'b1),
    .wea(wr_fire),
    .addra(wr_bin[DEPTH_LOG2-1:0]),
    .dina({wr_stage_user, wr_stage_last, wr_stage_keep, wr_stage_data}),
    .injectsbiterra(1'b0),
    .injectdbiterra(1'b0),
    .clkb(m_clk),
    .rstb(1'b0),
    .enb(1'b1),
    .regceb(1'b1),
    .addrb(rd_bin[DEPTH_LOG2-1:0]),
    .doutb(ram_dout),
    .sbiterrb(),
    .dbiterrb()
  );

  always @(posedge s_clk or negedge s_resetn) begin
    if (!s_resetn) begin
      wr_bin <= {PTR_W{1'b0}};
      wr_gray <= {PTR_W{1'b0}};
      rd_gray_wclk_1 <= {PTR_W{1'b0}};
      rd_gray_wclk_2 <= {PTR_W{1'b0}};
      clear_wclk_1 <= 1'b0;
      clear_wclk_2 <= 1'b0;
      wr_full <= 1'b1;
      wr_stage_data <= {DATA_W{1'b0}};
      wr_stage_keep <= {KEEP_W{1'b0}};
      wr_stage_user <= {USER_W{1'b0}};
      wr_stage_last <= 1'b0;
      wr_stage_valid <= 1'b0;
    end else begin
      clear_wclk_1 <= clear;
      clear_wclk_2 <= clear_wclk_1;

      if (s_clear_active) begin
        wr_bin <= {PTR_W{1'b0}};
        wr_gray <= {PTR_W{1'b0}};
        rd_gray_wclk_1 <= {PTR_W{1'b0}};
        rd_gray_wclk_2 <= {PTR_W{1'b0}};
        wr_full <= 1'b1;
        wr_stage_valid <= 1'b0;
      end else begin
      rd_gray_wclk_1 <= rd_gray;
      rd_gray_wclk_2 <= rd_gray_wclk_1;
      wr_full <= wr_fire ? wr_full_after_write : wr_full_now;

      if (s_fire) begin
        wr_stage_data <= s_axis_tdata;
        wr_stage_keep <= s_axis_tkeep;
        wr_stage_user <= s_axis_tuser;
        wr_stage_last <= s_axis_tlast;
        wr_stage_valid <= 1'b1;
      end else if (wr_fire) begin
        wr_stage_valid <= 1'b0;
      end

      if (wr_fire) begin
        wr_bin <= wr_bin_next;
        wr_gray <= wr_gray_next;
      end
      end
    end
  end

  always @(posedge m_clk) begin
    if (out_pop) begin
      out_payload_reg <= out_mem[out_rd_ptr];
    end

    if (ram_return_valid) begin
      out_mem[out_wr_ptr] <= ram_dout;
    end
  end

  always @(posedge m_clk or negedge m_resetn) begin
    if (!m_resetn) begin
      rd_bin <= {PTR_W{1'b0}};
      rd_gray <= {PTR_W{1'b0}};
      wr_gray_rclk_1 <= {PTR_W{1'b0}};
      wr_gray_rclk_2 <= {PTR_W{1'b0}};
      clear_rclk_1 <= 1'b0;
      clear_rclk_2 <= 1'b0;
      rd_valid_pipe <= {READ_PIPE_LEN{1'b0}};
      out_wr_ptr <= {OUT_PTR_W{1'b0}};
      out_rd_ptr <= {OUT_PTR_W{1'b0}};
      out_count <= {OUT_COUNT_W{1'b0}};
      out_valid_reg <= 1'b0;
    end else begin
      clear_rclk_1 <= clear;
      clear_rclk_2 <= clear_rclk_1;

      if (m_clear_active) begin
        rd_bin <= {PTR_W{1'b0}};
        rd_gray <= {PTR_W{1'b0}};
        wr_gray_rclk_1 <= {PTR_W{1'b0}};
        wr_gray_rclk_2 <= {PTR_W{1'b0}};
        rd_valid_pipe <= {READ_PIPE_LEN{1'b0}};
        out_wr_ptr <= {OUT_PTR_W{1'b0}};
        out_rd_ptr <= {OUT_PTR_W{1'b0}};
        out_count <= {OUT_COUNT_W{1'b0}};
        out_valid_reg <= 1'b0;
      end else begin
      wr_gray_rclk_1 <= wr_gray;
      wr_gray_rclk_2 <= wr_gray_rclk_1;
      rd_valid_pipe <= {rd_valid_pipe[READ_PIPE_LEN-2:0], rd_issue};

      if (rd_issue) begin
        rd_bin <= rd_bin_next;
        rd_gray <= rd_gray_next;
      end

      if (out_pop) begin
        out_valid_reg <= 1'b1;
        out_rd_ptr <= out_rd_ptr + {{(OUT_PTR_W-1){1'b0}}, 1'b1};
      end else if (out_fire) begin
        out_valid_reg <= 1'b0;
      end

      if (ram_return_valid) begin
        out_wr_ptr <= out_wr_ptr + {{(OUT_PTR_W-1){1'b0}}, 1'b1};
      end

      case ({ram_return_valid, out_pop})
        2'b10: out_count <= out_count + {{(OUT_COUNT_W-1){1'b0}}, 1'b1};
        2'b01: out_count <= out_count - {{(OUT_COUNT_W-1){1'b0}}, 1'b1};
        default: out_count <= out_count;
      endcase
      end
    end
  end
endmodule
