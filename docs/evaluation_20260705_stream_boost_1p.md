# 2026-07-05 STREAM Ring 单口冲高测试

本次测试目标是验证新的单口 STREAM ring boost bitstream 是否能把大包回放推到接近 100Gbps，并且用真实双 SSD + XDMA H2C 路径测试动态装载瓶颈。

归档 bitstream：

```text
bitstreams/20260705_stream_boost_1p_timing_clean/traffic_replay_bd_wrapper.bit
```

## 1. Bitstream 和时序

构建配置：

```text
TRAFFIC_REPLAY_PORT_COUNT=1
TRAFFIC_REPLAY_DDR_BANKS=1
TRAFFIC_REPLAY_VIVADO_JOBS=8
```

Vivado 2020.2 `write_bitstream` 完成。Post-route timing：

```text
WNS = +0.024 ns
TNS =  0.000 ns
WHS = +0.010 ns
THS =  0.000 ns
```

本版硬件侧主要变化：

- `ddr_stream_reader` 支持多 outstanding AXI read burst，用来隐藏 DDR read latency。
- STREAM 模式启动时，scheduler 会等 DDR prefetch FIFO 先暖起来，避免刚启动就 late。
- 本轮使用单口单 DDR bank bitstream，便于把变量集中到 STREAM 装载和单口 replay 上。

## 2. 板卡状态

烧录后重新枚举 PCIe，XDMA 设备恢复：

```text
$ lspci -nn -d 10ee:
01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]

$ ls -l /dev/xdma* | head
/dev/xdma0_c2h_0
/dev/xdma0_control
/dev/xdma0_h2c_0
/dev/xdma0_user
/dev/xdma0_xvc
```

由于这版只打开一个 replay port，而物理光纤目前是 QSFP0/QSFP1 互联，测试使用 `--force-link-up --force-tx-ready` 验证内部 TX 路径和 DDR/STREAM 装载路径。

## 3. 有限 Trace 全预填测试

`1518B` 大包、`gap=38` tick 的理论 L2 吞吐为：

```text
1518 * 8 / (38 / 300e6) = 95.874 Gbps
```

命令：

```bash
sudo /tmp/tr_stream_dualssd_board/software/xdma_stream_ring_fast --port 0 \
  --stripe-manifest /home/user/tick_dualssd_work/direct_blocks/dual_1518_gap38_1m/stripe_manifest.json \
  --reader-threads 2 --reader-window-blocks 8 \
  --ring-base 0x20000000 --ring-size 0x100000000 --prefill-bytes 0xc0000000 \
  --guard-bytes 0x100000 --queue-depth 8 --writer-threads 2 \
  --timeout 240 --feed-timeout 240 --force-link-up --force-tx-ready
```

结果：

```text
committed_bytes   : 1600000000
committed_packets : 1000000
tx_packets        : 1000000
tx_bytes          : 1518000000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
debug_ticks       : 38000026
hw_gbps           : 95.874
load_gbps         : 11.316
```

这个结果证明大包 STREAM replay 的 FPGA 内部路径可以达到 `gap=38` 对应的理论吞吐。

## 4. 8GB Trace 全预填对照

构造 `5,000,000` 个 `1518B/gap=38` packet，stream record 总大小 `8,000,000,000B`。使用 `12GB` ring，使整份 trace 可以在启动前进入 FPGA DDR。

命令：

```bash
sudo /tmp/tr_stream_dualssd_board/software/xdma_stream_ring_fast --port 0 \
  --stripe-manifest /home/user/tick_dualssd_work/direct_blocks/dual_1518_gap38_5m/stripe_manifest.json \
  --reader-threads 2 --reader-window-blocks 8 \
  --ring-base 0x20000000 --ring-size 0x300000000 --prefill-bytes 0x240000000 \
  --guard-bytes 0x100000 --queue-depth 8 --writer-threads 2 \
  --timeout 240 --feed-timeout 240 --force-link-up --force-tx-ready
```

结果：

```text
committed_bytes   : 8000000000
committed_packets : 5000000
tx_packets        : 5000000
tx_bytes          : 7590000000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
debug_ticks       : 190000026
hw_gbps           : 95.874
load_gbps         : 15.590
```

这说明本版 STREAM reader 和 replay core 对 8GB 级别大包 trace 本身没有吞吐问题；只要启动前 DDR ring 中有足够数据，调度精度和吞吐都能保持。

## 5. gap=36 冲高对照

`1518B/gap=36` 对应内部计算吞吐约：

```text
1518 * 8 / (36 / 300e6) = 101.200 Gbps
```

测试结果：

```text
committed_packets : 1000000
tx_packets        : 1000000
tx_bytes          : 1518000000
late_packets      : 0
underrun_packets  : 0
hw_gbps           : 101.200
```

这里使用 `force_tx_ready`，因此它验证的是 replay core 内部调度和 TX 数据路径能力。真实 CMAC 物理链路会把线速限制在 100G 附近。

## 6. 双 SSD + XDMA 动态装载测试

同一个 8GB trace，使用 `8GB` ring 和 `6GB` 左右预填后启动，剩余数据边回放边通过 XDMA H2C 写入 FPGA DDR。

命令：

```bash
sudo /tmp/tr_stream_dualssd_board/software/xdma_stream_ring_fast --port 0 \
  --stripe-manifest /home/user/tick_dualssd_work/direct_blocks/dual_1518_gap38_5m/stripe_manifest.json \
  --reader-threads 2 --reader-window-blocks 8 \
  --ring-base 0x20000000 --ring-size 0x200000000 --prefill-bytes 0x180000000 \
  --guard-bytes 0x100000 --queue-depth 8 --writer-threads 2 \
  --timeout 240 --feed-timeout 240 --force-link-up --force-tx-ready
```

结果：

```text
committed_bytes   : 8000000000
committed_packets : 5000000
tx_packets        : 5000000
tx_bytes          : 7590000000
late_packets      : 4999989
underrun_packets  : 172158888
max_ring_level    : 7166869504
load_gbps         : 14.584
hw_gbps           : 55.306
debug_ticks       : 329369689
```

这是真正的动态装载压力场景。结果说明 ring 中的初始数据可以把平均回放吞吐抬到 `55Gbps`，但长期持续段仍会被当前 host-to-FPGA 装载速度拖住。

## 7. 双 SSD dry-run

只读取双 SSD striped block、做顺序重排，不访问 XDMA：

```bash
/tmp/tr_stream_dualssd_board/software/xdma_stream_ring_fast --port 0 \
  --stripe-manifest /home/user/tick_dualssd_work/direct_blocks/dual_1518_gap38_5m/stripe_manifest.json \
  --reader-threads 2 --reader-window-blocks 8 \
  --queue-depth 8 --read-bytes 0x10000000 --dry-run
```

结果：

```text
committed_bytes   : 8000000000
committed_packets : 5000000
read_gbps         : 26.828
read_seconds      : 2.385580
```

软件参数加到 `reader_threads=4`、`writer_threads=4` 后，实际 XDMA load 仍约 `15.5Gbps`，没有显著提升。因此当前主要瓶颈不是 SSD 读线程数，而是 memory-mapped XDMA `pwrite()` H2C 路径和对应软件提交方式。

## 8. 结论

- 本版单口 STREAM replay 在全预填条件下可以达到 `95.874Gbps`，并且 `late/underrun/drop/stall` 为 0。
- `gap=36` 内部路径可达到 `101.2Gbps` 的计算负载，说明大包 replay core 已经具备 100G 级别能力。
- 真实动态 STREAM 的长期上限仍受 Host -> FPGA 装载限制。当前实测双 SSD dry-run 为 `26.8Gbps`，XDMA H2C load 为 `14.6-15.6Gbps`。
- 如果要让无限长/远大于 DDR 的 STREAM trace 稳定 100G，需要升级到 QDMA/XDMA AXI4-Stream H2C、pinned hugepage/内核态或 DPDK 风格提交、多 H2C queue，或者改变架构绕过 memory-mapped `pwrite -> DDR -> readback` 的双 DDR 流量路径。
