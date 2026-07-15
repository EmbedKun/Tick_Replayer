`timescale 1ps/1ps

module tb_egress_scheduler_pipeline;
  localparam int PACKETS = 4096;
  localparam real CMAC_CLK_MHZ = 322.265625;

  logic replay_clk = 1'b0;
  logic cmac_clk = 1'b0;
  logic replay_resetn = 1'b0;
  logic cmac_resetn = 1'b0;
  logic clear = 1'b0;
  logic [63:0] source_ticks;
  logic [63:0] source_gray;
  logic [63:0] cmac_ticks;
  logic [63:0] base_target;

  logic [511:0] s_tdata;
  logic [63:0] s_tkeep;
  logic s_tvalid;
  logic s_tready;
  logic s_tlast;
  logic s_tuser;
  logic [63:0] s_target;
  logic s_target_valid;

  logic [511:0] f_tdata;
  logic [63:0] f_tkeep;
  logic f_tvalid;
  logic f_tready;
  logic f_tlast;
  logic f_tuser;
  logic [63:0] f_target;
  logic f_target_valid;

  logic [127:0] tx_datain0;
  logic [127:0] tx_datain1;
  logic [127:0] tx_datain2;
  logic [127:0] tx_datain3;
  logic tx_enain0;
  logic tx_enain1;
  logic tx_enain2;
  logic tx_enain3;
  logic tx_sopin0;
  logic tx_sopin1;
  logic tx_sopin2;
  logic tx_sopin3;
  logic tx_eopin0;
  logic tx_eopin1;
  logic tx_eopin2;
  logic tx_eopin3;
  logic [3:0] tx_mtyin0;
  logic [3:0] tx_mtyin1;
  logic [3:0] tx_mtyin2;
  logic [3:0] tx_mtyin3;
  logic tx_errin0;
  logic tx_errin1;
  logic tx_errin2;
  logic tx_errin3;

  int recv_packets;
  longint unsigned first_cmac_cycle;
  longint unsigned last_cmac_cycle;
  longint unsigned cmac_cycle;
  longint unsigned max_late_ticks;

  always #1667 replay_clk = ~replay_clk;
  always #1552 cmac_clk = ~cmac_clk;

  replay_global_timebase timebase_i (
    .clk(replay_clk),
    .rstn(replay_resetn),
    .time_binary(source_ticks),
    .time_gray(source_gray)
  );

  replay_time_sync monitor_time_i (
    .clk(cmac_clk),
    .rstn(cmac_resetn),
    .time_gray_async(source_gray),
    .time_ticks(cmac_ticks)
  );

  scheduled_axis_async_fifo #(
    .DEPTH_LOG2(10)
  ) cdc_i (
    .s_clk(replay_clk),
    .s_resetn(replay_resetn),
    .m_clk(cmac_clk),
    .m_resetn(cmac_resetn),
    .clear(clear),
    .s_axis_tdata(s_tdata),
    .s_axis_tkeep(s_tkeep),
    .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready),
    .s_axis_tlast(s_tlast),
    .s_axis_tuser(s_tuser),
    .s_axis_target(s_target),
    .s_axis_target_valid(s_target_valid),
    .m_axis_tdata(f_tdata),
    .m_axis_tkeep(f_tkeep),
    .m_axis_tvalid(f_tvalid),
    .m_axis_tready(f_tready),
    .m_axis_tlast(f_tlast),
    .m_axis_tuser(f_tuser),
    .m_axis_target(f_target),
    .m_axis_target_valid(f_target_valid)
  );

  axis_to_lbus_512 #(
    .FIFO_DEPTH(256)
  ) egress_i (
    .clk(cmac_clk),
    .resetn(cmac_resetn),
    .clear(clear),
    .global_time_gray(source_gray),
    .egress_schedule_enable(1'b1),
    .s_axis_tdata(f_tdata),
    .s_axis_tkeep(f_tkeep),
    .s_axis_tvalid(f_tvalid),
    .s_axis_tready(f_tready),
    .s_axis_tlast(f_tlast),
    .s_axis_tuser(f_tuser),
    .s_axis_target(f_target),
    .s_axis_target_valid(f_target_valid),
    .tx_datain0(tx_datain0),
    .tx_datain1(tx_datain1),
    .tx_datain2(tx_datain2),
    .tx_datain3(tx_datain3),
    .tx_enain0(tx_enain0),
    .tx_enain1(tx_enain1),
    .tx_enain2(tx_enain2),
    .tx_enain3(tx_enain3),
    .tx_sopin0(tx_sopin0),
    .tx_sopin1(tx_sopin1),
    .tx_sopin2(tx_sopin2),
    .tx_sopin3(tx_sopin3),
    .tx_eopin0(tx_eopin0),
    .tx_eopin1(tx_eopin1),
    .tx_eopin2(tx_eopin2),
    .tx_eopin3(tx_eopin3),
    .tx_mtyin0(tx_mtyin0),
    .tx_mtyin1(tx_mtyin1),
    .tx_mtyin2(tx_mtyin2),
    .tx_mtyin3(tx_mtyin3),
    .tx_errin0(tx_errin0),
    .tx_errin1(tx_errin1),
    .tx_errin2(tx_errin2),
    .tx_errin3(tx_errin3),
    .tx_rdyout(1'b1),
    .tx_ovfout(1'b0),
    .tx_unfout(1'b0)
  );

  function automatic logic [63:0] target_for_packet(input int packet);
    target_for_packet = base_target + 64'(packet * 2 + packet / 9);
  endfunction

  always_ff @(posedge cmac_clk) begin
    logic [63:0] expected_target;
    logic [63:0] late_ticks;
    if (!cmac_resetn) begin
      recv_packets <= 0;
      first_cmac_cycle <= '0;
      last_cmac_cycle <= '0;
      cmac_cycle <= '0;
      max_late_ticks <= '0;
    end else begin
      cmac_cycle <= cmac_cycle + 1;
      if (tx_sopin0) begin
        expected_target = target_for_packet(recv_packets);
        if (cmac_ticks < expected_target) begin
          $fatal(1, "egress SOP released early packet=%0d expected=%0d actual=%0d",
                 recv_packets, expected_target, cmac_ticks);
        end
        late_ticks = cmac_ticks - expected_target;
        if (late_ticks > 64'd3) begin
          $fatal(1, "egress SOP late packet=%0d expected=%0d actual=%0d",
                 recv_packets, expected_target, cmac_ticks);
        end
        if (late_ticks > max_late_ticks) begin
          max_late_ticks <= late_ticks;
        end
        if (recv_packets == 0) begin
          first_cmac_cycle <= cmac_cycle;
        end
        last_cmac_cycle <= cmac_cycle;
        recv_packets <= recv_packets + 1;
      end
    end
  end

  initial begin
    real pps_m;
    real wire_gbps;
    longint unsigned span_cycles;
    s_tdata = '0;
    s_tkeep = '1;
    s_tvalid = 1'b0;
    s_tlast = 1'b1;
    s_tuser = 1'b0;
    s_target = '0;
    s_target_valid = 1'b1;
    base_target = 64'd0;

    repeat (20) @(posedge replay_clk);
    replay_resetn = 1'b1;
    repeat (20) @(posedge cmac_clk);
    cmac_resetn = 1'b1;
    repeat (20) @(posedge replay_clk);

    base_target = source_ticks + 64'd5000;
    for (int packet = 0; packet < PACKETS; packet++) begin
      @(negedge replay_clk);
      s_tdata = '0;
      s_tdata[31:0] = packet;
      s_target = target_for_packet(packet);
      s_tvalid = 1'b1;
      do begin
        @(posedge replay_clk);
      end while (!s_tready);
      @(negedge replay_clk);
      s_tvalid = 1'b0;
    end

    wait (recv_packets == PACKETS);
    span_cycles = last_cmac_cycle - first_cmac_cycle + 1;
    pps_m = ((PACKETS - 1) * CMAC_CLK_MHZ) / (span_cycles - 1);
    wire_gbps = pps_m * 88.0 * 8.0 / 1000.0;
    if (wire_gbps < 99.5) begin
      $fatal(1, "small-packet egress throughput below target pps=%.3fM wire=%.3fGbps",
             pps_m, wire_gbps);
    end
    $display("PASS: egress 64B fractional 2/3-tick cadence packets=%0d pps=%.3fM wire=%.3fGbps max_late_ticks=%0d",
             PACKETS, pps_m, wire_gbps, max_late_ticks);
    $finish;
  end

  initial begin
    #1000000000;
    $fatal(1, "egress scheduler pipeline simulation watchdog timeout");
  end
endmodule
