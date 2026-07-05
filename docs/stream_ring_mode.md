# DDR Ring STREAM Mode

`STREAM` ring mode is the large-trace replay path.  It keeps only a moving
window of the replay stream in FPGA `DDR4`, while host software continuously
refills that window from host storage and memory.

## Data Flow

```text
host SSD / large stream file
  -> host memory batch of complete stream records
  -> XDMA H2C pwrite into FPGA DDR ring
  -> host advances STREAM_WR_PTR
  -> FPGA ddr_stream_reader reads committed records
  -> FPGA advances STREAM_RD_PTR
  -> host_stream_parser
  -> replay scheduler
  -> TX engine
  -> CMAC TX
```

The stream record format is unchanged:

```text
64-byte header
64-byte-aligned packet payload
```

The header carries `gap_ticks`, `frame_len`, and `flags`.  The scheduler still
uses `gap_ticks`, so replay timing remains FPGA-driven after records enter the
parser.

## Pointer Ownership

The DDR ring is controlled with monotonic byte counters:

| Pointer | Owner | Meaning |
| --- | --- | --- |
| `STREAM_WR_PTR` | Host | Total committed bytes written into the ring. |
| `STREAM_RD_PTR` | FPGA | Total bytes consumed by `ddr_stream_reader`. |

The actual DDR address is:

```text
ring_address = ring_base + (pointer % ring_size)
```

Host software must write complete stream records first, then update
`STREAM_WR_PTR`.  The FPGA never reads beyond `STREAM_WR_PTR`.  If the ring is
empty and EOF is not set, the FPGA reader waits.  When the host reaches the end
of the stream, it writes the final packet count and sets `STREAM_CTRL[0]`.

## Overwrite Protection

Before writing more data, host software computes:

```text
level = STREAM_WR_PTR - STREAM_RD_PTR
free  = ring_size - level - guard_bytes
```

It writes a batch only if `free` is large enough for the complete records in that
batch.  The FPGA also reports an overrun flag if `level > ring_size`, which means
host software advanced the producer pointer too far and may have overwritten
unread data.

## Current Implementation

Implemented pieces:

* `ddr_stream_reader` supports the dynamic DDR ring path used by `STREAM` mode.
* `axi_lite_regs` exposes ring size, write pointer, read pointer, level, EOF,
  and stream status.
* `trace_replay_core` feeds the existing stream parser from the DDR stream FIFO.
  The current experimental build uses an 8192-beat XPM block-RAM prefetch FIFO
  for large STREAM FIFOs.
* `xdma_stream_ring.py` is the host loader for dynamic refill.  It commits only
  complete records and polls the FPGA read pointer before writing more.
* `xdma_stream_ring_fast.cpp` is the higher-throughput C++ loader.  It uses a
  producer/consumer pipeline, large record-aligned batches, and fewer copies
  before issuing memory-mapped `XDMA H2C` writes.  It can also grow the
  producer queue with `--host-cache-bytes auto`, using host DRAM as an SSD read
  cache before the FPGA DDR ring.
* `traffic_replay_cli.py status/regs` prints stream ring state.
* `tb_ddr_stream_reader_ring.sv` verifies wait-empty, wrap, invalid ring size,
  pointer error, and overrun handling.
* `tb_trace_replay_core.sv` verifies that invalid ring configuration exits
  cleanly, then checks that the FPGA emits one committed packet, waits for the
  host write pointer to advance, and resumes.

Validation currently completed:

```text
PASS: invalid DDR ring-stream configuration stops cleanly without emitting data
PASS: DDR ring-stream replay waited for host write pointer and emitted 2 packets
PASS: DDR preload replay emitted 3 packets
```

Current U200 hardware observations with
`20260628_140628_stream_fast_bram_fifo8192_experimental`:

* `XDMA H2C/C2H` DDR readback passed.
* `STREAM` ring smoke passed with `1000` 1518-byte packets, `late=0`,
  `underrun=0`.
* Synthetic `pcap -> trace -> stream -> ring replay` passed with `10000`
  packets and `underrun=0`.
* C++ ring feeder no-late/no-underrun point for 1518-byte packets is currently
  about `7.59Gbps`.
* The old finite-buffer `STREAM` path has been removed; new `STREAM` throughput
  tests should use `stream_stress_test.py` with the ring loader.

## Host DRAM Cache

The ring feeder has two windows:

```text
host SSD -> host DRAM producer queue -> XDMA H2C -> FPGA DDR ring
```

`--queue-depth` controls how many record-aligned chunks may sit in host memory.
`--host-cache-bytes auto` expands that queue to a fraction of Linux
`MemAvailable`:

```bash
cd /home/user/traffic_replay_software
make xdma_stream_ring_fast

sudo ./xdma_stream_ring_fast \
  --manifest /home/user/trace_out/stream_manifest.json \
  --port 0 \
  --ring-base 0x20000000 \
  --ring-size 0x08000000 \
  --read-bytes 0x04000000 \
  --batch-bytes 0x04000000 \
  --host-cache-bytes auto \
  --host-cache-fraction 0.85
```

This improves robustness when SSD service time jitters, and it allows the host
to stage a much larger part of the trace in DRAM while the FPGA consumes the DDR
ring.  It does not change replay precision: packet timing is still controlled by
the FPGA scheduler after records enter the ring.  It also does not remove the
memory-mapped `XDMA H2C pwrite` ceiling; sustained `100Gbps` dynamic replay still
requires the full end-to-end stream byte rate to fit through SSD, host memory,
PCIe, FPGA DDR write, and FPGA DDR read.

## Timing Precision

Packet timing is still determined inside the FPGA scheduler.  Host refill timing
does not directly schedule packets; it only determines whether enough future
records are available in the ring.  Therefore:

* If the ring stays ahead of the scheduler, inter-packet timing precision is the
  same as normal FPGA replay.
* If the ring runs empty, the scheduler cannot receive the next record on time;
  the design reports late/underrun behavior.

For precision tests, the important metric is not only TX packet count but also:

```text
STREAM_LEVEL never reaches 0 during active replay
late_packets remains 0 for the target timestamp profile
underrun_packets remains 0
TX packet/byte counters match the input stream
RX loopback packet/byte counters match TX
```

## 100G Feasibility

Ring mode solves trace capacity, but sustained `100Gbps` replay depends on three
bandwidths at the same time:

| Resource | Requirement for sustained replay |
| --- | --- |
| `CMAC` | Must transmit at the target wire rate. |
| `PCIe XDMA H2C` | Must refill stream bytes at least as fast as the FPGA consumes them. |
| `DDR4` | Must handle host writes and FPGA reads concurrently. |

The stream format has per-packet overhead because every packet has a 64-byte
header and 64-byte payload alignment.  Approximate stream bandwidth needed for
`100Gbps` TX payload replay is:

```text
stream_rate ~= tx_payload_rate * (64 + align(frame_len, 64)) / frame_len
```

Examples:

| Frame bytes | Stream bytes per packet | H2C stream rate for 100Gbps TX | DDR read+write traffic |
| ---: | ---: | ---: | ---: |
| 64 | 128 | ~200Gbps | ~400Gbps |
| 512 | 576 | ~112.5Gbps | ~225Gbps |
| 1518 | 1600 | ~105.4Gbps | ~210.8Gbps |

So sustained dynamic streaming at `100Gbps` is difficult with the current
memory-mapped `XDMA -> DDR -> reader -> CMAC` architecture, especially for small
packets.

Current U200 measurements from the 2026-07-05 single-port stream-boost build:

| Case | Result |
| --- | ---: |
| `1518B`, `gap=38`, `1M` packets, full DDR prefill | `95.874Gbps`, no late/underrun/drop |
| `1518B`, `gap=38`, `5M` packets, `12GB` ring/full prefill | `95.874Gbps`, no late/underrun/drop |
| `1518B`, `gap=36`, `1M` packets, forced-ready internal TX | `101.200Gbps`, no late/underrun/drop |
| `1518B`, `gap=38`, `5M` packets, `8GB` ring/dynamic refill | `55.306Gbps` average, late/underrun after ring drains |
| dual-SSD striped dry-run, `64GB` stream, cold cache | `24.102Gbps` read/reorder |
| dual-SSD + memory-mapped `XDMA H2C pwrite()`, `64GB` dynamic stream | `22.190Gbps` FPGA load, `22.770Gbps` scheduled L2 replay, no late/underrun |

The FPGA replay path can therefore hit the large-packet scheduler target when
the ring is fully prefetched.  The remaining sustained dynamic bottleneck is the
host-to-FPGA refill path.

The most realistic path toward sustained 100G is:

* Use large packets or payload-dense traces first.
* Increase DDR stream-reader throughput with larger bursts, deeper FIFOs, and
  multiple outstanding reads.
* Spread traffic across more DDR banks or use HBM on a different card.
* Consider true `QDMA`/`XDMA` AXI4-Stream H2C direct-to-replay for host streaming
  so the same bytes are not written to DDR and then read back before TX.
* Reduce stream metadata overhead for small packets, for example by packing
  several small packet descriptors into one metadata beat.

The next hardware step is to replace or bypass the memory-mapped `pwrite` feeder
when the goal is sustained dynamic `100Gbps`.  The current measurement set to
track is:

```text
H2C refill throughput
STREAM_LEVEL minimum
late/underrun counters
TX throughput
RX loopback counters
```
