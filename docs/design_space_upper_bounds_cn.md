# Tick Replayer 设计空间上界分析

本文计算 `PRELOAD` 模式和 `STREAM ring buffer` 模式在目标远程主机上的理论上界。
这里讨论的是设计空间上界，不是当前 RTL 或当前 host loader 的已实现性能。

## 结论摘要

* `PRELOAD` 的最大 `pcap` 大小由 FPGA DDR 容量决定。当前工程只使用 U200 的
  `DDR4 C0`，可用 trace 窗口按 `16GiB` 计算；如果后续设计扩展到 U200 全部
  4 个 DDR bank，则按 `64GiB` 计算。
* `STREAM ring buffer` 的最大 `pcap` 大小由主机存储决定。FPGA DDR 只保存一个
  滑动窗口，不限制整份 trace 的总容量。
* `PRELOAD` 的吞吐上界由 `CMAC` 线速、FPGA DDR 读带宽、内部预取能力共同限制；
  在设计空间上，单端口可以接近 100G 物理线速。
* `STREAM ring buffer` 的吞吐上界由 `SSD -> host memory -> PCIe H2C -> FPGA DDR`
  和 FPGA DDR 读写总带宽共同限制。以当前远程主机两块 SSD 实测连续读速度计算，
  动态流式大 trace 的上界低于单端口 100G。
* 两种模式的理想时间精度由 FPGA replay scheduler 的 tick 决定。当前工程使用
  `300MHz` replay/DDR UI clock，时间分辨率是 `3.333ns`。

## 目标主机和工程参数

采集时间：`2026-06-28`

目标主机：

```text
hostname      : FNIL-2022DEC-GPU-3
CPU           : AMD EPYC 7R13, 48 cores / 96 threads
Host memory   : 125GiB total, about 119GiB available during measurement
FPGA          : Xilinx Alveo U200
PCIe endpoint : Xilinx XDMA
PCIe link     : Gen3 x16, 8GT/s, MaxPayload=512B
```

存储：

```text
/dev/nvme0n1  KIOXIA EXCERIA PRO SSD, 2.000398934016 TB raw
              mounted at /home/rn-fellow/new_disk
              available: 1,329,698,299,904 bytes

/dev/nvme1n1  KIOXIA EXCERIA PRO SSD, 2.000398934016 TB raw
              system disk
/dev/nvme1n1p2 mounted at /
              available: 144,974,159,872 bytes
```

当前可用 SSD 空间：

```text
1,329,698,299,904 + 144,974,159,872
= 1,474,672,459,776 bytes
= about 1.475 TB
= about 1,373.40 GiB
```

两块 SSD 全部容量：

```text
2 * 2,000,398,934,016 bytes
= 4,000,797,868,032 bytes
= about 4.001 TB
```

双 SSD 顺序读实测：

```text
每块盘 direct read 16GiB，并发读两块盘
总读出 32GiB，用时约 5.51s
聚合顺序读带宽 = 32GiB * 8 / 5.51s = about 49.89Gbps
```

PCIe 上界：

```text
PCIe Gen3 x16 raw payload lane upper bound
= 8GT/s * 16 lanes * 128/130
= 126.03Gbps
```

工程中保守把可用于 H2C 数据面的设计预算记为约 `120Gbps`。实际软件、驱动、
TLP、IOMMU、cache copy 和 DMA batch 开销会让可实现值低于该值。

FPGA DDR 上界：

```text
当前工程只接 DDR4 C0:
512 bit * 300MHz = 153.6Gbps

U200 四个 DDR bank 的设计空间:
4 * 153.6Gbps = 614.4Gbps
```

当前工程地址空间：

```text
XDMA -> DDR4 C0 address range: 16GiB
replay_core_0/1 and rx_cap_0/1 -> DDR4 C0 address range: 16GiB
```

## 基本公式

本文按 classic `pcap` 文件估算。classic `pcap` 有一个 24B global header，
每个 packet record 有 16B record header。下面的大容量估算中，global header
只有 24B，可以忽略不计，但公式中仍保留。

`pcap` 中的 frame bytes 不包含 Ethernet FCS；CMAC 在发送侧插入 FCS。

### PRELOAD trace 格式

`PRELOAD` 使用两个文件：

```text
desc.bin : 每包 64B descriptor
data.bin : 每包 payload，按 64B 对齐
```

每包占用 FPGA DDR：

```text
preload_trace_bytes_per_packet = 64 + align64(frame_len)
```

对应 classic `pcap` 文件大小：

```text
pcap_bytes = 24 + packet_count * (16 + frame_len)
```

### STREAM record 格式

`STREAM` 中每包 record 为：

```text
64B stream header + align64(frame_len) payload
```

每包 stream 字节数：

```text
stream_bytes_per_packet = 64 + align64(frame_len)
```

动态回放时，主机需要持续向 FPGA DDR ring 写入这些 stream bytes。

### 物理线速换算成 pcap 字节吞吐

100G Ethernet 物理线速包括 FCS、preamble/SFD 和 IFG。`pcap` 通常不存 FCS，
也不存 preamble/SFD/IFG。因此 100G 线速对应的 `pcap` payload/frame 吞吐为：

```text
pcap_rate_at_100G = 100Gbps * frame_len / (frame_len + 4 + 20)
```

其中：

```text
4B  = Ethernet FCS
20B = 8B preamble/SFD + 12B IFG
```

## PRELOAD 模式最大 pcap 大小

当前工程只使用 `DDR4 C0`，按 `16GiB` trace 空间计算。

| Frame bytes | 每包 trace bytes | 当前工程 16GiB DDR 可容纳包数 | 对应 pcap 文件大小 |
| ---: | ---: | ---: | ---: |
| `64` | `128` | `134,217,728` | `10.00GiB` |
| `512` | `576` | `29,826,161` | `14.67GiB` |
| `1518` | `1600` | `10,737,418` | `15.34GiB` |
| `9000` | `9088` | `1,890,390` | `15.87GiB` |

如果后续扩展到 U200 全部四个 DDR bank，按 `64GiB` trace 空间计算：

| Frame bytes | 每包 trace bytes | 4-bank 64GiB DDR 可容纳包数 | 对应 pcap 文件大小 |
| ---: | ---: | ---: | ---: |
| `64` | `128` | `536,870,912` | `40.00GiB` |
| `512` | `576` | `119,304,647` | `58.67GiB` |
| `1518` | `1600` | `42,949,672` | `61.36GiB` |
| `9000` | `9088` | `7,561,562` | `63.49GiB` |

因此，`PRELOAD` 模式的容量上界大致可以记为：

```text
当前工程 DDR4 C0: 约 10GiB 到 16GiB 级别的 pcap，取决于包长
U200 全 DDR bank : 约 40GiB 到 64GiB 级别的 pcap，取决于包长
```

小包容量低，是因为每包固定 64B descriptor 和 64B 对齐开销很重。

## STREAM ring buffer 模式最大 pcap 大小

`STREAM ring buffer` 只要求 FPGA DDR 中有一个滑动窗口。整份 pcap 可以留在
主机 SSD 上，因此最大容量主要由主机 SSD 决定。

### 在线转换场景

如果 host loader 能边读原始 `pcap` 边转换成 stream record 并写入 FPGA DDR
ring，而不需要同时在磁盘上保存完整 stream 文件，则最大原始 pcap 大小近似等于
可用 SSD 空间：

| 存储条件 | 最大原始 pcap 大小 |
| --- | ---: |
| 当前远程主机剩余可用空间 | about `1.475TB` |
| 两块 SSD 全部清空后的 raw 设计空间 | about `4.001TB` |

这是大容量回放最理想的软件形态。

### 预转换 stream 文件场景

如果先把 `pcap` 转成 stream 文件并存盘，只保存 stream 文件，不同时保存原始
pcap，则原始 pcap 的可对应大小为：

```text
stream_to_pcap_file_factor = (64 + align64(frame_len)) / (16 + frame_len)
max_source_pcap = available_storage / stream_to_pcap_file_factor
```

当前剩余空间约 `1.475TB` 时：

| Frame bytes | stream / pcap 文件膨胀系数 | 当前剩余空间可对应的原始 pcap |
| ---: | ---: | ---: |
| `64` | `1.600x` | about `0.922TB` |
| `1518` | `1.043x` | about `1.414TB` |
| `9000` | `1.008x` | about `1.463TB` |

如果磁盘上需要同时保留原始 pcap 和转换后的 stream 文件，则最大原始 pcap 还要
再下降：

| Frame bytes | 当前剩余空间同时保留 pcap + stream |
| ---: | ---: |
| `64` | about `0.567TB` |
| `1518` | about `0.722TB` |
| `9000` | about `0.734TB` |

## 吞吐量理论上界

### 100G 物理线速对应 pcap 吞吐

| Frame bytes | 100G 线速下 pcap 吞吐上界 | 100G 线速下包速率 |
| ---: | ---: | ---: |
| `64` | `72.73Gbps` | `142.05Mpps` |
| `512` | `95.52Gbps` | `23.32Mpps` |
| `1518` | `98.44Gbps` | `8.11Mpps` |
| `9000` | `99.73Gbps` | `1.39Mpps` |

### PRELOAD 吞吐上界

`PRELOAD` 在回放时不再依赖 host SSD 或 PCIe H2C。理想情况下，数据已经全部在
FPGA DDR 中，因此上界是：

```text
min(CMAC line-rate pcap throughput, FPGA DDR read throughput / trace_overhead)
```

当前工程 `DDR4 C0` 理想读上界为 `153.6Gbps`，单端口 100G 回放所需的 DDR 读
带宽不超过该值。因此，在设计空间中，`PRELOAD` 单端口吞吐上界就是 100G 线速
对应的 pcap 吞吐：

| Frame bytes | PRELOAD 设计上界 |
| ---: | ---: |
| `64` | `72.73Gbps` pcap bytes |
| `512` | `95.52Gbps` pcap bytes |
| `1518` | `98.44Gbps` pcap bytes |
| `9000` | `99.73Gbps` pcap bytes |

注意：这不是当前简单 `ddr_trace_reader` 的实测值。当前实现对每包 descriptor
和 payload 读事务处理较串行，小包会远低于这个设计上界。达到上界需要 descriptor
cache、多 outstanding read、深 prefetch FIFO 和包级流水化。

### STREAM ring buffer 吞吐上界

动态 ring 模式需要主机持续写入 stream record，同时 FPGA 从 DDR 读出 stream
record。因此上界是：

```text
stream_factor = (64 + align64(frame_len)) / frame_len

pcap_rate <= CMAC_pcap_rate
pcap_rate <= PCIe_H2C_rate / stream_factor
pcap_rate <= SSD_read_rate / stream_factor
pcap_rate <= DDR_total_available_for_read_write / (2 * stream_factor)
```

其中 `2 * stream_factor` 是因为当前 memory-mapped ring 架构会把 stream bytes
先写入 FPGA DDR，再从 FPGA DDR 读出，同一份数据消耗一次 DDR write 和一次
DDR read。

以远程主机当前双 SSD 实测 `49.89Gbps` 聚合顺序读为约束：

| Frame bytes | stream_factor | STREAM ring 上界，从双 SSD 持续读 |
| ---: | ---: | ---: |
| `64` | `2.000x` | `24.94Gbps` |
| `512` | `1.125x` | `44.34Gbps` |
| `1518` | `1.054x` | `47.33Gbps` |
| `9000` | `1.010x` | `49.40Gbps` |

如果数据已经在 host memory/page cache 中，不受 SSD 连续读限制，则看 PCIe 和 FPGA
DDR：

| 设计条件 | 64B | 512B | 1518B | 9000B |
| --- | ---: | ---: | ---: | ---: |
| 当前工程，只用 DDR4 C0 | `38.40Gbps` | `68.27Gbps` | `72.86Gbps` | `76.06Gbps` |
| U200 四 DDR bank 设计空间 | `60.00Gbps` | `95.52Gbps` | `98.44Gbps` | `99.73Gbps` |

解释：

* 当前工程只用 DDR4 C0 时，动态 ring 需要 DDR 同时承担 host write 和 FPGA read，
  因此 `153.6Gbps / 2` 成为大包的主要上界。
* 四 DDR bank 设计空间下，大包可以接近 100G pcap 吞吐；小包仍受 PCIe 和
  stream header 开销限制。64B 小包要达到 100G 物理线速，H2C stream 需要约
  `145.45Gbps`，超过 PCIe Gen3 x16 的可用数据面上界。
* 如果从 SSD 实时读，则远程主机当前实测 `49.89Gbps` SSD 聚合读带宽会先成为
  上界，因此无法单靠当前两块 SSD 支撑 100G 动态回放。

## 回放精度理论上界

两种模式最终都由 FPGA replay scheduler 控制发包时刻。host 只负责把未来的数据
放进 DDR 或 ring，不直接决定每个包的发出时间。

当前工程 replay core 连接到 DDR4 UI clock，按 `300MHz` 计算：

```text
tick_period = 1 / 300MHz = 3.333ns
```

因此理想时间精度上界：

```text
时间分辨率: 3.333ns
保守量化误差: within +/- 1 tick, about +/- 3.333ns
如果软件转换 timestamp 时做 round-to-nearest: about +/- 1.667ns
```

如果后续把 scheduler 移到 CMAC user clock `322.265625MHz`，tick 可变为：

```text
1 / 322.265625MHz = 3.103ns
```

但当前工程的有效调度 tick 仍按 `300MHz` 计算。

精度成立的条件：

```text
PRELOAD:
  descriptor/payload prefetch 足够深
  DDR reader 不断供
  late_packets = 0
  underrun_packets = 0

STREAM ring:
  STREAM_LEVEL 不在 active replay 中掉到 0
  host producer 始终领先 FPGA consumer
  late_packets = 0
  underrun_packets = 0
  stream_overrun = 0
```

换句话说，理论时间分辨率是纳秒级；但实际“能不能保持这个精度”，取决于数据是否
总能提前到达 scheduler 前面的 FIFO。

## 设计含义

`PRELOAD`：

```text
优点: 吞吐上界最高，时间精度最好控制。
缺点: pcap 容量受 FPGA DDR 限制，当前工程约 10GiB 到 16GiB 级别。
```

`STREAM ring buffer`：

```text
优点: pcap 容量可以扩展到主机 SSD 级别，当前可用空间约 1.475TB。
缺点: 动态吞吐上界受 SSD、PCIe、DDR read/write 放大共同限制。
```

对这个目标远程主机而言，如果坚持从 SSD 动态读取并通过 memory-mapped
`XDMA H2C -> FPGA DDR ring -> FPGA DDR read -> CMAC` 的架构，单端口 100G
动态回放的设计上界被 SSD 实测聚合读带宽压在约 `50Gbps stream bytes`，大包
pcap 吞吐也只有约 `47Gbps` 上界。

要让动态大 trace 接近单端口 100G，需要至少满足下面几个方向之一：

* 更快的 SSD 阵列或更多 NVMe 并发读，使 SSD 聚合读超过约 `105Gbps` stream
  bytes for 1518B frames。
* 数据提前常驻 host memory/page cache，绕过 SSD 持续读瓶颈。
* 使用 U200 多 DDR bank，降低单 bank read/write 争用。
* 改为 `QDMA` 或 `XDMA AXI4-Stream H2C`，尽量绕开“写 DDR 再读 DDR”的双倍 DDR
  带宽消耗。
* 降低 stream 元数据开销，例如小包场景批量 metadata packing，而不是每包固定
  64B header。

