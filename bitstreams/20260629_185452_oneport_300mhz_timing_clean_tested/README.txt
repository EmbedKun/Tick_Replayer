Tick Replayer bitstream archive
================================

Version
-------
20260629_185452_oneport_300mhz_timing_clean_tested

Bitstream
---------
traffic_replay_bd_wrapper.bit

SHA256
------
38e5f37a9d0f851d92b7d4db18401bc5bed2335477257f184c8b924cee2c97ec

Build root
----------
/home/user/tr_hw_300_oneport_bd

Notes
-----
One-port TRAFFIC_REPLAY_PORT_COUNT=1 debug bitstream. 300 MHz route timing clean: WNS=0.000, TNS=0.000, WHS=0.006. Programmed on remote U200. H2C/C2H DDR readback passed. Preload smoke 3 packets passed. Stress: 100k x 1518 gap37 reached 99.761 Gbps wire-est with late=0 underrun=0; 100k x 64 gap0 reached 81.827 Gbps wire-est; 100k x 64 gap2 reached 88.949 Gbps wire-est with late due small-packet scheduler limit. Test used force_link_up and force_tx_ready because this build disables CMAC1.
