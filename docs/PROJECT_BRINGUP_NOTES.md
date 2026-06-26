# 项目 bring-up 笔记

这份文档是写给后续维护者，也就是我自己看的。它不追求像 README 那样对外简洁，而是尽量把当前工程从 0 到跑通的过程、模块边界、IP 配置、XDC 写法、调试现象和后续风险都记录下来。

## 1. 项目目标和当前边界

目标是做一个 FPGA 流量回放仪，板卡是 Xilinx Alveo U200，第一阶段先实现单端口 100Gbps 回放。系统最终希望由两部分组成：

- Host 侧 pcap 处理：对原始 trace 做链路状态转化、一致性修改、带宽/RTT/丢包率修改等。
- FPGA 侧高精度回放：Host 把处理后的 trace 送入 FPGA DDR，FPGA 按包间隔调度并送到 100G CMAC。

当前仓库已经完成的是第二部分的硬件原型：Host 通过 XDMA 把 `desc.bin` 和 `data.bin` 放入 U200 DDR4 C0，FPGA 从 DDR4 读 descriptor 和 payload，再把数据推到 CMAC TX 输入侧。

当前不是最终高吞吐架构。现在的 DDR reader 比较简单，一次读 descriptor，再读对应 payload。它适合 bring-up 和功能验证，后续要冲 100Gbps 小包线速，需要加 descriptor cache、payload prefetch、outstanding read 和更深 FIFO。

## 2. 当前仓库里每个目录是什么

```text
rtl/
  FPGA replay core 源码

sim/
  XSim testbench，目前验证 host stream path 和 DDR preload path

constraints/
  U200 top-level XDC 和 stub 综合 XDC

scripts/
  Vivado 工程生成、综合、实现、烧录、ILA 抓取、源码导出脚本

software/
  Host 侧 Python 工具：pcap 转 trace、XDMA trace loader、控制 CLI

docs/
  架构说明、本文档、架构图
```

Vivado 生成物不应该进入 Git，包括 `.xpr`、`.bd`、`.runs`、`.gen`、`.Xil`、bitstream、LTX、日志和 WebTalk 文件。这个项目的 Vivado 工程应通过 `scripts/create_hw_project.tcl` 重建。

## 3. 已经调通的完整链路

当前调通的是：

```text
Host Python
  -> /dev/xdma0_h2c_0
  -> PCIe XDMA M_AXI
  -> DDR4 C0
  -> replay_core M_AXI read
  -> ddr_trace_reader
  -> replay_scheduler
  -> replay_tx_engine
  -> axis_async_fifo
  -> CMAC TX AXIS input side
```

控制链路是：

```text
Host Python
  -> /dev/xdma0_user
  -> XDMA M_AXI_LITE
  -> axi_lite_regs
  -> mode/base/count/start/debug/status
```

这说明目前至少以下内容已经成立：

- PCIe endpoint 能枚举。
- XDMA driver 能 probe 到 config BAR 和 user BAR。
- H2C/C2H 能读写 DDR。
- AXI-Lite 寄存器能读写。
- replay core 能真正从 DDR 发 AXI read 读 descriptor/payload。
- scheduler 能释放包。
- TX engine 能计数并把包 drain 到输出侧。

无光纤时，用 `DEBUG_CTRL[0] force_link_up` 打开 TX gate，用 `DEBUG_CTRL[1] force_tx_ready` 让 TX engine 内部认为下游 ready，这样可以不依赖 CMAC 真实 link-up 来验证内部路径。

接上 QSFP0/QSFP1 之间的 100G 光纤后，TX0 -> RX1 和 TX1 -> RX0 都已经验证通过：CMAC link-up、TX 计数、RX 计数、RX ring 写入和 Host C2H 读回都能闭环。

## 4. Block Design 里的 IP

Block Design 由 `scripts/create_hw_project.tcl` 生成。关键 IP 如下。

### XDMA

位置：`scripts/create_hw_project.tcl`

主要配置：

```text
IP: xilinx.com:ip:xdma
PCIe: Gen3 x16
Vendor ID: 10EE
Device ID: 903F
Class code: 058000
Subsystem ID: 0007
AXI data width: 512 bit
AXI address width: 64 bit
AXI ID width: 4
AXI clock target: 250 MHz
H2C channels: 1
C2H channels: 1
AXI-Lite master: enabled
AXI-Lite master aperture: 1 MB
```

XDMA 的作用分两条：

- `M_AXI` 走 memory-mapped DMA，用于 Host 写 DDR 和从 DDR 读回。
- `M_AXI_LITE` 访问 replay core 寄存器和 DDR4 control regs。

Linux 侧使用 Xilinx XDMA reference driver，成功 probe 后应出现：

```text
/dev/xdma0_h2c_0
/dev/xdma0_c2h_0
/dev/xdma0_user
/dev/xdma0_control
```

### DDR4

主要配置：

```text
IP: xilinx.com:ip:ddr4
Board interface: ddr4_sdram_c0
Input clock board interface: default_300mhz_clk0
AXI data width: 512
AXI address width: 34
AXI ID width: 4
ECC: true
Memory part: MTA18ASF2G72PZ-2G3
Memory type: RDIMMs
Address map: ROW_COLUMN_BANK_INTLV
```

DDR4 C0 是当前 trace 存储空间。Host 的 H2C 通过 XDMA 写入，replay core 的 `ddr_trace_reader` 再通过自己的 M_AXI 端口读取。

### SmartConnect 和 Clock Converter

用了三个 SmartConnect：

```text
host_smc  : XDMA M_AXI 到 DDR path 的前级
ddr_smc   : Host 写 DDR 和 replay core 读 DDR 共享 DDR4 C0
ctrl_smc  : XDMA AXI-Lite 到 replay regs / DDR control regs
```

用了两个 AXI clock converter：

```text
xdma_to_ddr_cc : XDMA axi_aclk -> DDR UI clock
axil_ctrl_cc   : XDMA axi_aclk -> DDR UI clock
```

这样 Host 侧 PCIe 时钟域和 DDR UI clock 域隔离开。

### CMAC

主要配置：

```text
IP: xilinx.com:ip:cmac_usplus
Board interface: qsfp0_4x
GT refclk board interface: qsfp0_161mhz
GT type: GTY
Mode: CAUI-4, 4x25G
CMAC core: CMACE4_X0Y6
GT group: X1Y48~X1Y51
GT refclk: 161.1328125 MHz
User interface: AXIS
RS-FEC: disabled
TX flow control: disabled
RX flow control: disabled
TX CRC: insertion enabled
RX CRC: stripping enabled
TX IPG: 12
```

CMAC TX input 来自 `axis_async_fifo`。当前 BD 里 CMAC TX 侧 `tready` 没有作为外部信号反馈给 replay core，所以早期无光纤验证主要看 TX engine 计数和可选 ILA。接 QSFP0/QSFP1 互联光纤后，两个 CMAC 的 link 状态和双向 RX packet counter 已经验证通过；后续还需要接真实被测设备或外部网卡做端到端验证。

### ILA

ILA 是可选的，由环境变量 `TRAFFIC_REPLAY_ENABLE_ILA` 控制。

```text
TRAFFIC_REPLAY_ENABLE_ILA=1  创建 CMAC TX ILA
TRAFFIC_REPLAY_ENABLE_ILA=0  不创建 ILA，减小实现内存压力
```

ILA 探针包括：

```text
tx_axis_fifo/m_axis_tvalid
tready const
tx_axis_fifo/m_axis_tlast
tx_axis_fifo/m_axis_tuser
tx_axis_fifo/m_axis_tkeep
tx_axis_fifo/m_axis_tdata[31:0]
cmac_0/stat_rx_aligned
```

当前最后一次成功硬件验证为了避免 Vivado 实现阶段资源/内存问题，使用的是 `TRAFFIC_REPLAY_ENABLE_ILA=0`。调试主要依赖 AXI-Lite debug regs。

## 5. XDC 是怎么写的

XDC 文件是 `constraints/traffic_replay_u200.xdc`。写法上分几类。

### Bitstream 和配置模式

```tcl
set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property CONFIG_MODE B_SCAN [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
set_property BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE [current_design]
set_property BITSTREAM.CONFIG.EXTMASTERCCLK_EN DISABLE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 63.8 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
set_property BITSTREAM.CONFIG.OVERTEMPSHUTDOWN Enable [current_design]
```

最关键的是 `CONFIG_MODE B_SCAN`。这次远程 JTAG 烧录一开始失败过，Vivado 报 `End of startup status: LOW`。后来确认当前是 JTAG/BSCAN 烧录，不应该保留 SPI flash 专用 bitstream 配置。把 `CONFIG_MODE` 设成 `B_SCAN`，并去掉 `SPI_32BIT_ADDR/SPI_BUSWIDTH/SPI_FALL_EDGE` 后，bitstream 能正常烧录，Vivado 报 `End of startup status: HIGH`。

如果将来要做 flash 固化，应该单独准备 flash bitstream 配置，不要和 JTAG bring-up 配置混在同一套脚本里。

### DDR4 参考时钟

DDR4 C0 使用 U200 的 300MHz board clock：

```tcl
default_300mhz_clk0_clk_p -> AY37
default_300mhz_clk0_clk_n -> AY38
IOSTANDARD LVDS
```

DDR4 地址/数据 pin placement 由 DDR4 IP 通过 U200 board interface 生成，不在手写 XDC 里逐个列出。

### PCIe

XDC 显式约束了 PCIe x16 的 16 组 RX/TX MGT lane LOC、100MHz refclk 和 PERST：

```text
pcie_refclk_clk_p/n -> AM11/AM10
pcie_perstn         -> BD21, LVCMOS12, PULLUP
```

PCIe refclk 在 BD 中通过 `util_ds_buf`，类型设成 `IBUFDSGTE`，再分别接 XDMA 的 `sys_clk` 和 `sys_clk_gt`。这部分写法参考了 U200 上常见的 PCIe/Corundum 风格连接方式。

### QSFP0 / CMAC

QSFP0 用 4x25G lane：

```text
qsfp0_4x_grx/gtx[0..3]
qsfp0_161mhz_clk_p/n -> K11/K10
```

sideband 也约束了：

```text
qsfp0_modsell
qsfp0_resetl
qsfp0_lpmode
qsfp0_refclk_reset
qsfp0_fs[1:0]
```

BD 里把 sideband 绑成常量：

```text
modsell=0
resetl=1
lpmode=0
refclk_reset=0
fs=2'b10
```

这些 sideband 加了 false path，因为它们是静态控制脚，不参与高速时序。

### 时钟域约束

DDR/UI 逻辑和 CMAC TX AXIS 逻辑之间只通过 `axis_async_fifo` 交互，所以 XDC 中把相关时钟设成异步 clock group：

```tcl
set_clock_groups -asynchronous \
  -group [get_clocks -regexp -quiet {^mmcm_clkout0$}] \
  -group [get_clocks -regexp -quiet {^txoutclk_out\[0\]$}]
```

这条约束的目的是避免 Vivado 在两个异步时钟域之间分析不存在的同步时序路径。

## 6. RTL 模块细节

### `trace_replay_core.sv`

这是顶层核心，负责：

- 例化 `axi_lite_regs`。
- 例化 `ddr_trace_reader`。
- 例化 `host_stream_parser`。
- 根据 `MODE` 选择 DDR path 或 stream path。
- 例化 `replay_scheduler`。
- 例化 `replay_tx_engine`。
- 汇总状态计数和 debug regs。

这次修复里加了两点关键逻辑：

```systemverilog
assign tx_ready_effective = m_tx_axis_tready || cfg_force_tx_ready;
assign ddr_reader_start = sel_ddr_mode &&
  (start_pulse || (replay_running && !ddr_busy && !ddr_done && (cfg_pkt_count != 64'd0)));
```

第一条让无光纤情况下也能 drain TX engine。第二条避免 start pulse 如果被错过，DDR reader 不启动的问题。

### `axi_lite_regs.sv`

这是 Host 控制面。寄存器包括：

- `CONTROL`
- `MODE`
- `STATUS`
- descriptor/data base
- packet count
- loop count/gap
- start time
- debug control
- TX/late/underrun counters
- debug status/AXI/tick

`DEBUG_CTRL` 现在是：

```text
bit0 force_link_up
bit1 force_tx_ready
```

debug regs 对调试非常有帮助。比如如果 `STATUS.running=yes` 但 `tx_packets=0`，就看：

- `DEBUG_STATUS[3:0]`：DDR reader 卡在哪个状态。
- `DEBUG_AXI`：AXI read 是否发出、DDR 是否返回。
- `DEBUG_AR`：最后读地址是不是 descriptor/data 地址。
- `DEBUG_TICK`：scheduler tick 是否在跑。

### `ddr_trace_reader.sv`

状态机：

```text
IDLE
DESC_AR
DESC_R
META
PAYLOAD_AR
PAYLOAD_R
NEXT
DONE
```

每个包先读一个 64B descriptor，再用 `data_base + data_word_offset * 64` 去读 payload。payload 输出是 512-bit AXI4-Stream。

当前 reader 简单可靠，但吞吐不是最终形态。后续优化方向：

- descriptor cache，一次 AXI read 缓存多个 descriptor。
- payload prefetch FIFO。
- 支持多个 outstanding read。
- metadata 和 payload 解耦。

### `replay_scheduler.sv`

调度器维护一个 `now_ticks` 和 `target_ticks`。这次修复后，`start` 和 `clear` 都会重置回放相对时间基准：

```systemverilog
if (clear || start) begin
  now_ticks <= 0;
  pending <= 0;
  first_pkt <= 1;
end
```

`START_TIME=0` 时，首包释放时间是第一个 descriptor 的 `gap_ticks`；`START_TIME!=0` 时，首包释放时间是 Host 写入的相对 tick。

这解决了一个重要问题：FPGA 上电后如果一直运行，旧的全局计数器会很大。新 trace 进来后如果仍以全局绝对 tick 比较，就可能出现首包不按预期释放。现在使用相对时间基准，start/clear 后重新计时。

### `replay_tx_engine.sv`

TX engine 接收：

- scheduler 发来的 packet command：长度、flags。
- DDR reader 或 stream parser 发来的 payload AXIS。

它负责输出 CMAC TX AXIS：

```text
tdata[511:0]
tkeep[63:0]
tvalid
tready
tlast
tuser
```

当前 `tkeep` 根据 packet length 生成，`tx_packets/tx_bytes` 在成功完成一包时累计。

### `axis_async_fifo.v`

负责 DDR UI clock 到 CMAC TX user clock 的 CDC，也被 RX capture 用来从 CMAC RX clock 跨回 DDR UI clock。这次真实光纤联调时发现过一个关键 bug：`xpm_memory_sdpram` 的 `.READ_LATENCY_B(2)` 已经表示 RAM 输出延迟 2 拍，原代码又额外把 valid pipe 做成 `RAM_READ_LATENCY + 1`，导致 `tdata/tkeep/tlast` 与 valid 对齐晚了一拍。

现象是：

- 60B/64B 单 beat 包基本正常。
- 124B、128B、256B 这类多 beat 包会在 RX 侧被拆成多个包，`rx_packets` 比实际多，ring 里的数据也会出现错位或重复。

修复后：

```systemverilog
localparam READ_PIPE_LEN = RAM_READ_LATENCY;
```

同时 `outstanding_count` 只统计两个 valid pipe bit。修完后跑了双向长度扫描：`60/64/124/128/256B` 均为 TX 1 包、RX 1 包、字节数一致、`rx_errors=0`。

### `host_stream_parser.sv`

为未来 `STREAM` 模式保留。它把 host streaming 输入解析成：

- metadata：gap、length、flags。
- payload AXIS。

当前 BD 没有把 XDMA streaming H2C 接到这里，所以系统级 `STREAM` 未完成。

## 7. Host 软件

### `pcap2trace.py`

把 classic pcap 转成：

```text
desc.bin
data.bin
manifest.json
```

它会根据 pcap timestamp 计算相邻包间隔，再按 `--tick-hz` 转成 `gap_ticks`。

当前默认最小帧长补到 60B，不保留 FCS。CMAC TX 配置为插入 FCS。

### `xdma_load_trace.py`

负责：

- 读 `manifest.json`。
- 用 `/dev/xdma0_h2c_0` 把 `desc.bin` 写入 `DESC_BASE`。
- 把 `data.bin` 写入 `DATA_BASE`。
- 通过 `/dev/xdma0_user` 写寄存器。
- 可选写 `force_link_up/force_tx_ready`。
- 最后写 `CONTROL.start`。

常用命令：

```bash
sudo python3 /home/user/traffic_replay_software/xdma_load_trace.py \
  --manifest /home/user/trace_out/manifest.json \
  --desc-base 0x00000000 \
  --data-base 0x10000000 \
  --mode preload \
  --force-link-up \
  --force-tx-ready
```

### `traffic_replay_cli.py`

常用命令：

```bash
sudo python3 traffic_replay_cli.py stop
sudo python3 traffic_replay_cli.py clear
sudo python3 traffic_replay_cli.py status
sudo python3 traffic_replay_cli.py regs
sudo python3 traffic_replay_cli.py debug-force-link on
sudo python3 traffic_replay_cli.py debug-tx-ready on
```

`status` 会把关键状态翻译成人能读的形式。`regs` 用于完整 dump。

双端口 RX bring-up 时修过一次 CLI 位解析：`rx_capture_core` 的 `STATUS` 中 bit5 才是 `link_up`，bit4 是 `fifo_valid`，bit6 是 `overflow_seen`，`writer_state` 在 bit[8:7]。如果这些位解错，会出现原始寄存器已经显示链路 up，但 `rx-status` 仍打印 `link_up=no` 的假象。

## 8. 仿真做了什么

仿真入口：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action sim
```

testbench：`sim/tb_trace_replay_core.sv`

当前验证两条路径：

1. Host stream replay：模拟 host stream parser 输入，检查输出 2 个包。
2. DDR preload replay：testbench 内建 AXI read memory model，预置 3 个 descriptor 和 payload，检查输出 3 个包。

通过信息：

```text
PASS: host stream replay emitted 2 packets
PASS: DDR preload replay emitted 3 packets
```

仿真覆盖的是 RTL 功能，不覆盖真实 XDMA IP、DDR4 IP、CMAC IP 的物理行为。

## 9. 硬件调试过程和结论

### 第一次现象

Host 能成功：

- 写 descriptor/data 到 DDR。
- 从 DDR C2H 读回验证内容正确。
- 写 AXI-Lite 寄存器。

但启动后：

```text
running=yes
done=no
tx_packets=0
fifo_level=0
```

这说明 Host -> DDR 和 Host -> AXI-Lite 是通的，问题在 replay core 内部：DDR reader 没真正读 descriptor，或者读了但 scheduler/TX 没推进。

### 修复点

做了三类修改：

1. DDR reader start 兜底：如果 start pulse 错过，只要系统处于 running、DDR reader idle、pkt_count 非零，就重新拉起 reader。
2. 调度器时间基准：`start/clear` 重置 `now_ticks` 和首包状态，避免全局计数器旧值影响新 trace。
3. 调试通路：加 `force_tx_ready` 和 debug regs，使无光纤时也能确认 TX path 是否真的走完。
4. RX capture ring 写入改成完整 64B beat 写入，避免 sparse `WSTRB` 在调试 ring C2H 读回时引入不稳定因素。
5. 修复 `axis_async_fifo` read valid pipeline off-by-one，解决多 beat 包被拆包和 TLAST 对齐错误。

### 重新生成 bitstream

第一次 full build 在 `D:\tr_build_debug` 里遇到 Vivado 内部错误：

```text
Device 21-987 Linking the ceam library to the veamMap failed
TclStackFree: incorrect freePtr
```

后来使用新目录 `D:\tr_build_fix`，并设置：

```powershell
$env:TRAFFIC_REPLAY_ENABLE_ILA="0"
```

降低实现内存压力后，bitstream 生成成功。

### JTAG 烧录问题

普通 bitstream 第一次烧录失败：

```text
End of startup status: LOW
DONE status = 0
```

检查 Vivado design property 后发现当前合法配置模式不是 `JTAG`，而是：

```text
CONFIG_MODE B_SCAN
```

同时不能保留 SPI flash 专用配置：

```text
BITSTREAM.CONFIG.SPI_32BIT_ADDR
BITSTREAM.CONFIG.SPI_BUSWIDTH
BITSTREAM.CONFIG.SPI_FALL_EDGE
```

去掉 SPI 项并使用 `B_SCAN` 后，JTAG 烧录成功：

```text
End of startup status: HIGH
```

### PCIe rescan 问题

JTAG 重新配置 PCIe endpoint 后，Linux 侧旧 XDMA driver 上下文还在。直接 H2C 会失败：

```text
OSError: [Errno 512]
engine id missing
ioread32(...) = 0xffffffff
Failed to detect XDMA config BAR
```

解决方式是让 Linux 重新枚举 PCIe endpoint：

```bash
sudo rmmod xdma 2>/dev/null || true
echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/remove
echo 1 | sudo tee /sys/bus/pci/rescan
sudo insmod /home/user/dma_ip_drivers/XDMA/linux-kernel/xdma/xdma.ko
```

或者直接重启远端主机。

### H2C/C2H 验证

通过三组 DDR 地址写读回：

```text
0x00020000, 4KB, PASS
0x00200000, 64KB, PASS
0x11000000, 256KB, PASS
```

这个验证覆盖：

- `/dev/xdma0_h2c_0`
- `/dev/xdma0_c2h_0`
- PCIe XDMA M_AXI
- DDR4 C0

它不覆盖 replay core 内部 reader。

### DDR preload 回放验证

构造 3 个包：

```text
pkt0: gap=30000, word_off=0, frame_len=64,  payload=0xaa...
pkt1: gap=30000, word_off=1, frame_len=64,  payload=0x55...
pkt2: gap=30000, word_off=2, frame_len=124, payload=0x00..0x7b
```

启动命令带：

```text
--force-link-up
--force-tx-ready
```

最终状态：

```text
running           : no
done              : yes
late              : no
underrun          : no
cmac_link_up      : no
tx_gate_open      : yes
force_link_up     : yes
force_tx_ready    : yes
tx_packets        : 3
tx_bytes          : 252
late_packets      : 0
underrun_packets  : 0
debug_ticks       : 90006
```

这证明 DDR reader/scheduler/TX engine 已经跑通。`debug_ticks=90006` 对应 3 个 30000 tick gap 加少量状态机开销，符合预期。

## 10. 当前工程怎么打开和复现

Windows 本地：

```powershell
cd C:\Users\mkxue\Desktop\traffic_replay
$env:TRAFFIC_REPLAY_HW_BUILD_ROOT="D:\tr_build"
$env:TRAFFIC_REPLAY_ENABLE_ILA="0"
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action hwbd
& D:\Xilinx\Vivado\2020.2\bin\vivado.bat D:\tr_build\vivado_hw\traffic_replay_hw.xpr
```

仿真：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action sim
```

综合检查：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action synth
```

完整 bitstream：

```powershell
$env:TRAFFIC_REPLAY_HW_BUILD_ROOT="D:\tr_build"
$env:TRAFFIC_REPLAY_ENABLE_ILA="0"
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action hwbit_existing
```

远程烧录：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_vivado.ps1 -Action program -Bitfile D:\tr_build\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper.bit
```

如果继续使用当前已经验证过的 build 目录：

```text
D:\tr_build_fix\vivado_hw\traffic_replay_hw.xpr
D:\tr_build_fix\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper_bscan.bit
```

## 11. 双端口原型增量记录

这次在单端口版本上扩成了双端口原型，目标是让一块 U200 同时扮演 pcap 里的两个逻辑方向。现在已经用 QSFP0/QSFP1 之间的 100G 光纤把双向链路跑通：TX0 可以打到 RX1，TX1 可以打到 RX0。当前验证重点仍是功能闭环和调试能力，不代表已经做到 100Gbps 满速压力。

### 新增模块

新增文件：

```text
rtl/rx_capture_bd_core.sv  RX capture/stat SystemVerilog core
rtl/rx_capture_bd_core.v   Vivado BD 用 Verilog wrapper
```

`rx_capture_core` 做的事情：

- 接 CMAC RX AXIS：`rx_axis_tdata/tkeep/tvalid/tlast/tuser`。
- 因为 CMAC RX 没有 `tready`，内部只能在 FIFO 满时丢弃新 beat，并通过 overflow sticky bit 暴露风险。
- 用 `axis_async_fifo` 从 CMAC RX clock 跨到 DDR UI clock。
- 统计 RX packets/bytes/errors。
- 可选把每个包前 `TRUNC_BYTES` 对应的 64B beat 写入 DDR ring buffer。
- DDR ring 写入是单 beat AXI4 write，并且当前 `WSTRB` 全 1，便于 Host C2H 稳定回读调试数据；`rx_bytes` 才是 TKEEP 算出的有效以太网字节数，`captured_bytes` 是 ring 实际写入的 64B beat 字节数。
- 这个模块当前是统计和最近数据窗口，不是满速抓包器。

RX capture 寄存器地址相对每个 RX block base：

```text
0x0000 CONTROL        bit0 enable, bit1 clear, bit2 capture_enable
0x0004 STATUS         bit0 awvalid, bit1 wvalid, bit2 bvalid, bit3 fifo_ready,
                      bit4 fifo_valid, bit5 link_up, bit6 overflow_seen,
                      bit[8:7] writer_state
0x0010 RING_BASE_LO
0x0014 RING_BASE_HI
0x0018 RING_SIZE
0x001c TRUNC_BYTES
0x0020 WRITE_PTR
0x0030 RX_PKTS_LO
0x0034 RX_PKTS_HI
0x0038 RX_BYTES_LO
0x003c RX_BYTES_HI
0x0040 RX_ERRS_LO
0x0044 RX_ERRS_HI
0x0048 CAP_BYTES_LO
0x004c CAP_BYTES_HI
0x0050 AXI_WR_LO
0x0054 AXI_WR_HI
0x0058 AXI_ERR_LO
0x005c AXI_ERR_HI
0x0060 DEBUG
```

### BD 连接变化

现在 BD 里有两套 TX replay：

```text
replay_core_0/M_TX_AXIS -> tx_axis_fifo_0 -> cmac_0/axis_tx -> QSFP0
replay_core_1/M_TX_AXIS -> tx_axis_fifo_1 -> cmac_1/axis_tx -> QSFP1
```

两套 RX capture：

```text
cmac_0/rx_axis_* -> rx_cap_0 -> ddr_smc -> DDR4 C0
cmac_1/rx_axis_* -> rx_cap_1 -> ddr_smc -> DDR4 C0
```

DDR SmartConnect 现在有 5 个 slave input：

```text
S00: XDMA H2C/C2H memory mapped path
S01: replay_core_0 M_AXI read
S02: replay_core_1 M_AXI read
S03: rx_cap_0 M_AXI write
S04: rx_cap_1 M_AXI write
```

Control SmartConnect 现在有 5 个 master output：

```text
M00 -> replay_core_0/S_AXIL at 0x00000
M01 -> replay_core_1/S_AXIL at 0x10000
M02 -> rx_cap_0/S_AXIL      at 0x20000
M03 -> rx_cap_1/S_AXIL      at 0x30000
M04 -> DDR4 control regs    at 0x40000
```

Host 脚本变化：

- `traffic_replay_cli.py --port 0/1 ...` 控制 TX0/TX1 或 RX0/RX1。
- `xdma_load_trace.py --port 0/1 ...` 会把寄存器写到对应 replay core。
- 新增 `rx-status`、`rx-regs`、`rx-config`、`rx-enable`、`rx-disable`、`rx-capture`、`rx-clear`。

### QSFP1/CMAC1 约束

QSFP1 约束参考了本地 `build/corundum_ref/fpga/mqnic/Alveo/fpga_100g/fpga_au200.xdc`。关键映射：

```text
QSFP0: GTY X1Y48~X1Y51, CMACE4_X0Y6, refclk K11/K10
QSFP1: GTY X1Y44~X1Y47, CMACE4_X0Y5, refclk P11/P10
```

QSFP1 高速管脚：

```text
rx0 U4/U3, tx0 U9/U8
rx1 T2/T1, tx1 T7/T6
rx2 R4/R3, tx2 R9/R8
rx3 P2/P1, tx3 P7/P6
```

QSFP1 sideband：

```text
modsell AY20
resetl  BC18
lpmode  AV22
refclk_reset AR21
fs[0]   AR22
fs[1]   AU20
```

### 构建和烧录结果

双端口构建路径：

```text
D:\tr_build_dual\vivado_hw\traffic_replay_hw.xpr
D:\tr_build_dual\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper.bit
```

Vivado 结果：

- `validate_bd_design` 通过。
- `synth_design` 通过。
- `place_design` 通过，没有复现之前的 clock routing failed。
- `route_design` 通过。
- `write_bitstream` 通过，0 Errors。
- 最终 `reports/hw_impl_timing_summary.rpt` 显示 user constraints met；修复 FIFO 后最后一次 bitstream 的 WNS 是 `+0.007 ns`。
- CMAC 仍有 `cmac_an_lt` design_linking license 的 critical warning，这是 CMAC IP license 相关提示，不是实现错误。

远程 U200 烧录：

- bitstream 已通过 JTAG/hw_server 烧录到 `172.22.5.106:3121`。
- JTAG program 后执行 PCIe remove/rescan，XDMA driver 重新 probe 成功。
- `lspci -nn -d 10ee:` 显示 `01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]`。
- `/dev/xdma0_h2c_0`、`/dev/xdma0_c2h_0`、`/dev/xdma0_user` 等设备节点恢复。

### 双端口 debug 现象

DDR DMA 回读：

```text
0x00000000 4KB      PASS
0x00100000 64KB     PASS
0x10000000 1MB      PASS
0x30000000 4KB      PASS
0x32000000 4KB      PASS
```

TX0 装载 `/home/user/trace_out/manifest.json`：

```text
desc_base=0x00000000
data_base=0x10000000
force_link_up=yes
force_tx_ready=yes
done=yes
tx_packets=3
tx_bytes=252
late_packets=0
underrun_packets=0
```

TX1 装载同一 trace，但用不同 DDR 地址：

```text
desc_base=0x01000000
data_base=0x11000000
force_link_up=yes
force_tx_ready=yes
done=yes
tx_packets=3
tx_bytes=252
late_packets=0
underrun_packets=0
```

RX0/RX1 控制面和光纤互联前的空闲状态：

```text
RX0 ring_base=0x32000000, ring_size=0x00100000, truncate=128
RX1 ring_base=0x30000000, ring_size=0x00100000, truncate=128
rx_enable=yes
capture_enable=yes
fifo_ready=yes
```

接 QSFP0/QSFP1 100G 光纤后，先关闭 debug 强制项：

```bash
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 debug-force-link off
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 0 debug-tx-ready off
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 debug-force-link off
sudo python3 /home/user/traffic_replay_software/traffic_replay_cli.py --port 1 debug-tx-ready off
```

两个 TX status 都显示 `cmac_link_up=yes`，两个 RX status 都显示 `link_up=yes` 和 `fifo_ready=yes`。

单包长度扫描结果：

```text
dir        len  tx_pkts  tx_bytes  rx_pkts  rx_bytes  rx_errs  axi_writes  write_ptr
TX0->RX1    60        1        60        1        60        0           1         64
TX0->RX1    64        1        64        1        64        0           1         64
TX0->RX1   124        1       124        1       124        0           2        128
TX0->RX1   128        1       128        1       128        0           2        128
TX0->RX1   256        1       256        1       256        0           4        256
TX1->RX0    60        1        60        1        60        0           1         64
TX1->RX0    64        1        64        1        64        0           1         64
TX1->RX0   124        1       124        1       124        0           2        128
TX1->RX0   128        1       128        1       128        0           2        128
TX1->RX0   256        1       256        1       256        0           4        256
```

原 3 包 trace 双向结果：

```text
TX0 -> RX1:
  TX0 done=yes, tx_packets=3, tx_bytes=252, late_packets=0, underrun_packets=0
  RX1 link_up=yes, rx_packets=3, rx_bytes=252, rx_errors=0
  RX1 captured_bytes=256, axi_writes=4, write_ptr=256

TX1 -> RX0:
  TX1 done=yes, tx_packets=3, tx_bytes=252, late_packets=0, underrun_packets=0
  RX0 link_up=yes, rx_packets=3, rx_bytes=252, rx_errors=0
  RX0 captured_bytes=256, axi_writes=4, write_ptr=256
```

RX ring C2H 回读内容符合预期：第一包是 64B `0xaa`，第二包是 64B `0x55`，第三包是递增字节序列，占两个 64B beat。第三包有效长度是 124B，所以最后一个 beat 的末尾 4B 不是有效包数据。

## 12. 后续开发建议

优先级从高到低：

1. 接真实 DDoS 防御仪或外部网卡，验证端到端收包和双向业务场景。
2. 给 DDR reader 加 descriptor/payload prefetch，解决小包吞吐问题。
3. 把 scheduler/TX 移到 CMAC TX user clock 域，提高包间隔精度。
4. 接入 XDMA/QDMA streaming H2C，实现 Host streaming 模式。
5. 做高层 CLI，把 pcap2trace、load、start、status 封成一个用户命令。
6. 扩展 pcap 处理：IP/port/DNS/checksum 一致性修改，带宽/RTT/丢包率场景生成。
7. 增加真实 pcap 回放自动化测试、长时间稳定性测试和满速压力测试。

## 13. 容易踩坑的点

- JTAG 重新烧 PCIe endpoint 后，一定要 PCIe rescan 或重启。
- 不接光纤时不要指望 CMAC physical link-up。
- `force_link_up` 只打开 gate，不代表光口真 link-up。
- `force_tx_ready` 只用于内部 drain 验证，不代表真实 CMAC 下游 ready。
- `START_TIME=0` 的含义是使用首个 descriptor 的 gap 作为首包相对时间。
- 当前 `RATE_Q16_16` 没做硬件缩放，不要误以为改它就能改速率。
- Vivado 2020.2 对 U200 + CMAC + DDR + XDMA 的实现很吃内存，ILA 会显著增加压力。
- 远程主机上的 `/dev/xdma*` 默认只有 root 可读写，命令需要 `sudo`。
