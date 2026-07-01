# Timing floorplan for the U200 dual-port CMAC build.
#
# Keep the CMAC-facing TX logic close to the QSFP/CMAC clock regions.  This
# mirrors the placement style used by the AU200 100G Corundum design and keeps
# the 322 MHz LBUS ready path short enough for dual-port builds.

create_pblock pblock_tr_cmac_tx_qsfp
resize_pblock [get_pblocks pblock_tr_cmac_tx_qsfp] -add {CLOCKREGION_X0Y10:CLOCKREGION_X0Y14}
add_cells_to_pblock [get_pblocks pblock_tr_cmac_tx_qsfp] [get_cells -hier -quiet *tx_lbus_*]
