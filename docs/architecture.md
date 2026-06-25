# Architecture Notes

## Design intent

The replay datapath is intentionally split into source, scheduler, and TX engine layers:

```text
source layer      DDR trace reader or host stream parser
scheduler layer   converts pcap gaps to transmit eligibility
TX layer          consumes packet command + payload and drives CMAC AXIS
```

This keeps the timestamp behavior independent from whether packets are coming from DDR or PCIe streaming.

## Modes

`PRELOAD` is the preferred precision mode. The host loads a finite trace into DDR, sets `DESC_BASE`, `DATA_BASE`, `PKT_COUNT`, and writes `CONTROL.start`.

`STREAM` accepts a packet header beat followed by payload beats from host H2C stream. It can replay traces larger than DDR capacity, but underrun risk depends on host DMA and storage throughput.

`LOOP` is the same physical path as `PRELOAD`, with `loop_mode` enabled in the DDR reader. `LOOP_COUNT == 0` means infinite loop. `LOOP_GAP` replaces the first descriptor gap after each wrap.

## U200 hardware BD

`scripts/create_hw_project.tcl` builds the first U200 integration project. The important blocks are:

```text
XDMA x16 Gen3
  M_AXI       -> AXI clock converter -> DDR SmartConnect -> DDR4 C0
  M_AXI_LITE  -> AXI-Lite clock converter -> control SmartConnect
                                       -> replay_core/S_AXIL
                                       -> DDR4 control AXI-Lite

replay_core/M_AXI      -> DDR SmartConnect -> DDR4 C0
replay_core/M_TX_AXIS  -> axis_async_fifo -> CMAC QSFP0 axis_tx
```

The PCIe differential refclk is connected through `util_ds_buf` configured as `IBUFDSGTE`, matching the known-good U200 project style. The CMAC is configured for QSFP0, CAUI-4, 512-bit AXIS, 161.1328125 MHz GT refclk, and no RS-FEC.

The current BD clocks the replay core from the DDR4 UI clock. This is intentional for first bring-up because both the XDMA DDR write path and the replay DDR read path share the same memory clock after CDC. TX data crosses into the CMAC user clock through `axis_async_fifo.v`. For the final timing-precision version, move the scheduler and TX engine into the CMAC TX user clock domain and put a deeper packet FIFO between DDR and scheduler/TX.

Address map exposed to the host:

```text
XDMA M_AXI      0x0000_0000_0000_0000, 16GB  -> DDR4 C0
XDMA M_AXI_LITE 0x0000_0000, 64KB            -> replay regs
XDMA M_AXI_LITE 0x0001_0000, 64KB            -> DDR4 control regs
```

The `STREAM` mode RTL is preserved, but the current BD does not expose an XDMA/QDMA streaming H2C path into `host_stream_parser`. The present hardware path is therefore `PRELOAD` and `LOOP`.

## Throughput considerations

The current DDR reader is functional and simple: one 64B descriptor read per packet, followed by one payload burst. This makes verification easy, but the line-rate implementation should add:

- packed descriptor cache, ideally 4 descriptors per 64B read;
- independent descriptor and payload prefetch FIFOs;
- a skid buffer on AXI R data;
- outstanding read support with separate AXI IDs where the memory subsystem allows it;
- packet data FIFO deep enough to hide DDR arbitration latency.

For minimum Ethernet frames, descriptor command overhead can dominate. Keep the simple reader for early bring-up, then optimize after CMAC/QDMA/DDR wrappers are stable.

## Timestamp behavior

The scheduler uses replay-relative time. `CONTROL.start` and `CONTROL.clear` reset `now_ticks`, pending state, and first-packet state. The scheduler maintains `target_ticks`. For each packet:

```text
target_ticks = first ? (START_TIME == 0 ? first_gap : START_TIME)
                     : target_ticks + next_gap
```

`gap_ticks` is expected to be pre-scaled by host software. The register `RATE_Q16_16` is reserved for a later pipelined hardware scaler.

For the current hardware BD, generate traces with `--tick-hz 300000000` because the replay core is clocked by the DDR UI clock. The original stub and standalone CMAC-oriented estimates used 322.265625 MHz.

If a packet is eligible late, the scheduler records `late_pulse`; the TX path still sends the packet as soon as payload is available.

## Remote programming

The script `scripts/program_remote.tcl` connects to `172.22.5.106:3121`, opens the first available U200 device, and programs the provided bitstream. It assumes the remote host already has `hw_server` running and cable access configured.
