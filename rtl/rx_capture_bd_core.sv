`timescale 1ns/1ps

module rx_capture_core #(
  parameter int AXIL_ADDR_W = 16,
  parameter int AXI_ADDR_W_P = 64,
  parameter int AXI_ID_W_P = 4,
  parameter int AXIS_DATA_W_P = 512,
  parameter int AXIS_KEEP_W_P = 64
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIL:M_AXI, ASSOCIATED_RESET resetn, FREQ_HZ 300000000" *)
  input  wire                       clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                       resetn,

  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_RX_AXIS, ASSOCIATED_RESET rx_resetn" *)
  input  wire                       rx_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                       rx_resetn,
  input  wire                       link_up,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWADDR" *)
  input  wire [AXIL_ADDR_W-1:0]     s_axil_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWVALID" *)
  input  wire                       s_axil_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWREADY" *)
  output logic                      s_axil_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WDATA" *)
  input  wire [31:0]                s_axil_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WSTRB" *)
  input  wire [3:0]                 s_axil_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WVALID" *)
  input  wire                       s_axil_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WREADY" *)
  output logic                      s_axil_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BRESP" *)
  output wire [1:0]                 s_axil_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BVALID" *)
  output logic                      s_axil_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BREADY" *)
  input  wire                       s_axil_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARADDR" *)
  input  wire [AXIL_ADDR_W-1:0]     s_axil_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARVALID" *)
  input  wire                       s_axil_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARREADY" *)
  output wire                       s_axil_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RDATA" *)
  output logic [31:0]               s_axil_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RRESP" *)
  output wire [1:0]                 s_axil_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RVALID" *)
  output logic                      s_axil_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RREADY" *)
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 16, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, SUPPORTS_NARROW_BURST 0" *)
  input  wire                       s_axil_rready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID" *)
  output wire [AXI_ID_W_P-1:0]      m_axi_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *)
  output logic [AXI_ADDR_W_P-1:0]   m_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *)
  output wire [7:0]                 m_axi_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *)
  output wire [2:0]                 m_axi_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *)
  output wire [1:0]                 m_axi_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *)
  output wire                       m_axi_awlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *)
  output wire [3:0]                 m_axi_awcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *)
  output wire [2:0]                 m_axi_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWQOS" *)
  output wire [3:0]                 m_axi_awqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *)
  output logic                      m_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)
  input  wire                       m_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)
  output logic [AXIS_DATA_W_P-1:0]  m_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
  output logic [AXIS_KEEP_W_P-1:0]  m_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *)
  output wire                       m_axi_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)
  output logic                      m_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)
  input  wire                       m_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID" *)
  input  wire [AXI_ID_W_P-1:0]      m_axi_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)
  input  wire [1:0]                 m_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)
  input  wire                       m_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)
  output logic                      m_axi_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID" *)
  output wire [AXI_ID_W_P-1:0]      m_axi_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *)
  output wire [AXI_ADDR_W_P-1:0]    m_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *)
  output wire [7:0]                 m_axi_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *)
  output wire [2:0]                 m_axi_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *)
  output wire [1:0]                 m_axi_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *)
  output wire                       m_axi_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *)
  output wire [3:0]                 m_axi_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *)
  output wire [2:0]                 m_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARQOS" *)
  output wire [3:0]                 m_axi_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)
  output wire                       m_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)
  input  wire                       m_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RID" *)
  input  wire [AXI_ID_W_P-1:0]      m_axi_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)
  input  wire [AXIS_DATA_W_P-1:0]   m_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)
  input  wire [1:0]                 m_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *)
  input  wire                       m_axi_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)
  input  wire                       m_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4, DATA_WIDTH 512, ADDR_WIDTH 64, ID_WIDTH 4, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 0, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 256" *)
  output wire                       m_axi_rready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_RX_AXIS TDATA" *)
  input  wire [AXIS_DATA_W_P-1:0]   s_rx_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_RX_AXIS TKEEP" *)
  input  wire [AXIS_KEEP_W_P-1:0]   s_rx_axis_tkeep,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_RX_AXIS TVALID" *)
  input  wire                       s_rx_axis_tvalid,
  input  wire                       s_rx_axis_tstart,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_RX_AXIS TLAST" *)
  input  wire                       s_rx_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_RX_AXIS TUSER" *)
  (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 64, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 0" *)
  input  wire                       s_rx_axis_tuser
);
  localparam logic [AXIL_ADDR_W-1:0] REG_CONTROL       = 16'h0000;
  localparam logic [AXIL_ADDR_W-1:0] REG_STATUS        = 16'h0004;
  localparam logic [AXIL_ADDR_W-1:0] REG_RING_BASE_LO  = 16'h0010;
  localparam logic [AXIL_ADDR_W-1:0] REG_RING_BASE_HI  = 16'h0014;
  localparam logic [AXIL_ADDR_W-1:0] REG_RING_SIZE     = 16'h0018;
  localparam logic [AXIL_ADDR_W-1:0] REG_TRUNC_BYTES   = 16'h001c;
  localparam logic [AXIL_ADDR_W-1:0] REG_WRITE_PTR     = 16'h0020;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_PKTS_LO    = 16'h0030;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_PKTS_HI    = 16'h0034;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_BYTES_LO   = 16'h0038;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_BYTES_HI   = 16'h003c;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_ERRS_LO    = 16'h0040;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_ERRS_HI    = 16'h0044;
  localparam logic [AXIL_ADDR_W-1:0] REG_CAP_BYTES_LO  = 16'h0048;
  localparam logic [AXIL_ADDR_W-1:0] REG_CAP_BYTES_HI  = 16'h004c;
  localparam logic [AXIL_ADDR_W-1:0] REG_AXI_WR_LO     = 16'h0050;
  localparam logic [AXIL_ADDR_W-1:0] REG_AXI_WR_HI     = 16'h0054;
  localparam logic [AXIL_ADDR_W-1:0] REG_AXI_ERR_LO    = 16'h0058;
  localparam logic [AXIL_ADDR_W-1:0] REG_AXI_ERR_HI    = 16'h005c;
  localparam logic [AXIL_ADDR_W-1:0] REG_DEBUG         = 16'h0060;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_COUNT_LO  = 16'h0064;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_COUNT_HI  = 16'h0068;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_SUM_LO    = 16'h006c;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_SUM_HI    = 16'h0070;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_MIN_LO    = 16'h0074;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_MIN_HI    = 16'h0078;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_MAX_LO    = 16'h007c;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_MAX_HI    = 16'h0080;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_LAST_LO   = 16'h0084;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_LAST_HI   = 16'h0088;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_TICK_LO    = 16'h008c;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_TICK_HI    = 16'h0090;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_SAMPLE_INDEX = 16'h0094;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_SAMPLE_COUNT = 16'h0098;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_SAMPLE_LO    = 16'h009c;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_SAMPLE_HI    = 16'h00a0;
  localparam logic [AXIL_ADDR_W-1:0] REG_GAP_SAMPLE_WRITE_INDEX = 16'h00a4;
  localparam logic [AXIL_ADDR_W-1:0] REG_EVENT_INDEX    = 16'h00a8;
  localparam logic [AXIL_ADDR_W-1:0] REG_EVENT_COUNT_LO = 16'h00ac;
  localparam logic [AXIL_ADDR_W-1:0] REG_EVENT_COUNT_HI = 16'h00b0;
  localparam logic [AXIL_ADDR_W-1:0] REG_EVENT_DATA_LO  = 16'h00b4;
  localparam logic [AXIL_ADDR_W-1:0] REG_EVENT_DATA_HI  = 16'h00b8;
  localparam logic [AXIL_ADDR_W-1:0] REG_EVENT_WRITE_INDEX = 16'h00bc;
  localparam logic [AXIL_ADDR_W-1:0] REG_EVENT_DROP_LO  = 16'h00c0;
  localparam logic [AXIL_ADDR_W-1:0] REG_EVENT_DROP_HI  = 16'h00c4;
  localparam logic [AXIL_ADDR_W-1:0] REG_EVENT_CAPACITY = 16'h00c8;
  localparam logic [AXIL_ADDR_W-1:0] REG_HIST_INDEX     = 16'h00cc;
  localparam logic [AXIL_ADDR_W-1:0] REG_HIST_COUNT_LO  = 16'h00d0;
  localparam logic [AXIL_ADDR_W-1:0] REG_HIST_COUNT_HI  = 16'h00d4;
  localparam logic [AXIL_ADDR_W-1:0] REG_RX_CAPABILITIES = 16'h00d8;
  localparam int RX_CLEAR_CYCLES = 128;
  localparam int RX_CLEAR_CNT_W = $clog2(RX_CLEAR_CYCLES + 1);
  localparam logic [RX_CLEAR_CNT_W-1:0] RX_CLEAR_LEVEL = RX_CLEAR_CYCLES;
  localparam int GAP_SAMPLE_DEPTH_LOG2 = 12;
  localparam int GAP_SAMPLE_DEPTH = 1 << GAP_SAMPLE_DEPTH_LOG2;
  localparam logic [31:0] GAP_SAMPLE_DEPTH_U32 = GAP_SAMPLE_DEPTH;
  localparam int RX_FIFO_USER_W = 67;
  localparam int EVENT_WORD_LANES = 8;
  localparam int EVENT_WORD_LANE_W = 3;
  localparam int EVENT_RING_WORD_LOG2 = 16;
  localparam int EVENT_RING_WORDS = 1 << EVENT_RING_WORD_LOG2;
  localparam int EVENT_RING_SAMPLES = EVENT_RING_WORDS * EVENT_WORD_LANES;
  localparam int EVENT_RING_INDEX_W = EVENT_RING_WORD_LOG2 + EVENT_WORD_LANE_W;
  localparam logic [31:0] EVENT_RING_SAMPLES_U32 = EVENT_RING_SAMPLES;
  localparam int GAP_HIST_BINS = 16;

  logic [AXIL_ADDR_W-1:0] awaddr_q;
  logic [AXIL_ADDR_W-1:0] araddr_q;
  logic ar_pending_q;
  logic aw_hold;
  logic w_hold;
  logic [31:0] wdata_q;
  logic [3:0] wstrb_q;
  logic do_write;
  logic stats_clear_req_q;
  logic [RX_CLEAR_CNT_W-1:0] rx_fifo_clear_count_q;
  logic rx_fifo_clear;

  logic cfg_enable;
  logic cfg_capture_enable;
  logic [63:0] cfg_ring_base;
  logic [31:0] cfg_ring_size;
  logic [31:0] cfg_trunc_bytes;
  (* ASYNC_REG = "TRUE" *) logic cfg_enable_rx_meta;
  (* ASYNC_REG = "TRUE" *) logic cfg_enable_rx_sync;
  (* ASYNC_REG = "TRUE" *) logic rx_clear_rx_meta;
  (* ASYNC_REG = "TRUE" *) logic rx_clear_rx_sync;

  wire fifo_s_ready;
  wire fifo_tvalid;
  wire fifo_tready;
  wire [AXIS_DATA_W_P-1:0] fifo_tdata;
  wire [AXIS_KEEP_W_P-1:0] fifo_tkeep;
  wire fifo_tlast;
  wire fifo_tuser;
  wire fifo_tstart;
  wire fifo_tgap_valid;
  wire [63:0] fifo_tgap;
  wire [RX_FIFO_USER_W-1:0] fifo_tuser_vec;
  logic fifo_pipe_valid_q;
  logic [AXIS_DATA_W_P-1:0] fifo_pipe_tdata_q;
  logic [AXIS_KEEP_W_P-1:0] fifo_pipe_tkeep_q;
  logic fifo_pipe_tlast_q;
  logic fifo_pipe_tuser_q;
  logic fifo_pipe_tstart_q;
  logic fifo_pipe_tgap_valid_q;
  logic [63:0] fifo_pipe_tgap_q;
  wire rx_pipe_flush;
  wire fifo_pipe_consume;
  wire fifo_pipe_can_load;

  logic rx_overflow_seen;
  (* ASYNC_REG = "TRUE" *) logic rx_overflow_meta;
  (* ASYNC_REG = "TRUE" *) logic rx_overflow_sync;

  logic [31:0] write_ptr_q;
  logic [31:0] capture_remaining_q;
  logic in_packet_q;
  logic [63:0] stat_rx_pkts_q;
  logic [63:0] stat_rx_bytes_q;
  logic [63:0] stat_rx_errs_q;
  logic [63:0] stat_cap_bytes_q;
  logic [63:0] stat_axi_writes_q;
  logic [63:0] stat_axi_errors_q;
  logic [6:0]  stat_rx_bytes_inc_q;
  logic        stat_rx_bytes_inc_valid_q;
  logic [63:0] rx_tick_rx_q;
  logic [63:0] rx_prev_start_tick_rx_q;
  logic        rx_have_prev_start_rx_q;
  logic        rx_gap_measure_valid_q;
  logic [63:0] rx_gap_measure_q;
  logic        rx_hist_update_valid_q;
  logic [3:0]  rx_hist_update_bin_q;
  logic [63:0] stat_gap_count_rx_q;
  logic [63:0] stat_gap_sum_rx_q;
  logic [63:0] stat_gap_min_rx_q;
  logic [63:0] stat_gap_max_rx_q;
  logic [63:0] stat_gap_last_rx_q;
  logic [63:0] stat_rx_pkts_rx_q;
  logic [63:0] stat_rx_bytes_rx_q;
  logic [31:0] stat_rx_bytes_lo_rx_q;
  logic [31:0] stat_rx_bytes_hi_rx_q;
  logic [63:0] stat_rx_errs_rx_q;
  logic [63:0] stat_rx_pkts_sync_q;
  logic [63:0] stat_rx_bytes_sync_q;
  logic [63:0] stat_rx_errs_sync_q;
  logic [63:0] stat_rx_pkts_meta_q;
  logic [63:0] stat_rx_bytes_meta_q;
  logic [63:0] stat_rx_errs_meta_q;
  logic [63:0] gap_hist_rx_q [0:GAP_HIST_BINS-1];
  logic [63:0] gap_hist_meta_q [0:GAP_HIST_BINS-1];
  logic [63:0] gap_hist_sync_q [0:GAP_HIST_BINS-1];
  logic [3:0] gap_hist_rd_index_q;

  logic [511:0] rx_event_pack_q;
  logic [EVENT_WORD_LANE_W-1:0] rx_event_lane_q;
  logic [511:0] rx_event_word_q;
  logic rx_event_word_valid_q;
  wire rx_event_word_ready;
  logic [63:0] rx_event_drop_rx_q;
  logic [63:0] rx_event_drop_meta_q;
  logic [63:0] rx_event_drop_sync_q;
  wire [511:0] event_fifo_tdata;
  wire event_fifo_tvalid;
  wire event_fifo_tready;
  wire [63:0] event_fifo_unused_keep;
  wire event_fifo_unused_last;
  wire event_fifo_unused_user;
  logic [EVENT_RING_WORD_LOG2-1:0] event_ring_wr_word_q;
  logic [63:0] event_ring_count_q;
  logic [EVENT_RING_INDEX_W-1:0] event_rd_index_q;
  wire [511:0] event_rd_word;
  logic [EVENT_RING_WORD_LOG2-1:0] event_rd_word_addr;
  logic [63:0] event_rd_sample_q;
  wire event_mem_sbiterr;
  wire event_mem_dbiterr;
  logic [GAP_SAMPLE_DEPTH_LOG2-1:0] gap_sample_wr_ptr_q;
  logic [GAP_SAMPLE_DEPTH_LOG2-1:0] gap_sample_rd_index_q;
  logic [31:0] gap_sample_count_q;
  (* ram_style = "block" *) logic [63:0] gap_sample_mem [0:GAP_SAMPLE_DEPTH-1];
  logic [63:0] gap_sample_rd_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] rx_tick_meta_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] rx_tick_sync_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] stat_gap_count_meta_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] stat_gap_count_sync_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] stat_gap_sum_meta_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] stat_gap_sum_sync_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] stat_gap_min_meta_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] stat_gap_min_sync_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] stat_gap_max_meta_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] stat_gap_max_sync_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] stat_gap_last_meta_q;
  (* ASYNC_REG = "TRUE" *) logic [63:0] stat_gap_last_sync_q;

  logic [1:0] writer_state_q;
  logic aw_done_q;
  logic w_done_q;

  assign s_axil_bresp   = 2'b00;
  assign s_axil_rresp   = 2'b00;
  assign s_axil_arready = !ar_pending_q && !s_axil_rvalid;
  assign do_write       = aw_hold && w_hold && !s_axil_bvalid;

  assign m_axi_awid    = {AXI_ID_W_P{1'b0}};
  assign m_axi_awlen   = 8'd0;
  assign m_axi_awsize  = 3'd6;
  assign m_axi_awburst = 2'b01;
  assign m_axi_awlock  = 1'b0;
  assign m_axi_awcache = 4'b0011;
  assign m_axi_awprot  = 3'b000;
  assign m_axi_awqos   = 4'd0;
  assign m_axi_wlast   = 1'b1;

  assign m_axi_arid    = {AXI_ID_W_P{1'b0}};
  assign m_axi_araddr  = {AXI_ADDR_W_P{1'b0}};
  assign m_axi_arlen   = 8'd0;
  assign m_axi_arsize  = 3'd6;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arlock  = 1'b0;
  assign m_axi_arcache = 4'b0011;
  assign m_axi_arprot  = 3'b000;
  assign m_axi_arqos   = 4'd0;
  assign m_axi_arvalid = 1'b0;
  assign m_axi_rready  = 1'b1;

  assign rx_fifo_clear = (rx_fifo_clear_count_q != '0);
  assign rx_pipe_flush = stats_clear_req_q || rx_fifo_clear || !cfg_enable;
  assign fifo_pipe_consume = fifo_pipe_valid_q && !rx_pipe_flush &&
                             (writer_state_q == 2'd0);
  assign fifo_pipe_can_load = !fifo_pipe_valid_q || fifo_pipe_consume;
  assign fifo_tready = !rx_pipe_flush && fifo_pipe_can_load;

  function automatic [31:0] apply_wstrb(
    input [31:0] old_value,
    input [31:0] new_value,
    input [3:0]  strobe
  );
    begin
      apply_wstrb = old_value;
      for (int i = 0; i < 4; i++) begin
        if (strobe[i]) begin
          apply_wstrb[i*8 +: 8] = new_value[i*8 +: 8];
        end
      end
    end
  endfunction

  function automatic logic [GAP_SAMPLE_DEPTH_LOG2-1:0] apply_index_wstrb(
    input logic [GAP_SAMPLE_DEPTH_LOG2-1:0] old_value,
    input logic [31:0] new_value,
    input logic [3:0] strobe
  );
    automatic logic [31:0] merged;
    begin
      merged = apply_wstrb({{(32-GAP_SAMPLE_DEPTH_LOG2){1'b0}}, old_value}, new_value, strobe);
      apply_index_wstrb = merged[GAP_SAMPLE_DEPTH_LOG2-1:0];
    end
  endfunction

  function automatic [6:0] popcount_keep(input logic [AXIS_KEEP_W_P-1:0] keep);
    automatic logic [6:0] count;
    begin
      count = 7'd0;
      for (int i = 0; i < AXIS_KEEP_W_P; i++) begin
        count = count + {6'd0, keep[i]};
      end
      popcount_keep = count;
    end
  endfunction

  function automatic logic [3:0] gap_hist_bin(input logic [63:0] gap);
    logic [3:0] result;
    begin
      result = 4'd0;
      for (int i = 1; i < GAP_HIST_BINS; i++) begin
        if (gap >= (64'd1 << i)) begin
          result = i[3:0];
        end
      end
      gap_hist_bin = result;
    end
  endfunction

  function automatic logic [AXIS_KEEP_W_P-1:0] limit_keep(
    input logic [AXIS_KEEP_W_P-1:0] keep,
    input logic [31:0] byte_limit
  );
    automatic logic [AXIS_KEEP_W_P-1:0] out_keep;
    begin
      out_keep = '0;
      for (int i = 0; i < AXIS_KEEP_W_P; i++) begin
        if (i < byte_limit) begin
          out_keep[i] = keep[i];
        end
      end
      limit_keep = out_keep;
    end
  endfunction

  wire rx_fifo_push = cfg_enable_rx_sync && !rx_clear_rx_sync &&
                      s_rx_axis_tvalid && fifo_s_ready;
  wire rx_start_event = cfg_enable_rx_sync && !rx_clear_rx_sync &&
                        s_rx_axis_tvalid && s_rx_axis_tstart;
  wire [63:0] rx_gap_candidate = rx_tick_rx_q - rx_prev_start_tick_rx_q;
  wire rx_gap_valid_for_fifo = s_rx_axis_tstart && rx_have_prev_start_rx_q;
  wire [63:0] rx_gap_for_fifo = rx_have_prev_start_rx_q ? rx_gap_candidate : 64'd0;

  axis_async_fifo #(
    .DATA_W(AXIS_DATA_W_P),
    .KEEP_W(AXIS_KEEP_W_P),
    .USER_W(RX_FIFO_USER_W),
    .DEPTH_LOG2(5)
  ) rx_fifo_i (
    .s_clk(rx_clk),
    .s_resetn(rx_resetn),
    .m_clk(clk),
    .m_resetn(resetn),
    .clear(rx_fifo_clear),
    .s_axis_tdata(s_rx_axis_tdata),
    .s_axis_tkeep(s_rx_axis_tkeep),
    .s_axis_tvalid(rx_fifo_push),
    .s_axis_tready(fifo_s_ready),
    .s_axis_tlast(s_rx_axis_tlast),
    .s_axis_tuser({rx_gap_valid_for_fifo, rx_gap_for_fifo, s_rx_axis_tstart, s_rx_axis_tuser}),
    .m_axis_tdata(fifo_tdata),
    .m_axis_tkeep(fifo_tkeep),
    .m_axis_tvalid(fifo_tvalid),
    .m_axis_tready(fifo_tready),
    .m_axis_tlast(fifo_tlast),
    .m_axis_tuser(fifo_tuser_vec)
  );

  axis_async_fifo #(
    .DATA_W(512),
    .KEEP_W(64),
    .USER_W(1),
    .DEPTH_LOG2(6)
  ) rx_event_fifo_i (
    .s_clk(rx_clk),
    .s_resetn(rx_resetn),
    .m_clk(clk),
    .m_resetn(resetn),
    .clear(rx_fifo_clear),
    .s_axis_tdata(rx_event_word_q),
    .s_axis_tkeep(64'hffff_ffff_ffff_ffff),
    .s_axis_tvalid(rx_event_word_valid_q),
    .s_axis_tready(rx_event_word_ready),
    .s_axis_tlast(1'b1),
    .s_axis_tuser(1'b0),
    .m_axis_tdata(event_fifo_tdata),
    .m_axis_tkeep(event_fifo_unused_keep),
    .m_axis_tvalid(event_fifo_tvalid),
    .m_axis_tready(event_fifo_tready),
    .m_axis_tlast(event_fifo_unused_last),
    .m_axis_tuser(event_fifo_unused_user)
  );

  assign event_fifo_tready = 1'b1;

  xpm_memory_sdpram #(
    .MEMORY_SIZE(EVENT_RING_WORDS * 512),
    .MEMORY_PRIMITIVE("ultra"),
    .CLOCKING_MODE("common_clock"),
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"),
    .USE_MEM_INIT(0),
    .WAKEUP_TIME("disable_sleep"),
    .AUTO_SLEEP_TIME(0),
    .MESSAGE_CONTROL(0),
    .MEMORY_OPTIMIZATION("true"),
    .CASCADE_HEIGHT(4),
    .WRITE_DATA_WIDTH_A(512),
    .BYTE_WRITE_WIDTH_A(512),
    .ADDR_WIDTH_A(EVENT_RING_WORD_LOG2),
    .READ_DATA_WIDTH_B(512),
    .ADDR_WIDTH_B(EVENT_RING_WORD_LOG2),
    .READ_RESET_VALUE_B("0"),
    .READ_LATENCY_B(5),
    .WRITE_MODE_B("read_first"),
    .RST_MODE_B("SYNC")
  ) event_ring_mem_i (
    .sleep(1'b0),
    .clka(clk),
    .ena(event_fifo_tvalid && event_fifo_tready),
    .wea(1'b1),
    .addra(event_ring_wr_word_q),
    .dina(event_fifo_tdata),
    .injectsbiterra(1'b0),
    .injectdbiterra(1'b0),
    .clkb(clk),
    .rstb(!resetn || rx_fifo_clear),
    .enb(1'b1),
    .regceb(1'b1),
    .addrb(event_rd_word_addr),
    .doutb(event_rd_word),
    .sbiterrb(event_mem_sbiterr),
    .dbiterrb(event_mem_dbiterr)
  );

  assign fifo_tuser  = fifo_tuser_vec[0];
  assign fifo_tstart = fifo_tuser_vec[1];
  assign fifo_tgap   = fifo_tuser_vec[65:2];
  assign fifo_tgap_valid = fifo_tuser_vec[66];
  assign stat_rx_bytes_rx_q = {stat_rx_bytes_hi_rx_q, stat_rx_bytes_lo_rx_q};

  always_ff @(posedge rx_clk or negedge rx_resetn) begin
    if (!rx_resetn) begin
      cfg_enable_rx_meta <= 1'b0;
      cfg_enable_rx_sync <= 1'b0;
      rx_clear_rx_meta <= 1'b0;
      rx_clear_rx_sync <= 1'b0;
      rx_overflow_seen <= 1'b0;
      rx_tick_rx_q <= 64'd0;
      rx_prev_start_tick_rx_q <= 64'd0;
      rx_have_prev_start_rx_q <= 1'b0;
      rx_gap_measure_valid_q <= 1'b0;
      rx_gap_measure_q <= 64'd0;
      rx_hist_update_valid_q <= 1'b0;
      rx_hist_update_bin_q <= 4'd0;
      stat_gap_count_rx_q <= 64'd0;
      stat_gap_sum_rx_q <= 64'd0;
      stat_gap_min_rx_q <= 64'd0;
      stat_gap_max_rx_q <= 64'd0;
      stat_gap_last_rx_q <= 64'd0;
      stat_rx_pkts_rx_q <= 64'd0;
      stat_rx_bytes_lo_rx_q <= 32'd0;
      stat_rx_bytes_hi_rx_q <= 32'd0;
      stat_rx_errs_rx_q <= 64'd0;
      rx_event_pack_q <= '0;
      rx_event_lane_q <= '0;
      rx_event_word_q <= '0;
      rx_event_word_valid_q <= 1'b0;
      rx_event_drop_rx_q <= 64'd0;
      for (int hist = 0; hist < GAP_HIST_BINS; hist++) begin
        gap_hist_rx_q[hist] <= 64'd0;
      end
    end else begin
      cfg_enable_rx_meta <= cfg_enable;
      cfg_enable_rx_sync <= cfg_enable_rx_meta;
      rx_clear_rx_meta <= rx_fifo_clear;
      rx_clear_rx_sync <= rx_clear_rx_meta;
      if (!cfg_enable_rx_sync || rx_clear_rx_sync) begin
        rx_overflow_seen <= 1'b0;
        rx_tick_rx_q <= 64'd0;
        rx_prev_start_tick_rx_q <= 64'd0;
        rx_have_prev_start_rx_q <= 1'b0;
        rx_gap_measure_valid_q <= 1'b0;
        rx_gap_measure_q <= 64'd0;
        rx_hist_update_valid_q <= 1'b0;
        rx_hist_update_bin_q <= 4'd0;
        stat_gap_count_rx_q <= 64'd0;
        stat_gap_sum_rx_q <= 64'd0;
        stat_gap_min_rx_q <= 64'd0;
        stat_gap_max_rx_q <= 64'd0;
        stat_gap_last_rx_q <= 64'd0;
        stat_rx_pkts_rx_q <= 64'd0;
        stat_rx_bytes_lo_rx_q <= 32'd0;
        stat_rx_bytes_hi_rx_q <= 32'd0;
        stat_rx_errs_rx_q <= 64'd0;
        rx_event_pack_q <= '0;
        rx_event_lane_q <= '0;
        rx_event_word_q <= '0;
        rx_event_word_valid_q <= 1'b0;
        rx_event_drop_rx_q <= 64'd0;
        for (int hist = 0; hist < GAP_HIST_BINS; hist++) begin
          gap_hist_rx_q[hist] <= 64'd0;
        end
      end else if (s_rx_axis_tvalid && !fifo_s_ready) begin
        rx_overflow_seen <= 1'b1;
      end
      if (cfg_enable_rx_sync && !rx_clear_rx_sync) begin
        rx_gap_measure_valid_q <= 1'b0;
        rx_hist_update_valid_q <= rx_gap_measure_valid_q;
        if (rx_event_word_valid_q && rx_event_word_ready) begin
          rx_event_word_valid_q <= 1'b0;
        end
        rx_tick_rx_q <= rx_tick_rx_q + 64'd1;
        if (s_rx_axis_tvalid) begin
          automatic logic [32:0] rx_bytes_low_sum;
          rx_bytes_low_sum = {1'b0, stat_rx_bytes_lo_rx_q} +
                             {{26{1'b0}}, popcount_keep(s_rx_axis_tkeep)};
          stat_rx_bytes_lo_rx_q <= rx_bytes_low_sum[31:0];
          if (rx_bytes_low_sum[32]) begin
            stat_rx_bytes_hi_rx_q <= stat_rx_bytes_hi_rx_q + 32'd1;
          end
          if (s_rx_axis_tlast) begin
            stat_rx_pkts_rx_q <= stat_rx_pkts_rx_q + 64'd1;
            if (s_rx_axis_tuser) begin
              stat_rx_errs_rx_q <= stat_rx_errs_rx_q + 64'd1;
            end
          end
        end
        if (rx_hist_update_valid_q) begin
          gap_hist_rx_q[rx_hist_update_bin_q] <=
            gap_hist_rx_q[rx_hist_update_bin_q] + 64'd1;
        end
        if (rx_gap_measure_valid_q) begin
            automatic logic [511:0] completed_event_word;
            rx_hist_update_bin_q <= gap_hist_bin(rx_gap_measure_q);
            stat_gap_count_rx_q <= stat_gap_count_rx_q + 64'd1;
            stat_gap_sum_rx_q   <= stat_gap_sum_rx_q + rx_gap_measure_q;
            stat_gap_last_rx_q  <= rx_gap_measure_q;
            completed_event_word = rx_event_pack_q;
            completed_event_word[rx_event_lane_q*64 +: 64] = rx_gap_measure_q;
            if (rx_event_lane_q == EVENT_WORD_LANES-1) begin
              rx_event_lane_q <= '0;
              if (!rx_event_word_valid_q || rx_event_word_ready) begin
                rx_event_word_q <= completed_event_word;
                rx_event_word_valid_q <= 1'b1;
              end else begin
                rx_event_drop_rx_q <= rx_event_drop_rx_q + EVENT_WORD_LANES;
              end
            end else begin
              rx_event_pack_q[rx_event_lane_q*64 +: 64] <= rx_gap_measure_q;
              rx_event_lane_q <= rx_event_lane_q + 1'b1;
            end
            if ((stat_gap_count_rx_q == 64'd0) || (rx_gap_measure_q < stat_gap_min_rx_q)) begin
              stat_gap_min_rx_q <= rx_gap_measure_q;
            end
            if ((stat_gap_count_rx_q == 64'd0) || (rx_gap_measure_q > stat_gap_max_rx_q)) begin
              stat_gap_max_rx_q <= rx_gap_measure_q;
            end
        end
        if (rx_start_event) begin
          if (rx_have_prev_start_rx_q) begin
            rx_gap_measure_q <= rx_gap_candidate;
            rx_gap_measure_valid_q <= 1'b1;
          end
          rx_prev_start_tick_rx_q <= rx_tick_rx_q;
          rx_have_prev_start_rx_q <= 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn || rx_fifo_clear) begin
      rx_overflow_meta <= 1'b0;
      rx_overflow_sync <= 1'b0;
      rx_tick_meta_q <= 64'd0;
      rx_tick_sync_q <= 64'd0;
      stat_gap_count_meta_q <= 64'd0;
      stat_gap_count_sync_q <= 64'd0;
      stat_gap_sum_meta_q <= 64'd0;
      stat_gap_sum_sync_q <= 64'd0;
      stat_gap_min_meta_q <= 64'd0;
      stat_gap_min_sync_q <= 64'd0;
      stat_gap_max_meta_q <= 64'd0;
      stat_gap_max_sync_q <= 64'd0;
      stat_gap_last_meta_q <= 64'd0;
      stat_gap_last_sync_q <= 64'd0;
      stat_rx_pkts_meta_q <= 64'd0;
      stat_rx_pkts_sync_q <= 64'd0;
      stat_rx_bytes_meta_q <= 64'd0;
      stat_rx_bytes_sync_q <= 64'd0;
      stat_rx_errs_meta_q <= 64'd0;
      stat_rx_errs_sync_q <= 64'd0;
      rx_event_drop_meta_q <= 64'd0;
      rx_event_drop_sync_q <= 64'd0;
      for (int hist = 0; hist < GAP_HIST_BINS; hist++) begin
        gap_hist_meta_q[hist] <= 64'd0;
        gap_hist_sync_q[hist] <= 64'd0;
      end
    end else begin
      rx_overflow_meta <= rx_overflow_seen;
      rx_overflow_sync <= rx_overflow_meta;
      rx_tick_meta_q <= rx_tick_rx_q;
      rx_tick_sync_q <= rx_tick_meta_q;
      stat_gap_count_meta_q <= stat_gap_count_rx_q;
      stat_gap_count_sync_q <= stat_gap_count_meta_q;
      stat_gap_sum_meta_q <= stat_gap_sum_rx_q;
      stat_gap_sum_sync_q <= stat_gap_sum_meta_q;
      stat_gap_min_meta_q <= stat_gap_min_rx_q;
      stat_gap_min_sync_q <= stat_gap_min_meta_q;
      stat_gap_max_meta_q <= stat_gap_max_rx_q;
      stat_gap_max_sync_q <= stat_gap_max_meta_q;
      stat_gap_last_meta_q <= stat_gap_last_rx_q;
      stat_gap_last_sync_q <= stat_gap_last_meta_q;
      stat_rx_pkts_meta_q <= stat_rx_pkts_rx_q;
      stat_rx_pkts_sync_q <= stat_rx_pkts_meta_q;
      stat_rx_bytes_meta_q <= stat_rx_bytes_rx_q;
      stat_rx_bytes_sync_q <= stat_rx_bytes_meta_q;
      stat_rx_errs_meta_q <= stat_rx_errs_rx_q;
      stat_rx_errs_sync_q <= stat_rx_errs_meta_q;
      rx_event_drop_meta_q <= rx_event_drop_rx_q;
      rx_event_drop_sync_q <= rx_event_drop_meta_q;
      for (int hist = 0; hist < GAP_HIST_BINS; hist++) begin
        gap_hist_meta_q[hist] <= gap_hist_rx_q[hist];
        gap_hist_sync_q[hist] <= gap_hist_meta_q[hist];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      gap_sample_rd_q <= 64'd0;
    end else begin
      gap_sample_rd_q <= gap_sample_mem[gap_sample_rd_index_q];
    end
  end

  always_comb begin
    event_rd_word_addr = event_rd_index_q[EVENT_WORD_LANE_W +: EVENT_RING_WORD_LOG2];
  end

  always_ff @(posedge clk) begin
    if (!resetn || rx_fifo_clear) begin
      event_ring_wr_word_q <= '0;
      event_ring_count_q <= 64'd0;
      event_rd_sample_q <= 64'd0;
    end else begin
      event_rd_sample_q <=
        event_rd_word[event_rd_index_q[EVENT_WORD_LANE_W-1:0]*64 +: 64];
      if (event_fifo_tvalid && event_fifo_tready) begin
        event_ring_wr_word_q <= event_ring_wr_word_q + 1'b1;
        event_ring_count_q <= event_ring_count_q + EVENT_WORD_LANES;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      fifo_pipe_valid_q <= 1'b0;
    end else if (rx_pipe_flush) begin
      fifo_pipe_valid_q <= 1'b0;
    end else begin
      if (fifo_tvalid && fifo_tready) begin
        fifo_pipe_tdata_q  <= fifo_tdata;
        fifo_pipe_tkeep_q  <= fifo_tkeep;
        fifo_pipe_tlast_q  <= fifo_tlast;
        fifo_pipe_tuser_q  <= fifo_tuser;
        fifo_pipe_tstart_q <= fifo_tstart;
        fifo_pipe_tgap_q   <= fifo_tgap;
        fifo_pipe_tgap_valid_q <= fifo_tgap_valid;
        fifo_pipe_valid_q  <= 1'b1;
      end else if (fifo_pipe_consume) begin
        fifo_pipe_valid_q <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      s_axil_awready     <= 1'b0;
      s_axil_wready      <= 1'b0;
      s_axil_bvalid      <= 1'b0;
      s_axil_rvalid      <= 1'b0;
      s_axil_rdata       <= 32'd0;
      awaddr_q           <= '0;
      araddr_q           <= '0;
      ar_pending_q       <= 1'b0;
      aw_hold            <= 1'b0;
      w_hold             <= 1'b0;
      stats_clear_req_q  <= 1'b0;
      wdata_q            <= 32'd0;
      wstrb_q            <= 4'd0;
      rx_fifo_clear_count_q <= '0;
      cfg_enable         <= 1'b0;
      cfg_capture_enable <= 1'b0;
      cfg_ring_base      <= 64'd0;
      cfg_ring_size      <= 32'd0;
      cfg_trunc_bytes    <= 32'd256;
      write_ptr_q        <= 32'd0;
      capture_remaining_q <= 32'd0;
      in_packet_q        <= 1'b0;
      stat_rx_pkts_q     <= 64'd0;
      stat_rx_bytes_q    <= 64'd0;
      stat_rx_errs_q     <= 64'd0;
      stat_cap_bytes_q   <= 64'd0;
      stat_axi_writes_q  <= 64'd0;
      stat_axi_errors_q  <= 64'd0;
      stat_rx_bytes_inc_q <= 7'd0;
      stat_rx_bytes_inc_valid_q <= 1'b0;
      gap_sample_wr_ptr_q <= '0;
      gap_sample_rd_index_q <= '0;
      gap_sample_count_q <= 32'd0;
      event_rd_index_q <= '0;
      gap_hist_rd_index_q <= '0;
      writer_state_q     <= 2'd0;
      aw_done_q          <= 1'b0;
      w_done_q           <= 1'b0;
      m_axi_awaddr       <= '0;
      m_axi_awvalid      <= 1'b0;
      m_axi_wdata        <= '0;
      m_axi_wstrb        <= '0;
      m_axi_wvalid       <= 1'b0;
      m_axi_bready       <= 1'b0;
    end else begin
      stat_rx_bytes_inc_valid_q <= 1'b0;
      stats_clear_req_q <= 1'b0;
      if (stats_clear_req_q) begin
        rx_fifo_clear_count_q <= RX_CLEAR_LEVEL;
      end else if (rx_fifo_clear_count_q != '0) begin
        rx_fifo_clear_count_q <= rx_fifo_clear_count_q - {{(RX_CLEAR_CNT_W-1){1'b0}}, 1'b1};
      end

      if (stats_clear_req_q) begin
        write_ptr_q         <= 32'd0;
        capture_remaining_q <= 32'd0;
        in_packet_q         <= 1'b0;
        stat_rx_pkts_q      <= 64'd0;
        stat_rx_bytes_q     <= 64'd0;
        stat_rx_errs_q      <= 64'd0;
        stat_cap_bytes_q    <= 64'd0;
        stat_axi_writes_q   <= 64'd0;
        stat_axi_errors_q   <= 64'd0;
        stat_rx_bytes_inc_q <= 7'd0;
        stat_rx_bytes_inc_valid_q <= 1'b0;
        gap_sample_wr_ptr_q <= '0;
        gap_sample_count_q  <= 32'd0;
        event_rd_index_q    <= '0;
        gap_hist_rd_index_q <= '0;
        writer_state_q      <= 2'd0;
        aw_done_q           <= 1'b0;
        w_done_q            <= 1'b0;
        m_axi_awaddr        <= '0;
        m_axi_awvalid       <= 1'b0;
        m_axi_wdata         <= '0;
        m_axi_wstrb         <= '0;
        m_axi_wvalid        <= 1'b0;
        m_axi_bready        <= 1'b1;
      end else if (rx_fifo_clear) begin
        writer_state_q      <= 2'd0;
        aw_done_q           <= 1'b0;
        w_done_q            <= 1'b0;
        m_axi_awvalid       <= 1'b0;
        m_axi_wvalid        <= 1'b0;
        m_axi_bready        <= 1'b1;
      end else if (stat_rx_bytes_inc_valid_q) begin
        stat_rx_bytes_q <= stat_rx_bytes_q + {57'd0, stat_rx_bytes_inc_q};
      end

      s_axil_awready <= !aw_hold && !s_axil_bvalid;
      s_axil_wready  <= !w_hold && !s_axil_bvalid;

      if (s_axil_awready && s_axil_awvalid) begin
        aw_hold  <= 1'b1;
        awaddr_q <= s_axil_awaddr;
      end

      if (s_axil_wready && s_axil_wvalid) begin
        w_hold  <= 1'b1;
        wdata_q <= s_axil_wdata;
        wstrb_q <= s_axil_wstrb;
      end

      if (do_write) begin
        unique case (awaddr_q)
          REG_CONTROL: begin
            if (wstrb_q[0]) begin
              cfg_enable         <= wdata_q[0];
              cfg_capture_enable <= wdata_q[2];
              if (wdata_q[1]) begin
                stats_clear_req_q <= 1'b1;
              end
            end
          end
          REG_RING_BASE_LO: cfg_ring_base[31:0]  <= apply_wstrb(cfg_ring_base[31:0], wdata_q, wstrb_q);
          REG_RING_BASE_HI: cfg_ring_base[63:32] <= apply_wstrb(cfg_ring_base[63:32], wdata_q, wstrb_q);
          REG_RING_SIZE:    cfg_ring_size        <= apply_wstrb(cfg_ring_size, wdata_q, wstrb_q);
          REG_TRUNC_BYTES:  cfg_trunc_bytes      <= apply_wstrb(cfg_trunc_bytes, wdata_q, wstrb_q);
          REG_WRITE_PTR:    write_ptr_q          <= apply_wstrb(write_ptr_q, wdata_q, wstrb_q);
          REG_GAP_SAMPLE_INDEX: gap_sample_rd_index_q <= apply_index_wstrb(gap_sample_rd_index_q, wdata_q, wstrb_q);
          REG_EVENT_INDEX: begin
            if (|wstrb_q) begin
              event_rd_index_q <= wdata_q[EVENT_RING_INDEX_W-1:0];
            end
          end
          REG_HIST_INDEX: begin
            if (wstrb_q[0]) begin
              gap_hist_rd_index_q <= wdata_q[3:0];
            end
          end
          default: begin
          end
        endcase
        aw_hold       <= 1'b0;
        w_hold        <= 1'b0;
        s_axil_bvalid <= 1'b1;
      end else if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end

      if (s_axil_arready && s_axil_arvalid) begin
        ar_pending_q <= 1'b1;
        araddr_q <= s_axil_araddr;
      end

      if (ar_pending_q) begin
        ar_pending_q <= 1'b0;
        s_axil_rvalid <= 1'b1;
        unique case (araddr_q)
          REG_CONTROL:      s_axil_rdata <= {29'd0, cfg_capture_enable, 1'b0, cfg_enable};
          REG_STATUS:       s_axil_rdata <= {24'd0, writer_state_q, rx_overflow_sync, link_up, fifo_tvalid, fifo_s_ready, m_axi_bvalid, m_axi_wvalid, m_axi_awvalid};
          REG_RING_BASE_LO: s_axil_rdata <= cfg_ring_base[31:0];
          REG_RING_BASE_HI: s_axil_rdata <= cfg_ring_base[63:32];
          REG_RING_SIZE:    s_axil_rdata <= cfg_ring_size;
          REG_TRUNC_BYTES:  s_axil_rdata <= cfg_trunc_bytes;
          REG_WRITE_PTR:    s_axil_rdata <= write_ptr_q;
          REG_RX_PKTS_LO:   s_axil_rdata <= stat_rx_pkts_sync_q[31:0];
          REG_RX_PKTS_HI:   s_axil_rdata <= stat_rx_pkts_sync_q[63:32];
          REG_RX_BYTES_LO:  s_axil_rdata <= stat_rx_bytes_sync_q[31:0];
          REG_RX_BYTES_HI:  s_axil_rdata <= stat_rx_bytes_sync_q[63:32];
          REG_RX_ERRS_LO:   s_axil_rdata <= stat_rx_errs_sync_q[31:0];
          REG_RX_ERRS_HI:   s_axil_rdata <= stat_rx_errs_sync_q[63:32];
          REG_CAP_BYTES_LO: s_axil_rdata <= stat_cap_bytes_q[31:0];
          REG_CAP_BYTES_HI: s_axil_rdata <= stat_cap_bytes_q[63:32];
          REG_AXI_WR_LO:    s_axil_rdata <= stat_axi_writes_q[31:0];
          REG_AXI_WR_HI:    s_axil_rdata <= stat_axi_writes_q[63:32];
          REG_AXI_ERR_LO:   s_axil_rdata <= stat_axi_errors_q[31:0];
          REG_AXI_ERR_HI:   s_axil_rdata <= stat_axi_errors_q[63:32];
          REG_DEBUG:        s_axil_rdata <= {7'd0, rx_fifo_clear, capture_remaining_q[15:0], 5'd0, in_packet_q, writer_state_q};
          REG_GAP_COUNT_LO: s_axil_rdata <= stat_gap_count_sync_q[31:0];
          REG_GAP_COUNT_HI: s_axil_rdata <= stat_gap_count_sync_q[63:32];
          REG_GAP_SUM_LO:   s_axil_rdata <= stat_gap_sum_sync_q[31:0];
          REG_GAP_SUM_HI:   s_axil_rdata <= stat_gap_sum_sync_q[63:32];
          REG_GAP_MIN_LO:   s_axil_rdata <= stat_gap_min_sync_q[31:0];
          REG_GAP_MIN_HI:   s_axil_rdata <= stat_gap_min_sync_q[63:32];
          REG_GAP_MAX_LO:   s_axil_rdata <= stat_gap_max_sync_q[31:0];
          REG_GAP_MAX_HI:   s_axil_rdata <= stat_gap_max_sync_q[63:32];
          REG_GAP_LAST_LO:  s_axil_rdata <= stat_gap_last_sync_q[31:0];
          REG_GAP_LAST_HI:  s_axil_rdata <= stat_gap_last_sync_q[63:32];
          REG_RX_TICK_LO:   s_axil_rdata <= rx_tick_sync_q[31:0];
          REG_RX_TICK_HI:   s_axil_rdata <= rx_tick_sync_q[63:32];
          REG_GAP_SAMPLE_INDEX: s_axil_rdata <= {{(32-GAP_SAMPLE_DEPTH_LOG2){1'b0}}, gap_sample_rd_index_q};
          REG_GAP_SAMPLE_COUNT: s_axil_rdata <= gap_sample_count_q;
          REG_GAP_SAMPLE_LO:    s_axil_rdata <= gap_sample_rd_q[31:0];
          REG_GAP_SAMPLE_HI:    s_axil_rdata <= gap_sample_rd_q[63:32];
          REG_GAP_SAMPLE_WRITE_INDEX: s_axil_rdata <= {{(32-GAP_SAMPLE_DEPTH_LOG2){1'b0}}, gap_sample_wr_ptr_q};
          REG_EVENT_INDEX:       s_axil_rdata <= {{(32-EVENT_RING_INDEX_W){1'b0}}, event_rd_index_q};
          REG_EVENT_COUNT_LO:    s_axil_rdata <= event_ring_count_q[31:0];
          REG_EVENT_COUNT_HI:    s_axil_rdata <= event_ring_count_q[63:32];
          REG_EVENT_DATA_LO:     s_axil_rdata <= event_rd_sample_q[31:0];
          REG_EVENT_DATA_HI:     s_axil_rdata <= event_rd_sample_q[63:32];
          REG_EVENT_WRITE_INDEX: s_axil_rdata <= {{(32-EVENT_RING_INDEX_W){1'b0}}, event_ring_wr_word_q, 3'd0};
          REG_EVENT_DROP_LO:     s_axil_rdata <= rx_event_drop_sync_q[31:0];
          REG_EVENT_DROP_HI:     s_axil_rdata <= rx_event_drop_sync_q[63:32];
          REG_EVENT_CAPACITY:    s_axil_rdata <= EVENT_RING_SAMPLES_U32;
          REG_HIST_INDEX:        s_axil_rdata <= {28'd0, gap_hist_rd_index_q};
          REG_HIST_COUNT_LO:     s_axil_rdata <= gap_hist_sync_q[gap_hist_rd_index_q][31:0];
          REG_HIST_COUNT_HI:     s_axil_rdata <= gap_hist_sync_q[gap_hist_rd_index_q][63:32];
          REG_RX_CAPABILITIES:   s_axil_rdata <= 32'h0000_0007;
          default:          s_axil_rdata <= 32'h0;
        endcase
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end

      if (!rx_pipe_flush) begin
        case (writer_state_q)
        2'd0: begin
          if (fifo_pipe_consume) begin
            automatic logic [31:0] rem_before;
            automatic logic [6:0] beat_bytes;
            automatic logic do_capture;
            automatic logic packet_beat;

            packet_beat = in_packet_q || fifo_pipe_tstart_q;
            rem_before = fifo_pipe_tstart_q ? cfg_trunc_bytes : capture_remaining_q;
            beat_bytes = popcount_keep(fifo_pipe_tkeep_q);
            do_capture = packet_beat && cfg_capture_enable && (cfg_ring_size != 32'd0) && (rem_before != 32'd0);

            if (fifo_pipe_tstart_q && fifo_pipe_tgap_valid_q) begin
              gap_sample_mem[gap_sample_wr_ptr_q] <= fifo_pipe_tgap_q;
              gap_sample_wr_ptr_q <= gap_sample_wr_ptr_q + {{(GAP_SAMPLE_DEPTH_LOG2-1){1'b0}}, 1'b1};
              if (gap_sample_count_q < GAP_SAMPLE_DEPTH_U32) begin
                gap_sample_count_q <= gap_sample_count_q + 32'd1;
              end
            end

            // The debug ring stores full 512-bit beats; TKEEP-derived counters
            // still tell software how many bytes in each beat were meaningful.
            m_axi_wdata <= fifo_pipe_tdata_q;
            m_axi_wstrb <= {AXIS_KEEP_W_P{1'b1}};

            if (packet_beat) begin
              stat_rx_bytes_inc_q <= beat_bytes;
              stat_rx_bytes_inc_valid_q <= 1'b1;
              if (fifo_pipe_tlast_q) begin
                stat_rx_pkts_q <= stat_rx_pkts_q + 64'd1;
                if (fifo_pipe_tuser_q) begin
                  stat_rx_errs_q <= stat_rx_errs_q + 64'd1;
                end
                in_packet_q <= 1'b0;
                capture_remaining_q <= 32'd0;
              end else begin
                in_packet_q <= 1'b1;
                capture_remaining_q <= (rem_before > AXIS_KEEP_W_P) ? (rem_before - AXIS_KEEP_W_P) : 32'd0;
              end
            end

            if (do_capture) begin
              m_axi_awaddr  <= cfg_ring_base + {32'd0, write_ptr_q};
              m_axi_awvalid <= 1'b1;
              m_axi_wvalid  <= 1'b1;
              m_axi_bready  <= 1'b1;
              aw_done_q     <= 1'b0;
              w_done_q      <= 1'b0;
              writer_state_q <= 2'd1;
              if (write_ptr_q + AXIS_KEEP_W_P >= cfg_ring_size) begin
                write_ptr_q <= 32'd0;
              end else begin
                write_ptr_q <= write_ptr_q + AXIS_KEEP_W_P;
              end
            end
          end
        end
        2'd1: begin
          if (m_axi_awvalid && m_axi_awready) begin
            m_axi_awvalid <= 1'b0;
            aw_done_q <= 1'b1;
          end
          if (m_axi_wvalid && m_axi_wready) begin
            m_axi_wvalid <= 1'b0;
            w_done_q <= 1'b1;
          end
          if ((aw_done_q || (m_axi_awvalid && m_axi_awready)) &&
              (w_done_q || (m_axi_wvalid && m_axi_wready))) begin
            writer_state_q <= 2'd2;
          end
        end
        2'd2: begin
          if (m_axi_bvalid) begin
            stat_axi_writes_q <= stat_axi_writes_q + 64'd1;
            stat_cap_bytes_q <= stat_cap_bytes_q + 64'd64;
            if (m_axi_bresp != 2'b00) begin
              stat_axi_errors_q <= stat_axi_errors_q + 64'd1;
            end
            m_axi_bready <= 1'b0;
            writer_state_q <= 2'd0;
          end
        end
        default: writer_state_q <= 2'd0;
        endcase
      end
    end
  end
endmodule
