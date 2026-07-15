`timescale 1ps/1ps

module tb_replay_time_sync;
  logic src_clk = 1'b0;
  logic dst0_clk = 1'b0;
  logic dst1_clk = 1'b0;
  logic rstn = 1'b0;
  logic [63:0] source_ticks;
  logic [63:0] source_gray;
  logic [63:0] ticks0;
  logic [63:0] ticks1;
  logic [63:0] prev0;
  logic [63:0] prev1;
  logic [63:0] directed_gray;
  logic [63:0] directed_ticks;

  always #1667 src_clk = ~src_clk;
  initial begin
    #430;
    forever #1667 dst0_clk = ~dst0_clk;
  end
  initial begin
    #1210;
    forever #1667 dst1_clk = ~dst1_clk;
  end

  replay_global_timebase source_i (
    .clk(src_clk),
    .rstn(rstn),
    .time_binary(source_ticks),
    .time_gray(source_gray)
  );

  replay_time_sync sync0_i (
    .clk(dst0_clk),
    .rstn(rstn),
    .time_gray_async(source_gray),
    .time_ticks(ticks0)
  );

  replay_time_sync sync1_i (
    .clk(dst1_clk),
    .rstn(rstn),
    .time_gray_async(source_gray),
    .time_ticks(ticks1)
  );

  replay_time_sync directed_sync_i (
    .clk(dst0_clk),
    .rstn(rstn),
    .time_gray_async(directed_gray),
    .time_ticks(directed_ticks)
  );

  task automatic check_directed_decode(input logic [63:0] binary_value);
    begin
      directed_gray = binary_value ^ (binary_value >> 1);
      repeat (4) @(posedge dst0_clk);
      #1;
      if (directed_ticks != binary_value) begin
        $fatal(1, "Gray decode mismatch value=%h gray=%h decoded=%h",
               binary_value, directed_gray, directed_ticks);
      end
    end
  endtask

  always @(posedge dst0_clk) begin
    if (rstn && ticks0 < prev0) begin
      $fatal(1, "port0 synchronized time regressed prev=%0d now=%0d", prev0, ticks0);
    end
    prev0 <= ticks0;
  end

  always @(posedge dst1_clk) begin
    if (rstn && ticks1 < prev1) begin
      $fatal(1, "port1 synchronized time regressed prev=%0d now=%0d", prev1, ticks1);
    end
    prev1 <= ticks1;
  end

  initial begin
    prev0 = '0;
    prev1 = '0;
    directed_gray = '0;
    repeat (12) @(posedge src_clk);
    rstn = 1'b1;
    repeat (10000) @(posedge src_clk);

    if ((source_ticks - ticks0) > 64'd4) begin
      $fatal(1, "port0 synchronized time lag too large source=%0d dst=%0d", source_ticks, ticks0);
    end
    if ((source_ticks - ticks1) > 64'd4) begin
      $fatal(1, "port1 synchronized time lag too large source=%0d dst=%0d", source_ticks, ticks1);
    end
    if ((ticks0 > ticks1 ? ticks0 - ticks1 : ticks1 - ticks0) > 64'd1) begin
      $fatal(1, "cross-port synchronized time skew too large p0=%0d p1=%0d", ticks0, ticks1);
    end

    check_directed_decode(64'h0000_0000_0000_0000);
    check_directed_decode(64'h0000_0000_0000_0001);
    check_directed_decode(64'h0000_0000_0000_0002);
    check_directed_decode(64'h0000_0001_0000_0000);
    check_directed_decode(64'h0123_4567_89ab_cdef);
    check_directed_decode(64'h8000_0000_0000_0000);
    check_directed_decode(64'hffff_ffff_ffff_ffff);

    $display("PASS: global Gray-code timebase is monotonic and directed 64-bit decode vectors pass source=%0d p0=%0d p1=%0d",
             source_ticks, ticks0, ticks1);
    $finish;
  end
endmodule
