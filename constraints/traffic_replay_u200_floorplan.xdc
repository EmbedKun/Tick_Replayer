# Timing floorplan for the U200 dual-port CMAC build.
#
# Keep the CMAC-facing TX logic in the top SLR with CMACE4_X0Y6/X0Y7.  Including
# CLOCKREGION_X0Y10 allowed the ready-to-BRAM-enable path to leave the CMAC SLR
# and return to it, adding two SLR crossings on a 322 MHz path.

create_pblock pblock_tr_cmac_tx_qsfp
resize_pblock [get_pblocks pblock_tr_cmac_tx_qsfp] -add {CLOCKREGION_X0Y11:CLOCKREGION_X0Y14}
add_cells_to_pblock [get_pblocks pblock_tr_cmac_tx_qsfp] [get_cells -hier -quiet *tx_lbus_*]
