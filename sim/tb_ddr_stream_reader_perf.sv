`timescale 1ns/1ps

import traffic_replay_pkg::*;

module tb_ddr_stream_reader_perf;
  localparam logic [63:0] BASE = 64'h4000_0000;
  localparam int TOTAL_BEATS = 512;
  localparam logic [63:0] RING_SIZE = TOTAL_BEATS * AXIS_KEEP_BYTES;
  localparam int MAX_BURST = 16;
  localparam int REQ_DEPTH = 64;
  localparam int RESP_LATENCY = 24;

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

  logic [63:0] req_addr_mem [0:REQ_DEPTH-1];
  logic [7:0] req_len_mem [0:REQ_DEPTH-1];
  int req_wr_ptr;
  int req_rd_ptr;
  int req_count;
  int ar_count;
  int max_req_count;

  logic returning;
  logic [63:0] ret_addr;
  logic [7:0] ret_len;
  logic [7:0] ret_beat;
  int ret_delay;
  int seen_count;
  int first_seen_cycle;
  int last_seen_cycle;
  int cycle_count;
  logic req_push;
  logic req_pop_start;

  ddr_stream_reader #(
    .AXI_ADDR_W_P(64),
    .AXI_ID_W_P(4),
    .MAX_BURST_BEATS(MAX_BURST),
    .MAX_OUTSTANDING_BURSTS(16)
  ) dut (
    .clk(clk),
    .rstn(rstn),
    .start(start),
    .stop(stop),
    .clear(clear),
    .cfg_stream_base(BASE),
    .cfg_stream_bytes(cfg_stream_bytes),
    .cfg_ring_size(cfg_ring_size),
    .cfg_ring_write_count(cfg_ring_write_count),
    .cfg_ring_eof(cfg_ring_eof),
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
        word[i*8 +: 8] = 8'((id * 13 + i * 7) & 8'hff);
      end
      word_with_id = word;
    end
  endfunction

  function automatic logic [511:0] mem_read(input logic [63:0] addr);
    int idx;
    begin
      idx = int'((addr - BASE) >> 6);
      mem_read = word_with_id(idx);
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

  assign req_push = arvalid && arready;
  assign req_pop_start = !rvalid && !returning && (req_count != 0);

  always_ff @(posedge clk) begin
    if (!rstn) begin
      arready <= 1'b0;
      rid <= '0;
      rdata <= '0;
      rresp <= 2'b00;
      rlast <= 1'b0;
      rvalid <= 1'b0;
      req_wr_ptr <= 0;
      req_rd_ptr <= 0;
      req_count <= 0;
      ar_count <= 0;
      max_req_count <= 0;
      returning <= 1'b0;
      ret_addr <= '0;
      ret_len <= '0;
      ret_beat <= '0;
      ret_delay <= 0;
    end else begin
      arready <= (req_count < REQ_DEPTH - 1);

      if (req_push) begin
        req_addr_mem[req_wr_ptr] <= araddr;
        req_len_mem[req_wr_ptr] <= arlen;
        req_wr_ptr <= (req_wr_ptr == REQ_DEPTH - 1) ? 0 : req_wr_ptr + 1;
        ar_count <= ar_count + 1;
        if (!req_pop_start && (req_count + 1 > max_req_count)) begin
          max_req_count <= req_count + 1;
        end
      end

      if (rvalid && rready) begin
        if (rlast) begin
          rvalid <= 1'b0;
          rlast <= 1'b0;
          returning <= 1'b0;
        end else begin
          ret_beat <= ret_beat + 8'd1;
          rdata <= mem_read(ret_addr + ({56'd0, ret_beat + 8'd1} << 6));
          rlast <= (ret_beat + 8'd1 == ret_len);
        end
      end

      if (req_pop_start) begin
        returning <= 1'b1;
        ret_delay <= RESP_LATENCY;
        ret_addr <= req_addr_mem[req_rd_ptr];
        ret_len <= req_len_mem[req_rd_ptr];
        ret_beat <= '0;
        req_rd_ptr <= (req_rd_ptr == REQ_DEPTH - 1) ? 0 : req_rd_ptr + 1;
      end else if (returning && !rvalid) begin
        if (ret_delay != 0) begin
          ret_delay <= ret_delay - 1;
        end else begin
          rvalid <= 1'b1;
          rdata <= mem_read(ret_addr);
          rlast <= (ret_len == 8'd0);
          rresp <= 2'b00;
          rid <= '0;
        end
      end

      unique case ({req_push, req_pop_start})
        2'b10: req_count <= req_count + 1;
        2'b01: req_count <= req_count - 1;
        default: begin
        end
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      seen_count <= 0;
      first_seen_cycle <= -1;
      last_seen_cycle <= -1;
      cycle_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (axis_tvalid && axis_tready) begin
        if (first_seen_cycle < 0) begin
          first_seen_cycle <= cycle_count;
        end
        last_seen_cycle <= cycle_count;
        if (axis_tdata !== word_with_id(seen_count)) begin
          $fatal(1, "data mismatch at beat %0d", seen_count);
        end
        if (axis_tkeep !== {64{1'b1}} || axis_tlast !== 1'b0) begin
          $fatal(1, "unexpected keep/tlast at beat %0d", seen_count);
        end
        seen_count <= seen_count + 1;
      end
    end
  end

  initial begin
    repeat (20000) @(posedge clk);
    $fatal(1, "Simulation watchdog timeout");
  end

  initial begin
    start = 1'b0;
    stop = 1'b0;
    clear = 1'b0;
    cfg_stream_bytes = '0;
    cfg_ring_size = RING_SIZE;
    cfg_ring_write_count = RING_SIZE;
    cfg_ring_eof = 1'b1;
    axis_tready = 1'b1;

    repeat (10) @(posedge clk);
    rstn = 1'b1;
    repeat (10) @(posedge clk);

    pulse_start();

    for (int i = 0; i < 10000 && !done; i++) begin
      @(posedge clk);
    end

    if (!done) begin
      $fatal(1, "stream reader did not finish");
    end
    if (error) begin
      $fatal(1, "stream reader reported error status=0x%08x", stream_status);
    end
    if (seen_count != TOTAL_BEATS) begin
      $fatal(1, "expected %0d beats, saw %0d", TOTAL_BEATS, seen_count);
    end
    if (read_count != RING_SIZE) begin
      $fatal(1, "read_count mismatch: %0d", read_count);
    end
    if (max_req_count < 4) begin
      $fatal(1, "reader did not build enough outstanding requests, max_req_count=%0d ar_count=%0d",
             max_req_count, ar_count);
    end

    $display("PASS: stream reader perf simulation completed beats=%0d ar_count=%0d max_req_count=%0d output_cycles=%0d",
             seen_count, ar_count, max_req_count, last_seen_cycle - first_seen_cycle + 1);
    $finish;
  end
endmodule
