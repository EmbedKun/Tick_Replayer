# Traffic Replay on Xilinx Alveo U200

这个仓库是 U200 单端口 100Gbps 流量回放仪的源码化工程。当前目标是先跑通：

- Host 通过 PCIe XDMA 把 `desc.bin` / `data.bin` 写入 U200 DDR4 C0。
- FPGA 从 DDR4 读 trace，按包间隔调度，经 512-bit AXI4-Stream 发给 QSFP0 CMAC。
- 主机通过 XDMA AXI-Lite 控制面选择 `PRELOAD` / `LOOP`，并保留 `STREAM` RTL 路径。

## 本机环境

- Windows 工程目录：`C:\Users\mkxue\Desktop\traffic_replay`
- Vivado：`D:\Xilinx\Vivado\2020.2\bin\vivado.bat`
- 目标器件：`xcu200-fsgd2104-2-e`
- Board part：`xilinx.com:au200:part0:1.3`
- 硬件 Vivado 生成目录：默认 `D:\tr_build\vivado_hw`
- Vivado 临时目录：默认 `D:\tr_tmp`
- 远程烧录 hw_server：`172.22.5.106:3121`

不要把 SSH 密码、私钥、license 文件写入仓库。

## 目录结构

```text
rtl/        回放核心 RTL 和 BD module wrapper
sim/        XSim testbench
scripts/    Vivado 工程、仿真、综合、硬件 BD、远程烧录脚本
software/   pcap 转 trace 工具，以及 Linux XDMA trace loader
docs/       架构和维护笔记
constraints/ stub 约束，以及 U200 硬件 bitstream 约束
```

## 硬件 Block Design

脚本 `scripts/create_hw_project.tcl` 会创建 `D:\tr_build\vivado_hw\traffic_replay_hw.xpr`，其中包含：

```text
PCIe x16 Gen3 XDMA
  M_AXI      -> AXI clock converter -> DDR SmartConnect -> DDR4 C0
  M_AXI_LITE -> AXI-Lite clock converter -> control SmartConnect
                                      -> replay regs
                                      -> AXI-Lite register slice -> DDR4 control regs

DDR4 C0 -> replay_core M_AXI read path
replay_core M_TX_AXIS -> RTL AXIS async FIFO -> CMAC QSFP0 TX

QSFP0 CMAC:
  AXIS 512-bit
  CAUI-4 4x25G
  GT refclk 161.1328125 MHz
  CMAC hard block from the known-good U200 CMAC setup
```

PCIe refclk 使用 `util_ds_buf` 的 `IBUFDSGTE`，顶层暴露 `pcie_refclk_clk_p/n`，不是未约束的单端内部时钟。

硬件 bitstream 使用 `constraints/traffic_replay_u200.xdc`。该文件显式记录 U200 的 PCIe x16、QSFP0 4x25G、PCIe refclk、DDR4 C0 refclk、QSFP0 sideband 和 bitstream 配置；DDR4 C0 的完整地址/数据脚由 DDR4 IP 通过 U200 board interface 生成约束。stub 综合只加载 `constraints/traffic_replay_stub.xdc`。

QSFP0 sideband 当前由 BD 绑为常量：`qsfp0_resetl=1`、`qsfp0_lpmode=0`、`qsfp0_refclk_reset=0`、`qsfp0_fs=2'b10`，用于启用模块并选择 161.1328125 MHz 参考时钟。

XDMA endpoint 固定为 `10ee:903f`，class code 为 `058000`，避免 Linux 把它识别为串口类设备。AXI-Lite BAR 映射到 replay control/status 寄存器和 DDR4 control regs；AXI Memory BAR 通过 XDMA H2C/C2H 访问 DDR4 C0。

默认硬件 BD 会插入 `cmac_tx_ila`，采样时钟为 `cmac_0/gt_txusrclk2`，探针包含 CMAC TX AXIS 的 `tvalid/tlast/tuser/tkeep/tdata[31:0]` 和 `stat_rx_aligned`。如果只想生成不带 ILA 的版本，运行 Vivado 前设置 `TRAFFIC_REPLAY_ENABLE_ILA=0`。

CMAC AXIS TX 当前配置没有对外提供 `tready`，因此 BD 显式把 `tx_axis_fifo/m_axis_tready` 绑为 1。调试 ILA 里看到 `tvalid` 拉高、`tlast` 成帧，即表示 replay core 已经把包送到 CMAC TX 侧。

硬件工程默认生成在 D 盘短路径，避免 U200 XDMA/DDR/CMAC OOC 综合占满 C 盘，也降低 Vivado 2020.2 在 Windows 上对子 IP 临时路径长度敏感的问题。需要改工程位置时，运行前设置环境变量 `TRAFFIC_REPLAY_HW_BUILD_ROOT`；需要改临时目录时，设置 `TRAFFIC_REPLAY_VIVADO_TEMP`；需要改 Vivado 并行度时，设置 `TRAFFIC_REPLAY_VIVADO_JOBS`，默认是 `1`，用于避开本机通过 task worker 跑 XDMA/OOC 时偶发卡住的问题。

Vivado 2020.2 安装目录里的 `xpm_fifo.sv` 在本机不是标准 Xilinx XPM FIFO 定义，因此硬件 BD 不依赖 Xilinx `axis_clock_converter` IP 的 XPM FIFO；`rtl/axis_async_fifo.v` 用纯 RTL 实现 DDR UI clock 到 CMAC TX clock 的 AXIS 异步 FIFO。

当前 FIFO 读侧的预读判断只依赖已寄存的队列占用，不把 CMAC `tready` 同拍反馈到 BRAM enable/读指针；DDR4 AXI-Lite control 口前也插入了 `axi_register_slice`。这两处用于收敛 322MHz CMAC TX clock 和 DDR UI clock 域的关键时序路径。

当前硬件 BD 把 replay core 放在 DDR UI clock 域，并用 RTL AXIS async FIFO 跨到 CMAC TX user clock。这样便于先完成 Host -> DDR -> CMAC 的 bring-up；后续追求极限精度时，可以把 scheduler/TX 前移到 CMAC 时钟域，并给 DDR read path 加更深 FIFO。

## 地址映射

XDMA `M_AXI`：

```text
0x0000_0000_0000_0000 - 0x0000_0003_FFFF_FFFF  DDR4 C0, 16GB
```

XDMA `M_AXI_LITE`：

```text
0x0000_0000 - 0x0000_FFFF  replay control/status regs
0x0001_0000 - 0x0001_FFFF  DDR4 control regs
```

## 回放模式

- `PRELOAD`：Host 先把 descriptor/data 写入 DDR，再写寄存器启动。当前硬件主路径。
- `LOOP`：与 `PRELOAD` 使用同一 DDR 读路径，到尾部后回到起点。`LOOP_COUNT == 0` 表示无限循环。
- `STREAM`：RTL 已有 host stream parser，但当前 BD 没有把 XDMA H2C stream 接到该输入。后续可在 XDMA/QDMA streaming 口稳定后接入。

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

硬件 BD 中调度 tick 使用 DDR UI clock，建议生成 trace 时先用 `--tick-hz 300000000`。如果以后把 scheduler 放到 CMAC TX user clock，再改回 CMAC TX clock 对应频率。

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
0x0054 DEBUG_CTRL   bit0 force_link_up
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

stub 综合检查：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action synth
```

生成并校验 U200 硬件 BD：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action hwbd
```

完整生成硬件 bitstream（推荐先生成 BD，再打开已有工程构建）：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action hwbd
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action hwbit_existing
```

pcap 转 trace：

```powershell
python .\software\pcap2trace.py .\input.pcap --out-dir .\trace_out --tick-hz 300000000
```

在插有 U200 的 Linux 机器上，通过 XDMA driver 写 DDR 并启动：

```bash
python3 software/xdma_load_trace.py \
  --manifest trace_out/manifest.json \
  --desc-base 0x00000000 \
  --data-base 0x10000000 \
  --mode preload \
  --force-link-up
```

无光纤调试时使用 `--force-link-up` 或：

```bash
python3 software/traffic_replay_cli.py debug-force-link on
python3 software/traffic_replay_cli.py status
```

抓取 CMAC TX ILA：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action program -Bitfile D:\tr_build_debug\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper.bit
& D:\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch -source .\scripts\capture_cmac_ila.tcl -tclargs D:\tr_build_debug\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper.ltx .\reports\cmac_tx_ila_capture.csv
```

远程烧录已有 bitstream：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action program -Bitfile .\path\to\design.bit
```

烧录 PCIe endpoint bitstream 后建议重启远程主机，让 PCIe PERST 重新训练并重新分配 BAR。正常枚举应类似：

```bash
lspci -nn -d 10ee:
# 01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]
```

远程 Linux 使用 Xilinx XDMA driver，可从官方 `dma_ip_drivers` 的 `2020.2` 分支构建：

```bash
git clone https://github.com/Xilinx/dma_ip_drivers.git
cd dma_ip_drivers
git checkout 2020.2
make -C XDMA/linux-kernel/xdma
sudo insmod XDMA/linux-kernel/xdma/xdma.ko
ls -l /dev/xdma*
```

## 已验证

- `hwbd`：Vivado 2020.2 成功创建并 validate BD，生成 `traffic_replay_bd_wrapper.v`。
- `sim`：XSim testbench 通过，输出 2 个包。
- `synth`：stub 顶层综合通过，0 errors / 0 warnings。
- `hwbit_existing`：使用 `constraints/traffic_replay_u200.xdc` 生成完整 U200 bitstream。2026-06-25 本机通过，调试产物为 `D:\tr_build_debug\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper.bit`，ILA probes 为同目录 `traffic_replay_bd_wrapper.ltx`。
- 远程 bring-up：JTAG 烧录后重启远程主机，PCIe 枚举为 `Memory controller [0580]: Xilinx Corporation Device [10ee:903f]`。
- XDMA driver：远程 `dma_ip_drivers` 的 `2020.2` 分支驱动 `v2020.2.2` 成功 probe，识别 `config bar 1, user 0`，生成 `/dev/xdma0_h2c_0`、`/dev/xdma0_c2h_0`、`/dev/xdma0_user`。
- DDR/XDMA：远程通过 H2C/C2H 在 `0x00000000`、`0x00100000`、`0x10000000` 完成 4KB、64KB、1MB 往返读写测试，全部 PASS。
- 控制面：`traffic_replay_cli.py status/debug-force-link` 能读写 AXI-Lite；`DEBUG_CTRL[0]` 打开时 `tx_gate_open=yes`，关闭后恢复。
- 回放 smoke：无光纤、`force-link-up` 下，3 包 trace 回放完成，`tx_packets=3`、`tx_bytes=252`；使用足够 gap 时 `late_packets=0`、`underrun_packets=0`。
- CMAC TX ILA：远程 loop trace 运行时，`scripts/capture_cmac_ila.tcl` 以 `tx_axis_fifo_m_axis_tvalid==1` 触发并导出 `reports/cmac_tx_ila_capture.csv`；CSV 中能看到 `tvalid` 有效采样、`tkeep=ffffffffffffffff`、`tdata_low=aaaaaaaa`。
- 最终实现时序：`reports/hw_impl_timing_summary.rpt` 显示 `WNS=0.017ns`、`TNS=0.000ns`、失败端点 0，`All user specified timing constraints are met.`
- bitgen 仍有 `Evaluation License Warning` critical warning；正式长期使用前需要确认 CMAC 等 IP license 不是限时 evaluation。

## 版本管理

仓库保存源码、脚本、文档和软件工具。`build/`、`.Xil/`、Vivado 生成物、trace 输出不纳入版本管理。

建议后续提交粒度：

1. RTL 行为变更。
2. Vivado/IP/BD 脚本变更。
3. 主机软件和寄存器协议变更。
4. 文档和测试向量变更。
