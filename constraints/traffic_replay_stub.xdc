# Stub-level timing constraint for the CMAC TX user clock domain.
# 100G CMAC with a 512-bit user datapath commonly uses 322.265625 MHz.
create_clock -name replay_clk -period 3.103 [get_ports clk]

set_false_path -from [get_ports rstn]
