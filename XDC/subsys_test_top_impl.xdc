# -----------------------------------------------------------------------------
# subsys_test_top实现约束：仅用于实现阶段，PROCESSING_ORDER=LATE。
# -----------------------------------------------------------------------------

# A口SLR跨区与FIFO
create_pblock pb_rxa_src
add_cells_to_pblock [get_pblocks pb_rxa_src] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_a_inst/eth_stack_port_inst/eth_port_top_inst/axis_slr_crossing_rx/*slr_source*}]
resize_pblock [get_pblocks pb_rxa_src] -add {SLR0:SLR0}

create_pblock pb_rxa_dst
add_cells_to_pblock [get_pblocks pb_rxa_dst] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_a_inst/eth_stack_port_inst/eth_port_top_inst/axis_slr_crossing_rx/*slr_dest*}]
resize_pblock [get_pblocks pb_rxa_dst] -add {SLR1:SLR1}

create_pblock pb_txa_src
add_cells_to_pblock [get_pblocks pb_txa_src] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_a_inst/eth_stack_port_inst/eth_port_top_inst/axis_slr_crossing_tx/*slr_source*}]
resize_pblock [get_pblocks pb_txa_src] -add {SLR1:SLR1}

create_pblock pb_txa_dst
add_cells_to_pblock [get_pblocks pb_txa_dst] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_a_inst/eth_stack_port_inst/eth_port_top_inst/axis_slr_crossing_tx/*slr_dest*}]
resize_pblock [get_pblocks pb_txa_dst] -add {SLR0:SLR0}

create_pblock pb_fifo_rx_a
add_cells_to_pblock [get_pblocks pb_fifo_rx_a] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_a_inst/eth_stack_port_inst/eth_port_top_inst/axis_fifo_async_rx/*}]
resize_pblock [get_pblocks pb_fifo_rx_a] -add {SLR1:SLR1}

create_pblock pb_fifo_tx_a
add_cells_to_pblock [get_pblocks pb_fifo_tx_a] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_a_inst/eth_stack_port_inst/eth_port_top_inst/axis_fifo_async_tx/*}]
resize_pblock [get_pblocks pb_fifo_tx_a] -add {SLR1:SLR1}


# B口SLR跨区与FIFO
create_pblock pb_rxb_src
add_cells_to_pblock [get_pblocks pb_rxb_src] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_b_inst/eth_stack_port_inst/eth_port_top_inst/axis_slr_crossing_rx/*slr_source*}]
resize_pblock [get_pblocks pb_rxb_src] -add {SLR2:SLR2}

create_pblock pb_rxb_dst
add_cells_to_pblock [get_pblocks pb_rxb_dst] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_b_inst/eth_stack_port_inst/eth_port_top_inst/axis_slr_crossing_rx/*slr_dest*}]
resize_pblock [get_pblocks pb_rxb_dst] -add {SLR1:SLR1}

create_pblock pb_txb_src
add_cells_to_pblock [get_pblocks pb_txb_src] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_b_inst/eth_stack_port_inst/eth_port_top_inst/axis_slr_crossing_tx/*slr_source*}]
resize_pblock [get_pblocks pb_txb_src] -add {SLR1:SLR1}

create_pblock pb_txb_dst
add_cells_to_pblock [get_pblocks pb_txb_dst] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_b_inst/eth_stack_port_inst/eth_port_top_inst/axis_slr_crossing_tx/*slr_dest*}]
resize_pblock [get_pblocks pb_txb_dst] -add {SLR2:SLR2}

create_pblock pb_fifo_rx_b
add_cells_to_pblock [get_pblocks pb_fifo_rx_b] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_b_inst/eth_stack_port_inst/eth_port_top_inst/axis_fifo_async_rx/*}]
resize_pblock [get_pblocks pb_fifo_rx_b] -add {SLR1:SLR1}

create_pblock pb_fifo_tx_b
add_cells_to_pblock [get_pblocks pb_fifo_tx_b] [get_cells -hierarchical -filter {NAME =~ u_eth_stack_top/eth_stack_port_b_inst/eth_stack_port_inst/eth_port_top_inst/axis_fifo_async_tx/*}]
resize_pblock [get_pblocks pb_fifo_tx_b] -add {SLR1:SLR1}

# 顶层异步置位、同步释放：只豁免同步器自身PRE脚。
set_false_path -to [get_pins {{rst_sync_reg[0]/PRE} {rst_sync_reg[1]/PRE}}]

# 链路状态从gt_rxusrclk域进入业务clk域：仅豁免第一级D，第二级继续计时。
set_false_path -to [get_pins {u_eth_stack_top/eth_stack_port_a_inst/eth_stack_port_inst/link_up_d1_reg/D}]
set_false_path -to [get_pins {u_eth_stack_top/eth_stack_port_b_inst/eth_stack_port_inst/link_up_d1_reg/D}]

# A口模块在位信号分别进入init_clk和gt_rxusrclk域，只豁免各第一级D。
set_false_path -from [get_ports qsfp_prsn_port_a] -to [get_pins {u_eth_stack_top/eth_stack_port_a_inst/eth_stack_port_inst/eth_port_top_inst/gen_cmac_a.cmac_a_if_inst/init_qsfp_present_sync_reg[0]/D}]
set_false_path -from [get_ports qsfp_prsn_port_a] -to [get_pins {u_eth_stack_top/eth_stack_port_a_inst/eth_stack_port_inst/eth_port_top_inst/gen_cmac_a.cmac_a_if_inst/gt_rx_qsfp_present_sync_reg[0]/D}]
# gt_rx域在位同步链的原始异步复位，仅豁免同步器CLR脚。
set_false_path -to [get_pins {{u_eth_stack_top/eth_stack_port_a_inst/eth_stack_port_inst/eth_port_top_inst/gen_cmac_a.cmac_a_if_inst/gt_rx_qsfp_present_sync_reg[0]/CLR} {u_eth_stack_top/eth_stack_port_a_inst/eth_stack_port_inst/eth_port_top_inst/gen_cmac_a.cmac_a_if_inst/gt_rx_qsfp_present_sync_reg[1]/CLR}}]

# B口模块在位信号分别进入init_clk和gt_rxusrclk域，只豁免各第一级D。
set_false_path -from [get_ports qsfp_prsn_port_b] -to [get_pins {u_eth_stack_top/eth_stack_port_b_inst/eth_stack_port_inst/eth_port_top_inst/gen_cmac_b.cmac_b_if_inst/init_qsfp_present_sync_reg[0]/D}]
set_false_path -from [get_ports qsfp_prsn_port_b] -to [get_pins {u_eth_stack_top/eth_stack_port_b_inst/eth_stack_port_inst/eth_port_top_inst/gen_cmac_b.cmac_b_if_inst/gt_rx_qsfp_present_sync_reg[0]/D}]
# gt_rx域在位同步链的原始异步复位，仅豁免同步器CLR脚。
set_false_path -to [get_pins {{u_eth_stack_top/eth_stack_port_b_inst/eth_stack_port_inst/eth_port_top_inst/gen_cmac_b.cmac_b_if_inst/gt_rx_qsfp_present_sync_reg[0]/CLR} {u_eth_stack_top/eth_stack_port_b_inst/eth_stack_port_inst/eth_port_top_inst/gen_cmac_b.cmac_b_if_inst/gt_rx_qsfp_present_sync_reg[1]/CLR}}]
