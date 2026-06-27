# Remote Hardware Validation - Stream Ring Bitstream

This directory contains the lightweight logs copied back from the remote U200
host after testing the archived bitstream:

```text
bitstreams/20260627_232530_remote_clearfix_stream_ring_test_bit/
```

Large generated `.pcap` and `.bin` files remain on the remote host under:

```text
/home/user/traffic_replay_validation/current
```

## Hardware Image

| Item | Value |
| --- | --- |
| Bitstream SHA256 | `ef91e5a35bb081f0a738ac48a99874dd838b98e3f10ad6c74ec4f8931611aa93` |
| Build host | `user@172.22.5.106` |
| Remote build root | `/home/user/tr_build_remote_clearfix` |
| Vivado | `2020.2` |
| Programming result | Passed |
| PCIe after rescan | `10ee:903f`, Gen3 x16, `xdma` driver loaded |
| Timing | Functional test image, not timing-clean (`WNS=-0.229 ns`) |

## Test Summary

| Test | Result | Evidence |
| --- | --- | --- |
| `XDMA H2C/C2H` DDR readback | Passed | `00_ddr_readback.log` |
| `smoke` profile | Passed | `20260627_233933_smoke/validation.log` |
| `stress` profile | Passed | `20260627_234037_stress/validation.log` |
| Low-rate `TX0 -> RX1` optical loopback | Passed, 1000/1000 packets | `rx_low_rate/rx_low_rate.log` |
| High-rate `TX0 -> RX1` RX capture | Link works, capture overflows | `20260627_234037_stress/validation.log` |
| 200k-packet low-rate DDR ring replay | Passed, no late or underrun | `ring_200k_lowrate/ring_200k_lowrate.log` |
| DDR ring gap sweep | Passed, threshold measured | `ring_gap_sweep_50k/summary.csv` |
| 500k-packet finite stream long test | Exposed robustness limit | `20260627_234243_long/finite_stream_sweep.csv` |
| Recovery by reprogramming | Passed | `post_reprogram_recovery/post_reprogram_recovery.log` |

## Finite Stream Throughput

Stress profile, `100000` packets per frame length, zero timestamp gap:

| Frame bytes | Completed | TX packets | TX bytes | Replay Gbps | Load Gbps | Underrun count |
| ---: | :---: | ---: | ---: | ---: | ---: | ---: |
| `64` | yes | `100000` | `6400000` | `38.388` | `7.232` | `0` |
| `128` | yes | `100000` | `12800000` | `61.409` | `10.036` | `0` |
| `256` | yes | `100000` | `25600000` | `77.289` | `10.389` | `73451` |
| `512` | yes | `100000` | `51200000` | `88.371` | `10.178` | `257062` |
| `1024` | yes | `100000` | `102400000` | `94.190` | `11.005` | `666357` |
| `1518` | yes | `100000` | `151800000` | `95.518` | `18.290` | `1068958` |

The 1518-byte finite buffer path is close to 100G line rate, but zero-gap tests
still report underruns because the stream reader is a simple DDR-backed source,
not a deeply optimized multi-outstanding packet prefetch engine.

## DDR Ring Mode

The DDR ring mode was validated as a capacity-scaling path.  The host writes
complete stream records into a bounded FPGA DDR ring and only advances
`STREAM_WR_PTR` after each record is committed.  The FPGA advances
`STREAM_RD_PTR` as it consumes records.

Low-rate long ring test:

| Packets | Frame bytes | Gap ticks | TX packets | TX bytes | Late | Underrun | Replay Gbps |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `200000` | `1518` | `15000` | `200000` | `303600000` | `0` | `0` | `0.243` |

50k-packet gap sweep:

| Gap ticks | Completed | Replay Gbps | Late packets | Underrun packets |
| ---: | :---: | ---: | ---: | ---: |
| `20000` | yes | `0.182` | `0` | `0` |
| `15000` | yes | `0.243` | `0` | `0` |
| `12000` | yes | `0.304` | `0` | `0` |
| `10000` | yes | `0.364` | `0` | `0` |
| `8000` | yes | `0.455` | `0` | `0` |
| `6000` | yes | `0.546` | `13770` | `29342` |
| `4000` | yes | `0.549` | `29974` | `68707` |

Current conclusion: the dynamic DDR ring path is functionally correct, but the
Python memory-mapped `XDMA H2C` feeder limits sustained no-underrun replay to
about `0.45Gbps` for this test setup.  Reaching 100G in dynamic mode will require
a faster host loader, direct streaming DMA, larger batched DMA submissions, or a
different FPGA-side buffering strategy.

## Long-Run Robustness Finding

The `long` finite-buffer sweep used `500000` packets per frame length.  It
completed `64`, `128`, and `256` byte cases.  The `512` byte case transmitted
`481174` packets and then timed out.  The following `1024` and `1518` byte cases
entered a state where `running` asserted internally, the FIFO filled, but no
packets were transmitted.  A normal `stop`/`clear` did not restore TX operation.

Reprogramming the same bitstream and rescanning PCIe restored normal operation:

```text
1518B x 2000 finite stream: passed, 96.820Gbps
1518B x 20000 DDR ring: passed
```

This should be treated as the next RTL robustness item.  The likely fix is to
make `clear` reset all stream reader, scheduler, prefetch FIFO, and TX handshake
state, or add a soft-reset register that fully resets the per-port replay path.
