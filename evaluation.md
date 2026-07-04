# Tick_Replayer 板上评测报告

## 2026-07-04 增量评测：RX 调度精度、stream 装载上限与当前限制

本节记录在 `rxgap_precision_stream_loader_20260704` 这一轮上板后的增量结论。硬件 bitstream 基于当前双端口工程生成，新增了 RX 侧 SOP-to-SOP gap 统计寄存器，用来从接收端真实观测 `preload` 回放间隔；stream 部分只改 host loader 软件，不改变 FPGA 数据通路和时序。

### 0. 资源、时序和当前版本状态

当前实现报告来自：

```text
/home/user/traffic_replay_rxgap_20260704_src/reports/hw_impl_timing_summary.rpt
/home/user/traffic_replay_rxgap_20260704_src/reports/hw_impl_utilization.rpt
```

资源占用如下：

| 资源 | 使用量 | 总量 | 占比 |
| --- | ---: | ---: | ---: |
| `CLB LUTs` | `135886` | `1182240` | `11.49%` |
| `CLB Registers` | `139967` | `2364480` | `5.92%` |
| `Block RAM Tile` | `531.5` | `2160` | `24.61%` |
| `URAM` | `0` | `960` | `0.00%` |
| `DSPs` | `3` | `6840` | `0.04%` |
| `PLL` | `3` | `60` | `5.00%` |
| `MMCM` | `2` | `30` | `6.67%` |

时序已经收敛：

```text
WNS(ns)  TNS(ns)  TNS Failing Endpoints  WHS(ns)  THS(ns)
  0.024    0.000                      0    0.001    0.000
All user specified timing constraints are met.
```

本轮时序优化/保持方式：

- `preload` 发送主路径继续保持 300 MHz：descriptor/payload 读取、调度、packet engine 和 AXI-Stream FIFO 之间用分级流水和 FIFO 解耦，减少跨模块组合回压。
- DDR 读路径已经做过 register slice / prefetch / FIFO 化，避免 `AR` 发起、payload 扫描和 CMAC 发送直接形成长组合路径。
- 新增 RX gap 统计放在 CMAC RX 时钟域，只做 SOP 间隔计数；AXI-Lite 侧读取的是同步后的统计值，避免把 RX 统计逻辑接进 300 MHz TX 临界路径。
- stream loader 的优化均在 host 软件中完成，不会影响 bitstream 的 timing。

当前 limitations：

- `stream ring buffer` 的动态装载吞吐还没有接近 100 Gbps，瓶颈在 host loader + memory-mapped XDMA char-device + SSD/主机内存拷贝路径。
- 当前 bitstream 只使用一组 DDR4/MIG 作为 replay/capture 缓存，尚未把 U200 的 4 组 DDR4 全部打开成 64 GB 可用空间。
- RX 侧调度精度目前是 aggregate 统计：`count/min/max/last/sum/avg`，还不是每个包 timestamp 的完整 trace buffer。
- 动态 100 Gbps 需要 QDMA 或 XDMA AXI4-Stream H2C、多队列/多通道、pinned hugepage 或内核态 loader，以及 FPGA 侧更深 stream prefetch；这不是当前 timing-clean bitstream 的小修小补。

### 1. preload 模式真实调度精度测试

测试方法：用 QSFP 光纤将 TX0 回环到 RX1，在 RX 侧新增 SOP-to-SOP gap 统计。TX 侧仍按 `preload` descriptor 中的 `gap_ticks` 调度，RX 侧在 CMAC RX 时钟域计数，因此它测到的是“包真正从线侧回到接收端后的间隔”，不是单纯读取 TX 寄存器。

命令示例：

```bash
cd /home/user/traffic_replay_software
python3 preload_rx_precision_check.py \
  --tx-port 0 --rx-port 1 \
  --frame-len 64 --packet-count 1000 --gap-ticks 3000 \
  --tx-tick-hz 300000000 --rx-tick-hz 322265625 \
  --max-error-rx-cycles 16

python3 preload_rx_precision_check.py \
  --tx-port 0 --rx-port 1 \
  --frame-len 64 --packet-count 2000 --gap-ticks 300 \
  --tx-tick-hz 300000000 --rx-tick-hz 322265625 \
  --max-error-rx-cycles 16
```

结果摘要：

```text
### preload rx precision gap3000 64B
expected_rx_gap   : 3222.656250
packet_count      : 1000
tx_packets        : 1000
rx_packets        : 1000
drop_packets      : 0
late_packets      : 0
underrun_packets  : 0
rx_errors         : 0
rx_gap_count      : 999
rx_gap_min        : 3220
rx_gap_max        : 3225
rx_gap_avg        : 3222.655656
rx_gap_min_error  : -2.656250 cycles (-8.242 ns)
rx_gap_max_error  : 2.343750 cycles (7.273 ns)
rx_gap_avg_error  : -0.000594 cycles (-0.002 ns)
PASS: RX-side SOP gap statistics match requested PRELOAD spacing

### preload rx precision gap300 64B
expected_rx_gap   : 322.265625
packet_count      : 2000
tx_packets        : 2000
rx_packets        : 2000
drop_packets      : 0
late_packets      : 0
underrun_packets  : 0
rx_errors         : 0
rx_gap_count      : 1999
rx_gap_min        : 318
rx_gap_max        : 326
rx_gap_avg        : 322.265133
rx_gap_min_error  : -4.265625 cycles (-13.236 ns)
rx_gap_max_error  : 3.734375 cycles (11.588 ns)
rx_gap_avg_error  : -0.000492 cycles (-0.002 ns)
PASS: RX-side SOP gap statistics match requested PRELOAD spacing
```

结论：

- `gap=3000` 和 `gap=300` 两组都没有 TX drop、late、underrun，也没有 RX error。
- RX 侧平均 gap 误差接近 `0 ns`；min/max 抖动在约 `±14 ns` 以内。
- 这里的 min/max 包含 TX 300 MHz tick 到 CMAC RX 时钟域的跨域观测、CMAC/光纤回环路径以及统计采样误差；平均值更能反映调度器长期精度。

### 2. stream 模式装载速率、平台上限和本轮实现

本轮对 `xdma_stream_ring_fast` 保留了一类 correctness-safe 的 host 侧优化：

- 固定长度 stream manifest fast path：当 `manifest.json` 中有 `frame_len` 且 `stream_bytes == packet_count * record_len` 时，loader 按固定 `record_len = 64B header + aligned payload` 切 batch，不再逐包扫描 header。

raw 平台能力先分开测量：

```text
XDMA H2C raw, addr=0x80000000, total=8GiB, threads=2:
throughput_gbps   : 83.675

同一 stream 文件 cached read:
cached_read_elapsed=0.20    # 1.6GB，约 64Gbps

同一 stream 文件 direct read:
direct_read_elapsed=0.54    # 1.6GB，约 23.7Gbps

同一 DDR 地址 raw H2C, addr=0x40000000, total=1.6GB:
threads=1 throughput_gbps   : 51.157
threads=2 throughput_gbps   : 64.305

两块 SSD 并发 direct read, 4GiB + 4GiB:
concurrent_read_gbps=53.891
```

因此这个平台的理论/实测边界可以分三层看：

| 路径 | 上限/实测 | 说明 |
| --- | ---: | --- |
| PCIe Gen3 x16 编码后理论 | 约 `126 Gbps` | 128b/130b 后的物理上界，不等于应用可达 |
| 当前 XDMA memory-mapped H2C raw | 约 `84 Gbps` | host DRAM 中已有数据时的长时间实测上限 |
| 两块 SSD 并发 direct read | 约 `54 Gbps` | 从 SSD 持续读原始数据时的存储侧实测上限 |
| 当前 stream loader 端到端 | 最终实测 `12.956 Gbps` | 读 `stream.bin`、切 record、写 XDMA H2C、推进 ring pointer 的整体速度 |

优化前后对比：

```text
优化前，有限 buffer 预填 1.6GB stream:
load_gbps         : 12.817

固定 record fast path:
load_gbps         : 13.134

最终保留版本，重新烧录并恢复 XDMA 后复测:
load_gbps         : 12.956
```

真正动态 ring overrate 测试：

```text
frame_len         : 1518
packet_count      : 1000000
ring_size         : 536870912
gap_ticks         : 38
committed_bytes   : 1600000000
tx_packets        : 1000000
tx_bytes          : 1518000000
late_packets      : 975434
underrun_packets  : 2676
load_gbps         : 1.397
hw_gbps           : 0.905
```

解释：

- 有限 buffer/no-wait 测的是“loader 能多快把 stream 记录写入 FPGA DDR ring”，当前最终实测约 `13.0 Gbps`。
- 动态 overrate 测的是“FPGA 一边接近 100G 消费、一边 host 往小 ring 里补数据”的真实模式。因为 loader 远低于 100G，ring 很快被读空，随后进入 late/underrun，整体有效回放速率降到约 `1 Gbps` 量级。
- 在不改 DMA 接口形态的前提下，继续优化 userspace loader 预计最多接近 raw XDMA 与 SSD 读速的较小值：host DRAM 缓存场景上界约 `80Gbps`，双 SSD 持续供数场景上界约 `50Gbps`。当前 `13Gbps` 说明仍有软件路径优化空间，但单靠 memory-mapped `/dev/xdma0_h2c_0` + 普通文件读写，很难保证 100Gbps 动态装载。
- 想让 stream ring buffer 真正逼近 100Gbps，建议下一阶段改 QDMA/AXI4-Stream H2C 或至少多 XDMA H2C channel + pinned hugepage + io_uring/direct I/O + kernel bypass loader；FPGA 侧也需要把 stream reader 做成更深 prefetch 和多 outstanding。

### 3. DDR 64GB 是否能全部开启

U200 板卡物理上有 4 组 DDR4，总容量 64GB；当前工程为了先把 CMAC/XDMA/调度器/loopback 跑通，只打开了一组 DDR4/MIG，因此当前 replay/cache 的真实可用空间按单 bank 设计，约 16GB 地址空间内规划 descriptor、payload、stream ring 和 RX sample。

能不能全部打开：可以，但不建议在当前 timing-clean release 上直接硬改。

需要做的事情：

- 在 BD/Tcl 中实例化 4 个 DDR4/MIG 控制器，并接入各自的板级引脚/参考时钟/复位约束。
- 设计地址映射：按高地址 bit 选择 bank，或者做 stripe/interleave。`preload` 大 trace 更适合顺序 bank window；stream ring 更适合固定 bank 或按大块切换。
- 修改 XDMA M_AXI 到 DDR 的 SmartConnect/interconnect，让 host 能访问 64GB 地址空间。
- 修改 replay reader，让 descriptor/payload/ring 地址能跨 bank，或者先约束每个 trace segment 不跨 bank。
- 重新跑仿真、综合、实现和上板 H2C/C2H 全地址回读；4 MIG 会显著增加布线和时钟资源压力，可能破坏当前 `WNS=+0.024ns` 的余量。

结论：64GB 是下一阶段架构升级项，不应该和当前 RX 精度统计、stream loader 软件优化混在同一个 release 里做。当前 release 保持单 DDR bank，是为了不影响已验证的 preload/loop/stream 基础功能和 300MHz timing。

### 4. 本轮未完成工作

- stream ring buffer 仍未达到 100Gbps；当前实现已经更鲁棒，但动态装载吞吐受 host loader 和 XDMA memory-mapped 路径限制。
- RX 调度精度目前只有 aggregate gap 统计，后续可以增加 RX timestamp ring，把每个包的 SOP tick、len、hash 写入 DDR，host 再读回做完整分布统计。
- 64GB DDR 尚未打开；需要新分支单独做多 MIG 地址空间和 timing 收敛。
- 并行 pwrite、aligned DMA buffer、no-zero buffer 等激进 host loader 优化做过探索，但完整 stream safe case 发现会破坏回放正确性或触发 XDMA 异常，因此没有保留。后续应转向经过正确性验证的 pinned reusable buffers、direct I/O、io_uring、QDMA streaming H2C 或内核态 loader。
- 本轮极限/错误 stream 测试曾让 XDMA `C2H0-MM` 进入 BUSY timeout；最终通过重新烧录 bitstream、PCIe remove/rescan 和 chmod 设备节点恢复。后续需要把这类恢复步骤脚本化，或者在硬件/驱动侧增加更干净的 DMA channel reset。

本文记录当前 `timing10_ddr_regslice_20260704` bitstream 在远程 U200 板卡上的完整板上评测结果。测试覆盖 `preload`、`loop`、`stream ring buffer` 三种回放模式，以及 `XDMA H2C/C2H`、AXI-Lite 控制平面热刷新、TX/RX 光纤回环、过载鲁棒性、调度 tick 精度和可回放 trace 容量边界。

测试没有重新烧录 bitstream；所有模式切换、清空、重新装载和启动都通过 `/dev/xdma0_user` 暴露的 AXI-Lite 寄存器完成。

## 1. 测试对象

| 项目 | 内容 |
| --- | --- |
| 远程主机 | `FNIL-2022DEC-GPU-3` |
| OS | Ubuntu 20.04, Linux `5.15.0-139-generic` |
| FPGA 板卡 | Xilinx Alveo U200 |
| PCIe 设备 | `10ee:903f` |
| XDMA 设备 | `/dev/xdma0_h2c_0`, `/dev/xdma0_c2h_0`, `/dev/xdma0_user` |
| bitstream | `/home/user/tr_build_bugfix_timing10_ddr_regslice_20260704/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.bit` |
| bitstream SHA256 | `be1ccb31778bae73bd896fad90050a2ccf7571bea9471e67ff389a8b5168e0c9` |
| 测试软件目录 | `/home/user/traffic_replay_software` |
| 本轮原始日志 | 本地 `reports/eval_20260704_timing10_full/raw_remote.log`，远程数据目录 `/home/user/tick_eval_20260704_timing10_full` |

环境枚举输出：

```text
$ date; hostname; uname -a; lspci -nn -d 10ee:; ls -l /dev/xdma*; sha256sum traffic_replay_bd_wrapper.bit
2026年 07月 04日 星期六 07:04:08 CST
FNIL-2022DEC-GPU-3
Linux FNIL-2022DEC-GPU-3 5.15.0-139-generic #149~20.04.1-Ubuntu SMP Wed Apr 16 08:29:56 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux
01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]
crw-rw-rw- 1 root root 505, 36 7月   4 05:20 /dev/xdma0_c2h_0
crw-rw-rw- 1 root root 505, 32 7月   4 05:20 /dev/xdma0_h2c_0
crw-rw-rw- 1 root root 505,  0 7月   4 05:20 /dev/xdma0_user
be1ccb31778bae73bd896fad90050a2ccf7571bea9471e67ff389a8b5168e0c9  traffic_replay_bd_wrapper.bit
```

Vivado routed timing 已收敛：

```text
WNS(ns)  TNS(ns)  TNS Failing Endpoints  WHS(ns)  THS(ns)
  0.024    0.000                      0    0.010    0.000
All user specified timing constraints are met.
```

## 2. 总体结论

| 测试项 | 结论 | 关键结果 |
| --- | --- | --- |
| H2C/C2H DDR 读回 | 通过 | 多地址 deterministic pattern 全部读回一致 |
| AXI-Lite 热刷新 | 通过 | `write-reg/read-reg/clear/start` 可在不重烧 bitstream 的情况下刷新配置 |
| `preload` 小包 | 通过 | `64B gap=3`，`70.399Gbps wire`，`drop/late/underrun/stall=0` |
| `preload` 中包 | 通过 | `512B gap=13`，`98.953Gbps wire`，无丢包 |
| `preload` 大包 | 通过 | `1518B gap=38`，`97.389Gbps wire`，无丢包 |
| `preload` mixed | 通过 | `64:3,1518:38` 交错，`95.413Gbps wire`，无丢包 |
| `loop` 有限循环 | 通过 | `5000` 包循环 `4` 次，`tx_packets=20000`，无丢包 |
| `loop` 稳定性 | 通过 | `6,000,000` 包、约 `60s`、`loop_gap=1000` 时 `drop/late/underrun/stall=0` |
| `stream ring` 功能 | 通过 | `320MB` stream 使用 `16MB` FPGA DDR ring 动态换入换出完成 |
| `stream ring` 当前性能 | 低于目标 | 当前 C++ loader 在本机实测约 `0.8-1.0Gbps` 级别，瓶颈在 host loader/ring 装载 |
| TX/RX 数据通路 | 通过 | `TX0->RX1 64B` 和 `TX1->RX0 1518B` sample payload 均匹配 |
| `gap=0` 过载 | 鲁棒但非无损 | 会产生 `late/drop/stall` 计数，但不会死机，随后可 clear 并恢复 no-drop preload |

## 3. H2C/C2H DDR 读回校验

目的：验证 Host 通过 XDMA H2C 写入 FPGA DDR 后，可以通过 XDMA C2H 按地址读回一致数据。

命令：

```bash
python3 ddr_readback_check.py \
  --repeat 2 \
  --case 0x00000000:0x1000 \
  --case 0x00100000:0x10000 \
  --case 0x10000000:0x100000 \
  --case 0x40000000:0x400000
```

结果：

```text
PASS addr=0x00000000 size=4096 repeat=0 h2c=0.443Gbps c2h=0.695Gbps
PASS addr=0x00100000 size=65536 repeat=0 h2c=5.825Gbps c2h=3.439Gbps
PASS addr=0x10000000 size=1048576 repeat=0 h2c=8.137Gbps c2h=5.087Gbps
PASS addr=0x40000000 size=4194304 repeat=0 h2c=14.680Gbps c2h=4.748Gbps
PASS addr=0x00000000 size=4096 repeat=1 h2c=0.493Gbps c2h=0.080Gbps
PASS addr=0x00100000 size=65536 repeat=1 h2c=5.574Gbps c2h=12.391Gbps
PASS addr=0x10000000 size=1048576 repeat=1 h2c=43.810Gbps c2h=6.034Gbps
PASS addr=0x40000000 size=4194304 repeat=1 h2c=14.521Gbps c2h=5.427Gbps
SUMMARY cases=4 repeat=2 checked_bytes=10625024 aggregate_rw=0.082Gbps
```

说明：

- 这个测试是正确性测试，不是吞吐极限测试；小块读写和 Python pattern 生成会显著影响显示的平均速率。
- 结果证明 `XDMA H2C -> DDR -> XDMA C2H` 数据通路可用，没有发现地址错位或数据损坏。

## 4. AXI-Lite 控制平面热刷新

目的：验证不重新烧录 bitstream，仅通过 AXI-Lite 寄存器即可清空、改配置、重新启动。

命令：

```bash
python3 traffic_replay_cli.py --port 0 clear
python3 traffic_replay_cli.py --port 0 write-reg 0x4c 0x1234
python3 traffic_replay_cli.py --port 0 read-reg 0x4c
python3 traffic_replay_cli.py --port 0 write-reg 0x4c 0x1000
python3 traffic_replay_cli.py --port 0 read-reg 0x4c
python3 traffic_replay_cli.py --port 0 regs | sed -n '1,22p'
```

结果：

```text
0x0004c: 0x00001234
0x0004c: 0x00001000
0x00000 CONTROL        0x00000000
0x00004 MODE           0x00000000
0x00008 STATUS         0x00000030
0x00010 DESC_BASE_LO   0x04000000
0x00018 DATA_BASE_LO   0x14000000
0x00028 PKT_LO         0x0000012c
0x00048 RATE           0x00010000
0x0004c WATERMARK      0x00001000
0x00054 DEBUG_CTRL     0x00000004
0x00060 TX_PKTS_LO     0x00000000
```

结论：

- `WATERMARK` 可写可读，并且可恢复默认值。
- `clear` 后 TX 计数器归零。
- 后续测试在同一个 bitstream 上连续切换 `preload -> loop -> stream ring -> preload -> RX loopback`，没有重烧 FPGA。

## 5. Preload 模式性能与正确性

### 5.1 单端口安全速率 sweep

命令：

```bash
python3 preload_stress_test.py \
  --port 0 \
  --packet-count 100000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_safe_p0 \
  --csv /home/user/tick_eval_20260704_timing10_full/preload_safe_p0.csv \
  --timeout 90 \
  --require-no-drop \
  --case 64:3 \
  --case 512:13 \
  --case 1518:38
```

结果：

```text
case frame_len=64 gap=3 done=True tx=100000 drop=0 delivered_est=100000 late=0 underrun=0 stall=0 l2=51.199Gbps wire=70.399Gbps load=7.365Gbps
case frame_len=512 gap=13 done=True tx=100000 drop=0 delivered_est=100000 late=0 underrun=0 stall=0 l2=94.522Gbps wire=98.953Gbps load=9.398Gbps
case frame_len=1518 gap=38 done=True tx=100000 drop=0 delivered_est=100000 late=0 underrun=0 stall=0 l2=95.873Gbps wire=97.389Gbps load=10.317Gbps
```

结论：

- 当前 preload 模式下，大包和中包已经接近 100Gbps 线速。
- 64B 小包的安全点是 `gap=3`，对应约 `70.399Gbps wire`。这是整数 tick 调度的结果：`64B` 帧的 wire 字节按 `64+24` 估算，`300MHz / 3 ticks` 对应约 `70.4Gbps`；若强行 `gap=2`，目标 wire rate 会超过 100Gbps，容易进入 overrate。

### 5.2 双端口基本可用性

命令：

```bash
python3 preload_stress_test.py \
  --port 1 \
  --desc-base 0x06000000 \
  --data-base 0x18000000 \
  --packet-count 50000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_safe_p1 \
  --csv /home/user/tick_eval_20260704_timing10_full/preload_safe_p1.csv \
  --timeout 90 \
  --require-no-drop \
  --case 64:3 \
  --case 1518:38
```

结果：

```text
case frame_len=64 gap=3 done=True tx=50000 drop=0 delivered_est=50000 late=0 underrun=0 stall=0 l2=51.199Gbps wire=70.398Gbps load=7.251Gbps
case frame_len=1518 gap=38 done=True tx=50000 drop=0 delivered_est=50000 late=0 underrun=0 stall=0 l2=95.872Gbps wire=97.388Gbps load=10.583Gbps
```

结论：port1 的 preload TX 数据路径和 port0 同级别，至少在单端口分时测试中表现一致。

### 5.3 大小包 mixed 回放

命令：

```bash
python3 preload_mixed_test.py \
  --port 0 \
  --packet-count 100000 \
  --pattern 64:3,1518:38 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_mixed \
  --csv /home/user/tick_eval_20260704_timing10_full/preload_mixed.csv \
  --timeout 90 \
  --require-no-drop
```

结果：

```text
mixed port=0 pattern=64:3,1518:38 packets=100000 done=True tx=100000 drop=0 late=0 underrun=0 stall=0 ticks=2050027 expected_ticks=2050000 tick_error=27 l2=92.604Gbps wire=95.413Gbps load=11.366Gbps
```

结论：

- 混合包长不是分别跑两组，而是交错生成 descriptor/data。
- 当前 mixed case 可以稳定达到约 `95.413Gbps wire`，并保持 `drop=0 late=0 underrun=0 stall=0`。

## 6. 调度 tick 精度

当前硬件使用 `300MHz` tick。Host 侧提前把 pcap 包间隔换算成 `gap_ticks` 写入 descriptor；FPGA scheduler 按 descriptor 的 gap 逐包调度。

严格 0 tick 误差测试：

```bash
python3 preload_precision_check.py \
  --port 0 \
  --packet-count 50000 \
  --pattern 64:3,1518:38 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_precision \
  --timeout 90 \
  --max-abs-tick-error 0
```

结果：

```text
packet_count      : 50000
completed         : True
tx_packets        : 50000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
expected_ticks    : 1025000
debug_ticks       : 1025027
tick_error        : 27
FAIL: scheduler precision check failed
```

允许固定管线偏移后：

```bash
python3 preload_precision_check.py \
  --port 0 \
  --packet-count 50000 \
  --pattern 64:3,1518:38 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_precision_allow32 \
  --timeout 90 \
  --max-abs-tick-error 32
```

结果：

```text
expected_ticks    : 1025000
debug_ticks       : 1025027
tick_error        : 27
PASS: scheduler debug_ticks matches descriptor gap_ticks budget
```

解释：

- `27 ticks` 在 `300MHz` 下约为 `90ns`。
- 该误差在 mixed `100000` 包测试中仍为 `27 ticks`，表现为固定管线 flush/start-stop 偏移，而不是随包数增长的 per-packet 漂移。
- 目前这个测试验证的是 FPGA scheduler 内部 tick accounting。若要验证真实线侧包间隔，需要在 RX 侧增加 per-packet timestamp，或用 ILA/外部仪表捕获 CMAC TX/RX 边界。

## 7. Loop 模式

### 7.1 有限循环功能测试

命令：

```bash
python3 gen_synthetic_trace.py \
  --out-dir /home/user/tick_eval_20260704_timing10_full/loop_trace \
  --packet-count 5000 \
  --frame-len 512 \
  --gap-ticks 13

python3 xdma_load_trace.py \
  --manifest /home/user/tick_eval_20260704_timing10_full/loop_trace/manifest.json \
  --port 0 \
  --desc-base 0x02000000 \
  --data-base 0x12000000 \
  --mode loop \
  --loop-count 4 \
  --loop-gap 1000 \
  --auto-drop \
  --clear-force-tx-ready
```

结果：

```text
mode              : loop
running           : no
done              : yes
tx_packets        : 20000
tx_bytes          : 10240000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
debug_ticks       : 262972
```

结论：`loop-count=4` 按预期把 `5000` 包 trace 发送了 `4` 轮，总包数 `20000`，无丢包、无 underrun、无 stall。

### 7.2 Loop 稳定性测试

命令：

```bash
python3 gen_synthetic_trace.py \
  --out-dir /home/user/tick_eval_20260704_timing10_full/loop_stability_gap1000 \
  --packet-count 1000 \
  --frame-len 64 \
  --gap-ticks 3000

python3 xdma_load_trace.py \
  --manifest /home/user/tick_eval_20260704_timing10_full/loop_stability_gap1000/manifest.json \
  --port 0 \
  --desc-base 0x07000000 \
  --data-base 0x17000000 \
  --mode loop \
  --loop-count 6000 \
  --loop-gap 1000 \
  --auto-drop \
  --clear-force-tx-ready
```

结果：

```text
mode              : loop
running           : no
done              : yes
late              : no
underrun          : no
tx_packets        : 6000000
tx_bytes          : 384000000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
drop_beats        : 0
stall_events      : 0
debug_ticks       : 17988002004
```

补充观察：

- `loop_gap=0` 的 3 分钟测试也没有 `drop/underrun/stall`，但每轮边界出现 1 个 late，`loop-count=18000` 时 `late_packets=17999`。
- 因此 loop 模式建议配置非零 `loop_gap`，为每轮 trace 的 descriptor/payload 重启提供边界裕量。

## 8. Stream Ring Buffer 模式

当前 stream 模式只保留 DDR ring-buffer 路径：Host 持续把 stream record 写入 FPGA DDR ring，FPGA 从 ring 中解析 descriptor/payload 并调度发包。

### 8.1 错误 ring 参数拒绝

当 `batch_bytes + guard_bytes > ring_size` 时，C++ loader 会拒绝启动，防止 Host 撑爆 ring。

```text
ERROR: --batch-bytes plus --guard-bytes must fit in the ring
ring stream replay failed for frame_len=64 with exit=1
```

这说明 loader 侧的 ring 参数保护有效。

### 8.2 64B stream safe case

首次使用 `start-time=0` 时出现 `late_packets=1`，这是首包立即调度的启动边界效应：

```text
frame_len=64 gap_ticks=100
completed=true
tx_packets=100000
late_packets=1
underrun_packets=0
load_gbps=5.758
hw_gbps=1.536
```

补充直接调用 C++ loader，并设置 `--start-time 10000`：

```bash
./xdma_stream_ring_fast \
  --port 0 \
  --manifest /home/user/tick_eval_20260704_timing10_full/stream_safe_64_gap100/len64_pkts100000_gap100/stream_manifest.json \
  --ring-base 0x24000000 \
  --ring-size 0x02000000 \
  --prefill-bytes 0x01000000 \
  --guard-bytes 0x00100000 \
  --batch-bytes 0x00800000 \
  --read-bytes 0x00800000 \
  --queue-depth 4 \
  --watermark 4096 \
  --timeout 90 \
  --feed-timeout 90 \
  --start-time 10000
```

结果：

```text
completed         : true
tx_packets        : 100000
tx_bytes          : 6400000
late_packets      : 0
underrun_packets  : 0
stream_status     : 0x000003a5
max_ring_level    : 8388608
min_ring_free     : 24117248
load_gbps         : 5.586
hw_gbps           : 1.534
```

### 8.3 1518B stream safe case

命令：

```bash
python3 stream_stress_test.py \
  --port 0 \
  --frame-sizes 1518 \
  --packet-count 100000 \
  --gap-ticks 5000 \
  --ring-base 0x24000000 \
  --ring-size 0x02000000 \
  --prefill-bytes 0x01000000 \
  --batch-bytes 0x00800000 \
  --read-bytes 0x00800000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/stream_safe_1518_gap5000 \
  --csv /home/user/tick_eval_20260704_timing10_full/stream_safe_1518_gap5000.csv \
  --timeout 120 \
  --feed-timeout 120
```

结果：

```text
committed_bytes   : 160000000
committed_packets : 100000
completed         : true
tx_packets        : 100000
tx_bytes          : 151800000
late_packets      : 0
underrun_packets  : 0
stream_status     : 0x000003a5
max_ring_level    : 32356160
min_ring_free     : 149696
load_gbps         : 0.947
hw_gbps           : 0.729
```

### 8.4 Trace 大于 ring 的动态换入换出

命令：

```bash
python3 stream_stress_test.py \
  --port 0 \
  --frame-sizes 1518 \
  --packet-count 200000 \
  --gap-ticks 5000 \
  --ring-base 0x24000000 \
  --ring-size 0x01000000 \
  --prefill-bytes 0x00800000 \
  --batch-bytes 0x00800000 \
  --read-bytes 0x00800000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/stream_gt_ring_gap5000 \
  --csv /home/user/tick_eval_20260704_timing10_full/stream_gt_ring_gap5000.csv \
  --timeout 160 \
  --feed-timeout 160
```

结果：

```text
ring_size         : 16777216
committed_bytes   : 320000000
committed_packets : 200000
completed         : true
tx_packets        : 200000
tx_bytes          : 303600000
late_packets      : 0
underrun_packets  : 0
stream_status     : 0x000003a5
max_ring_level    : 15575360
min_ring_free     : 153280
load_gbps         : 0.805
hw_gbps           : 0.729
```

结论：

- 本测试的 stream 文件为 `320MB`，FPGA DDR ring 只有 `16MB`，证明当前 stream ring 不是一次性 preload，而是在 Host 和 FPGA DDR 之间动态换入换出。
- 当前动态模式的实际瓶颈在 Host loader/ring 提交链路，实测 `load_gbps` 约 `0.8-1.0Gbps`，远低于 preload 模式内部回放能力。要逼近 100Gbps，需要继续升级 loader、DMA 提交方式和 FPGA 侧 ring/prefetch。

### 8.5 Stream gap=0 过载鲁棒性

命令：

```bash
python3 stream_stress_test.py \
  --port 0 \
  --frame-sizes 64 \
  --packet-count 50000 \
  --gap-ticks 0 \
  --ring-base 0x24000000 \
  --ring-size 0x01000000 \
  --prefill-bytes 0x00800000 \
  --batch-bytes 0x00800000 \
  --read-bytes 0x00800000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/stream_gap0 \
  --csv /home/user/tick_eval_20260704_timing10_full/stream_gap0.csv \
  --timeout 90 \
  --feed-timeout 90
```

结果：

```text
completed         : true
tx_packets        : 50000
tx_bytes          : 3200000
late_packets      : 50000
underrun_packets  : 0
stream_status     : 0x000003a5
load_gbps         : 3.174
hw_gbps           : 21.935
```

随后不打开 `force_tx_ready`，直接恢复 preload safe case：

```bash
python3 traffic_replay_cli.py --port 0 debug-tx-ready off
python3 preload_stress_test.py \
  --port 0 \
  --packet-count 20000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/recovery_after_stream \
  --timeout 60 \
  --require-no-drop \
  --case 64:3
```

结果：

```text
case frame_len=64 gap=3 done=True tx=20000 drop=0 delivered_est=20000 late=0 underrun=0 stall=0 l2=51.197Gbps wire=70.395Gbps load=7.291Gbps
```

结论：stream overrate 后系统可以通过正常控制面恢复，不需要重新烧录 bitstream。

## 9. Gap=0 / overrate 鲁棒性

Preload overrate 命令：

```bash
python3 preload_stress_test.py \
  --port 0 \
  --packet-count 50000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_overrate \
  --csv /home/user/tick_eval_20260704_timing10_full/preload_overrate.csv \
  --timeout 90 \
  --case 64:0 \
  --case 1518:0
```

结果：

```text
case frame_len=64 gap=0 done=True tx=50000 drop=44663 delivered_est=5337 late=50000 underrun=0 stall=14 l2=7.290Gbps wire=10.024Gbps load=6.429Gbps
case frame_len=1518 gap=0 done=True tx=50000 drop=48724 delivered_est=1276 late=50000 underrun=0 stall=32 l2=3.487Gbps wire=3.542Gbps load=15.416Gbps
```

恢复测试：

```bash
python3 traffic_replay_cli.py --port 0 debug-tx-ready off
python3 preload_stress_test.py \
  --port 0 \
  --packet-count 20000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/recovery_preload \
  --timeout 60 \
  --require-no-drop \
  --case 64:3
```

结果：

```text
case frame_len=64 gap=3 done=True tx=20000 drop=0 delivered_est=20000 late=0 underrun=0 stall=0 l2=51.197Gbps wire=70.395Gbps load=6.612Gbps
```

结论：

- `gap=0` 的意义是极限过载/鲁棒性测试，不代表正确回放能力。
- 当前系统在 overrate 下会产生 `late/drop/stall` 计数，但不会卡死。
- overrate 后无需重新烧录 bitstream，使用 AXI-Lite `clear/start` 路径即可恢复正常 preload no-drop case。

## 10. TX/RX 光纤回环正确性

当前两路 QSFP 已经光纤互联。RX 侧只做统计和 sample ring 捕获，然后 Host 通过 C2H 从 DDR 读回 sample，和 TX 侧生成的 payload 对比。

### 10.1 TX0 -> RX1，64B

命令：

```bash
python3 loopback_rx_verify.py \
  --tx-port 0 \
  --rx-port 1 \
  --packet-count 1000 \
  --frame-len 64 \
  --truncate-bytes 64 \
  --gap-ticks 2000 \
  --desc-base 0x04000000 \
  --data-base 0x14000000 \
  --rx-ring-base 0x32000000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/rx_p0_to_p1_64 \
  --timeout 90
```

结果：

```text
packet_count      : 1000
completed         : True
tx_packets        : 1000
drop_packets      : 0
late_packets      : 0
stall_events      : 0
rx_packets        : 1000
rx_bytes          : 64000
rx_errors         : 0
captured_bytes    : 64000
axi_writes        : 1000
axi_errors        : 0
write_ptr         : 64000
checked_samples   : 1000
sample_mismatches : 0
PASS: TX/RX loopback sample payloads match
```

### 10.2 TX1 -> RX0，1518B deep sample

命令：

```bash
python3 loopback_rx_verify.py \
  --tx-port 1 \
  --rx-port 0 \
  --packet-count 300 \
  --frame-len 1518 \
  --truncate-bytes 1536 \
  --gap-ticks 2000 \
  --desc-base 0x08000000 \
  --data-base 0x18000000 \
  --rx-ring-base 0x34000000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/rx_p1_to_p0_1518 \
  --timeout 90
```

结果：

```text
packet_count      : 300
completed         : True
tx_packets        : 300
drop_packets      : 0
late_packets      : 0
stall_events      : 0
rx_packets        : 300
rx_bytes          : 455400
rx_errors         : 0
captured_bytes    : 460800
axi_writes        : 7200
axi_errors        : 0
write_ptr         : 460800
checked_samples   : 300
sample_mismatches : 0
PASS: TX/RX loopback sample payloads match
```

结论：两条方向的 TX/CMAC/光纤/RX/sample writer/C2H readback 链路均通过 payload 校验，当前没有复现此前的 RX sample 错位和 overflow 迹象。

## 11. 当前最大回放容量

这里讨论的是处理后 trace 在 FPGA/Host 中的容量边界，不是原始 `.pcap` 文件字节数。当前 descriptor 固定 `64B`，payload 按 `64B` 对齐存储。

### 11.1 Preload 模式

默认软件布局：

- `desc_base = 0x00000000`
- `data_base = 0x10000000`
- descriptor 区域到 data 区域之间为 `256MiB`
- descriptor 数量上限为 `256MiB / 64B = 4,194,304` 包

因此在默认布局下：

| 包长 | 单包 trace 存储 | 默认布局包数上限 | 对应 L2 payload |
| --- | ---: | ---: | ---: |
| `64B` | `64B desc + 64B data = 128B` | `4,194,304` | 约 `256MiB` |
| `1518B` | `64B desc + 1536B data = 1600B` | `4,194,304` | 约 `5.93GiB` |

如果重新规划 `desc_base/data_base`，理论上可以把整块 U200 DDR 空间在 descriptor 和 payload 之间重新分配。以 `16GiB` DDR 估算：

| 包长 | 单包 trace 存储 | 理论包数上限 | 对应 L2 payload |
| --- | ---: | ---: | ---: |
| `64B` | `128B` | `134,217,728` | `8GiB` |
| `1518B` | `1600B` | `10,737,418` | 约 `15.18GiB` |

### 11.2 Stream Ring Buffer 模式

Stream ring 的逻辑 pcap/trace 大小不再受 FPGA DDR 总容量直接限制，而受 Host SSD 文件大小和 loader 持续供给能力限制。FPGA DDR 只保存滚动窗口。

本轮实测：

- stream 文件大小：`320,000,000B`
- FPGA DDR ring 大小：`16,777,216B`
- 结果：`committed_bytes=320000000`, `tx_packets=200000`, `late_packets=0`, `underrun_packets=0`

这证明当前 stream ring 可以回放大于 FPGA DDR ring 的 trace；但当前吞吐远低于 100Gbps，主要受 Host loader/ring 提交速度限制。

## 12. 当前瓶颈与已知限制

1. `preload` 模式的回放吞吐主要受调度 tick 和 CMAC/AXIS/LBUS 数据路径影响。当前大包接近 100Gbps，小包在 `gap=3` 下约 `70.4Gbps wire`；若继续提高小包，需要更细粒度时间表达或多包同 tick/并行调度语义，否则 `gap=2` 已经超过 100Gbps。

2. `stream ring` 模式当前瓶颈在 Host loader 到 FPGA DDR ring 的持续装载速度。本轮 C++ loader 的 `1518B` 动态回放实测 `load_gbps` 约 `0.8-1.0Gbps`，不能支撑 100Gbps 实时回放。

3. 调度精度目前只能证明 FPGA scheduler 内部 tick accounting。真实线侧精度还需要 RX timestamp 或 ILA/外部仪表测试。

4. `loop_gap=0` 时，每轮 trace 边界可能产生 1 个 late；配置 `loop_gap=1000` 后，60s loop stability 测试中 late 消失。

5. `gap=0` 是过载测试，不是正确回放配置。系统能统计 drop/stall 并恢复，但不能保证无损。

## 13. 可复现实验顺序

建议按下面顺序复现：

```bash
cd /home/user/traffic_replay_software

# 1. 基础状态
lspci -nn -d 10ee:
ls -l /dev/xdma*
python3 traffic_replay_cli.py --port 0 status

# 2. DDR H2C/C2H 正确性
python3 ddr_readback_check.py --repeat 2 \
  --case 0x00000000:0x1000 \
  --case 0x00100000:0x10000 \
  --case 0x10000000:0x100000 \
  --case 0x40000000:0x400000

# 3. Preload 大小包和 mixed
python3 preload_stress_test.py --port 0 --packet-count 100000 \
  --require-no-drop --case 64:3 --case 512:13 --case 1518:38
python3 preload_mixed_test.py --port 0 --packet-count 100000 \
  --pattern 64:3,1518:38 --require-no-drop

# 4. Loop
python3 gen_synthetic_trace.py --out-dir /tmp/loop_trace \
  --packet-count 5000 --frame-len 512 --gap-ticks 13
python3 xdma_load_trace.py --manifest /tmp/loop_trace/manifest.json \
  --port 0 --mode loop --loop-count 4 --loop-gap 1000 \
  --desc-base 0x02000000 --data-base 0x12000000 --auto-drop

# 5. Stream ring
python3 stream_stress_test.py --port 0 --frame-sizes 1518 \
  --packet-count 200000 --gap-ticks 5000 \
  --ring-base 0x24000000 --ring-size 0x01000000 \
  --prefill-bytes 0x00800000 --batch-bytes 0x00800000 \
  --read-bytes 0x00800000 --timeout 160 --feed-timeout 160

# 6. TX/RX loopback
python3 loopback_rx_verify.py --tx-port 0 --rx-port 1 \
  --packet-count 1000 --frame-len 64 --truncate-bytes 64 \
  --gap-ticks 2000 --rx-ring-base 0x32000000
python3 loopback_rx_verify.py --tx-port 1 --rx-port 0 \
  --packet-count 300 --frame-len 1518 --truncate-bytes 1536 \
  --gap-ticks 2000 --rx-ring-base 0x34000000
```
