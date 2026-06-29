Tick Replayer bitstream archive
================================

Version
-------
20260629_231333_dual_300mhz_loop_correctness_timing_violation

Bitstream
---------
traffic_replay_bd_wrapper.bit

SHA256
------
c19331897adf931cbcb375a36be31b633a6ed4980763af7dea8d87954379ee33

Build root
----------
/home/user/tr_hw_300_dual_bd_20260629

Notes
-----
Dual-port TRAFFIC_REPLAY_PORT_COUNT=2 build. Bitstream generation completed, but timing is not clean: WNS=-0.145 ns, TNS=-486.061 ns. Programmed on remote U200; PCIe/XDMA and DDR readback passed; both CMAC links up over QSFP0/QSFP1 fiber. Correctness: 64B TX0->RX1 and TX1->RX0 passed with full sample compare; 128B both directions passed; longer packets show RX errors/sample mismatch in hardware despite RTL/perf simulations passing, so this is a debug/failing archive.
