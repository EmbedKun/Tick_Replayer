Tick Replayer bitstream archive
================================

Version
-------
20260628_224942_phase12_preload_prefetch_experimental_timing_violation

Bitstream
---------
traffic_replay_bd_wrapper.bit

SHA256
------
39eb06bda306159aa3dd245f6c8f2042e23d477095d4c4b5c85fa4e3719fb153

Build root
----------
/home/user/tr_build_phase12_timingclean_20260628_2000

Notes
-----
Phase 1/2 preload DDR reader experiment: descriptor/meta buffering, 8192-beat payload FIFO, 4-packet coalesced payload DDR reads. XSim passed and hardware smoke/preload stress passed, but routed timing is negative; do not treat as timing-clean release.

Hardware validation summary
---------------------------
Programmed on the remote U200 target through Vivado hw_server on 2026-06-28.
The PCIe endpoint enumerated as 10ee:903f and the XDMA driver recreated:
/dev/xdma0_h2c_0, /dev/xdma0_c2h_0, /dev/xdma0_user, /dev/xdma0_xvc.

Simulation:
- XSim replay testbench passed host-stream, DDR finite stream-buffer, DDR ring-stream, and DDR preload cases.

Hardware smoke:
- DDR H2C/C2H deterministic readback passed.
- QSFP0/QSFP1 link status was up on both CMACs.
- Stream finite-buffer sweep completed for 64/128/256/512/1024/1518 B packets.
- DDR ring-stream C++ loader committed 20,000 packets / 32,000,000 stream bytes and completed with no TX underrun.
- RX capture on the opposite QSFP observed packets and wrote truncated samples to DDR. At high continuous rates, RX sample capture can overflow; this is expected for the current sampling writer and is not full-line-rate capture.

Preload DDR replay stress:
- 20,000 x 64 B, gap=0: TX matched, no underrun, about 5.055 Gbps.
- 20,000 x 1518 B, gap=0: TX matched, no underrun, about 65.967 Gbps.
- 20,000 x 1518 B, gap=480: TX matched, no underrun, late=0, about 7.590 Gbps.
- 100,000 x 1518 B, gap=0: TX matched, no underrun, about 68.522 Gbps.
- 100,000 x 1518 B, gap=480: TX matched, no underrun, late=0, about 7.590 Gbps.
- 100,000 x 64 B, gap=0: TX matched, no underrun, about 5.123 Gbps.

Timing status:
- This is an experimental bitstream. It is functional in the smoke tests above, but routed timing does not meet the 300 MHz target.
- The dominant violations are in the mmcm_clkout0 domain around replay DDR reader address/coalescing logic, large AXIS FIFOs, and status/control fanout.

Timing extract
--------------
Overall timing summary: WNS=-1.119 ns, TNS=-2735.964 ns, failing setup endpoints=8097, WHS=0.006 ns, THS=0.000 ns.
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints   
