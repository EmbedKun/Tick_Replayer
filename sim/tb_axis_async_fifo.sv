`timescale 1ns/1ps

module tb_axis_async_fifo;
  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W / 8;
  localparam int USER_W = 1;
  localparam int DEPTH_LOG2 = 5;
  localparam int N_BEATS = 1024;

  logic s_clk = 1'b0;
  logic m_clk = 1'b0;
  logic s_resetn = 1'b0;
  logic m_resetn = 1'b0;

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

  logic [DATA_W-1:0] exp_data [0:N_BEATS-1];
  logic [KEEP_W-1:0] exp_keep [0:N_BEATS-1];
  logic              exp_last [0:N_BEATS-1];
  logic [USER_W-1:0] exp_user [0:N_BEATS-1];

  int unsigned send_idx;
  int unsigned recv_idx;
  int unsigned m_cycle;

  assign s_axis_tvalid = s_resetn && (send_idx < N_BEATS);
  assign s_axis_tdata  = (send_idx < N_BEATS) ? exp_data[send_idx] : '0;
  assign s_axis_tkeep  = (send_idx < N_BEATS) ? exp_keep[send_idx] : '0;
  assign s_axis_tlast  = (send_idx < N_BEATS) ? exp_last[send_idx] : 1'b0;
  assign s_axis_tuser  = (send_idx < N_BEATS) ? exp_user[send_idx] : '0;

  axis_async_fifo #(
    .DATA_W(DATA_W),
    .KEEP_W(KEEP_W),
    .USER_W(USER_W),
    .DEPTH_LOG2(DEPTH_LOG2)
  ) dut (
    .s_clk(s_clk),
    .s_resetn(s_resetn),
    .m_clk(m_clk),
    .m_resetn(m_resetn),
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

  function automatic logic [DATA_W-1:0] make_data(input int unsigned idx);
    logic [DATA_W-1:0] data;
    begin
      data = '0;
      for (int i = 0; i < DATA_W / 8; i++) begin
        data[i*8 +: 8] = 8'((idx * 11 + i * 7 + (idx >> 2)) & 8'hff);
      end
      make_data = data;
    end
  endfunction

  initial begin
    for (int i = 0; i < N_BEATS; i++) begin
      exp_data[i] = make_data(i);
      exp_keep[i] = (i % 5 == 4) ? 64'h0000_0000_0000_ffff : {KEEP_W{1'b1}};
      exp_last[i] = (i % 7 == 6);
      exp_user[i] = USER_W'(i[0]);
    end

    repeat (20) @(posedge s_clk);
    s_resetn = 1'b1;
    repeat (20) @(posedge m_clk);
    m_resetn = 1'b1;
  end

  always_ff @(posedge s_clk) begin
    if (!s_resetn) begin
      send_idx <= 0;
    end else begin
      if ((send_idx < N_BEATS) && s_axis_tready) begin
        send_idx <= send_idx + 1;
      end
    end
  end

  always_ff @(posedge m_clk) begin
    if (!m_resetn) begin
      recv_idx <= 0;
      m_cycle <= 0;
      m_axis_tready <= 1'b0;
    end else begin
      m_cycle <= m_cycle + 1;
      m_axis_tready <= ((m_cycle % 11) != 3) && ((m_cycle % 17) != 5);

      if (m_axis_tvalid && m_axis_tready) begin
        if (recv_idx >= N_BEATS) begin
          $fatal(1, "received too many beats");
        end
        if (m_axis_tdata !== exp_data[recv_idx]) begin
          $fatal(1, "data mismatch idx=%0d", recv_idx);
        end
        if (m_axis_tkeep !== exp_keep[recv_idx]) begin
          $fatal(1, "keep mismatch idx=%0d got=0x%016x exp=0x%016x",
                 recv_idx, m_axis_tkeep, exp_keep[recv_idx]);
        end
        if (m_axis_tlast !== exp_last[recv_idx]) begin
          $fatal(1, "last mismatch idx=%0d", recv_idx);
        end
        if (m_axis_tuser !== exp_user[recv_idx]) begin
          $fatal(1, "user mismatch idx=%0d", recv_idx);
        end
        recv_idx <= recv_idx + 1;
      end
    end
  end

  initial begin
    wait (m_resetn);
    wait (recv_idx == N_BEATS);
    repeat (20) @(posedge m_clk);
    $display("PASS: axis_async_fifo registered-output CDC FIFO simulation completed");
    $finish;
  end

  initial begin
    repeat (2000000) @(posedge m_clk);
    $fatal(1, "axis_async_fifo simulation watchdog timeout send=%0d recv=%0d", send_idx, recv_idx);
  end
endmodule
