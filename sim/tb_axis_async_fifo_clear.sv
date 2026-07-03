`timescale 1ns/1ps

module tb_axis_async_fifo_clear;
  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W / 8;
  localparam int USER_W = 1;

  logic s_clk = 1'b0;
  logic m_clk = 1'b0;
  logic s_resetn = 1'b0;
  logic m_resetn = 1'b0;
  logic clear = 1'b0;

  always #1.666 s_clk = ~s_clk;
  always #1.553 m_clk = ~m_clk;

  logic [DATA_W-1:0] s_axis_tdata;
  logic [KEEP_W-1:0] s_axis_tkeep;
  logic              s_axis_tvalid;
  logic              s_axis_tready;
  logic              s_axis_tlast;
  logic [USER_W-1:0] s_axis_tuser;

  logic [DATA_W-1:0] m_axis_tdata;
  logic [KEEP_W-1:0] m_axis_tkeep;
  logic              m_axis_tvalid;
  logic              m_axis_tready;
  logic              m_axis_tlast;
  logic [USER_W-1:0] m_axis_tuser;

  int unsigned recv_idx;
  logic check_phase;

  axis_async_fifo #(
    .DATA_W(DATA_W),
    .KEEP_W(KEEP_W),
    .USER_W(USER_W),
    .DEPTH_LOG2(4)
  ) dut (
    .s_clk(s_clk),
    .s_resetn(s_resetn),
    .m_clk(m_clk),
    .m_resetn(m_resetn),
    .clear(clear),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser)
  );

  function automatic logic [DATA_W-1:0] make_data(input int unsigned base);
    automatic logic [DATA_W-1:0] data;
    begin
      data = '0;
      for (int i = 0; i < KEEP_W; i++) begin
        data[i*8 +: 8] = 8'((base + i) & 8'hff);
      end
      make_data = data;
    end
  endfunction

  task automatic send_one(input int unsigned base);
    begin
      @(negedge s_clk);
      s_axis_tdata = make_data(base);
      s_axis_tkeep = '1;
      s_axis_tlast = 1'b1;
      s_axis_tuser = '0;
      s_axis_tvalid = 1'b1;
      do begin
        @(posedge s_clk);
      end while (!s_axis_tready);
      @(negedge s_clk);
      s_axis_tvalid = 1'b0;
      s_axis_tdata = '0;
      s_axis_tkeep = '0;
      s_axis_tlast = 1'b0;
    end
  endtask

  always_ff @(posedge m_clk) begin
    if (!m_resetn) begin
      recv_idx <= 0;
    end else if (m_axis_tvalid && m_axis_tready) begin
      if (!check_phase) begin
        $fatal(1, "stale beat escaped after FIFO clear");
      end
      if (m_axis_tdata !== make_data(32'h5000 + recv_idx)) begin
        $fatal(1, "post-clear data mismatch idx=%0d", recv_idx);
      end
      if (!m_axis_tlast || m_axis_tkeep !== '1) begin
        $fatal(1, "post-clear metadata mismatch idx=%0d", recv_idx);
      end
      recv_idx <= recv_idx + 1;
    end
  end

  initial begin
    s_axis_tdata = '0;
    s_axis_tkeep = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    s_axis_tuser = '0;
    m_axis_tready = 1'b0;
    check_phase = 1'b0;

    repeat (20) @(posedge s_clk);
    s_resetn = 1'b1;
    repeat (20) @(posedge m_clk);
    m_resetn = 1'b1;

    for (int i = 0; i < 8; i++) begin
      send_one(32'h1000 + i);
    end

    clear = 1'b1;
    repeat (32) @(posedge s_clk);
    clear = 1'b0;
    repeat (32) @(posedge m_clk);

    if (m_axis_tvalid) begin
      $fatal(1, "m_axis_tvalid stayed asserted after FIFO clear");
    end

    check_phase = 1'b1;
    m_axis_tready = 1'b1;
    for (int i = 0; i < 16; i++) begin
      send_one(32'h5000 + i);
    end

    wait (recv_idx == 16);
    repeat (20) @(posedge m_clk);
    $display("PASS: axis_async_fifo clear flushes stale buffered beats");
    $finish;
  end

  initial begin
    repeat (200000) @(posedge m_clk);
    $fatal(1, "axis_async_fifo clear simulation watchdog timeout recv=%0d", recv_idx);
  end
endmodule
