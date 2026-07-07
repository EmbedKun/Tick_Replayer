# 2026-07-07 STREAM Ping-Pong Pipeline 上板评估

本轮目标是把 `STREAM ring` 的动态换入路径继续往前推：硬件侧使用双 DDR bank
ping-pong ring，软件侧用 C++ loader、多线程 `H2C pwrite()`、双 SSD striped
输入和 container stripe 数据布局，验证哪些部分已经接近上限，哪些部分仍是瓶颈。

## 1. 硬件版本

bitstream 归档目录：

```text
/home/user/tick_replayer_bitstreams/20260707_stream_ring_pipeline_2bank_timing_clean/
```

构建配置：

```bash
TRAFFIC_REPLAY_PORT_COUNT=1
TRAFFIC_REPLAY_DDR_BANKS=2
TRAFFIC_REPLAY_PORT0_MULTI_DDR=1
TRAFFIC_REPLAY_ENABLE_RS_FEC=1
TRAFFIC_REPLAY_ENABLE_ILA=0
TRAFFIC_REPLAY_IMPL_STRATEGY=Performance_ExplorePostRoutePhysOpt
```

主要硬件修改：

- `ddr_stream_reader` 支持 `STREAM_CTRL[1]` 打开双 DDR bank ping-pong ring。
- `DESC_BASE` 在 `STREAM` 模式下作为 bank0 ring base。
- `DATA_BASE` 在 `STREAM` 模式下复用为 bank1 ring base。
- `STREAM` ring 的发 AR 逻辑拆成 `issue_window` 和 `issue_metrics` 两级，减少
  `PL_SCAN/PL_AR` 组合路径。
- ping-pong bank 选择由递增状态维护，不再在关键路径上重复计算大位宽取模。

时序结果：

```text
post-place WNS = +0.059 ns
post-route WNS = +0.009 ns
post-route WHS = +0.010 ns
TNS/THS = 0
```

结论：这版是 timing-clean release，可上板继续测试。

## 2. 仿真与基础验证

远程 Vivado 仿真：

```text
run_stream_ring_reader_sim.tcl
  PASS staged ring waits for writes and EOF
  PASS wrap without cross-boundary bursts
  PASS ping-pong bank0/bank1 alternation
  PASS reject non-power-of-two ping-pong segment
  PASS invalid ring size, pointer regression, overrun errors

run_stream_ring_reader_perf_sim.tcl
  PASS beats=512 ar_count=32 max_req_count=29 output_cycles=1318

run_sim.tcl
  PASS invalid ring-stream config stops cleanly
  PASS DDR ring-stream replay waited and emitted 2 packets
  PASS DDR preload replay emitted 3 packets
```

上板后 PCIe/XDMA 重新枚举成功，`/dev/xdma0_h2c_0`、`/dev/xdma0_c2h_0`、
`/dev/xdma0_user` 均恢复。

DDR H2C/C2H 读回校验覆盖 bank0 和 bank1：

```text
PASS addr=0x00000000 size=4096
PASS addr=0x00100000 size=1048576
PASS addr=0x400000000 size=4094096
PASS addr=0x400100000 size=1048576
```

## 3. 纯 H2C 写入上限

命令：

```bash
sudo /home/user/traffic_replay_software/xdma_h2c_bench \
  --addr 0x80000000 --bytes 0x100000000 --chunk-bytes 0x10000000 --threads 1

sudo /home/user/traffic_replay_software/xdma_h2c_bench \
  --addr 0x400000000 --bytes 0x100000000 --chunk-bytes 0x10000000 --threads 1

sudo /home/user/traffic_replay_software/xdma_h2c_bench \
  --addr 0x300000000 --bytes 0x200000000 --chunk-bytes 0x10000000 --threads 2
```

结果：

| Case | Throughput |
| --- | ---: |
| bank0 单线程 H2C | `48.868Gbps` |
| bank1 单线程 H2C | `47.787Gbps` |
| 双线程跨 bank H2C | `70.792Gbps` |

结论：当前 memory-mapped XDMA H2C 单通道用户态 `pwrite()` 路径，双线程可以到
约 `70Gbps`，但还不是 `100Gbps` 数据源。要让无限长 `STREAM` 动态回放达到
`100Gbps`，仍需要 QDMA/XDMA AXI4-Stream H2C、多 DMA queue、pinned hugepage
或内核态/DPDK 风格提交路径。

## 4. 软件优化

本轮同步并编译了新版 `xdma_stream_ring_fast`：

- 支持 `--pingpong` 和 `--pingpong-bank1-base`。
- 支持 striped direct-copy：多个 reader 读取 SSD lane block，多个 worker 直接
  写 `/dev/xdma0_h2c_0`，`STREAM_WR_PTR` 仍按 `block_id` 顺序推进。
- 支持 per-lane container stripe：每个 SSD lane 一个大文件，block list 记录
  `file_offset`，避免大量小文件造成的文件系统开销。
- `stream_stripe.py` 新增 `--container-files`。
- `stream_stripe.py` 新增 `--override-gap-ticks`，仅用于合成压力测试时重写 stream
  record header 中的 gap。

推荐 stripe 命令：

```bash
python3 /home/user/traffic_replay_software/stream_stripe.py \
  --manifest /path/to/stream_manifest.json \
  --lane-dir /mnt/ssd0/tick_lane0 \
  --lane-dir /mnt/ssd1/tick_lane1 \
  --block-bytes 65536000 \
  --container-files \
  --out-manifest /path/to/stripe_manifest.json \
  --force
```

其中 `65536000` 对 `1518B` 固定大包压力流是一个合适值：每条 stream record 为
`64 + align64(1518) = 1600B`，`65536000` 同时满足 record 对齐和 `4096B`
页对齐，适合 `O_DIRECT`。

## 5. STREAM 上板测试

### 5.1 全预填/小规模 smoke

`100000 x 1518B`，`gap=38`，双 bank ping-pong：

```text
tx_packets        : 100000
tx_bytes          : 151800000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
load_gbps         : 9.266
hw_gbps           : 95.873
```

结论：硬件 reader/scheduler/TX 路径可以按 `gap=38` 达到接近 `100Gbps` 的
大包内部吞吐；这个 case 主要是预填充分，不代表无限长动态换入上限。

### 5.2 单 stream 文件动态换入

`2M x 1518B`，`gap=80`，stream 文件 `3.2GB`，1GiB total ring：

```text
source_mode       : stream
stream_capacity   : 1073741824
committed_bytes   : 3200000000
tx_packets        : 2000000
load_gbps         : 6.401
hw_gbps           : 8.175
late_packets      : 1286969
underrun_packets  : 1251
stall_events      : 0
```

结论：旧的单 stream producer/record 打包路径太慢，不适合高带宽动态换入。

### 5.3 小文件 striped direct

同一组 `gap=80` 数据，先切成多个 64MiB block 文件，再 striped direct-copy：

```text
source_mode       : striped_direct
stream_capacity   : 1073741824
committed_bytes   : 3200000000
load_gbps         : 19.637
hw_gbps           : 24.068
late_packets      : 1417393
underrun_packets  : 882935
stall_events      : 0
```

结论：多 reader + direct H2C 能明显提升，但多小文件布局读盘效率差。

### 5.4 Container striped direct

同一组 `gap=80` 数据，改成每个 SSD lane 一个 container 文件，1GiB total ring：

```text
source_mode       : striped_direct
stream_capacity   : 1073741824
committed_bytes   : 3200000000
load_gbps         : 32.614
hw_gbps           : 41.692
late_packets      : 1330234
underrun_packets  : 4564696
stall_events      : 0
```

2GiB total ring、预填接近满水位：

```text
stream_capacity   : 2147483648
load_gbps         : 35.155
hw_gbps           : 45.540
tx_packets        : 2000000
tx_bytes          : 3036000000
stall_events      : 0
```

结论：container stripe 明显更好。`gap=80` 的理论 L2 吞吐是：

```text
1518 * 8 / (80 / 300e6) = 45.540Gbps
```

这版已经可以把平均吞吐推到理论值附近，但仍出现 late/underrun，说明动态补给在
短时仍低于 `gap=80` 需要的 stream 消费速率，调度精度不能算通过。

### 5.5 动态安全点

复用相同 payload，仅把 stream header gap 重写为 `120 ticks`：

```text
source_mode       : striped_direct
stream_capacity   : 1073741824
committed_bytes   : 3200000000
tx_packets        : 2000000
tx_bytes          : 3036000000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
load_gbps         : 30.205
hw_gbps           : 30.360
```

`gap=120` 的理论 L2 吞吐：

```text
1518 * 8 / (120 / 300e6) = 30.360Gbps
```

结论：在当前远程主机、当前文件布局和 XDMA memory-mapped loader 下，`30Gbps`
级别的大包动态 stream replay 可以做到 `late=0`、`underrun=0`。继续压到
`gap=80` 时平均吞吐能上去，但调度精度还不能保证。

## 6. 当前瓶颈

当前瓶颈分层如下：

1. `PRELOAD` 或 `STREAM` 全预填时，瓶颈主要在 FPGA TX 调度与 CMAC 侧；大包可到
   `95.873Gbps`。
2. 无限长/远大于 DDR 的 `STREAM` 动态模式，瓶颈主要在
   `SSD -> host memory -> XDMA H2C -> FPGA DDR ring`。
3. 纯 H2C 双线程上限约 `70Gbps`，说明即使 SSD 足够快，当前 memory-mapped XDMA
   提交路径也不是 `100Gbps` 级持续数据源。
4. 本轮真实文件读取存在明显波动。container stripe 比小文件 stripe 更好，但两个
   挂载点的冷态读取经常只有十几到三十几 Gbps。根盘已接近满盘，会影响测试稳定性。

## 7. 后续建议

- 保留 container stripe 作为默认双 SSD 输入布局。
- 若要继续逼近 `100Gbps` 动态换入，优先升级 host-to-FPGA 数据通路：
  QDMA/XDMA AXI4-Stream H2C、多 queue、pinned hugepage、内核态提交或 DPDK 风格
  zero-copy pipeline。
- 若继续使用 memory-mapped XDMA，建议增加多 H2C channel 或拆成多个 XDMA function；
  单 `/dev/xdma0_h2c_0` 很难稳定喂满 `100Gbps`。
- 远程主机根盘已接近满盘，后续严肃测速应清理空间，或把两个 lane 放在两块健康、
  空闲、连续空间充足的 NVMe 上。
- `gap=80` 能平均发完但 late/underrun 高，应作为 overrate/robustness case，而不是
  精度通过 case。
