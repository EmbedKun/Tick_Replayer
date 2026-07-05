# 2026-07-05 超大 STREAM 动态换入测试

本轮目标是让超大 trace 的 `STREAM ring` 动态换入尽量达到双 SSD 并发读上限，而不是依赖 FPGA DDR 全量预填。

## 1. Loader 优化

本轮软件侧做了三个关键优化：

- `xdma_stream_ring_fast.cpp` 的 stream chunk 改成 `4096B` 对齐 DMA buffer，避免 XDMA H2C 对普通 `std::vector` 用户缓冲走更慢路径。
- striped 输入默认使用更深的并发流水：`reader_threads=16`、`reader_window=128`、`queue_depth=128`、`writer_threads=4`。
- `stream_stripe.py` 和 `stream_stress_test.py` 默认 stripe block 改成 `64MiB` 级别，方便多 reader 并发吃满 SSD。

这些修改只影响 host loader，不改变 FPGA 调度器和时间戳语义。host 仍然只在写完完整 stream record 后推进 `STREAM_WR_PTR`，FPGA 仍然按照 descriptor/header 中的 tick 调度发包。

## 2. 基线测试

主机内存到 XDMA H2C 的上限：

```text
threads=2, chunk=64MiB:
throughput_gbps = 77.162

threads=4, chunk=64MiB:
throughput_gbps = 77.278
```

这说明当前 `STREAM` 动态换入不是 XDMA H2C 物理能力本身卡在 20Gbps 以下，之前主要是 loader 缓冲和 SSD/pwrite pipeline 没有吃满。

8GB striped trace 上，4096B 对齐前后对比：

```text
before:
load_gbps = 14.6-15.6

after, 256MB block:
load_gbps = 25.933

after, 64MB block, cached/run-to-run best:
load_gbps = 38.676
```

冷 cache 更接近真实 SSD 读盘场景：

```text
8GB cold dry-run, 16 readers / 128 window:
read_gbps = 19.553

8GB cold live, 16 readers / 128 window / 4 writers:
load_gbps = 18.871
```

冷态 live 装载达到 cold SSD dry-run 的约 `96.5%`。

## 3. 64GB 超大 Trace

构造 `1518B` 大包、`64GB` stream 文件，两个 SSD lane 交替保存 `64MB` block。

```text
packet_count       = 40,000,000
frame_len          = 1518
record_len         = 1600
stream_bytes       = 64,000,000,000
total_frame_bytes  = 60,720,000,000
block_count        = 1000
lane_count         = 2
```

### Cold SSD Dry-run

只读双 SSD 并重排 block，不访问 XDMA：

```bash
sync
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

/tmp/tr_stream_dualssd_board/software/xdma_stream_ring_fast --port 0 \
  --stripe-manifest /home/user/tick_dualssd_work/direct_blocks/dual_1518_gap160_40m_64mblk/stripe_manifest.json \
  --reader-threads 16 --reader-window-blocks 128 \
  --queue-depth 128 --read-bytes 0x4000000 --dry-run
```

结果：

```text
block_count       : 1000
reader_threads    : 16
reader_window     : 128
chunks            : 1000
committed_bytes   : 64000000000
committed_packets : 40000000
read_gbps         : 24.102
read_seconds      : 21.243467
```

### Dynamic STREAM Replay

使用 `gap=160`，对应 L2 回放吞吐：

```text
1518 * 8 / (160 / 300e6) = 22.770Gbps
```

对应 stream record 消费约：

```text
1600 * 8 / (160 / 300e6) = 24.000Gbps
```

命令：

```bash
sync
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

sudo /tmp/tr_stream_dualssd_board/software/xdma_stream_ring_fast --port 0 \
  --stripe-manifest /home/user/tick_dualssd_work/direct_blocks/dual_1518_gap160_40m_64mblk/stripe_manifest.json \
  --ring-base 0x20000000 --ring-size 0x300000000 --prefill-bytes 0x2c0000000 \
  --guard-bytes 0x100000 --timeout 180 --feed-timeout 180 \
  --force-link-up --force-tx-ready
```

注意：这里没有显式写 `--reader-threads/--reader-window-blocks/--queue-depth/--writer-threads`，因为本轮已经把 striped 模式默认值固化成高性能参数。

结果：

```text
block_count       : 1000
reader_threads    : 16
reader_window     : 128
queue_depth       : 128
writer_threads    : 4
dma_buffer_align  : 4096
committed_bytes   : 64000000000
committed_packets : 40000000
tx_packets        : 40000000
tx_bytes          : 60720000000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
load_gbps         : 22.190
hw_gbps           : 22.770
debug_ticks       : 6400000026
stream_write_ptr  : 64000000000
stream_read_ptr   : 64000000000
stream_ptr_error  : no
stream_overrun    : no
stream_size_valid : yes
```

这个测试证明：当 trace 远大于 FPGA ring buffer 时，系统可以持续执行

```text
dual SSD -> host memory queue -> XDMA H2C -> FPGA DDR ring -> scheduler/TX
```

并且在接近 cold SSD 并发读上限的速率下保持正确性。

## 4. 结论

- 4096B 对齐 DMA buffer 是这轮提升的关键，解决了普通用户态 buffer 造成的 XDMA H2C 慢路径问题。
- 64GB 级别动态换入已经稳定通过，`late/underrun/drop/stall` 全为 0。
- 对这台主机，cold 双 SSD 并发读上限在本测试中约 `24.1Gbps` stream bytes；动态 replay case 达到 `22.19Gbps` measured load 和 `22.77Gbps` scheduled L2 replay。
- 如果要让超大 trace 动态 STREAM 达到 100Gbps，需要更高的 SSD 阵列读带宽和更高效的 host-to-FPGA 提交路径，例如 QDMA/XDMA AXI4-Stream H2C、多 H2C queue、pinned hugepage 或内核态提交。
