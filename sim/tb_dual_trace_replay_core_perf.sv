`timescale 1ns/1ps

import traffic_replay_pkg::*;

module tb_dual_trace_replay_core_perf;
  localparam int PORTS = 2;
  localparam int CLK_MHZ = 300;
  localparam int CMD_Q_DEPTH = 128;
  localparam logic [63:0] DESC_BASE = 64'h0000_0000;
  localparam logic [63:0] DATA_BASE = 64'h1000_0000;

  logic clk = 1'b0;
  logic rstn = 1'b0;
  always #1.666 clk = ~clk;

  logic [PORTS-1:0][15:0] axil_awaddr;
  logic [PORTS-1:0]       axil_awvalid;
  logic [PORTS-1:0]       axil_awready;
  logic [PORTS-1:0][31:0] axil_wdata;
  logic [PORTS-1:0][3:0]  axil_wstrb;
  logic [PORTS-1:0]       axil_wvalid;
  logic [PORTS-1:0]       axil_wready;
  logic [PORTS-1:0][1:0]  axil_bresp;
  logic [PORTS-1:0]       axil_bvalid;
  logic [PORTS-1:0]       axil_bready;
  logic [PORTS-1:0][15:0] axil_araddr;
  logic [PORTS-1:0]       axil_arvalid;
  logic [PORTS-1:0]       axil_arready;
  logic [PORTS-1:0][31:0] axil_rdata;
  logic [PORTS-1:0][1:0]  axil_rresp;
  logic [PORTS-1:0]       axil_rvalid;
  logic [PORTS-1:0]       axil_rready;

  logic [PORTS-1:0][511:0] host_tdata;
  logic [PORTS-1:0][63:0]  host_tkeep;
  logic [PORTS-1:0]        host_tvalid;
  logic [PORTS-1:0]        host_tready;
  logic [PORTS-1:0]        host_tlast;

  logic [PORTS-1:0][3:0]   arid;
  logic [PORTS-1:0][63:0]  araddr;
  logic [PORTS-1:0][7:0]   arlen;
  logic [PORTS-1:0][2:0]   arsize;
  logic [PORTS-1:0][1:0]   arburst;
  logic [PORTS-1:0]        arvalid;
  logic [PORTS-1:0]        arready;
  logic [PORTS-1:0][3:0]   rid;
  logic [PORTS-1:0][511:0] rdata;
  logic [PORTS-1:0][1:0]   rresp;
  logic [PORTS-1:0]        rlast;
  logic [PORTS-1:0]        rvalid;
  logic [PORTS-1:0]        rready;

  logic [PORTS-1:0][511:0] tx_tdata;
  logic [PORTS-1:0][63:0]  tx_tkeep;
  logic [PORTS-1:0]        tx_tvalid;
  logic [PORTS-1:0]        tx_tready;
  logic [PORTS-1:0]        tx_tlast;
  logic [PORTS-1:0]        tx_tuser;

  int unsigned case_pkt_len;
  longint unsigned case_pkt_count;
  longint unsigned case_gap_ticks;
  int unsigned case_latency_cycles;
  int unsigned case_ar_stall_period;
  int unsigned case_beats_per_pkt;
  bit expect_over_100g;
  bit expect_wire_over_100g;
  bit check_underrun;
  string case_name;

  longint unsigned cycle_count;
  longint unsigned tx_pkt_count [PORTS];
  longint unsigned tx_beat_count [PORTS];
  longint unsigned tx_byte_count [PORTS];
  longint unsigned first_tx_cycle [PORTS];
  longint unsigned last_tx_cycle [PORTS];
  longint unsigned steady_start_cycle [PORTS];
  longint unsigned steady_last_cycle [PORTS];
  longint unsigned steady_beat_count [PORTS];
  longint unsigned steady_byte_count [PORTS];
  longint unsigned expected_pkt_idx [PORTS];
  int unsigned expected_beat_idx [PORTS];
  int unsigned warmup_pkts;

  logic [63:0] cmd_addr_mem [PORTS][CMD_Q_DEPTH];
  logic [8:0]  cmd_beats_mem [PORTS][CMD_Q_DEPTH];
  longint unsigned cmd_ready_cycle_mem [PORTS][CMD_Q_DEPTH];
  int unsigned cmd_wr_ptr [PORTS];
  int unsigned cmd_rd_ptr [PORTS];
  int unsigned cmd_count [PORTS];
  int unsigned rsp_beat_idx [PORTS];
  longint unsigned ar_count [PORTS];
  longint unsigned desc_ar_count [PORTS];
  longint unsigned payload_ar_count [PORTS];
  longint unsigned desc_ar_beats [PORTS];
  longint unsigned payload_ar_beats [PORTS];

  function automatic logic [15:0] beats_from_bytes(input logic [15:0] byte_count);
    begin
      beats_from_bytes = (byte_count[5:0] == 6'd0) ? (byte_count >> 6) : ((byte_count >> 6) + 16'd1);
    end
  endfunction

  function automatic logic [7:0] payload_byte(
    input int unsigned port,
    input longint unsigned word_idx,
    input int unsigned byte_idx
  );
    begin
      payload_byte = 8'((word_idx * 17 + byte_idx * 3 + (word_idx >> 4) + port * 89) & 8'hff);
    end
  endfunction

  function automatic logic [511:0] payload_word(
    input int unsigned port,
    input longint unsigned word_idx
  );
    logic [511:0] word;
    begin
      word = '0;
      for (int i = 0; i < 64; i++) begin
        word[i*8 +: 8] = payload_byte(port, word_idx, i);
      end
      payload_word = word;
    end
  endfunction

  function automatic logic [511:0] model_read_word(
    input int unsigned port,
    input logic [63:0] addr
  );
    logic [511:0] word;
    longint unsigned idx;
    longint unsigned payload_idx;
    begin
      word = '0;
      if ((addr >= DESC_BASE) && (addr < DATA_BASE)) begin
        idx = (addr - DESC_BASE) >> DESC_WORD_SHIFT;
        word[63:0]    = case_gap_ticks;
        word[95:64]   = 32'(idx * case_beats_per_pkt);
        word[111:96]  = 16'(case_pkt_len);
        word[127:112] = 16'd0;
      end else begin
        payload_idx = (addr - DATA_BASE) >> DESC_WORD_SHIFT;
        word = payload_word(port, payload_idx);
      end
      model_read_word = word;
    end
  endfunction

  function automatic int unsigned bytes_in_output_beat(input int unsigned beat_idx);
    int unsigned remaining;
    begin
      remaining = case_pkt_len - beat_idx * 64;
      bytes_in_output_beat = (remaining >= 64) ? 64 : remaining;
    end
  endfunction

  function automatic logic [63:0] expected_keep(input int unsigned beat_idx);
    logic [63:0] keep;
    int unsigned valid_bytes;
    begin
      valid_bytes = bytes_in_output_beat(beat_idx);
      keep = '0;
      for (int i = 0; i < 64; i++) begin
        keep[i] = (i < valid_bytes);
      end
      expected_keep = keep;
    end
  endfunction

  for (genvar gi = 0; gi < PORTS; gi++) begin : gen_port
    localparam int P = gi;

    traffic_replay_top_stub dut (
      .clk(clk),
      .rstn(rstn),
      .link_up(1'b1),
      .s_axil_awaddr(axil_awaddr[P]),
      .s_axil_awvalid(axil_awvalid[P]),
      .s_axil_awready(axil_awready[P]),
      .s_axil_wdata(axil_wdata[P]),
      .s_axil_wstrb(axil_wstrb[P]),
      .s_axil_wvalid(axil_wvalid[P]),
      .s_axil_wready(axil_wready[P]),
      .s_axil_bresp(axil_bresp[P]),
      .s_axil_bvalid(axil_bvalid[P]),
      .s_axil_bready(axil_bready[P]),
      .s_axil_araddr(axil_araddr[P]),
      .s_axil_arvalid(axil_arvalid[P]),
      .s_axil_arready(axil_arready[P]),
      .s_axil_rdata(axil_rdata[P]),
      .s_axil_rresp(axil_rresp[P]),
      .s_axil_rvalid(axil_rvalid[P]),
      .s_axil_rready(axil_rready[P]),
      .s_host_axis_tdata(host_tdata[P]),
      .s_host_axis_tkeep(host_tkeep[P]),
      .s_host_axis_tvalid(host_tvalid[P]),
      .s_host_axis_tready(host_tready[P]),
      .s_host_axis_tlast(host_tlast[P]),
      .m_axi_arid(arid[P]),
      .m_axi_araddr(araddr[P]),
      .m_axi_arlen(arlen[P]),
      .m_axi_arsize(arsize[P]),
      .m_axi_arburst(arburst[P]),
      .m_axi_arvalid(arvalid[P]),
      .m_axi_arready(arready[P]),
      .m_axi_rid(rid[P]),
      .m_axi_rdata(rdata[P]),
      .m_axi_rresp(rresp[P]),
      .m_axi_rlast(rlast[P]),
      .m_axi_rvalid(rvalid[P]),
      .m_axi_rready(rready[P]),
      .m_tx_axis_tdata(tx_tdata[P]),
      .m_tx_axis_tkeep(tx_tkeep[P]),
      .m_tx_axis_tvalid(tx_tvalid[P]),
      .m_tx_axis_tready(tx_tready[P]),
      .m_tx_axis_tlast(tx_tlast[P]),
      .m_tx_axis_tuser(tx_tuser[P])
    );

    assign arready[P] =
      rstn &&
      (cmd_count[P] < CMD_Q_DEPTH) &&
      ((case_ar_stall_period == 0) ||
       (((cycle_count + P) % case_ar_stall_period) != (case_ar_stall_period - 1)));

    assign tx_tready[P] = rstn;

    always_ff @(posedge clk) begin
      bit ar_push;
      bit cmd_pop;
      if (!rstn) begin
        rid[P]          <= '0;
        rdata[P]        <= '0;
        rresp[P]        <= 2'b00;
        rlast[P]        <= 1'b0;
        rvalid[P]       <= 1'b0;
        cmd_wr_ptr[P]   <= 0;
        cmd_rd_ptr[P]   <= 0;
        cmd_count[P]    <= 0;
        rsp_beat_idx[P] <= 0;
      end else begin
        ar_push = arvalid[P] && arready[P];
        cmd_pop = rvalid[P] && rready[P] && rlast[P];

        if (ar_push) begin
          cmd_addr_mem[P][cmd_wr_ptr[P]]        <= araddr[P];
          cmd_beats_mem[P][cmd_wr_ptr[P]]       <= {1'b0, arlen[P]} + 9'd1;
          cmd_ready_cycle_mem[P][cmd_wr_ptr[P]] <= cycle_count + case_latency_cycles;
          cmd_wr_ptr[P] <= (cmd_wr_ptr[P] + 1) % CMD_Q_DEPTH;
        end

        if (rvalid[P]) begin
          if (rready[P]) begin
            if (rlast[P]) begin
              rvalid[P]       <= 1'b0;
              rlast[P]        <= 1'b0;
              rsp_beat_idx[P] <= 0;
              cmd_rd_ptr[P]   <= (cmd_rd_ptr[P] + 1) % CMD_Q_DEPTH;
            end else begin
              rsp_beat_idx[P] <= rsp_beat_idx[P] + 1;
              rdata[P]        <= model_read_word(P, cmd_addr_mem[P][cmd_rd_ptr[P]] + (64'(rsp_beat_idx[P] + 1) << DESC_WORD_SHIFT));
              rlast[P]        <= ((rsp_beat_idx[P] + 1) == (cmd_beats_mem[P][cmd_rd_ptr[P]] - 1));
            end
          end
        end else if ((cmd_count[P] != 0) && (cycle_count >= cmd_ready_cycle_mem[P][cmd_rd_ptr[P]])) begin
          rvalid[P]       <= 1'b1;
          rresp[P]        <= 2'b00;
          rid[P]          <= '0;
          rdata[P]        <= model_read_word(P, cmd_addr_mem[P][cmd_rd_ptr[P]]);
          rlast[P]        <= (cmd_beats_mem[P][cmd_rd_ptr[P]] == 9'd1);
          rsp_beat_idx[P] <= 0;
        end

        unique case ({ar_push, cmd_pop})
          2'b10: cmd_count[P] <= cmd_count[P] + 1;
          2'b01: cmd_count[P] <= cmd_count[P] - 1;
          default: begin
          end
        endcase
      end
    end

    always_ff @(posedge clk) begin
      longint unsigned word_idx;
      int unsigned valid_bytes;
      logic [63:0] exp_keep;

      if (!rstn) begin
        tx_pkt_count[P]       <= '0;
        tx_beat_count[P]      <= '0;
        tx_byte_count[P]      <= '0;
        first_tx_cycle[P]     <= '0;
        last_tx_cycle[P]      <= '0;
        steady_start_cycle[P] <= '0;
        steady_last_cycle[P]  <= '0;
        steady_beat_count[P]  <= '0;
        steady_byte_count[P]  <= '0;
        expected_pkt_idx[P]   <= '0;
        expected_beat_idx[P]  <= 0;
      end else if (tx_tvalid[P] && tx_tready[P]) begin
        if (tx_beat_count[P] == 0) begin
          first_tx_cycle[P] <= cycle_count;
        end
        last_tx_cycle[P] <= cycle_count;

        valid_bytes = bytes_in_output_beat(expected_beat_idx[P]);
        exp_keep = expected_keep(expected_beat_idx[P]);
        if (tx_tkeep[P] !== exp_keep) begin
          $fatal(1, "%s port%0d keep mismatch pkt=%0d beat=%0d got=0x%016x exp=0x%016x",
                 case_name, P, expected_pkt_idx[P], expected_beat_idx[P], tx_tkeep[P], exp_keep);
        end
        if (tx_tlast[P] !== (expected_beat_idx[P] == (case_beats_per_pkt - 1))) begin
          $fatal(1, "%s port%0d tlast mismatch pkt=%0d beat=%0d got=%0b",
                 case_name, P, expected_pkt_idx[P], expected_beat_idx[P], tx_tlast[P]);
        end

        word_idx = expected_pkt_idx[P] * case_beats_per_pkt + expected_beat_idx[P];
        for (int i = 0; i < 64; i++) begin
          if ((i < valid_bytes) && (tx_tdata[P][i*8 +: 8] !== payload_byte(P, word_idx, i))) begin
            $fatal(1, "%s port%0d data mismatch pkt=%0d beat=%0d byte=%0d got=0x%02x exp=0x%02x",
                   case_name, P, expected_pkt_idx[P], expected_beat_idx[P], i,
                   tx_tdata[P][i*8 +: 8], payload_byte(P, word_idx, i));
          end
        end

        tx_beat_count[P] <= tx_beat_count[P] + 1;
        tx_byte_count[P] <= tx_byte_count[P] + valid_bytes;

        if ((expected_pkt_idx[P] >= warmup_pkts) && (expected_pkt_idx[P] < (case_pkt_count - warmup_pkts))) begin
          if (steady_beat_count[P] == 0) begin
            steady_start_cycle[P] <= cycle_count;
          end
          steady_last_cycle[P] <= cycle_count;
          steady_beat_count[P] <= steady_beat_count[P] + 1;
          steady_byte_count[P] <= steady_byte_count[P] + valid_bytes;
        end

        if (tx_tlast[P]) begin
          tx_pkt_count[P] <= tx_pkt_count[P] + 1;
          expected_pkt_idx[P] <= expected_pkt_idx[P] + 1;
          expected_beat_idx[P] <= 0;
        end else begin
          expected_beat_idx[P] <= expected_beat_idx[P] + 1;
        end
      end
    end

    always_ff @(posedge clk) begin
      if (!rstn) begin
        ar_count[P]         <= '0;
        desc_ar_count[P]    <= '0;
        payload_ar_count[P] <= '0;
        desc_ar_beats[P]    <= '0;
        payload_ar_beats[P] <= '0;
      end else if (arvalid[P] && arready[P]) begin
        ar_count[P] <= ar_count[P] + 1;
        if (araddr[P] < DATA_BASE) begin
          desc_ar_count[P] <= desc_ar_count[P] + 1;
          desc_ar_beats[P] <= desc_ar_beats[P] + ({1'b0, arlen[P]} + 9'd1);
        end else begin
          payload_ar_count[P] <= payload_ar_count[P] + 1;
          payload_ar_beats[P] <= payload_ar_beats[P] + ({1'b0, arlen[P]} + 9'd1);
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      cycle_count <= '0;
    end else begin
      cycle_count <= cycle_count + 1;
    end
  end

  task automatic axil_write_both(input [15:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      for (int p = 0; p < PORTS; p++) begin
        axil_awaddr[p]  <= addr;
        axil_awvalid[p] <= 1'b1;
        axil_wdata[p]   <= data;
        axil_wstrb[p]   <= 4'hf;
        axil_wvalid[p]  <= 1'b1;
        axil_bready[p]  <= 1'b1;
      end
      wait (&(axil_awready & axil_wready));
      @(posedge clk);
      axil_awvalid <= '0;
      axil_wvalid  <= '0;
      wait (&axil_bvalid);
      @(posedge clk);
      axil_bready <= '0;
    end
  endtask

  task automatic axil_read_one(input int unsigned port, input [15:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      axil_araddr[port]  <= addr;
      axil_arvalid[port] <= 1'b1;
      axil_rready[port]  <= 1'b1;
      wait (axil_arready[port]);
      @(posedge clk);
      axil_arvalid[port] <= 1'b0;
      wait (axil_rvalid[port]);
      data = axil_rdata[port];
      @(posedge clk);
      axil_rready[port] <= 1'b0;
    end
  endtask

  task automatic reset_case;
    begin
      rstn = 1'b0;
      axil_awaddr  = '0;
      axil_awvalid = '0;
      axil_wdata   = '0;
      axil_wstrb   = '0;
      axil_wvalid  = '0;
      axil_bready  = '0;
      axil_araddr  = '0;
      axil_arvalid = '0;
      axil_rready  = '0;
      host_tdata   = '0;
      host_tkeep   = '0;
      host_tvalid  = '0;
      host_tlast   = '0;
      repeat (20) @(posedge clk);
      rstn = 1'b1;
      repeat (20) @(posedge clk);
    end
  endtask

  task automatic configure_preload_both;
    begin
      axil_write_both(16'h0004, 32'd0);
      axil_write_both(16'h0010, DESC_BASE[31:0]);
      axil_write_both(16'h0014, DESC_BASE[63:32]);
      axil_write_both(16'h0018, DATA_BASE[31:0]);
      axil_write_both(16'h001c, DATA_BASE[63:32]);
      axil_write_both(16'h0028, case_pkt_count[31:0]);
      axil_write_both(16'h002c, case_pkt_count[63:32]);
      axil_write_both(16'h0040, 32'd0);
      axil_write_both(16'h0044, 32'd0);
      axil_write_both(16'h0000, 32'd1);
    end
  endtask

  task automatic report_port(input int unsigned p);
    longint unsigned active_cycles;
    longint unsigned steady_cycles;
    real l2_gbps;
    real axis_gbps;
    real steady_l2_gbps;
    real steady_axis_gbps;
    real pps_m;
    real steady_pps_m;
    real wire_gbps;
    real steady_wire_gbps;
    real steady_pkt_count;
    real payload_avg_burst;
    logic [31:0] status;
    logic [31:0] tx_pkts_lo;
    logic [31:0] underrun_lo;
    begin
      active_cycles = last_tx_cycle[p] - first_tx_cycle[p] + 1;
      steady_cycles = steady_last_cycle[p] - steady_start_cycle[p] + 1;
      l2_gbps = (tx_byte_count[p] * 8.0 * CLK_MHZ) / (active_cycles * 1000.0);
      axis_gbps = (tx_beat_count[p] * 64.0 * 8.0 * CLK_MHZ) / (active_cycles * 1000.0);
      pps_m = (tx_pkt_count[p] * 1.0 * CLK_MHZ) / active_cycles;
      wire_gbps = (tx_pkt_count[p] * (case_pkt_len + 20.0) * 8.0 * CLK_MHZ) / (active_cycles * 1000.0);
      steady_l2_gbps = (steady_byte_count[p] * 8.0 * CLK_MHZ) / (steady_cycles * 1000.0);
      steady_axis_gbps = (steady_beat_count[p] * 64.0 * 8.0 * CLK_MHZ) / (steady_cycles * 1000.0);
      steady_pkt_count = steady_byte_count[p] * 1.0 / case_pkt_len;
      steady_pps_m = (steady_pkt_count * CLK_MHZ) / steady_cycles;
      steady_wire_gbps = (steady_pkt_count * (case_pkt_len + 20.0) * 8.0 * CLK_MHZ) / (steady_cycles * 1000.0);
      payload_avg_burst = (payload_ar_count[p] == 0) ? 0.0 : (payload_ar_beats[p] * 1.0 / payload_ar_count[p]);

      axil_read_one(p, 16'h0008, status);
      axil_read_one(p, 16'h0060, tx_pkts_lo);
      axil_read_one(p, 16'h0078, underrun_lo);

      $display("DUAL %-28s port=%0d pkt_len=%0d pkts=%0d latency=%0d ar_stall_period=%0d",
               case_name, p, case_pkt_len, case_pkt_count, case_latency_cycles, case_ar_stall_period);
      $display("  output: packets=%0d beats=%0d bytes=%0d active_cycles=%0d pps=%.3fM l2=%.3fGbps wire=%.3fGbps axis=%.3fGbps",
               tx_pkt_count[p], tx_beat_count[p], tx_byte_count[p], active_cycles, pps_m, l2_gbps, wire_gbps, axis_gbps);
      $display("  steady: warmup_pkts=%0d beats=%0d bytes=%0d cycles=%0d pps=%.3fM l2=%.3fGbps wire=%.3fGbps axis=%.3fGbps",
               warmup_pkts, steady_beat_count[p], steady_byte_count[p], steady_cycles,
               steady_pps_m, steady_l2_gbps, steady_wire_gbps, steady_axis_gbps);
      $display("  axi_ar: total=%0d desc=%0d payload=%0d desc_beats=%0d payload_beats=%0d payload_avg_burst=%.2f",
               ar_count[p], desc_ar_count[p], payload_ar_count[p], desc_ar_beats[p],
               payload_ar_beats[p], payload_avg_burst);
      $display("  regs: status=0x%08x tx_pkts_lo=%0d underrun_lo=%0d", status, tx_pkts_lo, underrun_lo);

      if (check_underrun && (status[3] || (underrun_lo != 32'd0))) begin
        $fatal(1, "%s port%0d underrun detected status=0x%08x underrun_lo=%0d", case_name, p, status, underrun_lo);
      end
      if (expect_over_100g && (steady_l2_gbps < 100.0)) begin
        $fatal(1, "%s port%0d steady core throughput %.3fGbps below 100Gbps target", case_name, p, steady_l2_gbps);
      end
      if (expect_wire_over_100g && (steady_wire_gbps < 100.0)) begin
        $fatal(1, "%s port%0d steady wire throughput %.3fGbps below 100Gbps target", case_name, p, steady_wire_gbps);
      end
    end
  endtask

  task automatic run_case(
    input string name_i,
    input longint unsigned pkt_count_i,
    input int unsigned pkt_len_i,
    input longint unsigned gap_ticks_i,
    input int unsigned latency_i,
    input int unsigned ar_stall_period_i,
    input bit expect_over_100g_i,
    input bit expect_wire_over_100g_i,
    input bit check_underrun_i
  );
    longint unsigned timeout_cycles;
    begin
      case_name = name_i;
      case_pkt_count = pkt_count_i;
      case_pkt_len = pkt_len_i;
      case_gap_ticks = gap_ticks_i;
      case_latency_cycles = latency_i;
      case_ar_stall_period = ar_stall_period_i;
      case_beats_per_pkt = beats_from_bytes(16'(pkt_len_i));
      expect_over_100g = expect_over_100g_i;
      expect_wire_over_100g = expect_wire_over_100g_i;
      check_underrun = check_underrun_i;
      warmup_pkts = (pkt_count_i > 16384) ? 4096 : ((pkt_count_i > 1024) ? 256 : 16);

      reset_case();
      configure_preload_both();

      timeout_cycles = pkt_count_i * (case_beats_per_pkt + 24) + latency_i * 16 + 30000;
      for (longint unsigned timeout = 0; timeout < timeout_cycles; timeout++) begin
        @(posedge clk);
        if ((tx_pkt_count[0] == pkt_count_i) && (tx_pkt_count[1] == pkt_count_i)) begin
          break;
        end
      end

      for (int p = 0; p < PORTS; p++) begin
        if (tx_pkt_count[p] != pkt_count_i) begin
          $fatal(1, "%s port%0d packet count mismatch got=%0d exp=%0d",
                 case_name, p, tx_pkt_count[p], pkt_count_i);
        end
      end

      for (int p = 0; p < PORTS; p++) begin
        report_port(p);
      end
      repeat (20) @(posedge clk);
    end
  endtask

  initial begin
    run_case("dual_1518B_latency64", 4096, 1518, 0, 64, 0, 1'b1, 1'b1, 1'b1);
    run_case("dual_64B_gap2_wire100", 32768, 64, 2, 64, 0, 1'b0, 1'b1, 1'b1);

    $display("PASS: dual trace_replay_core concurrent preload correctness and throughput simulation completed");
    $finish;
  end

  initial begin
    repeat (20000000) @(posedge clk);
    $fatal(1, "Simulation watchdog timeout");
  end
endmodule
