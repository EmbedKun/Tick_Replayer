`timescale 1ns/1ps

module axi_lite_regs #(
  parameter int ADDR_W = 16,
  parameter int DATA_W = 32
) (
  input  logic              aclk,
  input  logic              aresetn,

  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [DATA_W-1:0] s_axil_wdata,
  input  logic [DATA_W/8-1:0] s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,

  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [DATA_W-1:0] s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,

  output logic              start_pulse,
  output logic              stop_pulse,
  output logic              clear_pulse,
  output logic              pause,
  output logic [1:0]        cfg_mode,
  output logic [63:0]       cfg_desc_base,
  output logic [63:0]       cfg_data_base,
  output logic [63:0]       cfg_trace_bytes,
  output logic [63:0]       cfg_pkt_count,
  output logic [63:0]       cfg_loop_count,
  output logic [63:0]       cfg_loop_gap_ticks,
  output logic [63:0]       cfg_start_time,
  output logic [31:0]       cfg_rate_q16_16,
  output logic [31:0]       cfg_watermark,
  output logic              cfg_force_link_up,
  output logic              cfg_force_tx_ready,

  input  logic              stat_running,
  input  logic              stat_done,
  input  logic              stat_late,
  input  logic              stat_underrun,
  input  logic              stat_link_up,
  input  logic              stat_effective_link_up,
  input  logic [31:0]       stat_fifo_level,
  input  logic [63:0]       stat_tx_pkts,
  input  logic [63:0]       stat_tx_bytes,
  input  logic [63:0]       stat_late_pkts,
  input  logic [63:0]       stat_underrun_pkts,
  input  logic [31:0]       stat_debug_status,
  input  logic [31:0]       stat_debug_axi,
  input  logic [63:0]       stat_debug_araddr,
  input  logic [31:0]       stat_debug_rdata_low,
  input  logic [63:0]       stat_debug_ticks
);
  localparam logic [ADDR_W-1:0] REG_CONTROL      = 16'h0000;
  localparam logic [ADDR_W-1:0] REG_MODE         = 16'h0004;
  localparam logic [ADDR_W-1:0] REG_STATUS       = 16'h0008;
  localparam logic [ADDR_W-1:0] REG_DESC_BASE_LO = 16'h0010;
  localparam logic [ADDR_W-1:0] REG_DESC_BASE_HI = 16'h0014;
  localparam logic [ADDR_W-1:0] REG_DATA_BASE_LO = 16'h0018;
  localparam logic [ADDR_W-1:0] REG_DATA_BASE_HI = 16'h001c;
  localparam logic [ADDR_W-1:0] REG_TRACE_LO     = 16'h0020;
  localparam logic [ADDR_W-1:0] REG_TRACE_HI     = 16'h0024;
  localparam logic [ADDR_W-1:0] REG_PKT_LO       = 16'h0028;
  localparam logic [ADDR_W-1:0] REG_PKT_HI       = 16'h002c;
  localparam logic [ADDR_W-1:0] REG_LOOP_LO      = 16'h0030;
  localparam logic [ADDR_W-1:0] REG_LOOP_HI      = 16'h0034;
  localparam logic [ADDR_W-1:0] REG_LOOP_GAP_LO  = 16'h0038;
  localparam logic [ADDR_W-1:0] REG_LOOP_GAP_HI  = 16'h003c;
  localparam logic [ADDR_W-1:0] REG_START_LO     = 16'h0040;
  localparam logic [ADDR_W-1:0] REG_START_HI     = 16'h0044;
  localparam logic [ADDR_W-1:0] REG_RATE         = 16'h0048;
  localparam logic [ADDR_W-1:0] REG_WATERMARK    = 16'h004c;
  localparam logic [ADDR_W-1:0] REG_FIFO_LEVEL   = 16'h0050;
  localparam logic [ADDR_W-1:0] REG_DEBUG_CTRL   = 16'h0054;
  localparam logic [ADDR_W-1:0] REG_TX_PKTS_LO   = 16'h0060;
  localparam logic [ADDR_W-1:0] REG_TX_PKTS_HI   = 16'h0064;
  localparam logic [ADDR_W-1:0] REG_TX_BYTES_LO  = 16'h0068;
  localparam logic [ADDR_W-1:0] REG_TX_BYTES_HI  = 16'h006c;
  localparam logic [ADDR_W-1:0] REG_LATE_LO      = 16'h0070;
  localparam logic [ADDR_W-1:0] REG_LATE_HI      = 16'h0074;
  localparam logic [ADDR_W-1:0] REG_UNDERRUN_LO  = 16'h0078;
  localparam logic [ADDR_W-1:0] REG_UNDERRUN_HI  = 16'h007c;
  localparam logic [ADDR_W-1:0] REG_DEBUG_STATUS = 16'h0080;
  localparam logic [ADDR_W-1:0] REG_DEBUG_AXI    = 16'h0084;
  localparam logic [ADDR_W-1:0] REG_DEBUG_AR_LO  = 16'h0088;
  localparam logic [ADDR_W-1:0] REG_DEBUG_AR_HI  = 16'h008c;
  localparam logic [ADDR_W-1:0] REG_DEBUG_RDATA  = 16'h0090;
  localparam logic [ADDR_W-1:0] REG_DEBUG_TICK_LO= 16'h0094;
  localparam logic [ADDR_W-1:0] REG_DEBUG_TICK_HI= 16'h0098;

  logic [ADDR_W-1:0] awaddr_q;
  logic [ADDR_W-1:0] araddr_q;
  logic aw_hold;
  logic w_hold;
  logic [DATA_W-1:0] wdata_q;
  logic [DATA_W/8-1:0] wstrb_q;
  logic do_write;

  assign s_axil_awready = !aw_hold && !s_axil_bvalid;
  assign s_axil_wready  = !w_hold && !s_axil_bvalid;
  assign do_write       = aw_hold && w_hold && !s_axil_bvalid;
  assign s_axil_bresp   = 2'b00;
  assign s_axil_rresp   = 2'b00;
  assign s_axil_arready = !s_axil_rvalid;

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

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      aw_hold            <= 1'b0;
      w_hold             <= 1'b0;
      s_axil_bvalid      <= 1'b0;
      s_axil_rvalid      <= 1'b0;
      s_axil_rdata       <= '0;
      awaddr_q           <= '0;
      araddr_q           <= '0;
      wdata_q            <= '0;
      wstrb_q            <= '0;
      start_pulse        <= 1'b0;
      stop_pulse         <= 1'b0;
      clear_pulse        <= 1'b0;
      pause              <= 1'b0;
      cfg_mode           <= 2'd0;
      cfg_desc_base      <= '0;
      cfg_data_base      <= '0;
      cfg_trace_bytes    <= '0;
      cfg_pkt_count      <= '0;
      cfg_loop_count     <= '0;
      cfg_loop_gap_ticks <= '0;
      cfg_start_time     <= '0;
      cfg_rate_q16_16    <= 32'h0001_0000;
      cfg_watermark      <= 32'd4096;
      cfg_force_link_up  <= 1'b0;
      cfg_force_tx_ready <= 1'b0;
    end else begin
      start_pulse <= 1'b0;
      stop_pulse  <= 1'b0;
      clear_pulse <= 1'b0;

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
            start_pulse <= wdata_q[0] & wstrb_q[0];
            stop_pulse  <= wdata_q[1] & wstrb_q[0];
            clear_pulse <= wdata_q[2] & wstrb_q[0];
            if (wstrb_q[0]) begin
              pause <= wdata_q[3];
            end
          end
          REG_MODE: begin
            if (wstrb_q[0]) begin
              cfg_mode <= wdata_q[1:0];
            end
          end
          REG_DESC_BASE_LO: cfg_desc_base[31:0]  <= apply_wstrb(cfg_desc_base[31:0], wdata_q, wstrb_q);
          REG_DESC_BASE_HI: cfg_desc_base[63:32] <= apply_wstrb(cfg_desc_base[63:32], wdata_q, wstrb_q);
          REG_DATA_BASE_LO: cfg_data_base[31:0]  <= apply_wstrb(cfg_data_base[31:0], wdata_q, wstrb_q);
          REG_DATA_BASE_HI: cfg_data_base[63:32] <= apply_wstrb(cfg_data_base[63:32], wdata_q, wstrb_q);
          REG_TRACE_LO:     cfg_trace_bytes[31:0]  <= apply_wstrb(cfg_trace_bytes[31:0], wdata_q, wstrb_q);
          REG_TRACE_HI:     cfg_trace_bytes[63:32] <= apply_wstrb(cfg_trace_bytes[63:32], wdata_q, wstrb_q);
          REG_PKT_LO:       cfg_pkt_count[31:0]  <= apply_wstrb(cfg_pkt_count[31:0], wdata_q, wstrb_q);
          REG_PKT_HI:       cfg_pkt_count[63:32] <= apply_wstrb(cfg_pkt_count[63:32], wdata_q, wstrb_q);
          REG_LOOP_LO:      cfg_loop_count[31:0]  <= apply_wstrb(cfg_loop_count[31:0], wdata_q, wstrb_q);
          REG_LOOP_HI:      cfg_loop_count[63:32] <= apply_wstrb(cfg_loop_count[63:32], wdata_q, wstrb_q);
          REG_LOOP_GAP_LO:  cfg_loop_gap_ticks[31:0]  <= apply_wstrb(cfg_loop_gap_ticks[31:0], wdata_q, wstrb_q);
          REG_LOOP_GAP_HI:  cfg_loop_gap_ticks[63:32] <= apply_wstrb(cfg_loop_gap_ticks[63:32], wdata_q, wstrb_q);
          REG_START_LO:     cfg_start_time[31:0]  <= apply_wstrb(cfg_start_time[31:0], wdata_q, wstrb_q);
          REG_START_HI:     cfg_start_time[63:32] <= apply_wstrb(cfg_start_time[63:32], wdata_q, wstrb_q);
          REG_RATE:         cfg_rate_q16_16 <= apply_wstrb(cfg_rate_q16_16, wdata_q, wstrb_q);
          REG_WATERMARK:    cfg_watermark   <= apply_wstrb(cfg_watermark, wdata_q, wstrb_q);
          REG_DEBUG_CTRL: begin
            if (wstrb_q[0]) begin
              cfg_force_link_up <= wdata_q[0];
              cfg_force_tx_ready <= wdata_q[1];
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
        araddr_q      <= s_axil_araddr;
        s_axil_rvalid <= 1'b1;
        unique case (s_axil_araddr)
          REG_CONTROL:     s_axil_rdata <= {28'd0, pause, 3'd0};
          REG_MODE:        s_axil_rdata <= {30'd0, cfg_mode};
          REG_STATUS:      s_axil_rdata <= {26'd0, stat_effective_link_up, stat_link_up, stat_underrun, stat_late, stat_done, stat_running};
          REG_DESC_BASE_LO:s_axil_rdata <= cfg_desc_base[31:0];
          REG_DESC_BASE_HI:s_axil_rdata <= cfg_desc_base[63:32];
          REG_DATA_BASE_LO:s_axil_rdata <= cfg_data_base[31:0];
          REG_DATA_BASE_HI:s_axil_rdata <= cfg_data_base[63:32];
          REG_TRACE_LO:    s_axil_rdata <= cfg_trace_bytes[31:0];
          REG_TRACE_HI:    s_axil_rdata <= cfg_trace_bytes[63:32];
          REG_PKT_LO:      s_axil_rdata <= cfg_pkt_count[31:0];
          REG_PKT_HI:      s_axil_rdata <= cfg_pkt_count[63:32];
          REG_LOOP_LO:     s_axil_rdata <= cfg_loop_count[31:0];
          REG_LOOP_HI:     s_axil_rdata <= cfg_loop_count[63:32];
          REG_LOOP_GAP_LO: s_axil_rdata <= cfg_loop_gap_ticks[31:0];
          REG_LOOP_GAP_HI: s_axil_rdata <= cfg_loop_gap_ticks[63:32];
          REG_START_LO:    s_axil_rdata <= cfg_start_time[31:0];
          REG_START_HI:    s_axil_rdata <= cfg_start_time[63:32];
          REG_RATE:        s_axil_rdata <= cfg_rate_q16_16;
          REG_WATERMARK:   s_axil_rdata <= cfg_watermark;
          REG_FIFO_LEVEL:  s_axil_rdata <= stat_fifo_level;
          REG_DEBUG_CTRL:  s_axil_rdata <= {30'd0, cfg_force_tx_ready, cfg_force_link_up};
          REG_TX_PKTS_LO:  s_axil_rdata <= stat_tx_pkts[31:0];
          REG_TX_PKTS_HI:  s_axil_rdata <= stat_tx_pkts[63:32];
          REG_TX_BYTES_LO: s_axil_rdata <= stat_tx_bytes[31:0];
          REG_TX_BYTES_HI: s_axil_rdata <= stat_tx_bytes[63:32];
          REG_LATE_LO:     s_axil_rdata <= stat_late_pkts[31:0];
          REG_LATE_HI:     s_axil_rdata <= stat_late_pkts[63:32];
          REG_UNDERRUN_LO: s_axil_rdata <= stat_underrun_pkts[31:0];
          REG_UNDERRUN_HI: s_axil_rdata <= stat_underrun_pkts[63:32];
          REG_DEBUG_STATUS:s_axil_rdata <= stat_debug_status;
          REG_DEBUG_AXI:   s_axil_rdata <= stat_debug_axi;
          REG_DEBUG_AR_LO: s_axil_rdata <= stat_debug_araddr[31:0];
          REG_DEBUG_AR_HI: s_axil_rdata <= stat_debug_araddr[63:32];
          REG_DEBUG_RDATA: s_axil_rdata <= stat_debug_rdata_low;
          REG_DEBUG_TICK_LO:s_axil_rdata <= stat_debug_ticks[31:0];
          REG_DEBUG_TICK_HI:s_axil_rdata <= stat_debug_ticks[63:32];
          default:         s_axil_rdata <= 32'h0;
        endcase
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end
endmodule
