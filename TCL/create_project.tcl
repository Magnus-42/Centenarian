# ============================================================================
# File Name   : create_project.tcl
# Description : 在已打开的 Vivado 工程中, 逐个导入 RTL / 仿真 / 约束文件
# Author      : LiXintao
# Date        : 2026-08-15
# Version     : v2.0
# ----------------------------------------------------------------------------
# 用法:
#   1) 先打开 (或新建) 目标 Vivado 工程
#   2) 在 Tcl Console 中执行 (路径用正斜杠 /):
#        source <本脚本完整路径>/create_project.tcl
# ----------------------------------------------------------------------------
# 说明:
#   - 不创建工程, 只向 [current_project] 添加文件
#   - 相对路径基准 = 本脚本上一级目录, 即 RTL/ TB/ XDC/ 所在目录
#   - 每个文件单独一行 add_files, 便于自行增删或修改路径
#   - RTL 加入 sources_1 (设计源), TB 加入 sim_1 (仅仿真), XDC 加入 constrs_1
# ============================================================================

# ----------------------------------------------------------------------------
# 相对路径基准: 切换到脚本上一级目录 (xhs_user)
# ----------------------------------------------------------------------------
set base_dir [file normalize "[file dirname [info script]]/.."]
cd $base_dir

# ============================================================================
# 1. 设计源 (RTL)  —— 默认加入 sources_1
# ============================================================================
add_files RTL/Top/cmac_test_top.v
add_files RTL/Top/ipv4_test_top.v
add_files RTL/Top/subsys_test_top.v

# --- Algorithm ---
add_files RTL/Algorithm/arbiter.v
add_files RTL/Algorithm/lfsr.v
add_files RTL/Algorithm/priority_encoder.v
add_files RTL/Algorithm/crc_32.v

# --- Bsp/Axis ---
add_files RTL/Bsp/Axis/axis_nto1.v

# --- Bsp/skid ---
add_files RTL/Bsp/Skid/axis_skid_buffer.v
add_files RTL/Bsp/Skid/skid_buffer.v


# --- Bsp/Fifo ---
add_files RTL/Bsp/Fifo/axis_fifo_async.v
add_files RTL/Bsp/Fifo/axis_fifo_sync.v
add_files RTL/Bsp/Fifo/fifo_sync.v

# --- Net/Arp ---
add_files RTL/Eth/Arp/arp_eth_rx.v
add_files RTL/Eth/Arp/arp_eth_tx.v
add_files RTL/Eth/Arp/arp_engine_top.v
add_files RTL/Eth/Arp/arp_cache.v
add_files RTL/Eth/Arp/arp_cache_top.v
add_files RTL/Eth/Arp/arp_lookup.v
add_files RTL/Eth/Arp/arp_write.v
add_files RTL/Eth/Arp/arp_pending_ctrl.v

# --- Bsp/Bram ---
add_files RTL/Bsp/Bram/sdp_bram.v
add_files RTL/Bsp/Bram/sp_bram.v
add_files RTL/Bsp/Bram/tdp_bram.v

# --- Eth/MAC (L1 端口 + L2 以太网层) ---
add_files RTL/Eth/MAC/eth_top.v
add_files RTL/Eth/MAC/eth_tx_mux.v
add_files RTL/Eth/MAC/eth_frame_pad60.v
add_files RTL/Eth/MAC/eth_type_demux.v
add_files RTL/Eth/MAC/cmac_a_if.v
add_files RTL/Eth/MAC/cmac_b_if.v

add_files RTL/Eth/Ipv4/ipv4_eth_rx.v
add_files RTL/Eth/Ipv4/ipv4_eth_tx.v
add_files RTL/Eth/Ipv4/ipv4_arp_service.v
add_files RTL/Eth/Ipv4/ipv4_mac_add.v
add_files RTL/Eth/Ipv4/ipv4_top.v
add_files RTL/Eth/Ipv4/ipv4_tx_mux.v
add_files RTL/Eth/Ipv4/ipv4_type_demux.v


# --- Eth/Udp (L4 UDP 层) ---
add_files RTL/Eth/Udp/udp_ipv4_rx.v
add_files RTL/Eth/Udp/udp_ipv4_tx.v
add_files RTL/Eth/Udp/udp_ipv4_header_add.v
add_files RTL/Eth/Udp/udp_type_demux.v
add_files RTL/Eth/Udp/udp_top.v

# --- Eth 子系统顶层 ---
add_files RTL/Eth/eth_subsys_top.v

# --- Test ---
add_files RTL/Test/eth_100g_tester.v
add_files RTL/Test/ipv4_100g_tester.v
add_files RTL/Test/subsys_100g_tester.v

# ============================================================================
# 2. 仿真源 (TB)  —— 加入 sim_1, 不进综合/实现
# ============================================================================
add_files -fileset sim_1 TB/Bsp/Fifo/tb_axis_fifo_async.v
add_files -fileset sim_1 TB/Eth/Arp/tb_arp_eth_top.v

# ============================================================================
# 3. 约束 (XDC)  —— 加入 constrs_1
# ============================================================================
# 当前顶层 = subsys_test_top, 只加载对应 XDC（切回 ipv4_test_top 时交换下面两行）
add_files -fileset constrs_1 XDC/subsys_test_top.xdc
#add_files -fileset constrs_1 XDC/ipv4_test_top.xdc
add_files -fileset constrs_1 XDC/axis_fifo_async.tcl

# ============================================================================
# 4. 顶层设置 (按需修改)
# ============================================================================
set top_module "subsys_test_top"              ;# 综合/实现顶层
set sim_top    "tb_arp_eth_top"    ;# 仿真顶层 (8 个 tb 任选一个)

set_property top $top_module [get_filesets sources_1]
set_property top $sim_top    [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "导入完成: RTL/TB/XDC 已加入当前工程"
