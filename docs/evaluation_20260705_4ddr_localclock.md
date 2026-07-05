# 2026-07-05 四 DDR Bank Timing-Clean 版本上板评测

本次评测目标是验证 `TRAFFIC_REPLAY_DDR_BANKS=4` 的双端口版本是否真正可用：打开 U200 四个 DDR4 bank，拆开双端口大包回放时共享单 DDR 的瓶颈，同时确认 `PRELOAD`、`STREAM ring`、RX 回环和调度精度没有被破坏。

归档 bitstream：

```text
bitstreams/20260705_4ddr_localclock_timing_clean/traffic_replay_bd_wrapper.bit
```

详细终端日志：

```text
docs/evaluation_assets/20260705_4ddr_localclock/
```

## 1. 构建和时序

构建选项：

```bash
TRAFFIC_REPLAY_PORT_COUNT=2 \
TRAFFIC_REPLAY_DDR_BANKS=4 \
TRAFFIC_REPLAY_VIVADO_JOBS=8 \
TRAFFIC_REPLAY_IMPL_STRATEGY=Performance_ExplorePostRoutePhysOpt \
TRAFFIC_REPLAY_HW_BUILD_ROOT=/home/user/tr_build_4ddr_localclock_impl_addrinc \
vivado -mode batch -source scripts/build_hw_bitstream.tcl
```

最终时序：

```text
WNS(ns)      TNS(ns)  TNS Failing Endpoints      WHS(ns)      THS(ns)
  0.002        0.000                      0        0.005        0.000

All user specified timing constraints are met.
```

资源摘要：

```text
Block RAM Tile    : 609 / 2160, 28.19%
URAM              : 0 / 960, 0.00%
DSPs              : 12 / 6840, 0.18%
```

这版实现采用 bank-local 架构：`port0` TX 使用 `ddr4_0`，`port1` TX 使用 `ddr4_1`，`rx_cap_0` 使用 `ddr4_2`，`rx_cap_1` 使用 `ddr4_3`。每个 bank-local master 尽量运行在对应 DDR UI 时钟域中，避免一个巨大的 all-to-all DDR crossbar 造成时序和拥塞问题。`ddr_stream_reader` 中 STREAM ring 的 AXI 地址路径也从 `base + offset` 的宽组合加法改成了递增地址计数器，以去掉之前最临界的一条路径。

## 2. PCIe / XDMA 状态

烧录后设备枚举为：

```text
01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]
```

XDMA 设备节点正常生成：

```text
/dev/xdma0_h2c_0
/dev/xdma0_c2h_0
/dev/xdma0_user
```

注意：JTAG 重新烧录后，主机侧需要对 PCIe 端点做一次干净的 remove/rescan，否则可能看到 BAR 读数全为 `0xffffffff`，H2C/C2H 也可能报 XDMA error。实测执行 remove/rescan 后 BAR 和 DMA 都恢复正常。

## 3. 四 Bank DDR H2C/C2H 校验

低地址 1MiB 读写校验通过：

```text
PASS addr=0x00000000 size=1048576 repeat=0 h2c=14.025Gbps c2h=5.508Gbps
PASS addr=0x400000000 size=1048576 repeat=0 h2c=13.700Gbps c2h=6.129Gbps
PASS addr=0x800000000 size=1048576 repeat=0 h2c=14.797Gbps c2h=13.710Gbps
PASS addr=0xc00000000 size=1048576 repeat=0 h2c=17.172Gbps c2h=22.363Gbps
PASS addr=0x00000000 size=1048576 repeat=1 h2c=14.042Gbps c2h=15.380Gbps
PASS addr=0x400000000 size=1048576 repeat=1 h2c=13.751Gbps c2h=14.217Gbps
PASS addr=0x800000000 size=1048576 repeat=1 h2c=14.853Gbps c2h=35.345Gbps
PASS addr=0xc00000000 size=1048576 repeat=1 h2c=9.107Gbps c2h=22.774Gbps
```

每个 16GiB bank 末尾 4KiB 也通过，说明 64GB 地址空间高位 decode 正常：

```text
PASS addr=0x3fffff000 size=4096 repeat=0 h2c=0.514Gbps c2h=0.790Gbps
PASS addr=0x7fffff000 size=4096 repeat=0 h2c=0.786Gbps c2h=1.148Gbps
PASS addr=0xbfffff000 size=4096 repeat=0 h2c=0.792Gbps c2h=1.230Gbps
PASS addr=0xffffff000 size=4096 repeat=0 h2c=0.823Gbps c2h=1.390Gbps
```

## 4. PRELOAD 回放吞吐

单端口测试保持原有性能：

```text
port0 64B gap=3    : tx=100000 drop=0 late=0 underrun=0 stall=0 wire=70.399Gbps
port0 1518B gap=38 : tx=100000 drop=0 late=0 underrun=0 stall=0 wire=97.389Gbps
port1 64B gap=3    : tx=100000 drop=0 late=0 underrun=0 stall=0 wire=70.399Gbps
port1 1518B gap=38 : tx=100000 drop=0 late=0 underrun=0 stall=0 wire=97.389Gbps
```

双端口大包并发通过，原先共享单 DDR bank 造成的双端口大包过载问题在这版中消失：

```text
port0: tx=100000 drop=0 late=0 underrun=0 stall=0 l2=95.873Gbps wire=97.389Gbps
port1: tx=100000 drop=0 late=0 underrun=0 stall=0 l2=95.873Gbps wire=97.389Gbps
aggregate: l2=191.746Gbps wire=194.778Gbps
```

双端口小包也通过：

```text
port0: tx=100000 drop=0 late=0 underrun=0 stall=0 l2=51.199Gbps wire=70.399Gbps
port1: tx=100000 drop=0 late=0 underrun=0 stall=0 l2=51.199Gbps wire=70.399Gbps
aggregate: l2=102.399Gbps wire=140.798Gbps
```

## 5. STREAM Ring 测试

`STREAM ring` 模式功能可用，但当前正确性安全的 memory-mapped XDMA loader 仍不能支撑 100G 动态装载。稳定通过的单端口测试如下：

```text
writer_threads=2
frame_len=1518
gap_ticks=300
committed_bytes   : 480000000
committed_packets : 300000
completed         : true
tx_packets        : 300000
late_packets      : 0
underrun_packets  : 0
load_gbps         : 9.698
hw_gbps           : 12.144
```

`port1` 的 bank-local STREAM ring sanity 也通过：

```text
port1 frame_len=1518 gap_ticks=300
completed         : true
tx_packets        : 300000
late_packets      : 0
underrun_packets  : 0
load_gbps         : 10.459
hw_gbps           : 12.144
```

当把 `gap_ticks` 压到 `160/100/80/50/38` 时，trace 最终仍能发完，但出现大量 late/underrun，实际吞吐显著下降。这说明当前 STREAM 的主瓶颈仍在主机动态装载路径：host file/cache、用户态 loader、memory-mapped XDMA `pwrite()`、单 H2C engine 和 FPGA ring 消费之间的协同。四 DDR bank 解决的是 FPGA 内部并发 DDR 访问，不会把单路 XDMA memory-mapped loader 自动变成 100G 动态数据源。

## 6. TX/RX 光纤回环正确性

低速 RX sample payload 校验双向通过：

```text
tx_port           : 0
rx_port           : 1
packet_count      : 4096
tx_packets        : 4096
rx_packets        : 4096
rx_errors         : 0
axi_errors        : 0
sample_mismatches : 0
PASS: TX/RX loopback sample payloads match

tx_port           : 1
rx_port           : 0
packet_count      : 4096
tx_packets        : 4096
rx_packets        : 4096
rx_errors         : 0
axi_errors        : 0
sample_mismatches : 0
PASS: TX/RX loopback sample payloads match
```

高速 RX sample stress 使用 `256B/gap=20` 时失败，表现为 RX packet count 小于 TX packet count，sample 出现错位。这不是 TX replay 错包，而是当前 RX sample writer 的能力限制：它是轻量 debug writer，每次写一个 64B beat 并等待 AXI B 响应，不是全速抓包 DMA。因此高吞吐场景下 RX sample ring 只能作为低速/抽样正确性工具，不能当作全量包捕获器。

## 7. 调度精度回归

RX 侧 SOP-to-SOP 间隔测试全部通过：

```text
uniform_128B_gap3000      PASS  max_abs_error_ns = 7.272727
mixed_gap_128B            PASS  max_abs_error_ns = 13.284848
small_packet_small_gap    PASS  max_abs_error_ns = 8.618182
mixed_size_legal          PASS  max_abs_error_ns = 85.042424
long_uniform_128B_gap3000 PASS  max_abs_error_ns = 10.375758
```

其中 `mixed_size_legal` 的误差更大，是因为混合包长会改变 CMAC/PCS 侧的实际 SOP 间隔，RX 测到的是“线侧回来的包起点间隔”，不仅包含调度器 tick，还包含包长、AXI/CMAC 适配和跨时钟测量量化影响。该 case 的阈值设置为 `120ns`，实测仍通过。

## 8. 当前结论

- 四 DDR bank 的 64GB 地址空间已经在板上验证通过。
- 四 bank bank-local 架构 timing-clean，WNS 为 `+0.002ns`。
- 单端口 `PRELOAD` 大包/小包性能没有退化。
- 双端口同时大包近 100G 回放已经通过，aggregate wire 约 `194.8Gbps`。
- `STREAM ring` 仍是功能正确但不接近 100G 的状态，瓶颈在 host-to-FPGA 动态装载路径。
- RX sample payload 适合低速/抽样正确性验证；高速全量 RX 捕获需要另一个更强的 DMA/capture 架构。
