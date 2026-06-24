`timescale 1ns/1ps

module replay_scheduler (
  input  logic        clk,
  input  logic        rstn,
  input  logic        enable,
  input  logic        clear,
  input  logic [63:0] cfg_start_time,
  input  logic [31:0] cfg_rate_q16_16,

  input  logic        s_meta_valid,
  output logic        s_meta_ready,
  input  logic [63:0] s_meta_gap_ticks,
  input  logic [15:0] s_meta_len,
  input  logic [15:0] s_meta_flags,

  output logic        m_pkt_valid,
  input  logic        m_pkt_ready,
  output logic [15:0] m_pkt_len,
  output logic [15:0] m_pkt_flags,

  output logic [63:0] now_ticks,
  output logic        late_pulse
);
  logic        pending;
  logic [63:0] target_ticks;
  logic [15:0] pkt_len_q;
  logic [15:0] pkt_flags_q;
  logic        first_pkt;

  assign s_meta_ready     = enable && !pending;
  assign m_pkt_valid      = enable && pending && (now_ticks >= target_ticks);
  assign m_pkt_len        = pkt_len_q;
  assign m_pkt_flags      = pkt_flags_q;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      now_ticks    <= '0;
      pending      <= 1'b0;
      target_ticks <= '0;
      pkt_len_q    <= '0;
      pkt_flags_q  <= '0;
      first_pkt    <= 1'b1;
      late_pulse   <= 1'b0;
    end else begin
      now_ticks  <= now_ticks + 64'd1;
      late_pulse <= 1'b0;

      if (clear) begin
        pending      <= 1'b0;
        target_ticks <= '0;
        pkt_len_q    <= '0;
        pkt_flags_q  <= '0;
        first_pkt    <= 1'b1;
      end else begin
        if (s_meta_valid && s_meta_ready) begin
          pending     <= 1'b1;
          pkt_len_q   <= s_meta_len;
          pkt_flags_q <= s_meta_flags;
          if (first_pkt) begin
            target_ticks <= (cfg_start_time == 64'd0) ? (now_ticks + s_meta_gap_ticks) : cfg_start_time;
            first_pkt    <= 1'b0;
          end else begin
            target_ticks <= target_ticks + s_meta_gap_ticks;
          end
        end

        if (m_pkt_valid && m_pkt_ready) begin
          pending    <= 1'b0;
          late_pulse <= (now_ticks > target_ticks);
        end
      end
    end
  end
endmodule
