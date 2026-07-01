`timescale 1ns/1ps

module tb_axis_sync_fifo;
  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W / 8;
  localparam int DEPTH = 2048;
  localparam int N_BEATS = 4096;

  logic clk = 1'b0;
  logic rstn = 1'b0;
  logic clear = 1'b0;

  logic [DATA_W-1:0] s_axis_tdata;
  logic [KEEP_W-1:0] s_axis_tkeep;
  logic              s_axis_tvalid;
  logic              s_axis_tready;
  logic              s_axis_tlast;
  logic [DATA_W-1:0] m_axis_tdata;
  logic [KEEP_W-1:0] m_axis_tkeep;
  logic              m_axis_tvalid;
  logic              m_axis_tready;
  logic              m_axis_tlast;
  logic [$clog2(DEPTH+1)-1:0] level;

  int send_idx;
  int recv_idx;
  int cycle_idx;
  int clear_send_idx;
  int clear_recv_idx;
  logic run_enable;

  always #1.667 clk = ~clk;

  assign s_axis_tdata = pattern(send_idx);
  assign s_axis_tkeep = keep_pattern(send_idx);
  assign s_axis_tlast = (send_idx[4:0] == 5'd31);

  axis_sync_fifo #(
    .DATA_W(DATA_W),
    .KEEP_W(KEEP_W),
    .DEPTH(DEPTH)
  ) dut (
    .clk(clk),
    .rstn(rstn),
    .clear(clear),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .level(level)
  );

  function automatic logic [DATA_W-1:0] pattern(input int idx);
    logic [DATA_W-1:0] out;
    begin
      for (int b = 0; b < DATA_W/32; b++) begin
        out[b*32 +: 32] = 32'h5a00_0000 ^ (idx * 32'h1021) ^ b;
      end
      pattern = out;
    end
  endfunction

  function automatic logic [KEEP_W-1:0] keep_pattern(input int idx);
    begin
      keep_pattern = (idx[2:0] == 3'd0) ? {{(KEEP_W-7){1'b1}}, 7'h7f} : {KEEP_W{1'b1}};
    end
  endfunction

  initial begin
    run_enable = 1'b0;
    clear_send_idx = -1;
    clear_recv_idx = -1;

    repeat (10) @(posedge clk);
    rstn = 1'b1;
    repeat (5) @(posedge clk);

    run_enable = 1'b1;

    wait (send_idx >= 128);
    @(posedge clk);
    clear = 1'b1;
    clear_send_idx = send_idx;
    repeat (3) @(posedge clk);
    clear = 1'b0;
    clear_recv_idx = recv_idx;

    wait (recv_idx >= clear_recv_idx + (N_BEATS - clear_send_idx));
    repeat (20) @(posedge clk);
    $display("PASS: axis_sync_fifo BRAM registered-output FIFO simulation completed send=%0d recv=%0d level=%0d", send_idx, recv_idx, level);
    $finish;
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      s_axis_tvalid <= 1'b0;
      m_axis_tready <= 1'b0;
      send_idx <= 0;
      cycle_idx <= 0;
    end else if (!run_enable) begin
      s_axis_tvalid <= 1'b0;
      m_axis_tready <= 1'b0;
    end else if (clear) begin
      s_axis_tvalid <= s_axis_tvalid;
    end else begin
      cycle_idx <= cycle_idx + 1;
      m_axis_tready <= ((cycle_idx % 17) != 5) && ((cycle_idx % 23) != 9);
      if (!s_axis_tvalid && (send_idx < N_BEATS)) begin
        s_axis_tvalid <= 1'b1;
      end
      if (s_axis_tvalid && s_axis_tready && (send_idx < N_BEATS)) begin
        if (send_idx == N_BEATS - 1) begin
          s_axis_tvalid <= 1'b0;
        end
        send_idx <= send_idx + 1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      recv_idx <= 0;
    end else if (rstn && !clear && m_axis_tvalid && m_axis_tready) begin
      int expected_idx;
      if (clear_recv_idx >= 0) begin
        expected_idx = clear_send_idx + (recv_idx - clear_recv_idx);
      end else begin
        expected_idx = recv_idx;
      end
      if (m_axis_tdata !== pattern(expected_idx)) begin
        $fatal(1, "DATA mismatch recv=%0d expected_idx=%0d", recv_idx, expected_idx);
      end
      if (m_axis_tkeep !== keep_pattern(expected_idx)) begin
        $fatal(1, "KEEP mismatch recv=%0d expected_idx=%0d", recv_idx, expected_idx);
      end
      if (m_axis_tlast !== (expected_idx[4:0] == 5'd31)) begin
        $fatal(1, "TLAST mismatch recv=%0d expected_idx=%0d", recv_idx, expected_idx);
      end
      recv_idx <= recv_idx + 1;
    end
  end

  initial begin
    repeat (300000) @(posedge clk);
    $fatal(1, "axis_sync_fifo simulation watchdog timeout send=%0d recv=%0d level=%0d", send_idx, recv_idx, level);
  end
endmodule
