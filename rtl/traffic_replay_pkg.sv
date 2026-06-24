package traffic_replay_pkg;
  localparam int AXIS_DATA_W = 512;
  localparam int AXIS_KEEP_W = AXIS_DATA_W / 8;
  localparam logic [15:0] AXIS_KEEP_BYTES = AXIS_KEEP_W;
  localparam int AXI_ADDR_W  = 64;
  localparam int AXI_ID_W    = 4;

  localparam logic [1:0] MODE_PRELOAD = 2'd0;
  localparam logic [1:0] MODE_STREAM  = 2'd1;
  localparam logic [1:0] MODE_LOOP    = 2'd2;

  localparam int DESC_BYTES = 64;
  localparam int DESC_WORD_SHIFT = 6;

  function automatic logic [AXIS_KEEP_W-1:0] keep_from_len(input logic [15:0] byte_count);
    logic [AXIS_KEEP_W-1:0] keep;
    int valid_bytes;
    begin
      valid_bytes = byte_count % AXIS_KEEP_W;
      if (valid_bytes == 0) begin
        keep = {AXIS_KEEP_W{1'b1}};
      end else begin
        keep = '0;
        for (int i = 0; i < AXIS_KEEP_W; i++) begin
          if (i < valid_bytes) begin
            keep[i] = 1'b1;
          end
        end
      end
      keep_from_len = keep;
    end
  endfunction

  function automatic logic [15:0] bytes_this_beat(input logic [15:0] bytes_left);
    begin
      if (bytes_left >= AXIS_KEEP_BYTES) begin
        bytes_this_beat = AXIS_KEEP_BYTES;
      end else begin
        bytes_this_beat = bytes_left;
      end
    end
  endfunction
endpackage
