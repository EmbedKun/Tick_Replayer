# 2026-07-08 Four-DDR Dual-Port Prefetch Evaluation

This note records the first board smoke test for the timing-clean four-DDR,
dual-port replay build.

## Build Under Test

- Archive: `bitstreams/20260708_040647_4ddr_dual_prefetch_timing_clean`
- Remote build tree: `/home/user/tr_4ddr_timingfix_runs/bd_4ddr_dual_20260708_001610`
- Board: Xilinx Alveo U200
- Enabled ports: `2`
- Enabled DDR banks: `4`
- Implementation strategy: `Performance_ExplorePostRoutePhysOpt`

Address map:

| Function | DDR bank | Host address window |
| --- | --- | ---: |
| Port 0 TX descriptors and payload | `ddr4_0` | `0x0000000000` to `0x03ffffffff` |
| Port 1 TX descriptors and payload | `ddr4_1` | `0x0400000000` to `0x07ffffffff` |
| Port 0 RX sample/capture ring | `ddr4_2` | `0x0800000000` to `0x0bffffffff` |
| Port 1 RX sample/capture ring | `ddr4_3` | `0x0c00000000` to `0x0fffffffff` |

## Implementation Results

Post-route timing is clean:

```text
WNS = +0.010 ns
TNS = 0.000 ns
WHS = +0.006 ns
THS = 0.000 ns
All user specified timing constraints are met.
```

Placed resource summary:

```text
CLB LUTs      243083 / 1182240  20.56%
CLB registers 283137 / 2364480  11.97%
Block RAM        732 / 2160     33.89%
UltraRAM           0 / 960       0.00%
DSP               12 / 6840      0.18%
```

Artifact checksums:

```text
traffic_replay_bd_wrapper.bit  1621b5656ce4aaa5ff3ec2da5b9654f69b32673b17ec49a8b733444b3ce9a3c6
traffic_replay_bd_wrapper.ltx  fdb462c913475fc3ea07a028e375a52fd07b7fd673b7f91a94c8df992a918697
```

## Programming Note

The board was programmed over JTAG.  After programming, the host still had stale
XDMA PCIe state, so `H2C` DMA initially reported an invalid engine ID.  Removing
and rescanning the endpoint refreshed the Linux XDMA driver without rebooting:

```bash
echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/remove
echo 1 | sudo tee /sys/bus/pci/rescan
lspci -nn -d 10ee:
ls -l /dev/xdma*
```

After rescan, the endpoint appeared as `10ee:903f`, the `xdma` kernel driver was
bound, and `/dev/xdma0_h2c_0`, `/dev/xdma0_c2h_0`, and `/dev/xdma0_user` were
available.

## Four-DDR H2C/C2H Readback

Start-of-bank check:

```bash
sudo python3 software/ddr_readback_check.py \
  --case 0x0000000000:0x100000 \
  --case 0x0400000000:0x100000 \
  --case 0x0800000000:0x100000 \
  --case 0x0c00000000:0x100000 \
  --repeat 2
```

Result: all eight 1MiB write/readback checks passed.

End-of-bank check:

```bash
sudo python3 software/ddr_readback_check.py \
  --case 0x03fff00000:0x100000 \
  --case 0x07fff00000:0x100000 \
  --case 0x0bfff00000:0x100000 \
  --case 0x0ffff00000:0x100000 \
  --repeat 1
```

Output:

```text
PASS addr=0x3fff00000 size=1048576 repeat=0 h2c=13.968Gbps c2h=5.355Gbps
PASS addr=0x7fff00000 size=1048576 repeat=0 h2c=13.964Gbps c2h=6.272Gbps
PASS addr=0xbfff00000 size=1048576 repeat=0 h2c=15.053Gbps c2h=14.108Gbps
PASS addr=0xffff00000 size=1048576 repeat=0 h2c=17.865Gbps c2h=23.299Gbps
SUMMARY cases=4 repeat=1 checked_bytes=4194304 aggregate_rw=0.082Gbps
```

This verifies that the host can access the beginning and high end of all four
`16GiB` DDR windows through the XDMA memory-mapped path.

## Control Plane

Both TX replay register windows and both RX capture register windows were
readable through `/dev/xdma0_user`.

```bash
sudo python3 software/traffic_replay_cli.py --port 0 status
sudo python3 software/traffic_replay_cli.py --port 1 status
sudo python3 software/traffic_replay_cli.py --port 0 regs
sudo python3 software/traffic_replay_cli.py --port 1 regs
sudo python3 software/traffic_replay_cli.py --port 0 rx-status
sudo python3 software/traffic_replay_cli.py --port 1 rx-status
```

Observed state:

```text
mode              : preload
running           : no
cmac_link_up      : yes
tx_gate_open      : yes
force_link_up     : no
force_tx_ready    : no
auto_tx_drop      : yes
```

RX status was readable on both ports with `link_up=yes`, `fifo_ready=yes`, and
zero counters before the loopback tests.

## Dual-Port PRELOAD Throughput Smoke

Large-packet dual-port test:

```bash
sudo python3 software/dual_port_preload_test.py \
  --work-dir /tmp/tr_4ddr_dual_smoke_1518 \
  --packet-count 20000 \
  --frame-len 1518 \
  --gap-ticks 38 \
  --port0-desc-base 0x0000000000 \
  --port0-data-base 0x0010000000 \
  --port1-desc-base 0x0400000000 \
  --port1-data-base 0x0410000000 \
  --require-no-drop \
  --timeout 60
```

Output:

```text
port0: tx=20000 drop=0 late=0 underrun=0 stall=0 l2=95.870Gbps wire=97.386Gbps
port1: tx=20000 drop=0 late=0 underrun=0 stall=0 l2=95.870Gbps wire=97.386Gbps
aggregate: l2=191.741Gbps wire=194.772Gbps
```

Small-packet dual-port test:

```bash
sudo python3 software/dual_port_preload_test.py \
  --work-dir /tmp/tr_4ddr_dual_smoke_64 \
  --packet-count 50000 \
  --frame-len 64 \
  --gap-ticks 3 \
  --port0-desc-base 0x0000000000 \
  --port0-data-base 0x0010000000 \
  --port1-desc-base 0x0400000000 \
  --port1-data-base 0x0410000000 \
  --require-no-drop \
  --timeout 60
```

Output:

```text
port0: tx=50000 drop=0 late=0 underrun=0 stall=0 l2=51.199Gbps wire=70.398Gbps
port1: tx=50000 drop=0 late=0 underrun=0 stall=0 l2=51.199Gbps wire=70.398Gbps
aggregate: l2=102.397Gbps wire=140.796Gbps
```

The four-bank split removes the former shared-single-DDR bottleneck for
simultaneous large-packet replay.  The `64B` result is still limited by the
current scheduler cadence and descriptor format, not by DDR bandwidth.

## Optical Loopback Payload Correctness

The two QSFP ports were connected with 100G fiber.  The tests below transmit
from one port and verify the recent-packet sample ring written by the opposite
RX capture core.

Port 0 TX to port 1 RX:

```bash
sudo python3 software/loopback_rx_verify.py \
  --tx-port 0 \
  --rx-port 1 \
  --desc-base 0x0000000000 \
  --data-base 0x0010000000 \
  --rx-ring-base 0x0c10000000 \
  --rx-ring-size 0x01000000 \
  --truncate-bytes 128 \
  --packet-count 4096 \
  --frame-len 128 \
  --gap-ticks 2000 \
  --timeout 30
```

Output:

```text
tx_packets        : 4096
drop_packets      : 0
late_packets      : 0
stall_events      : 0
rx_packets        : 4096
rx_bytes          : 524288
rx_errors         : 0
captured_bytes    : 524288
axi_writes        : 8192
axi_errors        : 0
checked_samples   : 4096
sample_mismatches : 0
PASS: TX/RX loopback sample payloads match
```

Port 1 TX to port 0 RX:

```bash
sudo python3 software/loopback_rx_verify.py \
  --tx-port 1 \
  --rx-port 0 \
  --desc-base 0x0400000000 \
  --data-base 0x0410000000 \
  --rx-ring-base 0x0810000000 \
  --rx-ring-size 0x01000000 \
  --truncate-bytes 128 \
  --packet-count 4096 \
  --frame-len 128 \
  --gap-ticks 2000 \
  --timeout 30
```

Output:

```text
tx_packets        : 4096
drop_packets      : 0
late_packets      : 0
stall_events      : 0
rx_packets        : 4096
rx_bytes          : 524288
rx_errors         : 0
captured_bytes    : 524288
axi_writes        : 8192
axi_errors        : 0
checked_samples   : 4096
sample_mismatches : 0
PASS: TX/RX loopback sample payloads match
```

This confirms that both CMAC TX/RX directions, RX sample clear, packet boundary
alignment, sample write pointer handling, and DDR sample writes are functional.

## RX-Side Replay Precision Smoke

The RX capture core measures the SOP-to-SOP interval between adjacent received
packets in the CMAC RX clock domain.  The software converts the TX-domain
requested `gap_ticks` to the expected RX-domain cycle interval and checks the
aggregate RX gap statistics.

Port 0 TX to port 1 RX:

```bash
sudo python3 software/preload_rx_precision_check.py \
  --tx-port 0 \
  --rx-port 1 \
  --desc-base 0x0000000000 \
  --data-base 0x0010000000 \
  --packet-count 4096 \
  --frame-len 128 \
  --gap-ticks 3000 \
  --timeout 30
```

Output:

```text
expected_rx_gap   : 3222.656250
rx_gap_count      : 4095
rx_gap_min        : 3218
rx_gap_max        : 3227
rx_gap_avg        : 3222.658364
rx_gap_min_error  : -4.656250 cycles (-14.448 ns)
rx_gap_max_error  : 4.343750 cycles (13.479 ns)
rx_gap_avg_error  : 0.002114 cycles (0.007 ns)
PASS: RX-side SOP gap statistics match requested PRELOAD spacing
```

Port 1 TX to port 0 RX:

```bash
sudo python3 software/preload_rx_precision_check.py \
  --tx-port 1 \
  --rx-port 0 \
  --desc-base 0x0400000000 \
  --data-base 0x0410000000 \
  --packet-count 4096 \
  --frame-len 128 \
  --gap-ticks 3000 \
  --timeout 30
```

Output:

```text
expected_rx_gap   : 3222.656250
rx_gap_count      : 4095
rx_gap_min        : 3218
rx_gap_max        : 3227
rx_gap_avg        : 3222.656410
rx_gap_min_error  : -4.656250 cycles (-14.448 ns)
rx_gap_max_error  : 4.343750 cycles (13.479 ns)
rx_gap_avg_error  : 0.000160 cycles (0.000 ns)
PASS: RX-side SOP gap statistics match requested PRELOAD spacing
```

The min/max error includes CDC, RX clock quantization, and RX-side measurement
granularity.  The average error is effectively zero for this fixed-gap smoke
case.

## STREAM Ring Dynamic Load Smoke

Small sanity run:

```bash
sudo python3 software/stream_stress_test.py \
  --port 0 \
  --work-dir /tmp/tr_4ddr_stream_smoke \
  --frame-sizes 1518 \
  --packet-count 20000 \
  --gap-ticks 300 \
  --ring-base 0x0020000000 \
  --ring-size 0x04000000 \
  --prefill-bytes 0x02000000 \
  --batch-bytes 0x01000000 \
  --read-bytes 0x01000000 \
  --queue-depth 2 \
  --writer-threads 1 \
  --timeout 60 \
  --loader cpp
```

Output:

```text
completed         : true
tx_packets        : 20000
tx_bytes          : 30360000
late_packets      : 0
underrun_packets  : 0
stream_status     : 0x000003a2
final_level       : 0
committed_bytes   : 32000000
load_gbps         : 6.650
hw_gbps           : 12.144
```

Two-SSD striped warm-cache run:

```bash
sudo python3 software/stream_stress_test.py \
  --port 0 \
  --work-dir /home/user/tick_dualssd_work/tr_4ddr_stream \
  --lane-dir /home/user/tick_dualssd_lane0/tr_4ddr_stream \
  --lane-dir /home/rn-fellow/new_disk/tick_dualssd_lane1/tr_4ddr_stream \
  --stripe-block-bytes 0x04000000 \
  --frame-sizes 1518 \
  --packet-count 500000 \
  --gap-ticks 80 \
  --ring-base 0x0020000000 \
  --ring-size 0x40000000 \
  --prefill-bytes 0x04000000 \
  --batch-bytes 0x04000000 \
  --read-bytes 0x04000000 \
  --queue-depth 4 \
  --writer-threads 2 \
  --timeout 120 \
  --feed-timeout 120 \
  --loader cpp
```

Output:

```text
source_mode       : striped_direct
lane_count        : 2
stream_bytes      : 800000000
committed_bytes   : 800000000
committed_packets : 500000
completed         : true
tx_packets        : 500000
late_packets      : 0
underrun_packets  : 0
stream_status     : 0x000003a2
max_ring_level    : 738196800
min_ring_free     : 334496448
load_gbps         : 70.016
hw_gbps           : 45.540
```

Two-SSD striped cold-read run after dropping Linux page cache:

```bash
sync
echo 3 | sudo tee /proc/sys/vm/drop_caches
sudo ./software/xdma_stream_ring_fast \
  --port 0 \
  --stripe-manifest /home/user/tick_dualssd_work/tr_4ddr_stream/len1518_pkts500000_gap80/stripe_manifest.json \
  --h2c /dev/xdma0_h2c_0 \
  --user /dev/xdma0_user \
  --ring-base 0x0020000000 \
  --ring-size 0x40000000 \
  --prefill-bytes 0x04000000 \
  --guard-bytes 0x100000 \
  --batch-bytes 0x04000000 \
  --watermark 4096 \
  --timeout 120 \
  --feed-timeout 120 \
  --read-bytes 0x04000000 \
  --queue-depth 4 \
  --writer-threads 2
```

Output:

```text
source_mode       : striped_direct
committed_bytes   : 800000000
committed_packets : 500000
completed         : true
tx_packets        : 500000
late_packets      : 0
underrun_packets  : 0
stream_status     : 0x000003a2
load_gbps         : 28.252
hw_gbps           : 45.540
```

An alternate cold-read run with deeper queues and more writer threads measured
`28.549Gbps`.  The current safe STREAM path therefore remains limited mainly by
host cold-read and memory-mapped XDMA write submission, not by the FPGA replay
reader.

## Simulation Regression

Before implementation, the following local simulation regressions passed:

```text
scripts/run_axis_sync_fifo_sim.tcl              PASS
scripts/run_reader_quick_sim.tcl                PASS
scripts/run_core_perf_sim.tcl                   PASS
scripts/run_dual_core_perf_sim.tcl              PASS
scripts/run_stream_ring_reader_sim.tcl          PASS
scripts/run_stream_ring_reader_perf_sim.tcl     PASS
```

Key simulated throughput points:

```text
DDR trace reader, 1518B latency64: steady L2 149.952Gbps
DDR trace reader, 64B latency64:   steady L2 100.908Gbps
Replay core, 1518B latency64:      steady wire 152.715Gbps
Replay core, 64B gap2:             steady wire 100.802Gbps
Dual replay, 1518B latency64:      steady wire 152.715Gbps per port
Dual replay, 64B gap2:             steady wire 100.802Gbps per port
STREAM reader perf:                32 AXI read requests, max 29 outstanding
```

## Conclusion

This bitstream is a timing-clean four-DDR, dual-port board smoke release:

- Four `16GiB` DDR windows are accessible through XDMA.
- Dual-port `PRELOAD` large-packet replay reaches about `194.8Gbps` aggregate
  wire rate with no drops, late packets, underruns, or stalls.
- Dual-port `64B` replay reaches about `140.8Gbps` aggregate wire rate with the
  current 64-byte descriptor and scheduler cadence.
- Optical TX-to-RX payload sample checks pass in both directions.
- RX-side SOP-to-SOP fixed-gap precision checks pass in both directions.
- `STREAM` ring mode is functional, but cold-read dynamic load throughput is
  still far below the 100G target in the current XDMA memory-mapped loader path.

The next optimization target is the host dynamic load path: pinned memory,
larger effective DMA requests, better direct I/O behavior, or moving to
QDMA/XDMA AXI4-Stream H2C if sustained cold-stream 100G replay is required.
