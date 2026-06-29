`timescale 1ns/1ps

import traffic_replay_pkg::*;

module tb_trace_replay_core_perf;
  localparam int CLK_MHZ = 300;
  localparam int CMD_Q_DEPTH = 128;
  localparam logic [63:0] DESC_BASE = 64'h0000_0000;
  localparam logic [63:0] DATA_BASE = 64'h1000_0000;

  logic clk = 1'b0;
  logic rstn = 1'b0;
  always #1.666 clk = ~clk;

  logic [15:0] axil_awaddr;
  logic        axil_awvalid;
  logic        axil_awready;
  logic [31:0] axil_wdata;
  logic [3:0]  axil_wstrb;
  logic        axil_wvalid;
  logic        axil_wready;
  logic [1:0]  axil_bresp;
  logic        axil_bvalid;
  logic        axil_bready;
  logic [15:0] axil_araddr;
  logic        axil_arvalid;
  logic        axil_arready;
  logic [31:0] axil_rdata;
  logic [1:0]  axil_rresp;
  logic        axil_rvalid;
  logic        axil_rready;

  logic [511:0] host_tdata;
  logic [63:0]  host_tkeep;
  logic         host_tvalid;
  logic         host_tready;
  logic         host_tlast;

  logic [3:0]   arid;
  logic [63:0]  araddr;
  logic [7:0]   arlen;
  logic [2:0]   arsize;
  logic [1:0]   arburst;
  logic         arvalid;
  logic         arready;
  logic [3:0]   rid;
  logic [511:0] rdata;
  logic [1:0]   rresp;
  logic         rlast;
  logic         rvalid;
  logic         rready;

  logic [511:0] tx_tdata;
  logic [63:0]  tx_tkeep;
  logic         tx_tvalid;
  logic         tx_tready;
  logic         tx_tlast;
  logic         tx_tuser;

  traffic_replay_top_stub dut (
    .clk(clk),
    .rstn(rstn),
    .link_up(1'b1),
    .s_axil_awaddr(axil_awaddr),
    .s_axil_awvalid(axil_awvalid),
    .s_axil_awready(axil_awready),
    .s_axil_wdata(axil_wdata),
    .s_axil_wstrb(axil_wstrb),
    .s_axil_wvalid(axil_wvalid),
    .s_axil_wready(axil_wready),
    .s_axil_bresp(axil_bresp),
    .s_axil_bvalid(axil_bvalid),
    .s_axil_bready(axil_bready),
    .s_axil_araddr(axil_araddr),
    .s_axil_arvalid(axil_arvalid),
    .s_axil_arready(axil_arready),
    .s_axil_rdata(axil_rdata),
    .s_axil_rresp(axil_rresp),
    .s_axil_rvalid(axil_rvalid),
    .s_axil_rready(axil_rready),
    .s_host_axis_tdata(host_tdata),
    .s_host_axis_tkeep(host_tkeep),
    .s_host_axis_tvalid(host_tvalid),
    .s_host_axis_tready(host_tready),
    .s_host_axis_tlast(host_tlast),
    .m_axi_arid(arid),
    .m_axi_araddr(araddr),
    .m_axi_arlen(arlen),
    .m_axi_arsize(arsize),
    .m_axi_arburst(arburst),
    .m_axi_arvalid(arvalid),
    .m_axi_arready(arready),
    .m_axi_rid(rid),
    .m_axi_rdata(rdata),
    .m_axi_rresp(rresp),
    .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid),
    .m_axi_rready(rready),
    .m_tx_axis_tdata(tx_tdata),
    .m_tx_axis_tkeep(tx_tkeep),
    .m_tx_axis_tvalid(tx_tvalid),
    .m_tx_axis_tready(tx_tready),
    .m_tx_axis_tlast(tx_tlast),
    .m_tx_axis_tuser(tx_tuser)
  );

  int unsigned case_pkt_len;
  longint unsigned case_pkt_count;
  longint unsigned case_gap_ticks;
  int unsigned case_latency_cycles;
  int unsigned case_ar_stall_period;
  int unsigned case_tready_stall_period;
  int unsigned case_beats_per_pkt;
  bit expect_over_100g;
  bit expect_wire_over_100g;
  bit check_underrun;
  string case_name;

  longint unsigned cycle_count;
  longint unsigned tx_pkt_count;
  longint unsigned tx_beat_count;
  longint unsigned tx_byte_count;
  longint unsigned ar_count;
  longint unsigned desc_ar_count;
  longint unsigned payload_ar_count;
  longint unsigned desc_ar_beats;
  longint unsigned payload_ar_beats;
  longint unsigned first_tx_cycle;
  longint unsigned last_tx_cycle;
  longint unsigned steady_start_cycle;
  longint unsigned steady_last_cycle;
  longint unsigned steady_beat_count;
  longint unsigned steady_byte_count;
  longint unsigned expected_pkt_idx;
  int unsigned expected_beat_idx;
  int unsigned warmup_pkts;

  logic [63:0] cmd_addr_mem [CMD_Q_DEPTH];
  logic [8:0]  cmd_beats_mem [CMD_Q_DEPTH];
  longint unsigned cmd_ready_cycle_mem [CMD_Q_DEPTH];
  int unsigned cmd_wr_ptr;
  int unsigned cmd_rd_ptr;
  int unsigned cmd_count;
  int unsigned rsp_beat_idx;

  function automatic logic [15:0] beats_from_bytes(input logic [15:0] byte_count);
    begin
      beats_from_bytes = (byte_count[5:0] == 6'd0) ? (byte_count >> 6) : ((byte_count >> 6) + 16'd1);
    end
  endfunction

  function automatic logic [7:0] payload_byte(input longint unsigned word_idx, input int unsigned byte_idx);
    begin
      payload_byte = 8'((word_idx * 17 + byte_idx * 3 + (word_idx >> 4)) & 8'hff);
    end
  endfunction

  function automatic logic [511:0] payload_word(input longint unsigned word_idx);
    logic [511:0] word;
    begin
      word = '0;
      for (int i = 0; i < 64; i++) begin
        word[i*8 +: 8] = payload_byte(word_idx, i);
      end
      payload_word = word;
    end
  endfunction

  function automatic logic [511:0] model_read_word(input logic [63:0] addr);
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
        word = payload_word(payload_idx);
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

  assign arready =
    rstn &&
    (cmd_count < CMD_Q_DEPTH) &&
    ((case_ar_stall_period == 0) || ((cycle_count % case_ar_stall_period) != (case_ar_stall_period - 1)));

  assign tx_tready =
    rstn &&
    ((case_tready_stall_period == 0) || ((cycle_count % case_tready_stall_period) != (case_tready_stall_period - 1)));

  always_ff @(posedge clk) begin
    if (!rstn) begin
      cycle_count <= '0;
    end else begin
      cycle_count <= cycle_count + 1;
    end
  end

  always_ff @(posedge clk) begin
    bit ar_push;
    bit cmd_pop;
    if (!rstn) begin
      rid          <= '0;
      rdata        <= '0;
      rresp        <= 2'b00;
      rlast        <= 1'b0;
      rvalid       <= 1'b0;
      cmd_wr_ptr   <= 0;
      cmd_rd_ptr   <= 0;
      cmd_count    <= 0;
      rsp_beat_idx <= 0;
    end else begin
      ar_push = arvalid && arready;
      cmd_pop = rvalid && rready && rlast;

      if (ar_push) begin
        cmd_addr_mem[cmd_wr_ptr]        <= araddr;
        cmd_beats_mem[cmd_wr_ptr]       <= {1'b0, arlen} + 9'd1;
        cmd_ready_cycle_mem[cmd_wr_ptr] <= cycle_count + case_latency_cycles;
        cmd_wr_ptr <= (cmd_wr_ptr + 1) % CMD_Q_DEPTH;
      end

      if (rvalid) begin
        if (rready) begin
          if (rlast) begin
            rvalid       <= 1'b0;
            rlast        <= 1'b0;
            rsp_beat_idx <= 0;
            cmd_rd_ptr   <= (cmd_rd_ptr + 1) % CMD_Q_DEPTH;
          end else begin
            rsp_beat_idx <= rsp_beat_idx + 1;
            rdata        <= model_read_word(cmd_addr_mem[cmd_rd_ptr] + (64'(rsp_beat_idx + 1) << DESC_WORD_SHIFT));
            rlast        <= ((rsp_beat_idx + 1) == (cmd_beats_mem[cmd_rd_ptr] - 1));
          end
        end
      end else if ((cmd_count != 0) && (cycle_count >= cmd_ready_cycle_mem[cmd_rd_ptr])) begin
        rvalid       <= 1'b1;
        rresp        <= 2'b00;
        rid          <= '0;
        rdata        <= model_read_word(cmd_addr_mem[cmd_rd_ptr]);
        rlast        <= (cmd_beats_mem[cmd_rd_ptr] == 9'd1);
        rsp_beat_idx <= 0;
      end

      unique case ({ar_push, cmd_pop})
        2'b10: cmd_count <= cmd_count + 1;
        2'b01: cmd_count <= cmd_count - 1;
        default: begin
        end
      endcase
    end
  end

  task automatic axil_write(input [15:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      axil_awaddr  <= addr;
      axil_awvalid <= 1'b1;
      axil_wdata   <= data;
      axil_wstrb   <= 4'hf;
      axil_wvalid  <= 1'b1;
      axil_bready  <= 1'b1;
      wait (axil_awready && axil_wready);
      @(posedge clk);
      axil_awvalid <= 1'b0;
      axil_wvalid  <= 1'b0;
      wait (axil_bvalid);
      @(posedge clk);
      axil_bready <= 1'b0;
    end
  endtask

  task automatic axil_read(input [15:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      axil_araddr  <= addr;
      axil_arvalid <= 1'b1;
      axil_rready  <= 1'b1;
      wait (axil_arready);
      @(posedge clk);
      axil_arvalid <= 1'b0;
      wait (axil_rvalid);
      data = axil_rdata;
      @(posedge clk);
      axil_rready <= 1'b0;
    end
  endtask

  task automatic reset_case;
    begin
      rstn = 1'b0;
      axil_awaddr  = '0;
      axil_awvalid = 1'b0;
      axil_wdata   = '0;
      axil_wstrb   = 4'h0;
      axil_wvalid  = 1'b0;
      axil_bready  = 1'b0;
      axil_araddr  = '0;
      axil_arvalid = 1'b0;
      axil_rready  = 1'b0;
      host_tdata   = '0;
      host_tkeep   = '0;
      host_tvalid  = 1'b0;
      host_tlast   = 1'b0;
      repeat (20) @(posedge clk);
      rstn = 1'b1;
      repeat (20) @(posedge clk);
    end
  endtask

  task automatic configure_preload;
    begin
      axil_write(16'h0004, 32'd0);
      axil_write(16'h0010, DESC_BASE[31:0]);
      axil_write(16'h0014, DESC_BASE[63:32]);
      axil_write(16'h0018, DATA_BASE[31:0]);
      axil_write(16'h001c, DATA_BASE[63:32]);
      axil_write(16'h0028, case_pkt_count[31:0]);
      axil_write(16'h002c, case_pkt_count[63:32]);
      axil_write(16'h0040, 32'd0);
      axil_write(16'h0044, 32'd0);
      axil_write(16'h0000, 32'd1);
    end
  endtask

  always_ff @(posedge clk) begin
    longint unsigned word_idx;
    int unsigned valid_bytes;
    logic [63:0] exp_keep;

    if (!rstn) begin
      tx_pkt_count       <= '0;
      tx_beat_count      <= '0;
      tx_byte_count      <= '0;
      first_tx_cycle     <= '0;
      last_tx_cycle      <= '0;
      steady_start_cycle <= '0;
      steady_last_cycle  <= '0;
      steady_beat_count  <= '0;
      steady_byte_count  <= '0;
      expected_pkt_idx   <= '0;
      expected_beat_idx  <= 0;
    end else if (tx_tvalid && tx_tready) begin
      if (tx_beat_count == 0) begin
        first_tx_cycle <= cycle_count;
      end
      last_tx_cycle <= cycle_count;

      valid_bytes = bytes_in_output_beat(expected_beat_idx);
      exp_keep = expected_keep(expected_beat_idx);
      if (tx_tkeep !== exp_keep) begin
        $fatal(1, "%s keep mismatch pkt=%0d beat=%0d got=0x%016x exp=0x%016x",
               case_name, expected_pkt_idx, expected_beat_idx, tx_tkeep, exp_keep);
      end
      if (tx_tlast !== (expected_beat_idx == (case_beats_per_pkt - 1))) begin
        $fatal(1, "%s tlast mismatch pkt=%0d beat=%0d got=%0b",
               case_name, expected_pkt_idx, expected_beat_idx, tx_tlast);
      end

      word_idx = expected_pkt_idx * case_beats_per_pkt + expected_beat_idx;
      for (int i = 0; i < 64; i++) begin
        if ((i < valid_bytes) && (tx_tdata[i*8 +: 8] !== payload_byte(word_idx, i))) begin
          $fatal(1, "%s data mismatch pkt=%0d beat=%0d byte=%0d got=0x%02x exp=0x%02x",
                 case_name, expected_pkt_idx, expected_beat_idx, i,
                 tx_tdata[i*8 +: 8], payload_byte(word_idx, i));
        end
      end

      tx_beat_count <= tx_beat_count + 1;
      tx_byte_count <= tx_byte_count + valid_bytes;

      if ((expected_pkt_idx >= warmup_pkts) && (expected_pkt_idx < (case_pkt_count - warmup_pkts))) begin
        if (steady_beat_count == 0) begin
          steady_start_cycle <= cycle_count;
        end
        steady_last_cycle <= cycle_count;
        steady_beat_count <= steady_beat_count + 1;
        steady_byte_count <= steady_byte_count + valid_bytes;
      end

      if (tx_tlast) begin
        tx_pkt_count <= tx_pkt_count + 1;
        expected_pkt_idx <= expected_pkt_idx + 1;
        expected_beat_idx <= 0;
      end else begin
        expected_beat_idx <= expected_beat_idx + 1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      ar_count         <= '0;
      desc_ar_count    <= '0;
      payload_ar_count <= '0;
      desc_ar_beats    <= '0;
      payload_ar_beats <= '0;
    end else if (arvalid && arready) begin
      ar_count <= ar_count + 1;
      if (araddr < DATA_BASE) begin
        desc_ar_count <= desc_ar_count + 1;
        desc_ar_beats <= desc_ar_beats + ({1'b0, arlen} + 9'd1);
      end else begin
        payload_ar_count <= payload_ar_count + 1;
        payload_ar_beats <= payload_ar_beats + ({1'b0, arlen} + 9'd1);
      end
    end
  end

  task automatic report_case;
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
      active_cycles = last_tx_cycle - first_tx_cycle + 1;
      steady_cycles = steady_last_cycle - steady_start_cycle + 1;
      l2_gbps = (tx_byte_count * 8.0 * CLK_MHZ) / (active_cycles * 1000.0);
      axis_gbps = (tx_beat_count * 64.0 * 8.0 * CLK_MHZ) / (active_cycles * 1000.0);
      pps_m = (tx_pkt_count * 1.0 * CLK_MHZ) / active_cycles;
      wire_gbps = (tx_pkt_count * (case_pkt_len + 20.0) * 8.0 * CLK_MHZ) / (active_cycles * 1000.0);
      steady_l2_gbps = (steady_byte_count * 8.0 * CLK_MHZ) / (steady_cycles * 1000.0);
      steady_axis_gbps = (steady_beat_count * 64.0 * 8.0 * CLK_MHZ) / (steady_cycles * 1000.0);
      steady_pkt_count = steady_byte_count * 1.0 / case_pkt_len;
      steady_pps_m = (steady_pkt_count * CLK_MHZ) / steady_cycles;
      steady_wire_gbps = (steady_pkt_count * (case_pkt_len + 20.0) * 8.0 * CLK_MHZ) / (steady_cycles * 1000.0);
      payload_avg_burst = (payload_ar_count == 0) ? 0.0 : (payload_ar_beats * 1.0 / payload_ar_count);

      axil_read(16'h0008, status);
      axil_read(16'h0060, tx_pkts_lo);
      axil_read(16'h0078, underrun_lo);

      $display("CORE %-28s pkt_len=%0d pkts=%0d latency=%0d ar_stall_period=%0d tready_stall_period=%0d",
               case_name, case_pkt_len, case_pkt_count, case_latency_cycles,
               case_ar_stall_period, case_tready_stall_period);
      $display("  output: packets=%0d beats=%0d bytes=%0d active_cycles=%0d pps=%.3fM l2=%.3fGbps wire=%.3fGbps axis=%.3fGbps",
               tx_pkt_count, tx_beat_count, tx_byte_count, active_cycles, pps_m, l2_gbps, wire_gbps, axis_gbps);
      $display("  steady: warmup_pkts=%0d beats=%0d bytes=%0d cycles=%0d pps=%.3fM l2=%.3fGbps wire=%.3fGbps axis=%.3fGbps",
               warmup_pkts, steady_beat_count, steady_byte_count, steady_cycles,
               steady_pps_m, steady_l2_gbps, steady_wire_gbps, steady_axis_gbps);
      $display("  axi_ar: total=%0d desc=%0d payload=%0d desc_beats=%0d payload_beats=%0d payload_avg_burst=%.2f",
               ar_count, desc_ar_count, payload_ar_count, desc_ar_beats,
               payload_ar_beats, payload_avg_burst);
      $display("  regs: status=0x%08x tx_pkts_lo=%0d underrun_lo=%0d", status, tx_pkts_lo, underrun_lo);

      if (check_underrun && (status[3] || (underrun_lo != 32'd0))) begin
        $fatal(1, "%s underrun detected status=0x%08x underrun_lo=%0d", case_name, status, underrun_lo);
      end
      if (expect_over_100g && (steady_l2_gbps < 100.0)) begin
        $fatal(1, "%s steady core throughput %.3fGbps below 100Gbps target", case_name, steady_l2_gbps);
      end
      if (expect_wire_over_100g && (steady_wire_gbps < 100.0)) begin
        $fatal(1, "%s steady wire throughput %.3fGbps below 100Gbps target", case_name, steady_wire_gbps);
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
    input int unsigned tready_stall_period_i,
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
      case_tready_stall_period = tready_stall_period_i;
      case_beats_per_pkt = beats_from_bytes(16'(pkt_len_i));
      expect_over_100g = expect_over_100g_i;
      expect_wire_over_100g = expect_wire_over_100g_i;
      check_underrun = check_underrun_i;
      warmup_pkts = (pkt_count_i > 16384) ? 4096 : ((pkt_count_i > 1024) ? 256 : 16);

      reset_case();
      configure_preload();

      timeout_cycles = pkt_count_i * (case_beats_per_pkt + 24) + latency_i * 16 + 30000;
      for (longint unsigned timeout = 0; timeout < timeout_cycles; timeout++) begin
        @(posedge clk);
        if (tx_pkt_count == pkt_count_i) begin
          break;
        end
      end

      if (tx_pkt_count != pkt_count_i) begin
        $fatal(1, "%s packet count mismatch got=%0d exp=%0d",
               case_name, tx_pkt_count, pkt_count_i);
      end

      report_case();
      repeat (20) @(posedge clk);
    end
  endtask

  initial begin
    run_case("core_1518B_latency64", 4096, 1518, 0, 64, 0, 0, 1'b1, 1'b1, 1'b1);
    run_case("core_1518B_latency128_ar75", 4096, 1518, 0, 128, 4, 0, 1'b1, 1'b1, 1'b1);
    run_case("core_64B_gap0_max", 32768, 64, 0, 64, 0, 0, 1'b0, 1'b0, 1'b0);
    run_case("core_64B_gap2_wire100", 32768, 64, 2, 64, 0, 0, 1'b0, 1'b1, 1'b1);

    $display("PASS: trace_replay_core preload pipeline correctness and throughput simulation completed");
    $finish;
  end

  initial begin
    repeat (20000000) @(posedge clk);
    $fatal(1, "Simulation watchdog timeout");
  end
endmodule
