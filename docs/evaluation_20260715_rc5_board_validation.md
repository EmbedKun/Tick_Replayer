# 2026-07-15 RC5 上板验证记录

本次验证对象是 `20260715_0754_rc5_4ddr_dual_timing_clean` bitstream。
该版本为双端口、四 DDR bank、300 MHz timing-clean release candidate。

## 版本与时序

远程构建目录：

```text
/home/user/tick_replayer_rc1_20260710/build_release_rc5_timing_patch_20260715_051922
```

归档目录：

```text
bitstreams/20260715_0754_rc5_4ddr_dual_timing_clean/
```

实现结果：

```text
WNS = +0.006 ns
TNS = 0.000 ns
WHS = +0.006 ns
THS = 0.000 ns
All user specified timing constraints are met.
```

资源使用：

```text
CLB LUTs        239471 / 1182240  20.26%
CLB Registers   308427 / 2364480  13.04%
Block RAM Tile     842 / 2160     38.98%
URAM               256 / 960      26.67%
DSPs                12 / 6840      0.18%
```

烧录后需要做一次 PCIe remove/rescan，随后 XDMA BAR 和设备节点恢复正常：

```text
01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]
Kernel driver in use: xdma
/dev/xdma0_h2c_0
/dev/xdma0_c2h_0
/dev/xdma0_user
```

## DDR H2C/C2H 读回校验

覆盖四个 DDR bank 的低地址窗口：

```bash
python3 software/ddr_readback_check.py \
  --repeat 1 \
  --case 0x00000000:1048576 \
  --case 0x10000000:1048576 \
  --case 0x400000000:1048576 \
  --case 0x800000000:1048576 \
  --case 0xc00000000:1048576 \
  --chunk-bytes 1048576
```

输出摘录：

```text
PASS addr=0x00000000 size=1048576 repeat=0 h2c=13.711Gbps c2h=4.986Gbps
PASS addr=0x10000000 size=1048576 repeat=0 h2c=13.746Gbps c2h=6.105Gbps
PASS addr=0x400000000 size=1048576 repeat=0 h2c=13.613Gbps c2h=13.989Gbps
PASS addr=0x800000000 size=1048576 repeat=0 h2c=8.764Gbps c2h=20.832Gbps
PASS addr=0xc00000000 size=1048576 repeat=0 h2c=14.328Gbps c2h=15.830Gbps
```

结论：Host XDMA 到四个 DDR bank 的读写路径均通过确定性 pattern 校验。

## 控制平面

```bash
python3 software/traffic_replay_cli.py stop
python3 software/traffic_replay_cli.py clear
python3 software/traffic_replay_cli.py status
```

输出摘录：

```text
mode              : preload
running           : no
cmac_link_up      : yes
tx_gate_open      : yes
force_link_up     : no
force_tx_ready    : no
auto_tx_drop      : yes
tx_packets        : 0
tx_bytes          : 0
drop_packets      : 0
stall_events      : 0
```

结论：AXI-Lite 控制寄存器可读写，`stop/clear/status` 工作正常。

## PRELOAD 单端口吞吐

```bash
python3 software/preload_stress_test.py \
  --port 0 \
  --packet-count 200000 \
  --case 1518:38 \
  --case 64:3 \
  --require-no-drop \
  --timeout 30
```

输出摘录：

```text
case frame_len=1518 gap=38 done=True tx=200000 drop=0 delivered_est=200000 late=0 underrun=0 stall=0 l2=95.873Gbps wire=97.389Gbps
case frame_len=64 gap=3 done=True tx=200000 drop=0 delivered_est=200000 late=0 underrun=0 stall=0 l2=51.200Gbps wire=70.400Gbps
```

混合包测试：

```bash
python3 software/preload_mixed_test.py \
  --port 0 \
  --packet-count 200000 \
  --pattern 64:3,1518:38 \
  --require-no-drop \
  --timeout 30
```

输出摘录：

```text
mixed port=0 pattern=64:3,1518:38 packets=200000 done=True tx=200000 drop=0 late=0 underrun=0 stall=0 ticks=4100027 expected_ticks=4100000 tick_error=27 l2=92.604Gbps wire=95.414Gbps
```

## PRELOAD 双端口同步回放

大包：

```bash
python3 software/dual_port_preload_test.py \
  --packet-count 100000 \
  --frame-len 1518 \
  --gap-ticks 38 \
  --port0-desc-base 0x0000000000 \
  --port0-data-base 0x0010000000 \
  --port1-desc-base 0x0400000000 \
  --port1-data-base 0x0410000000 \
  --require-no-drop \
  --timeout 40
```

输出摘录：

```text
port0: tx=100000 drop=0 late=0 underrun=0 stall=0 l2=95.873Gbps wire=97.389Gbps
port1: tx=100000 drop=0 late=0 underrun=0 stall=0 l2=95.873Gbps wire=97.389Gbps
aggregate: l2=191.746Gbps wire=194.778Gbps
```

小包：

```text
port0: tx=100000 drop=0 late=0 underrun=0 stall=0 l2=51.199Gbps wire=70.399Gbps
port1: tx=100000 drop=0 late=0 underrun=0 stall=0 l2=51.199Gbps wire=70.399Gbps
aggregate: l2=102.399Gbps wire=140.798Gbps
```

结论：双端口 bank-local PRELOAD 可以同时工作，且两个端口保持同等级吞吐。

## LOOP 模式

```bash
python3 software/gen_synthetic_trace.py \
  --out-dir reports/board_validation_20260715/work/loop_trace \
  --packet-count 100 \
  --frame-len 512 \
  --gap-ticks 1000

python3 software/tick_replay.py load \
  --manifest reports/board_validation_20260715/work/loop_trace/manifest.json \
  --mode loop \
  --port 0 \
  --desc-base 0x0000000000 \
  --data-base 0x0010000000 \
  --loop-count 3 \
  --loop-gap 30000
```

输出摘录：

```text
mode              : loop
running           : no
done              : yes
tx_packets        : 300
tx_bytes          : 153600
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
```

结论：LOOP 模式可以通过 AXI-Lite 重新配置，不需要重新烧录 bitstream。

## STREAM Ring 模式

### 正确性安全工作点

当前双端口 release 中，port0 replay reader 只接 DDR0，port1 replay reader 只接 DDR1。
因此本版本的 port0 STREAM ring 是单 DDR bank ring；port0 跨 DDR0/DDR1 的 ping-pong ring
需要单端口 multi-DDR build 或修改 BD 连接。

500k 个 `1518B` 包，gap 改写为 `800` tick，dual-SSD striped 输入，单 DDR0 ring：

```bash
python3 software/tick_replay.py stream \
  --stripe-manifest reports/board_validation_20260715/work/stream_striped_gap800/stripe_manifest.json \
  --port 0 \
  --ring-base 0x20000000 \
  --ring-size 0x08000000 \
  --prefill-bytes 0x04000000 \
  --batch-bytes 0x04000000 \
  --read-bytes 0x04000000 \
  --queue-depth 128 \
  --writer-threads 4 \
  --reader-threads 16 \
  --reader-window-blocks 128 \
  --timeout 120 \
  --feed-timeout 120
```

输出摘录：

```text
source_mode       : striped_direct
committed_bytes   : 800000000
committed_packets : 500000
completed         : true
tx_packets        : 500000
tx_bytes          : 759000000
late_packets      : 0
underrun_packets  : 0
stream_status     : 0x000003a2
load_gbps         : 5.559
hw_gbps           : 4.554
drop_packets      : 0
stall_events      : 0
```

结论：当前 dual-port release 的 STREAM ring 功能正确，安全动态回放点为本测试覆盖的
`4.554 Gbps` L2。更高动态速率需要 port0 multi-DDR/ping-pong build 或更深的 stream reader
和出口调度缓冲。

### 高速装载后端基准

同一份 dual-SSD striped 数据源，只测 SSD -> Host DRAM reorder/read，不访问 FPGA：

```bash
./software/xdma_stream_ring_fast \
  --stripe-manifest reports/board_validation_20260715/work/stream_striped_pingpong_gap160/stripe_manifest.json \
  --dry-run \
  --reader-threads 16 \
  --reader-window-blocks 128 \
  --queue-depth 128 \
  --read-bytes 0x04000000
```

输出摘录：

```text
direct_read       : true
committed_bytes   : 800000000
committed_packets : 500000
read_gbps         : 41.828
read_seconds      : 0.153007
```

Buffered read：

```text
direct_read       : false
read_gbps         : 43.586
```

XDMA H2C 写入基准：

```text
bank0 single-thread H2C: 42.124 Gbps
bank1 single-thread H2C: 41.853 Gbps
bank0 two-thread H2C:   53.276 Gbps
DDR0+DDR1 parallel H2C: 35.291 + 34.859 = 70.150 Gbps
```

结论：主机侧 dual-SSD 读源和 XDMA H2C 本身明显高于当前 correctness-safe STREAM 回放点。
当前动态模式瓶颈主要在 dual-port release 的单 DDR ring 读写耦合、出口 ready/drop 保护和
stream egress 调度缓冲，而不是 SSD 顺序读能力。

### 当前不接受的 ping-pong 测试

尝试在当前 dual-port build 中让 port0 使用 `--pingpong --pingpong-bank1-base 0x400000000`：

```text
ERROR: FPGA stream ring error: status=0x000022e2
```

该状态表示 ping-pong/ring/size-valid/done/error，但没有 overrun 或 pointer error。
原因是当前 BD 中 `replay_core_0/M_AXI` 是 bank-local 连接，只能读 DDR0；Host 能写 DDR1，
但 port0 reader 不能读 DDR1，所以 AXI read response error 是预期限制。

## RX 光纤回环 payload 校验

TX0 -> QSFP0 -> 光纤 -> QSFP1 -> RX1：

```bash
python3 software/loopback_rx_verify.py \
  --tx-port 0 \
  --rx-port 1 \
  --desc-base 0x0000000000 \
  --data-base 0x0010000000 \
  --rx-ring-base 0x0c00000000 \
  --rx-ring-size 0x01000000 \
  --packet-count 256 \
  --frame-len 256 \
  --gap-ticks 200
```

输出摘录：

```text
tx_packets        : 256
drop_packets      : 0
late_packets      : 0
rx_packets        : 256
rx_bytes          : 65536
rx_errors         : 0
axi_writes        : 256
checked_samples   : 256
sample_mismatches : 0
PASS: TX/RX loopback sample payloads match
```

结论：TX -> CMAC -> 光纤 -> RX -> sample ring -> C2H/AXI-Lite 观察路径通过。

## RX 侧回放精度

```bash
python3 software/replay_precision_suite.py \
  --tx-port 0 \
  --rx-port 1 \
  --work-dir reports/board_validation_20260715/work/precision_suite \
  --desc-base 0x0000000000 \
  --data-base 0x0010000000 \
  --timeout 60 \
  --report reports/board_validation_20260715/rx_precision_suite.md
```

结果：

```text
uniform_128B_gap3000       PASS max_abs_error_ns = 7.272727
mixed_gap_128B             PASS max_abs_error_ns = 14.727273
small_packet_small_gap     PASS max_abs_error_ns = 8.048485
mixed_size_legal           PASS max_abs_error_ns = 85.042424
long_uniform_128B_gap3000  PASS max_abs_error_ns = 14.448485
```

说明：

- RX capture core 在 CMAC RX 时钟域统计连续包 SOP-to-SOP 间隔。
- 软件把 descriptor 中的 TX gap tick 换算到 RX CMAC tick，再和 RX sample ring 中的 gap 逐项比较。
- mixed-size 用例包含不同包长，包序列在 CMAC/PCS/FIFO 中经历更复杂的对齐和排队，因此误差上限更高，但仍在本测试设置的 `120 ns` 阈值内。

## gap=0 和恢复能力

极端 `64B/gap=0`：

```text
case frame_len=64 gap=0 done=True tx=100000 drop=98887 delivered_est=1113 late=100000 underrun=0 stall=27
```

随后 clear 并跑大包 safe case：

```text
case frame_len=1518 gap=38 done=True tx=50000 drop=0 delivered_est=50000 late=0 underrun=0 stall=0 l2=95.872Gbps wire=97.388Gbps
```

结论：overrate/gap=0 会按设计产生 late/drop/stall 计数，但系统不会死机；`clear` 后可恢复正常回放。

## 本轮结论

通过项：

- 四 DDR bank 的 XDMA H2C/C2H 读回正确。
- `PRELOAD` 单端口、双端口、大包、小包、混合包均通过。
- `LOOP` 模式通过。
- `STREAM` ring 在当前 dual-port 单 DDR ring 工作点通过。
- RX 光纤回环 payload 正确。
- RX SOP-to-SOP 回放精度套件通过。
- gap=0/overrate 后 clear 能恢复。
- 300 MHz routed timing 严格收敛。

当前限制：

- 当前 dual-port release 的 port0/port1 replay reader 是 bank-local 连接；port0 不能直接跨 DDR1 做 ping-pong ring。
- STREAM 动态高吞吐没有达到 H2C/SSD 上限，主要受单 DDR ring 读写耦合和出口调度缓冲限制。
- `--egress-schedule` 当前更适合 PRELOAD/fully-prefetched 场景；STREAM 动态路径仍需要更深的出口预发送缓冲和更严格的 backpressure 策略。

下一步建议：

- 发布两个 bitstream profile：`dual-port release` 和 `single-port high-stream multi-DDR release`。
- 在 single-port high-stream profile 中打开 `TRAFFIC_REPLAY_PORT0_MULTI_DDR=1`，使用 DDR0/DDR1 ping-pong ring。
- 为 STREAM + egress scheduling 增加专门的 TX pre-issue FIFO，避免上游 reader 被出口调度抽空。
- 将 `stream_stress_test.py` 暴露 `--pingpong`、`--start-delay-ms`、`--egress-schedule` 参数，避免绕过统一 CLI。
