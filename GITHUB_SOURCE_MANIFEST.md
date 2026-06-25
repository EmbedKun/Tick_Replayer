# GitHub Source Manifest

这个文件说明本工程上传到 GitHub 时应保留的“源码化 Vivado 工程”内容。原则是：仓库保存可复现工程的源码、约束、脚本、仿真、软件和文档；不保存 Vivado 生成物、bitstream、日志、远程主机密码或临时 trace 数据。

## 应上传的文件

根目录：

```text
.gitattributes
.gitignore
README.md
GITHUB_SOURCE_MANIFEST.md
```

RTL：

```text
rtl/traffic_replay_pkg.sv
rtl/trace_replay_core.sv
rtl/axi_lite_regs.sv
rtl/ddr_trace_reader.sv
rtl/replay_scheduler.sv
rtl/replay_tx_engine.sv
rtl/host_stream_parser.sv
rtl/axis_async_fifo.v
rtl/traffic_replay_bd_core.v
rtl/traffic_replay_top_stub.sv
```

约束：

```text
constraints/traffic_replay_u200.xdc
constraints/traffic_replay_stub.xdc
```

Vivado 脚本：

```text
scripts/run_vivado.ps1
scripts/create_hw_project.tcl
scripts/build_existing_hw_bitstream.tcl
scripts/build_hw_bitstream.tcl
scripts/rerun_hw_impl.tcl
scripts/create_project.tcl
scripts/run_sim.tcl
scripts/synth_check.tcl
scripts/program_remote.tcl
scripts/capture_cmac_ila.tcl
scripts/query_xdma_props.tcl
```

仿真：

```text
sim/tb_trace_replay_core.sv
```

Host 软件：

```text
software/pcap2trace.py
software/xdma_load_trace.py
software/traffic_replay_cli.py
```

文档：

```text
docs/architecture.md
```

## 不应上传的内容

```text
.Xil/
build/
reports/
artifacts/
trace_out/
traffic_replay.cache/
traffic_replay.hw/
traffic_replay.ip_user_files/
traffic_replay.sim/
*.xpr
*.runs/
*.gen/
*.jou
*.log
*.wdb
*.bit
*.ltx
__pycache__/
*.pyc
```

说明：

- Vivado GUI 工程由 `scripts/create_hw_project.tcl` 从源码重建，不需要提交 `.xpr` 和 `.bd` 生成物。
- bitstream 和 `.ltx` 属于构建产物，不进 GitHub。需要交付二进制时放到 GitHub Release 或单独归档。
- 远程主机 IP 可以记录在 README 作为实验环境信息，但不要提交密码、私钥、license 文件。

## 一键导出

在仓库根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\export_github_sources.ps1 -Zip
```

脚本会生成：

```text
artifacts/github_source/traffic_replay/
artifacts/traffic_replay_github_source.zip
```

这个导出目录/zip 是上传 GitHub 前的源码快照检查用；真正推荐的 GitHub 方式仍然是直接推送当前 Git 仓库。
