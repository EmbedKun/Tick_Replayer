`timescale 1ns/1ps

module replay_global_timebase_bd (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET rstn" *)
  input  wire        clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rstn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire        rstn,
  output wire [63:0] time_binary,
  output wire [63:0] time_gray
);
  replay_global_timebase core_i (
    .clk(clk),
    .rstn(rstn),
    .time_binary(time_binary),
    .time_gray(time_gray)
  );
endmodule
