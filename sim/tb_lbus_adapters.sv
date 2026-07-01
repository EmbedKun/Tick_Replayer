`timescale 1ns/1ps

module tb_lbus_adapters;
  localparam int DATA_W = 512;
  localparam int KEEP_W = 64;
  localparam int SEG_DATA_W = 128;
  localparam int MAX_BEATS = 4096;

  logic clk = 1'b0;
  logic resetn = 1'b0;

  logic [DATA_W-1:0] s_axis_tdata;
  logic [KEEP_W-1:0] s_axis_tkeep;
  logic              s_axis_tvalid;
  logic              s_axis_tready;
  logic              s_axis_tlast;
  logic              s_axis_tuser;

  logic [SEG_DATA_W-1:0] tx_datain0;
  logic [SEG_DATA_W-1:0] tx_datain1;
  logic [SEG_DATA_W-1:0] tx_datain2;
  logic [SEG_DATA_W-1:0] tx_datain3;
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
  logic tx_rdyout;

  logic [DATA_W-1:0] m_axis_tdata;
  logic [KEEP_W-1:0] m_axis_tkeep;
  logic              m_axis_tvalid;
  logic              m_axis_tlast;
  logic              m_axis_tuser;

  logic [DATA_W-1:0] exp_data [0:MAX_BEATS-1];
  logic [KEEP_W-1:0] exp_keep [0:MAX_BEATS-1];
  logic              exp_last [0:MAX_BEATS-1];
  logic              exp_user [0:MAX_BEATS-1];
  int exp_wr = 0;
  int exp_rd = 0;
  int sop_count = 0;
  int eop_count = 0;
  int cycle_count = 0;
  int full_rate_outputs = 0;
  int full_rate_first_cycle = -1;
  int full_rate_last_cycle = -1;
  logic force_ready = 1'b0;
  logic full_rate_phase = 1'b0;

  always #1.55 clk = ~clk;

  axis_to_lbus_512 dut_tx (
    .clk(clk),
    .resetn(resetn),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
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
    .tx_rdyout(tx_rdyout),
    .tx_ovfout(1'b0),
    .tx_unfout(1'b0)
  );

  lbus_to_axis_512 dut_rx (
    .clk(clk),
    .resetn(resetn),
    .rx_dataout0(tx_datain0),
    .rx_dataout1(tx_datain1),
    .rx_dataout2(tx_datain2),
    .rx_dataout3(tx_datain3),
    .rx_enaout0(tx_rdyout && tx_enain0),
    .rx_enaout1(tx_rdyout && tx_enain1),
    .rx_enaout2(tx_rdyout && tx_enain2),
    .rx_enaout3(tx_rdyout && tx_enain3),
    .rx_sopout0(tx_rdyout && tx_sopin0),
    .rx_sopout1(tx_rdyout && tx_sopin1),
    .rx_sopout2(tx_rdyout && tx_sopin2),
    .rx_sopout3(tx_rdyout && tx_sopin3),
    .rx_eopout0(tx_rdyout && tx_eopin0),
    .rx_eopout1(tx_rdyout && tx_eopin1),
    .rx_eopout2(tx_rdyout && tx_eopin2),
    .rx_eopout3(tx_rdyout && tx_eopin3),
    .rx_mtyout0(tx_mtyin0),
    .rx_mtyout1(tx_mtyin1),
    .rx_mtyout2(tx_mtyin2),
    .rx_mtyout3(tx_mtyin3),
    .rx_errout0(tx_rdyout && tx_errin0),
    .rx_errout1(tx_rdyout && tx_errin1),
    .rx_errout2(tx_rdyout && tx_errin2),
    .rx_errout3(tx_rdyout && tx_errin3),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser)
  );

  function automatic [DATA_W-1:0] make_data(input int pkt_id, input int beat_idx);
    automatic logic [DATA_W-1:0] data;
    begin
      data = '0;
      for (int i = 0; i < KEEP_W; i++) begin
        data[i*8 +: 8] = (pkt_id * 11 + beat_idx * 7 + i) & 8'hff;
      end
      make_data = data;
    end
  endfunction

  function automatic [KEEP_W-1:0] make_keep(input int byte_count);
    automatic logic [KEEP_W-1:0] keep;
    begin
      keep = '0;
      for (int i = 0; i < KEEP_W; i++) begin
        keep[i] = i < byte_count;
      end
      make_keep = keep;
    end
  endfunction

  task automatic expect_beat(
    input logic [DATA_W-1:0] data,
    input logic [KEEP_W-1:0] keep,
    input logic last,
    input logic user
  );
    begin
      if (exp_wr >= MAX_BEATS) begin
        $fatal(1, "expected beat queue overflow");
      end
      exp_data[exp_wr] = data;
      exp_keep[exp_wr] = keep;
      exp_last[exp_wr] = last;
      exp_user[exp_wr] = user;
      exp_wr++;
    end
  endtask

  task automatic send_beat(
    input logic [DATA_W-1:0] data,
    input logic [KEEP_W-1:0] keep,
    input logic last,
    input logic user
  );
    begin
      @(negedge clk);
      s_axis_tdata  = data;
      s_axis_tkeep  = keep;
      s_axis_tlast  = last;
      s_axis_tuser  = user;
      s_axis_tvalid = 1'b1;
      do begin
        @(posedge clk);
      end while (!s_axis_tready);
      expect_beat(data, keep, last, user && last);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast  = 1'b0;
      s_axis_tuser  = 1'b0;
      s_axis_tkeep  = '0;
      s_axis_tdata  = '0;
    end
  endtask

  task automatic send_packet(input int pkt_id, input int length_bytes, input logic err);
    automatic int remaining;
    automatic int beat_idx;
    automatic int beat_bytes;
    begin
      remaining = length_bytes;
      beat_idx = 0;
      while (remaining > 0) begin
        beat_bytes = (remaining > KEEP_W) ? KEEP_W : remaining;
        send_beat(
          make_data(pkt_id, beat_idx),
          make_keep(beat_bytes),
          remaining <= KEEP_W,
          err && (remaining <= KEEP_W)
        );
        remaining -= beat_bytes;
        beat_idx++;
      end
    end
  endtask

  task automatic send_full_rate_64(input int packet_count);
    automatic int sent;
    automatic logic [DATA_W-1:0] data;
    begin
      sent = 0;
      @(negedge clk);
      s_axis_tkeep  = '1;
      s_axis_tlast  = 1'b1;
      s_axis_tuser  = 1'b0;
      s_axis_tvalid = 1'b1;
      s_axis_tdata  = make_data(1000, sent);
      while (sent < packet_count) begin
        @(posedge clk);
        if (s_axis_tready) begin
          data = make_data(1000, sent);
          expect_beat(data, '1, 1'b1, 1'b0);
          sent++;
          @(negedge clk);
          if (sent < packet_count) begin
            s_axis_tdata = make_data(1000, sent);
          end
        end else begin
          @(negedge clk);
        end
      end
      s_axis_tvalid = 1'b0;
      s_axis_tlast  = 1'b0;
      s_axis_tuser  = 1'b0;
      s_axis_tkeep  = '0;
      s_axis_tdata  = '0;
    end
  endtask

  always_ff @(posedge clk) begin
    if (!resetn) begin
      tx_rdyout <= 1'b0;
      cycle_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      tx_rdyout <= force_ready || ($urandom_range(0, 7) != 0);
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      exp_rd <= 0;
      sop_count <= 0;
      eop_count <= 0;
    end else begin
      if (tx_rdyout) begin
        sop_count <= sop_count + tx_sopin0 + tx_sopin1 + tx_sopin2 + tx_sopin3;
        eop_count <= eop_count + tx_eopin0 + tx_eopin1 + tx_eopin2 + tx_eopin3;
      end

      if (m_axis_tvalid) begin
        if (full_rate_phase) begin
          if (full_rate_outputs == 0) begin
            full_rate_first_cycle <= cycle_count;
          end
          full_rate_outputs <= full_rate_outputs + 1;
          full_rate_last_cycle <= cycle_count;
        end

        if (exp_rd >= exp_wr) begin
          $fatal(1, "unexpected output beat");
        end
        if (m_axis_tdata !== exp_data[exp_rd]) begin
          $fatal(1, "TDATA mismatch beat %0d expected=%h got=%h", exp_rd, exp_data[exp_rd], m_axis_tdata);
        end
        if (m_axis_tkeep !== exp_keep[exp_rd]) begin
          $fatal(1, "TKEEP mismatch beat %0d expected=%h got=%h", exp_rd, exp_keep[exp_rd], m_axis_tkeep);
        end
        if (m_axis_tlast !== exp_last[exp_rd]) begin
          $fatal(1, "TLAST mismatch beat %0d expected=%0b got=%0b", exp_rd, exp_last[exp_rd], m_axis_tlast);
        end
        if (m_axis_tuser !== exp_user[exp_rd]) begin
          $fatal(1, "TUSER mismatch beat %0d expected=%0b got=%0b", exp_rd, exp_user[exp_rd], m_axis_tuser);
        end
        exp_rd <= exp_rd + 1;
      end
    end
  end

  initial begin
    s_axis_tdata = '0;
    s_axis_tkeep = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    s_axis_tuser = 1'b0;

    repeat (16) @(posedge clk);
    resetn = 1'b1;
    repeat (8) @(posedge clk);

    send_packet(0, 64, 1'b0);
    send_packet(1, 65, 1'b0);
    send_packet(2, 124, 1'b1);
    send_packet(3, 1518, 1'b0);
    send_packet(4, 256, 1'b0);

    wait (exp_rd == exp_wr);
    repeat (8) @(posedge clk);

    if (sop_count != 5) begin
      $fatal(1, "SOP count mismatch expected=5 got=%0d", sop_count);
    end
    if (eop_count != 5) begin
      $fatal(1, "EOP count mismatch expected=5 got=%0d", eop_count);
    end

    force_ready = 1'b1;
    repeat (4) @(posedge clk);
    full_rate_phase = 1'b1;
    send_full_rate_64(1024);
    wait (exp_rd == exp_wr);
    repeat (4) @(posedge clk);
    full_rate_phase = 1'b0;

    if (full_rate_outputs != 1024) begin
      $fatal(1, "full-rate output count mismatch expected=1024 got=%0d", full_rate_outputs);
    end
    if ((full_rate_last_cycle - full_rate_first_cycle + 1) > 1026) begin
      $fatal(1, "full-rate adapter phase inserted too many bubbles: first=%0d last=%0d outputs=%0d",
             full_rate_first_cycle, full_rate_last_cycle, full_rate_outputs);
    end

    $display("PASS: LBUS adapters preserve AXIS payload, keep, last, and error metadata under backpressure");
    $display("PASS: LBUS adapter full-rate 64B burst outputs=%0d span_cycles=%0d",
             full_rate_outputs, full_rate_last_cycle - full_rate_first_cycle + 1);
    $finish;
  end
endmodule
