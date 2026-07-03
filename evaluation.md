# Tick_Replayer 板上评测报告

本文记录当前 `timing10_ddr_regslice_20260704` bitstream 在远程 U200 板卡上的完整板上评测结果。测试覆盖 `preload`、`loop`、`stream ring buffer` 三种回放模式，以及 `XDMA H2C/C2H`、AXI-Lite 控制平面热刷新、TX/RX 光纤回环、过载鲁棒性、调度 tick 精度和可回放 trace 容量边界。

测试没有重新烧录 bitstream；所有模式切换、清空、重新装载和启动都通过 `/dev/xdma0_user` 暴露的 AXI-Lite 寄存器完成。

## 1. 测试对象

| 项目 | 内容 |
| --- | --- |
| 远程主机 | `FNIL-2022DEC-GPU-3` |
| OS | Ubuntu 20.04, Linux `5.15.0-139-generic` |
| FPGA 板卡 | Xilinx Alveo U200 |
| PCIe 设备 | `10ee:903f` |
| XDMA 设备 | `/dev/xdma0_h2c_0`, `/dev/xdma0_c2h_0`, `/dev/xdma0_user` |
| bitstream | `/home/user/tr_build_bugfix_timing10_ddr_regslice_20260704/vivado_hw/traffic_replay_hw.runs/impl_1/traffic_replay_bd_wrapper.bit` |
| bitstream SHA256 | `be1ccb31778bae73bd896fad90050a2ccf7571bea9471e67ff389a8b5168e0c9` |
| 测试软件目录 | `/home/user/traffic_replay_software` |
| 本轮原始日志 | 本地 `reports/eval_20260704_timing10_full/raw_remote.log`，远程数据目录 `/home/user/tick_eval_20260704_timing10_full` |

环境枚举输出：

```text
$ date; hostname; uname -a; lspci -nn -d 10ee:; ls -l /dev/xdma*; sha256sum traffic_replay_bd_wrapper.bit
2026年 07月 04日 星期六 07:04:08 CST
FNIL-2022DEC-GPU-3
Linux FNIL-2022DEC-GPU-3 5.15.0-139-generic #149~20.04.1-Ubuntu SMP Wed Apr 16 08:29:56 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux
01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]
crw-rw-rw- 1 root root 505, 36 7月   4 05:20 /dev/xdma0_c2h_0
crw-rw-rw- 1 root root 505, 32 7月   4 05:20 /dev/xdma0_h2c_0
crw-rw-rw- 1 root root 505,  0 7月   4 05:20 /dev/xdma0_user
be1ccb31778bae73bd896fad90050a2ccf7571bea9471e67ff389a8b5168e0c9  traffic_replay_bd_wrapper.bit
```

Vivado routed timing 已收敛：

```text
WNS(ns)  TNS(ns)  TNS Failing Endpoints  WHS(ns)  THS(ns)
  0.024    0.000                      0    0.010    0.000
All user specified timing constraints are met.
```

## 2. 总体结论

| 测试项 | 结论 | 关键结果 |
| --- | --- | --- |
| H2C/C2H DDR 读回 | 通过 | 多地址 deterministic pattern 全部读回一致 |
| AXI-Lite 热刷新 | 通过 | `write-reg/read-reg/clear/start` 可在不重烧 bitstream 的情况下刷新配置 |
| `preload` 小包 | 通过 | `64B gap=3`，`70.399Gbps wire`，`drop/late/underrun/stall=0` |
| `preload` 中包 | 通过 | `512B gap=13`，`98.953Gbps wire`，无丢包 |
| `preload` 大包 | 通过 | `1518B gap=38`，`97.389Gbps wire`，无丢包 |
| `preload` mixed | 通过 | `64:3,1518:38` 交错，`95.413Gbps wire`，无丢包 |
| `loop` 有限循环 | 通过 | `5000` 包循环 `4` 次，`tx_packets=20000`，无丢包 |
| `loop` 稳定性 | 通过 | `6,000,000` 包、约 `60s`、`loop_gap=1000` 时 `drop/late/underrun/stall=0` |
| `stream ring` 功能 | 通过 | `320MB` stream 使用 `16MB` FPGA DDR ring 动态换入换出完成 |
| `stream ring` 当前性能 | 低于目标 | 当前 C++ loader 在本机实测约 `0.8-1.0Gbps` 级别，瓶颈在 host loader/ring 装载 |
| TX/RX 数据通路 | 通过 | `TX0->RX1 64B` 和 `TX1->RX0 1518B` sample payload 均匹配 |
| `gap=0` 过载 | 鲁棒但非无损 | 会产生 `late/drop/stall` 计数，但不会死机，随后可 clear 并恢复 no-drop preload |

## 3. H2C/C2H DDR 读回校验

目的：验证 Host 通过 XDMA H2C 写入 FPGA DDR 后，可以通过 XDMA C2H 按地址读回一致数据。

命令：

```bash
python3 ddr_readback_check.py \
  --repeat 2 \
  --case 0x00000000:0x1000 \
  --case 0x00100000:0x10000 \
  --case 0x10000000:0x100000 \
  --case 0x40000000:0x400000
```

结果：

```text
PASS addr=0x00000000 size=4096 repeat=0 h2c=0.443Gbps c2h=0.695Gbps
PASS addr=0x00100000 size=65536 repeat=0 h2c=5.825Gbps c2h=3.439Gbps
PASS addr=0x10000000 size=1048576 repeat=0 h2c=8.137Gbps c2h=5.087Gbps
PASS addr=0x40000000 size=4194304 repeat=0 h2c=14.680Gbps c2h=4.748Gbps
PASS addr=0x00000000 size=4096 repeat=1 h2c=0.493Gbps c2h=0.080Gbps
PASS addr=0x00100000 size=65536 repeat=1 h2c=5.574Gbps c2h=12.391Gbps
PASS addr=0x10000000 size=1048576 repeat=1 h2c=43.810Gbps c2h=6.034Gbps
PASS addr=0x40000000 size=4194304 repeat=1 h2c=14.521Gbps c2h=5.427Gbps
SUMMARY cases=4 repeat=2 checked_bytes=10625024 aggregate_rw=0.082Gbps
```

说明：

- 这个测试是正确性测试，不是吞吐极限测试；小块读写和 Python pattern 生成会显著影响显示的平均速率。
- 结果证明 `XDMA H2C -> DDR -> XDMA C2H` 数据通路可用，没有发现地址错位或数据损坏。

## 4. AXI-Lite 控制平面热刷新

目的：验证不重新烧录 bitstream，仅通过 AXI-Lite 寄存器即可清空、改配置、重新启动。

命令：

```bash
python3 traffic_replay_cli.py --port 0 clear
python3 traffic_replay_cli.py --port 0 write-reg 0x4c 0x1234
python3 traffic_replay_cli.py --port 0 read-reg 0x4c
python3 traffic_replay_cli.py --port 0 write-reg 0x4c 0x1000
python3 traffic_replay_cli.py --port 0 read-reg 0x4c
python3 traffic_replay_cli.py --port 0 regs | sed -n '1,22p'
```

结果：

```text
0x0004c: 0x00001234
0x0004c: 0x00001000
0x00000 CONTROL        0x00000000
0x00004 MODE           0x00000000
0x00008 STATUS         0x00000030
0x00010 DESC_BASE_LO   0x04000000
0x00018 DATA_BASE_LO   0x14000000
0x00028 PKT_LO         0x0000012c
0x00048 RATE           0x00010000
0x0004c WATERMARK      0x00001000
0x00054 DEBUG_CTRL     0x00000004
0x00060 TX_PKTS_LO     0x00000000
```

结论：

- `WATERMARK` 可写可读，并且可恢复默认值。
- `clear` 后 TX 计数器归零。
- 后续测试在同一个 bitstream 上连续切换 `preload -> loop -> stream ring -> preload -> RX loopback`，没有重烧 FPGA。

## 5. Preload 模式性能与正确性

### 5.1 单端口安全速率 sweep

命令：

```bash
python3 preload_stress_test.py \
  --port 0 \
  --packet-count 100000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_safe_p0 \
  --csv /home/user/tick_eval_20260704_timing10_full/preload_safe_p0.csv \
  --timeout 90 \
  --require-no-drop \
  --case 64:3 \
  --case 512:13 \
  --case 1518:38
```

结果：

```text
case frame_len=64 gap=3 done=True tx=100000 drop=0 delivered_est=100000 late=0 underrun=0 stall=0 l2=51.199Gbps wire=70.399Gbps load=7.365Gbps
case frame_len=512 gap=13 done=True tx=100000 drop=0 delivered_est=100000 late=0 underrun=0 stall=0 l2=94.522Gbps wire=98.953Gbps load=9.398Gbps
case frame_len=1518 gap=38 done=True tx=100000 drop=0 delivered_est=100000 late=0 underrun=0 stall=0 l2=95.873Gbps wire=97.389Gbps load=10.317Gbps
```

结论：

- 当前 preload 模式下，大包和中包已经接近 100Gbps 线速。
- 64B 小包的安全点是 `gap=3`，对应约 `70.399Gbps wire`。这是整数 tick 调度的结果：`64B` 帧的 wire 字节按 `64+24` 估算，`300MHz / 3 ticks` 对应约 `70.4Gbps`；若强行 `gap=2`，目标 wire rate 会超过 100Gbps，容易进入 overrate。

### 5.2 双端口基本可用性

命令：

```bash
python3 preload_stress_test.py \
  --port 1 \
  --desc-base 0x06000000 \
  --data-base 0x18000000 \
  --packet-count 50000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_safe_p1 \
  --csv /home/user/tick_eval_20260704_timing10_full/preload_safe_p1.csv \
  --timeout 90 \
  --require-no-drop \
  --case 64:3 \
  --case 1518:38
```

结果：

```text
case frame_len=64 gap=3 done=True tx=50000 drop=0 delivered_est=50000 late=0 underrun=0 stall=0 l2=51.199Gbps wire=70.398Gbps load=7.251Gbps
case frame_len=1518 gap=38 done=True tx=50000 drop=0 delivered_est=50000 late=0 underrun=0 stall=0 l2=95.872Gbps wire=97.388Gbps load=10.583Gbps
```

结论：port1 的 preload TX 数据路径和 port0 同级别，至少在单端口分时测试中表现一致。

### 5.3 大小包 mixed 回放

命令：

```bash
python3 preload_mixed_test.py \
  --port 0 \
  --packet-count 100000 \
  --pattern 64:3,1518:38 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_mixed \
  --csv /home/user/tick_eval_20260704_timing10_full/preload_mixed.csv \
  --timeout 90 \
  --require-no-drop
```

结果：

```text
mixed port=0 pattern=64:3,1518:38 packets=100000 done=True tx=100000 drop=0 late=0 underrun=0 stall=0 ticks=2050027 expected_ticks=2050000 tick_error=27 l2=92.604Gbps wire=95.413Gbps load=11.366Gbps
```

结论：

- 混合包长不是分别跑两组，而是交错生成 descriptor/data。
- 当前 mixed case 可以稳定达到约 `95.413Gbps wire`，并保持 `drop=0 late=0 underrun=0 stall=0`。

## 6. 调度 tick 精度

当前硬件使用 `300MHz` tick。Host 侧提前把 pcap 包间隔换算成 `gap_ticks` 写入 descriptor；FPGA scheduler 按 descriptor 的 gap 逐包调度。

严格 0 tick 误差测试：

```bash
python3 preload_precision_check.py \
  --port 0 \
  --packet-count 50000 \
  --pattern 64:3,1518:38 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_precision \
  --timeout 90 \
  --max-abs-tick-error 0
```

结果：

```text
packet_count      : 50000
completed         : True
tx_packets        : 50000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
expected_ticks    : 1025000
debug_ticks       : 1025027
tick_error        : 27
FAIL: scheduler precision check failed
```

允许固定管线偏移后：

```bash
python3 preload_precision_check.py \
  --port 0 \
  --packet-count 50000 \
  --pattern 64:3,1518:38 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_precision_allow32 \
  --timeout 90 \
  --max-abs-tick-error 32
```

结果：

```text
expected_ticks    : 1025000
debug_ticks       : 1025027
tick_error        : 27
PASS: scheduler debug_ticks matches descriptor gap_ticks budget
```

解释：

- `27 ticks` 在 `300MHz` 下约为 `90ns`。
- 该误差在 mixed `100000` 包测试中仍为 `27 ticks`，表现为固定管线 flush/start-stop 偏移，而不是随包数增长的 per-packet 漂移。
- 目前这个测试验证的是 FPGA scheduler 内部 tick accounting。若要验证真实线侧包间隔，需要在 RX 侧增加 per-packet timestamp，或用 ILA/外部仪表捕获 CMAC TX/RX 边界。

## 7. Loop 模式

### 7.1 有限循环功能测试

命令：

```bash
python3 gen_synthetic_trace.py \
  --out-dir /home/user/tick_eval_20260704_timing10_full/loop_trace \
  --packet-count 5000 \
  --frame-len 512 \
  --gap-ticks 13

python3 xdma_load_trace.py \
  --manifest /home/user/tick_eval_20260704_timing10_full/loop_trace/manifest.json \
  --port 0 \
  --desc-base 0x02000000 \
  --data-base 0x12000000 \
  --mode loop \
  --loop-count 4 \
  --loop-gap 1000 \
  --auto-drop \
  --clear-force-tx-ready
```

结果：

```text
mode              : loop
running           : no
done              : yes
tx_packets        : 20000
tx_bytes          : 10240000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
debug_ticks       : 262972
```

结论：`loop-count=4` 按预期把 `5000` 包 trace 发送了 `4` 轮，总包数 `20000`，无丢包、无 underrun、无 stall。

### 7.2 Loop 稳定性测试

命令：

```bash
python3 gen_synthetic_trace.py \
  --out-dir /home/user/tick_eval_20260704_timing10_full/loop_stability_gap1000 \
  --packet-count 1000 \
  --frame-len 64 \
  --gap-ticks 3000

python3 xdma_load_trace.py \
  --manifest /home/user/tick_eval_20260704_timing10_full/loop_stability_gap1000/manifest.json \
  --port 0 \
  --desc-base 0x07000000 \
  --data-base 0x17000000 \
  --mode loop \
  --loop-count 6000 \
  --loop-gap 1000 \
  --auto-drop \
  --clear-force-tx-ready
```

结果：

```text
mode              : loop
running           : no
done              : yes
late              : no
underrun          : no
tx_packets        : 6000000
tx_bytes          : 384000000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
drop_beats        : 0
stall_events      : 0
debug_ticks       : 17988002004
```

补充观察：

- `loop_gap=0` 的 3 分钟测试也没有 `drop/underrun/stall`，但每轮边界出现 1 个 late，`loop-count=18000` 时 `late_packets=17999`。
- 因此 loop 模式建议配置非零 `loop_gap`，为每轮 trace 的 descriptor/payload 重启提供边界裕量。

## 8. Stream Ring Buffer 模式

当前 stream 模式只保留 DDR ring-buffer 路径：Host 持续把 stream record 写入 FPGA DDR ring，FPGA 从 ring 中解析 descriptor/payload 并调度发包。

### 8.1 错误 ring 参数拒绝

当 `batch_bytes + guard_bytes > ring_size` 时，C++ loader 会拒绝启动，防止 Host 撑爆 ring。

```text
ERROR: --batch-bytes plus --guard-bytes must fit in the ring
ring stream replay failed for frame_len=64 with exit=1
```

这说明 loader 侧的 ring 参数保护有效。

### 8.2 64B stream safe case

首次使用 `start-time=0` 时出现 `late_packets=1`，这是首包立即调度的启动边界效应：

```text
frame_len=64 gap_ticks=100
completed=true
tx_packets=100000
late_packets=1
underrun_packets=0
load_gbps=5.758
hw_gbps=1.536
```

补充直接调用 C++ loader，并设置 `--start-time 10000`：

```bash
./xdma_stream_ring_fast \
  --port 0 \
  --manifest /home/user/tick_eval_20260704_timing10_full/stream_safe_64_gap100/len64_pkts100000_gap100/stream_manifest.json \
  --ring-base 0x24000000 \
  --ring-size 0x02000000 \
  --prefill-bytes 0x01000000 \
  --guard-bytes 0x00100000 \
  --batch-bytes 0x00800000 \
  --read-bytes 0x00800000 \
  --queue-depth 4 \
  --watermark 4096 \
  --timeout 90 \
  --feed-timeout 90 \
  --start-time 10000
```

结果：

```text
completed         : true
tx_packets        : 100000
tx_bytes          : 6400000
late_packets      : 0
underrun_packets  : 0
stream_status     : 0x000003a5
max_ring_level    : 8388608
min_ring_free     : 24117248
load_gbps         : 5.586
hw_gbps           : 1.534
```

### 8.3 1518B stream safe case

命令：

```bash
python3 stream_stress_test.py \
  --port 0 \
  --frame-sizes 1518 \
  --packet-count 100000 \
  --gap-ticks 5000 \
  --ring-base 0x24000000 \
  --ring-size 0x02000000 \
  --prefill-bytes 0x01000000 \
  --batch-bytes 0x00800000 \
  --read-bytes 0x00800000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/stream_safe_1518_gap5000 \
  --csv /home/user/tick_eval_20260704_timing10_full/stream_safe_1518_gap5000.csv \
  --timeout 120 \
  --feed-timeout 120
```

结果：

```text
committed_bytes   : 160000000
committed_packets : 100000
completed         : true
tx_packets        : 100000
tx_bytes          : 151800000
late_packets      : 0
underrun_packets  : 0
stream_status     : 0x000003a5
max_ring_level    : 32356160
min_ring_free     : 149696
load_gbps         : 0.947
hw_gbps           : 0.729
```

### 8.4 Trace 大于 ring 的动态换入换出

命令：

```bash
python3 stream_stress_test.py \
  --port 0 \
  --frame-sizes 1518 \
  --packet-count 200000 \
  --gap-ticks 5000 \
  --ring-base 0x24000000 \
  --ring-size 0x01000000 \
  --prefill-bytes 0x00800000 \
  --batch-bytes 0x00800000 \
  --read-bytes 0x00800000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/stream_gt_ring_gap5000 \
  --csv /home/user/tick_eval_20260704_timing10_full/stream_gt_ring_gap5000.csv \
  --timeout 160 \
  --feed-timeout 160
```

结果：

```text
ring_size         : 16777216
committed_bytes   : 320000000
committed_packets : 200000
completed         : true
tx_packets        : 200000
tx_bytes          : 303600000
late_packets      : 0
underrun_packets  : 0
stream_status     : 0x000003a5
max_ring_level    : 15575360
min_ring_free     : 153280
load_gbps         : 0.805
hw_gbps           : 0.729
```

结论：

- 本测试的 stream 文件为 `320MB`，FPGA DDR ring 只有 `16MB`，证明当前 stream ring 不是一次性 preload，而是在 Host 和 FPGA DDR 之间动态换入换出。
- 当前动态模式的实际瓶颈在 Host loader/ring 提交链路，实测 `load_gbps` 约 `0.8-1.0Gbps`，远低于 preload 模式内部回放能力。要逼近 100Gbps，需要继续升级 loader、DMA 提交方式和 FPGA 侧 ring/prefetch。

### 8.5 Stream gap=0 过载鲁棒性

命令：

```bash
python3 stream_stress_test.py \
  --port 0 \
  --frame-sizes 64 \
  --packet-count 50000 \
  --gap-ticks 0 \
  --ring-base 0x24000000 \
  --ring-size 0x01000000 \
  --prefill-bytes 0x00800000 \
  --batch-bytes 0x00800000 \
  --read-bytes 0x00800000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/stream_gap0 \
  --csv /home/user/tick_eval_20260704_timing10_full/stream_gap0.csv \
  --timeout 90 \
  --feed-timeout 90
```

结果：

```text
completed         : true
tx_packets        : 50000
tx_bytes          : 3200000
late_packets      : 50000
underrun_packets  : 0
stream_status     : 0x000003a5
load_gbps         : 3.174
hw_gbps           : 21.935
```

随后不打开 `force_tx_ready`，直接恢复 preload safe case：

```bash
python3 traffic_replay_cli.py --port 0 debug-tx-ready off
python3 preload_stress_test.py \
  --port 0 \
  --packet-count 20000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/recovery_after_stream \
  --timeout 60 \
  --require-no-drop \
  --case 64:3
```

结果：

```text
case frame_len=64 gap=3 done=True tx=20000 drop=0 delivered_est=20000 late=0 underrun=0 stall=0 l2=51.197Gbps wire=70.395Gbps load=7.291Gbps
```

结论：stream overrate 后系统可以通过正常控制面恢复，不需要重新烧录 bitstream。

## 9. Gap=0 / overrate 鲁棒性

Preload overrate 命令：

```bash
python3 preload_stress_test.py \
  --port 0 \
  --packet-count 50000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/preload_overrate \
  --csv /home/user/tick_eval_20260704_timing10_full/preload_overrate.csv \
  --timeout 90 \
  --case 64:0 \
  --case 1518:0
```

结果：

```text
case frame_len=64 gap=0 done=True tx=50000 drop=44663 delivered_est=5337 late=50000 underrun=0 stall=14 l2=7.290Gbps wire=10.024Gbps load=6.429Gbps
case frame_len=1518 gap=0 done=True tx=50000 drop=48724 delivered_est=1276 late=50000 underrun=0 stall=32 l2=3.487Gbps wire=3.542Gbps load=15.416Gbps
```

恢复测试：

```bash
python3 traffic_replay_cli.py --port 0 debug-tx-ready off
python3 preload_stress_test.py \
  --port 0 \
  --packet-count 20000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/recovery_preload \
  --timeout 60 \
  --require-no-drop \
  --case 64:3
```

结果：

```text
case frame_len=64 gap=3 done=True tx=20000 drop=0 delivered_est=20000 late=0 underrun=0 stall=0 l2=51.197Gbps wire=70.395Gbps load=6.612Gbps
```

结论：

- `gap=0` 的意义是极限过载/鲁棒性测试，不代表正确回放能力。
- 当前系统在 overrate 下会产生 `late/drop/stall` 计数，但不会卡死。
- overrate 后无需重新烧录 bitstream，使用 AXI-Lite `clear/start` 路径即可恢复正常 preload no-drop case。

## 10. TX/RX 光纤回环正确性

当前两路 QSFP 已经光纤互联。RX 侧只做统计和 sample ring 捕获，然后 Host 通过 C2H 从 DDR 读回 sample，和 TX 侧生成的 payload 对比。

### 10.1 TX0 -> RX1，64B

命令：

```bash
python3 loopback_rx_verify.py \
  --tx-port 0 \
  --rx-port 1 \
  --packet-count 1000 \
  --frame-len 64 \
  --truncate-bytes 64 \
  --gap-ticks 2000 \
  --desc-base 0x04000000 \
  --data-base 0x14000000 \
  --rx-ring-base 0x32000000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/rx_p0_to_p1_64 \
  --timeout 90
```

结果：

```text
packet_count      : 1000
completed         : True
tx_packets        : 1000
drop_packets      : 0
late_packets      : 0
stall_events      : 0
rx_packets        : 1000
rx_bytes          : 64000
rx_errors         : 0
captured_bytes    : 64000
axi_writes        : 1000
axi_errors        : 0
write_ptr         : 64000
checked_samples   : 1000
sample_mismatches : 0
PASS: TX/RX loopback sample payloads match
```

### 10.2 TX1 -> RX0，1518B deep sample

命令：

```bash
python3 loopback_rx_verify.py \
  --tx-port 1 \
  --rx-port 0 \
  --packet-count 300 \
  --frame-len 1518 \
  --truncate-bytes 1536 \
  --gap-ticks 2000 \
  --desc-base 0x08000000 \
  --data-base 0x18000000 \
  --rx-ring-base 0x34000000 \
  --work-dir /home/user/tick_eval_20260704_timing10_full/rx_p1_to_p0_1518 \
  --timeout 90
```

结果：

```text
packet_count      : 300
completed         : True
tx_packets        : 300
drop_packets      : 0
late_packets      : 0
stall_events      : 0
rx_packets        : 300
rx_bytes          : 455400
rx_errors         : 0
captured_bytes    : 460800
axi_writes        : 7200
axi_errors        : 0
write_ptr         : 460800
checked_samples   : 300
sample_mismatches : 0
PASS: TX/RX loopback sample payloads match
```

结论：两条方向的 TX/CMAC/光纤/RX/sample writer/C2H readback 链路均通过 payload 校验，当前没有复现此前的 RX sample 错位和 overflow 迹象。

## 11. 当前最大回放容量

这里讨论的是处理后 trace 在 FPGA/Host 中的容量边界，不是原始 `.pcap` 文件字节数。当前 descriptor 固定 `64B`，payload 按 `64B` 对齐存储。

### 11.1 Preload 模式

默认软件布局：

- `desc_base = 0x00000000`
- `data_base = 0x10000000`
- descriptor 区域到 data 区域之间为 `256MiB`
- descriptor 数量上限为 `256MiB / 64B = 4,194,304` 包

因此在默认布局下：

| 包长 | 单包 trace 存储 | 默认布局包数上限 | 对应 L2 payload |
| --- | ---: | ---: | ---: |
| `64B` | `64B desc + 64B data = 128B` | `4,194,304` | 约 `256MiB` |
| `1518B` | `64B desc + 1536B data = 1600B` | `4,194,304` | 约 `5.93GiB` |

如果重新规划 `desc_base/data_base`，理论上可以把整块 U200 DDR 空间在 descriptor 和 payload 之间重新分配。以 `16GiB` DDR 估算：

| 包长 | 单包 trace 存储 | 理论包数上限 | 对应 L2 payload |
| --- | ---: | ---: | ---: |
| `64B` | `128B` | `134,217,728` | `8GiB` |
| `1518B` | `1600B` | `10,737,418` | 约 `15.18GiB` |

### 11.2 Stream Ring Buffer 模式

Stream ring 的逻辑 pcap/trace 大小不再受 FPGA DDR 总容量直接限制，而受 Host SSD 文件大小和 loader 持续供给能力限制。FPGA DDR 只保存滚动窗口。

本轮实测：

- stream 文件大小：`320,000,000B`
- FPGA DDR ring 大小：`16,777,216B`
- 结果：`committed_bytes=320000000`, `tx_packets=200000`, `late_packets=0`, `underrun_packets=0`

这证明当前 stream ring 可以回放大于 FPGA DDR ring 的 trace；但当前吞吐远低于 100Gbps，主要受 Host loader/ring 提交速度限制。

## 12. 当前瓶颈与已知限制

1. `preload` 模式的回放吞吐主要受调度 tick 和 CMAC/AXIS/LBUS 数据路径影响。当前大包接近 100Gbps，小包在 `gap=3` 下约 `70.4Gbps wire`；若继续提高小包，需要更细粒度时间表达或多包同 tick/并行调度语义，否则 `gap=2` 已经超过 100Gbps。

2. `stream ring` 模式当前瓶颈在 Host loader 到 FPGA DDR ring 的持续装载速度。本轮 C++ loader 的 `1518B` 动态回放实测 `load_gbps` 约 `0.8-1.0Gbps`，不能支撑 100Gbps 实时回放。

3. 调度精度目前只能证明 FPGA scheduler 内部 tick accounting。真实线侧精度还需要 RX timestamp 或 ILA/外部仪表测试。

4. `loop_gap=0` 时，每轮 trace 边界可能产生 1 个 late；配置 `loop_gap=1000` 后，60s loop stability 测试中 late 消失。

5. `gap=0` 是过载测试，不是正确回放配置。系统能统计 drop/stall 并恢复，但不能保证无损。

## 13. 可复现实验顺序

建议按下面顺序复现：

```bash
cd /home/user/traffic_replay_software

# 1. 基础状态
lspci -nn -d 10ee:
ls -l /dev/xdma*
python3 traffic_replay_cli.py --port 0 status

# 2. DDR H2C/C2H 正确性
python3 ddr_readback_check.py --repeat 2 \
  --case 0x00000000:0x1000 \
  --case 0x00100000:0x10000 \
  --case 0x10000000:0x100000 \
  --case 0x40000000:0x400000

# 3. Preload 大小包和 mixed
python3 preload_stress_test.py --port 0 --packet-count 100000 \
  --require-no-drop --case 64:3 --case 512:13 --case 1518:38
python3 preload_mixed_test.py --port 0 --packet-count 100000 \
  --pattern 64:3,1518:38 --require-no-drop

# 4. Loop
python3 gen_synthetic_trace.py --out-dir /tmp/loop_trace \
  --packet-count 5000 --frame-len 512 --gap-ticks 13
python3 xdma_load_trace.py --manifest /tmp/loop_trace/manifest.json \
  --port 0 --mode loop --loop-count 4 --loop-gap 1000 \
  --desc-base 0x02000000 --data-base 0x12000000 --auto-drop

# 5. Stream ring
python3 stream_stress_test.py --port 0 --frame-sizes 1518 \
  --packet-count 200000 --gap-ticks 5000 \
  --ring-base 0x24000000 --ring-size 0x01000000 \
  --prefill-bytes 0x00800000 --batch-bytes 0x00800000 \
  --read-bytes 0x00800000 --timeout 160 --feed-timeout 160

# 6. TX/RX loopback
python3 loopback_rx_verify.py --tx-port 0 --rx-port 1 \
  --packet-count 1000 --frame-len 64 --truncate-bytes 64 \
  --gap-ticks 2000 --rx-ring-base 0x32000000
python3 loopback_rx_verify.py --tx-port 1 --rx-port 0 \
  --packet-count 300 --frame-len 1518 --truncate-bytes 1536 \
  --gap-ticks 2000 --rx-ring-base 0x34000000
```

