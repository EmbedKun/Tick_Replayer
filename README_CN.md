<div align="center">

# Tick Replayer

**基于 FPGA DDR 和硬件 tick 调度的 100G 流量回放与测量系统**

`Alveo U200` | `双 100G CMAC` | `PCIe XDMA` | `4 x DDR4` | `PCAP Replay`

[English README](README.md)

</div>

Tick Replayer 面向高速网络实验中的可重复流量回放。主机软件把 `pcap`
转换为 FPGA 可直接读取的 descriptor 和 payload，通过 PCIe XDMA 写入 FPGA
DDR；FPGA 按照每个包的 `gap_ticks` 做硬件调度，并从 100G CMAC/QSFP 端口发出。

项目名里的 `Tick` 来自软硬件之间的时间契约：主机把 pcap 时间戳量化为整数
tick，FPGA 只负责按照这些 tick 做确定性调度。默认 replay 时钟是 `300 MHz`，
因此 `1 tick = 3.333 ns`。

> **当前发布候选版本：**
> [`20260715_0754_rc5_4ddr_dual_timing_clean`](bitstreams/20260715_0754_rc5_4ddr_dual_timing_clean)。
> 这是双端口、四 DDR bank、300 MHz timing-clean 的 U200 build，已经完成
> PRELOAD、LOOP、STREAM、双端口、RX 光纤回环、RX 间隔精度和鲁棒性验证。

## 目录

- [核心能力](#核心能力)
- [实测基线](#实测基线)
- [快速开始](#快速开始)
- [系统架构](#系统架构)
- [回放模式](#回放模式)
- [容量与地址空间](#容量与地址空间)
- [Trace 格式](#trace-格式)
- [Host 软件](#host-软件)
- [构建与烧录](#构建与烧录)
- [验证](#验证)
- [仓库结构](#仓库结构)
- [当前限制](#当前限制)

## 核心能力

| 项目 | 当前设计 |
| --- | --- |
| FPGA | Xilinx Alveo U200, `xcu200-fsgd2104-2-e` |
| 以太网 | 两个 Xilinx 100G CMAC，连接 `QSFP0` 和 `QSFP1` |
| PCIe | Gen3 x16 XDMA，memory-mapped `H2C`/`C2H`，AXI-Lite user BAR |
| FPGA 内存 | 四个独立 `16 GiB` DDR4 bank，共 `64 GiB` 物理地址空间 |
| 回放模式 | `PRELOAD`、`LOOP`、有界 `STREAM` ring |
| TX 调度 | per-packet descriptor gap，共享绝对时基，可选 CMAC 时钟域 SOP release |
| RX 测量 | 包/字节/error 计数、payload sample ring、gap 统计、histogram、per-gap event ring |
| Host 入口 | 统一 Linux 命令 `tick-replay`，以及 Python/C++ 工具 |
| 鲁棒性 | stop/clear/restart、ring 越界保护、late/underrun/drop/stall 计数 |

当前归档 release 暴露一个 XDMA H2C channel：`/dev/xdma0_h2c_0`。
`TRAFFIC_REPLAY_H2C_CHANNELS=1/2/4` 仍然是可选构建参数，但 2026-07-15
归档版本优先保证双端口隔离、时序收敛和可复现实测。

## 实测基线

以下结果来自当前归档 bitstream 的真实上板测试，不是 RTL 仿真估计。

| 测试 | 实测结果 |
| --- | ---: |
| 单端口 `1518 B`、`gap=38`、`PRELOAD` | `95.873 Gbps` L2，`97.389 Gbps` wire |
| 单端口 `64 B`、`gap=3`、`PRELOAD` | `51.200 Gbps` L2，`70.400 Gbps` wire |
| 混合 `64:3,1518:38`、`PRELOAD` | `92.604 Gbps` L2，`95.414 Gbps` wire |
| 双端口 `1518 B`、`gap=38`、`PRELOAD` | `191.746 Gbps` aggregate L2，`194.778 Gbps` aggregate wire |
| 双端口 `64 B`、`gap=3`、`PRELOAD` | `102.399 Gbps` aggregate L2，`140.798 Gbps` aggregate wire |
| `LOOP`，`100` 包 x `3` 次 | `300` TX packets，无 late/underrun/drop |
| `STREAM`，双 SSD striped source，单 DDR ring，`1518 B`、`gap=800` | `4.554 Gbps` L2，无 late/underrun/drop |
| 双 SSD striped source dry-run | `41.828 Gbps` direct read，`43.586 Gbps` buffered read |
| XDMA H2C benchmark | 单 bank 双线程 `53.276 Gbps`，DDR0+DDR1 并行 `70.150 Gbps` |
| TX0 -> RX1 光纤回环 payload 校验 | `256/256` samples matched，`0` RX errors |
| RX 侧间隔精度套件 | 全部通过，最差 `85.043 ns` max absolute error |
| Routed timing | `WNS=+0.006 ns`，`WHS=+0.006 ns` |

小包测试需要区分 wire rate 和 pcap/L2 rate。一个 `64 B` 以太网帧在计入
FCS、preamble/SFD 和 IFG 后占用 `88 B` 线时，因此 `100 Gbps` 物理线速大约
等价于 `72.73 Gbps` 的 64B pcap/L2 数据和 `142.05 Mpps`。

详细上板记录见
[`docs/evaluation_20260715_rc5_board_validation.md`](docs/evaluation_20260715_rc5_board_validation.md)。

## 快速开始

仓库和 Host 软件面向 Linux。以下命令假设 FPGA 已经烧录，XDMA 驱动已经创建
`/dev/xdma0_*`，QSFP 链路已经连接。

### 1. 编译 Host 工具

```bash
make -C software
sudo make -C software install
tick-replay --version
```

### 2. 转换 PCAP

```bash
tick-replay prepare /data/input.pcap \
  --out-dir /var/tmp/tick-trace \
  --tick-hz 300000000
```

输出目录包含 `desc.bin`、`data.bin` 和 `manifest.json`。

### 3. PRELOAD 回放

```bash
sudo tick-replay load \
  --port 0 \
  --mode preload \
  --manifest /var/tmp/tick-trace/manifest.json

sudo tick-replay status --port 0
```

### 4. LOOP 回放

```bash
sudo tick-replay load \
  --port 0 \
  --mode loop \
  --loop-count 100 \
  --loop-gap 300000 \
  --manifest /var/tmp/tick-trace/manifest.json
```

在 `300 MHz` 下，`300000` 个 loop-gap tick 等于 `1 ms`。

### 5. STREAM Ring 回放

先把 descriptor/payload trace 转换为完整 stream record：

```bash
python3 software/trace_to_stream.py \
  --manifest /var/tmp/tick-trace/manifest.json \
  --out /var/tmp/tick-trace/stream.bin
```

运行有界 ring loader：

```bash
sudo tick-replay stream \
  --port 0 \
  --manifest /var/tmp/tick-trace/stream_manifest.json \
  --h2c auto \
  --ring-base 0x20000000 \
  --ring-size 0x08000000 \
  --prefill-bytes 0x04000000 \
  --writer-threads 4 \
  --queue-depth 128
```

如果 trace 分布在多块 SSD 上，使用 `software/stream_stripe.py` 生成 record-aligned
stripe manifest，然后用 `--stripe-manifest` 替代 `--manifest`。

当前双端口 release 使用 bank-local replay 路径：port `0` 读 `DDR0`，port `1`
读 `DDR1`。port0 跨 DDR0/DDR1 的高性能 ping-pong STREAM ring 属于单端口
multi-DDR build profile。

### 6. 双端口同步启动

先装载两个端口但不发 `START`，再 arm 到同一个 FPGA 绝对 tick：

```bash
sudo tick-replay load --port 0 --mode preload \
  --manifest /var/tmp/trace0/manifest.json --arm-only

sudo tick-replay load --port 1 --mode preload \
  --manifest /var/tmp/trace1/manifest.json --arm-only

sudo tick-replay sync-start \
  --ports 0,1 \
  --delay-ms 100 \
  --egress-schedule
```

## 系统架构

![Tick Replayer architecture](docs/images/replay_arch.png)

缩写说明：`APP` 是主机 trace 处理与控制程序；`XDMA` 是 Xilinx PCIe DMA endpoint；
`AXIL M` 是 AXI-Lite 控制 master；`AXI M` 是 memory-mapped AXI DMA master；
`H2C` 是 host-to-card DMA；`C2H` 是 card-to-host DMA；`DDR4` 存储 descriptor、
payload、stream ring 和 RX sample；`CMAC` 是 100G Ethernet MAC；`QSFP` 是光口。

数据路径：

```text
Host SSD / Host DRAM
  -> XDMA H2C
  -> FPGA DDR4
  -> descriptor / stream reader
  -> scheduler
  -> TX packet engine
  -> AXI-Stream / LBUS adapter
  -> CMAC
  -> QSFP

QSFP
  -> CMAC RX
  -> RX capture core
  -> counters / interval samples / truncated payload samples
  -> AXI-Lite status or C2H readback
```

## 回放模式

### PRELOAD

`PRELOAD` 先把完整 trace 放入 FPGA DDR，再启动回放。它的容量受端口所分配 DDR
区域限制，但调度最稳定、吞吐最高、验证最简单。当前双端口 release 中，每个 TX
端口默认有一个独立 `16 GiB` replay bank。

### LOOP

`LOOP` 在 `PRELOAD` 的基础上重复回放同一段 trace，支持 `loop_count` 和 `loop_gap`。
适合长时间压力测试、ILA 触发和重复实验。

### STREAM

`STREAM` 把 FPGA DDR 抽象为有界 producer/consumer ring。Host 按顺序提交完整
stream record，FPGA 按 stream read pointer 取出 record 并调度发包。

当前 dual-port release 的 STREAM 已经功能可用，但高吞吐动态换入仍受单 DDR ring
读写耦合、XDMA memory-mapped pwrite、出口 backpressure 和 stream reader 预取能力限制。

## 容量与地址空间

U200 暴露四个 `16 GiB` DDR 窗口：

| Bank | Base address | 默认用途 |
| --- | ---: | --- |
| `DDR0` | `0x0000000000` | TX0 descriptor、payload 或 STREAM ring |
| `DDR1` | `0x0400000000` | TX1 descriptor、payload 或 STREAM ring |
| `DDR2` | `0x0800000000` | RX0 sample storage |
| `DDR3` | `0x0c00000000` | RX1 sample storage |

默认双端口 release 为每个 TX 端口分配一个 `16 GiB` replay bank。单个逻辑
`64 GiB` PRELOAD trace 或 port0 多 DDR STREAM ping-pong 需要单端口 multi-DDR
构建配置。

## Trace 格式

每个 descriptor 固定 `64 B`：

| Offset | Size | Field |
| ---: | ---: | --- |
| `0x00` | `8` | `gap_ticks`，距离上一个包的 tick 间隔 |
| `0x08` | `4` | `payload_word_offset`，以 `64 B` word 为单位 |
| `0x0c` | `2` | `frame_len` |
| `0x0e` | `2` | `flags` |
| `0x10` | `48` | 保留 |

payload 以 `64 B` 对齐存储。STREAM record 使用同样的 `64 B` metadata header，
后面紧跟对齐后的 payload。

## Host 软件

统一入口：

```bash
tick-replay prepare
tick-replay load
tick-replay stream
tick-replay status
tick-replay sync-start
tick-replay rx
tick-replay verify
tick-replay validate
tick-replay benchmark
```

常用脚本：

| 工具 | 用途 |
| --- | --- |
| `pcap2trace.py` | pcap 转 descriptor/payload |
| `trace_to_stream.py` | descriptor/payload 转 STREAM record |
| `xdma_load_trace.py` | PRELOAD/LOOP 装载 |
| `xdma_stream_ring_fast.cpp` | 高性能 C++ STREAM loader |
| `traffic_replay_cli.py` | 低层 AXI-Lite 控制与状态查看 |
| `preload_stress_test.py` | PRELOAD 吞吐和鲁棒性测试 |
| `dual_port_preload_test.py` | 双端口同步回放测试 |
| `loopback_rx_verify.py` | TX/RX 光纤回环 payload 校验 |
| `replay_precision_suite.py` | RX 侧 SOP-to-SOP 精度测试 |

## 构建与烧录

创建 release bitstream：

```bash
export TRAFFIC_REPLAY_PORT_COUNT=2
export TRAFFIC_REPLAY_DDR_BANKS=4
export TRAFFIC_REPLAY_H2C_CHANNELS=1
export TRAFFIC_REPLAY_PORT0_MULTI_DDR=0
./scripts/build_4ddr_dual_port.sh
```

烧录：

```bash
vivado -mode batch -source scripts/program_remote.tcl \
  -tclargs bitstreams/<release>/traffic_replay_bd_wrapper.bit \
           bitstreams/<release>/traffic_replay_bd_wrapper.ltx
```

JTAG 烧录后 Linux 侧通常需要 PCIe remove/rescan，让 XDMA BAR 和设备节点重新映射。

## 验证

本项目要求重要 bitstream 通过以下验证后再归档：

- XDMA H2C/C2H DDR readback
- AXI-Lite stop/clear/status/control-plane restart
- PRELOAD 大包、小包、混合包吞吐
- 双端口同步 PRELOAD
- LOOP 模式
- STREAM ring correctness-safe 动态回放
- gap=0/overrate 后 clear 恢复
- TX -> RX 光纤回环 payload sample 校验
- RX 侧 SOP-to-SOP 间隔精度套件
- Routed timing 和 utilization 归档

本轮完整记录见
[`docs/evaluation_20260715_rc5_board_validation.md`](docs/evaluation_20260715_rc5_board_validation.md)。

## 仓库结构

```text
constraints/   U200 PCIe、DDR、QSFP 和 floorplan 约束
rtl/           replay、scheduler、CDC、CMAC adapter、RX measurement RTL
sim/           自检 RTL testbench
scripts/       Vivado project、simulation、implementation、programming Tcl
software/      Linux CLI、trace converter、loader、benchmark、validation tools
docs/          架构、模式、寄存器和评估记录
bitstreams/    重要 bitstream、ltx、timing/utilization 报告和 release note
```

## 当前限制

- 当前硬件使用 XDMA memory-mapped H2C，不是 QDMA 或 AXI4-Stream H2C，因此动态
  STREAM 吞吐受 Host DMA 提交、SSD 读取、内存复制和 DDR 仲裁共同影响。
- 当前 dual-port release 是 bank-local replay：port `0` 读 `DDR0`，port `1`
  读 `DDR1`。Host 可以写四个 DDR bank，但 port0 不能在这个 release 中读 `DDR1`
  做 ping-pong ring。
- 单个逻辑 `64 GiB` PRELOAD trace 或高性能 port0 multi-DDR STREAM 需要单端口
  multi-DDR build profile。
- CMAC-domain egress scheduling 已实现，但动态 STREAM + egress scheduling 还需要
  更深的预发送缓冲和 backpressure 策略，才能作为高吞吐发布路径。
- RX 默认做统计、间隔测量和截断 sample，不做全量 100G payload 回传，以避免占满
  PCIe 和 DDR 带宽。
- pcapng 和 pcap 链路状态/一致性编辑属于上层 trace processing，不属于本 FPGA
  replay 子系统的当前发布范围。
