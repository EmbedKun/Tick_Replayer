# Traffic Replay on Xilinx Alveo U200

这个仓库是基于 Xilinx Alveo U200 的单端口 100Gbps 流量回放仪工程。当前版本已经跑通主链路：

Host 通过 PCIe XDMA 把 trace 写入 FPGA DDR4，FPGA 从 DDR4 读取包描述符和包数据，按照 descriptor 中的包间隔调度，经 512-bit AXI4-Stream 送到 QSFP0 CMAC TX。当前重点是先完成 `PRELOAD` 和 `DDR LOOP` 两种 DDR 回放模式，以及无光纤时的 ILA bring-up。

## 工程位置

- 源码工程：`C:\Users\mkxue\Desktop\traffic_replay`
- Vivado 版本：`D:\Xilinx\Vivado\2020.2\bin\vivado.bat`
- Vivado GUI 工程：`D:\tr_build_debug\vivado_hw\traffic_replay_hw.xpr`
- 已生成 bitstream：`D:\tr_build_debug\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper.bit`
- 已生成 ILA probes：`D:\tr_build_debug\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper.ltx`
- 远程 U200 主机：`172.22.5.106`
- 远程 hw_server：`172.22.5.106:3121`

不要把 SSH 密码、私钥、license 文件写入仓库。

## 当前完成度

已完成：

- U200 硬件 BD 工程脚本化生成。
- PCIe XDMA endpoint，设备 ID 固定为 `10ee:903f`，class code 为 `058000`。
- Host 通过 XDMA H2C/C2H 访问 FPGA DDR4 C0。
- Host 通过 XDMA user BAR 访问 FPGA AXI-Lite 控制寄存器。
- DDR 预加载回放模式 `PRELOAD`。
- DDR 循环回放模式 `LOOP`，`LOOP_COUNT=0` 表示无限循环。
- 无光纤调试开关 `DEBUG_CTRL[0] force_link_up`。
- CMAC TX 侧 ILA，能抓 `tvalid/tlast/tuser/tkeep/tdata[31:0]`。
- Linux 命令行工具：pcap 转 trace、加载 trace、控制/读状态。
- 仿真、综合、实现、bitstream、远程烧录、XDMA 驱动加载、DDR 读写和 ILA 抓包验证。

暂未完成：

- XDMA/QDMA streaming H2C 直连 `STREAM` 模式的 BD 接线。
- 完整 traffic_replay 风格的高层 CLI，例如一条命令完成 pcap 转换、下载、配置、启动、状态轮询。
- 真实光纤链路下的 CMAC link-up、线速发包、外部网卡收包验证。
- 多端口 100Gbps 回放。
- 精度优化版调度架构。当前 scheduler 在 DDR UI clock 域，后续若追求极限间隔精度，建议把 scheduler/TX 前移到 CMAC TX user clock 域，并在 DDR read path 后增加更深预取 FIFO。
- 高吞吐压力测试和大 pcap 长时间稳定性测试。
- pcapng 支持。当前 `pcap2trace.py` 只支持 classic pcap。

## 总体架构图

```mermaid
flowchart LR
  subgraph "Host Linux"
    PCAP["pcap file"]
    CONVERT["pcap2trace.py<br/>desc.bin + data.bin"]
    LOAD["xdma_load_trace.py<br/>write DDR + start"]
    CLI["traffic_replay_cli.py<br/>status/control"]
    XDMA_DRV["Xilinx XDMA driver<br/>/dev/xdma0_*"]
  end

  subgraph "PCIe Gen3 x16"
    XDMA["XDMA IP<br/>device 10ee:903f"]
  end

  subgraph "FPGA DDR UI Clock Domain"
    DDR["DDR4 C0<br/>trace storage"]
    REGS["axi_lite_regs.sv<br/>control/status"]
    READER["ddr_trace_reader.sv<br/>read descriptor/data"]
    SCHED["replay_scheduler.sv<br/>gap tick scheduler"]
    TX["replay_tx_engine.sv<br/>packetize AXIS"]
  end

  subgraph "CMAC TX Clock Domain"
    FIFO["axis_async_fifo.v<br/>CDC FIFO"]
    ILA["cmac_tx_ila<br/>TX debug probes"]
    CMAC["CMAC QSFP0<br/>512-bit AXIS TX"]
    QSFP["QSFP0 100G port"]
  end

  PCAP --> CONVERT
  CONVERT --> LOAD
  LOAD --> XDMA_DRV
  CLI --> XDMA_DRV
  XDMA_DRV --> XDMA
  XDMA -- "M_AXI H2C/C2H" --> DDR
  XDMA -- "M_AXI_LITE user BAR" --> REGS
  REGS -- "mode/base/count/start/force-link" --> READER
  DDR --> READER
  READER -- "meta: gap,len,flags" --> SCHED
  READER -- "payload AXIS" --> TX
  SCHED -- "packet release" --> TX
  TX -- "512-bit AXIS" --> FIFO
  FIFO --> ILA
  ILA --> CMAC
  CMAC --> QSFP
```

## 目录结构

```text
rtl/          回放核心 RTL
sim/          XSim testbench
scripts/      Vivado 工程、仿真、综合、实现、烧录、ILA 抓取脚本
software/     pcap 转 trace、XDMA trace loader、控制 CLI
constraints/  U200 硬件约束和 stub 约束
reports/      时序报告、ILA CSV 等验证输出
docs/         维护笔记
```

注意：`build/`、`.Xil/`、Vivado 生成物、trace 输出不纳入版本管理。`build/corundum_ref/` 只是参考资料缓存，不是当前设计的主源码。

## 主要模块

| 模块 | 文件 | 功能 | 时钟域 |
| --- | --- | --- | --- |
| 顶层回放核心 | `rtl/trace_replay_core.sv` | 连接寄存器、DDR reader、scheduler、TX engine，选择 DDR/stream 数据源 | DDR UI clock |
| AXI-Lite 寄存器 | `rtl/axi_lite_regs.sv` | Host 控制面，模式、地址、包数、loop、force-link、状态计数器 | DDR UI clock |
| DDR trace reader | `rtl/ddr_trace_reader.sv` | 从 DDR 读 64B descriptor，再按 descriptor 读 payload | DDR UI clock |
| 调度器 | `rtl/replay_scheduler.sv` | 按 `gap_ticks` 控制每个包何时释放给 TX engine | DDR UI clock |
| TX engine | `rtl/replay_tx_engine.sv` | 把 payload AXIS 和 packet metadata 组合成 CMAC TX AXIS 包流 | DDR UI clock |
| 异步 FIFO | `rtl/axis_async_fifo.v` | DDR UI clock 到 CMAC TX user clock 的 AXIS CDC | DDR UI clock / CMAC TX clock |
| Host stream parser | `rtl/host_stream_parser.sv` | RTL 已有 stream parser，用于未来 host streaming 模式 | DDR UI clock |
| BD wrapper core | `rtl/traffic_replay_bd_core.v` | 把 RTL core 包装成 Vivado BD module | DDR UI clock |
| 包格式公共定义 | `rtl/traffic_replay_pkg.sv` | 数据宽度、keep 生成、descriptor 常量 | RTL package |
| stub top | `rtl/traffic_replay_top_stub.sv` | 快速 stub 综合检查 | stub |

## Block Design 连接关系

`scripts/create_hw_project.tcl` 创建完整 U200 硬件 BD，核心连接如下：

```text
PCIe x16 Gen3 XDMA
  M_AXI
    -> AXI clock converter
    -> DDR SmartConnect
    -> DDR4 C0

  M_AXI_LITE
    -> AXI-Lite clock converter
    -> control SmartConnect
    -> trace_replay_core AXI-Lite regs
    -> AXI-Lite register slice
    -> DDR4 control regs

DDR4 C0
  -> trace_replay_core M_AXI read path
  -> ddr_trace_reader
  -> replay_scheduler + replay_tx_engine
  -> axis_async_fifo
  -> CMAC QSFP0 TX

CMAC TX ILA
  probes: tvalid, tready_const, tlast, tuser, tkeep, tdata[31:0], stat_rx_aligned
```

PCIe refclk 使用 `util_ds_buf` 的 `IBUFDSGTE`，顶层暴露 `pcie_refclk_clk_p/n`。CMAC QSFP0 使用 4x25G CAUI-4，GT refclk 为 161.1328125 MHz。QSFP0 sideband 当前由 BD 绑为常量：`qsfp0_resetl=1`、`qsfp0_lpmode=0`、`qsfp0_refclk_reset=0`、`qsfp0_fs=2'b10`。

CMAC AXIS TX 当前配置没有对外提供 `tready`，因此 BD 显式把 `tx_axis_fifo/m_axis_tready` 绑为 1。ILA 里看到 `tvalid` 拉高、`tlast` 成帧，即表示 replay core 已经把包送到 CMAC TX 侧。

## 地址映射

XDMA `M_AXI` 访问 DDR：

```text
0x0000_0000_0000_0000 - 0x0000_0003_FFFF_FFFF  DDR4 C0, 16GB
```

XDMA `M_AXI_LITE` 访问控制面：

```text
0x0000_0000 - 0x0000_FFFF  replay control/status regs
0x0001_0000 - 0x0001_FFFF  DDR4 control regs
```

## 回放模式

`PRELOAD`：
Host 先把 `desc.bin` 和 `data.bin` 写入 DDR，再写 AXI-Lite 寄存器启动。当前主路径已实现并通过硬件验证。

`LOOP`：
与 `PRELOAD` 共用 DDR reader，到最后一个包后回到第一个包。`LOOP_COUNT=0` 表示无限循环。已实现并通过 ILA loop trace 验证。

`STREAM`：
RTL 中已有 `host_stream_parser.sv`，但当前 BD 没有把 XDMA H2C streaming 口接进来，所以系统级 streaming 模式暂未实现。

## Trace 格式

DDR 预加载和循环模式使用两个连续区域：

- descriptor 区：每包 64B。
- data 区：payload 按 64B 对齐连续存储。

descriptor 小端格式：

```c
struct replay_desc {
    uint64_t gap_ticks;
    uint32_t data_word_offset;  // 64B word offset from data_base
    uint16_t frame_len;
    uint16_t flags;
    uint8_t  reserved[48];
};
```

当前调度 tick 使用 DDR UI clock，建议生成 trace 时使用：

```powershell
python .\software\pcap2trace.py .\input.pcap --out-dir .\trace_out --tick-hz 300000000
```

## 寄存器表

AXI-Lite 数据宽度 32 bit：

```text
0x0000 CONTROL      bit0 start, bit1 stop, bit2 clear counters, bit3 pause
0x0004 MODE         0 preload, 1 stream, 2 loop
0x0008 STATUS       bit0 running, bit1 done, bit2 late, bit3 underrun,
                    bit4 physical_cmac_link_up, bit5 tx_gate_open
0x0010 DESC_BASE_LO
0x0014 DESC_BASE_HI
0x0018 DATA_BASE_LO
0x001c DATA_BASE_HI
0x0020 TRACE_BYTES_LO
0x0024 TRACE_BYTES_HI
0x0028 PKT_COUNT_LO
0x002c PKT_COUNT_HI
0x0030 LOOP_COUNT_LO    0 means infinite loop
0x0034 LOOP_COUNT_HI
0x0038 LOOP_GAP_LO
0x003c LOOP_GAP_HI
0x0040 START_TIME_LO    0 means start after first descriptor gap
0x0044 START_TIME_HI
0x0048 RATE_Q16_16      reserved; host should pre-scale gap_ticks for now
0x004c WATERMARK
0x0050 FIFO_LEVEL
0x0054 DEBUG_CTRL       bit0 force_link_up
0x0060 TX_PKTS_LO
0x0064 TX_PKTS_HI
0x0068 TX_BYTES_LO
0x006c TX_BYTES_HI
0x0070 LATE_PKTS_LO
0x0074 LATE_PKTS_HI
0x0078 UNDERRUN_PKTS_LO
0x007c UNDERRUN_PKTS_HI
```

## 如何打开 Vivado GUI 工程

如果已经生成过硬件 BD，直接打开：

```powershell
& D:\Xilinx\Vivado\2020.2\bin\vivado.bat D:\tr_build_debug\vivado_hw\traffic_replay_hw.xpr
```

如果要从脚本重新生成工程：

```powershell
$env:TRAFFIC_REPLAY_HW_BUILD_ROOT="D:\tr_build_debug"
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action hwbd
& D:\Xilinx\Vivado\2020.2\bin\vivado.bat D:\tr_build_debug\vivado_hw\traffic_replay_hw.xpr
```

默认硬件工程目录是 `D:\tr_build\vivado_hw`。本次调试为了避开已经打开的旧 Vivado GUI，使用的是 `D:\tr_build_debug\vivado_hw`。

## 常用命令

仿真：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action sim
```

stub 综合检查：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action synth
```

生成并校验 U200 硬件 BD：

```powershell
$env:TRAFFIC_REPLAY_HW_BUILD_ROOT="D:\tr_build_debug"
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action hwbd
```

完整生成硬件 bitstream：

```powershell
$env:TRAFFIC_REPLAY_HW_BUILD_ROOT="D:\tr_build_debug"
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action hwbit_existing
```

远程烧录已有 bitstream：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action program -Bitfile D:\tr_build_debug\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper.bit
```

抓取 CMAC TX ILA：

```powershell
& D:\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch -source .\scripts\capture_cmac_ila.tcl -tclargs D:\tr_build_debug\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper.ltx .\reports\cmac_tx_ila_capture.csv
```

Linux 上加载 trace 并启动：

```bash
python3 /home/user/traffic_replay_software/xdma_load_trace.py \
  --manifest /home/user/trace_out/manifest.json \
  --desc-base 0x00000000 \
  --data-base 0x10000000 \
  --mode preload
```

无光纤调试时打开 TX gate：

```bash
python3 /home/user/traffic_replay_software/traffic_replay_cli.py debug-force-link on
python3 /home/user/traffic_replay_software/traffic_replay_cli.py status
```

## 远程板卡启动流程

1. 本地生成 bitstream。
2. 本地通过 Vivado 连接远程 `hw_server` 烧录 U200。
3. 远程主机重启，让 PCIe endpoint 经过 PERST 重新训练和重新分配 BAR。
4. 远程确认枚举：

```bash
lspci -nn -d 10ee:
# 01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]
```

5. 远程加载 Xilinx XDMA driver：

```bash
cd /home/user/dma_ip_drivers
git checkout 2020.2
make -C XDMA/linux-kernel/xdma
sudo insmod XDMA/linux-kernel/xdma/xdma.ko
ls -l /dev/xdma*
```

6. 远程使用 `/home/user/traffic_replay_software/traffic_replay_cli.py` 和 `xdma_load_trace.py` 控制回放。

## 已验证结果

仿真：

- `powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action sim`
- XSim testbench 通过，输出 2 个包。

本地实现：

- `hwbd`：Vivado 2020.2 成功创建并 validate BD。
- `synth`：stub 顶层综合通过。
- `hwbit_existing`：完整 U200 bitstream 生成成功。
- 最终时序报告：`reports/hw_impl_timing_summary.rpt`
- 关键时序：`WNS=0.017ns`、`TNS=0.000ns`、失败端点 0。
- 报告中显示：`All user specified timing constraints are met.`
- bitgen 有 `Evaluation License Warning` critical warning；正式长期使用前需要确认 CMAC 等 IP license 不是限时 evaluation。

远程硬件：

- JTAG 烧录成功，Vivado 识别 1 个 MIG core 和 1 个 ILA core。
- 重启后 PCIe 枚举为 `Memory controller [0580] 10ee:903f`。
- XDMA driver `v2020.2.2` 成功 probe，识别 `config bar 1, user 0`。
- `/dev/xdma0_h2c_0`、`/dev/xdma0_c2h_0`、`/dev/xdma0_user` 均生成。
- DDR/XDMA 往返读写测试通过：
  - `0x00000000`，4KB，PASS。
  - `0x00100000`，64KB，PASS。
  - `0x10000000`，1MB，PASS。
- AXI-Lite 控制面可读写。
- `DEBUG_CTRL[0] force_link_up` 打开后 `tx_gate_open=yes`，关闭后恢复。
- 无光纤下 3 包 smoke trace 回放完成，`tx_packets=3`、`tx_bytes=252`。
- 使用足够 gap 时，`late_packets=0`、`underrun_packets=0`。
- loop trace 运行时，`scripts/capture_cmac_ila.tcl` 成功以 `tx_axis_fifo_m_axis_tvalid==1` 触发 ILA。
- ILA CSV：`reports/cmac_tx_ila_capture.csv`，可见 `tvalid` 有效、`tkeep=ffffffffffffffff`、`tdata_low=aaaaaaaa`。

## 重要实现细节

当前硬件 BD 把 replay core 放在 DDR UI clock 域，使用 `axis_async_fifo.v` 跨到 CMAC TX user clock 域。这样工程容易 bring-up，也便于 Host 写 DDR 后直接回放。

DDR reader 当前在 descriptor metadata 被 scheduler 接收后才发 payload read。如果首包 gap 太小，TX engine 可能先要数据而 DDR payload 尚未返回，此时会产生 `underrun`。硬件 smoke test 使用较大 gap 后，`late/underrun` 均为 0。后续做高精度/高吞吐版本时，应增加 descriptor/payload 预取队列。

`RATE_Q16_16` 目前保留，硬件没有做动态速率缩放。主机侧应在生成 trace 时预先把 pcap 时间间隔转换成当前 tick 频率下的 `gap_ticks`。

## 版本管理

当前重要提交：

```text
73a8f21073bb64561f46a665624c0eba1becda39  Bring up XDMA DDR replay debug flow
```

上传 GitHub 前可以先导出一份干净源码快照：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\export_github_sources.ps1 -Zip
```

导出结果：

```text
artifacts/github_source/traffic_replay/
artifacts/traffic_replay_github_source.zip
```

标准源码文件清单见 `GITHUB_SOURCE_MANIFEST.md`。Vivado 生成物、bitstream、日志、trace 输出和远程密码不应上传。

建议后续提交粒度：

1. RTL 行为变更。
2. Vivado/IP/BD 脚本变更。
3. 主机软件和寄存器协议变更。
4. 文档和测试向量变更。
