# Architecture Notes

## Design intent

The replay datapath is intentionally split into source, scheduler, and TX engine layers:

```text
source layer      DDR trace reader or host stream parser
scheduler layer   converts pcap gaps to transmit eligibility
TX layer          consumes packet command + payload and drives CMAC AXIS
```

This keeps the timestamp behavior independent from whether packets are coming from DDR or PCIe streaming.

## Modes

`PRELOAD` is the preferred precision mode. The host loads a finite trace into DDR, sets `DESC_BASE`, `DATA_BASE`, `PKT_COUNT`, and writes `CONTROL.start`.

`STREAM` accepts a packet header beat followed by payload beats from host H2C stream. It can replay traces larger than DDR capacity, but underrun risk depends on host DMA and storage throughput.

`LOOP` is the same physical path as `PRELOAD`, with `loop_mode` enabled in the DDR reader. `LOOP_COUNT == 0` means infinite loop. `LOOP_GAP` replaces the first descriptor gap after each wrap.

## Throughput considerations

The current DDR reader is functional and simple: one 64B descriptor read per packet, followed by one payload burst. This makes verification easy, but the line-rate implementation should add:

- packed descriptor cache, ideally 4 descriptors per 64B read;
- independent descriptor and payload prefetch FIFOs;
- a skid buffer on AXI R data;
- outstanding read support with separate AXI IDs where the memory subsystem allows it;
- packet data FIFO deep enough to hide DDR arbitration latency.

For minimum Ethernet frames, descriptor command overhead can dominate. Keep the simple reader for early bring-up, then optimize after CMAC/QDMA/DDR wrappers are stable.

## Timestamp behavior

The scheduler maintains `target_ticks`. For each packet:

```text
target_ticks = first ? start_time_or_now_plus_gap : target_ticks + scaled_gap
```

`gap_ticks` is expected to be pre-scaled by host software. The register `RATE_Q16_16` is reserved for a later pipelined hardware scaler; the first timing-oriented RTL avoids a combinational 64x32 multiply in the 322MHz scheduler path.

If a packet is eligible late, the scheduler records `late_pulse`; the TX path still sends the packet as soon as payload is available.

## Remote programming

The script `scripts/program_remote.tcl` connects to `172.22.5.106:3121`, opens the first available U200 device, and programs the provided bitstream. It assumes the remote host already has `hw_server` running and cable access configured.
