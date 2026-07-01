<div align="center">

<h1>Tick Replayer</h1>

<p><strong>面向 Xilinx Alveo U200 的 DDR 后备双端口 100G FPGA 流量回放原型。</strong></p>

<p>
  <code>FPGA</code> /
  <code>100G Ethernet</code> /
  <code>Xilinx Alveo U200</code> /
  <code>PCIe XDMA</code> /
  <code>DDR4</code> /
  <code>CMAC</code> /
  <code>PCAP replay</code>
</p>

<p><a href="README.md">English README</a></p>

</div>

## 概览

`Tick Replayer` 从 Linux 主机通过 `PCIe XDMA` 将包描述符和包载荷写入
FPGA `DDR4`，再由 FPGA 按描述符中的包间隔调度信息，通过 100G `CMAC`
端口发出流量。

仓库名 `Tick_Replayer` 里的 `Tick` 指的是 FPGA 回放时钟 tick。pcap 中
相邻包的时间戳差值会被转换成 `gap_ticks`，硬件调度器用回放相对计时器
和这些 tick 值比较，决定每个包的释放时刻。所以这个项目不只是把包发出去，
而是围绕“以硬件 tick 为单位的精确时间调度”来做流量回放。

当前设计是一个双端口原型。`QSFP0` 和 `QSFP1` 各自有独立的发送回放
流水线，每个接收方向都有轻量级统计和最近包采样能力。两个 `QSFP`
端口可以同时收发，用于让一块 FPGA 模拟双向 trace 中的两端流量。

本仓库以源代码和可复现流程为中心，包含 `RTL`、Vivado Tcl 脚本、约束、
仿真、主机端工具、文档、验证截图，以及若干带说明的 bitstream 归档。
Vivado 生成工程、临时 trace、机器私有状态和大部分构建中间文件不纳入
源码管理。

## 目录

* [功能特性](#功能特性)
* [系统架构](#系统架构)
* [FPGA 数据通路](#fpga-数据通路)
* [Trace 描述符格式](#trace-描述符格式)
* [仓库结构](#仓库结构)
* [环境要求](#环境要求)
* [构建](#构建)
* [Bitstream 归档](#bitstream-归档)
* [烧录和 PCIe 重扫](#烧录和-pcie-重扫)
* [主机端工具](#主机端工具)
* [STREAM 模式和压力测试](#stream-模式和压力测试)
* [硬件验证套件](#硬件验证套件)
* [PRELOAD 模式状态](#preload-模式状态)
* [验证情况](#验证情况)
* [当前限制](#当前限制)

## 功能特性

* 目标板卡为 `Xilinx Alveo U200`。
* 基于 Xilinx `XDMA` 的 `PCIe Gen3 x16` endpoint。
* 一路 memory-mapped `XDMA H2C`/`C2H` 通道用于访问 FPGA `DDR4`。
* 通过 `XDMA` user `BAR` 暴露 `AXI-Lite` 控制面。
* `DDR4` 存储待回放 trace 的描述符和包载荷。
* 双 100G `CMAC` 数据通路：
  * `TX0` replay core 到 `QSFP0`。
  * `TX1` replay core 到 `QSFP1`。
  * `RX0` capture/stat core 来自 `QSFP0`。
  * `RX1` capture/stat core 来自 `QSFP1`。
* 描述符包含每包间隔、载荷偏移、帧长和 flags。
* 回放模式：
  * `PRELOAD`：主机先把描述符和载荷完整预加载到 `DDR4`。
  * `LOOP`：基于 `DDR4` 的循环回放路径已经在 `RTL` 中连通。
  * `STREAM`：主机写入有限 stream buffer，或持续补充一个 `DDR4` ring；
    FPGA 读取完整 stream record 后送入时间戳调度器。本仓库包含 Python
    feeder 和吞吐更高的 C++ feeder。
* Python 主机端工具用于 `pcap` 转换、`XDMA` 加载、寄存器控制、状态读取
  和 RX capture 配置。
* C++ `STREAM` ring feeder 使用异步 producer/consumer、大批量 record 对齐
  写入和更少内存拷贝。
* 已用 `QSFP0` 与 `QSFP1` 的 100G 光纤互联验证双向 `TX`/`RX` 计数和
  `DDR4` ring 读回。

## 系统架构

### 架构图

![Tick Replayer block diagram](docs/images/replay_arch.png)

图中模块含义如下。`APP` 是主机端脚本，用于 `pcap` 处理、trace 生成、
`XDMA` 加载和回放控制；`XDMA Driver` 是 Linux 上的 Xilinx DMA 驱动，
暴露 `H2C`、`C2H` 和 user `BAR` 字符设备；`PCIe XDMA IP` 是 Xilinx PCI
Express DMA endpoint；`AXIL M` 是 `XDMA` 发起 `AXI-Lite` 控制访问的
master；`AXI M` 是用于 `H2C`/`C2H` DDR 访问的 memory-mapped AXI master；
`H2C` 表示 host-to-card DMA；`C2H` 表示 card-to-host DMA；`BAR` 是 PCIe
Base Address Register 映射出来的寄存器窗口；`SmartConnect` 是 Xilinx AXI
互联和仲裁结构；`DDR4` 是 FPGA 外部存储，用于 `TX` 描述符、`TX` 载荷
和 `RX` sample ring；`TX DESC` 是发送包描述符存储；`TX DATA` 是发送包
载荷存储；`RX SAMPLE` 是截断后的接收采样 ring；`TX Replay Core` 包含
描述符/载荷预取、回放调度器和发送包引擎；`Sched` 是由包间隔驱动的回放
调度器；`RX Capture Core` 做接收统计和 sample 写入；`FIFO` 是
`AXI-Stream` 跨时钟/缓冲；`CMAC` 是 Xilinx 100G Ethernet MAC；`QSFP`
是 100G 光口。

主机准备 trace 并通过 `PCIe` 控制 FPGA。FPGA 将 trace 存在 `DDR4` 中，
再由每端口独立的 replay core 喂给 100G `CMAC` 发送接口。接收方向不把
所有包上传主机，只维护统计，并可把最近一段截断包窗口写进 `DDR4`，供
软件通过 `XDMA C2H` 检查。

PRELOAD 数据流：

```text
PCAP / generated trace
  -> pcap2trace.py
  -> desc.bin + data.bin + manifest.json
  -> xdma_load_trace.py
  -> /dev/xdma0_h2c_0
  -> XDMA M_AXI
  -> DDR4 descriptor/data regions
  -> ddr_trace_reader
  -> replay scheduler
  -> TX packet engine
  -> 100G CMAC TX
```

STREAM ring 数据流：

```text
large stream.bin
  -> xdma_stream_ring_fast 或 xdma_stream_ring.py
  -> host software batches complete stream records in host memory
  -> /dev/xdma0_h2c_0
  -> XDMA M_AXI
  -> DDR4 STREAM ring
  -> host advances STREAM_WR_PTR
  -> FPGA consumes committed records and advances STREAM_RD_PTR
  -> host_stream_parser
  -> replay scheduler
  -> TX packet engine
  -> 100G CMAC TX
```

控制和调试路径：

```text
traffic_replay_cli.py
  -> /dev/xdma0_user
  -> XDMA AXI-Lite master
  -> control SmartConnect
  -> TX/RX control and status registers

RX capture DDR ring
  -> /dev/xdma0_c2h_0
  -> host-side debug readback
```

## FPGA 数据通路

Vivado block design 由 `scripts/create_hw_project.tcl` 生成。主要 IP 和 RTL
模块如下：

| 模块 | 作用 |
| --- | --- |
| `XDMA` | `PCIe Gen3 x16` endpoint，提供 memory-mapped `H2C`/`C2H` DMA 和 `BAR` 映射的 `AXI-Lite` master。 |
| `DDR4 MIG` | U200 `DDR4 C0` 控制器，存储 `TX` 描述符、`TX` 载荷和 `RX` capture ring。 |
| `SmartConnect` | 仲裁主机 DMA、`TX` 读者和 `RX` ring writer 对 `DDR4` 的访问，也负责 `AXI-Lite` 控制访问路由。 |
| `trace_replay_core` | 每端口 `TX` 回放核心，包含 `AXI-Lite` 寄存器、`DDR4` trace reader、调度器和 `TX` engine。 |
| `ddr_trace_reader` | 从 `DDR4` 读取 64 字节描述符和载荷 beat。 |
| `ddr_stream_reader` | 在 `STREAM` 模式下读取有限 stream buffer 或主机持续补充的 `DDR4` ring。 |
| `host_stream_parser` | 解析一个 64 字节 stream header beat 和后续包载荷 beat。 |
| `replay_scheduler` | 维护回放相对 tick 计数器，并根据描述符 gap 释放包。 |
| `replay_tx_engine` | 把被调度的 payload beat 转成 512-bit `CMAC TX AXI-Stream` 帧。 |
| `axis_sync_fifo` | 同步 `AXI-Stream` 预取 FIFO；大深度 FIFO 使用 Xilinx `XPM` block RAM。 |
| `axis_async_fifo` | 在 `DDR4` UI 时钟和 `CMAC` user clock 之间跨时钟。 |
| `rx_capture_bd_core` | 每端口 `RX` 统计和截断包 `DDR4` ring capture。 |
| `CMAC0` / `CMAC1` | 连接 `QSFP0` 和 `QSFP1` 的 100G Ethernet MAC。 |

调试阶段可以设置 `TRAFFIC_REPLAY_PORT_COUNT=1` 生成单接口硬件工程。
这是构建时裁剪，不是运行时简单关闭：生成的 block design 会省略
`replay_core_1`、`rx_cap_1`、`tx_axis_fifo_1` 和 `CMAC1`，并同步缩小相关
`SmartConnect` 的接口数量。默认值是 `2`，也就是完整双端口原型。

当前 `AXI-Lite` 地址映射：

```text
0x00000 - 0x0ffff  TX0 replay registers
0x10000 - 0x1ffff  TX1 replay registers
0x20000 - 0x2ffff  RX0 capture/stat registers
0x30000 - 0x3ffff  RX1 capture/stat registers
0x40000 - 0x4ffff  DDR4 controller control window
```

单接口 build 中只会存在 `TX0`、`RX0` 和 `DDR4` 控制窗口；主机命令应使用
`--port 0`。

每个 TX 端口的 `STREAM` ring 控制寄存器：

```text
0x00a0 STREAM_WR_LO       Host producer pointer, low 32 bits
0x00a4 STREAM_WR_HI       Host producer pointer, high 32 bits
0x00a8 STREAM_RD_LO       FPGA consumer pointer, low 32 bits
0x00ac STREAM_RD_HI       FPGA consumer pointer, high 32 bits
0x00b0 STREAM_RING_LO     DDR ring size in bytes, low 32 bits
0x00b4 STREAM_RING_HI     DDR ring size in bytes, high 32 bits
0x00b8 STREAM_CTRL        bit 0 = EOF
0x00bc STREAM_STATUS      reader state, ring mode, EOF, overrun, empty-wait flags
0x00c0 STREAM_LEVEL_LO    committed bytes not yet consumed, low 32 bits
0x00c4 STREAM_LEVEL_HI    committed bytes not yet consumed, high 32 bits
```

TX/RX 端口连接：

```text
TX0: replay_core_0 -> tx_axis_fifo_0 -> CMAC0 TX -> QSFP0
TX1: replay_core_1 -> tx_axis_fifo_1 -> CMAC1 TX -> QSFP1

RX0: QSFP0 -> CMAC0 RX -> rx_cap_0 -> DDR ring writer
RX1: QSFP1 -> CMAC1 RX -> rx_cap_1 -> DDR ring writer
```

## Trace 描述符格式

`PRELOAD` 和 `LOOP` 模式使用两个二进制文件：

* `desc.bin`：每包一个固定大小描述符。
* `data.bin`：包载荷，按 64 字节 AXI data beat 补齐。

每个描述符固定 64 字节，小端格式，并自然对齐到一个 512-bit AXI beat。
硬件从下面的地址读取第 `N` 个描述符：

```text
descriptor_address = DESC_BASE + N * 64
```

描述符布局：

| 字节偏移 | RTL bits | 字段 | 宽度 | 说明 |
| --- | --- | --- | --- | --- |
| `0x00` | `[63:0]` | `gap_ticks` | 64 bits | 包间隔，单位为 replay clock tick。`START_TIME=0` 时，第一个包也会等待第一个 descriptor gap。 |
| `0x08` | `[95:64]` | `data_word_offset` | 32 bits | 载荷相对 `DATA_BASE` 的偏移，单位为 64 字节 word。 |
| `0x0c` | `[111:96]` | `frame_len` | 16 bits | 有效帧字节数。FCS 不存储，由 CMAC 在 TX 侧插入。 |
| `0x0e` | `[127:112]` | `flags` | 16 bits | 预留字段，当前工具写 `0`。 |
| `0x10` | `[511:128]` | `reserved` | 48 bytes | 预留，当前应写 0。 |

等价 C 结构：

```c
struct replay_desc {
    uint64_t gap_ticks;
    uint32_t data_word_offset;
    uint16_t frame_len;
    uint16_t flags;
    uint8_t  reserved[48];
};
```

载荷地址计算：

```text
payload_address = DATA_BASE + data_word_offset * 64
payload_beats   = ceil(frame_len / 64)
```

`data.bin` 中每个包从 64 字节边界开始。如果 `frame_len` 不是 64 的倍数，
主机会补齐最后一个 beat，TX engine 根据 `frame_len` 生成 `TKEEP`，只发送
有效字节。当前 `pcap2trace.py` 默认把短帧补到 60 字节，不存 Ethernet FCS。

`STREAM` 模式使用 `DDR4` 中的 stream buffer。buffer 是连续的 packet record：

```text
64-byte stream header for packet 0
64-byte-aligned payload for packet 0
64-byte stream header for packet 1
64-byte-aligned payload for packet 1
...
```

stream header 的前 16 字节和 `replay_desc` 相同。`gap_ticks`、`frame_len`
和 `flags` 被 FPGA stream parser 使用；`data_word_offset` 在 `STREAM` 模式
下忽略，应写 `0`。载荷紧跟 header，并补齐到 64 字节边界。FPGA 会从
`DESC_BASE` 读取恰好 `TRACE_BYTES` 字节，所以主机必须把 `DESC_BASE` 配成
stream buffer 基地址，把 `TRACE_BYTES` 配成完整 stream buffer 大小。

## 仓库结构

```text
bitstreams/    选中的 bitstream 归档和每版本说明
constraints/   U200 和 stub XDC 约束
docs/images/   架构图和验证截图
rtl/           回放、CDC、RX capture 的 SystemVerilog/Verilog
scripts/       Vivado 工程创建、仿真、实现、烧录脚本
sim/           XSim testbench
software/      pcap 转换、XDMA loader、控制 CLI 等主机端工具
```

## 环境要求

FPGA 构建主机：

* Linux host，安装 `Vivado 2020.2`。
* 具备 `CMAC`、`XDMA`、`DDR4` 和相关 IP 的 Xilinx license。
* Bash 和标准 Linux 开发工具链。

目标机器：

* 插有 `Alveo U200` 的 Linux host。
* Xilinx `XDMA` reference driver。
* 用于 JTAG 烧录的远程 `hw_server`。
* 两个 `QSFP` 100G 光口。当前 smoke test 使用 `QSFP0` 与 `QSFP1` 光纤互联。

## 构建

创建 Vivado 硬件工程：

```bash
source /tools/Xilinx/Vivado/2020.2/settings64.sh
export TRAFFIC_REPLAY_HW_BUILD_ROOT=/home/user/tr_build_dual
export TRAFFIC_REPLAY_ENABLE_ILA=0
export TRAFFIC_REPLAY_PORT_COUNT=2
bash scripts/run_vivado.sh hwbd
```

需要交互检查时打开 Vivado GUI：

```bash
vivado /home/user/tr_build_dual/vivado_hw/traffic_replay_hw.xpr
```

运行 implementation 并生成 bitstream：

```bash
source /tools/Xilinx/Vivado/2020.2/settings64.sh
export TRAFFIC_REPLAY_HW_BUILD_ROOT=/home/user/tr_build_dual
export TRAFFIC_REPLAY_ENABLE_ILA=0
export TRAFFIC_REPLAY_PORT_COUNT=2
export TRAFFIC_REPLAY_VIVADO_JOBS=1
bash scripts/run_vivado.sh hwbit_existing
```

生成的 bitstream 位于：

```text
$TRAFFIC_REPLAY_HW_BUILD_ROOT/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.bit
```

为了加快 bring-up，可以生成单接口调试版本：

```bash
source /tools/Xilinx/Vivado/2020.2/settings64.sh
export TRAFFIC_REPLAY_HW_BUILD_ROOT=/home/user/tr_hw_300_oneport_bd
export TRAFFIC_REPLAY_ENABLE_ILA=0
export TRAFFIC_REPLAY_PORT_COUNT=1
bash scripts/run_vivado.sh hwbd
bash scripts/run_vivado.sh hwbit_existing
```

该模式只生成 `TX0`/`RX0`，主机命令应使用 `--port 0`。已归档的单端口调试
版本 `bitstreams/20260629_185452_oneport_300mhz_timing_clean_tested/` 在
300 MHz post-route 时序收敛，并包含对应测试说明。

## Bitstream 归档

重要硬件镜像归档在 `bitstreams/` 下。每个版本应包含 `.bit` 文件、匹配的
`.ltx` 文件以及一份 TXT 说明，记录 source commit、SHA256、build root 和
验证状态。

归档命令示例：

```bash
bash scripts/archive_bitstream.sh \
  --bitfile /home/user/tr_build_dual/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.bit \
  --ltx /home/user/tr_build_dual/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.ltx \
  --name pre_stream_dual_qsfp_loop_verified \
  --build-root /home/user/tr_build_dual \
  --notes "H2C/C2H DDR readback passed; TX0->RX1 and TX1->RX0 loopback passed."
```

归档 TXT 是该硬件镜像的审计记录。烧录旧 bitstream 前，应比对 TXT 中的
SHA256 和本地文件。

## 烧录和 PCIe 重扫

通过远程 hardware server 烧录 U200：

```bash
source /tools/Xilinx/Vivado/2020.2/settings64.sh
bash scripts/run_vivado.sh program \
  /home/user/tr_build_dual/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.bit
```

通过 JTAG 重新配置 PCIe endpoint 之后，Linux host 必须重扫 PCIe 或重启。
典型流程：

```bash
sudo rmmod xdma 2>/dev/null || true
echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/remove
echo 1 | sudo tee /sys/bus/pci/rescan
sudo insmod /home/user/dma_ip_drivers/XDMA/linux-kernel/xdma/xdma.ko
lspci -nn -d 10ee:
ls -l /dev/xdma*
```

期望 PCIe 设备 ID：

```text
01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]
```

## 主机端工具

生成确定性的 Ethernet/IPv4/UDP pcap 测试流量：

```bash
python3 /home/user/traffic_replay_software/gen_synthetic_pcap.py \
  --out /home/user/pcap_tests/udp_1518_1M.pcap \
  --packet-count 1000000 \
  --frame-len 1518 \
  --gap-ticks 0 \
  --vary-flow
```

把 classic pcap 转成 replay trace：

```bash
python3 /home/user/traffic_replay_software/pcap2trace.py \
  /home/user/input.pcap \
  --out-dir /home/user/trace_out \
  --tick-hz 300000000
```

转换结果：

```text
desc.bin
data.bin
manifest.json
```

加载 trace 到 TX0 并启动 `PRELOAD` 回放：

```bash
sudo python3 /home/user/traffic_replay_software/xdma_load_trace.py \
  --port 0 \
  --manifest /home/user/trace_out/manifest.json \
  --desc-base 0x00000000 \
  --data-base 0x10000000 \
  --mode preload
```

加载 trace 到 TX1，使用独立的 DDR 地址范围：

```bash
sudo python3 /home/user/traffic_replay_software/xdma_load_trace.py \
  --port 1 \
  --manifest /home/user/trace_out/manifest.json \
  --desc-base 0x01000000 \
  --data-base 0x11000000 \
  --mode preload
```

将 descriptor/data trace 转成 `STREAM` buffer：

```bash
python3 /home/user/traffic_replay_software/trace_to_stream.py \
  --manifest /home/user/trace_out/manifest.json \
  --out /home/user/trace_out/stream.bin
```

加载有限 stream buffer 并启动 `STREAM` 回放：

```bash
sudo python3 /home/user/traffic_replay_software/xdma_stream_load.py \
  --port 0 \
  --manifest /home/user/trace_out/stream_manifest.json \
  --stream-base 0x20000000
```

当 stream 大于选定 FPGA DDR 回放窗口时，使用 `DDR4` ring 持续补充：

```bash
sudo python3 /home/user/traffic_replay_software/xdma_stream_ring.py \
  --port 0 \
  --manifest /home/user/trace_out/stream_manifest.json \
  --ring-base 0x20000000 \
  --ring-size 0x08000000 \
  --prefill-bytes 0x02000000 \
  --timeout 60
```

构建并运行吞吐更高的 C++ feeder：

```bash
cd /home/user/traffic_replay_software
make xdma_stream_ring_fast

./xdma_stream_ring_fast \
  --port 0 \
  --manifest /home/user/trace_out/stream_manifest.json \
  --ring-base 0x20000000 \
  --ring-size 0x08000000 \
  --prefill-bytes 0x04000000 \
  --batch-bytes 0x02000000 \
  --read-bytes 0x02000000 \
  --queue-depth 4 \
  --timeout 120 \
  --feed-timeout 120
```

两个 ring feeder 都只提交完整 packet record。loader 轮询 `STREAM_RD_PTR`，
用 `ring_size - (write_ptr - read_ptr)` 计算空闲空间，通过
`/dev/xdma0_h2c_0` 写入 record，然后推进 `STREAM_WR_PTR`。这样不会破坏
回放精度，因为发包时间仍完全由 FPGA scheduler 控制；主机只决定未来 record
何时进入 DDR ring。

查询状态：

```bash
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 status
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 status
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 rx-status
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 rx-status
```

配置 RX capture ring：

```bash
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py \
  --port 0 rx-config --ring-base 0x32000000 --ring-size 0x00100000 --truncate-bytes 128
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 rx-clear
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 rx-enable
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 rx-capture on
```

`RX` capture 会向 `DDR4` 写完整 64 字节 beat。`rx_bytes` 是从 `TKEEP` 得到
的有效字节数，`captured_bytes` 是 ring 中实际写入的 64 字节对齐字节数。

## STREAM 模式和压力测试

`STREAM` 模式由 DDR 支撑。主机使用 memory-mapped `XDMA H2C` 把 stream
record 放入 `DDR4`；FPGA `ddr_stream_reader` 读取 512-bit AXI beat，喂给
`host_stream_parser`，再由 replay scheduler 按 record 中的 gap 调度发包。

两种 `STREAM` 用法：

| 用法 | 场景 | 寄存器配置 |
| --- | --- | --- |
| 有限 buffer | 整个 stream 能放进一段 FPGA DDR。 | `DESC_BASE=stream_base`, `TRACE_BYTES=stream_size`, `STREAM_RING_SIZE=0`。 |
| DDR ring | replay stream 大于选定 FPGA DDR 窗口。 | `DESC_BASE=ring_base`, `TRACE_BYTES=0`, `STREAM_RING_SIZE=ring_size`，主机推进 `STREAM_WR_PTR`，FPGA 推进 `STREAM_RD_PTR`。 |

DDR ring 是面向大容量 pcap 的模式。主机拥有 producer pointer，FPGA 拥有
consumer pointer。主机不能写超过 `ring_size - (write_ptr - read_ptr)` 的
空间；如果写指针推进过远，FPGA 会在 `STREAM_STATUS` 中报告 overrun。

更多设计细节见 `docs/stream_ring_mode.md`。

运行 synthetic zero-gap 最大吞吐 sweep：

```bash
sudo python3 /home/user/traffic_replay_software/stream_stress_test.py \
  --port 0 \
  --frame-sizes 64,128,256,512,1024,1518 \
  --packet-count 100000 \
  --gap-ticks 0 \
  --stream-base 0x20000000 \
  --csv /home/user/stream_stress.csv
```

常用调试开关：

* `--force-link-up`：没有光链路时强制打开 replay gate，仅用于 bring-up。
* `--force-tx-ready`：下游 `CMAC`/FIFO 未 ready 时也 drain replay core。
  该选项会绕过真实 TX backpressure，不应用于最终吞吐数据。

压力脚本报告：

* `load_gbps`：主机向 FPGA DDR 加载 stream buffer 的速率。
* `hw_gbps`：根据 `tx_bytes` 和硬件 replay tick counter 计算的 FPGA 回放速率。
* `late_packets` 和 `underrun_packets`：调度迟到和 payload 饥饿指标。

## 硬件验证套件

`hw_validation_suite.py` 会运行常用的烧录后检查，并在目标 host 上保留带时间戳
的日志目录。它适合比较重要 bitstream 版本，因为每次运行记录同样的证据：

* `XDMA H2C` / `C2H` 确定性 `DDR4` readback。
* synthetic `pcap` 生成、`pcap2trace.py` 转换和 `trace_to_stream.py` 转换。
* 有限 buffer `STREAM` 吞吐 sweep。
* 超出 ring 大小的 `DDR4` ring `STREAM` 回放。
* 可选的 `QSFP0` -> `QSFP1` RX loopback 统计和截断 sample ring capture。

烧录后快速 smoke：

```bash
cd /home/user/traffic_replay_software
make xdma_stream_ring_fast

sudo python3 /home/user/traffic_replay_software/hw_validation_suite.py \
  --profile smoke \
  --port 0 \
  --rx-port 1 \
  --ring-loader cpp
```

更大的 stress：

```bash
sudo python3 /home/user/traffic_replay_software/hw_validation_suite.py \
  --profile stress \
  --port 0 \
  --rx-port 1
```

本节中的 STREAM 硬件结果使用归档 bitstream
`bitstreams/20260628_140628_stream_fast_bram_fifo8192_experimental/`，并在远程
U200 上烧录测试，`QSFP0` 与 `QSFP1` 通过 100G 光纤连接。

该 build 的重要结果：

* bitstream 生成成功，Vivado 报 `0 Errors`。
* 最终时序未完全收敛：`WNS=-0.247 ns`，`TNS=-51.325 ns`。
* 烧录后 `XDMA H2C/C2H` 确定性 `DDR4` readback 通过。
* `STREAM` ring smoke：`1000` 个 1518 字节包，`gap_ticks=30000`，
  `late=0`，`underrun=0`。
* synthetic `pcap -> trace -> stream -> DDR ring replay`：`10000` 个包，
  `underrun=0`。
* `QSFP0` -> `QSFP1` 低速 RX loopback：RX1 看到 `2000` 个包。

C++ DDR-ring `STREAM`，TX0，`100000` 个 1518 字节包：

| Gap ticks | 目标回放 Gbps | 完成 | TX packets | Late packets | Underrun packets |
| ---: | ---: | :---: | ---: | ---: | ---: |
| `720` | `5.060` | yes | `100000` | `0` | `0` |
| `600` | `6.072` | yes | `100000` | `0` | `0` |
| `480` | `7.590` | yes | `100000` | `0` | `0` |
| `360` | `10.120` | yes | `100000` | `24820` | `7940879` |
| `300` | `12.144` | yes | `100000` | `56812` | `14888217` |
| `240` | `14.893` | yes | `100000` | `76783` | `10944245` |

这版动态 ring 在 1518 字节包下最快的 no-late/no-underrun 点约为
`7.59Gbps`。C++ feeder 相比早期 Python feeder 有明显提升，但当前
memory-mapped `XDMA H2C pwrite` 路径持续补 ring 的速率约在 `10Gbps` 附近，
无法无限期支撑 `100Gbps` 动态回放。

有限 buffer `STREAM`，TX0，`100000` 个 1518 字节包：

| Gap ticks | 完成 | TX packets | TX bytes | Replay Gbps | Late packets | Underrun packets |
| ---: | :---: | ---: | ---: | ---: | ---: | ---: |
| `0` | yes | `100000` | `151800000` | `96.983` | `100000` | `1012270` |
| `36` | yes | `100000` | `151800000` | `96.986` | `99989` | `1012317` |

这些有限 buffer 结果说明 FPGA 大包路径可以接近 `100Gbps`，但 zero-gap 和
近线速测试仍会报告 `late_packets` 与 `underrun_packets`，因此这是吞吐压力
结果，不是最终精确回放结果。

单端口 preload timing-clean build：

`bitstreams/20260629_185452_oneport_300mhz_timing_clean_tested/` 使用
`TRAFFIC_REPLAY_PORT_COUNT=1` 构建，并已烧录到远程 U200。由于该调试镜像
有意省略 `CMAC1`，测试时使用了 `force_link_up` 和 `force_tx_ready` 做内部
replay 通路验证。

| 测试 | 包数 | 帧字节数 | Gap ticks | 线速口径 Gbps | Late packets | Underrun packets |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 大包 target-100G preload | `100000` | `1518` | `37` | `99.761` | `0` | `0` |
| 大包 max-drain preload | `100000` | `1518` | `0` | `138.323` | `100000` | `0` |
| 小包 max-drain preload | `100000` | `64` | `0` | `81.827` | `100000` | `0` |
| 小包 target-100G preload | `100000` | `64` | `2` | `88.949` | `81354` | `0` |

其中 `gap=0` 是内部最大 drain rate 压力测试。真正有代表性的精确/吞吐
结果是大包 `gap=37`：在没有 `late` 和 `underrun` 的情况下达到接近 100G
线速。

## PRELOAD 模式状态

当前双端口 `PRELOAD` 工作的详细说明见
[`docs/preload.md`](docs/preload.md)。这是第一版把 replay scheduler、
DDR reader、TX path、CMAC link 和 RX counter path 放在真实
`QSFP0` <-> `QSFP1` 100G 光纤环回上一起测试的双端口版本。

归档镜像位于：

```text
bitstreams/20260701_203500_dual_preload_gap38_mixed_timing_violation/
```

这版 bitstream 已经生成成功，但仍是实验版本，因为 post-route timing 还有
轻微负 slack：`WNS=-0.018ns`，`TNS=-0.228ns`，setup failing endpoints
为 `21`。

关键结果截图如下：

![Preload validation terminal summary](docs/images/preload_20260701_terminal.png)

| 测试 | 包数 | Gap ticks | TX packets | RX packets | Late | Underrun | 线速口径 Gbps | 说明 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `1518B` sweep 最佳通过点 | `20000` | `38` | `20000` | `20000` | `0` | `0` | `97.386` | RX error 仍有 `1255`。 |
| `1518B` 过载边界 | `20000` | `37` | `2103` | `2083` | `0` | `0` | timeout | 下游 `tready` 背压导致 replay core 停住。 |
| `64B` sweep 最佳通过点 | `200000` | `3` | `200000` | `200000` | `0` | `0` | `70.400` | RX error 为 `0`，但没到 100G。 |
| `64B` 过载边界 | `200000` | `2` | `502` | invalid | `0` | `0` | timeout | `gap=2` 等价于约 `105.6Gbps` 线速口径，已经超过物理口。 |
| 混合包长 | `120000` | 每包不同 | `120000` | `120000` | `0` | `0` | `96.158` | 调度误差只有 `+11` ticks，但 RX error 仍有 `128`。 |

这轮最重要的结论是：大包 `PRELOAD` 已经接近 100G 物理极限，混合包调度
精度也很好。当前瓶颈不是主机装载速度，因为 `PRELOAD` 模式下 timed replay
窗口里 Host 已经退出数据通路。剩余关键问题是双端口时序仍未完全收敛，
RX error/字节计数还要清零，以及过载后需要一个 BAR 可控的完整 TX datapath
soft reset。

## 验证情况

运行 `RTL` 仿真：

```bash
source /tools/Xilinx/Vivado/2020.2/settings64.sh
bash scripts/run_vivado.sh sim
```

当前 `XSim` testbench 覆盖：

* Host stream parser path：发出 2 个包。
* DDR-backed `STREAM` buffer path：从 AXI read memory model 发出 2 个包。
* DDR-backed ring `STREAM` path：发出一个已提交包，等待主机写指针推进，再继续发出下一个包。
* `DDR4` preload path：从 AXI read memory model 发出 3 个包。

主机端工具语法检查：

```bash
python3 -m py_compile \
  software/traffic_replay_cli.py \
  software/xdma_load_trace.py \
  software/xdma_stream_load.py \
  software/xdma_stream_ring.py \
  software/ddr_readback_check.py \
  software/pcap2trace.py \
  software/trace_to_stream.py \
  software/gen_synthetic_pcap.py \
  software/gen_synthetic_trace.py \
  software/stream_stress_test.py \
  software/hw_validation_suite.py
```

烧录后运行基础 `XDMA` `DDR4` readback：

```bash
sudo python3 ddr_readback_check.py
```

代表性输出截图：

![XDMA probe and DDR readback](docs/images/xdma_probe_and_ddr.png)

连接 `QSFP0` 和 `QSFP1` 后检查双端口 link 和 `RX` 状态：

![Dual-port link status](docs/images/dual_link_status.png)

双向 packet length sweep：

![Packet length sweep](docs/images/packet_length_sweep.png)

三包 DDR preload trace 双向测试：

![Three-packet trace result](docs/images/three_packet_trace.png)

目前硬件 smoke test 已经证明：

* Host `H2C`/`C2H` DMA 可以读写 `DDR4`。
* `XDMA` user `BAR` 上的 `AXI-Lite` 寄存器访问正常。
* `TX0` 和 `TX1` 能从 `DDR4` 读取描述符和 payload。
* 调度器和 `TX` engine 可以发包并更新计数。
* DDR-backed 有限 `STREAM` 模式通过 RTL 仿真和硬件吞吐测试。
* DDR-backed ring `STREAM` 模式通过 RTL 仿真和 U200 硬件测试。
* `QSFP0` 和 `QSFP1` 的 `CMAC` link 能在 100G 光纤互联下 up。
* `TX0` -> `RX1` 和 `TX1` -> `RX0` 在通过的 loopback 测试中包计数可用。
  大包和混合包的 RX byte/error 计数仍需要继续修正，详见
  [`docs/preload.md`](docs/preload.md)。
* `RX` capture 可以把最近包窗口写入 `DDR4` 并读回。

## 当前限制

* 最新双端口 `PRELOAD` 镜像功能可用，但仍是实验版本：post-route physopt
  timing 为 `WNS=-0.018 ns`，`TNS=-0.228 ns`。
* 大包 `PRELOAD` 在 `1518B`、`gap=38` 时达到 `97.386Gbps` 线速口径，
  没有 `late` 和 `underrun`，但 RX error counter 还没有清零。
* 小包 `64B` `PRELOAD` 在 `gap=3` 时稳定，约 `70.400Gbps` 线速口径。
  当前整数 tick、每 tick 最多释放一个包的 scheduler 还不能表达 100G
  最小包所需的平均间隔，除非改成 fractional/multi-packet 调度架构。
* 过载 `PRELOAD` 测试会填满下游 TX async FIFO/CMAC 侧，并以
  `m_tx_axis_tready=0` 停住。当前 `stop`/`clear` 会复位 replay core，
  但还没有覆盖整个每端口 TX datapath。
* BRAM-FIFO STREAM build 功能可用，但不是 timing-clean：
  implementation timing 为 `WNS=-0.247 ns`。
* 有限 buffer `STREAM` 对 1518 字节包可达到约 `96.98Gbps`，但近线速测试
  仍出现 `late_packets` 和 `underrun_packets`，因此还不是最终精确回放结果。
* 动态 DDR ring `STREAM` 已用 C++ feeder 功能验证。当前 1518 字节包最快
  no-late/no-underrun 点约 `7.59Gbps`。memory-mapped `XDMA H2C pwrite` 在
  该系统中持续补 ring 约为 `10Gbps` 量级，无法长期喂满 `100Gbps` 回放。
* 真正的 `100Gbps` 动态回放需要新的输入架构：直接 `XDMA`/`QDMA`
  `AXI4-Stream H2C`、更大的 kernel/user DMA batch、更低拷贝主机 loader，
  以及 FPGA 侧带多个 outstanding DDR read 的更强 prefetch。当前仓库已经有
  C++ memory-mapped feeder 和更深 BRAM prefetch FIFO，但尚未把 PCIe 路径
  替换成 QDMA。
* `DDR4` trace reader 仍比较简单，descriptor cache、payload prefetch、
  多 outstanding read 等仍是后续工作。
* `RX` capture 是统计和最近包调试窗口，不是全速包记录器。
* 当前 `pcap` converter 支持 classic `pcap`，暂不支持 `pcapng`。
* 通过真实 DDoS 防御设备的端到端系统测试仍是后续集成工作。
