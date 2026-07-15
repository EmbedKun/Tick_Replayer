`timescale 1ns/1ps

module replay_time_sync (
  input  logic        clk,
  input  logic        rstn,
  input  logic [63:0] time_gray_async,
  output logic [63:0] time_ticks
);
  (* ASYNC_REG = "TRUE" *) logic [63:0] time_gray_sync1;
  (* ASYNC_REG = "TRUE" *) logic [63:0] time_gray_sync2;

  function automatic logic [63:0] gray_to_binary(input logic [63:0] gray);
    logic [63:0] value;
    begin
      value = gray;
      value = value ^ (value >> 1);
      value = value ^ (value >> 2);
      value = value ^ (value >> 4);
      value = value ^ (value >> 8);
      value = value ^ (value >> 16);
      value = value ^ (value >> 32);
      gray_to_binary = value;
    end
  endfunction

  always_ff @(posedge clk) begin
    if (!rstn) begin
      time_gray_sync1 <= '0;
      time_gray_sync2 <= '0;
      time_ticks      <= '0;
    end else begin
      time_gray_sync1 <= time_gray_async;
      time_gray_sync2 <= time_gray_sync1;
      time_ticks      <= gray_to_binary(time_gray_sync2);
    end
  end
endmodule
