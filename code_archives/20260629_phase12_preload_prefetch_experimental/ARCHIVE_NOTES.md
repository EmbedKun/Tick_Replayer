# Tick Replayer Phase 1/2 Archive

Archive date: 2026-06-29

This snapshot freezes the Phase 1/2 preload DDR-reader experiment before starting the next optimization round toward 100 Gbps replay.

## Included State

- RTL source, constraints, Vivado scripts, simulation files, host software, project documentation.
- Current experimental bitstream archive:
  `bitstreams/20260628_224942_phase12_preload_prefetch_experimental_timing_violation`
- Hardware validation logs and reports copied inside that bitstream archive.

## Phase 1/2 Functional State

- `ddr_trace_reader.sv` uses a 128-entry descriptor FIFO, 128-entry metadata FIFO, 8192-beat payload FIFO, and a 4-packet payload coalescing window.
- XSim passed host-stream, DDR finite stream-buffer, DDR ring-stream, and DDR preload cases.
- The bitstream was generated and programmed on the remote U200.
- XDMA H2C/C2H DDR readback passed.
- QSFP0/QSFP1 CMAC links were up.
- Preload stress completed without TX underrun:
  - `100000 x 1518B, gap=0`: about 68.522 Gbps.
  - `100000 x 1518B, gap=480`: about 7.590 Gbps, no late packets.
  - `100000 x 64B, gap=0`: about 5.123 Gbps.

## Timing Status

This is not a timing-clean release.

- Overall WNS: `-1.119 ns`
- Overall TNS: `-2735.964 ns`
- Failing setup endpoints: `8097`
- WHS: `0.006 ns`

The dominant timing and throughput limits are in the 300 MHz replay/DDR-reader path, especially around payload address/coalescing logic, large AXIS FIFOs, and status/control fanout.

## Next Optimization Baseline

Future work toward 100 Gbps should start from this archive and focus on:

- Multiple outstanding DDR reads.
- Larger payload coalescing windows.
- Descriptor/payload dual-path prefetching or deeper independent prefetch queues.
- Removing `PL_SCAN` / `PL_AR` bubbles between payload runs.
- Closing 300 MHz timing with a cleaner microarchitecture rather than only relying on implementation strategy.
