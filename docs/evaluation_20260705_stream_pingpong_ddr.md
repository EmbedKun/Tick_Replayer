# STREAM 双 DDR Ping-Pong Ring 评估记录

日期：2026-07-05

## 目标

将 `STREAM` ring 从单 DDR bank 扩展为双 DDR bank ping-pong window，使 host
通过 `XDMA H2C` 写入一个 DDR bank 时，FPGA replay reader 通常从另一个 DDR
bank 读取，从而降低动态换入时同一 DDR bank 上的读写竞争。

本轮目标是完成 RTL/host loader/BD 结构修改，并先做仿真和 Vivado BD validate。
完整 bitstream、上板吞吐和稳定性测试尚未完成。

## 修改内容

- `ddr_stream_reader.sv`
  - 新增 `cfg_stream_base1` 和 `cfg_pingpong_enable`。
  - `STREAM_CTRL[1]` 置位后启用 ping-pong。
  - `ring_size` 表示单 bank segment size，必须为 2 的幂且 64B 对齐。
  - 读地址生成规则：

```text
segment_offset = read_count & (ring_size - 1)
bank_select    = (read_count & ring_size) != 0
axi_araddr     = (bank_select ? bank1_base : bank0_base) + segment_offset
```

- `axi_lite_regs.sv` / `trace_replay_core.sv`
  - `STREAM_CTRL[0]` 保持 EOF。
  - `STREAM_CTRL[1]` 新增 `stream_pingpong_enable`。
  - `DESC_BASE` 在 `STREAM` 模式下作为 bank0 base。
  - `DATA_BASE` 在 `STREAM` 模式下复用为 bank1 base。

- `scripts/create_hw_project.tcl`
  - 新增 `TRAFFIC_REPLAY_PORT0_MULTI_DDR`。
  - 四 DDR bank 构建时，`port0 replay_core_0/M_AXI` 可接入 `host_smc/S01_AXI`，
    通过 SmartConnect 地址 decode 访问多个 DDR window。

- `software/xdma_stream_ring_fast.cpp`
  - 新增 `--pingpong`。
  - 新增 `--pingpong-bank1-base`，默认 `0x400000000`。
  - ping-pong 模式下 host 写入规则与 FPGA 读取规则一致。
  - loader 仍只在完整 stream record 写入完成后推进 `STREAM_WR_PTR`。

## 验证结果

### RTL Ring Reader Robustness Simulation

命令：

```bash
cd /tmp/tr_pingpong_work
vivado -mode batch -source scripts/run_stream_ring_reader_sim.tcl
```

结果：

```text
PASS: staged ring reader waits for writes and exits on EOF
PASS: ring reader wraps without issuing cross-boundary bursts
PASS: ping-pong ring reader alternates bank0/bank1 segments
PASS: ping-pong mode rejects non-power-of-two segment size
PASS: invalid ring size terminates with hardware-visible error
PASS: ring producer pointer regression terminates with hardware-visible error
PASS: ring overrun terminates with hardware-visible error
PASS: ddr_stream_reader ring-mode robustness simulation completed
```

### RTL Reader Performance Simulation

命令：

```bash
cd /tmp/tr_pingpong_work
vivado -mode batch -source scripts/run_stream_ring_reader_perf_sim.tcl
```

结果：

```text
PASS: stream reader perf simulation completed beats=512 ar_count=32 max_req_count=15 output_cycles=1318
```

说明：ping-pong 地址逻辑没有破坏 reader 原有多 outstanding read 行为。

### C++ Loader Build

命令：

```bash
cd /tmp/tr_pingpong_work/software
/usr/bin/g++-9 -O3 -std=c++17 -Wall -Wextra -pedantic -pthread \
  -o xdma_stream_ring_fast xdma_stream_ring_fast.cpp
```

结果：编译通过，`--help` 已显示 `--pingpong` 和 `--pingpong-bank1-base`。

### Four-DDR Single-Port BD Validate

命令：

```bash
cd /tmp/tr_pingpong_work
TRAFFIC_REPLAY_HW_BUILD_ROOT=/tmp/tr_pingpong_hwbd \
TRAFFIC_REPLAY_DDR_BANKS=4 \
TRAFFIC_REPLAY_PORT_COUNT=1 \
TRAFFIC_REPLAY_PORT0_MULTI_DDR=1 \
vivado -mode batch -source scripts/create_hw_project.tcl
```

结果：

```text
Traffic replay hardware port count: 1
Traffic replay DDR bank count: 4
Traffic replay port0 multi-DDR read access: 1
Hardware BD project created at /tmp/tr_pingpong_hwbd/vivado_hw
```

Vivado 报告了若干 SmartConnect 接 infrastructure IP 的 warning，这是当前工程已有的
AXI clock converter / register slice 结构导致的 warning，`validate_bd_design` 通过。

## 尚未完成

- 四 DDR ping-pong 版本完整 synthesis 未完成。本轮尝试运行 synthesis 时超过本地
  1 小时命令超时，远程 Vivado 被中断，没有得到 `synth_design Complete`。
- 尚未生成 ping-pong bitstream。
- 尚未上板测试 `--pingpong` 动态换入吞吐、鲁棒性和长期稳定性。

## 推荐测试命令

生成四 DDR/single-port ping-pong bitstream：

```bash
TRAFFIC_REPLAY_PORT_COUNT=1 \
TRAFFIC_REPLAY_DDR_BANKS=4 \
TRAFFIC_REPLAY_PORT0_MULTI_DDR=1 \
TRAFFIC_REPLAY_HW_BUILD_ROOT=$PWD/build_hw_1p_4ddr_pingpong \
vivado -mode batch -source scripts/build_hw_bitstream.tcl
```

上板后运行双 SSD striped ping-pong STREAM：

```bash
sudo ./software/xdma_stream_ring_fast \
  --port 0 \
  --stripe-manifest "$STREAM_DIR/stripe_manifest.json" \
  --pingpong \
  --ring-base 0x20000000 \
  --pingpong-bank1-base 0x400000000 \
  --ring-size 0x200000000 \
  --prefill-bytes 0x200000000 \
  --guard-bytes 0x04000000 \
  --batch-bytes 0x04000000 \
  --read-bytes 0x04000000 \
  --reader-threads 4 \
  --reader-window-blocks 16 \
  --queue-depth 16 \
  --writer-threads 2 \
  --host-cache-bytes auto \
  --timeout 300
```
