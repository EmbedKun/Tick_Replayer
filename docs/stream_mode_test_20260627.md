# Stream Mode Hardware Test - 2026-06-27

This note records the hardware validation run for the DDR-backed `STREAM` mode
bitstream archived as:

```text
bitstreams/20260627_014343_stream_prefetch_lutram_fifo_dual_qsfp_impl/
```

## Setup

* Board: Xilinx Alveo U200.
* Host: Ubuntu 20.04 remote server with Xilinx `XDMA` driver.
* FPGA image: `traffic_replay_bd_wrapper.bit` from the archive above.
* Link setup: `QSFP0` and `QSFP1` connected by 100G fiber.
* Vivado build: 2020.2, `ILA=0`, single-job implementation.
* Routed timing: met, `WNS=0.026 ns`, `TNS=0.000 ns`, `WHS=0.010 ns`.

After programming, Linux was rescanned and the expected XDMA devices were
created:

```text
01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]
/dev/xdma0_h2c_0
/dev/xdma0_c2h_0
/dev/xdma0_user
```

Initial status showed the optical link and TX gate were open:

```text
cmac_link_up      : yes
tx_gate_open      : yes
force_link_up     : no
force_tx_ready    : no
```

## Smoke Test

Command:

```bash
python3 /home/user/traffic_replay_software/stream_stress_test.py \
  --port 0 \
  --frame-sizes 64,1518 \
  --packet-count 1000 \
  --gap-ticks 0 \
  --stream-base 0x20000000 \
  --work-dir /home/user/traffic_replay_stream_stress \
  --csv /home/user/stream_stress_smoke_lutram_fifo.csv \
  --timeout 10
```

Result:

| Frame bytes | Packets | Completed | TX packets | TX bytes | Replay Gbps | Load Gbps | Late packets | Underrun count |
| ---: | ---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 1,000 | yes | 1,000 | 64,000 | 17.135 | 4.261 | 1,000 | 0 |
| 1518 | 1,000 | yes | 1,000 | 1,518,000 | 32.855 | 14.105 | 1,000 | 76,825 |

With `gap_ticks=0`, every packet is requested as soon as possible.  Late packets
are expected in this mode.  Underruns on large packets show that the current DDR
stream reader/FIFO path cannot continuously feed the TX engine at line rate.

## Zero-Gap Stress Sweep

Command:

```bash
python3 /home/user/traffic_replay_software/stream_stress_test.py \
  --port 0 \
  --frame-sizes 64,128,256,512,1024,1518 \
  --packet-count 100000 \
  --gap-ticks 0 \
  --stream-base 0x20000000 \
  --work-dir /home/user/traffic_replay_stream_stress \
  --csv /home/user/stream_stress_max_lutram_fifo.csv \
  --timeout 60
```

Result:

| Frame bytes | Packets | Completed | TX packets | TX bytes | Replay Gbps | Load Gbps | Late packets | Underrun count |
| ---: | ---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 100,000 | yes | 100,000 | 6,400,000 | 17.328 | 7.011 | 100,000 | 0 |
| 128 | 100,000 | yes | 100,000 | 12,800,000 | 23.104 | 13.789 | 100,000 | 249,960 |
| 256 | 100,000 | yes | 100,000 | 25,600,000 | 27.725 | 15.961 | 100,000 | 892,300 |
| 512 | 100,000 | yes | 100,000 | 51,200,000 | 30.807 | 17.641 | 100,000 | 2,258,888 |
| 1024 | 100,000 | yes | 100,000 | 102,400,000 | 32.619 | 18.786 | 100,000 | 4,947,916 |
| 1518 | 100,000 | yes | 100,000 | 151,800,000 | 32.882 | 11.983 | 100,000 | 7,692,989 |

The current maximum measured replay rate is about `32.9 Gbps` for 1518-byte
frames.  This is not a CMAC limit; it is the current stream-source
implementation limit.  The `ddr_stream_reader` issues one burst at a time and
uses a simple FIFO/prefetch policy, so the TX engine sees gaps under aggressive
zero-gap scheduling.

## Scheduled 1518-Byte Sweep

Command pattern:

```bash
python3 /home/user/traffic_replay_software/stream_stress_test.py \
  --port 0 \
  --frame-sizes 1518 \
  --packet-count 20000 \
  --gap-ticks <gap> \
  --stream-base 0x20000000 \
  --work-dir /home/user/traffic_replay_stream_stress \
  --timeout 30
```

Result with the default `WATERMARK=4096`:

| Gap ticks | Replay Gbps | Late packets | Underrun count |
| ---: | ---: | ---: | ---: |
| 40 | 32.881 | 20,000 | 1,538,410 |
| 80 | 32.881 | 20,000 | 1,538,405 |
| 120 | 30.360 | 25 | 2,477 |
| 160 | 22.770 | 5 | 437 |
| 240 | 15.180 | 1 | 197 |
| 320 | 11.385 | 1 | 52 |
| 480 | 7.590 | 0 | 0 |
| 640 | 5.692 | 0 | 0 |

The current no-underrun point in this sweep is `gap_ticks=480`, which is about
`7.59 Gbps` for 1518-byte frames.  This is a conservative result for the current
simple stream reader.  It should improve after adding multiple outstanding
reads, larger read bursts, and packet-aware prefetch hysteresis.

## RX Loopback and Capture

With `QSFP0` connected to `QSFP1`, TX0 replay was observed by RX1.

RX counter check:

```bash
python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-clear
python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-enable
python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-capture on
python3 /home/user/traffic_replay_software/stream_stress_test.py \
  --port 0 \
  --frame-sizes 512 \
  --packet-count 1000 \
  --gap-ticks 480 \
  --stream-base 0x20000000 \
  --work-dir /home/user/traffic_replay_stream_stress \
  --timeout 10
python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-status
```

Observed RX1 status:

```text
rx_packets        : 1000
rx_bytes          : 512000
```

RX sample ring check:

```bash
python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-config \
  --ring-base 0x30000000 \
  --ring-size 0x100000 \
  --truncate-bytes 128
python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-clear
python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-enable
python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-capture on
python3 /home/user/traffic_replay_software/stream_stress_test.py \
  --port 0 \
  --frame-sizes 128 \
  --packet-count 16 \
  --gap-ticks 480 \
  --stream-base 0x20000000 \
  --work-dir /home/user/traffic_replay_stream_stress \
  --timeout 10
```

Observed RX1 status:

```text
rx_packets        : 16
rx_bytes          : 2048
captured_bytes    : 2048
axi_writes        : 32
axi_errors        : 0
```

Reading `/dev/xdma0_c2h_0` at `0x30000000` returned the expected synthetic
payload bytes, proving that the RX sample writer, DDR ring, and C2H readback
path are connected.

## Interpretation

This version proves the complete DDR-backed stream replay path:

```text
host synthetic stream -> XDMA H2C -> DDR4 stream buffer
  -> ddr_stream_reader -> host_stream_parser -> scheduler
  -> TX engine -> CMAC0 TX -> QSFP0
  -> fiber loop -> QSFP1 -> CMAC1 RX -> RX statistics / DDR sample ring
  -> XDMA C2H readback
```

The design is functionally connected and controllable from Linux.  The measured
throughput is not yet a 100G line-rate result.  The next performance step is to
make the stream source packet-aware and memory-efficient: deeper buffering,
larger/pipelined AXI read bursts, multiple outstanding reads, and a parser
enable policy that only pauses cleanly between packet records.
