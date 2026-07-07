# 2026-07-07 当前版本完整功能与性能检查

本次检查对象是当前已烧录到 U200 的单端口、双 DDR bank、STREAM ping-pong
pipeline bitstream：

```text
/home/user/tick_replayer_bitstreams/20260707_stream_ring_pipeline_2bank_timing_clean/
```

构建结果：

```text
post-route WNS = +0.009 ns
post-route WHS = +0.010 ns
TNS/THS = 0
```

测试日志保存在远程主机：

```text
/home/user/tick_eval_20260707_full/
```

## 1. 测试边界

这版 bitstream 是单端口 build，只启用 `QSFP0`/`CMAC0` 的 TX 路径。由于当前没有
启用第二个 CMAC 端口，测试使用：

```text
--force-link-up
--force-tx-ready
```

因此，本轮可以验证：

- `XDMA` 枚举和 Linux 字符设备是否正常。
- `AXI-Lite` 控制寄存器是否可读写。
- `H2C/C2H` 到两个 DDR bank 的数据读写是否正确。
- `PRELOAD`/`LOOP`/`STREAM` 的调度、计数器、吞吐和鲁棒性。
- `STREAM` ping-pong ring 的大地址配置和动态换入。

本轮不能证明：

- 真实光口 TX-to-RX payload 完整性。
- RX 侧 SOP-to-SOP 的真实光纤回环逐包精度。

这些需要双端口 bitstream 或者把流量接回当前启用的 RX 端口。

## 2. PCIe、控制平面和 DDR 读写

`lspci` 和 `/dev/xdma*` 正常：

```text
01:00.0 Memory controller [0580]: Xilinx Corporation Device [10ee:903f]
/dev/xdma0_h2c_0
/dev/xdma0_c2h_0
/dev/xdma0_user
```

`AXI-Lite` 控制平面测试：

```text
write-reg 0x54 0x3 -> read back 0x00000003
write-reg 0x54 0x0 -> read back 0x00000000
```

DDR H2C/C2H 读回校验覆盖 bank0 和 bank1：

```text
PASS addr=0x00000000 size=4096
PASS addr=0x00100000 size=1048576
PASS addr=0x20000000 size=16777216
PASS addr=0x400000000 size=4096
PASS addr=0x400100000 size=1048576
PASS addr=0x420000000 size=16777216
```

纯 H2C 参考测速：

```text
bank0 4GiB write              : 48.868Gbps
bank1 4GiB write              : 47.787Gbps
two threads crossing banks    : 70.792Gbps
```

结论：`XDMA -> DDR` 和 `DDR -> XDMA` 数据通路正确，两个 DDR bank 都可通过
host 访问。当前 memory-mapped XDMA H2C 路径不是无限长 `100Gbps` STREAM 的充足数据源。

## 3. PRELOAD 模式

命令摘要：

```bash
sudo python3 /home/user/traffic_replay_software/preload_stress_test.py \
  --port 0 \
  --packet-count 200000 \
  --case 64:3 \
  --case 256:8 \
  --case 512:14 \
  --case 1518:38 \
  --force-link-up \
  --force-tx-ready \
  --require-no-drop
```

结果：

| Frame | Gap ticks | Packets | Frame/L2 throughput | Wire throughput | Result |
| ---: | ---: | ---: | ---: | ---: | --- |
| `64B` | `3` | `200000` | `51.200Gbps` | `70.400Gbps` | PASS |
| `256B` | `8` | `200000` | `76.800Gbps` | `84.000Gbps` | PASS |
| `512B` | `14` | `200000` | `87.771Gbps` | `91.885Gbps` | PASS |
| `1518B` | `38` | `200000` | `95.873Gbps` | `97.389Gbps` | PASS |

所有 case：

```text
drop_packets     = 0
late_packets     = 0
underrun_packets = 0
stall_events     = 0
```

Mixed preload：

```text
pattern           : 64:3,1518:38
packets           : 200000
tx_packets        : 200000
tx_bytes          : 158200000
late/underrun/drop/stall : 0
frame/L2          : 92.604Gbps
wire              : 95.414Gbps
```

调度 tick 预算检查：

```text
pattern           : 64:3,1518:38,128:30,512:20
packet_count      : 50000
expected_ticks    : 1137500
debug_ticks       : 1137511
tick_error        : 11 ticks = 36.7 ns
late/underrun/drop/stall : 0
```

说明：这个检查使用 TX core 的 `debug_ticks` 和 descriptor gap 总预算比较，不是
RX 侧逐包 SOP-to-SOP 测量。`11 tick` 的误差来自完成后状态采样/流水尾部余量，
真实 RX 侧精度仍需要双口或真实链路测试。

## 4. LOOP 模式

测试：

```text
trace packets      : 1000
frame_len          : 128
gap_ticks          : 50
loop_count         : 10
expected packets   : 10000
expected bytes     : 1280000
```

结果：

```text
tx_packets        : 10000
tx_bytes          : 1280000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
```

结论：`LOOP` 模式计数正确，可以不重新烧录 bitstream，仅通过 AXI-Lite 控制寄存器
重新配置并启动。

## 5. STREAM Ring 模式

### 5.1 全预填高吞吐

`100000 x 1518B`，`gap=38`，ping-pong stream：

```text
committed_bytes   : 160000000
committed_packets : 100000
tx_packets        : 100000
tx_bytes          : 151800000
late_packets      : 0
underrun_packets  : 0
load_gbps         : 8.951
hw_gbps           : 95.873
```

结论：当 ring 中已有足够数据时，STREAM reader + scheduler + TX path 可以达到
大包接近 100G 的调度吞吐。

### 5.2 最大 ring 配置 sanity

测试使用：

```text
ring_base         : 0x0
pingpong_bank1    : 0x400000000
ring_size         : 0x400000000
stream_capacity   : 34359738368 bytes = 32GiB
```

结果：

```text
tx_packets        : 16
tx_bytes          : 2048
late_packets      : 0
underrun_packets  : 0
stream_status     : 0x000023a2
```

结论：当前单口双 DDR bitstream 接受 `16GiB/bank`、总 `32GiB` 的 ping-pong
STREAM ring 配置。

### 5.3 动态 container-striped STREAM

安全动态 case，`2M x 1518B`，`gap=120`：

```text
stream_capacity   : 1073741824
committed_bytes   : 3200000000
committed_packets : 2000000
tx_packets        : 2000000
tx_bytes          : 3036000000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
load_gbps         : 31.952
hw_gbps           : 30.360
```

更高动态 case，`2M x 1518B`，`gap=80`，`2GiB` total ring：

```text
stream_capacity   : 2147483648
committed_bytes   : 3200000000
committed_packets : 2000000
tx_packets        : 2000000
tx_bytes          : 3036000000
late_packets      : 0
underrun_packets  : 0
drop_packets      : 0
stall_events      : 0
load_gbps         : 43.647
hw_gbps           : 45.540
```

结论：container stripe + 双 DDR ping-pong ring 在当前 3.2GB 合成 trace 上可以
稳定支撑约 `45.5Gbps` frame/L2 动态回放。这个结果依赖足够的 ring 预填和短时
trace 长度，不能外推成无限长 `100Gbps` 动态回放。

## 6. RX 控制面和受限项

RX control-plane sanity：

```text
rx_enable         : yes
capture_enable    : yes
link_up           : no
fifo_ready        : yes
overflow_seen     : no
ring_base         : 0x0000000030000000
ring_size         : 1048576
truncate_bytes    : 256
rx_packets        : 0
rx_bytes          : 0
rx_errors         : 0
axi_errors        : 0
```

结论：RX 寄存器、clear/config/enable/capture 控制正常；由于当前 bitstream 只启用
单端口且 `cmac_link_up=no`，没有进行真实 RX payload 校验。

## 7. 当前核心指标

| Item | Current result |
| --- | ---: |
| Routed timing | `WNS=+0.009 ns`, `WHS=+0.010 ns` |
| DDR exposed in latest bit | `2 x 16GiB = 32GiB` |
| Max validated STREAM ring config | `32GiB` ping-pong |
| PRELOAD large packet | `1518B`, `gap=38`, `95.873Gbps` frame/L2 |
| PRELOAD small packet | `64B`, `gap=3`, `51.200Gbps` frame/L2 |
| PRELOAD mixed | `64:3,1518:38`, `95.414Gbps` wire |
| LOOP | `1000 x 10`, exact packet/byte count |
| STREAM full-prefill | `1518B`, `gap=38`, `95.873Gbps` frame/L2 |
| STREAM dynamic, no errors | `1518B`, `gap=80`, `2M` packets, `45.540Gbps` frame/L2 |
| Raw H2C, single bank | about `48Gbps` |
| Raw H2C, two threads crossing banks | about `70.8Gbps` |

## 8. 结论

当前版本的 `PRELOAD`、`LOOP`、`STREAM` 基本功能、控制平面、DDR 读写和关键吞吐
测试均正常。最重要的限制是：这版是单口 forced-ready 测试 bitstream，无法证明真实
光口 TX/RX payload 完整性；而超大 pcap 的无限长动态 `STREAM` 仍受 host-to-FPGA
装载链路限制。
