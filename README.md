<div align="center">

<h1>Tick Replayer</h1>

<p><strong>DDR-backed dual-port 100G FPGA traffic replay prototype for Xilinx Alveo U200.</strong></p>

<p>
  <code>FPGA</code> /
  <code>100G Ethernet</code> /
  <code>Xilinx Alveo U200</code> /
  <code>PCIe XDMA</code> /
  <code>DDR4</code> /
  <code>CMAC</code> /
  <code>PCAP replay</code>
</p>

<p><a href="README_CN.md">中文 README</a></p>

</div>

## Overview

`Tick Replayer` loads packet descriptors and payload data from a Linux host into
FPGA `DDR4` through `PCIe XDMA`, then replays the traffic through 100G `CMAC`
ports with descriptor-controlled inter-packet timing.

The repository name, `Tick_Replayer`, comes from the unit that matters most in
the system: the replay clock tick.  A pcap timestamp delta is converted into
`gap_ticks`, and the FPGA scheduler releases each packet by comparing those tick
counts against a replay-relative hardware timer.  In other words, the project is
not only a packet player; it is a tick-accurate replay engine.

The current design is a dual-port prototype.  `QSFP0` and `QSFP1` each have an
independent transmit replay pipeline, and each receive side has a lightweight
statistics and recent-packet capture path.  The two `QSFP` ports can transmit
and receive at the same time, which is the behavior needed when one FPGA
emulates both sides of a bidirectional trace around a network device under test.

This repository is source-oriented: it contains `RTL`, Vivado Tcl scripts,
constraints, simulation, host utilities, documentation, verification
screenshots, and selected archived bitstreams with matching TXT notes.  Vivado
generated projects, build logs, temporary traces, and private machine state are
intentionally excluded.

## Table of Contents

* [Features](#features)
* [System Architecture](#system-architecture)
* [FPGA Datapath](#fpga-datapath)
* [Trace Descriptor Format](#trace-descriptor-format)
* [Repository Layout](#repository-layout)
* [Requirements](#requirements)
* [Build](#build)
* [Bitstream Archive](#bitstream-archive)
* [Programming and PCIe Rescan](#programming-and-pcie-rescan)
* [Host Tools](#host-tools)
* [Stream Mode and Stress Testing](#stream-mode-and-stress-testing)
* [Hardware Validation Suite](#hardware-validation-suite)
* [Verification](#verification)
* [Current Limitations](#current-limitations)

## Features

* `Xilinx Alveo U200` target.
* `PCIe Gen3 x16` endpoint based on Xilinx `XDMA`.
* One memory-mapped `H2C`/`C2H` `XDMA` path for `DDR4` access.
* `AXI-Lite` control plane through the `XDMA` user `BAR`.
* `DDR4`-backed trace storage for descriptors and payloads.
* Dual 100G `CMAC` datapath:
  * `TX0` replay core to `QSFP0`.
  * `TX1` replay core to `QSFP1`.
  * `RX0` capture/stat core from `QSFP0`.
  * `RX1` capture/stat core from `QSFP1`.
* Descriptor format with per-packet gap, payload offset, frame length, and flags.
* Replay modes:
  * `PRELOAD`: host preloads descriptor and payload files into `DDR4`.
  * `LOOP`: `DDR4`-backed replay loop is wired in `RTL`.
  * `STREAM`: host writes either a finite stream buffer or a continuously
    refilled DDR ring through memory-mapped `XDMA H2C`; the FPGA reads complete
    stream records and feeds the timestamp scheduler.  The repository includes
    both a Python feeder and a higher-throughput C++ feeder for this mode.
* Host-side Python tools for `pcap` conversion, `XDMA` loading, control registers,
  status registers, and RX capture configuration.
* Host-side C++ `STREAM` ring feeder with asynchronous producer/consumer loading
  and large batched `XDMA H2C` writes.
* Verified `QSFP0` <-> `QSFP1` 100G optical loop with bidirectional `TX`/`RX`
  counters and `DDR4` ring readback.

## System Architecture

### Block Diagram

![Tick Replayer block diagram](docs/images/replay_arch.png)

Block diagram of the `Tick Replayer` FPGA traffic replay system.  `APP`:
host-side application scripts for `pcap` processing, trace generation, `XDMA`
loading, and replay control; `XDMA Driver`: Xilinx DMA Linux driver exposing
`H2C`, `C2H`, and user `BAR` character devices; `PCIe XDMA IP`: Xilinx PCI
Express DMA endpoint; `AXIL M`: `AXI-Lite` master used by `XDMA` to access
control and status registers; `AXI M`: memory-mapped AXI master used for `H2C`
and `C2H` DDR access; `H2C`: host-to-card DMA; `C2H`: card-to-host DMA; `BAR`:
PCIe base address register window used for `AXI-Lite` control; `SmartConnect`:
Xilinx AXI interconnect/arbitration fabric; `DDR4`: FPGA external memory used
for `TX` descriptors, `TX` payload data, and `RX` sample rings; `TX DESC`:
transmit packet descriptor storage; `TX DATA`: transmit packet payload storage;
`RX SAMPLE`: truncated receive sample ring storage; `TX Replay Core`:
descriptor/payload prefetch, replay scheduler, and transmit packet engine;
`Sched`: replay scheduler driven by descriptor packet gaps; `RX Capture Core`:
receive statistics and sample writer; `FIFO`: `AXI-Stream` clock-domain crossing
and buffering; `CMAC`: Xilinx 100G Ethernet MAC; `QSFP`: 100G optical
transceiver port.  The diagram shows one replay/capture interface slice; the
dual-port build instantiates the same logical `TX`/`RX` path for the active
`CMAC`/`QSFP` ports.

The host prepares replay traces and controls the FPGA through `PCIe`.  The FPGA
stores traces in `DDR4` and uses independent per-port replay cores to feed the
100G `CMAC` transmit interfaces.  The receive side does not upload every packet
to the host; it keeps counters and optionally writes a truncated recent-packet
window into `DDR4` so that software can inspect selected data through `XDMA C2H`.

High-level data movement:

```text
PCAP / generated trace
  -> pcap2trace.py
  -> desc.bin + data.bin + manifest.json
  -> xdma_load_trace.py
  -> /dev/xdma0_h2c_0
  -> FPGA DDR4
  -> per-port descriptor reader / payload reader
  -> replay scheduler
  -> TX packet engine
  -> AXI-Stream async FIFO
  -> 100G CMAC TX
  -> QSFP0 / QSFP1
```

DDR-backed finite `STREAM` movement:

```text
desc.bin + data.bin
  -> trace_to_stream.py
  -> stream.bin
  -> xdma_stream_load.py
  -> /dev/xdma0_h2c_0
  -> FPGA DDR4 stream buffer
  -> ddr_stream_reader
  -> host_stream_parser
  -> replay scheduler
  -> TX packet engine
  -> 100G CMAC TX
```

DDR-backed ring `STREAM` movement:

```text
large PCAP / stream file on host SSD
  -> host software batches complete stream records in host memory
  -> XDMA H2C writes records into FPGA DDR4 ring
  -> host advances STREAM_WR_PTR only after full records are written
  -> FPGA ddr_stream_reader consumes records and advances STREAM_RD_PTR
  -> host polls STREAM_RD_PTR / STREAM_LEVEL before writing more
  -> host sets STREAM_CTRL.eof at end of file
  -> host_stream_parser
  -> replay scheduler
  -> TX packet engine
  -> 100G CMAC TX
```

Control and debug movement:

```text
traffic_replay_cli.py
  -> /dev/xdma0_user
  -> XDMA AXI-Lite master
  -> control SmartConnect
  -> TX/RX control and status registers

RX capture DDR ring
  -> /dev/xdma0_c2h_0
  -> host-side debug readback
```

## FPGA Datapath

The Vivado block design is generated by `scripts/create_hw_project.tcl`.
The major IP and RTL blocks are:

| Block | Role |
| --- | --- |
| `XDMA` | `PCIe Gen3 x16` endpoint.  Provides memory-mapped `H2C`/`C2H` DMA and an `AXI-Lite` master for `BAR`-mapped registers. |
| `DDR4 MIG` | U200 `DDR4 C0` memory controller.  Stores `TX` descriptors, `TX` payloads, and `RX` capture rings. |
| `SmartConnect` | Arbitrates host DMA, `TX` readers, and `RX` ring writers into `DDR4`; also routes `AXI-Lite` control accesses. |
| `trace_replay_core` | Per-port `TX` replay core with `AXI-Lite` registers, `DDR4` trace reader, scheduler, and `TX` engine. |
| `ddr_trace_reader` | Reads 64-byte descriptors and payload beats from `DDR4`. |
| `ddr_stream_reader` | Reads either a finite sequential stream buffer or a Host-refilled DDR ring for `STREAM` mode. |
| `host_stream_parser` | Parses one 64-byte stream header beat followed by packet payload beats. |
| `replay_scheduler` | Maintains a replay-relative tick counter and releases packets according to descriptor gap fields. |
| `replay_tx_engine` | Converts scheduled payload beats into 512-bit `CMAC TX AXI-Stream` frames. |
| `axis_sync_fifo` | Synchronous AXI-Stream prefetch FIFO.  Large replay FIFOs use Xilinx `XPM` block RAM to avoid oversized LUTRAM/register arrays. |
| `axis_async_fifo` | Crosses between the `DDR4` UI clock and `CMAC` user clocks. |
| `rx_capture_bd_core` | Per-port `RX` statistics and truncated `DDR4` ring capture. |
| `CMAC0` / `CMAC1` | 100G Ethernet MACs connected to `QSFP0` and `QSFP1`. |

`TRAFFIC_REPLAY_PORT_COUNT=1` can be used for a single-interface debug build.
This is a build-time cut: the generated block design omits `replay_core_1`,
`rx_cap_1`, `tx_axis_fifo_1`, and `CMAC1`, and shrinks the related
`SmartConnect` ports.  The default is `2`, which keeps the full dual-port
prototype.

Current `AXI-Lite` map:

```text
0x00000 - 0x0ffff  TX0 replay registers
0x10000 - 0x1ffff  TX1 replay registers
0x20000 - 0x2ffff  RX0 capture/stat registers
0x30000 - 0x3ffff  RX1 capture/stat registers
0x40000 - 0x4ffff  DDR4 controller control window
```

In a single-interface build, only `TX0`, `RX0`, and the `DDR4` control window
are populated; host commands should use `--port 0`.

Per-port `STREAM` ring control registers live inside each TX replay register
window:

```text
0x00a0 STREAM_WR_LO       Host producer pointer, low 32 bits
0x00a4 STREAM_WR_HI       Host producer pointer, high 32 bits
0x00a8 STREAM_RD_LO       FPGA consumer pointer, low 32 bits
0x00ac STREAM_RD_HI       FPGA consumer pointer, high 32 bits
0x00b0 STREAM_RING_LO     DDR ring size in bytes, low 32 bits
0x00b4 STREAM_RING_HI     DDR ring size in bytes, high 32 bits
0x00b8 STREAM_CTRL        bit 0 = EOF
0x00bc STREAM_STATUS      reader state, ring mode, EOF, overrun, empty-wait flags
0x00c0 STREAM_LEVEL_LO    committed bytes not yet consumed, low 32 bits
0x00c4 STREAM_LEVEL_HI    committed bytes not yet consumed, high 32 bits
```

TX/RX port connections:

```text
TX0: replay_core_0 -> tx_axis_fifo_0 -> CMAC0 TX -> QSFP0
TX1: replay_core_1 -> tx_axis_fifo_1 -> CMAC1 TX -> QSFP1

RX0: QSFP0 -> CMAC0 RX -> rx_cap_0 -> DDR ring writer
RX1: QSFP1 -> CMAC1 RX -> rx_cap_1 -> DDR ring writer
```

## Trace Descriptor Format

`PRELOAD` and `LOOP` replay modes use two binary files:

* `desc.bin`: one fixed-size descriptor per packet.
* `data.bin`: packet payload bytes, padded to 64-byte AXI data beats.

Each descriptor is exactly 64 bytes, little-endian, and naturally aligned to one
512-bit AXI beat.  The hardware descriptor reader fetches descriptor `N` from:

```text
descriptor_address = DESC_BASE + N * 64
```

Descriptor byte layout:

| Byte offset | RTL bits | Field | Width | Description |
| --- | --- | --- | --- | --- |
| `0x00` | `[63:0]` | `gap_ticks` | 64 bits | Inter-packet gap in replay clock ticks.  With `START_TIME=0`, the first packet is released after the first descriptor gap. |
| `0x08` | `[95:64]` | `data_word_offset` | 32 bits | Payload offset from `DATA_BASE`, measured in 64-byte words. |
| `0x0c` | `[111:96]` | `frame_len` | 16 bits | Number of valid frame bytes to transmit.  FCS is not stored; CMAC inserts FCS on TX. |
| `0x0e` | `[127:112]` | `flags` | 16 bits | Reserved for future per-packet options.  Current tools write `0`. |
| `0x10` | `[511:128]` | `reserved` | 48 bytes | Reserved.  Must be written as zero for forward compatibility. |

Equivalent packed C layout:

```c
struct replay_desc {
    uint64_t gap_ticks;
    uint32_t data_word_offset;
    uint16_t frame_len;
    uint16_t flags;
    uint8_t  reserved[48];
};
```

The payload start address is computed by the FPGA as:

```text
payload_address = DATA_BASE + data_word_offset * 64
payload_beats   = ceil(frame_len / 64)
```

`data.bin` stores each packet payload at a 64-byte boundary.  If `frame_len` is
not a multiple of 64, the host pads the remaining bytes in the final beat, and
the TX engine generates `TKEEP` from `frame_len` so that only valid bytes are
transmitted.  The current `pcap2trace.py` default pads short frames to 60 bytes
and does not store Ethernet FCS.

Example descriptors from the three-packet smoke trace:

| Packet | `gap_ticks` | `data_word_offset` | `frame_len` | `flags` |
| --- | ---: | ---: | ---: | ---: |
| 0 | `30000` | `0` | `64` | `0` |
| 1 | `30000` | `1` | `64` | `0` |
| 2 | `30000` | `2` | `124` | `0` |

`STREAM` mode uses a DDR-backed stream buffer.  The buffer is a linear sequence
of packet records:

```text
64-byte stream header for packet 0
64-byte-aligned payload for packet 0
64-byte stream header for packet 1
64-byte-aligned payload for packet 1
...
```

The stream header uses the same first 16 bytes as `replay_desc`:
`gap_ticks`, `frame_len`, and `flags` are consumed by the FPGA stream parser.
`data_word_offset` is ignored in `STREAM` mode and should be written as `0`.
The payload immediately follows the header and is padded to a 64-byte boundary.
The FPGA reads exactly `TRACE_BYTES` bytes from `DESC_BASE`, so the host must
program `DESC_BASE` as the stream-buffer base address and `TRACE_BYTES` as the
full stream-buffer size.

## Repository Layout

```text
bitstreams/    Selected archived bitstreams plus per-version TXT notes
constraints/   U200 and stub XDC constraints
docs/images/   Architecture and verification screenshots
rtl/           SystemVerilog/Verilog replay, CDC, and RX capture RTL
scripts/       Vivado project creation, simulation, implementation, programming
sim/           XSim testbench
software/      Host-side pcap conversion, XDMA loader, and control CLI
```

## Requirements

FPGA build host:

* Linux host with `Vivado 2020.2`.
* Xilinx licenses for `CMAC`, `XDMA`, `DDR4`, and related IP.
* Bash shell and standard Linux development tools.

Target machine:

* Linux host with an `Alveo U200` installed.
* Xilinx `XDMA` reference driver.
* Remote `hw_server` for JTAG programming.
* Two `QSFP` 100G optical ports.  The current smoke test uses a `QSFP0` <->
  `QSFP1` fiber loop.

## Build

Create the Vivado hardware project:

```bash
source /tools/Xilinx/Vivado/2020.2/settings64.sh
export TRAFFIC_REPLAY_HW_BUILD_ROOT=/home/user/tr_build_dual
export TRAFFIC_REPLAY_ENABLE_ILA=0
export TRAFFIC_REPLAY_PORT_COUNT=2
bash scripts/run_vivado.sh hwbd
```

Open the project in Vivado GUI when interactive inspection is needed:

```bash
vivado /home/user/tr_build_dual/vivado_hw/traffic_replay_hw.xpr
```

Run implementation and write the bitstream:

```bash
source /tools/Xilinx/Vivado/2020.2/settings64.sh
export TRAFFIC_REPLAY_HW_BUILD_ROOT=/home/user/tr_build_dual
export TRAFFIC_REPLAY_ENABLE_ILA=0
export TRAFFIC_REPLAY_PORT_COUNT=2
export TRAFFIC_REPLAY_VIVADO_JOBS=1
bash scripts/run_vivado.sh hwbit_existing
```

The generated bitstream is written under the selected build root:

```text
$TRAFFIC_REPLAY_HW_BUILD_ROOT/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.bit
```

For faster bring-up, generate a single-interface build:

```bash
source /tools/Xilinx/Vivado/2020.2/settings64.sh
export TRAFFIC_REPLAY_HW_BUILD_ROOT=/home/user/tr_hw_300_oneport_bd
export TRAFFIC_REPLAY_ENABLE_ILA=0
export TRAFFIC_REPLAY_PORT_COUNT=1
bash scripts/run_vivado.sh hwbd
bash scripts/run_vivado.sh hwbit_existing
```

In this mode only `TX0`/`RX0` are present, and host commands should use
`--port 0`.  The archived single-port debug build
`bitstreams/20260629_185452_oneport_300mhz_timing_clean_tested/` met 300 MHz
post-route timing and includes the matching test summary.

## Bitstream Archive

Important hardware images are archived under `bitstreams/`.  Each version should
include the `.bit` file, the matching `.ltx` file when available, and a TXT note
with the source commit, SHA256 hash, build root, and verification status.

Archive a generated bitstream:

```bash
bash scripts/archive_bitstream.sh \
  --bitfile /home/user/tr_build_dual/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.bit \
  --ltx /home/user/tr_build_dual/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.ltx \
  --name pre_stream_dual_qsfp_loop_verified \
  --build-root /home/user/tr_build_dual \
  --notes "H2C/C2H DDR readback passed; TX0->RX1 and TX1->RX0 loopback passed."
```

The archived TXT file is the audit trail for that hardware image.  Before
programming an old bitstream, compare its recorded SHA256 hash with the local
file.

## Programming and PCIe Rescan

Program the U200 through the remote hardware server:

```bash
source /tools/Xilinx/Vivado/2020.2/settings64.sh
bash scripts/run_vivado.sh program \
  /home/user/tr_build_dual/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.bit
```

After programming a PCIe endpoint through JTAG, the Linux host must rescan PCIe
or reboot.  A typical rescan sequence is:

```bash
sudo rmmod xdma 2>/dev/null || true
echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/remove
echo 1 | sudo tee /sys/bus/pci/rescan
sudo insmod /home/user/dma_ip_drivers/XDMA/linux-kernel/xdma/xdma.ko
lspci -nn -d 10ee:
ls -l /dev/xdma*
```

Expected PCIe device ID:

```text
01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]
```

## Host Tools

Generate deterministic Ethernet/IPv4/UDP pcap traffic for reproducible tests:

```bash
python3 /home/user/traffic_replay_software/gen_synthetic_pcap.py \
  --out /home/user/pcap_tests/udp_1518_1M.pcap \
  --packet-count 1000000 \
  --frame-len 1518 \
  --gap-ticks 0 \
  --vary-flow
```

Convert a classic pcap to the replay trace format:

```bash
python3 /home/user/traffic_replay_software/pcap2trace.py \
  /home/user/input.pcap \
  --out-dir /home/user/trace_out \
  --tick-hz 300000000
```

The converter creates:

```text
desc.bin
data.bin
manifest.json
```

Load a trace to TX0 and start `PRELOAD` replay:

```bash
sudo python3 /home/user/traffic_replay_software/xdma_load_trace.py \
  --port 0 \
  --manifest /home/user/trace_out/manifest.json \
  --desc-base 0x00000000 \
  --data-base 0x10000000 \
  --mode preload
```

Load a trace to TX1 with a separate DDR address range:

```bash
sudo python3 /home/user/traffic_replay_software/xdma_load_trace.py \
  --port 1 \
  --manifest /home/user/trace_out/manifest.json \
  --desc-base 0x01000000 \
  --data-base 0x11000000 \
  --mode preload
```

Convert a descriptor/data trace into a `STREAM` buffer:

```bash
python3 /home/user/traffic_replay_software/trace_to_stream.py \
  --manifest /home/user/trace_out/manifest.json \
  --out /home/user/trace_out/stream.bin
```

Load the stream buffer and start `STREAM` replay:

```bash
sudo python3 /home/user/traffic_replay_software/xdma_stream_load.py \
  --port 0 \
  --manifest /home/user/trace_out/stream_manifest.json \
  --stream-base 0x20000000
```

Continuously feed a DDR ring when the stream is larger than the available FPGA
DDR replay window:

```bash
sudo python3 /home/user/traffic_replay_software/xdma_stream_ring.py \
  --port 0 \
  --manifest /home/user/trace_out/stream_manifest.json \
  --ring-base 0x20000000 \
  --ring-size 0x08000000 \
  --prefill-bytes 0x02000000 \
  --timeout 60
```

Build and run the higher-throughput C++ feeder:

```bash
cd /home/user/traffic_replay_software
make xdma_stream_ring_fast

./xdma_stream_ring_fast \
  --port 0 \
  --manifest /home/user/trace_out/stream_manifest.json \
  --ring-base 0x20000000 \
  --ring-size 0x08000000 \
  --prefill-bytes 0x04000000 \
  --batch-bytes 0x02000000 \
  --read-bytes 0x02000000 \
  --queue-depth 4 \
  --timeout 120 \
  --feed-timeout 120
```

Both ring feeders commit only complete packet records.  The loader polls
`STREAM_RD_PTR`, computes free space as `ring_size - (write_ptr - read_ptr)`,
writes records through `/dev/xdma0_h2c_0`, and then advances `STREAM_WR_PTR`.
This preserves replay precision because the FPGA scheduler still owns all packet
release timing; host software only controls how quickly complete records become
available in the DDR ring.

Generate a synthetic trace for controlled testing:

```bash
python3 /home/user/traffic_replay_software/gen_synthetic_trace.py \
  --out-dir /home/user/synth_64B \
  --packet-count 100000 \
  --frame-len 64 \
  --gap-ticks 0
```

Query status:

```bash
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 status
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 status
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 rx-status
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-status
```

Configure RX capture rings:

```bash
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py \
  --port 0 rx-config --ring-base 0x32000000 --ring-size 0x00100000 --truncate-bytes 128
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 rx-clear
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 rx-enable
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 rx-capture on

sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py \
  --port 1 rx-config --ring-base 0x30000000 --ring-size 0x00100000 --truncate-bytes 128
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-clear
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-enable
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-capture on
```

`RX` capture writes complete 64-byte beats to `DDR4`.  `rx_bytes` is the meaningful
byte count derived from `TKEEP`, while `captured_bytes` is the number of 64-byte
ring bytes written.  The unused lanes at the end of the final beat are not valid
packet bytes.

## Stream Mode and Stress Testing

`STREAM` mode is DDR-backed.  The host uses memory-mapped `XDMA H2C` writes to
place stream records in `DDR4`; the FPGA `ddr_stream_reader` reads 512-bit AXI
beats, feeds `host_stream_parser`, and the replay scheduler releases packets
according to the per-record timestamp gap.

There are two `STREAM` operating styles:

| Style | Use case | Register setup |
| --- | --- | --- |
| Finite buffer | The whole stream fits in one FPGA DDR region. | `DESC_BASE=stream_base`, `TRACE_BYTES=stream_size`, `STREAM_RING_SIZE=0`. |
| DDR ring | The replay stream is larger than the selected FPGA DDR window. | `DESC_BASE=ring_base`, `TRACE_BYTES=0`, `STREAM_RING_SIZE=ring_size`, Host advances `STREAM_WR_PTR`, FPGA advances `STREAM_RD_PTR`. |

The DDR ring path is the intended large-PCAP mode.  Host software owns the
producer pointer and the FPGA owns the consumer pointer.  The Host must not
write more than `ring_size - (write_ptr - read_ptr)` bytes; if it does, the
FPGA sets the stream overrun flag in `STREAM_STATUS`.

More design detail is in
[`docs/stream_ring_mode.md`](docs/stream_ring_mode.md).

Run a max-throughput sweep with synthetic zero-gap packets:

```bash
sudo python3 /home/user/traffic_replay_software/stream_stress_test.py \
  --port 0 \
  --frame-sizes 64,128,256,512,1024,1518 \
  --packet-count 100000 \
  --gap-ticks 0 \
  --stream-base 0x20000000 \
  --csv /home/user/stream_stress.csv
```

Useful debug switches:

* `--force-link-up`: open the replay gate even when the `CMAC` link is down.
* `--force-tx-ready`: drain the replay core when the downstream `CMAC`/FIFO path
  is not ready.  This is useful for logic-only bring-up, but it bypasses the
  real transmit backpressure path and should not be used for final throughput
  numbers.

The stress script reports:

* `load_gbps`: host-to-DDR DMA load rate for the generated stream buffer.
* `hw_gbps`: FPGA replay throughput computed from `tx_bytes` and the hardware
  replay tick counter.
* `late_packets` and `underrun_packets`: scheduler and payload starvation
  indicators.

## Hardware Validation Suite

`hw_validation_suite.py` runs the common post-programming checks and keeps a
timestamped log directory on the target host.  It is the preferred way to compare
important bitstream versions because each run records the same classes of
evidence:

* `XDMA H2C` / `C2H` deterministic `DDR4` readback.
* Synthetic `pcap` generation, `pcap2trace.py` conversion, and
  `trace_to_stream.py` conversion.
* Finite-buffer `STREAM` throughput sweep.
* Oversized `DDR4` ring `STREAM` replay where the stream file is larger than the
  selected FPGA ring window.
* Optional `QSFP0` -> `QSFP1` RX loopback statistics and truncated sample-ring
  capture.

Run a quick smoke pass after programming:

```bash
cd /home/user/traffic_replay_software
make xdma_stream_ring_fast

sudo python3 /home/user/traffic_replay_software/hw_validation_suite.py \
  --profile smoke \
  --port 0 \
  --rx-port 1 \
  --ring-loader cpp
```

Run a larger stress pass:

```bash
sudo python3 /home/user/traffic_replay_software/hw_validation_suite.py \
  --profile stress \
  --port 0 \
  --rx-port 1
```

Use `--force-link-up` only for logic bring-up without an optical link.  Throughput
and packet-loss numbers should be collected with a real `CMAC` link and without
forcing downstream readiness.

Latest hardware results were collected with the archived bitstream
`bitstreams/20260628_140628_stream_fast_bram_fifo8192_experimental/`, programmed
onto the remote U200, with `QSFP0` and `QSFP1` connected by 100G fiber.

Important notes for this build:

* Bitstream generation completed with `0 Errors`.
* Final timing is not clean: `WNS=-0.247 ns`, `TNS=-51.325 ns`.
* `XDMA H2C/C2H` deterministic `DDR4` readback passed after programming.
* `STREAM` ring smoke passed with `1000` packets, `1518`-byte frames,
  `gap_ticks=30000`, `late=0`, and `underrun=0`.
* Synthetic `pcap` -> trace -> stream -> DDR ring replay passed with `10000`
  packets and `underrun=0`.
* `QSFP0` -> `QSFP1` low-rate RX loopback observed `2000` packets on RX1.

C++ DDR-ring `STREAM` replay on TX0, `100000` packets, `1518`-byte frames:

| Gap ticks | Target replay Gbps | Completed | TX packets | Late packets | Underrun packets |
| ---: | ---: | :---: | ---: | ---: | ---: |
| `720` | `5.060` | yes | `100000` | `0` | `0` |
| `600` | `6.072` | yes | `100000` | `0` | `0` |
| `480` | `7.590` | yes | `100000` | `0` | `0` |
| `360` | `10.120` | yes | `100000` | `24820` | `7940879` |
| `300` | `12.144` | yes | `100000` | `56812` | `14888217` |
| `240` | `14.893` | yes | `100000` | `76783` | `10944245` |

The fastest no-late/no-underrun dynamic ring point measured in this build is
about `7.59Gbps` for `1518`-byte frames.  The C++ feeder improves substantially
over the earlier Python feeder, but the current memory-mapped `XDMA H2C`
`pwrite` path still tops out around `10Gbps` for sustained ring refilling.

Finite-buffer `STREAM` stress on TX0, `100000` packets, `1518`-byte frames:

| Gap ticks | Completed | TX packets | TX bytes | Replay Gbps | Late packets | Underrun packets |
| ---: | :---: | ---: | ---: | ---: | ---: | ---: |
| `0` | yes | `100000` | `151800000` | `96.983` | `100000` | `1012270` |
| `36` | yes | `100000` | `151800000` | `96.986` | `99989` | `1012317` |

These finite-buffer runs show that the FPGA can push close to `100Gbps` with
large packets, but the zero-gap and near-line-rate cases are throughput stress
tests, not precision-clean replay tests.

Single-port preload timing-clean build:

`bitstreams/20260629_185452_oneport_300mhz_timing_clean_tested/` was built with
`TRAFFIC_REPLAY_PORT_COUNT=1`, programmed onto the remote U200, and validated
with internal replay gating (`force_link_up` and `force_tx_ready`) because
`CMAC1` is intentionally omitted in this debug image.

| Test | Packets | Frame bytes | Gap ticks | Wire-est. Gbps | Late packets | Underrun packets |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Large-packet target-100G preload | `100000` | `1518` | `37` | `99.761` | `0` | `0` |
| Large-packet max-drain preload | `100000` | `1518` | `0` | `138.323` | `100000` | `0` |
| Small-packet max-drain preload | `100000` | `64` | `0` | `81.827` | `100000` | `0` |
| Small-packet target-100G preload | `100000` | `64` | `2` | `88.949` | `81354` | `0` |

The `gap=0` rows are internal drain-rate tests.  The large-packet `gap=37`
result is the useful precision/throughput datapoint for this one-port build:
it reaches the 100G line-rate target without `late` or `underrun`.

## Verification

Run `RTL` simulation:

```bash
source /tools/Xilinx/Vivado/2020.2/settings64.sh
bash scripts/run_vivado.sh sim
```

The current `XSim` testbench covers:

* Host stream parser path: emits 2 packets.
* DDR-backed `STREAM` buffer path: emits 2 packets from an AXI read memory
  model.
* DDR-backed ring `STREAM` path: emits one packet, waits for the Host write
  pointer to advance, then emits the next packet.
* `DDR4` preload path: emits 3 packets from an AXI read memory model.

Run syntax checks for the host tools:

```bash
python3 -m py_compile \
  software/traffic_replay_cli.py \
  software/xdma_load_trace.py \
  software/xdma_stream_load.py \
  software/xdma_stream_ring.py \
  software/ddr_readback_check.py \
  software/pcap2trace.py \
  software/trace_to_stream.py \
  software/gen_synthetic_pcap.py \
  software/gen_synthetic_trace.py \
  software/stream_stress_test.py \
  software/hw_validation_suite.py
```

Run basic `XDMA` `DDR4` readback after programming:

```bash
sudo python3 ddr_readback_check.py
```

Representative output:

![XDMA probe and DDR readback](docs/images/xdma_probe_and_ddr.png)

Check dual-port link and `RX` status after connecting `QSFP0` and `QSFP1` with a
100G fiber:

![Dual-port link status](docs/images/dual_link_status.png)

Run a single-packet length sweep over both directions:

![Packet length sweep](docs/images/packet_length_sweep.png)

Run the three-packet DDR preload trace over both directions:

![Three-packet trace result](docs/images/three_packet_trace.png)

The latest hardware smoke test proves:

* Host `H2C`/`C2H` DMA can read and write `DDR4`.
* `AXI-Lite` register access works through the `XDMA` user `BAR`.
* `TX0` and `TX1` can read descriptors and payloads from `DDR4`.
* The scheduler and `TX` engine release packets and update counters.
* DDR-backed finite `STREAM` mode passes `RTL` simulation and hardware
  throughput testing with `stream_stress_test.py`.
* DDR-backed ring `STREAM` mode passes `RTL` simulation and U200 hardware tests:
  the reader consumes committed bytes, waits while the Host producer pointer is
  unchanged, then resumes when software advances `STREAM_WR_PTR`.
* `QSFP0` and `QSFP1` `CMAC` links come up over the 100G optical loop.
* `TX0` -> `RX1` and `TX1` -> `RX0` both preserve packet count and byte count.
* Multi-beat packets up to at least 256 bytes are not split after the `FIFO`
  read-latency fix.
* `RX` capture writes a readable recent-packet window into `DDR4`.
* DDR-backed `STREAM` replay now runs on hardware.  TX0 zero-gap stress tests
  complete for `64` through `1518` byte synthetic packets, DDR ring mode
  completes bounded-producer tests, and RX1 loopback counters plus DDR sample
  ring readback were verified at low rate.

## Current Limitations

* The latest archived BRAM-FIFO STREAM build is functional but not timing-clean:
  final implementation timing is `WNS=-0.247 ns`.
* The finite-buffer `STREAM` path reaches about `96.98Gbps` for 1518-byte
  packets, but near-line-rate tests still report `late_packets` and
  `underrun_packets`.  This is a throughput stress result, not a final
  precision replay result.
* Dynamic DDR ring `STREAM` is functionally verified with the C++ feeder.  The
  current no-late/no-underrun point is about `7.59Gbps` for 1518-byte packets.
  The memory-mapped `XDMA H2C` `pwrite` path sustains roughly `10Gbps` in this
  setup, so it cannot feed a `100Gbps` replay stream indefinitely.
* True `100Gbps` dynamic replay needs a different ingestion architecture:
  direct `XDMA`/`QDMA` `AXI4-Stream H2C`, larger kernel/user DMA batches,
  a lower-copy host loader, and FPGA-side prefetch with multiple outstanding DDR
  reads.  The current repository has the C++ memory-mapped feeder and deeper
  BRAM prefetch FIFO; it does not yet replace the PCIe path with QDMA.
* A 500000-packet finite-buffer long sweep exposed a replay-path recovery issue:
  after a timeout, normal `stop`/`clear` did not always restore TX operation.
  Reprogramming the same bitstream recovered the system.  The next RTL fix
  should add a stronger per-port soft reset covering the stream reader,
  scheduler, prefetch FIFO, and TX handshake state.
* The `DDR4` trace reader is intentionally simple; descriptor caching, payload
  prefetch, deeper FIFOs, and multiple outstanding reads are still future work.
* `RX` capture is a statistics and recent-packet debug window, not a full-rate
  packet recorder.
* The current `pcap` converter supports classic `pcap`, not `pcapng`.
* End-to-end testing through the target DDoS protection appliance is still a
  future integration step.
