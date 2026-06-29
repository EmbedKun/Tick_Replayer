`timescale 1ns/1ps

import traffic_replay_pkg::*;

module tb_ddr_trace_reader_perf;
  localparam int CLK_MHZ = 300;
  localparam int CMD_Q_DEPTH = 128;
  localparam logic [63:0] DESC_BASE = 64'h0000_0000;
  localparam logic [63:0] DATA_BASE = 64'h1000_0000;

  logic clk = 1'b0;
  logic rstn = 1'b0;
  always #1.666 clk = ~clk;

  logic start;
  logic stop;
  logic clear;
  logic loop_mode;
  logic [63:0] cfg_desc_base;
  logic [63:0] cfg_data_base;
  logic [63:0] cfg_pkt_count;
  logic [63:0] cfg_loop_count;
  logic [63:0] cfg_loop_gap_ticks;

  logic [3:0]   m_axi_arid;
  logic [63:0]  m_axi_araddr;
  logic [7:0]   m_axi_arlen;
  logic [2:0]   m_axi_arsize;
  logic [1:0]   m_axi_arburst;
  logic         m_axi_arvalid;
  logic         m_axi_arready;
  logic [3:0]   m_axi_rid;
  logic [511:0] m_axi_rdata;
  logic [1:0]   m_axi_rresp;
  logic         m_axi_rlast;
  logic         m_axi_rvalid;
  logic         m_axi_rready;

  logic         m_meta_valid;
  logic         m_meta_ready;
  logic [63:0]  m_meta_gap_ticks;
  logic [15:0]  m_meta_len;
  logic [15:0]  m_meta_flags;

  logic [511:0] m_axis_tdata;
  logic [63:0]  m_axis_tkeep;
  logic         m_axis_tvalid;
  logic         m_axis_tready;
  logic         m_axis_tlast;

  logic busy;
  logic done;
  logic error;
  logic [3:0] debug_state;

  ddr_trace_reader dut (
    .clk(clk),
    .rstn(rstn),
    .start(start),
    .stop(stop),
    .clear(clear),
    .loop_mode(loop_mode),
    .cfg_desc_base(cfg_desc_base),
    .cfg_data_base(cfg_data_base),
    .cfg_pkt_count(cfg_pkt_count),
    .cfg_loop_count(cfg_loop_count),
    .cfg_loop_gap_ticks(cfg_loop_gap_ticks),
    .m_axi_arid(m_axi_arid),
    .m_axi_araddr(m_axi_araddr),
    .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize),
    .m_axi_arburst(m_axi_arburst),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp),
    .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid),
    .m_axi_rready(m_axi_rready),
    .m_meta_valid(m_meta_valid),
    .m_meta_ready(m_meta_ready),
    .m_meta_gap_ticks(m_meta_gap_ticks),
    .m_meta_len(m_meta_len),
    .m_meta_flags(m_meta_flags),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .busy(busy),
    .done(done),
    .error(error),
    .debug_state(debug_state)
  );

  int unsigned case_pkt_len;
  longint unsigned case_pkt_count;
  longint unsigned case_gap_ticks;
  int unsigned case_latency_cycles;
  int unsigned case_ar_stall_period;
  int unsigned case_tready_stall_period;
  int unsigned case_beats_per_pkt;
  bit expect_over_100g;
  string case_name;

  longint unsigned cycle_count;
  longint unsigned meta_count;
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

  assign m_axi_arready =
    rstn &&
    (cmd_count < CMD_Q_DEPTH) &&
    ((case_ar_stall_period == 0) || ((cycle_count % case_ar_stall_period) != (case_ar_stall_period - 1)));

  assign m_meta_ready = 1'b1;
  assign m_axis_tready =
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
      m_axi_rid    <= '0;
      m_axi_rdata  <= '0;
      m_axi_rresp  <= 2'b00;
      m_axi_rlast  <= 1'b0;
      m_axi_rvalid <= 1'b0;
      cmd_wr_ptr   <= 0;
      cmd_rd_ptr   <= 0;
      cmd_count    <= 0;
      rsp_beat_idx <= 0;
    end else begin
      ar_push = m_axi_arvalid && m_axi_arready;
      cmd_pop = m_axi_rvalid && m_axi_rready && m_axi_rlast;

      if (ar_push) begin
        cmd_addr_mem[cmd_wr_ptr]        <= m_axi_araddr;
        cmd_beats_mem[cmd_wr_ptr]       <= {1'b0, m_axi_arlen} + 9'd1;
        cmd_ready_cycle_mem[cmd_wr_ptr] <= cycle_count + case_latency_cycles;
        cmd_wr_ptr <= (cmd_wr_ptr + 1) % CMD_Q_DEPTH;
      end

      if (m_axi_rvalid) begin
        if (m_axi_rready) begin
          if (m_axi_rlast) begin
            m_axi_rvalid <= 1'b0;
            m_axi_rlast  <= 1'b0;
            rsp_beat_idx <= 0;
            cmd_rd_ptr   <= (cmd_rd_ptr + 1) % CMD_Q_DEPTH;
          end else begin
            rsp_beat_idx <= rsp_beat_idx + 1;
            m_axi_rdata  <= model_read_word(cmd_addr_mem[cmd_rd_ptr] + (64'(rsp_beat_idx + 1) << DESC_WORD_SHIFT));
            m_axi_rlast  <= ((rsp_beat_idx + 1) == (cmd_beats_mem[cmd_rd_ptr] - 1));
          end
        end
      end else if ((cmd_count != 0) && (cycle_count >= cmd_ready_cycle_mem[cmd_rd_ptr])) begin
        m_axi_rvalid <= 1'b1;
        m_axi_rresp  <= 2'b00;
        m_axi_rid    <= '0;
        m_axi_rdata  <= model_read_word(cmd_addr_mem[cmd_rd_ptr]);
        m_axi_rlast  <= (cmd_beats_mem[cmd_rd_ptr] == 9'd1);
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

  always_ff @(posedge clk) begin
    if (!rstn) begin
      meta_count <= '0;
    end else if (m_meta_valid && m_meta_ready) begin
      if (m_meta_gap_ticks !== case_gap_ticks) begin
        $fatal(1, "%s meta gap mismatch pkt=%0d got=%0d exp=%0d",
               case_name, meta_count, m_meta_gap_ticks, case_gap_ticks);
      end
      if (m_meta_len !== 16'(case_pkt_len)) begin
        $fatal(1, "%s meta len mismatch pkt=%0d got=%0d exp=%0d",
               case_name, meta_count, m_meta_len, case_pkt_len);
      end
      if (m_meta_flags !== 16'd0) begin
        $fatal(1, "%s meta flags mismatch pkt=%0d got=0x%04x",
               case_name, meta_count, m_meta_flags);
      end
      meta_count <= meta_count + 1;
    end
  end

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
    end else if (m_axis_tvalid && m_axis_tready) begin
      if (tx_beat_count == 0) begin
        first_tx_cycle <= cycle_count;
      end
      last_tx_cycle <= cycle_count;

      valid_bytes = bytes_in_output_beat(expected_beat_idx);
      exp_keep = expected_keep(expected_beat_idx);
      if (m_axis_tkeep !== exp_keep) begin
        $fatal(1, "%s keep mismatch pkt=%0d beat=%0d got=0x%016x exp=0x%016x",
               case_name, expected_pkt_idx, expected_beat_idx, m_axis_tkeep, exp_keep);
      end
      if (m_axis_tlast !== (expected_beat_idx == (case_beats_per_pkt - 1))) begin
        $fatal(1, "%s tlast mismatch pkt=%0d beat=%0d got=%0b",
               case_name, expected_pkt_idx, expected_beat_idx, m_axis_tlast);
      end

      word_idx = expected_pkt_idx * case_beats_per_pkt + expected_beat_idx;
      for (int i = 0; i < 64; i++) begin
        if ((i < valid_bytes) && (m_axis_tdata[i*8 +: 8] !== payload_byte(word_idx, i))) begin
          $fatal(1, "%s data mismatch pkt=%0d beat=%0d byte=%0d got=0x%02x exp=0x%02x",
                 case_name, expected_pkt_idx, expected_beat_idx, i,
                 m_axis_tdata[i*8 +: 8], payload_byte(word_idx, i));
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

      if (m_axis_tlast) begin
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
    end else if (m_axi_arvalid && m_axi_arready) begin
      ar_count <= ar_count + 1;
      if (m_axi_araddr < DATA_BASE) begin
        desc_ar_count <= desc_ar_count + 1;
        desc_ar_beats <= desc_ar_beats + ({1'b0, m_axi_arlen} + 9'd1);
      end else begin
        payload_ar_count <= payload_ar_count + 1;
        payload_ar_beats <= payload_ar_beats + ({1'b0, m_axi_arlen} + 9'd1);
      end
    end
  end

  task automatic reset_case;
    begin
      rstn = 1'b0;
      start = 1'b0;
      stop = 1'b0;
      clear = 1'b0;
      loop_mode = 1'b0;
      cfg_desc_base = DESC_BASE;
      cfg_data_base = DATA_BASE;
      cfg_pkt_count = case_pkt_count;
      cfg_loop_count = 64'd0;
      cfg_loop_gap_ticks = 64'd0;
      repeat (20) @(posedge clk);
      rstn = 1'b1;
      repeat (20) @(posedge clk);
    end
  endtask

  task automatic start_case;
    begin
      @(posedge clk);
      start <= 1'b1;
      @(posedge clk);
      start <= 1'b0;
    end
  endtask

  task automatic report_case;
    longint unsigned active_cycles;
    longint unsigned steady_cycles;
    real l2_gbps;
    real axis_gbps;
    real steady_l2_gbps;
    real steady_axis_gbps;
    real payload_avg_burst;
    begin
      active_cycles = last_tx_cycle - first_tx_cycle + 1;
      steady_cycles = steady_last_cycle - steady_start_cycle + 1;
      l2_gbps = (tx_byte_count * 8.0 * CLK_MHZ) / (active_cycles * 1000.0);
      axis_gbps = (tx_beat_count * 64.0 * 8.0 * CLK_MHZ) / (active_cycles * 1000.0);
      steady_l2_gbps = (steady_byte_count * 8.0 * CLK_MHZ) / (steady_cycles * 1000.0);
      steady_axis_gbps = (steady_beat_count * 64.0 * 8.0 * CLK_MHZ) / (steady_cycles * 1000.0);
      payload_avg_burst = (payload_ar_count == 0) ? 0.0 : (payload_ar_beats * 1.0 / payload_ar_count);

      $display("PERF %-28s pkt_len=%0d pkts=%0d latency=%0d ar_stall_period=%0d tready_stall_period=%0d",
               case_name, case_pkt_len, case_pkt_count, case_latency_cycles,
               case_ar_stall_period, case_tready_stall_period);
      $display("  output: packets=%0d beats=%0d bytes=%0d active_cycles=%0d l2=%.3fGbps axis=%.3fGbps",
               tx_pkt_count, tx_beat_count, tx_byte_count, active_cycles, l2_gbps, axis_gbps);
      $display("  steady: warmup_pkts=%0d beats=%0d bytes=%0d cycles=%0d l2=%.3fGbps axis=%.3fGbps",
               warmup_pkts, steady_beat_count, steady_byte_count, steady_cycles,
               steady_l2_gbps, steady_axis_gbps);
      $display("  axi_ar: total=%0d desc=%0d payload=%0d desc_beats=%0d payload_beats=%0d payload_avg_burst=%.2f",
               ar_count, desc_ar_count, payload_ar_count, desc_ar_beats,
               payload_ar_beats, payload_avg_burst);

      if (expect_over_100g && (steady_l2_gbps < 100.0)) begin
        $fatal(1, "%s steady throughput %.3fGbps below 100Gbps target", case_name, steady_l2_gbps);
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
    input bit expect_over_100g_i
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
      warmup_pkts = (pkt_count_i > 1024) ? 256 : 16;

      reset_case();
      start_case();

      timeout_cycles = pkt_count_i * (case_beats_per_pkt + 16) + latency_i * 16 + 20000;
      for (longint unsigned timeout = 0; timeout < timeout_cycles; timeout++) begin
        @(posedge clk);
        if (done && (tx_pkt_count == pkt_count_i)) begin
          break;
        end
      end

      if (tx_pkt_count != pkt_count_i) begin
        $fatal(1, "%s packet count mismatch got=%0d exp=%0d done=%0b busy=%0b error=%0b debug=0x%0x",
               case_name, tx_pkt_count, pkt_count_i, done, busy, error, debug_state);
      end
      if (meta_count != pkt_count_i) begin
        $fatal(1, "%s meta count mismatch got=%0d exp=%0d",
               case_name, meta_count, pkt_count_i);
      end
      if (error) begin
        $fatal(1, "%s DUT error asserted", case_name);
      end

      report_case();
      repeat (20) @(posedge clk);
    end
  endtask

  initial begin
    start = 1'b0;
    stop = 1'b0;
    clear = 1'b0;
    loop_mode = 1'b0;
    cfg_desc_base = DESC_BASE;
    cfg_data_base = DATA_BASE;
    cfg_pkt_count = 64'd0;
    cfg_loop_count = 64'd0;
    cfg_loop_gap_ticks = 64'd0;

    run_case("1518B_latency64", 4096, 1518, 0, 64, 0, 0, 1'b1);
    run_case("1518B_latency128_ar75", 4096, 1518, 0, 128, 4, 0, 1'b1);
    run_case("64B_latency64", 8192, 64, 0, 64, 0, 0, 1'b0);
    run_case("256B_latency64_tready75", 4096, 256, 0, 64, 0, 4, 1'b0);

    $display("PASS: ddr_trace_reader pipeline correctness and throughput simulation completed");
    $finish;
  end

  initial begin
    repeat (20000000) @(posedge clk);
    $fatal(1, "Simulation watchdog timeout");
  end
endmodule
