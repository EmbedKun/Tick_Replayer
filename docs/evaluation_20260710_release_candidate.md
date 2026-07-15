# 2026-07-10 Release Candidate Evaluation

This document records the release-gate evidence for the synchronized dual-port
Tick Replayer build.  All Vivado simulation, synthesis, implementation, and
programming commands are executed on the Linux build/board host.

## Candidate Configuration

| Item | Configuration |
| --- | --- |
| FPGA | Xilinx Alveo U200 |
| Ethernet | Two 100G CMAC ports |
| Replay clock | 300 MHz |
| CMAC user clock | approximately 322.266 MHz |
| DDR | Four 16 GiB banks enabled |
| XDMA | PCIe Gen3 x16, memory-mapped AXI, two H2C engines, one C2H engine |
| TX placement | Port 0 in DDR bank 0; port 1 in DDR bank 1 |
| RX sample placement | Port 0 in DDR bank 2; port 1 in DDR bank 3 |

The two-H2C configuration is the release target.  A four-H2C experiment was
rejected because its routed design did not meet timing.

## RTL Simulation

The following simulations were completed before implementation.

| Area | Result |
| --- | --- |
| Shared timebase CDC | Monotonic Gray-coded time observed by both replay domains |
| Dual-port synchronized start | Staggered host ARM commands produced the same first-TX cycle |
| Scheduled AXIS CDC FIFO | 2,048 packet targets and 5,120 beats preserved |
| CMAC egress scheduler | 4,096 64-byte packets, fractional 2/3-tick cadence, 142.115 Mpps, 100.049 Gbit/s wire rate, maximum lateness one tick |
| LBUS adapter | 1,024 consecutive 64-byte packets accepted at one packet per CMAC clock |
| Mixed-size egress | Eight packets released within zero to four CMAC ticks of their target |
| PRELOAD DDR reader | 64-byte steady state 150.003 Mpps; 1,518-byte steady state 150.729 Gbit/s L2 before the CMAC line-rate limiter |
| STREAM ring reader | Wrap, staged producer, ping-pong banks, invalid size, pointer regression, and overrun behavior passed |
| RX high-rate measurement | 100,000 packets counted, 99,992 complete interval events stored, zero event drops, clear/restart passed |

Representative commands:

```bash
vivado -mode batch -source scripts/run_replay_time_sync_sim.tcl
vivado -mode batch -source scripts/run_scheduled_axis_fifo_sim.tcl
vivado -mode batch -source scripts/run_egress_scheduler_sim.tcl
vivado -mode batch -source scripts/run_lbus_adapter_sim.tcl
vivado -mode batch -source scripts/run_rx_capture_core_clear_sim.tcl
```

Representative simulator output:

```text
PASS: global Gray-code timebase is monotonic and directed 64-bit decode vectors pass source=10028 p0=10027 p1=10026
PASS: staggered host ARM commands produced synchronized first TX cycle=20054 target=20052
PASS: dual trace_replay_core concurrent preload correctness and throughput simulation completed
PASS: scheduled AXIS CDC FIFO preserved 2048 packet targets across 5120 beats
PASS: egress 64B fractional 2/3-tick cadence packets=4096 pps=142.115M wire=100.049Gbps max_late_ticks=1
PASS: LBUS adapter full-rate 64B burst outputs=1024 span_cycles=1024
PASS: RX full-rate measurement logged 99992 gaps with zero event drops while counting 100000 packets
PASS: rx_capture_core clear resets state and sample ring captures fresh packet starts
```

## Host Software Tests

```bash
python3 -m py_compile \
  software/preload_stress_test.py \
  software/hw_validation_suite.py \
  software/tick_replay.py
python3 -m unittest discover -s software/tests -v
```

Result: six tests passed.  The suite covers timestamp quantization without
accumulated drift, fractional 100G small-packet gaps, unified CLI command
construction, multi-H2C STREAM selection, validation command routing, and
bank-local port 0/port 1 PRELOAD addresses.

## Timing Iteration

The first two-H2C implementation exposed a serial Gray-to-binary conversion in
the shared timebase CDC path.  Its function was correct, but the original loop
formed a long XOR prefix before the 64-bit due/late comparison.  That candidate
was stopped before route and archived as a rejected diagnostic:

```text
post-place WNS   = -1.348 ns
post-physopt WNS = -1.242 ns
post-physopt TNS = -1454.910 ns
```

The decoder was first replaced with an equivalent six-level parallel prefix
network.  Directed vectors exercised low and high bits across the full 64-bit
range.  Synthesis setup improved to:

```text
WNS = +0.138 ns
TNS =  0.000 ns
```

Physical placement also improved, but decode plus compare was still too deep:

```text
parallel-prefix-only post-place WNS = -0.911 ns
```

The accepted RTL direction therefore registers the decoded tick before the
64-bit due/late comparison.  Replay-domain look-ahead changes from two to three
ticks in synchronized mode to account for the added stage.  CMAC scheduling
keeps the uncompensated target so a packet is never released early.  The final
pre-implementation simulation results are:

```text
64-byte egress: 142.115 Mpps, 100.049 Gbit/s wire, maximum +1 tick, no early packet
mixed-size egress with random ready backpressure: 0..+5 CMAC ticks, no early packet
dual-port synchronized first TX cycle: 20054 on both ports
```

The mixed/backpressured upper bound is one CMAC cycle larger than the
parallel-prefix-only version.  This bounded late-only tradeoff removes the
decode/comparator timing chain while preserving descriptor timestamps and
continuous small-packet throughput.

Post-route values remain the release sign-off criterion.

## Implementation Gate

The release bitstream is accepted only when the final routed report has:

- non-negative setup and hold slack;
- zero setup and hold total negative slack;
- no unrouted nets;
- no release-blocking DRC violations.

The final timing, utilization, route, and DRC values will be copied from the
remote implementation reports after routing completes.

## Board Validation Matrix

After the timing gate passes, the candidate is programmed and validated in the
following order:

1. PCIe enumeration, XDMA driver reload, BAR access, and two H2C device nodes.
2. H2C/C2H data-integrity checks at the low and high end of all four DDR banks.
3. AXI-Lite control, stop, clear, restart, and mode changes without reprogramming.
4. PRELOAD small, large, mixed-size, dual-port, legal-rate, and overrate cases.
5. LOOP completion/count behavior and sustained replay.
6. STREAM ring wrap, refill, EOF, producer backpressure, and multi-H2C load rate.
7. Synchronized dual-port start and CMAC-domain egress scheduling.
8. Optical TX-to-RX payload loopback, RX counters, interval events, histogram,
   overflow reporting, and clear/restart.
9. Gap-accuracy comparison against descriptor timestamps.
10. Long-duration stress and recovery after deliberately excessive offered load.

Measured board results are added only after the candidate passes this sequence.
