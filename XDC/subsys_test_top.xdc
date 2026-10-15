##setting
set_property BITSTREAM.CONFIG.CONFIGRATE 36.4 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

##clock
set_property PACKAGE_PIN G18 [get_ports sys_clk]
create_clock -period 10.000 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS18 [get_ports sys_clk]

##ethernet a
set_property PACKAGE_PIN AN41 [get_ports gt_ref_clk_n_a]
set_property PACKAGE_PIN AN40 [get_ports gt_ref_clk_p_a]

set_property PACKAGE_PIN AU53 [get_ports {gt_rxp_in_a[0]}]
set_property PACKAGE_PIN AU54 [get_ports {gt_rxn_in_a[0]}]
set_property PACKAGE_PIN AU48 [get_ports {gt_txp_out_a[0]}]
set_property PACKAGE_PIN AU49 [get_ports {gt_txn_out_a[0]}]

set_property PACKAGE_PIN AT51 [get_ports {gt_rxp_in_a[1]}]
set_property PACKAGE_PIN AT52 [get_ports {gt_rxn_in_a[1]}]
set_property PACKAGE_PIN AT46 [get_ports {gt_txp_out_a[1]}]
set_property PACKAGE_PIN AT47 [get_ports {gt_txn_out_a[1]}]

set_property PACKAGE_PIN AR53 [get_ports {gt_rxp_in_a[2]}]
set_property PACKAGE_PIN AR54 [get_ports {gt_rxn_in_a[2]}]
set_property PACKAGE_PIN AR48 [get_ports {gt_txp_out_a[2]}]
set_property PACKAGE_PIN AR49 [get_ports {gt_txn_out_a[2]}]

set_property PACKAGE_PIN AP51 [get_ports {gt_rxp_in_a[3]}]
set_property PACKAGE_PIN AP52 [get_ports {gt_rxn_in_a[3]}]
set_property PACKAGE_PIN AR44 [get_ports {gt_txp_out_a[3]}]
set_property PACKAGE_PIN AR45 [get_ports {gt_txn_out_a[3]}]

set_property PACKAGE_PIN BF21 [get_ports qsfp_rstn_port_a]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp_rstn_port_a]
set_property PACKAGE_PIN BG22 [get_ports qsfp_lp_mode_port_a]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp_lp_mode_port_a]
set_property PACKAGE_PIN BG23 [get_ports qsfp_seln_port_a]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp_seln_port_a]
set_property PACKAGE_PIN BH22 [get_ports qsfp_prsn_port_a]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp_prsn_port_a]
set_property PACKAGE_PIN D19 [get_ports qsfp_led_port_a]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp_led_port_a]

#ethernet b
set_property PACKAGE_PIN AD43 [get_ports gt_ref_clk_n_b]
set_property PACKAGE_PIN AD42 [get_ports gt_ref_clk_p_b]

set_property PACKAGE_PIN AD51 [get_ports {gt_rxp_in_b[0]}]
set_property PACKAGE_PIN AD52 [get_ports {gt_rxn_in_b[0]}]
set_property PACKAGE_PIN AD46 [get_ports {gt_txp_out_b[0]}]
set_property PACKAGE_PIN AD47 [get_ports {gt_txn_out_b[0]}]

set_property PACKAGE_PIN AC53 [get_ports {gt_rxp_in_b[1]}]
set_property PACKAGE_PIN AC54 [get_ports {gt_rxn_in_b[1]}]
set_property PACKAGE_PIN AC44 [get_ports {gt_txp_out_b[1]}]
set_property PACKAGE_PIN AC45 [get_ports {gt_txn_out_b[1]}]

set_property PACKAGE_PIN AC49 [get_ports {gt_rxp_in_b[2]}]
set_property PACKAGE_PIN AC50 [get_ports {gt_rxn_in_b[2]}]
set_property PACKAGE_PIN AB46 [get_ports {gt_txp_out_b[2]}]
set_property PACKAGE_PIN AB47 [get_ports {gt_txn_out_b[2]}]

set_property PACKAGE_PIN AB51 [get_ports {gt_rxp_in_b[3]}]
set_property PACKAGE_PIN AB52 [get_ports {gt_rxn_in_b[3]}]
set_property PACKAGE_PIN AA48 [get_ports {gt_txp_out_b[3]}]
set_property PACKAGE_PIN AA49 [get_ports {gt_txn_out_b[3]}]


set_property PACKAGE_PIN BJ22 [get_ports qsfp_rstn_port_b]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp_rstn_port_b]
set_property PACKAGE_PIN BL22 [get_ports qsfp_lp_mode_port_b]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp_lp_mode_port_b]
set_property PACKAGE_PIN BK21 [get_ports qsfp_seln_port_b]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp_seln_port_b]
set_property PACKAGE_PIN BK24 [get_ports qsfp_prsn_port_b]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp_prsn_port_b]
set_property PACKAGE_PIN D20 [get_ports qsfp_led_port_b]
set_property IOSTANDARD LVCMOS18 [get_ports qsfp_led_port_b]

# ==================== PB_BEGIN (自动生成段, 勿手改) ====================
# 由 Centenarian.user/TCL/gen_subsys_pblocks.py 生成
# 加网口: 改脚本里 ETH_PORT_NUM + PORT_SLR_CFG, 重新运行本脚本即可
#
# DUT 层次 : u_dut/gen_port[i].u_eth_top/...
# SLR 归属 : CMAC_A=SLR0, CMAC_B=SLR2, 400M 用户域=SLR1
# RX : CMAC(SLR_cmac) -> u_slr_x_rx -> u_fifo_rx(SLR_user) -> 400M 下游
# TX : 400M 上游 -> u_fifo_tx(SLR_user) -> u_slr_x_tx -> CMAC(SLR_cmac)
#
# ==============================================================================

# ---- 网口 0 (a) : u_dut/gen_port[0].u_eth_top ----
create_pblock pb_rxa_src
add_cells_to_pblock [get_pblocks pb_rxa_src] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_top*u_slr_x_rx*slr_source*}]
resize_pblock [get_pblocks pb_rxa_src] -add {SLR0:SLR0}

create_pblock pb_rxa_dst
add_cells_to_pblock [get_pblocks pb_rxa_dst] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_top*u_slr_x_rx*slr_dest*}]
resize_pblock [get_pblocks pb_rxa_dst] -add {SLR1:SLR1}

create_pblock pb_txa_src
add_cells_to_pblock [get_pblocks pb_txa_src] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_top*u_slr_x_tx*slr_source*}]
resize_pblock [get_pblocks pb_txa_src] -add {SLR1:SLR1}

create_pblock pb_txa_dst
add_cells_to_pblock [get_pblocks pb_txa_dst] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_top*u_slr_x_tx*slr_dest*}]
resize_pblock [get_pblocks pb_txa_dst] -add {SLR0:SLR0}

create_pblock pb_fifo_rx_a
add_cells_to_pblock [get_pblocks pb_fifo_rx_a] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_top*u_fifo_rx*}]
resize_pblock [get_pblocks pb_fifo_rx_a] -add {SLR1:SLR1}

create_pblock pb_fifo_tx_a
add_cells_to_pblock [get_pblocks pb_fifo_tx_a] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_top*u_fifo_tx*}]
resize_pblock [get_pblocks pb_fifo_tx_a] -add {SLR1:SLR1}

# ---- 网口 1 (b) : u_dut/gen_port[1].u_eth_top ----
create_pblock pb_rxb_src
add_cells_to_pblock [get_pblocks pb_rxb_src] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_top*u_slr_x_rx*slr_source*}]
resize_pblock [get_pblocks pb_rxb_src] -add {SLR2:SLR2}

create_pblock pb_rxb_dst
add_cells_to_pblock [get_pblocks pb_rxb_dst] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_top*u_slr_x_rx*slr_dest*}]
resize_pblock [get_pblocks pb_rxb_dst] -add {SLR1:SLR1}

create_pblock pb_txb_src
add_cells_to_pblock [get_pblocks pb_txb_src] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_top*u_slr_x_tx*slr_source*}]
resize_pblock [get_pblocks pb_txb_src] -add {SLR1:SLR1}

create_pblock pb_txb_dst
add_cells_to_pblock [get_pblocks pb_txb_dst] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_top*u_slr_x_tx*slr_dest*}]
resize_pblock [get_pblocks pb_txb_dst] -add {SLR2:SLR2}

create_pblock pb_fifo_rx_b
add_cells_to_pblock [get_pblocks pb_fifo_rx_b] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_top*u_fifo_rx*}]
resize_pblock [get_pblocks pb_fifo_rx_b] -add {SLR1:SLR1}

create_pblock pb_fifo_tx_b
add_cells_to_pblock [get_pblocks pb_fifo_tx_b] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_top*u_fifo_tx*}]
resize_pblock [get_pblocks pb_fifo_tx_b] -add {SLR1:SLR1}

# ===================== PB_END =====================

# ------------------------------------------------------------------------------
# 跨时钟域复位信号
# ------------------------------------------------------------------------------
set_false_path -to [get_pins -filter {IS_PRESET == 1 || IS_RESET == 1} -of [get_cells -filter {NAME =~ *rst_sync_reg*}]]
