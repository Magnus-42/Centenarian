`resetall
`default_nettype none
`timescale 1ns / 1ps

//****************************************Copyright (c)***********************************//
// Created by:             LiXintao
// Created date:           2026/09/13 17:12:07
// mail      :             1454396890@qq.com
// Version:                V1.0
// TEXT NAME:              cmac_a_if.v
// PATH:                   D:\Prj\Centenarian\Centenarian.user\RTL\Eth\Mac\cmac_a_if.v
// Descriptions:           
//                         
//****************************************************************************************//

module cmac_a_if(
  input  wire                                          init_clk        ,
  input  wire                                          sys_reset       ,

  output wire          [                   3: 0]       gt_txp_out      ,
  output wire          [                   3: 0]       gt_txn_out      ,
  input  wire          [                   3: 0]       gt_rxp_in       ,
  input  wire          [                   3: 0]       gt_rxn_in       ,

  input  wire                                          gt_ref_clk_p    ,
  input  wire                                          gt_ref_clk_n    ,
  output wire                                          gt_txusrclk     ,
  output wire                                          gt_rxusrclk     ,


  output wire                                          axis_mvalid     ,
  output wire          [                 511: 0]       axis_mdata      ,
  output wire                                          axis_mlast      ,
  output wire          [                  63: 0]       axis_mkeep      ,
  output wire                                          axis_musr       ,

  input  wire                                          axis_svalid     ,
  input  wire          [                 511: 0]       axis_sdata      ,
  input  wire                                          axis_slast      ,
  input  wire          [                  63: 0]       axis_skeep      ,
  input  wire                                          axis_susr       ,
  output wire                                          axis_sready     ,

  output wire                                          usr_tx_reset    ,
  output wire                                          usr_rx_reset    ,

  output wire                                          qsfp_rstn_port  ,
  output wire                                          qsfp_lp_mode_port,
  output wire                                          qsfp_seln_port  ,
  input  wire                                          qsfp_prsn_port  ,
  output wire                                          qsfp_led_port    
);

  wire                                                 stat_rx_aligned    ;
  wire                                                 gt_txusrclk2       ;
  wire                                                 gt_rxusrclk2       ;
  wire                                                 rx_clk             ;

  assign  rx_clk           = gt_rxusrclk2     ;// GT接口输出直接给RX域
  assign  gt_txusrclk      = gt_txusrclk2     ;
  assign  gt_rxusrclk      = gt_rxusrclk2     ;

  assign  qsfp_rstn_port   = 1'b1             ;// 默认模块不复位
  assign  qsfp_lp_mode_port= 1'b0             ;// 默认高功耗模式
  assign  qsfp_seln_port   = 1'b1             ;// 默认屏蔽IIC通信
  assign  qsfp_led_port    = !qsfp_prsn_port  ;// 接入光口亮灯


cmac_usplus_a u_cmac_usplus_a (
	// system interface
    .sys_reset        (sys_reset        ),// input wire sys_reset
    .init_clk         (init_clk         ),// input wire init_clk

	// GT Interface
    .gt_ref_clk_p     (gt_ref_clk_p     ),// input wire gt_ref_clk_p
    .gt_ref_clk_n     (gt_ref_clk_n     ),// input wire gt_ref_clk_n
    .gt_txp_out       (gt_txp_out       ),// output wire [3 : 0] gt_txp_out
    .gt_txn_out       (gt_txn_out       ),// output wire [3 : 0] gt_txn_out
    .gt_rxp_in        (gt_rxp_in        ),// input wire [3 : 0] gt_rxp_in
    .gt_rxn_in        (gt_rxn_in        ),// input wire [3 : 0] gt_rxn_in
    .gt_txusrclk2     (gt_txusrclk2     ),// output wire gt_txusrclk2
    .gt_rxusrclk2     (gt_rxusrclk2     ),// output wire gt_rxusrclk2
    .gt_loopback_in   (12'b0            ),// input wire [11 : 0] gt_loopback_in
    .gt_ref_clk_out   (                 ),// output wire gt_ref_clk_out
    .gt_rxrecclkout   (                 ),// output wire [3 : 0] gt_rxrecclkout
    .gt_powergoodout  (                 ),// output wire [3 : 0] gt_powergoodout
    .gtwiz_reset_tx_datapath(1'b0             ),// input wire gtwiz_reset_tx_datapath
    .gtwiz_reset_rx_datapath(1'b0             ),// input wire gtwiz_reset_rx_datapath

	// AXI-S Interface
    .rx_axis_tvalid   (axis_mvalid      ),// output wire rx_axis_tvalid
    .rx_axis_tdata    (axis_mdata       ),// output wire [511 : 0] rx_axis_tdata
    .rx_axis_tlast    (axis_mlast       ),// output wire rx_axis_tlast
    .rx_axis_tkeep    (axis_mkeep       ),// output wire [63 : 0] rx_axis_tkeep
    .rx_axis_tuser    (axis_musr        ),// output wire rx_axis_tuser
    .tx_axis_tready   (axis_sready      ),// output wire tx_axis_tready
    .tx_axis_tvalid   (axis_svalid      ),// input wire tx_axis_tvalid
    .tx_axis_tdata    (axis_sdata       ),// input wire [511 : 0] tx_axis_tdata
    .tx_axis_tlast    (axis_slast       ),// input wire tx_axis_tlast
    .tx_axis_tkeep    (axis_skeep       ),// input wire [63 : 0] tx_axis_tkeep
    .tx_axis_tuser    (axis_susr        ),// input wire tx_axis_tuser

	// rsfec Interface
    .ctl_tx_rsfec_enable(1'b1             ),// input wire ctl_tx_rsfec_enable
    .ctl_rx_rsfec_enable(1'b1             ),// input wire ctl_rx_rsfec_enable
    .ctl_rsfec_ieee_error_indication_mode(1'b0             ),// input wire ctl_rsfec_ieee_error_indication_mode
    .ctl_rx_rsfec_enable_correction(1'b1             ),// input wire ctl_rx_rsfec_enable_correction
    .ctl_rx_rsfec_enable_indication(1'b1             ),// input wire ctl_rx_rsfec_enable_indication
    .stat_rx_rsfec_am_lock0(                 ),// output wire stat_rx_rsfec_am_lock0
    .stat_rx_rsfec_am_lock1(                 ),// output wire stat_rx_rsfec_am_lock1
    .stat_rx_rsfec_am_lock2(                 ),// output wire stat_rx_rsfec_am_lock2
    .stat_rx_rsfec_am_lock3(                 ),// output wire stat_rx_rsfec_am_lock3
    .stat_rx_rsfec_corrected_cw_inc(                 ),// output wire stat_rx_rsfec_corrected_cw_inc
    .stat_rx_rsfec_cw_inc(                 ),// output wire stat_rx_rsfec_cw_inc
    .stat_rx_rsfec_err_count0_inc(                 ),// output wire [2 : 0] stat_rx_rsfec_err_count0_inc
    .stat_rx_rsfec_err_count1_inc(                 ),// output wire [2 : 0] stat_rx_rsfec_err_count1_inc
    .stat_rx_rsfec_err_count2_inc(                 ),// output wire [2 : 0] stat_rx_rsfec_err_count2_inc
    .stat_rx_rsfec_err_count3_inc(                 ),// output wire [2 : 0] stat_rx_rsfec_err_count3_inc
    .stat_rx_rsfec_hi_ser(                 ),// output wire stat_rx_rsfec_hi_ser
    .stat_rx_rsfec_lane_alignment_status(                 ),// output wire stat_rx_rsfec_lane_alignment_status
    .stat_rx_rsfec_lane_fill_0(                 ),// output wire [13 : 0] stat_rx_rsfec_lane_fill_0
    .stat_rx_rsfec_lane_fill_1(                 ),// output wire [13 : 0] stat_rx_rsfec_lane_fill_1
    .stat_rx_rsfec_lane_fill_2(                 ),// output wire [13 : 0] stat_rx_rsfec_lane_fill_2
    .stat_rx_rsfec_lane_fill_3(                 ),// output wire [13 : 0] stat_rx_rsfec_lane_fill_3
    .stat_rx_rsfec_lane_mapping(                 ),// output wire [7 : 0] stat_rx_rsfec_lane_mapping
    .stat_rx_rsfec_uncorrected_cw_inc(                 ),// output wire stat_rx_rsfec_uncorrected_cw_inc

	// tx/rx control interface
    .ctl_tx_enable    (1'b1             ),// input wire ctl_tx_enable
    .ctl_tx_send_idle (1'b0             ),// input wire ctl_tx_send_idle
    .ctl_tx_send_rfi  (1'b0             ),// input wire ctl_tx_send_rfi
    .ctl_tx_send_lfi  (1'b0             ),// input wire ctl_tx_send_lfi
    .ctl_tx_test_pattern(1'b0             ),// input wire ctl_tx_test_pattern
    .core_tx_reset    (1'b0             ),// input wire core_tx_reset
    .ctl_rx_enable    (1'b1             ),// input wire ctl_rx_enable
    .ctl_rx_force_resync(1'b0             ),// input wire ctl_rx_force_resync
    .ctl_rx_test_pattern(1'b0             ),// input wire ctl_rx_test_pattern
    .core_rx_reset    (1'b0             ),// input wire core_rx_reset
    .rx_clk           (rx_clk           ),// input wire rx_clk
  
	// 用户复位输出 / FIFO 警告
    .usr_rx_reset     (usr_rx_reset     ),// output wire usr_rx_reset
    .usr_tx_reset     (usr_tx_reset     ),// output wire usr_tx_reset
    .tx_ovfout        (                 ),// output wire tx_ovfout
    .tx_unfout        (                 ),// output wire tx_unfout
  
	// OTN / 前导码接口
    .rx_otn_bip8_0    (                 ),// output wire [7 : 0] rx_otn_bip8_0
    .rx_otn_bip8_1    (                 ),// output wire [7 : 0] rx_otn_bip8_1
    .rx_otn_bip8_2    (                 ),// output wire [7 : 0] rx_otn_bip8_2
    .rx_otn_bip8_3    (                 ),// output wire [7 : 0] rx_otn_bip8_3
    .rx_otn_bip8_4    (                 ),// output wire [7 : 0] rx_otn_bip8_4
    .rx_otn_data_0    (                 ),// output wire [65 : 0] rx_otn_data_0
    .rx_otn_data_1    (                 ),// output wire [65 : 0] rx_otn_data_1
    .rx_otn_data_2    (                 ),// output wire [65 : 0] rx_otn_data_2
    .rx_otn_data_3    (                 ),// output wire [65 : 0] rx_otn_data_3
    .rx_otn_data_4    (                 ),// output wire [65 : 0] rx_otn_data_4
    .rx_otn_ena       (                 ),// output wire rx_otn_ena
    .rx_otn_lane0     (                 ),// output wire rx_otn_lane0
    .rx_otn_vlmarker  (                 ),// output wire rx_otn_vlmarker
    .rx_preambleout   (                 ),// output wire [55 : 0] rx_preambleout
    .tx_preamblein    (56'd0            ),// input wire [55 : 0] tx_preamblein

	// DRP
    .core_drp_reset   (sys_reset        ),// input wire core_drp_reset
    .drp_clk          (init_clk         ),// input wire drp_clk
    .drp_addr         (10'b0            ),// input wire [9 : 0] drp_addr
    .drp_di           (16'b0            ),// input wire [15 : 0] drp_di
    .drp_en           (1'b0             ),// input wire drp_en
    .drp_do           (                 ),// output wire [15 : 0] drp_do
    .drp_rdy          (                 ),// output wire drp_rdy
    .drp_we           (1'b0             ),// input wire drp_we
  
	// RX 链路 / PCS 状态
    .stat_rx_aligned  (                 ),// output wire stat_rx_aligned
    .stat_rx_aligned_err(                 ),// output wire stat_rx_aligned_err
    .stat_rx_bad_code (                 ),// output wire [2 : 0] stat_rx_bad_code
    .stat_rx_bad_fcs  (                 ),// output wire [2 : 0] stat_rx_bad_fcs
    .stat_rx_bad_preamble(                 ),// output wire stat_rx_bad_preamble
    .stat_rx_bad_sfd  (                 ),// output wire stat_rx_bad_sfd
    .stat_rx_bip_err_0(                 ),// output wire stat_rx_bip_err_0
    .stat_rx_bip_err_1(                 ),// output wire stat_rx_bip_err_1
    .stat_rx_bip_err_10(                 ),// output wire stat_rx_bip_err_10
    .stat_rx_bip_err_11(                 ),// output wire stat_rx_bip_err_11
    .stat_rx_bip_err_12(                 ),// output wire stat_rx_bip_err_12
    .stat_rx_bip_err_13(                 ),// output wire stat_rx_bip_err_13
    .stat_rx_bip_err_14(                 ),// output wire stat_rx_bip_err_14
    .stat_rx_bip_err_15(                 ),// output wire stat_rx_bip_err_15
    .stat_rx_bip_err_16(                 ),// output wire stat_rx_bip_err_16
    .stat_rx_bip_err_17(                 ),// output wire stat_rx_bip_err_17
    .stat_rx_bip_err_18(                 ),// output wire stat_rx_bip_err_18
    .stat_rx_bip_err_19(                 ),// output wire stat_rx_bip_err_19
    .stat_rx_bip_err_2(                 ),// output wire stat_rx_bip_err_2
    .stat_rx_bip_err_3(                 ),// output wire stat_rx_bip_err_3
    .stat_rx_bip_err_4(                 ),// output wire stat_rx_bip_err_4
    .stat_rx_bip_err_5(                 ),// output wire stat_rx_bip_err_5
    .stat_rx_bip_err_6(                 ),// output wire stat_rx_bip_err_6
    .stat_rx_bip_err_7(                 ),// output wire stat_rx_bip_err_7
    .stat_rx_bip_err_8(                 ),// output wire stat_rx_bip_err_8
    .stat_rx_bip_err_9(                 ),// output wire stat_rx_bip_err_9
    .stat_rx_block_lock(                 ),// output wire [19 : 0] stat_rx_block_lock
    .stat_rx_broadcast(                 ),// output wire stat_rx_broadcast
    .stat_rx_fragment (                 ),// output wire [2 : 0] stat_rx_fragment
    .stat_rx_framing_err_0(                 ),// output wire [1 : 0] stat_rx_framing_err_0
    .stat_rx_framing_err_1(                 ),// output wire [1 : 0] stat_rx_framing_err_1
    .stat_rx_framing_err_10(                 ),// output wire [1 : 0] stat_rx_framing_err_10
    .stat_rx_framing_err_11(                 ),// output wire [1 : 0] stat_rx_framing_err_11
    .stat_rx_framing_err_12(                 ),// output wire [1 : 0] stat_rx_framing_err_12
    .stat_rx_framing_err_13(                 ),// output wire [1 : 0] stat_rx_framing_err_13
    .stat_rx_framing_err_14(                 ),// output wire [1 : 0] stat_rx_framing_err_14
    .stat_rx_framing_err_15(                 ),// output wire [1 : 0] stat_rx_framing_err_15
    .stat_rx_framing_err_16(                 ),// output wire [1 : 0] stat_rx_framing_err_16
    .stat_rx_framing_err_17(                 ),// output wire [1 : 0] stat_rx_framing_err_17
    .stat_rx_framing_err_18(                 ),// output wire [1 : 0] stat_rx_framing_err_18
    .stat_rx_framing_err_19(                 ),// output wire [1 : 0] stat_rx_framing_err_19
    .stat_rx_framing_err_2(                 ),// output wire [1 : 0] stat_rx_framing_err_2
    .stat_rx_framing_err_3(                 ),// output wire [1 : 0] stat_rx_framing_err_3
    .stat_rx_framing_err_4(                 ),// output wire [1 : 0] stat_rx_framing_err_4
    .stat_rx_framing_err_5(                 ),// output wire [1 : 0] stat_rx_framing_err_5
    .stat_rx_framing_err_6(                 ),// output wire [1 : 0] stat_rx_framing_err_6
    .stat_rx_framing_err_7(                 ),// output wire [1 : 0] stat_rx_framing_err_7
    .stat_rx_framing_err_8(                 ),// output wire [1 : 0] stat_rx_framing_err_8
    .stat_rx_framing_err_9(                 ),// output wire [1 : 0] stat_rx_framing_err_9
    .stat_rx_framing_err_valid_0(                 ),// output wire stat_rx_framing_err_valid_0
    .stat_rx_framing_err_valid_1(                 ),// output wire stat_rx_framing_err_valid_1
    .stat_rx_framing_err_valid_10(                 ),// output wire stat_rx_framing_err_valid_10
    .stat_rx_framing_err_valid_11(                 ),// output wire stat_rx_framing_err_valid_11
    .stat_rx_framing_err_valid_12(                 ),// output wire stat_rx_framing_err_valid_12
    .stat_rx_framing_err_valid_13(                 ),// output wire stat_rx_framing_err_valid_13
    .stat_rx_framing_err_valid_14(                 ),// output wire stat_rx_framing_err_valid_14
    .stat_rx_framing_err_valid_15(                 ),// output wire stat_rx_framing_err_valid_15
    .stat_rx_framing_err_valid_16(                 ),// output wire stat_rx_framing_err_valid_16
    .stat_rx_framing_err_valid_17(                 ),// output wire stat_rx_framing_err_valid_17
    .stat_rx_framing_err_valid_18(                 ),// output wire stat_rx_framing_err_valid_18
    .stat_rx_framing_err_valid_19(                 ),// output wire stat_rx_framing_err_valid_19
    .stat_rx_framing_err_valid_2(                 ),// output wire stat_rx_framing_err_valid_2
    .stat_rx_framing_err_valid_3(                 ),// output wire stat_rx_framing_err_valid_3
    .stat_rx_framing_err_valid_4(                 ),// output wire stat_rx_framing_err_valid_4
    .stat_rx_framing_err_valid_5(                 ),// output wire stat_rx_framing_err_valid_5
    .stat_rx_framing_err_valid_6(                 ),// output wire stat_rx_framing_err_valid_6
    .stat_rx_framing_err_valid_7(                 ),// output wire stat_rx_framing_err_valid_7
    .stat_rx_framing_err_valid_8(                 ),// output wire stat_rx_framing_err_valid_8
    .stat_rx_framing_err_valid_9(                 ),// output wire stat_rx_framing_err_valid_9
    .stat_rx_got_signal_os(                 ),// output wire stat_rx_got_signal_os
    .stat_rx_hi_ber   (                 ),// output wire stat_rx_hi_ber
    .stat_rx_inrangeerr(                 ),// output wire stat_rx_inrangeerr
    .stat_rx_internal_local_fault(                 ),// output wire stat_rx_internal_local_fault
    .stat_rx_jabber   (                 ),// output wire stat_rx_jabber
    .stat_rx_local_fault(                 ),// output wire stat_rx_local_fault
    .stat_rx_mf_err   (                 ),// output wire [19 : 0] stat_rx_mf_err
    .stat_rx_mf_len_err(                 ),// output wire [19 : 0] stat_rx_mf_len_err
    .stat_rx_mf_repeat_err(                 ),// output wire [19 : 0] stat_rx_mf_repeat_err
    .stat_rx_misaligned(                 ),// output wire stat_rx_misaligned
    .stat_rx_multicast(                 ),// output wire stat_rx_multicast
    .stat_rx_oversize (                 ),// output wire stat_rx_oversize
    .stat_rx_packet_1024_1518_bytes(                 ),// output wire stat_rx_packet_1024_1518_bytes
    .stat_rx_packet_128_255_bytes(                 ),// output wire stat_rx_packet_128_255_bytes
    .stat_rx_packet_1519_1522_bytes(                 ),// output wire stat_rx_packet_1519_1522_bytes
    .stat_rx_packet_1523_1548_bytes(                 ),// output wire stat_rx_packet_1523_1548_bytes
    .stat_rx_packet_1549_2047_bytes(                 ),// output wire stat_rx_packet_1549_2047_bytes
    .stat_rx_packet_2048_4095_bytes(                 ),// output wire stat_rx_packet_2048_4095_bytes
    .stat_rx_packet_256_511_bytes(                 ),// output wire stat_rx_packet_256_511_bytes
    .stat_rx_packet_4096_8191_bytes(                 ),// output wire stat_rx_packet_4096_8191_bytes
    .stat_rx_packet_512_1023_bytes(                 ),// output wire stat_rx_packet_512_1023_bytes
    .stat_rx_packet_64_bytes(                 ),// output wire stat_rx_packet_64_bytes
    .stat_rx_packet_65_127_bytes(                 ),// output wire stat_rx_packet_65_127_bytes
    .stat_rx_packet_8192_9215_bytes(                 ),// output wire stat_rx_packet_8192_9215_bytes
    .stat_rx_packet_bad_fcs(                 ),// output wire stat_rx_packet_bad_fcs
    .stat_rx_packet_large(                 ),// output wire stat_rx_packet_large
    .stat_rx_packet_small(                 ),// output wire [2 : 0] stat_rx_packet_small
    .stat_rx_received_local_fault(                 ),// output wire stat_rx_received_local_fault
    .stat_rx_remote_fault(                 ),// output wire stat_rx_remote_fault
    .stat_rx_status   (                 ),// output wire stat_rx_status
    .stat_rx_stomped_fcs(                 ),// output wire [2 : 0] stat_rx_stomped_fcs
    .stat_rx_synced   (                 ),// output wire [19 : 0] stat_rx_synced
    .stat_rx_synced_err(                 ),// output wire [19 : 0] stat_rx_synced_err
    .stat_rx_test_pattern_mismatch(                 ),// output wire [2 : 0] stat_rx_test_pattern_mismatch
    .stat_rx_toolong  (                 ),// output wire stat_rx_toolong
    .stat_rx_total_bytes(                 ),// output wire [6 : 0] stat_rx_total_bytes
    .stat_rx_total_good_bytes(                 ),// output wire [13 : 0] stat_rx_total_good_bytes
    .stat_rx_total_good_packets(                 ),// output wire stat_rx_total_good_packets
    .stat_rx_total_packets(                 ),// output wire [2 : 0] stat_rx_total_packets
    .stat_rx_truncated(                 ),// output wire stat_rx_truncated
    .stat_rx_undersize(                 ),// output wire [2 : 0] stat_rx_undersize
    .stat_rx_unicast  (                 ),// output wire stat_rx_unicast
    .stat_rx_vlan     (                 ),// output wire stat_rx_vlan
    .stat_rx_pcsl_demuxed(                 ),// output wire [19 : 0] stat_rx_pcsl_demuxed
    .stat_rx_pcsl_number_0(                 ),// output wire [4 : 0] stat_rx_pcsl_number_0
    .stat_rx_pcsl_number_1(                 ),// output wire [4 : 0] stat_rx_pcsl_number_1
    .stat_rx_pcsl_number_10(                 ),// output wire [4 : 0] stat_rx_pcsl_number_10
    .stat_rx_pcsl_number_11(                 ),// output wire [4 : 0] stat_rx_pcsl_number_11
    .stat_rx_pcsl_number_12(                 ),// output wire [4 : 0] stat_rx_pcsl_number_12
    .stat_rx_pcsl_number_13(                 ),// output wire [4 : 0] stat_rx_pcsl_number_13
    .stat_rx_pcsl_number_14(                 ),// output wire [4 : 0] stat_rx_pcsl_number_14
    .stat_rx_pcsl_number_15(                 ),// output wire [4 : 0] stat_rx_pcsl_number_15
    .stat_rx_pcsl_number_16(                 ),// output wire [4 : 0] stat_rx_pcsl_number_16
    .stat_rx_pcsl_number_17(                 ),// output wire [4 : 0] stat_rx_pcsl_number_17
    .stat_rx_pcsl_number_18(                 ),// output wire [4 : 0] stat_rx_pcsl_number_18
    .stat_rx_pcsl_number_19(                 ),// output wire [4 : 0] stat_rx_pcsl_number_19
    .stat_rx_pcsl_number_2(                 ),// output wire [4 : 0] stat_rx_pcsl_number_2
    .stat_rx_pcsl_number_3(                 ),// output wire [4 : 0] stat_rx_pcsl_number_3
    .stat_rx_pcsl_number_4(                 ),// output wire [4 : 0] stat_rx_pcsl_number_4
    .stat_rx_pcsl_number_5(                 ),// output wire [4 : 0] stat_rx_pcsl_number_5
    .stat_rx_pcsl_number_6(                 ),// output wire [4 : 0] stat_rx_pcsl_number_6
    .stat_rx_pcsl_number_7(                 ),// output wire [4 : 0] stat_rx_pcsl_number_7
    .stat_rx_pcsl_number_8(                 ),// output wire [4 : 0] stat_rx_pcsl_number_8
    .stat_rx_pcsl_number_9(                 ),// output wire [4 : 0] stat_rx_pcsl_number_9
    .stat_tx_bad_fcs  (                 ),// output wire stat_tx_bad_fcs
    .stat_tx_broadcast(                 ),// output wire stat_tx_broadcast
    .stat_tx_frame_error(                 ),// output wire stat_tx_frame_error
    .stat_tx_local_fault(                 ),// output wire stat_tx_local_fault
    .stat_tx_multicast(                 ),// output wire stat_tx_multicast
    .stat_tx_packet_1024_1518_bytes(                 ),// output wire stat_tx_packet_1024_1518_bytes
    .stat_tx_packet_128_255_bytes(                 ),// output wire stat_tx_packet_128_255_bytes
    .stat_tx_packet_1519_1522_bytes(                 ),// output wire stat_tx_packet_1519_1522_bytes
    .stat_tx_packet_1523_1548_bytes(                 ),// output wire stat_tx_packet_1523_1548_bytes
    .stat_tx_packet_1549_2047_bytes(                 ),// output wire stat_tx_packet_1549_2047_bytes
    .stat_tx_packet_2048_4095_bytes(                 ),// output wire stat_tx_packet_2048_4095_bytes
    .stat_tx_packet_256_511_bytes(                 ),// output wire stat_tx_packet_256_511_bytes
    .stat_tx_packet_4096_8191_bytes(                 ),// output wire stat_tx_packet_4096_8191_bytes
    .stat_tx_packet_512_1023_bytes(                 ),// output wire stat_tx_packet_512_1023_bytes
    .stat_tx_packet_64_bytes(                 ),// output wire stat_tx_packet_64_bytes
    .stat_tx_packet_65_127_bytes(                 ),// output wire stat_tx_packet_65_127_bytes
    .stat_tx_packet_8192_9215_bytes(                 ),// output wire stat_tx_packet_8192_9215_bytes
    .stat_tx_packet_large(                 ),// output wire stat_tx_packet_large
    .stat_tx_packet_small(                 ),// output wire stat_tx_packet_small
    .stat_tx_total_bytes(                 ),// output wire [5 : 0] stat_tx_total_bytes
    .stat_tx_total_good_bytes(                 ),// output wire [13 : 0] stat_tx_total_good_bytes
    .stat_tx_total_good_packets(                 ),// output wire stat_tx_total_good_packets
    .stat_tx_total_packets(                 ),// output wire stat_tx_total_packets
    .stat_tx_unicast  (                 ),// output wire stat_tx_unicast
    .stat_tx_vlan     (                 ) // output wire stat_tx_vlan
);

endmodule
`resetall
