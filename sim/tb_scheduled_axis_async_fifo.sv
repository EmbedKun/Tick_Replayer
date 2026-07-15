`timescale 1ns/1ps

module tb_scheduled_axis_async_fifo;
  localparam int PACKETS = 2048;

  logic s_clk = 1'b0;
  logic m_clk = 1'b0;
  logic s_resetn = 1'b0;
  logic m_resetn = 1'b0;
  logic clear = 1'b0;
  logic [511:0] s_tdata;
  logic [63:0] s_tkeep;
  logic s_tvalid;
  logic s_tready;
  logic s_tlast;
  logic s_tuser;
  logic [63:0] s_target;
  logic s_target_valid;
  logic [511:0] m_tdata;
  logic [63:0] m_tkeep;
  logic m_tvalid;
  logic m_tready;
  logic m_tlast;
  logic m_tuser;
  logic [63:0] m_target;
  logic m_target_valid;
  int sent_packets;
  int sent_beats;
  int recv_packets;
  int recv_beats;
  int recv_beat_in_packet;

  always #1667 s_clk = ~s_clk;
  always #1552 m_clk = ~m_clk;

  scheduled_axis_async_fifo #(
    .DEPTH_LOG2(8)
  ) dut (
    .s_clk(s_clk),
    .s_resetn(s_resetn),
    .m_clk(m_clk),
    .m_resetn(m_resetn),
    .clear(clear),
    .s_axis_tdata(s_tdata),
    .s_axis_tkeep(s_tkeep),
    .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready),
    .s_axis_tlast(s_tlast),
    .s_axis_tuser(s_tuser),
    .s_axis_target(s_target),
    .s_axis_target_valid(s_target_valid),
    .m_axis_tdata(m_tdata),
    .m_axis_tkeep(m_tkeep),
    .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready),
    .m_axis_tlast(m_tlast),
    .m_axis_tuser(m_tuser),
    .m_axis_target(m_target),
    .m_axis_target_valid(m_target_valid)
  );

  always_ff @(posedge m_clk) begin
    if (!m_resetn) begin
      m_tready <= 1'b0;
    end else begin
      m_tready <= ($urandom_range(0, 7) != 0);
    end
  end

  always_ff @(posedge m_clk) begin
    int expected_beats;
    if (!m_resetn) begin
      recv_packets <= 0;
      recv_beats <= 0;
      recv_beat_in_packet <= 0;
    end else if (m_tvalid && m_tready) begin
      expected_beats = (recv_packets % 4) + 1;
      if (m_tdata[31:0] !== recv_packets || m_tdata[63:32] !== recv_beat_in_packet) begin
        $fatal(1, "scheduled FIFO payload mismatch packet=%0d beat=%0d data=%h",
               recv_packets, recv_beat_in_packet, m_tdata[63:0]);
      end
      if (m_target_valid !== (recv_beat_in_packet == 0)) begin
        $fatal(1, "scheduled FIFO target-valid mismatch packet=%0d beat=%0d valid=%0b",
               recv_packets, recv_beat_in_packet, m_target_valid);
      end
      if ((recv_beat_in_packet == 0) && (m_target !== (64'd10000 + recv_packets * 64'd17))) begin
        $fatal(1, "scheduled FIFO target mismatch packet=%0d got=%0d", recv_packets, m_target);
      end
      if (m_tlast !== (recv_beat_in_packet == expected_beats - 1)) begin
        $fatal(1, "scheduled FIFO last mismatch packet=%0d beat=%0d", recv_packets, recv_beat_in_packet);
      end
      recv_beats <= recv_beats + 1;
      if (m_tlast) begin
        recv_packets <= recv_packets + 1;
        recv_beat_in_packet <= 0;
      end else begin
        recv_beat_in_packet <= recv_beat_in_packet + 1;
      end
    end
  end

  initial begin
    s_tdata = '0;
    s_tkeep = '1;
    s_tvalid = 1'b0;
    s_tlast = 1'b0;
    s_tuser = 1'b0;
    s_target = '0;
    s_target_valid = 1'b0;
    sent_packets = 0;
    sent_beats = 0;

    repeat (20) @(posedge s_clk);
    s_resetn = 1'b1;
    repeat (20) @(posedge m_clk);
    m_resetn = 1'b1;

    for (int packet = 0; packet < PACKETS; packet++) begin
      automatic int beats = (packet % 4) + 1;
      for (int beat = 0; beat < beats; beat++) begin
        @(negedge s_clk);
        s_tdata = '0;
        s_tdata[31:0] = packet;
        s_tdata[63:32] = beat;
        s_tlast = (beat == beats - 1);
        s_target = 64'd10000 + packet * 64'd17;
        s_target_valid = (beat == 0);
        s_tvalid = 1'b1;
        do begin
          @(posedge s_clk);
        end while (!s_tready);
        sent_beats++;
        @(negedge s_clk);
        s_tvalid = 1'b0;
      end
      sent_packets++;
    end

    wait (recv_packets == PACKETS);
    if (recv_beats != sent_beats) begin
      $fatal(1, "scheduled FIFO beat count mismatch sent=%0d recv=%0d", sent_beats, recv_beats);
    end
    $display("PASS: scheduled AXIS CDC FIFO preserved %0d packet targets across %0d beats",
             recv_packets, recv_beats);
    $finish;
  end

  initial begin
    #500000000;
    $fatal(1, "scheduled AXIS FIFO simulation watchdog timeout");
  end
endmodule
