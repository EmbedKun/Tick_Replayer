`timescale 1ns/1ps

module replay_scheduler #(
  parameter int PKT_FIFO_DEPTH = 4096
) (
  input  logic        clk,
  input  logic        rstn,
  input  logic        start,
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
  localparam int PTR_W = $clog2(PKT_FIFO_DEPTH);
  localparam int CNT_W = $clog2(PKT_FIFO_DEPTH + 1);
  localparam logic [CNT_W-1:0] PKT_FIFO_DEPTH_LEVEL = PKT_FIFO_DEPTH;

  logic [PTR_W-1:0] wr_ptr;
  logic [PTR_W-1:0] rd_ptr;
  logic [CNT_W-1:0] mem_count;
  logic [63:0] target_mem [PKT_FIFO_DEPTH];
  logic [15:0] len_mem [PKT_FIFO_DEPTH];
  logic [15:0] flags_mem [PKT_FIFO_DEPTH];

  logic [63:0] target_accum;
  logic [63:0] push_target;
  logic [63:0] schedule_tick_next;
  logic [63:0] head_target;
  logic [15:0] head_len;
  logic [15:0] head_flags;
  logic        head_valid;
  logic [15:0] out_len;
  logic [15:0] out_flags;
  logic        out_valid;
  logic        out_late;
  logic        first_pkt;
  logic        meta_fire;
  logic        pkt_fire;
  logic        load_fire;
  logic        out_can_load;
  logic        refill_from_mem;
  logic        meta_to_head;
  logic        meta_to_mem;
  logic [CNT_W:0] total_count;

  assign push_target =
    first_pkt ?
      ((cfg_start_time == 64'd0) ? s_meta_gap_ticks : cfg_start_time) :
      (target_accum + s_meta_gap_ticks);

  assign schedule_tick_next = now_ticks + 64'd1;
  assign total_count = {1'b0, mem_count} +
                       {{CNT_W{1'b0}}, head_valid} +
                       {{CNT_W{1'b0}}, out_valid};
  assign s_meta_ready = !clear && (total_count < {1'b0, PKT_FIFO_DEPTH_LEVEL});
  assign m_pkt_valid  = enable && out_valid;
  assign m_pkt_len    = out_len;
  assign m_pkt_flags  = out_flags;
  assign meta_fire    = s_meta_valid && s_meta_ready;
  assign pkt_fire     = m_pkt_valid && m_pkt_ready;
  assign out_can_load = !out_valid || pkt_fire;
  assign load_fire    = enable && out_can_load && head_valid &&
                        (head_target <= schedule_tick_next);
  assign refill_from_mem = (mem_count != '0) && (load_fire || !head_valid);
  assign meta_to_head = meta_fire && (mem_count == '0) && (!head_valid || load_fire);
  assign meta_to_mem  = meta_fire && !meta_to_head;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      now_ticks    <= '0;
      wr_ptr       <= '0;
      rd_ptr       <= '0;
      mem_count    <= '0;
      target_accum <= '0;
      head_target  <= '0;
      head_len     <= '0;
      head_flags   <= '0;
      head_valid   <= 1'b0;
      out_len      <= '0;
      out_flags    <= '0;
      out_valid    <= 1'b0;
      out_late     <= 1'b0;
      first_pkt    <= 1'b1;
      late_pulse   <= 1'b0;
    end else begin
      late_pulse <= 1'b0;

      if (clear || start) begin
        now_ticks    <= '0;
        wr_ptr       <= '0;
        rd_ptr       <= '0;
        mem_count    <= '0;
        target_accum <= '0;
        head_target  <= '0;
        head_len     <= '0;
        head_flags   <= '0;
        head_valid   <= 1'b0;
        out_len      <= '0;
        out_flags    <= '0;
        out_valid    <= 1'b0;
        out_late     <= 1'b0;
        first_pkt    <= 1'b1;
      end else begin
        if (enable) begin
          now_ticks <= now_ticks + 64'd1;
        end

        if (meta_to_mem) begin
          target_mem[wr_ptr] <= push_target;
          len_mem[wr_ptr]    <= s_meta_len;
          flags_mem[wr_ptr]  <= s_meta_flags;
          wr_ptr             <= wr_ptr + {{(PTR_W-1){1'b0}}, 1'b1};
        end

        if (meta_fire) begin
          target_accum       <= push_target;
          first_pkt          <= 1'b0;
        end

        if (pkt_fire) begin
          late_pulse <= out_late;
        end

        if (load_fire) begin
          out_len   <= head_len;
          out_flags <= head_flags;
          out_late  <= (head_target < schedule_tick_next);
        end

        if (refill_from_mem) begin
          head_target <= target_mem[rd_ptr];
          head_len    <= len_mem[rd_ptr];
          head_flags  <= flags_mem[rd_ptr];
          head_valid  <= 1'b1;
          rd_ptr    <= rd_ptr + {{(PTR_W-1){1'b0}}, 1'b1};
        end else if (meta_to_head) begin
          head_target <= push_target;
          head_len    <= s_meta_len;
          head_flags  <= s_meta_flags;
          head_valid  <= 1'b1;
        end else if (load_fire) begin
          head_valid <= 1'b0;
        end

        unique case ({load_fire, pkt_fire})
          2'b10: out_valid <= 1'b1;
          2'b01: out_valid <= 1'b0;
          default: begin
          end
        endcase

        unique case ({meta_to_mem, refill_from_mem})
          2'b10: mem_count <= mem_count + {{(CNT_W-1){1'b0}}, 1'b1};
          2'b01: mem_count <= mem_count - {{(CNT_W-1){1'b0}}, 1'b1};
          default: begin
          end
        endcase
      end
    end
  end
endmodule
