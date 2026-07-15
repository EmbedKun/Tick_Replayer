<div align="center">

# Tick Replayer

**A DDR-backed, tick-scheduled 100G FPGA traffic replay and measurement system.**

`Alveo U200` | `Dual 100G CMAC` | `PCIe XDMA` | `4 x DDR4` | `PCAP Replay`

[中文文档](README_CN.md)

</div>

Tick Replayer converts a classic `pcap` trace on a Linux host, loads packet
descriptors and payloads through PCIe, and replays the packets from FPGA DDR at
hardware-controlled intervals.  Both U200 QSFP ports have independent TX
replay and RX measurement paths, so one FPGA can represent both sides of a
bidirectional traffic experiment.

The name comes from the hardware timing contract: host software converts pcap
timestamps into integer `gap_ticks`, and the FPGA schedules packet starts from
those ticks.  At the default `300 MHz` replay clock, one tick is approximately
`3.333 ns`.

> **Release status:** the latest archived and board-validated release candidate
> is [`20260715_0754_rc5_4ddr_dual_timing_clean`](bitstreams/20260715_0754_rc5_4ddr_dual_timing_clean).
> It is a dual-port, four-DDR-bank U200 build with routed `300 MHz` timing
> closure, unified `tick-replay` host control, RX interval measurement, and
> validated PRELOAD, LOOP, STREAM, dual-port, and optical-loopback tests.

## Contents

- [Capabilities](#capabilities)
- [Measured Baseline](#measured-baseline)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Replay Modes](#replay-modes)
- [Scheduling And Precision](#scheduling-and-precision)
- [Capacity And Addressing](#capacity-and-addressing)
- [Trace Format](#trace-format)
- [Control Plane](#control-plane)
- [RTL Modules](#rtl-modules)
- [Host Software](#host-software)
- [Build And Program](#build-and-program)
- [Validation](#validation)
- [Repository Layout](#repository-layout)
- [Limitations](#limitations)

## Capabilities

| Area | Current design |
| --- | --- |
| FPGA | Xilinx Alveo U200, `xcu200-fsgd2104-2-e` |
| Ethernet | Two Xilinx 100G CMACs connected to `QSFP0` and `QSFP1` |
| PCIe | Gen3 x16 XDMA endpoint, memory-mapped `H2C`/`C2H` plus AXI-Lite user BAR |
| FPGA memory | Four independent `16 GiB` DDR4 banks, `64 GiB` physical address space |
| Replay modes | `PRELOAD`, `LOOP`, and bounded `STREAM` ring |
| TX timing | Per-packet descriptor gaps, shared absolute timebase, optional CMAC-domain SOP release |
| RX measurement | Packet/byte/error counters, payload sample ring, aggregate gap statistics, histogram, and per-gap event ring |
| Host interface | Unified Linux command `tick-replay` plus reusable Python and C++ tools |
| Robustness | Explicit stop/clear/restart, ring overrun protection, late/underrun/drop/stall counters |

The current archived release build exposes one XDMA H2C channel
(`/dev/xdma0_h2c_0`).  `1`, `2`, and `4` engine builds remain selectable
through `TRAFFIC_REPLAY_H2C_CHANNELS`; the release configuration favors routed
timing closure and deterministic validation over experimental channel count.

## Measured Baseline

These are board measurements from the latest archived timing-clean baseline,
not estimates from RTL simulation.

| Test | Board result |
| --- | ---: |
| Single-port `1518 B`, `gap=38`, `PRELOAD` | `95.873 Gbps` L2, `97.389 Gbps` wire |
| Single-port `64 B`, `gap=3`, `PRELOAD` | `51.200 Gbps` L2, `70.400 Gbps` wire |
| Mixed `64:3,1518:38`, `PRELOAD` | `92.604 Gbps` L2, `95.414 Gbps` wire |
| Dual-port `1518 B`, `gap=38`, `PRELOAD` | `191.746 Gbps` aggregate L2, `194.778 Gbps` aggregate wire |
| Dual-port `64 B`, `gap=3`, `PRELOAD` | `102.399 Gbps` aggregate L2, `140.798 Gbps` aggregate wire |
| `LOOP`, `100` packets x `3` loops | `300` TX packets, no late/underrun/drop |
| `STREAM`, striped source, single DDR ring, `1518 B`, `gap=800` | `4.554 Gbps` L2, no late/underrun/drop |
| Two-SSD striped source dry-run | `41.828 Gbps` direct read, `43.586 Gbps` buffered read |
| XDMA H2C benchmark | `53.276 Gbps` single-bank two-thread, `70.150 Gbps` DDR0+DDR1 parallel |
| TX0 -> RX1 optical payload check | `256/256` samples matched, `0` RX errors |
| RX-side interval precision suite | all cases passed, worst case `85.043 ns` max absolute error |
| Routed timing | `WNS=+0.006 ns`, `WHS=+0.006 ns` |

For small packets, wire rate and pcap/L2 rate are different.  A `64 B` Ethernet
frame occupies `88 B` of line time when FCS, preamble/SFD, and IFG are included.
Therefore, a full `100 Gbps` wire corresponds to approximately `72.73 Gbps`
of `64 B` pcap frame data and `142.05 Mpps`.

Detailed board results for this release candidate are recorded in
[`docs/evaluation_20260715_rc5_board_validation.md`](docs/evaluation_20260715_rc5_board_validation.md).
Historical experiments and design-space notes are kept under [`docs/`](docs/).

## Quick Start

The repository and host software target Linux.  The commands below assume the
FPGA is programmed, the Xilinx XDMA driver has created `/dev/xdma0_*`, and the
QSFP link is connected.

### 1. Build And Install The Host Tools

```bash
make -C software
sudo make -C software install
tick-replay --version
```

### 2. Convert A PCAP

```bash
tick-replay prepare /data/input.pcap \
  --out-dir /var/tmp/tick-trace \
  --tick-hz 300000000
```

The output directory contains `desc.bin`, `data.bin`, and `manifest.json`.

### 3. PRELOAD Replay

```bash
sudo tick-replay load \
  --port 0 \
  --mode preload \
  --manifest /var/tmp/tick-trace/manifest.json

sudo tick-replay status --port 0
```

### 4. LOOP Replay

```bash
sudo tick-replay load \
  --port 0 \
  --mode loop \
  --loop-count 100 \
  --loop-gap 300000 \
  --manifest /var/tmp/tick-trace/manifest.json
```

At `300 MHz`, `300000` loop-gap ticks are `1 ms`.

### 5. STREAM Ring Replay

Convert the descriptor/data trace into complete stream records:

```bash
python3 software/trace_to_stream.py \
  --manifest /var/tmp/tick-trace/manifest.json \
  --out /var/tmp/tick-trace/stream.bin
```

Run the high-performance bounded ring loader.  `--h2c auto` discovers every
available H2C engine and distributes ordered writes across them.

```bash
sudo tick-replay stream \
  --port 0 \
  --manifest /var/tmp/tick-trace/stream_manifest.json \
  --h2c auto \
  --ring-base 0x20000000 \
  --ring-size 0x08000000 \
  --prefill-bytes 0x04000000 \
  --writer-threads 4 \
  --queue-depth 128
```

For traces striped across multiple SSDs, create a record-aligned stripe
manifest with `software/stream_stripe.py` and pass it with
`--stripe-manifest` instead of `--manifest`.

The current dual-port release uses a bank-local replay path: port `0` reads
from `DDR0`, and port `1` reads from `DDR1`.  A port-0 multi-DDR `STREAM`
ping-pong ring is a separate single-port/high-stream build profile.

### 6. Synchronized Dual-Port Start

Load both ports without issuing `START`, then arm them for the same absolute
FPGA tick:

```bash
sudo tick-replay load --port 0 --mode preload \
  --manifest /var/tmp/trace0/manifest.json --arm-only

sudo tick-replay load --port 1 --mode preload \
  --manifest /var/tmp/trace1/manifest.json --arm-only

sudo tick-replay sync-start \
  --ports 0,1 \
  --delay-ms 100 \
  --egress-schedule
```

### 7. Observe And Reset

```bash
sudo tick-replay status --port all
sudo tick-replay rx --port 1 status
sudo tick-replay rx --port 1 events --limit 64

sudo tick-replay stop --port 0
sudo tick-replay clear --port 0
```

`force_link_up` and `force_tx_ready` are debug-only controls.  Do not use them
for reported throughput, packet-integrity, or precision results.

## Architecture

![Tick Replayer architecture](docs/images/replay_arch.png)

Block diagram abbreviations: `APP`, host trace preparation and control
application; `XDMA`, Xilinx PCIe DMA endpoint; `AXIL M`, AXI-Lite control
master; `AXI M`, memory-mapped AXI DMA master; `H2C`, host-to-card DMA; `C2H`,
card-to-host DMA; `DDR4`, external descriptor, payload, stream, and RX sample
storage; `TX DESC`, transmit descriptors; `TX DATA`, transmit payloads;
`RX SAMPLE`, truncated receive samples; `CMAC`, 100G Ethernet media access
controller; `QSFP`, optical port.

### Host-To-TX Data Path

```text
pcap
  -> tick-replay prepare
  -> descriptor/payload or stream records
  -> XDMA H2C
  -> DDR4
  -> descriptor and payload prefetch
  -> tick scheduler
  -> scheduled async FIFO
  -> CMAC-clock egress scheduler
  -> AXI-Stream to LBUS adapter
  -> 100G CMAC
  -> QSFP
```

### RX Measurement Path

```text
QSFP
  -> 100G CMAC RX LBUS
  -> LBUS packet reconstruction
  -> packet/byte/error counters
  -> SOP interval pipeline
  -> aggregate statistics + histogram + on-chip event ring
  -> optional truncated DDR sample writer
  -> AXI-Lite status or C2H DDR readback
```

### Clock Domains

| Domain | Nominal frequency | Main logic |
| --- | ---: | --- |
| DDR/replay | `300 MHz` | DDR readers, trace parser, replay scheduler, shared timebase |
| XDMA AXI | `250 MHz` | PCIe DMA and AXI interconnect ingress |
| CMAC TX/RX | approximately `322 MHz` | LBUS adapters, final SOP gate, RX interval measurement |
| CMAC init | `100 MHz` | reset and initialization control |

Clock-domain crossings use AXI clock converters, XPM asynchronous FIFOs, or
Gray-coded counters.  Packet target ticks travel with the packet through the TX
asynchronous FIFO, so final SOP release occurs in the CMAC TX clock domain.

## Replay Modes

### PRELOAD

The host loads the complete descriptor and payload regions before `START`.
During replay, the host is not in the TX data path.  This mode provides the
highest throughput, the most repeatable timing, and the simplest correctness
model.  Its trace size is limited by the DDR region assigned to the replay port.

### LOOP

`LOOP` reuses a PRELOAD trace for a configured number of iterations, with an
optional hardware loop gap.  It is intended for long-running DUT stress tests
without repeated PCIe loading.

### STREAM Ring

`STREAM` treats FPGA DDR as a bounded producer/consumer ring.  The host commits
only complete packet records and advances a monotonic write counter after DMA
completion.  The FPGA advances its read counter as records are consumed.  A
guard region prevents the producer from overwriting unread data.

The scheduler still owns packet timing.  If the host/SSD/PCIe path falls behind,
the replay core records an underrun or late packet instead of silently changing
the requested timestamps.

## Scheduling And Precision

Each descriptor carries a gap in replay ticks.  The scheduler accumulates those
gaps into absolute targets.  Host timestamp conversion uses cumulative absolute
rounding, which prevents per-packet rounding errors from accumulating into
long-trace drift.

Two timing modes are available:

1. Local replay time resets on every `START` or `CLEAR`.
2. Synchronized time uses a shared 64-bit FPGA counter and an absolute start
   tick, allowing both replay ports to arm independently and begin together.

With egress scheduling enabled, a packet can be prefetched through DDR and the
CDC FIFO before it is due.  The CMAC-domain adapter holds only the packet SOP
until the target time.  This separates memory latency from the final release
decision and preserves payload continuity once a frame starts.

RX precision validation measures consecutive receive SOP timestamps:

```text
rx_gap_cycles = current_sop_tick - previous_sop_tick
error_ns      = measured_gap_ns - requested_gap_ns
```

The RX core maintains aggregate count/sum/min/max values, a 16-bin logarithmic
histogram, and a `524288`-entry per-port interval event ring.  Eight 64-bit
intervals are packed into each 512-bit UltraRAM word.  This avoids the old
small-window limitation while keeping measurement in the full-rate RX domain.

## Capacity And Addressing

The U200 exposes four `16 GiB` DDR windows:

| Bank | Base address | Default dual-port ownership |
| --- | ---: | --- |
| `DDR0` | `0x0000000000` | TX0 descriptors, payloads, or STREAM ring |
| `DDR1` | `0x0400000000` | TX1 descriptors, payloads, or STREAM ring |
| `DDR2` | `0x0800000000` | RX0 sample storage |
| `DDR3` | `0x0c00000000` | RX1 sample storage |

The host XDMA master can access all four windows.  The default dual-port data
plane keeps replay and capture traffic bank-local to reduce SmartConnect
contention and make simultaneous high-rate operation predictable.

### PRELOAD Capacity

Each packet consumes one `64 B` descriptor plus a `64 B`-aligned payload:

```text
trace_bytes_per_packet = 64 + align64(frame_len)
```

Approximate capacity for one `16 GiB` replay bank:

| Frame length | Stored bytes/packet | Packet capacity | Approx. source frame bytes |
| ---: | ---: | ---: | ---: |
| `64 B` | `128 B` | `134,217,728` | `8.00 GiB` |
| `512 B` | `576 B` | `29,826,161` | `14.22 GiB` |
| `1518 B` | `1600 B` | `10,737,418` | `15.18 GiB` |
| `9000 B` | `9088 B` | `1,890,390` | `15.84 GiB` |

A single-port multi-DDR build can expose a larger replay window.  The default
dual-port release assigns one replay bank per port and reserves the remaining
banks for RX capture, so each port has an independent `16 GiB` PRELOAD region.

### STREAM Capacity

The complete trace does not need to fit in FPGA DDR.  Maximum replay length is
bounded by host storage and the ability of SSD, host memory, XDMA, and the DDR
ring loader to sustain the requested trace rate.  The FPGA ring is a cache, not
the capacity limit.

## Trace Format

`PRELOAD` and `LOOP` use:

- `desc.bin`: one fixed `64 B` descriptor per packet.
- `data.bin`: frame bytes padded to `64 B` AXI beats.
- `manifest.json`: filenames, packet count, byte count, and conversion metadata.

Each little-endian descriptor occupies one 512-bit beat:

| Byte offset | Field | Width | Meaning |
| ---: | --- | ---: | --- |
| `0x00` | `gap_ticks` | `64 bits` | Requested packet gap in replay-clock ticks |
| `0x08` | `data_word_offset` | `32 bits` | Payload offset from `DATA_BASE` in `64 B` words |
| `0x0c` | `frame_len` | `16 bits` | Ethernet frame bytes, excluding preamble and FCS |
| `0x0e` | `flags` | `16 bits` | Reserved per-packet controls |
| `0x10` | reserved | `48 B` | Written as zero |

STREAM records use the same `64 B` metadata header followed immediately by the
aligned payload.  The producer commits only complete records to the ring.

## Control Plane

XDMA exposes an AXI-Lite master through `/dev/xdma0_user`.  The BAR contains
four `64 KiB` application windows:

| BAR offset | Window |
| ---: | --- |
| `0x00000` | TX0 replay control and statistics |
| `0x10000` | TX1 replay control and statistics |
| `0x20000` | RX0 measurement and capture |
| `0x30000` | RX1 measurement and capture |

Important TX register groups include mode and lifecycle control, descriptor and
payload bases, packet/loop configuration, stream producer/consumer pointers,
debug policy, TX counters, shared-time synchronization, and egress scheduling.
Important RX groups include capture configuration, packet/byte/error counters,
gap aggregates, event-ring indexing, histogram bins, and overflow indicators.

The full register tables are documented in [`docs/preload.md`](docs/preload.md)
and implemented by [`rtl/axi_lite_regs.sv`](rtl/axi_lite_regs.sv) and
[`rtl/rx_capture_bd_core.sv`](rtl/rx_capture_bd_core.sv).

## RTL Modules

| Module | Responsibility |
| --- | --- |
| `traffic_replay_pkg.sv` | Shared widths, mode IDs, descriptor constants, and helper functions |
| `traffic_replay_bd_core.v` | Block-design wrapper for one TX replay interface |
| `trace_replay_core.sv` | Top-level replay state, source selection, scheduler, TX engine, and counters |
| `axi_lite_regs.sv` | TX control/status register file behind the XDMA user BAR |
| `ddr_trace_reader.sv` | Deep descriptor/payload prefetch for PRELOAD and LOOP |
| `ddr_stream_reader.sv` | Bounded DDR stream-ring reader with monotonic pointers |
| `host_stream_parser.sv` | STREAM record metadata and payload parser |
| `replay_scheduler.sv` | Gap accumulation, absolute targets, late detection, and synchronized scheduling |
| `replay_global_timebase.sv` | Shared 64-bit free-running FPGA timebase |
| `replay_time_sync.sv` | Gray-coded timebase CDC into replay and CMAC domains |
| `replay_tx_engine.sv` | Scheduled metadata/payload coupling and TX AXI-Stream generation |
| `axis_sync_fifo.sv` | Deep same-clock payload buffering |
| `scheduled_axis_async_fifo.sv` | Packet plus target-timestamp CDC into the CMAC TX domain |
| `axis_to_lbus_512.sv` | AXI-Stream to CMAC LBUS formatting and final SOP scheduling |
| `lbus_to_axis_512.sv` | CMAC RX LBUS packet reconstruction |
| `rx_capture_bd_core.sv` | Full-rate RX statistics, interval events, histogram, and sample writer |
| `traffic_replay_top_stub.sv` | Simulation-friendly wrapper around one replay core |

[`scripts/create_hw_project.tcl`](scripts/create_hw_project.tcl) is the system
integrator.  It instantiates XDMA, four DDR controllers, two CMACs,
SmartConnect/clock converters, two replay cores, two RX cores, and the CDC
adapters, then assigns BAR and DDR address spaces.

## Host Software

`tick-replay` is the supported operator interface:

| Command | Purpose |
| --- | --- |
| `prepare` | Convert a classic pcap into FPGA descriptor and payload files |
| `load` | Load and configure PRELOAD or LOOP replay |
| `stream` | Run the parallel C++ STREAM ring backend |
| `status` | Display both TX and RX state and counters |
| `start`, `stop`, `clear`, `pause`, `resume` | Replay lifecycle control |
| `sync-start` | Arm selected ports for one shared absolute FPGA tick |
| `rx` | Control RX capture and read interval events/histograms |
| `verify` | Run DDR, optical-loopback, or precision checks |
| `benchmark` | Run host-to-FPGA H2C benchmarks |
| `validate` | Execute an archived smoke, stress, or long validation profile |

The command wraps reusable tools under [`software/`](software/).  The STREAM
backend is implemented in C++ with large batched writes, asynchronous SSD
readers, multiple producer workers, ordered completion, and automatic H2C
engine discovery.  Producer pointers are published only after all earlier byte
ranges have completed, preserving ring order even when DMA writes run in
parallel.

## Build And Program

Vivado builds target Linux with Xilinx Vivado `2020.2`.  Generated Vivado state
is intentionally excluded from Git; the checked-in Tcl recreates the project.

### Create A Release Bitstream

```bash
export XILINX_VIVADO=/tools/Xilinx/Vivado/2020.2
export TRAFFIC_REPLAY_PORT_COUNT=2
export TRAFFIC_REPLAY_DDR_BANKS=4
export TRAFFIC_REPLAY_H2C_CHANNELS=2
export TRAFFIC_REPLAY_VIVADO_THREADS=4
export TRAFFIC_REPLAY_VIVADO_JOBS=1

bash scripts/run_vivado.sh hwbit
```

Useful hardware build parameters:

| Variable | Values | Default |
| --- | --- | ---: |
| `TRAFFIC_REPLAY_PORT_COUNT` | `1`, `2` | `2` |
| `TRAFFIC_REPLAY_DDR_BANKS` | `1`, `2`, `4` | `4` |
| `TRAFFIC_REPLAY_H2C_CHANNELS` | `1`, `2`, `4` | `2` |
| `TRAFFIC_REPLAY_PORT0_MULTI_DDR` | `0`, `1` | auto for single-port builds |
| `TRAFFIC_REPLAY_IMPL_STRATEGY` | Vivado implementation strategy name | `Performance_ExplorePostRoutePhysOpt` |
| `TRAFFIC_REPLAY_INCREMENTAL_CHECKPOINT` | timing-clean routed DCP | unset |

Do not release or program a build solely because Vivado generated a `.bit`.
The routed report must have non-negative `WNS` and `WHS`, zero `TNS` and `THS`,
no route errors, and acceptable DRC results.

### Program The FPGA

```bash
bash scripts/run_vivado.sh program \
  bitstreams/<release>/traffic_replay_bd_wrapper.bit
```

After programming an image that changes the PCIe endpoint configuration,
perform the platform-appropriate PCIe rescan or reboot, reload the XDMA driver,
and verify the expected device nodes before accessing the BAR.

## Validation

The release-candidate gate, simulation evidence, and board test matrix are
recorded in
[`docs/evaluation_20260710_release_candidate.md`](docs/evaluation_20260710_release_candidate.md).

### Software Regression

```bash
python3 -m unittest discover -s software/tests -v
make -C software clean all
```

### DDR H2C/C2H Readback

```bash
sudo tick-replay verify ddr --repeat 2
```

The release profile checks both the low and high end of every `16 GiB` DDR
window.

### Optical Payload Loopback

```bash
sudo tick-replay verify loopback \
  --tx-port 0 --rx-port 1 \
  --packet-count 4096 \
  --frame-len 128 \
  --gap-ticks 2000
```

### RX-Side Precision

```bash
sudo tick-replay verify precision \
  --tx-port 0 --rx-port 1 \
  --work-dir /var/tmp/tick-precision \
  --report /var/tmp/tick-precision/report.md
```

### H2C Throughput

```bash
sudo tick-replay benchmark h2c \
  --h2c auto \
  --bytes 0x100000000 \
  --chunk-bytes 0x04000000 \
  --threads 2 \
  --passes 3
```

### Release Profiles

```bash
sudo tick-replay validate --profile smoke
sudo tick-replay validate --profile stress
sudo tick-replay validate --profile long
```

Each run writes the command lines, outputs, elapsed times, and CSV artifacts to
a timestamped validation directory.  A release is accepted only after DDR
readback, control-plane restart, PRELOAD/LOOP/STREAM, small/large/mixed packet
tests, optical payload verification, precision measurement, and robustness
tests complete without unexplained drops or stalls.

## Repository Layout

```text
constraints/   U200 PCIe, DDR, QSFP, and floorplan constraints
rtl/           replay, scheduling, CDC, CMAC adapters, and RX measurement RTL
sim/           self-checking RTL testbenches
scripts/       Vivado project generation, simulation, implementation, and programming Tcl
software/      Linux CLI, trace converters, loaders, benchmarks, and validation tools
docs/          architecture, register, mode, and evaluation notes
bitstreams/    immutable important bitstreams with reports, checksums, and release notes
```

## Limitations

- The current hardware uses XDMA memory-mapped H2C, not QDMA or an AXI4-Stream
  host ingress.  Dynamic STREAM throughput therefore depends strongly on host
  DMA submission, SSD reads, memory copies, and DDR arbitration.
- The current dual-port release assigns one `16 GiB` replay bank per TX port:
  port `0` reads `DDR0`, and port `1` reads `DDR1`.  Host XDMA can access all
  four banks, but port `0` cannot use `DDR1` as a STREAM ping-pong partner in
  this release profile.
- A single logical `64 GiB` PRELOAD trace or a high-rate port-0 multi-DDR
  STREAM ring requires a single-port/multi-DDR build profile and compatible
  host address layout.
- Four H2C engines and port-0 multi-DDR reads are supported as experimental
  build options.  They are not enabled in the archived 2026-07-15 dual-port
  release candidate because timing closure and dual-port isolation take
  priority for this profile.
- CMAC-domain egress scheduling is implemented and validated for controlled
  replay paths, but dynamic STREAM plus egress scheduling still needs a deeper
  pre-issue/output buffer before it is treated as a high-throughput release
  path.
- Full payload RX capture at 100G is intentionally not the default.  RX keeps
  counters, interval events, and selected truncated samples so measurement does
  not consume all PCIe and DDR bandwidth.
- Timing-clean implementation is seed, strategy, and floorplan sensitive on the
  three-SLR U200.  Every important bitstream is archived with its exact reports
  and checksum.
- Classic pcap is supported.  Pcapng and higher-level trace consistency editing
  are outside the FPGA replay subsystem.
