`timescale 1ns/1ps

module replay_global_timebase (
  input  logic        clk,
  input  logic        rstn,
  output logic [63:0] time_binary,
  output logic [63:0] time_gray
);
  logic [63:0] time_binary_next;

  assign time_binary_next = time_binary + 64'd1;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      time_binary <= '0;
      time_gray   <= '0;
    end else begin
      time_binary <= time_binary_next;
      time_gray   <= time_binary_next ^ (time_binary_next >> 1);
    end
  end
endmodule
