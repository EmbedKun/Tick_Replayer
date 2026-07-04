<div align="center">

# Tick Replayer

**DDR-backed 100G FPGA traffic replay engine with tick-based packet scheduling.**

`FPGA` / `100G Ethernet` / `PCIe XDMA` / `DDR4` / `CMAC` / `PCAP Replay`

[Chinese README](README_CN.md)

</div>

## Overview

`Tick Replayer` is an FPGA traffic replay prototype for the Xilinx Alveo U200.
The Linux host converts a `pcap` file into packet descriptors and payload data,
loads the trace into FPGA `DDR4` through `PCIe XDMA`, and controls replay through
an `AXI-Lite` register space.  The FPGA then transmits packets through 100G
`CMAC` ports according to per-packet timing gaps.

The name `Tick Replayer` comes from the timing unit used by the hardware.  A
pcap timestamp delta is converted into `gap_ticks`, and the replay scheduler
uses a replay-relative hardware tick counter to decide when each packet is
released.  The project is therefore organized around four practical questions:

- How large a trace can be replayed?
- How much replay throughput can the FPGA generate?
- How accurately does it preserve packet spacing?
- How do the host tools prepare, load, control, and validate a replay?

The current design is a dual-port prototype.  `QSFP0` and `QSFP1` each have an
independent transmit replay path and a lightweight receive statistics/capture
path.  A single FPGA can therefore transmit and receive on both high-speed
ports, which is the intended direction for emulating two sides of a bidirectional
traffic trace.

## Table Of Contents

- [Current Status](#current-status)
- [Architecture](#architecture)
- [Replay Capacity](#replay-capacity)
- [Replay Throughput](#replay-throughput)
- [Replay Precision](#replay-precision)
- [Host Software Tools](#host-software-tools)
- [Replay Modes](#replay-modes)
- [Trace Descriptor Format](#trace-descriptor-format)
- [Build And Program](#build-and-program)
- [Validation Commands](#validation-commands)
- [Repository Layout](#repository-layout)
- [Known Limitations](#known-limitations)
- [Roadmap](#roadmap)

## Current Status

| Area | Status |
| --- | --- |
| Target board | Xilinx Alveo U200 |
| PCIe | Xilinx `XDMA`, Gen3 x16, memory-mapped `H2C`/`C2H` |
| Ethernet | Dual 100G `CMAC` connected to `QSFP0` and `QSFP1` |
| Control plane | `XDMA` user `BAR` to `AXI-Lite` registers |
| Trace memory | Current build uses one U200 `DDR4` bank, address range `16GiB` |
| Replay modes | `PRELOAD`, `LOOP`, and `STREAM` ring buffer |
| RX path | Packet/byte/error counters, recent sample capture, SOP-to-SOP gap statistics |
| Timing archive | `bitstreams/20260704_rxgap_precision_stream_loader_timing_clean` reports `WNS=+0.024 ns` |
| Full 64GB DDR | Planned.  The current public build does not yet use all four U200 DDR banks |

## Architecture

![Tick Replayer architecture](docs/images/replay_arch.png)

Block diagram of the `Tick Replayer` FPGA traffic replay system.  `APP`:
host-side trace generation, `XDMA` loading, and replay control tools; `XDMA
Driver`: Xilinx DMA Linux driver exposing `H2C`, `C2H`, and user `BAR`
character devices; `PCIe XDMA IP`: Xilinx PCI Express DMA endpoint; `AXIL M`:
`AXI-Lite` master used by `XDMA` to access control/status registers; `AXI M`:
memory-mapped AXI master used for `H2C` and `C2H` DDR access; `SmartConnect`:
Xilinx AXI interconnect and arbitration fabric; `DDR4`: external packet
descriptor, payload, stream ring, and RX sample storage; `TX Replay Core`:
descriptor/payload prefetch, timestamp scheduling, and transmit packet
generation; `RX Capture Core`: receive counters, recent sample writer, and
SOP-to-SOP gap measurement; `CMAC`: Xilinx 100G Ethernet MAC; `QSFP`: optical
Ethernet port.

High-level `PRELOAD` data path:

```text
pcap
  -> pcap2trace.py
  -> desc.bin + data.bin + manifest.json
  -> xdma_load_trace.py
  -> /dev/xdma0_h2c_0
  -> FPGA DDR4
  -> ddr_trace_reader
  -> replay_scheduler
  -> replay_tx_engine
  -> AXI-Stream FIFO
  -> CMAC TX
  -> QSFP
```

High-level `STREAM` ring data path:

```text
large pcap / stream file on host storage
  -> host loader batches complete stream records
  -> /dev/xdma0_h2c_0
  -> FPGA DDR4 ring
  -> host advances STREAM_WR_PTR after full records are committed
  -> FPGA advances STREAM_RD_PTR as records are consumed
  -> host_stream_parser
  -> replay_scheduler
  -> CMAC TX
```

The receive path is intentionally lightweight.  It does not upload every packet
to the host by default.  Instead, it maintains counters, stores recent truncated
samples when enabled, and records receive-side packet-spacing statistics for
precision validation.

## Replay Capacity

Capacity depends on the replay mode.

### PRELOAD Capacity

`PRELOAD` mode requires the whole replay trace to fit in FPGA DDR before replay
starts.  The stored trace is not exactly the same size as the source `pcap`.
Each packet consumes:

```text
preload_trace_bytes_per_packet = 64 + align64(frame_len)
```

where `64` is the fixed descriptor size and `align64(frame_len)` is the padded
payload storage size.

The current build uses one U200 `DDR4` bank with a `16GiB` DDR address window.
Approximate source `pcap` capacity is:

| Frame bytes | Trace bytes per packet | Packets in `16GiB` DDR | Approx. source `pcap` size |
| ---: | ---: | ---: | ---: |
| `64` | `128` | `134,217,728` | `10.00GiB` |
| `512` | `576` | `29,826,161` | `14.67GiB` |
| `1518` | `1600` | `10,737,418` | `15.34GiB` |
| `9000` | `9088` | `1,890,390` | `15.87GiB` |

If the design is later expanded to all four U200 DDR banks, the design-space
capacity becomes roughly four times larger:

| Frame bytes | Packets in `64GiB` DDR | Approx. source `pcap` size |
| ---: | ---: | ---: |
| `64` | `536,870,912` | `40.00GiB` |
| `512` | `119,304,647` | `58.67GiB` |
| `1518` | `42,949,672` | `61.36GiB` |
| `9000` | `7,561,562` | `63.49GiB` |

### STREAM Ring Capacity

`STREAM` ring mode uses FPGA DDR as a sliding buffer.  The complete trace does
not need to fit in FPGA DDR, so the maximum source `pcap` size is mainly bounded
by host storage and the host-side conversion/loading pipeline.

For the measured remote host, the design-space notes used the following storage
budget:

| Storage condition | Approx. maximum source `pcap` |
| --- | ---: |
| Available free SSD space during measurement | `1.475TB` |
| Two 2TB SSDs as raw design space | `4.001TB` |

If a preconverted `stream.bin` must also be stored on disk, small packets suffer
from larger expansion because every packet still carries a 64-byte stream
header.

## Replay Throughput

Throughput should be read with two different units in mind:

- `wire throughput`: physical Ethernet line usage, including FCS, preamble/SFD,
  and IFG.
- `pcap` or frame throughput: bytes visible in the trace file, usually excluding
  FCS, preamble/SFD, and IFG.

At 100G Ethernet line rate, the corresponding source `pcap` throughput depends
on packet length:

| Frame bytes | 100G line-rate `pcap` throughput | Packet rate |
| ---: | ---: | ---: |
| `64` | `72.73Gbps` | `142.05Mpps` |
| `512` | `95.52Gbps` | `23.32Mpps` |
| `1518` | `98.44Gbps` | `8.11Mpps` |
| `9000` | `99.73Gbps` | `1.39Mpps` |

Current board measurements on the U200 optical loopback:

| Mode | Case | Result |
| --- | --- | ---: |
| `PRELOAD` | `64B`, `gap=3` | `70.4Gbps` wire, `51.2Gbps` frame/L2 |
| `PRELOAD` | `256B`, `gap=8` | `84.0Gbps` wire, `76.8Gbps` frame/L2 |
| `PRELOAD` | `512B`, `gap=14` | `91.9Gbps` wire, `87.8Gbps` frame/L2 |
| `PRELOAD` | `1518B`, `gap=38` | `97.4Gbps` wire, `95.9Gbps` frame/L2 |
| `PRELOAD` | mixed `64:3,1518:38` | `95.4Gbps` wire |
| `LOOP` | `1000` packets x `10` loops | correct count, no drop/stall/late/underrun |
| `STREAM` ring | `1518B`, `gap=300`, `1M` packets | `12.1Gbps` scheduled replay in current correctness-safe test |
| raw `XDMA H2C` | host-memory write benchmark | observed `69Gbps` to `83Gbps` depending run/configuration |

`PRELOAD` is the highest-throughput mode because the host is out of the transmit
data path during replay.  `STREAM` ring mode is designed for much larger traces,
but its sustained replay rate is limited by the host storage path, host memory
copy/conversion, `XDMA H2C`, DDR ring writes, and FPGA DDR reads.

## Replay Precision

The replay scheduler runs from the `300MHz` DDR/replay clock, so the scheduler
tick resolution is:

```text
1 / 300MHz = 3.333ns
```

For board-level precision testing, the project uses RX-side `SOP-to-SOP`
measurement.  The FPGA RX capture core keeps a free-running counter in the CMAC
RX clock domain.  On each received start-of-packet (`SOP`), it computes:

```text
rx_gap_cycles = current_sop_tick - previous_sop_tick
```

The host then compares each sampled RX interval with the original descriptor
`gap_ticks`, converted to nanoseconds.  This measures end-to-end packet spacing
through the TX replay path, CMAC TX, optical loopback, and CMAC RX.  It is more
realistic than only reading the TX scheduler counter.

Current RX-side precision suite results:

| Test case | Purpose | Result |
| --- | --- | ---: |
| `uniform_128B_gap3000` | fixed gap baseline | max abs error `10.38ns` |
| `mixed_gap_128B` | mixed packet gaps | max abs error `12.61ns` |
| `small_packet_small_gap` | 64B packets with `3/4/5/6/8` tick gaps | max abs error `8.05ns` |
| `mixed_size_legal` | mixed 64B to 1518B packets | max abs error `85.04ns` |
| `long_uniform_128B_gap3000` | `200000` packets, long-run drift check | max abs error `14.45ns` on sampled gaps |

The RX gap sample ring stores the most recent `4096` intervals.  Long traces
still update full aggregate statistics (`count`, `sum`, `min`, `max`, `last`),
but per-gap CSV readback is limited to the most recent sample window.

Run the precision suite:

```bash
python3 software/replay_precision_suite.py \
  --tx-port 0 --rx-port 1 \
  --work-dir /tmp/precision_suite \
  --desc-base 0x04000000 \
  --data-base 0x14000000 \
  --timeout 180 \
  --report /tmp/precision_suite/report.md
```

## Host Software Tools

The host software is intentionally small and command-line oriented.

| Tool | Purpose |
| --- | --- |
| `software/pcap2trace.py` | Convert classic `pcap` into `desc.bin`, `data.bin`, and `manifest.json` |
| `software/gen_synthetic_trace.py` | Generate deterministic synthetic descriptor/data traces |
| `software/gen_synthetic_pcap.py` | Generate synthetic `pcap` inputs |
| `software/xdma_load_trace.py` | Load `PRELOAD`/`LOOP` traces into FPGA DDR and program TX registers |
| `software/traffic_replay_cli.py` | Read/write control and status registers through `/dev/xdma0_user` |
| `software/ddr_readback_check.py` | Verify `XDMA H2C` and `C2H` access to FPGA DDR |
| `software/preload_stress_test.py` | Generate and replay fixed-size preload stress cases |
| `software/preload_mixed_test.py` | Generate and replay mixed-size preload cases |
| `software/loopback_rx_verify.py` | Check TX-to-RX payload samples over optical loopback |
| `software/replay_precision_suite.py` | Run RX-side replay precision tests |
| `software/xdma_stream_ring_fast.cpp` | C++ `STREAM` ring loader with batched H2C writes |
| `software/stream_stress_test.py` | Generate and run `STREAM` ring stress datasets |

Build the C++ loaders:

```bash
cd software
make
```

Convert a pcap:

```bash
python3 software/pcap2trace.py input.pcap \
  --out-dir /tmp/trace_out \
  --tick-hz 300000000
```

Load and start a preload replay:

```bash
sudo python3 software/xdma_load_trace.py \
  --port 0 \
  --manifest /tmp/trace_out/manifest.json \
  --desc-base 0x04000000 \
  --data-base 0x14000000 \
  --mode preload
```

Inspect status:

```bash
sudo python3 software/traffic_replay_cli.py --port 0 status
sudo python3 software/traffic_replay_cli.py --port 0 regs
sudo python3 software/traffic_replay_cli.py --port 1 rx-status
```

## Replay Modes

### PRELOAD

The host loads the complete descriptor and payload regions into FPGA DDR before
starting replay.  During replay, the FPGA reads everything from DDR and the host
is not in the transmit data path.

Best for:

- Maximum replay throughput.
- Best timing stability.
- Repeatable benchmark and precision tests.

Tradeoff:

- Maximum trace size is bounded by the allocated FPGA DDR space.

### LOOP

`LOOP` mode reuses the same DDR-resident trace multiple times.  It is useful for
long-duration stress tests without repeatedly loading data from the host.

### STREAM Ring

`STREAM` ring mode keeps a bounded ring in FPGA DDR.  The host writes complete
stream records into the ring, then advances `STREAM_WR_PTR`.  The FPGA consumes
records and advances `STREAM_RD_PTR`.

Best for:

- Traces larger than the available FPGA DDR preload window.
- Future SSD-to-host-memory-to-FPGA streaming workflows.

Tradeoff:

- Sustained throughput is limited by the dynamic loading path.
- The current correctness-safe implementation is functional but not yet 100G
  sustained.

## Trace Descriptor Format

`PRELOAD` and `LOOP` use two binary files:

- `desc.bin`: one 64-byte descriptor per packet.
- `data.bin`: packet payload bytes padded to 64-byte AXI beats.

Each descriptor is little-endian and exactly one 512-bit AXI beat:

| Byte offset | Field | Width | Description |
| ---: | --- | ---: | --- |
| `0x00` | `gap_ticks` | 64 bits | Gap from the previous packet in replay clock ticks |
| `0x08` | `data_word_offset` | 32 bits | Payload offset from `DATA_BASE`, measured in 64-byte words |
| `0x0c` | `frame_len` | 16 bits | Ethernet frame length in bytes, excluding preamble and FCS |
| `0x0e` | `flags` | 16 bits | Reserved for future per-packet controls |
| `0x10` | reserved | 48 bytes | Must be zero for forward compatibility |

See [docs/preload.md](docs/preload.md) for the detailed register map and
preload implementation notes.

## Build And Program

The repository is source-oriented.  Vivado projects are generated from Tcl.

Requirements:

- Linux host.
- Vivado 2020.2.
- Xilinx Alveo U200.
- Xilinx `XDMA` Linux driver.
- Python 3.
- `g++` and `make` for C++ host loaders.

Build a dual-port bitstream:

```bash
TRAFFIC_REPLAY_PORT_COUNT=2 \
TRAFFIC_REPLAY_HW_BUILD_ROOT=$PWD/build_hw \
vivado -mode batch -source scripts/build_hw_bitstream.tcl
```

Build a single-port debug bitstream:

```bash
TRAFFIC_REPLAY_PORT_COUNT=1 \
TRAFFIC_REPLAY_HW_BUILD_ROOT=$PWD/build_hw_oneport \
vivado -mode batch -source scripts/build_hw_bitstream.tcl
```

Program a board through Vivado hardware server:

```bash
vivado -mode batch -source scripts/program_remote.tcl \
  -tclargs build_hw/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.bit
```

After reprogramming an FPGA that is attached over PCIe, rescan the endpoint and
check the XDMA character devices:

```bash
lspci -nn -d 10ee:
ls -l /dev/xdma*
```

## Validation Commands

Check control plane:

```bash
sudo python3 software/traffic_replay_cli.py --port 0 clear
sudo python3 software/traffic_replay_cli.py --port 0 status
sudo python3 software/traffic_replay_cli.py --port 1 status
```

Check DDR readback through `H2C` and `C2H`:

```bash
sudo python3 software/ddr_readback_check.py \
  --case 0x00000000:4096 \
  --case 0x00100000:65536 \
  --case 0x08000000:1048576 \
  --repeat 2
```

Run preload throughput cases:

```bash
sudo python3 software/preload_stress_test.py \
  --port 0 \
  --packet-count 100000 \
  --case 64:3 \
  --case 256:8 \
  --case 512:14 \
  --case 1518:38 \
  --desc-base 0x04000000 \
  --data-base 0x14000000 \
  --require-no-drop
```

Run optical loopback payload verification:

```bash
sudo python3 software/loopback_rx_verify.py \
  --tx-port 0 \
  --rx-port 1 \
  --desc-base 0x1c000000 \
  --data-base 0x4c000000 \
  --rx-ring-base 0x70000000 \
  --rx-ring-size 0x01000000 \
  --truncate-bytes 128 \
  --packet-count 64 \
  --frame-len 128 \
  --gap-ticks 3000
```

Run stream ring stress:

```bash
python3 software/stream_stress_test.py \
  --port 0 \
  --frame-sizes 1518 \
  --packet-count 1000000 \
  --gap-ticks 300 \
  --ring-base 0x50000000 \
  --ring-size 0x20000000 \
  --prefill-bytes 0x10000000 \
  --batch-bytes 0x08000000 \
  --read-bytes 0x08000000 \
  --queue-depth 4 \
  --loader cpp
```

## Repository Layout

```text
rtl/           Synthesizable RTL
constraints/   Board and timing constraints
scripts/       Vivado project, build, and programming Tcl scripts
software/      Linux host tools and loaders
sim/           Testbenches
docs/          Design notes and evaluation reports
docs/images/   Architecture and result images
bitstreams/    Selected archived bitstreams with notes
reports/       Selected validation reports
```

## Known Limitations

- The current public hardware build uses one U200 DDR bank, not all four DDR
  banks.  Full `64GB` DDR use is planned.
- `STREAM` ring mode is functional, but the current correctness-safe host loader
  does not sustain 100G replay.
- RX interval sample readback stores the most recent `4096` intervals.  Full
  long-trace statistics are available as aggregate counters, not as a complete
  per-packet timestamp log.
- End-to-end RX precision includes scheduler behavior, TX buffering, CMAC
  framing, optical loopback, RX CMAC, and RX measurement quantization.  Mixed
  packet sizes can therefore show larger local SOP-to-SOP error than fixed-size
  traces.
- Dual-port simultaneous near-100G large-packet replay can overload the shared
  single-DDR-bank path.

## Roadmap

- Enable all four U200 DDR banks and expose a larger trace memory space.
- Improve `STREAM` mode with a faster loader path and less DDR read/write
  amplification.
- Add deeper and more parallel DDR prefetch paths for dual-port replay.
- Add an optional egress-side scheduler close to `CMAC` for tighter mixed-size
  end-to-end SOP timing.
- Expand RX event logging from recent gap samples to a larger timestamp/event
  ring.
- Keep important bitstreams archived with source commit, timing summary,
  resource summary, and validation notes.
