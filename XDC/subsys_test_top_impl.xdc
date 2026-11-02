# 实现阶段XDC，仅在实现阶段使用

# ---- 网口 0 (a) : u_dut/gen_port[0].u_eth_port_top ----
create_pblock pb_rxa_src
add_cells_to_pblock [get_pblocks pb_rxa_src] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_port_top*u_slr_x_rx*slr_source*}]
resize_pblock [get_pblocks pb_rxa_src] -add {SLR0:SLR0}

create_pblock pb_rxa_dst
add_cells_to_pblock [get_pblocks pb_rxa_dst] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_port_top*u_slr_x_rx*slr_dest*}]
resize_pblock [get_pblocks pb_rxa_dst] -add {SLR1:SLR1}

create_pblock pb_txa_src
add_cells_to_pblock [get_pblocks pb_txa_src] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_port_top*u_slr_x_tx*slr_source*}]
resize_pblock [get_pblocks pb_txa_src] -add {SLR1:SLR1}

create_pblock pb_txa_dst
add_cells_to_pblock [get_pblocks pb_txa_dst] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_port_top*u_slr_x_tx*slr_dest*}]
resize_pblock [get_pblocks pb_txa_dst] -add {SLR0:SLR0}

create_pblock pb_fifo_rx_a
add_cells_to_pblock [get_pblocks pb_fifo_rx_a] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_port_top*u_fifo_rx*}]
resize_pblock [get_pblocks pb_fifo_rx_a] -add {SLR1:SLR1}

create_pblock pb_fifo_tx_a
add_cells_to_pblock [get_pblocks pb_fifo_tx_a] [get_cells -hierarchical -filter {NAME =~ *gen_port?0?.u_eth_port_top*u_fifo_tx*}]
resize_pblock [get_pblocks pb_fifo_tx_a] -add {SLR1:SLR1}

# ---- 网口 1 (b) : u_dut/gen_port[1].u_eth_port_top ----
create_pblock pb_rxb_src
add_cells_to_pblock [get_pblocks pb_rxb_src] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_port_top*u_slr_x_rx*slr_source*}]
resize_pblock [get_pblocks pb_rxb_src] -add {SLR2:SLR2}

create_pblock pb_rxb_dst
add_cells_to_pblock [get_pblocks pb_rxb_dst] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_port_top*u_slr_x_rx*slr_dest*}]
resize_pblock [get_pblocks pb_rxb_dst] -add {SLR1:SLR1}

create_pblock pb_txb_src
add_cells_to_pblock [get_pblocks pb_txb_src] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_port_top*u_slr_x_tx*slr_source*}]
resize_pblock [get_pblocks pb_txb_src] -add {SLR1:SLR1}

create_pblock pb_txb_dst
add_cells_to_pblock [get_pblocks pb_txb_dst] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_port_top*u_slr_x_tx*slr_dest*}]
resize_pblock [get_pblocks pb_txb_dst] -add {SLR2:SLR2}

create_pblock pb_fifo_rx_b
add_cells_to_pblock [get_pblocks pb_fifo_rx_b] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_port_top*u_fifo_rx*}]
resize_pblock [get_pblocks pb_fifo_rx_b] -add {SLR1:SLR1}

create_pblock pb_fifo_tx_b
add_cells_to_pblock [get_pblocks pb_fifo_tx_b] [get_cells -hierarchical -filter {NAME =~ *gen_port?1?.u_eth_port_top*u_fifo_tx*}]
resize_pblock [get_pblocks pb_fifo_tx_b] -add {SLR1:SLR1}

# 设置伪路径
set_false_path -to [get_pins {{rst_sync_reg[0]/PRE} {rst_sync_reg[1]/PRE}}]

# 设置时钟组
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sys_clk] -group [get_clocks -include_generated_clocks gt_ref_clk_p_a] -group [get_clocks -include_generated_clocks gt_ref_clk_p_b]
