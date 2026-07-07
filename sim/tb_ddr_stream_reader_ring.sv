`timescale 1ns/1ps

import traffic_replay_pkg::*;

module tb_ddr_stream_reader_ring;
  localparam logic [63:0] BASE = 64'h2000_0000;
  localparam logic [63:0] BASE1 = 64'h4_0000_0000;
  localparam logic [63:0] RING_SIZE = 64'd256;

  logic clk = 1'b0;
  logic rstn = 1'b0;

  always #1.55 clk = ~clk;

  logic start;
  logic stop;
  logic clear;
  logic [63:0] cfg_stream_bytes;
  logic [63:0] cfg_ring_size;
  logic [63:0] cfg_ring_write_count;
  logic cfg_ring_eof;
  logic cfg_pingpong_enable;

  logic [3:0] arid;
  logic [63:0] araddr;
  logic [7:0] arlen;
  logic [2:0] arsize;
  logic [1:0] arburst;
  logic arvalid;
  logic arready;
  logic [3:0] rid;
  logic [511:0] rdata;
  logic [1:0] rresp;
  logic rlast;
  logic rvalid;
  logic rready;

  logic [511:0] axis_tdata;
  logic [63:0] axis_tkeep;
  logic axis_tvalid;
  logic axis_tready;
  logic axis_tlast;

  logic busy;
  logic done;
  logic error;
  logic [63:0] read_count;
  logic [63:0] ring_level;
  logic [31:0] stream_status;
  logic [3:0] debug_state;

  logic [511:0] ring_mem [0:3];
  logic [511:0] ring_mem1 [0:3];
  logic [511:0] expected [0:31];
  int expected_count;
  int seen_count;
  int ar_count;
  bit fatal_seen;

  logic rd_active;
  logic [63:0] rd_addr_q;
  logic [7:0] rd_len_q;
  logic [7:0] rd_beat_q;
  logic [1:0] rd_delay_q;

  ddr_stream_reader #(
    .AXI_ADDR_W_P(64),
    .AXI_ID_W_P(4),
    .MAX_BURST_BEATS(4)
  ) dut (
    .clk(clk),
    .rstn(rstn),
    .start(start),
    .stop(stop),
    .clear(clear),
    .cfg_stream_base(BASE),
    .cfg_stream_base1(BASE1),
    .cfg_stream_bytes(cfg_stream_bytes),
    .cfg_ring_size(cfg_ring_size),
    .cfg_ring_write_count(cfg_ring_write_count),
    .cfg_ring_eof(cfg_ring_eof),
    .cfg_pingpong_enable(cfg_pingpong_enable),
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
    .m_axis_tdata(axis_tdata),
    .m_axis_tkeep(axis_tkeep),
    .m_axis_tvalid(axis_tvalid),
    .m_axis_tready(axis_tready),
    .m_axis_tlast(axis_tlast),
    .busy(busy),
    .done(done),
    .error(error),
    .read_count(read_count),
    .ring_level(ring_level),
    .stream_status(stream_status),
    .debug_state(debug_state)
  );

  function automatic logic [511:0] word_with_id(input int id);
    logic [511:0] word;
    begin
      word = '0;
      for (int i = 0; i < 64; i++) begin
        word[i*8 +: 8] = 8'((id * 17 + i) & 8'hff);
      end
      word_with_id = word;
    end
  endfunction

  function automatic logic [511:0] mem_read(input logic [63:0] addr);
    int idx;
    begin
      if (addr >= BASE1) begin
        idx = int'(((addr - BASE1) >> 6) & 64'h3);
        mem_read = ring_mem1[idx];
      end else if (addr < BASE) begin
        mem_read = '0;
      end else begin
        idx = int'(((addr - BASE) >> 6) & 64'h3);
        mem_read = ring_mem[idx];
      end
    end
  endfunction

  task automatic pulse_start;
    begin
      @(posedge clk);
      start <= 1'b1;
      @(posedge clk);
      start <= 1'b0;
    end
  endtask

  task automatic pulse_clear;
    begin
      @(posedge clk);
      clear <= 1'b1;
      @(posedge clk);
      clear <= 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic add_expected(input logic [511:0] word);
    begin
      expected[expected_count] = word;
      expected_count++;
    end
  endtask

  task automatic wait_seen(input int count, input int timeout_cycles);
    begin
      for (int i = 0; i < timeout_cycles && seen_count < count; i++) begin
        @(posedge clk);
      end
      if (seen_count < count) begin
        $fatal(1,
               "timeout waiting for %0d output beats, saw %0d read_count=%0d write_count=%0d status=0x%08x state=%0d ar_count=%0d",
               count, seen_count, read_count, cfg_ring_write_count, stream_status, debug_state, ar_count);
      end
    end
  endtask

  task automatic wait_done(input int timeout_cycles);
    begin
      for (int i = 0; i < timeout_cycles && !done; i++) begin
        @(posedge clk);
      end
      if (!done) begin
        $fatal(1, "timeout waiting for stream reader done");
      end
    end
  endtask

  assign arready = !rd_active && !rvalid;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      rid        <= '0;
      rdata      <= '0;
      rresp      <= 2'b00;
      rlast      <= 1'b0;
      rvalid     <= 1'b0;
      rd_active  <= 1'b0;
      rd_addr_q  <= '0;
      rd_len_q   <= '0;
      rd_beat_q  <= '0;
      rd_delay_q <= '0;
      ar_count   <= 0;
      fatal_seen <= 1'b0;
    end else begin
      if (arvalid && arready) begin
        rd_active  <= 1'b1;
        rd_addr_q  <= araddr;
        rd_len_q   <= arlen;
        rd_beat_q  <= '0;
        rd_delay_q <= 2'd1;
        ar_count   <= ar_count + 1;
        if (((araddr - BASE) & 64'hff) + (({56'd0, arlen} + 64'd1) << 6) > RING_SIZE) begin
          fatal_seen <= 1'b1;
          $error("AXI burst crosses ring boundary: addr=0x%016h arlen=%0d", araddr, arlen);
        end
      end

      if (rd_active && !rvalid) begin
        if (rd_delay_q != 2'd0) begin
          rd_delay_q <= rd_delay_q - 2'd1;
        end else begin
          rvalid <= 1'b1;
          rdata  <= mem_read(rd_addr_q + ({56'd0, rd_beat_q} << 6));
          rlast  <= (rd_beat_q == rd_len_q);
          rresp  <= 2'b00;
          rid    <= '0;
        end
      end else if (rvalid && rready) begin
        if (rlast) begin
          rvalid    <= 1'b0;
          rlast     <= 1'b0;
          rd_active <= 1'b0;
        end else begin
          rd_beat_q <= rd_beat_q + 8'd1;
          rdata     <= mem_read(rd_addr_q + ({56'd0, rd_beat_q + 8'd1} << 6));
          rlast     <= (rd_beat_q + 8'd1 == rd_len_q);
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rstn || clear) begin
      seen_count <= 0;
    end else if (axis_tvalid && axis_tready) begin
      if (axis_tdata !== expected[seen_count]) begin
        $fatal(1,
               "stream data mismatch at beat %0d got_lsb=0x%02x exp_lsb=0x%02x read_count=%0d status=0x%08x state=%0d ar_count=%0d",
               seen_count, axis_tdata[7:0], expected[seen_count][7:0],
               read_count, stream_status, debug_state, ar_count);
      end
      if (axis_tkeep !== {64{1'b1}} || axis_tlast !== 1'b0) begin
        $fatal(1, "raw ring stream beat had unexpected keep/tlast at beat %0d", seen_count);
      end
      seen_count <= seen_count + 1;
    end
  end

  initial begin
    repeat (5000) @(posedge clk);
    $fatal(1, "Simulation watchdog timeout");
  end

  initial begin
    start = 1'b0;
    stop = 1'b0;
    clear = 1'b0;
    cfg_stream_bytes = '0;
    cfg_ring_size = RING_SIZE;
    cfg_ring_write_count = '0;
    cfg_ring_eof = 1'b0;
    cfg_pingpong_enable = 1'b0;
    axis_tready = 1'b1;
    expected_count = 0;
    for (int i = 0; i < 4; i++) begin
      ring_mem[i] = '0;
      ring_mem1[i] = '0;
    end

    repeat (10) @(posedge clk);
    rstn = 1'b1;
    repeat (10) @(posedge clk);

    pulse_start();
    repeat (20) @(posedge clk);
    if (ar_count != 0) begin
      $fatal(1, "reader issued AR before host committed any ring bytes");
    end
    if (!(stream_status & (1 << 11))) begin
      $fatal(1, "expected stream_wait_empty while ring is empty");
    end

    ring_mem[0] = word_with_id(0);
    ring_mem[1] = word_with_id(1);
    add_expected(ring_mem[0]);
    add_expected(ring_mem[1]);
    @(negedge clk);
    cfg_ring_write_count = 64'd128;
    wait_seen(2, 200);
    if (read_count != 64'd128) begin
      $fatal(1, "read_count after first staged write is %0d", read_count);
    end

    repeat (20) @(posedge clk);
    ring_mem[2] = word_with_id(2);
    ring_mem[3] = word_with_id(3);
    add_expected(ring_mem[2]);
    add_expected(ring_mem[3]);
    @(negedge clk);
    cfg_ring_write_count = 64'd256;
    cfg_ring_eof = 1'b1;
    wait_seen(4, 200);
    wait_done(100);
    if (error || fatal_seen) begin
      $fatal(1, "staged ring reader test reported error");
    end
    $display("PASS: staged ring reader waits for writes and exits on EOF");

    pulse_clear();
    cfg_ring_eof = 1'b0;
    cfg_ring_write_count = 64'd0;
    expected_count = 0;

    ring_mem[0] = word_with_id(10);
    ring_mem[1] = word_with_id(11);
    ring_mem[2] = word_with_id(12);
    ring_mem[3] = word_with_id(13);
    add_expected(ring_mem[0]);
    add_expected(ring_mem[1]);
    add_expected(ring_mem[2]);
    add_expected(ring_mem[3]);
    @(negedge clk);
    cfg_ring_write_count = 64'd256;
    pulse_start();
    wait_seen(4, 300);

    ring_mem[0] = word_with_id(14);
    ring_mem[1] = word_with_id(15);
    add_expected(ring_mem[0]);
    add_expected(ring_mem[1]);
    @(negedge clk);
    cfg_ring_write_count = 64'd384;
    cfg_ring_eof = 1'b1;
    wait_seen(6, 300);
    wait_done(100);
    if (error || fatal_seen) begin
      $fatal(1, "wrap ring reader test reported error");
    end
    $display("PASS: ring reader wraps without issuing cross-boundary bursts");

    pulse_clear();
    cfg_pingpong_enable = 1'b1;
    cfg_ring_size = RING_SIZE;
    cfg_ring_eof = 1'b0;
    cfg_ring_write_count = 64'd0;
    expected_count = 0;

    for (int i = 0; i < 4; i++) begin
      ring_mem[i] = word_with_id(30 + i);
      ring_mem1[i] = word_with_id(40 + i);
      add_expected(ring_mem[i]);
    end
    for (int i = 0; i < 4; i++) begin
      add_expected(ring_mem1[i]);
    end
    @(negedge clk);
    cfg_ring_write_count = RING_SIZE * 2;
    cfg_ring_eof = 1'b1;
    pulse_start();
    wait_seen(8, 400);
    wait_done(100);
    if (error || fatal_seen) begin
      $fatal(1, "ping-pong ring reader test reported error status=0x%08x", stream_status);
    end
    if (!(stream_status & (1 << 13))) begin
      $fatal(1, "ping-pong status bit was not visible: status=0x%08x", stream_status);
    end
    $display("PASS: ping-pong ring reader alternates bank0/bank1 segments");

    pulse_clear();
    cfg_pingpong_enable = 1'b1;
    cfg_ring_size = 64'd384;
    cfg_ring_write_count = 64'd0;
    cfg_ring_eof = 1'b0;
    pulse_start();
    wait_done(50);
    repeat (2) @(posedge clk);
    if (!error || !(stream_status & (1 << 6)) || (stream_status & (1 << 9))) begin
      $fatal(1, "non-power-of-two ping-pong segment was not rejected: status=0x%08x",
             stream_status);
    end
    $display("PASS: ping-pong mode rejects non-power-of-two segment size");

    pulse_clear();
    cfg_pingpong_enable = 1'b0;
    cfg_ring_eof = 1'b0;
    cfg_ring_size = 64'd130;
    cfg_ring_write_count = 64'd0;
    pulse_start();
    wait_done(50);
    repeat (2) @(posedge clk);
    if (!error || !(stream_status & (1 << 6)) || (stream_status & (1 << 9))) begin
      $fatal(1, "invalid ring size was not reported correctly: status=0x%08x", stream_status);
    end
    $display("PASS: invalid ring size terminates with hardware-visible error");

    pulse_clear();
    cfg_ring_size = RING_SIZE;
    cfg_ring_eof = 1'b0;
    cfg_ring_write_count = 64'd0;
    expected_count = 0;
    ring_mem[0] = word_with_id(20);
    ring_mem[1] = word_with_id(21);
    add_expected(ring_mem[0]);
    add_expected(ring_mem[1]);
    @(negedge clk);
    cfg_ring_write_count = 64'd256;
    pulse_start();
    wait_seen(2, 200);
    @(negedge clk);
    cfg_ring_write_count = 64'd128;
    wait_done(80);
    repeat (2) @(posedge clk);
    if (!error || !(stream_status & (1 << 12))) begin
      $fatal(1, "ring producer pointer regression was not reported correctly: status=0x%08x", stream_status);
    end
    $display("PASS: ring producer pointer regression terminates with hardware-visible error");

    pulse_clear();
    cfg_ring_size = RING_SIZE;
    cfg_ring_eof = 1'b0;
    @(negedge clk);
    cfg_ring_write_count = RING_SIZE + 64'd64;
    pulse_start();
    wait_done(80);
    repeat (2) @(posedge clk);
    if (!error || !(stream_status & (1 << 10))) begin
      $fatal(1, "ring overrun was not reported correctly: status=0x%08x", stream_status);
    end
    $display("PASS: ring overrun terminates with hardware-visible error");

    $display("PASS: ddr_stream_reader ring-mode robustness simulation completed");
    $finish;
  end
endmodule
