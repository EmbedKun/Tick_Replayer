# Optional QSFP1 4x25G lane and 161.1328125 MHz MGT reference-clock
# constraints for the dual-port Alveo U200 build.

set_property LOC U4 [get_ports -quiet {qsfp1_4x_grx_p[0]}]
set_property LOC U3 [get_ports -quiet {qsfp1_4x_grx_n[0]}]
set_property LOC U9 [get_ports -quiet {qsfp1_4x_gtx_p[0]}]
set_property LOC U8 [get_ports -quiet {qsfp1_4x_gtx_n[0]}]
set_property LOC T2 [get_ports -quiet {qsfp1_4x_grx_p[1]}]
set_property LOC T1 [get_ports -quiet {qsfp1_4x_grx_n[1]}]
set_property LOC T7 [get_ports -quiet {qsfp1_4x_gtx_p[1]}]
set_property LOC T6 [get_ports -quiet {qsfp1_4x_gtx_n[1]}]
set_property LOC R4 [get_ports -quiet {qsfp1_4x_grx_p[2]}]
set_property LOC R3 [get_ports -quiet {qsfp1_4x_grx_n[2]}]
set_property LOC R9 [get_ports -quiet {qsfp1_4x_gtx_p[2]}]
set_property LOC R8 [get_ports -quiet {qsfp1_4x_gtx_n[2]}]
set_property LOC P2 [get_ports -quiet {qsfp1_4x_grx_p[3]}]
set_property LOC P1 [get_ports -quiet {qsfp1_4x_grx_n[3]}]
set_property LOC P7 [get_ports -quiet {qsfp1_4x_gtx_p[3]}]
set_property LOC P6 [get_ports -quiet {qsfp1_4x_gtx_n[3]}]

set_property LOC P11 [get_ports -quiet qsfp1_161mhz_clk_p]
set_property LOC P10 [get_ports -quiet qsfp1_161mhz_clk_n]
