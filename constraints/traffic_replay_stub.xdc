# Stub-level timing constraint for the replay core clock domain.
# In the U200 block design the replay/capture cores run on the DDR4 UI clock.
create_clock -name replay_clk -period 3.333 [get_ports clk]

set_false_path -from [get_ports rstn]
