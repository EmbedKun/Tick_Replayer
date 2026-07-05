# 2026-07-05 SSD 上限与 STREAM 动态换入瓶颈复测

本轮目标是解释为什么双 SSD 曾经测到 `50Gbps+` 读上限，但 `STREAM ring` 动态换入一开始只有 `20Gbps+`，并尝试把 loader 推近 SSD 上限。

## 1. 重新测 SSD 上限

远程主机有两块 `KIOXIA-EXCERIA PRO SSD`：

```text
nvme0n1 -> /home/rn-fellow/new_disk
nvme1n1p2 -> /
```

使用临时 C++ 基准，从 `64GB` striped block 数据集做乱序 `O_DIRECT` 读。每个线程复用 `4096B` 对齐 buffer，不做排序、不写 XDMA。

结果：

```text
aggregate, lane=-1:
bytes   = 64,000,000,000
seconds = 10.102655
gbps    = 50.680

lane 0:
bytes   = 32,000,000,000
seconds = 8.594031
gbps    = 29.788

lane 1:
bytes   = 32,000,000,000
seconds = 8.552936
gbps    = 29.931
```

结论：用户说的 `50Gbps+` SSD 并发读上限是成立的。之前 `xdma_stream_ring_fast --dry-run` 测到 `24Gbps`，不是 SSD 本体上限，而是旧 loader 的读队列、按序重排、大块临时分配和 buffered read 路径共同造成的上限。

## 2. Host 到 XDMA 上限

主机内存到 XDMA H2C 的 benchmark：

```text
threads=2, chunk=64MiB:
throughput_gbps = 77.162

threads=4, chunk=64MiB:
throughput_gbps = 77.278
```

所以 Host memory -> XDMA 本身也不是 `20Gbps` 级瓶颈。

## 3. Loader 修改

`xdma_stream_ring_fast.cpp` 新增 striped direct-copy path：

```text
SSD block -> small 4096B-aligned reusable buffer -> XDMA H2C -> FPGA DDR ring
```

关键点：

- 不再先把完整 `64MiB` block 读入大 `Chunk` 再排队给 writer。
- worker 直接把 block 搬到已经预留好的 FPGA ring offset。
- `STREAM_WR_PTR` 仍然只按 block 顺序推进，保证 FPGA 不会读到未完整写入的 record。
- 每个 worker 独立打开 H2C fd，避免多线程共享同一个 XDMA fd。

这保持了原来的调度语义：host 只负责填 ring，FPGA 仍按 stream header 中的 tick 调度发包。

## 4. 稳定动态换入测试

使用 `64GB` stream、`1518B`、`gap=160`：

```text
stream_bytes      = 64,000,000,000
packet_count      = 40,000,000
record_len        = 1600
stream demand     = 1600 * 8 / (160 / 300e6) = 24.000Gbps
L2 replay demand  = 1518 * 8 / (160 / 300e6) = 22.770Gbps
```

direct-copy loader 结果：

```text
source_mode       : striped_direct
reader_threads    : 4
direct_read       : true
committed_bytes   : 64000000000
tx_packets        : 40000000
late_packets      : 0
underrun_packets  : 0
load_gbps         : 28.324
hw_gbps           : 22.770
load_seconds      : 18.076563
```

`reader_threads=8` 得到类似结果：

```text
load_gbps = 28.339
late      = 0
underrun  = 0
```

相比上一版 `22.190Gbps` load，这版在稳定动态 case 上提升到约 `28.3Gbps`。

## 5. 为什么还没有达到 50Gbps

为了让 loader 真正以 `50Gbps` 速度持续换入，需要 replay 侧也以接近 `50Gbps` 消费 stream，否则 ring 会被写满，loader 会被反压。

因此构造了 `1518B`、`gap=80`、`64GB` trace：

```text
stream demand = 1600 * 8 / (80 / 300e6) = 48.000Gbps
L2 demand     = 1518 * 8 / (80 / 300e6) = 45.540Gbps
```

这个测试会触发当前硬件的 stream ring error：

```text
ERROR: FPGA stream ring error: status=0x000002d1
```

降低 direct-copy worker 并发、降低预填水位、增大 guard 后仍复现。`gap=160` 稳定通过，而 `gap=80` 在高动态读写压力下触发错误，说明当前瓶颈已经从 host loader 转移到 FPGA 侧的单 DDR stream ring/AXI 读写压力边界。

当前单口 bitstream 使用一个 DDR bank。`gap=80` 动态场景相当于同一个 DDR ring 同时承受：

```text
~48Gbps H2C write into DDR
~48Gbps DDR read by stream reader
```

再加上 AXI arbitration、ring wrap、prefetch FIFO 和 stream parser 压力。这个组合已经打到当前硬件实现的鲁棒性边界。

## 6. 结论

- SSD 本体上限确实约 `50.680Gbps`。
- Host memory -> XDMA H2C 可达约 `77Gbps`。
- 旧 loader 的 `20Gbps+` 不是 SSD 上限，而是软件读/排队/写 pipeline 上限。
- 新 direct-copy loader 在稳定动态 STREAM case 中把换入提升到约 `28.3Gbps`，且 `late=0`、`underrun=0`。
- 要真正达到 SSD `50Gbps` 上限，需要继续改硬件侧：
  - 修复/增强高并发 STREAM ring 下的 `0x2d1` error。
  - 使用两个 DDR bank 做 ping-pong ring，让 H2C 写和 replay 读落到不同 bank。
  - 或改成 QDMA/XDMA AXI4-Stream H2C，绕开写 DDR 再读 DDR 的双倍 DDR 压力。
  - 增加 stream reader/write-side CDC 和 AXI outstanding 的鲁棒性验证。

这轮已经证明：host 侧不是不能读到 `50Gbps`，而是当前单 DDR ring 硬件还不能在“50Gbps 写入 + 50Gbps 读出 + 精确调度”同时发生时稳定工作。
