# Traffic Replay on Xilinx Alveo U200

这个仓库是 U200 单端口 100Gbps 流量回放仪的源码化工程骨架。目标是先把单端口 CMAC TX 方向跑通，并保留三种运行模式：

- `PRELOAD`：主机预先把 descriptor/data 搬到 U200 DDR，FPGA 从 DDR 按 pcap 时间间隔回放。
- `STREAM`：主机经 PCIe/QDMA 流式推送 header + payload，FPGA 实时调度发送。
- `LOOP`：主机预加载一段 trace 到 DDR，FPGA 在 DDR 中循环回放。

当前版本包含可仿真的核心 RTL、pcap 转 trace 工具、Vivado 2020.2 批处理脚本、远程 hw_server 烧录脚本。CMAC/QDMA/DDR 的板级 block design wrapper 下一步接入。

## 本机环境

- Windows 主机工程目录：`C:\Users\mkxue\Desktop\traffic_replay`
- Vivado：`D:\Xilinx\Vivado\2020.2\bin\vivado.bat`
- 目标器件：`xcu200-fsgd2104-2-e`
- Board part：`xilinx.com:au200:part0:1.3`
- 远程烧录 hw_server：`172.22.5.106:3121`

不要把 SSH 密码、私钥、license 文件写入仓库。

## 目录结构

```text
rtl/        FPGA 回放核心 RTL
sim/        XSim 仿真 testbench
scripts/    Vivado 创建工程、仿真、综合检查、远程烧录脚本
software/   主机端 pcap 转 trace 工具
docs/       架构和维护笔记
```

## RTL 数据路径

```text
AXI-Lite regs
    -> mode manager
        -> DDR trace reader      -> metadata/data mux
        -> host stream parser    -> metadata/data mux
    -> timestamp scheduler
    -> packet TX engine
    -> 512-bit AXI4-Stream to CMAC TX
```

核心接口统一使用 512-bit AXI4-Stream，对应 100G CMAC 常用 user-side 数据宽度。调度器使用 `clk` 域 64-bit tick 计数器，第一版按 `322.265625 MHz` CMAC TX user clock 估算，每 tick 约 3.1ns。

## Trace 格式

DDR 预加载和循环模式使用两个连续区域：

- descriptor 区：每包 64B，当前只用前 16B，后续可优化成 4 个 descriptor/beat。
- data 区：packet payload 按 64B 对齐连续存储。

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

主机流式模式中，每个包先发送 1 个 64B header beat，前 16B 与 descriptor 相同，随后发送 payload beat。

## 寄存器表

AXI-Lite 数据宽度 32 bit，偏移如下：

```text
0x0000 CONTROL      bit0 start, bit1 stop, bit2 clear counters, bit3 pause
0x0004 MODE         0 preload, 1 stream, 2 loop
0x0008 STATUS       bit0 running, bit1 done, bit2 late, bit3 underrun, bit4 link_up
0x0010 DESC_BASE_LO
0x0014 DESC_BASE_HI
0x0018 DATA_BASE_LO
0x001c DATA_BASE_HI
0x0020 TRACE_BYTES_LO
0x0024 TRACE_BYTES_HI
0x0028 PKT_COUNT_LO
0x002c PKT_COUNT_HI
0x0030 LOOP_COUNT_LO    0 表示无限循环
0x0034 LOOP_COUNT_HI
0x0038 LOOP_GAP_LO
0x003c LOOP_GAP_HI
0x0040 START_TIME_LO    0 表示收到首包后按首包 gap 发送
0x0044 START_TIME_HI
0x0048 RATE_Q16_16      保留字段；当前版本建议主机侧预缩放 gap_ticks
0x004c WATERMARK
0x0050 FIFO_LEVEL
0x0060 TX_PKTS_LO
0x0064 TX_PKTS_HI
0x0068 TX_BYTES_LO
0x006c TX_BYTES_HI
0x0070 LATE_PKTS_LO
0x0074 LATE_PKTS_HI
0x0078 UNDERRUN_PKTS_LO
0x007c UNDERRUN_PKTS_HI
```

## 常用命令

仿真：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action sim
```

综合检查：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action synth
```

远程烧录：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action program -Bitfile .\build\vivado\traffic_replay.runs\impl_1\traffic_replay_top_stub.bit
```

pcap 转 trace：

```powershell
python .\software\pcap2trace.py .\input.pcap --out-dir .\trace_out
```

输出文件：

- `trace_out/desc.bin`
- `trace_out/data.bin`
- `trace_out/manifest.json`

## 版本管理

仓库采用源码化 Vivado 流程，`build/`、`.Xil/`、`.runs/`、`.cache/` 等生成物不纳入版本管理。推荐提交粒度：

1. RTL 行为变更。
2. Vivado/IP wrapper 变更。
3. 主机软件和寄存器协议变更。
4. 文档和测试向量变更。

## 后续接入任务

- 接 CMAC US+ IP：QSFP0 RX/TX 引脚、GT refclk、CMAC TX AXIS。
- 接 QDMA/XDMA：AXI-Lite 控制面、H2C stream、DDR 写入路径。
- 接 DDR4/MIG 或平台 shell 暴露的 AXI memory interface。
- 给 DDR reader 增加 descriptor prefetch FIFO 和 payload FIFO，以支撑最小包 100G 场景。
- 增加主机端 DMA loader，负责把 `desc.bin`/`data.bin` 写入 U200 DDR 并配置寄存器启动。
- 若确实需要运行时速率缩放，给 scheduler 增加流水化乘法；不要在 322MHz 路径上放组合 64x32 乘法。

当前 `constraints/traffic_replay_stub.xdc` 只约束 stub 顶层的 `clk` 为 322.265625MHz。接入 CMAC/QDMA/DDR block design 后，需要替换为真实时钟、GT、QSFP、PCIe 和 DDR 约束。
