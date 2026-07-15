# PRELOAD And LOOP Hardware Reference

This document is the hardware/software contract for Tick Replayer `PRELOAD`
and `LOOP` modes.  It describes the trace format, BAR registers, DDR layout,
scheduling behavior, datapath implementation, and release validation criteria.
Historical board measurements remain in the dated files under `docs/`.

## Data Path

```text
classic pcap
  -> tick-replay prepare
  -> desc.bin + data.bin + manifest.json
  -> XDMA memory-mapped H2C
  -> FPGA DDR4
  -> ddr_trace_reader
  -> replay_scheduler
  -> replay_tx_engine
  -> scheduled_axis_async_fifo
  -> CMAC-domain egress scheduler
  -> AXI-Stream to LBUS adapter
  -> 100G CMAC
  -> QSFP
```

The host leaves the transmit data path after loading the trace.  During replay,
the FPGA reads descriptors and payloads from bank-local DDR, accumulates packet
gaps into target ticks, and sends complete frames to the selected CMAC.

`LOOP` uses the same data path and DDR trace.  At end of trace it reloads the
descriptor/payload reader, waits for the configured loop gap, and starts the
next iteration.

## Descriptor Format

Each descriptor is exactly `64 B`, little-endian, and aligned to one 512-bit
DDR beat.

| Byte offset | Width | Field | Meaning |
| ---: | ---: | --- | --- |
| `0x00` | `64 bits` | `gap_ticks` | Requested gap relative to the previous packet, in replay ticks |
| `0x08` | `32 bits` | `data_word_offset` | Payload offset from `DATA_BASE`, measured in `64 B` words |
| `0x0c` | `16 bits` | `frame_len` | Ethernet frame bytes, excluding preamble and FCS |
| `0x0e` | `16 bits` | `flags` | Reserved per-packet controls |
| `0x10` | `48 B` | reserved | Written as zero |

Payloads are concatenated in `data.bin` and padded to `64 B` boundaries.  The
fixed descriptor size simplifies DDR burst reads and leaves space for future
metadata without changing the host/FPGA ABI.

## BAR Windows

XDMA exposes the application AXI-Lite master through `/dev/xdma0_user`.

| BAR offset | Window |
| ---: | --- |
| `0x00000` | TX0 replay control and statistics |
| `0x10000` | TX1 replay control and statistics |
| `0x20000` | RX0 measurement and capture |
| `0x30000` | RX1 measurement and capture |

All offsets below are relative to the selected TX or RX window.

## TX Register Map

| Offset | Register | Access | Description |
| ---: | --- | :---: | --- |
| `0x0000` | `CONTROL` | RW pulse/state | bit 0 `start`, bit 1 `stop`, bit 2 `clear`, bit 3 `pause` |
| `0x0004` | `MODE` | RW | `0=PRELOAD`, `1=STREAM`, `2=LOOP` |
| `0x0008` | `STATUS` | RO | running, done, late, underrun, raw link, and effective TX gate |
| `0x0010` | `DESC_BASE_LO` | RW | Descriptor base low word |
| `0x0014` | `DESC_BASE_HI` | RW | Descriptor base high word |
| `0x0018` | `DATA_BASE_LO` | RW | Payload base low word |
| `0x001c` | `DATA_BASE_HI` | RW | Payload base high word |
| `0x0020` | `TRACE_LO` | RW | Trace byte count low word |
| `0x0024` | `TRACE_HI` | RW | Trace byte count high word |
| `0x0028` | `PKT_LO` | RW | Packet count low word |
| `0x002c` | `PKT_HI` | RW | Packet count high word |
| `0x0030` | `LOOP_LO` | RW | Loop count low word; zero means unbounded where supported |
| `0x0034` | `LOOP_HI` | RW | Loop count high word |
| `0x0038` | `LOOP_GAP_LO` | RW | Gap between iterations, low word |
| `0x003c` | `LOOP_GAP_HI` | RW | Gap between iterations, high word |
| `0x0040` | `START_LO` | RW | Start target low word |
| `0x0044` | `START_HI` | RW | Start target high word |
| `0x0048` | `RATE` | RW | Q16.16 rate field; descriptor ticks are the current timing authority |
| `0x004c` | `WATERMARK` | RW | STREAM prefetch watermark |
| `0x0050` | `FIFO_LEVEL` | RO | Internal source FIFO level |
| `0x0054` | `DEBUG_CTRL` | RW | bit 0 force link, bit 1 force TX ready, bit 2 best-effort auto-drop |
| `0x0060` | `TX_PKTS_LO` | RO | TX packet count low word |
| `0x0064` | `TX_PKTS_HI` | RO | TX packet count high word |
| `0x0068` | `TX_BYTES_LO` | RO | TX frame-byte count low word |
| `0x006c` | `TX_BYTES_HI` | RO | TX frame-byte count high word |
| `0x0070` | `LATE_LO` | RO | Late packet count low word |
| `0x0074` | `LATE_HI` | RO | Late packet count high word |
| `0x0078` | `UNDERRUN_LO` | RO | Payload underrun count low word |
| `0x007c` | `UNDERRUN_HI` | RO | Payload underrun count high word |
| `0x0080` | `DEBUG_STATUS` | RO | Replay-source, scheduler, and TX ready state |
| `0x0084` | `DEBUG_AXI` | RO | AXI read-channel state |
| `0x0088` | `DEBUG_AR_LO` | RO | Last/active AXI read address low word |
| `0x008c` | `DEBUG_AR_HI` | RO | Last/active AXI read address high word |
| `0x0090` | `DEBUG_RDATA` | RO | Low word of observed AXI read data |
| `0x0094` | `DEBUG_TICK_LO` | RO | Replay-relative tick low word |
| `0x0098` | `DEBUG_TICK_HI` | RO | Replay-relative tick high word |
| `0x00a0` | `STREAM_WR_LO` | RW | Host-committed stream bytes low word |
| `0x00a4` | `STREAM_WR_HI` | RW | Host-committed stream bytes high word |
| `0x00a8` | `STREAM_RD_LO` | RO | FPGA-consumed stream bytes low word |
| `0x00ac` | `STREAM_RD_HI` | RO | FPGA-consumed stream bytes high word |
| `0x00b0` | `STREAM_RING_LO` | RW | STREAM ring size low word |
| `0x00b4` | `STREAM_RING_HI` | RW | STREAM ring size high word |
| `0x00b8` | `STREAM_CTRL` | RW | bit 0 signals STREAM EOF |
| `0x00bc` | `STREAM_STATUS` | RO | STREAM reader state and error bits |
| `0x00c0` | `STREAM_LEVEL_LO` | RO | Available committed stream bytes low word |
| `0x00c4` | `STREAM_LEVEL_HI` | RO | Available committed stream bytes high word |
| `0x00c8` | `DROP_PKTS_LO` | RO | Best-effort dropped packets low word |
| `0x00cc` | `DROP_PKTS_HI` | RO | Best-effort dropped packets high word |
| `0x00d0` | `DROP_BEATS_LO` | RO | Best-effort dropped AXI beats low word |
| `0x00d4` | `DROP_BEATS_HI` | RO | Best-effort dropped AXI beats high word |
| `0x00d8` | `STALL_EVT_LO` | RO | Long downstream stall events low word |
| `0x00dc` | `STALL_EVT_HI` | RO | Long downstream stall events high word |
| `0x00e0` | `SCHED_CTRL` | RW | bit 0 shared timebase; bit 1 CMAC-domain egress scheduling |
| `0x00e4` | `GLOBAL_TICK_LO` | RO | Shared free-running FPGA tick low word |
| `0x00e8` | `GLOBAL_TICK_HI` | RO | Shared free-running FPGA tick high word |
| `0x00ec` | `SCHED_STATUS` | RO | bit 0 sync enabled, bit 1 future start armed, bit 2 egress enabled |

`DEBUG_CTRL[0]` and `[1]` are bring-up overrides.  They must remain clear for
reported physical throughput and precision tests.  `DEBUG_CTRL[2]` prevents a
permanent hang when the downstream path remains blocked: the core records the
drop and stall instead of waiting forever.  A lossless result still requires
all drop, stall, late, and underrun counters to remain zero.

## RX Register Map

| Offset | Register | Access | Description |
| ---: | --- | :---: | --- |
| `0x0000` | `CONTROL` | RW | bit 0 enable, bit 1 clear pulse, bit 2 DDR sample capture |
| `0x0004` | `STATUS` | RO | Link, FIFO, writer state, and overflow status |
| `0x0010` | `RING_BASE_LO` | RW | DDR sample ring base low word |
| `0x0014` | `RING_BASE_HI` | RW | DDR sample ring base high word |
| `0x0018` | `RING_SIZE` | RW | DDR sample ring bytes |
| `0x001c` | `TRUNC_BYTES` | RW | Maximum captured bytes per packet |
| `0x0020` | `WRITE_PTR` | RW/RO | Current DDR sample write pointer |
| `0x0030` | `RX_PKTS_LO` | RO | RX packet count low word |
| `0x0034` | `RX_PKTS_HI` | RO | RX packet count high word |
| `0x0038` | `RX_BYTES_LO` | RO | RX byte count low word |
| `0x003c` | `RX_BYTES_HI` | RO | RX byte count high word |
| `0x0040` | `RX_ERRS_LO` | RO | RX error count low word |
| `0x0044` | `RX_ERRS_HI` | RO | RX error count high word |
| `0x0048` | `CAP_BYTES_LO` | RO | Captured sample bytes low word |
| `0x004c` | `CAP_BYTES_HI` | RO | Captured sample bytes high word |
| `0x0050` | `AXI_WR_LO` | RO | DDR sample writes low word |
| `0x0054` | `AXI_WR_HI` | RO | DDR sample writes high word |
| `0x0058` | `AXI_ERR_LO` | RO | DDR sample AXI errors low word |
| `0x005c` | `AXI_ERR_HI` | RO | DDR sample AXI errors high word |
| `0x0060` | `DEBUG` | RO | Capture writer and FIFO state |
| `0x0064` | `GAP_COUNT_LO` | RO | Measured SOP intervals low word |
| `0x0068` | `GAP_COUNT_HI` | RO | Measured SOP intervals high word |
| `0x006c` | `GAP_SUM_LO` | RO | Sum of interval cycles low word |
| `0x0070` | `GAP_SUM_HI` | RO | Sum of interval cycles high word |
| `0x0074` | `GAP_MIN_LO` | RO | Minimum interval low word |
| `0x0078` | `GAP_MIN_HI` | RO | Minimum interval high word |
| `0x007c` | `GAP_MAX_LO` | RO | Maximum interval low word |
| `0x0080` | `GAP_MAX_HI` | RO | Maximum interval high word |
| `0x0084` | `GAP_LAST_LO` | RO | Latest interval low word |
| `0x0088` | `GAP_LAST_HI` | RO | Latest interval high word |
| `0x008c` | `RX_TICK_LO` | RO | RX-domain tick low word |
| `0x0090` | `RX_TICK_HI` | RO | RX-domain tick high word |
| `0x0094` | `GAP_SAMPLE_INDEX` | RW | Legacy 4096-entry sample selector |
| `0x0098` | `GAP_SAMPLE_COUNT` | RO | Legacy retained sample count |
| `0x009c` | `GAP_SAMPLE_LO` | RO | Selected legacy sample low word |
| `0x00a0` | `GAP_SAMPLE_HI` | RO | Selected legacy sample high word |
| `0x00a4` | `GAP_SAMPLE_WRITE_INDEX` | RO | Legacy next-write index |
| `0x00a8` | `EVENT_INDEX` | RW | High-capacity interval event selector |
| `0x00ac` | `EVENT_COUNT_LO` | RO | Retained event count low word |
| `0x00b0` | `EVENT_COUNT_HI` | RO | Retained event count high word |
| `0x00b4` | `EVENT_DATA_LO` | RO | Selected event low word |
| `0x00b8` | `EVENT_DATA_HI` | RO | Selected event high word |
| `0x00bc` | `EVENT_WRITE_INDEX` | RO | Next event write index |
| `0x00c0` | `EVENT_DROP_LO` | RO | Dropped measurement events low word |
| `0x00c4` | `EVENT_DROP_HI` | RO | Dropped measurement events high word |
| `0x00c8` | `EVENT_CAPACITY` | RO | Current capacity, `524288` intervals |
| `0x00cc` | `HIST_INDEX` | RW | Selects one of 16 logarithmic bins |
| `0x00d0` | `HIST_COUNT_LO` | RO | Selected bin count low word |
| `0x00d4` | `HIST_COUNT_HI` | RO | Selected bin count high word |
| `0x00d8` | `RX_CAPABILITIES` | RO | Aggregate/event/histogram capability bits |

The legacy sample window remains for compatibility.  The UltraRAM event ring is
the release measurement path.  It packs eight 64-bit intervals into each
512-bit word and stores up to `524288` intervals per port.

## Scheduling Semantics

The host converts pcap timestamps into descriptor gaps before loading the FPGA.
Conversion uses cumulative absolute rounding so sub-tick rounding does not
accumulate into long-trace drift.

The scheduler accumulates gaps into absolute packet targets.  On every `START`
or `CLEAR`, local replay time and per-trace target state reset.  Long FPGA uptime
therefore cannot make a newly loaded trace appear late.

When `SCHED_CTRL[0]=0`, target ticks use the local replay counter.  When it is
set, both TX cores observe the same Gray-coded global timebase.  Software writes
the same future `START` tick to both ports and then arms them independently.

When `SCHED_CTRL[1]=1`, packet data may cross into the CMAC TX domain before it
is due.  The LBUS adapter holds the first beat until the target tick, then emits
the complete frame without inserting scheduler bubbles inside the frame.

## DDR Prefetch Architecture

`ddr_trace_reader` separates descriptor and payload activity:

1. Descriptor bursts fill a deep descriptor FIFO.
2. A scan pipeline validates packet order and creates payload plans.
3. Adjacent payload ranges are coalesced where legal.
4. Multiple AXI read commands remain outstanding.
5. Metadata and payload FIFOs absorb DDR latency and burst variation.
6. The scheduler sees complete packet metadata only after payload capacity has
   been reserved.

The two replay ports use different DDR controllers in the default dual-port
build.  This removes one shared DDR arbitration point from simultaneous replay.

## Capacity

One packet consumes:

```text
trace_bytes_per_packet = 64 + align64(frame_len)
```

The default dual-port build allocates one `16 GiB` TX bank per port.  A
single-port multi-DDR build can expose a larger logical trace window.  Exact
capacity depends on frame-size distribution because every packet has one fixed
descriptor and one aligned payload.

## Host Commands

Prepare and replay one trace:

```bash
tick-replay prepare /data/input.pcap --out-dir /var/tmp/tick-trace

sudo tick-replay load \
  --port 0 \
  --mode preload \
  --manifest /var/tmp/tick-trace/manifest.json
```

Repeat the same trace:

```bash
sudo tick-replay load \
  --port 0 \
  --mode loop \
  --loop-count 1000 \
  --loop-gap 300000 \
  --manifest /var/tmp/tick-trace/manifest.json
```

Synchronized dual-port replay:

```bash
sudo tick-replay load --port 0 --mode preload \
  --manifest /var/tmp/trace0/manifest.json --arm-only
sudo tick-replay load --port 1 --mode preload \
  --manifest /var/tmp/trace1/manifest.json --arm-only
sudo tick-replay sync-start --ports 0,1 --delay-ms 100 --egress-schedule
```

## Precision Validation

The RX core measures consecutive receive SOP timestamps.  Host software
compares the measured interval with the descriptor interval:

```text
error_ns[i] = measured_rx_gap_ns[i] - requested_descriptor_gap_ns[i]
```

Run the end-to-end optical-loopback suite:

```bash
sudo tick-replay verify precision \
  --tx-port 0 \
  --rx-port 1 \
  --work-dir /var/tmp/tick-precision \
  --report /var/tmp/tick-precision/report.md
```

The testbench `tb_rx_capture_core_clear.sv` verifies counters, interval events,
legacy samples, and clear behavior.  The high-rate case drives `100000`
consecutive 64-byte packets at one SOP per RX cycle and requires zero event
drops.

## Release Validation

A PRELOAD/LOOP release must pass all of the following:

- Routed timing with non-negative `WNS` and `WHS`, and zero `TNS`/`THS`.
- H2C write and C2H readback at the low and high end of all enabled DDR banks.
- Stop, clear, reload, and restart without reprogramming the bitstream.
- Small, large, and mixed packet replay with correct packet and byte counts.
- Dual-port simultaneous replay and synchronized first-packet release.
- Optical payload comparison through the opposite RX port.
- RX interval-event comparison with the original descriptor sequence.
- Gap-zero and over-rate robustness without a permanent stall.
- Long-duration LOOP stress without unexplained drops, late packets, or errors.

Use the unified profiles for repeatable logs:

```bash
sudo tick-replay validate --profile smoke
sudo tick-replay validate --profile stress
sudo tick-replay validate --profile long
```

Final timing, utilization, checksums, and board results are stored with each
important bitstream under `bitstreams/`.
