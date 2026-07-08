<div align="center">

# Tick Replayer

**基于 FPGA DDR 的 100G 流量回放原型，使用硬件 tick 调度包间隔。**

`FPGA` / `100G Ethernet` / `PCIe XDMA` / `DDR4` / `CMAC` / `PCAP Replay`

[English README](README.md)

</div>

> 2026-07-08 更新：默认双端口、四 DDR bank、深预取版本已经完成实现并归档到
> `bitstreams/20260708_040647_4ddr_dual_prefetch_timing_clean`。该版本映射 U200
> 四个 `16GiB` DDR 窗口，总计 `64GiB`，post-route `WNS=+0.010ns`、
> `WHS=+0.006ns`。

## 项目概述

`Tick Replayer` 是面向 Xilinx Alveo U200 的 FPGA 流量回放原型。Linux 主机先
把 `pcap` 转换成包描述符和包载荷文件，再通过 `PCIe XDMA` 写入 FPGA `DDR4`，
随后通过 `AXI-Lite` 寄存器控制 FPGA 从 100G `CMAC` 端口按包间隔发出流量。

项目名里的 `Tick` 指硬件回放时钟 tick。`pcap` 中相邻包的时间戳差会被转换成
`gap_ticks`，FPGA 调度器用一个相对回放计数器决定每个包的释放时刻。因此这个项目
关注的不只是“把包发出去”，而是下面四个问题：

- 最大能回放多大的 `pcap` 或 trace。
- 最大能达到多少回放吞吐。
- 包间隔回放精度有多高。
- 主机侧软件工具如何完成转换、装载、控制和验证。

当前设计是双端口原型。`QSFP0` 和 `QSFP1` 各自有独立的 TX replay 通路，也各自有
轻量级 RX 统计和采样通路。因此一块 FPGA 可以同时在两个高速口收发，为后续模拟
双向 trace 的两端打基础。

## 目录

- [当前状态](#当前状态)
- [快速开始](#快速开始)
- [系统架构](#系统架构)
- [RTL 模块导览](#rtl-模块导览)
- [最大回放容量](#最大回放容量)
- [最大回放吞吐](#最大回放吞吐)
- [回放精度](#回放精度)
- [主机侧软件工具](#主机侧软件工具)
- [回放模式](#回放模式)
- [Trace 描述符格式](#trace-描述符格式)
- [构建和烧录](#构建和烧录)
- [验证命令](#验证命令)
- [仓库结构](#仓库结构)
- [当前限制](#当前限制)
- [后续计划](#后续计划)

## 当前状态

| 项目 | 状态 |
| --- | --- |
| 目标板卡 | Xilinx Alveo U200 |
| PCIe | Xilinx `XDMA`，Gen3 x16，memory-mapped `H2C`/`C2H` |
| Ethernet | 双 100G `CMAC`，连接 `QSFP0` 和 `QSFP1` |
| 控制面 | `XDMA` user `BAR` 到 `AXI-Lite` 寄存器 |
| Trace 存储 | 硬件生成器默认启用 U200 四个 `DDR4` bank。双端口 build 使用 bank-local replay/capture 路径；单端口 multi-DDR build 可以暴露 `64GiB` FPGA trace 窗口 |
| 回放模式 | `PRELOAD`、`LOOP`、`STREAM` ring buffer |
| RX 功能 | 包/字节/error 计数，最近包采样，SOP-to-SOP 间隔统计 |
| 时序归档 | 当前四 bank 双端口归档：`bitstreams/20260708_040647_4ddr_dual_prefetch_timing_clean`，`WNS=+0.010 ns`；已完整上板评估的单口 STREAM build：`/home/user/tick_replayer_bitstreams/20260707_stream_ring_pipeline_2bank_timing_clean`，`WNS=+0.009 ns` |
| 全 64GB DDR | 生成器支持四个 `16GiB` DDR 窗口。单口 64GiB 容量 build 使用 `scripts/build_4ddr_single_port_64g.sh`；双口高负载 build 使用 `scripts/build_4ddr_dual_port.sh` |

详细上板结果记录在
[`docs/evaluation_20260708_4ddr_dual_prefetch.md`](docs/evaluation_20260708_4ddr_dual_prefetch.md)、
[`docs/evaluation_20260707_full_system_check.md`](docs/evaluation_20260707_full_system_check.md)、
[`docs/evaluation_20260707_stream_pingpong_pipeline.md`](docs/evaluation_20260707_stream_pingpong_pipeline.md)
和 [`docs/evaluation_20260705_4ddr_localclock.md`](docs/evaluation_20260705_4ddr_localclock.md)。

## 快速开始

下面的命令展示如何把一份经典 `pcap` 文件从 `port 0` 回放出去。运行前默认已经完成
FPGA bitstream 烧录，Xilinx `XDMA` 驱动已经生成 `/dev/xdma0_*` 设备，并且对应
`QSFP` 链路已经连接。

先设置输入和输出路径：

```bash
export PCAP=/data/input.pcap
export TRACE_DIR=/tmp/tick_trace
export STREAM_DIR=/tmp/tick_stream
```

编译主机侧 C++ loader，并把 `pcap` 转成硬件 trace 格式：

```bash
make -C software

rm -rf "$TRACE_DIR" "$STREAM_DIR"
mkdir -p "$TRACE_DIR" "$STREAM_DIR"

python3 software/pcap2trace.py "$PCAP" \
  --out-dir "$TRACE_DIR" \
  --tick-hz 300000000
```

检查板卡和控制面是否可见：

```bash
lspci -nn -d 10ee:
ls -l /dev/xdma*
sudo python3 software/traffic_replay_cli.py --port 0 clear
sudo python3 software/traffic_replay_cli.py --port 0 status
```

真实光口回放时不要打开 `debug-force-link` 和 `debug-tx-ready`。只有在无光纤调试时，
才建议用 `debug-force-link on` 强制打开 TX gate；`debug-tx-ready on` 会让发送通路
直接 drain，不会真正把包打到线上。

### PRELOAD 回放

`PRELOAD` 模式先把完整 trace 复制到 FPGA `DDR4`，然后 FPGA 从 DDR 自主按时间戳
调度发包，回放过程中 host 不再参与 TX 数据路径。

```bash
sudo python3 software/xdma_load_trace.py \
  --port 0 \
  --manifest "$TRACE_DIR/manifest.json" \
  --desc-base 0x04000000 \
  --data-base 0x14000000 \
  --mode preload \
  --no-auto-drop

sudo python3 software/traffic_replay_cli.py --port 0 status
```

重新装载另一份 trace 前，先停止并清空回放核心：

```bash
sudo python3 software/traffic_replay_cli.py --port 0 stop
sudo python3 software/traffic_replay_cli.py --port 0 clear
```

### LOOP 回放

`LOOP` 模式重复使用同一份已经放在 DDR 中的 trace。下面的例子会把该 `pcap` 回放
`10` 次，并在每轮之间插入 `300000` 个 replay tick；在 `300MHz` 下这等于 `1ms`。

```bash
sudo python3 software/xdma_load_trace.py \
  --port 0 \
  --manifest "$TRACE_DIR/manifest.json" \
  --desc-base 0x04000000 \
  --data-base 0x14000000 \
  --mode loop \
  --loop-count 10 \
  --loop-gap 300000 \
  --no-auto-drop

sudo python3 software/traffic_replay_cli.py --port 0 status
```

### STREAM Ring 回放

`STREAM` ring 模式适合大于 FPGA DDR 预加载窗口的 trace。host 先把 `desc.bin` 和
`data.bin` 转成连续 stream record，再通过 `XDMA H2C` 持续填充 FPGA DDR 中的 ring。
只有完整 record 写入后，host 才推进 FPGA 可见的写指针；包间隔调度仍由 FPGA 完成。

```bash
python3 software/trace_to_stream.py \
  --manifest "$TRACE_DIR/manifest.json" \
  --out "$STREAM_DIR/stream.bin" \
  --out-manifest "$STREAM_DIR/stream_manifest.json"

sudo ./software/xdma_stream_ring_fast \
  --port 0 \
  --manifest "$STREAM_DIR/stream_manifest.json" \
  --ring-base 0x20000000 \
  --ring-size 0x08000000 \
  --prefill-bytes 0x04000000 \
  --batch-bytes 0x04000000 \
  --read-bytes 0x04000000 \
  --queue-depth 4 \
  --writer-threads 2 \
  --host-cache-bytes auto \
  --timeout 300

sudo python3 software/traffic_replay_cli.py --port 0 status
```

如果请求的回放速率高于当前动态装载安全速率，`status` 会出现 `late_packets` 或
`underrun_packets`。此时应增大包间隔、降低目标 `pcap` 带宽，或者改用 `PRELOAD`
模式获得最高吞吐。

如果要在单个 QSFP/单个 replay port 上使用双 SSD 并发 STREAM 装载，先把 stream 文件
切成按完整 packet record 对齐的大 block。host 可以从两块 SSD 并发读取这些 block，
但 loader 仍然严格按照 `block_id` 顺序提交到 FPGA ring，因此包间隔仍由 FPGA
scheduler 控制。

```bash
export SSD0=/mnt/ssd0/tick_stream_lane0
export SSD1=/mnt/ssd1/tick_stream_lane1

python3 software/stream_stripe.py \
  --manifest "$STREAM_DIR/stream_manifest.json" \
  --lane-dir "$SSD0" \
  --lane-dir "$SSD1" \
  --block-bytes 0x10000000 \
  --out-manifest "$STREAM_DIR/stripe_manifest.json" \
  --force

sudo ./software/xdma_stream_ring_fast \
  --port 0 \
  --stripe-manifest "$STREAM_DIR/stripe_manifest.json" \
  --reader-threads 2 \
  --reader-window-blocks 8 \
  --ring-base 0x20000000 \
  --ring-size 0x08000000 \
  --prefill-bytes 0x04000000 \
  --batch-bytes 0x04000000 \
  --read-bytes 0x04000000 \
  --queue-depth 8 \
  --writer-threads 2 \
  --host-cache-bytes auto \
  --timeout 300
```

在四 DDR bank bitstream 上，`port 0` 的 `STREAM` 可以启用双 bank ping-pong ring。
此时 `--ring-size` 表示每个 DDR bank 的 segment 大小，而不是总 ring 容量，并且必须是
2 的幂且 64 字节对齐。host 将偶数 segment 写入 bank 0、奇数 segment 写入 bank 1；
FPGA reader 用同一个单调递增的读指针选择当前读 bank，从而让 `XDMA H2C` 写和 replay
读尽量落在不同 DDR bank 上。

```bash
sudo ./software/xdma_stream_ring_fast \
  --port 0 \
  --stripe-manifest "$STREAM_DIR/stripe_manifest.json" \
  --pingpong \
  --ring-base 0x20000000 \
  --pingpong-bank1-base 0x400000000 \
  --ring-size 0x200000000 \
  --prefill-bytes 0x200000000 \
  --guard-bytes 0x04000000 \
  --batch-bytes 0x04000000 \
  --read-bytes 0x04000000 \
  --reader-threads 4 \
  --reader-window-blocks 16 \
  --queue-depth 16 \
  --writer-threads 2 \
  --host-cache-bytes auto \
  --timeout 300
```

### 端口和地址说明

上面的例子使用 `port 0` 和单 DDR bank 下安全的地址布局。四 DDR bank build 中，
`port 1` 通常把 TX 数据放在 bank 1：

```bash
# port 1 的 PRELOAD 或 LOOP
--port 1 --desc-base 0x0400000000 --data-base 0x0410000000

# port 1 的 STREAM ring
--port 1 --ring-base 0x0420000000 --ring-size 0x08000000
```

同一个 DDR bank 内不要让 `desc`、`data`、`STREAM` ring 或 RX sample 区域互相重叠。

## 系统架构

![Tick Replayer architecture](docs/images/replay_arch.png)

图中 `APP` 是主机侧 trace 生成、`XDMA` 装载和回放控制工具；`XDMA Driver` 是
Xilinx DMA Linux 驱动，暴露 `H2C`、`C2H` 和 user `BAR` 字符设备；`PCIe XDMA IP`
是 Xilinx PCI Express DMA endpoint；`AXIL M` 是访问控制/状态寄存器的
`AXI-Lite` master；`AXI M` 是访问 DDR 的 memory-mapped AXI master；`SmartConnect`
是 Xilinx AXI 互联和仲裁结构；`DDR4` 保存 TX 描述符、TX 载荷、STREAM ring 和
RX sample；`TX Replay Core` 包含描述符/载荷预取、时间戳调度和发包引擎；
`RX Capture Core` 负责接收统计、最近包采样和 SOP-to-SOP 间隔测量；`CMAC` 是
Xilinx 100G Ethernet MAC；`QSFP` 是 100G 光口。

`PRELOAD` 数据路径：

```text
pcap
  -> pcap2trace.py
  -> desc.bin + data.bin + manifest.json
  -> xdma_load_trace.py
  -> /dev/xdma0_h2c_0
  -> FPGA DDR4
  -> ddr_trace_reader
  -> replay_scheduler
  -> replay_tx_engine
  -> AXI-Stream FIFO
  -> CMAC TX
  -> QSFP
```

`STREAM` ring 数据路径：

```text
large pcap / stream file on host storage
  -> host loader 批量组织完整 stream record
  -> /dev/xdma0_h2c_0
  -> FPGA DDR4 ring
  -> host 写入完成后推进 STREAM_WR_PTR
  -> FPGA 消费 record 后推进 STREAM_RD_PTR
  -> host_stream_parser
  -> replay_scheduler
  -> CMAC TX
```

RX 侧默认不把所有包上传主机，而是维护计数器；需要时可以保存最近的截断包窗口，
并记录收到包之间的 SOP-to-SOP 间隔，用来验证回放精度。

当前深预取 RTL 保持原有 descriptor 格式和 BAR 寄存器映射不变，但加大了 DDR 读窗口：
`ddr_trace_reader` 的 descriptor/meta FIFO 为 `512` 项，payload plan FIFO 为 `1024`
项，payload/AXI command queue 为 `64` 项，payload FIFO 为 `8192` 个 512-bit beat。
`STREAM` DDR reader 最多可发出 `64` 个 outstanding read burst。这些改动用于隐藏 DDR
访问延迟，并在双端口分别读取不同 DDR bank 时尽量保持两个 replay port 都不断粮。

## RTL 模块导览

阅读 RTL 时建议从外到内看：Vivado block design wrapper 负责把模块包装成标准
`AXI-Lite`、`AXI4`、`AXI-Stream` 和 CMAC `LBUS` 接口；核心逻辑再拆成控制寄存器、
DDR 读出、包间隔调度、TX 格式化和 RX 侧统计/采样。

| RTL 文件 / 模块 | 作用 |
| --- | --- |
| `traffic_replay_pkg.sv` | 全局常量和工具函数：`512-bit` 数据通路宽度、`64B` descriptor 大小、回放模式编号、`tkeep` 生成、每 beat 字节数计算等。 |
| `traffic_replay_bd_core.v` | 单个 TX replay interface 的 Vivado block design wrapper。它把 replay core 暴露成 `S_AXIL`、只读 `M_AXI` 和 `M_TX_AXIS` 接口，并把未使用的 AXI 写通道绑成常量。 |
| `traffic_replay_top_stub.sv` | 面向仿真的轻量 wrapper，直接包住 `trace_replay_core`，不用实例化完整 Vivado block design 就能做 RTL 测试。 |
| `trace_replay_core.sv` | TX 回放主核心。负责 replay 状态机、寄存器、模式选择、PRELOAD/LOOP DDR reader、STREAM ring reader、stream parser、scheduler、TX engine、计数器、stall/drop 处理和 debug 状态。 |
| `axi_lite_regs.sv` | XDMA user `BAR` 后面的控制/状态寄存器文件。解析 `start`、`stop`、`clear`、模式、DDR 基地址、包数、loop 参数、STREAM 写指针、debug 控制和 TX 统计。 |
| `ddr_trace_reader.sv` | PRELOAD/LOOP trace reader。从 DDR 扫描 `64B` descriptor，检查包顺序，发起 payload `AXI4` read burst，维护深 descriptor/meta/payload FIFO，并输出对齐的包 metadata 和 payload AXI-Stream beat。 |
| `ddr_stream_reader.sv` | STREAM ring reader。把 FPGA DDR 当作有界 record ring，维护单调递增的读/写字节计数，防止 wrap/overrun，支持 EOF 完成，并可在两个 DDR bank 之间做 ping-pong segment 读取。 |
| `host_stream_parser.sv` | STREAM record 解析器。每条 record 的第一个 `64B` beat 解析为 packet metadata，也就是 `gap_ticks`、长度和 flags；后续 beat 作为 payload 送入 scheduler/TX engine。 |
| `replay_scheduler.sv` | 包间隔调度器。把 descriptor 里的 `gap_ticks` 累加为相对回放目标 tick，缓存 packet metadata，到期后释放包；`start`/`clear` 时重置相对时间基准，并统计 late packet。 |
| `replay_tx_engine.sv` | 把 scheduler 给出的 packet metadata 和 payload beat 合并成 TX AXI-Stream。它生成 `tkeep`/`tlast`，统计 TX 包数/字节数，并在包已经到期但 payload 没准备好时报告 underrun。 |
| `axis_sync_fifo.sv` | 同时钟 AXI-Stream FIFO，底层使用 XPM simple dual-port RAM。当前版本支持可配置 BRAM read latency 和输出缓冲，用来吸收 DDR read burst，减少 scheduler 可见的气泡。 |
| `axis_async_fifo.v` | 跨时钟 AXI-Stream FIFO，使用 Gray pointer 做 CDC，保留 `tdata`、`tkeep`、`tlast`、`tuser`，用于 replay/DDR 时钟域和 CMAC 用户时钟域之间。 |
| `axis_to_lbus_512.sv` | TX 方向 AXI-Stream 到 CMAC 四段 `LBUS` 的适配器。负责字节序转换、SOP/EOP 放置、MTY 生成，以及基于 `tx_rdyout` 的帧级缓存。 |
| `axis_to_lbus_512_bd.v` | `axis_to_lbus_512` 的 Vivado block design wrapper，加上接口元信息，方便在 IP Integrator 里连接 CMAC。 |
| `lbus_to_axis_512.sv` | RX 方向 CMAC 四段 `LBUS` 到内部 AXI-Stream-like 总线的适配器，重建 `tdata`、`tkeep`、`tstart`、`tlast` 和包错误标志。 |
| `rx_capture_bd_core.v` | RX capture 的 Vivado block design wrapper，适用于已经转成 AXI-Stream-like RX 包的连接方式。 |
| `rx_capture_lbus_bd_core.v` | 直接接 CMAC `LBUS` 的 RX capture wrapper，内部先做 `LBUS` 到 AXI-Stream-like 的转换，再进入 capture core。 |
| `rx_capture_bd_core.sv` / `rx_capture_core` | 轻量 RX 统计和采样核心。统计包数/字节数/error，在 RX 时钟域统计 SOP-to-SOP 间隔，将最近包按截断长度写入 DDR sample ring，并通过 `AXI-Lite` 暴露控制/状态寄存器。 |

默认四 DDR 双端口 build 中，`scripts/create_hw_project.tcl` 是系统级 top。它实例化两个
TX replay core、两个 RX capture core、两个 CMAC、XDMA、四个 DDR controller、
SmartConnect、clock converter、register slice 以及 AXI-Stream/LBUS adapter。仓库里的
RTL 文件则是这些 block design 中可复用的数据通路模块。

## 最大回放容量

容量取决于回放模式。

### PRELOAD 容量

`PRELOAD` 要求整份 trace 在回放前完整放入 FPGA DDR。存入 DDR 的 trace 大小不等于
原始 `pcap` 大小。每个包占用：

```text
preload_trace_bytes_per_packet = 64 + align64(frame_len)
```

其中 `64` 是固定描述符大小，`align64(frame_len)` 是按 64 字节对齐后的包载荷空间。

当前工程使用一个 U200 `DDR4` bank，按 `16GiB` trace 空间估算：

| Frame bytes | 每包 trace bytes | `16GiB` DDR 可容纳包数 | 约等于原始 `pcap` 大小 |
| ---: | ---: | ---: | ---: |
| `64` | `128` | `134,217,728` | `10.00GiB` |
| `512` | `576` | `29,826,161` | `14.67GiB` |
| `1518` | `1600` | `10,737,418` | `15.34GiB` |
| `9000` | `9088` | `1,890,390` | `15.87GiB` |

当前默认硬件生成会启用 U200 四个 DDR bank。`20260708_040647_4ddr_dual_prefetch_timing_clean`
已经在板上验证四个 `16GiB` 窗口的起始地址和高端地址均可通过 `H2C` 写入和
`C2H` 读回。四 bank 设计空间约为单 bank 的四倍：

| Frame bytes | `64GiB` DDR 可容纳包数 | 约等于原始 `pcap` 大小 |
| ---: | ---: | ---: |
| `64` | `536,870,912` | `40.00GiB` |
| `512` | `119,304,647` | `58.67GiB` |
| `1518` | `42,949,672` | `61.36GiB` |
| `9000` | `7,561,562` | `63.49GiB` |

### STREAM Ring 容量

`STREAM` ring 模式把 FPGA DDR 当滑动窗口，整份 trace 不必全部放入 FPGA DDR。因此
最大原始 `pcap` 大小主要受主机存储容量和主机侧转换/装载流水线限制。

以之前目标主机的存储预算为例：

| 存储条件 | 约可支持的最大原始 `pcap` |
| --- | ---: |
| 测试时剩余 SSD 空间 | `1.475TB` |
| 两块 2TB SSD 的原始设计空间 | `4.001TB` |

如果磁盘上还需要保存预转换后的 `stream.bin`，小包场景会因为每包 64 字节 stream
header 带来更明显的膨胀。

## 最大回放吞吐

吞吐需要区分两个口径：

- `wire throughput`：100G 物理链路上的占用，包含 FCS、preamble/SFD 和 IFG。
- `pcap/frame throughput`：trace 文件中可见的帧字节吞吐，通常不含 FCS、preamble/SFD 和 IFG。

100G 线速对应的原始 `pcap` 吞吐随包长变化：

| Frame bytes | 100G 线速对应 `pcap` 吞吐 | 包速率 |
| ---: | ---: | ---: |
| `64` | `72.73Gbps` | `142.05Mpps` |
| `512` | `95.52Gbps` | `23.32Mpps` |
| `1518` | `98.44Gbps` | `8.11Mpps` |
| `9000` | `99.73Gbps` | `1.39Mpps` |

当前 U200 光纤回环实测：

| 模式 | 测试项 | 结果 |
| --- | --- | ---: |
| `PRELOAD` | `64B`, `gap=3` | `70.4Gbps` wire，`51.2Gbps` frame/L2 |
| `PRELOAD` | `256B`, `gap=8` | `84.0Gbps` wire，`76.8Gbps` frame/L2 |
| `PRELOAD` | `512B`, `gap=14` | `91.9Gbps` wire，`87.8Gbps` frame/L2 |
| `PRELOAD` | `1518B`, `gap=38` | `97.4Gbps` wire，`95.9Gbps` frame/L2 |
| `PRELOAD` | mixed `64:3,1518:38` | `95.4Gbps` wire |
| `LOOP` | `1000` 包 x `10` loops | 计数正确，无 drop/stall/late/underrun |
| `STREAM` ring | `1518B`, `gap=38`, `1M` packets，全量预填 DDR | L2 `95.874Gbps`，无 late/underrun/drop |
| `STREAM` ring | `1518B`, `gap=38`, `5M` packets，`12GB` ring 全量预填 | L2 `95.874Gbps`，无 late/underrun/drop |
| `STREAM` ring | `1518B`, `gap=36`, `1M` packets，全量预填 DDR | 内部 forced-ready TX 测试 `101.200Gbps` |
| `STREAM` ring | `1518B`, `gap=38`, `5M` packets，aligned-buffer loader 前的 `8GB` ring 动态换入 | 平均 `55.306Gbps`；ring 耗尽后出现 late/underrun |
| `STREAM` ring | `1518B`, `gap=160`, `40M` packets，`64GB` stream 冷态动态换入 | L2 `22.770Gbps`，无 late/underrun/drop/stall |
| `STREAM` ring | `1518B`, `gap=160`, `64GB` stream，striped direct-copy loader | 装载 `28.3Gbps`，无 late/underrun |
| `STREAM` ring | `1518B`, `gap=120`, `2M` packets，container-striped ping-pong ring | L2 `30.360Gbps`，无 late/underrun/drop/stall |
| `STREAM` ring | `1518B`, `gap=80`, `2M` packets，`2GiB` container-striped ping-pong ring | L2 `45.540Gbps`，2026-07-07 测试无 late/underrun/drop/stall |
| `STREAM` ring | `1518B`, `gap=80`, `500k` packets，双 SSD striped warm-cache，2026-07-08 四 bank bit | 装载 `70.016Gbps`，回放 L2 `45.540Gbps`，无 late/underrun |
| `STREAM` ring | 同一数据集，清空 Linux page cache 后冷读 | 冷装载 `28.252Gbps`，无 late/underrun |
| `STREAM` ring | 最大 ring 配置 sanity | `16GiB` per bank，`32GiB` total ping-pong ring 可配置并完成小 trace |
| SSD read bench | 双 SSD `O_DIRECT` 乱序读，`64GB` striped blocks | `50.680Gbps` |
| Host loader | 双 SSD striped dry-run，`64GB` stream，cold cache | 读取/重排 `24.102Gbps` |
| Host loader | 双 SSD + memory-mapped `XDMA H2C pwrite()`，`64GB` stream | FPGA 装载 `22.190Gbps` |
| raw `XDMA H2C` | host memory 写 FPGA DDR benchmark | 不同配置下观察到约 `69Gbps` 到 `83Gbps` |

`PRELOAD` 吞吐最高，因为回放过程中 host 不在发包数据路径里。`STREAM` ring 模式主要
用于更大 trace。当前单口增强版本证明了全量预填的大包 STREAM 可以达到调度上限，
但无限长动态回放仍受 host 内存拷贝/转换、memory-mapped `XDMA H2C` 提交、DDR ring
写入以及 FPGA DDR 读出限制。

## 回放精度

FPGA 回放调度器工作在 `300MHz` DDR/replay 时钟上，因此 tick 分辨率是：

```text
1 / 300MHz = 3.333ns
```

板上精度测试使用 RX 侧 `SOP-to-SOP` 测量。RX capture core 在 CMAC RX 时钟域里维护
自由运行计数器，每次收到一个包的 SOP 时计算：

```text
rx_gap_cycles = current_sop_tick - previous_sop_tick
```

主机软件再把这个 RX 实测间隔和原始 descriptor 里的 `gap_ticks` 换算到 ns 后逐项比较。
这个方法测的是端到端包间隔，包含 TX replay、CMAC TX、光纤回环和 CMAC RX，比只看
TX 调度器内部计数更接近真实现象。

当前 RX 侧精度套件结果：

| 测试项 | 目的 | 结果 |
| --- | --- | ---: |
| `uniform_128B_gap3000` | 固定 gap 基准 | 最大绝对误差 `10.38ns` |
| `mixed_gap_128B` | 混合 gap | 最大绝对误差 `12.61ns` |
| `small_packet_small_gap` | 64B 小包，`3/4/5/6/8` tick gap | 最大绝对误差 `8.05ns` |
| `mixed_size_legal` | 64B 到 1518B 大小包混合 | 最大绝对误差 `85.04ns` |
| `long_uniform_128B_gap3000` | `200000` 包长时漂移测试 | sample 窗口最大绝对误差 `14.45ns` |

RX gap sample ring 保存最近 `4096` 个包间隔。长 trace 的全部间隔都会参与
`count/sum/min/max/last` 统计，但逐项 CSV 读回只覆盖最近的 sample 窗口。

运行精度套件：

```bash
python3 software/replay_precision_suite.py \
  --tx-port 0 --rx-port 1 \
  --work-dir /tmp/precision_suite \
  --desc-base 0x04000000 \
  --data-base 0x14000000 \
  --timeout 180 \
  --report /tmp/precision_suite/report.md
```

## 主机侧软件工具

| 工具 | 用途 |
| --- | --- |
| `software/pcap2trace.py` | 把 classic `pcap` 转换成 `desc.bin`、`data.bin` 和 `manifest.json` |
| `software/gen_synthetic_trace.py` | 生成确定性 synthetic trace |
| `software/gen_synthetic_pcap.py` | 生成 synthetic `pcap` 输入 |
| `software/xdma_load_trace.py` | 把 `PRELOAD`/`LOOP` trace 装入 FPGA DDR，并配置 TX 寄存器 |
| `software/traffic_replay_cli.py` | 通过 `/dev/xdma0_user` 读写控制/状态寄存器 |
| `software/ddr_readback_check.py` | 验证 `XDMA H2C` 和 `C2H` 访问 FPGA DDR |
| `software/preload_stress_test.py` | 生成并回放固定包长 preload 压力测试 |
| `software/preload_mixed_test.py` | 生成并回放大小包混合 preload 测试 |
| `software/loopback_rx_verify.py` | 通过光纤回环检查 TX 到 RX 的 payload sample |
| `software/replay_precision_suite.py` | 运行 RX 侧回放精度测试 |
| `software/stream_stripe.py` | 把 `STREAM` 文件按完整 record 切成跨 SSD lane 的 block |
| `software/xdma_stream_ring_fast.cpp` | C++ `STREAM` ring loader，使用批量 H2C 写 |
| `software/stream_stress_test.py` | 生成并运行 `STREAM` ring 压力测试 |

构建 C++ loader：

```bash
cd software
make
```

转换 pcap：

```bash
python3 software/pcap2trace.py input.pcap \
  --out-dir /tmp/trace_out \
  --tick-hz 300000000
```

装载并启动 preload 回放：

```bash
sudo python3 software/xdma_load_trace.py \
  --port 0 \
  --manifest /tmp/trace_out/manifest.json \
  --desc-base 0x04000000 \
  --data-base 0x14000000 \
  --mode preload
```

查看状态：

```bash
sudo python3 software/traffic_replay_cli.py --port 0 status
sudo python3 software/traffic_replay_cli.py --port 0 regs
sudo python3 software/traffic_replay_cli.py --port 1 rx-status
```

## 回放模式

### PRELOAD

host 在回放前把完整 `desc.bin` 和 `data.bin` 写入 FPGA DDR。回放过程中 FPGA 从 DDR
读取所有描述符和载荷，host 不再参与发包数据路径。

适合：

- 最大吞吐测试。
- 最稳定的时间调度。
- 可重复 benchmark 和精度测试。

限制：

- 最大 trace 大小受 FPGA DDR 空间限制。

### LOOP

`LOOP` 模式重复使用同一份 DDR 中的 trace，适合长时间压力测试，避免反复从 host 装载。

### STREAM Ring

`STREAM` ring 模式在 FPGA DDR 中维护一个有界 ring。host 写入完整 stream record 后推进
`STREAM_WR_PTR`，FPGA 消费 record 后推进 `STREAM_RD_PTR`。

适合：

- 大于 FPGA DDR preload 窗口的大 trace。
- 后续 SSD -> host memory -> FPGA DDR 的动态装载回放。

限制：

- 持续吞吐受动态装载路径限制。
- 当前正确性优先实现已经可用，但还没有达到 100G 持续回放。

## Trace 描述符格式

`PRELOAD` 和 `LOOP` 使用两个二进制文件：

- `desc.bin`：每个包一个 64 字节 descriptor。
- `data.bin`：包载荷，按 64 字节 AXI beat 对齐。

每个 descriptor 是小端格式，正好一个 512-bit AXI beat：

| Byte offset | 字段 | 宽度 | 含义 |
| ---: | --- | ---: | --- |
| `0x00` | `gap_ticks` | 64 bits | 相对上一个包的间隔，单位是 replay clock tick |
| `0x08` | `data_word_offset` | 32 bits | 从 `DATA_BASE` 开始的载荷偏移，单位是 64 字节 word |
| `0x0c` | `frame_len` | 16 bits | Ethernet frame 长度，不含 preamble 和 FCS |
| `0x0e` | `flags` | 16 bits | 预留给未来 per-packet 控制 |
| `0x10` | reserved | 48 bytes | 保留，当前应写 0 |

更完整的寄存器表和 preload 实现细节见 [docs/preload.md](docs/preload.md)。

## 构建和烧录

仓库以源码为中心，Vivado 工程由 Tcl 生成。

环境要求：

- Linux host。
- Vivado 2020.2。
- Xilinx Alveo U200。
- Xilinx `XDMA` Linux driver。
- Python 3。
- `g++` 和 `make`。

构建默认的双端口、四 DDR bank bitstream。这个配置面向双端口高负载回放，两个 TX
通路和两个 RX 采样通路分别连接到本地 DDR bank：

```bash
bash scripts/build_4ddr_dual_port.sh
```

等价的显式命令是：

```bash
TRAFFIC_REPLAY_PORT_COUNT=2 \
TRAFFIC_REPLAY_DDR_BANKS=4 \
TRAFFIC_REPLAY_PORT0_MULTI_DDR=0 \
TRAFFIC_REPLAY_HW_BUILD_ROOT=$PWD/build_hw_4ddr \
vivado -mode batch -source scripts/build_hw_bitstream.tcl
```

构建单端口、四 DDR bank、支持 `port 0` 多 DDR 读访问的 64GiB trace/STREAM bitstream：

```bash
bash scripts/build_4ddr_single_port_64g.sh
```

等价的显式命令是：

```bash
TRAFFIC_REPLAY_PORT_COUNT=1 \
TRAFFIC_REPLAY_DDR_BANKS=4 \
TRAFFIC_REPLAY_PORT0_MULTI_DDR=1 \
TRAFFIC_REPLAY_HW_BUILD_ROOT=$PWD/build_hw_1p_4ddr_pingpong \
vivado -mode batch -source scripts/build_hw_bitstream.tcl
```

构建单端口调试 bitstream：

```bash
TRAFFIC_REPLAY_PORT_COUNT=1 \
TRAFFIC_REPLAY_HW_BUILD_ROOT=$PWD/build_hw_oneport \
vivado -mode batch -source scripts/build_hw_bitstream.tcl
```

通过 Vivado hardware server 烧录：

```bash
vivado -mode batch -source scripts/program_remote.tcl \
  -tclargs build_hw/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.bit
```

重新烧录 PCIe endpoint 后，检查设备是否枚举：

```bash
lspci -nn -d 10ee:
ls -l /dev/xdma*
```

## 验证命令

控制面检查：

```bash
sudo python3 software/traffic_replay_cli.py --port 0 clear
sudo python3 software/traffic_replay_cli.py --port 0 status
sudo python3 software/traffic_replay_cli.py --port 1 status
```

DDR H2C/C2H 读回校验：

```bash
sudo python3 software/ddr_readback_check.py \
  --case 0x00000000:4096 \
  --case 0x00100000:65536 \
  --case 0x08000000:1048576 \
  --repeat 2
```

preload 吞吐测试：

```bash
sudo python3 software/preload_stress_test.py \
  --port 0 \
  --packet-count 100000 \
  --case 64:3 \
  --case 256:8 \
  --case 512:14 \
  --case 1518:38 \
  --desc-base 0x04000000 \
  --data-base 0x14000000 \
  --require-no-drop
```

光纤回环 payload 验证：

```bash
sudo python3 software/loopback_rx_verify.py \
  --tx-port 0 \
  --rx-port 1 \
  --desc-base 0x1c000000 \
  --data-base 0x4c000000 \
  --rx-ring-base 0x70000000 \
  --rx-ring-size 0x01000000 \
  --truncate-bytes 128 \
  --packet-count 64 \
  --frame-len 128 \
  --gap-ticks 3000
```

stream ring 压力测试：

```bash
python3 software/stream_stress_test.py \
  --port 0 \
  --frame-sizes 1518 \
  --packet-count 1000000 \
  --gap-ticks 300 \
  --ring-base 0x50000000 \
  --ring-size 0x20000000 \
  --prefill-bytes 0x10000000 \
  --batch-bytes 0x08000000 \
  --read-bytes 0x08000000 \
  --queue-depth 4 \
  --loader cpp
```

## 仓库结构

```text
rtl/           可综合 RTL
constraints/   板卡和时序约束
scripts/       Vivado 工程生成、构建、烧录 Tcl 脚本
software/      Linux 主机侧工具和 loader
sim/           仿真 testbench
docs/          设计说明和评估报告
docs/images/   架构图和结果图
bitstreams/    带说明的重要 bitstream 归档
reports/       部分验证报告
```

## 当前限制

- 硬件生成器已经默认启用双端口、四 DDR bank 设计。新的四 bank 深预取 bitstream 已经 timing clean，并归档到 `bitstreams/20260708_040647_4ddr_dual_prefetch_timing_clean`。本轮上板 smoke 已验证四个 DDR 窗口、双端口 PRELOAD 吞吐、双向真实光口 TX/RX sample payload 正确性，以及 RX 侧固定 gap SOP-to-SOP 精度。
- `STREAM` ring 模式可用。全量预填的大包 STREAM 测试可以达到 `95.874Gbps`。双 DDR bank ping-pong ring 已验证最大 `32GiB` 配置；2026-07-08 四 bank bit 的双 SSD striped warm-cache 动态测试达到 `70.016Gbps` 装载和 L2 `45.540Gbps` 回放，清 page cache 后冷装载约 `28.252Gbps`。无限长动态 `100Gbps` 回放仍受 `SSD -> host memory -> memory-mapped XDMA H2C -> FPGA DDR` 装载链路限制。
- RX interval sample 只保存最近 `4096` 个间隔。长 trace 有完整聚合统计，但没有完整逐包 timestamp 日志。
- RX 侧端到端精度包含 scheduler、TX buffering、CMAC framing、光纤回环、RX CMAC 和 RX 采样量化；大小包混合场景的局部误差会比固定包长更大。
- 双端口同时接近 100G 大包回放时，两份 trace 应放在不同 DDR bank。默认四 bank 双端口 build 已将 `port0` 和 `port1` TX 路径映射到不同 DDR controller，避免单 DDR bank 共享瓶颈。

## 后续计划

- 对四 bank 深预取 build 多跑几个实现 seed，持续归档最优 bitstream 和对应验证记录。
- 继续优化 `STREAM` 模式，提升动态装载和持续回放吞吐。
- 根据真实双端口高负载测试继续调优 DDR 预取深度和仲裁策略。
- 增加靠近 `CMAC` 的可选 egress-side scheduler，降低大小包混合场景的端到端 SOP 抖动。
- 将 RX event logging 从最近 gap sample 扩展为更大的 timestamp/event ring。
- 持续归档重要 bitstream，并记录源码 commit、时序、资源和板上验证结果。
