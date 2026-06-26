Traffic Replay Bitstream Archive
================================

Important generated bitstreams are stored under this directory.  Each archived
version should live in its own timestamped subdirectory and include a matching
TXT note file with the source commit, SHA256 hash, build path, and verification
status.

Recommended command from PowerShell:

  powershell -ExecutionPolicy Bypass -File scripts\archive_bitstream.ps1 `
    -Bitfile D:\tr_build_dual\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper.bit `
    -Name dual_qsfp_loop_verified `
    -BuildRoot D:\tr_build_dual `
    -Notes "H2C/C2H DDR readback passed; TX0->RX1 and TX1->RX0 loopback passed."

