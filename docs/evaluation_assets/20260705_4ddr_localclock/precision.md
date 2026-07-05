# Replay Precision Suite

The tests replay generated PRELOAD traces through the optical loopback and compare RX-side SOP-to-SOP intervals with descriptor gaps.

| Case | Result | Packets | Pattern |
| --- | --- | ---: | --- |
| `uniform_128B_gap3000` | PASS | 1024 | `128B/3000tick` |
| `mixed_gap_128B` | PASS | 4096 | `128B/3000tick, 128B/300tick, 128B/1200tick, 128B/37tick, 128B/4800tick, 128B/96tick, 128B/15000tick, 128B/8tick` |
| `small_packet_small_gap` | PASS | 4096 | `64B/3tick, 64B/3tick, 64B/4tick, 64B/3tick, 64B/5tick, 64B/6tick, 64B/3tick, 64B/8tick` |
| `mixed_size_legal` | PASS | 4096 | `64B/80tick, 1518B/8tick, 256B/80tick, 512B/20tick, 128B/25tick, 1518B/12tick` |
| `long_uniform_128B_gap3000` | PASS | 200000 | `128B/3000tick` |

## uniform_128B_gap3000

```text
tx_port              : 0
rx_port              : 1
descriptor_file      : /tmp/traffic_replay_precision_suite/uniform_128B_gap3000/desc.bin
data_file            : /tmp/traffic_replay_precision_suite/uniform_128B_gap3000/data.bin
packet_count         : 1024
tx_tick_hz           : 300000000
rx_tick_hz           : 322265625
completed            : True
wall_seconds         : 0.015213
tx_packets           : 1024
drop_packets         : 0
late_packets         : 0
underrun_packets     : 0
rx_packets           : 1024
rx_bytes             : 131072
rx_errors            : 0
axi_errors           : 0
rx_gap_count         : 1023
rx_gap_min_cycles    : 3221
rx_gap_max_cycles    : 3225
rx_gap_last_cycles   : 3222
rx_gap_avg_cycles    : 3222.656891
rx_gap_sample_count  : 1023
rx_gap_sample_wr     : 1023
compared_samples     : 1023
first_desc_index     : 1
max_error_ns_allowed : 80.000000
min_error_ns         : -5.139394
max_error_ns         : 7.272727
avg_error_ns         : 0.001991
max_abs_error_ns     : 7.272727
error_over_limit     : 0
rx_tick              : 70169897
csv                  : /tmp/traffic_replay_precision_suite/uniform_128B_gap3000/rx_gap_samples.csv
PASS: RX packet intervals match descriptor trace gaps within tolerance
```

## mixed_gap_128B

```text
tx_port              : 0
rx_port              : 1
descriptor_file      : /tmp/traffic_replay_precision_suite/mixed_gap_128B/desc.bin
data_file            : /tmp/traffic_replay_precision_suite/mixed_gap_128B/data.bin
packet_count         : 4096
tx_tick_hz           : 300000000
rx_tick_hz           : 322265625
completed            : True
wall_seconds         : 0.045664
tx_packets           : 4096
drop_packets         : 0
late_packets         : 0
underrun_packets     : 0
rx_packets           : 4096
rx_bytes             : 524288
rx_errors            : 0
axi_errors           : 0
rx_gap_count         : 4095
rx_gap_min_cycles    : 6
rx_gap_max_cycles    : 16115
rx_gap_last_cycles   : 7
rx_gap_avg_cycles    : 3281.888400
rx_gap_sample_count  : 4095
rx_gap_sample_wr     : 4095
compared_samples     : 4095
first_desc_index     : 1
max_error_ns_allowed : 80.000000
min_error_ns         : -13.284848
max_error_ns         : 12.024242
avg_error_ns         : 0.004286
max_abs_error_ns     : 13.284848
error_over_limit     : 0
rx_tick              : 79981650
csv                  : /tmp/traffic_replay_precision_suite/mixed_gap_128B/rx_gap_samples.csv
PASS: RX packet intervals match descriptor trace gaps within tolerance
```

## small_packet_small_gap

```text
tx_port              : 0
rx_port              : 1
descriptor_file      : /tmp/traffic_replay_precision_suite/small_packet_small_gap/desc.bin
data_file            : /tmp/traffic_replay_precision_suite/small_packet_small_gap/data.bin
packet_count         : 4096
tx_tick_hz           : 300000000
rx_tick_hz           : 322265625
completed            : True
wall_seconds         : 0.005075
tx_packets           : 4096
drop_packets         : 0
late_packets         : 0
underrun_packets     : 0
rx_packets           : 4096
rx_bytes             : 262144
rx_errors            : 0
axi_errors           : 0
rx_gap_count         : 4095
rx_gap_min_cycles    : 2
rx_gap_max_cycles    : 11
rx_gap_last_cycles   : 7
rx_gap_avg_cycles    : 4.700122
rx_gap_sample_count  : 4095
rx_gap_sample_wr     : 4095
compared_samples     : 4095
first_desc_index     : 1
max_error_ns_allowed : 30.000000
min_error_ns         : -8.048485
max_error_ns         : 8.618182
avg_error_ns         : 0.000169
max_abs_error_ns     : 8.618182
error_over_limit     : 0
rx_tick              : 66903631
csv                  : /tmp/traffic_replay_precision_suite/small_packet_small_gap/rx_gap_samples.csv
PASS: RX packet intervals match descriptor trace gaps within tolerance
```

## mixed_size_legal

```text
tx_port              : 0
rx_port              : 1
descriptor_file      : /tmp/traffic_replay_precision_suite/mixed_size_legal/desc.bin
data_file            : /tmp/traffic_replay_precision_suite/mixed_size_legal/data.bin
packet_count         : 4096
tx_tick_hz           : 300000000
rx_tick_hz           : 322265625
completed            : True
wall_seconds         : 0.005074
tx_packets           : 4096
drop_packets         : 0
late_packets         : 0
underrun_packets     : 0
rx_packets           : 4096
rx_bytes             : 2727622
rx_errors            : 0
axi_errors           : 0
rx_gap_count         : 4095
rx_gap_min_cycles    : 18
rx_gap_max_cycles    : 66
rx_gap_last_cycles   : 27
rx_gap_avg_cycles    : 40.284005
rx_gap_sample_count  : 4095
rx_gap_sample_wr     : 4095
compared_samples     : 4095
first_desc_index     : 1
max_error_ns_allowed : 120.000000
min_error_ns         : -80.484848
max_error_ns         : 85.042424
avg_error_ns         : 0.006151
max_abs_error_ns     : 85.042424
error_over_limit     : 0
rx_tick              : 66902251
csv                  : /tmp/traffic_replay_precision_suite/mixed_size_legal/rx_gap_samples.csv
PASS: RX packet intervals match descriptor trace gaps within tolerance
```

## long_uniform_128B_gap3000

```text
tx_port              : 0
rx_port              : 1
descriptor_file      : /tmp/traffic_replay_precision_suite/long_uniform_128B_gap3000/desc.bin
data_file            : /tmp/traffic_replay_precision_suite/long_uniform_128B_gap3000/data.bin
packet_count         : 200000
tx_tick_hz           : 300000000
rx_tick_hz           : 322265625
completed            : True
wall_seconds         : 2.002807
tx_packets           : 200000
drop_packets         : 0
late_packets         : 0
underrun_packets     : 0
rx_packets           : 200000
rx_bytes             : 25600000
rx_errors            : 0
axi_errors           : 0
rx_gap_count         : 199999
rx_gap_min_cycles    : 3218
rx_gap_max_cycles    : 3227
rx_gap_last_cycles   : 3223
rx_gap_avg_cycles    : 3222.657703
rx_gap_sample_count  : 4096
rx_gap_sample_wr     : 3391
compared_samples     : 4096
first_desc_index     : 195904
max_error_ns_allowed : 80.000000
min_error_ns         : -5.139394
max_error_ns         : 10.375758
avg_error_ns         : 0.004545
max_abs_error_ns     : 10.375758
error_over_limit     : 0
rx_tick              : 710708755
csv                  : /tmp/traffic_replay_precision_suite/long_uniform_128B_gap3000/rx_gap_samples.csv
PASS: RX packet intervals match descriptor trace gaps within tolerance
```
