`resetall
`timescale 1ns/100ps

// CMAC US+ 仿真桩，仅供 xsim 使用（不参与综合）

// ============================================================================
// cmac_usplus_a —— CMAC US+ 仿真桩（仅 xsim，不参与综合）
//   端口表自 cmac_a_if 例化自动提取；链路恒 up、无 fault、无复位
// ============================================================================
module cmac_usplus_a (
  input  wire             sys_reset,
  input  wire             init_clk,
  input  wire             gt_ref_clk_p,
  input  wire             gt_ref_clk_n,
  output wire [3:0]       gt_txp_out,
  output wire [3:0]       gt_txn_out,
  input  wire [3:0]       gt_rxp_in,
  input  wire [3:0]       gt_rxn_in,
  output wire             gt_txusrclk2,
  output wire             gt_rxusrclk2,
  input  wire [11:0]      gt_loopback_in,
  output wire             gt_ref_clk_out,
  output wire [3:0]       gt_rxrecclkout,
  output wire [3:0]       gt_powergoodout,
  input  wire             gtwiz_reset_tx_datapath,
  input  wire             gtwiz_reset_rx_datapath,
  output wire             rx_axis_tvalid,
  output wire [511:0]     rx_axis_tdata,
  output wire             rx_axis_tlast,
  output wire [63:0]      rx_axis_tkeep,
  output wire             rx_axis_tuser,
  output wire             tx_axis_tready,
  input  wire             tx_axis_tvalid,
  input  wire [511:0]     tx_axis_tdata,
  input  wire             tx_axis_tlast,
  input  wire [63:0]      tx_axis_tkeep,
  input  wire             tx_axis_tuser,
  input  wire             ctl_tx_rsfec_enable,
  input  wire             ctl_rx_rsfec_enable,
  input  wire             ctl_rsfec_ieee_error_indication_mode,
  input  wire             ctl_rx_rsfec_enable_correction,
  input  wire             ctl_rx_rsfec_enable_indication,
  output wire             stat_rx_rsfec_am_lock0,
  output wire             stat_rx_rsfec_am_lock1,
  output wire             stat_rx_rsfec_am_lock2,
  output wire             stat_rx_rsfec_am_lock3,
  output wire             stat_rx_rsfec_corrected_cw_inc,
  output wire             stat_rx_rsfec_cw_inc,
  output wire [2:0]       stat_rx_rsfec_err_count0_inc,
  output wire [2:0]       stat_rx_rsfec_err_count1_inc,
  output wire [2:0]       stat_rx_rsfec_err_count2_inc,
  output wire [2:0]       stat_rx_rsfec_err_count3_inc,
  output wire             stat_rx_rsfec_hi_ser,
  output wire             stat_rx_rsfec_lane_alignment_status,
  output wire [13:0]      stat_rx_rsfec_lane_fill_0,
  output wire [13:0]      stat_rx_rsfec_lane_fill_1,
  output wire [13:0]      stat_rx_rsfec_lane_fill_2,
  output wire [13:0]      stat_rx_rsfec_lane_fill_3,
  output wire [7:0]       stat_rx_rsfec_lane_mapping,
  output wire             stat_rx_rsfec_uncorrected_cw_inc,
  input  wire             ctl_tx_enable,
  input  wire             ctl_tx_send_idle,
  input  wire             ctl_tx_send_rfi,
  input  wire             ctl_tx_send_lfi,
  input  wire             ctl_tx_test_pattern,
  input  wire             core_tx_reset,
  input  wire             ctl_rx_enable,
  input  wire             ctl_rx_force_resync,
  input  wire             ctl_rx_test_pattern,
  input  wire             core_rx_reset,
  input  wire             rx_clk,
  output wire             usr_rx_reset,
  output wire             usr_tx_reset,
  output wire             tx_ovfout,
  output wire             tx_unfout,
  output wire [7:0]       rx_otn_bip8_0,
  output wire [7:0]       rx_otn_bip8_1,
  output wire [7:0]       rx_otn_bip8_2,
  output wire [7:0]       rx_otn_bip8_3,
  output wire [7:0]       rx_otn_bip8_4,
  output wire [65:0]      rx_otn_data_0,
  output wire [65:0]      rx_otn_data_1,
  output wire [65:0]      rx_otn_data_2,
  output wire [65:0]      rx_otn_data_3,
  output wire [65:0]      rx_otn_data_4,
  output wire             rx_otn_ena,
  output wire             rx_otn_lane0,
  output wire             rx_otn_vlmarker,
  output wire [55:0]      rx_preambleout,
  input  wire [55:0]      tx_preamblein,
  input  wire             core_drp_reset,
  input  wire             drp_clk,
  input  wire [9:0]       drp_addr,
  input  wire [15:0]      drp_di,
  input  wire             drp_en,
  output wire [15:0]      drp_do,
  output wire             drp_rdy,
  input  wire             drp_we,
  output wire             stat_rx_aligned,
  output wire             stat_rx_aligned_err,
  output wire [2:0]       stat_rx_bad_code,
  output wire [2:0]       stat_rx_bad_fcs,
  output wire             stat_rx_bad_preamble,
  output wire             stat_rx_bad_sfd,
  output wire             stat_rx_bip_err_0,
  output wire             stat_rx_bip_err_1,
  output wire             stat_rx_bip_err_10,
  output wire             stat_rx_bip_err_11,
  output wire             stat_rx_bip_err_12,
  output wire             stat_rx_bip_err_13,
  output wire             stat_rx_bip_err_14,
  output wire             stat_rx_bip_err_15,
  output wire             stat_rx_bip_err_16,
  output wire             stat_rx_bip_err_17,
  output wire             stat_rx_bip_err_18,
  output wire             stat_rx_bip_err_19,
  output wire             stat_rx_bip_err_2,
  output wire             stat_rx_bip_err_3,
  output wire             stat_rx_bip_err_4,
  output wire             stat_rx_bip_err_5,
  output wire             stat_rx_bip_err_6,
  output wire             stat_rx_bip_err_7,
  output wire             stat_rx_bip_err_8,
  output wire             stat_rx_bip_err_9,
  output wire [19:0]      stat_rx_block_lock,
  output wire             stat_rx_broadcast,
  output wire [2:0]       stat_rx_fragment,
  output wire [1:0]       stat_rx_framing_err_0,
  output wire [1:0]       stat_rx_framing_err_1,
  output wire [1:0]       stat_rx_framing_err_10,
  output wire [1:0]       stat_rx_framing_err_11,
  output wire [1:0]       stat_rx_framing_err_12,
  output wire [1:0]       stat_rx_framing_err_13,
  output wire [1:0]       stat_rx_framing_err_14,
  output wire [1:0]       stat_rx_framing_err_15,
  output wire [1:0]       stat_rx_framing_err_16,
  output wire [1:0]       stat_rx_framing_err_17,
  output wire [1:0]       stat_rx_framing_err_18,
  output wire [1:0]       stat_rx_framing_err_19,
  output wire [1:0]       stat_rx_framing_err_2,
  output wire [1:0]       stat_rx_framing_err_3,
  output wire [1:0]       stat_rx_framing_err_4,
  output wire [1:0]       stat_rx_framing_err_5,
  output wire [1:0]       stat_rx_framing_err_6,
  output wire [1:0]       stat_rx_framing_err_7,
  output wire [1:0]       stat_rx_framing_err_8,
  output wire [1:0]       stat_rx_framing_err_9,
  output wire             stat_rx_framing_err_valid_0,
  output wire             stat_rx_framing_err_valid_1,
  output wire             stat_rx_framing_err_valid_10,
  output wire             stat_rx_framing_err_valid_11,
  output wire             stat_rx_framing_err_valid_12,
  output wire             stat_rx_framing_err_valid_13,
  output wire             stat_rx_framing_err_valid_14,
  output wire             stat_rx_framing_err_valid_15,
  output wire             stat_rx_framing_err_valid_16,
  output wire             stat_rx_framing_err_valid_17,
  output wire             stat_rx_framing_err_valid_18,
  output wire             stat_rx_framing_err_valid_19,
  output wire             stat_rx_framing_err_valid_2,
  output wire             stat_rx_framing_err_valid_3,
  output wire             stat_rx_framing_err_valid_4,
  output wire             stat_rx_framing_err_valid_5,
  output wire             stat_rx_framing_err_valid_6,
  output wire             stat_rx_framing_err_valid_7,
  output wire             stat_rx_framing_err_valid_8,
  output wire             stat_rx_framing_err_valid_9,
  output wire             stat_rx_got_signal_os,
  output wire             stat_rx_hi_ber,
  output wire             stat_rx_inrangeerr,
  output wire             stat_rx_internal_local_fault,
  output wire             stat_rx_jabber,
  output wire             stat_rx_local_fault,
  output wire [19:0]      stat_rx_mf_err,
  output wire [19:0]      stat_rx_mf_len_err,
  output wire [19:0]      stat_rx_mf_repeat_err,
  output wire             stat_rx_misaligned,
  output wire             stat_rx_multicast,
  output wire             stat_rx_oversize,
  output wire             stat_rx_packet_1024_1518_bytes,
  output wire             stat_rx_packet_128_255_bytes,
  output wire             stat_rx_packet_1519_1522_bytes,
  output wire             stat_rx_packet_1523_1548_bytes,
  output wire             stat_rx_packet_1549_2047_bytes,
  output wire             stat_rx_packet_2048_4095_bytes,
  output wire             stat_rx_packet_256_511_bytes,
  output wire             stat_rx_packet_4096_8191_bytes,
  output wire             stat_rx_packet_512_1023_bytes,
  output wire             stat_rx_packet_64_bytes,
  output wire             stat_rx_packet_65_127_bytes,
  output wire             stat_rx_packet_8192_9215_bytes,
  output wire             stat_rx_packet_bad_fcs,
  output wire             stat_rx_packet_large,
  output wire [2:0]       stat_rx_packet_small,
  output wire             stat_rx_received_local_fault,
  output wire             stat_rx_remote_fault,
  output wire             stat_rx_status,
  output wire [2:0]       stat_rx_stomped_fcs,
  output wire [19:0]      stat_rx_synced,
  output wire [19:0]      stat_rx_synced_err,
  output wire [2:0]       stat_rx_test_pattern_mismatch,
  output wire             stat_rx_toolong,
  output wire [6:0]       stat_rx_total_bytes,
  output wire [13:0]      stat_rx_total_good_bytes,
  output wire             stat_rx_total_good_packets,
  output wire [2:0]       stat_rx_total_packets,
  output wire             stat_rx_truncated,
  output wire [2:0]       stat_rx_undersize,
  output wire             stat_rx_unicast,
  output wire             stat_rx_vlan,
  output wire [19:0]      stat_rx_pcsl_demuxed,
  output wire [4:0]       stat_rx_pcsl_number_0,
  output wire [4:0]       stat_rx_pcsl_number_1,
  output wire [4:0]       stat_rx_pcsl_number_10,
  output wire [4:0]       stat_rx_pcsl_number_11,
  output wire [4:0]       stat_rx_pcsl_number_12,
  output wire [4:0]       stat_rx_pcsl_number_13,
  output wire [4:0]       stat_rx_pcsl_number_14,
  output wire [4:0]       stat_rx_pcsl_number_15,
  output wire [4:0]       stat_rx_pcsl_number_16,
  output wire [4:0]       stat_rx_pcsl_number_17,
  output wire [4:0]       stat_rx_pcsl_number_18,
  output wire [4:0]       stat_rx_pcsl_number_19,
  output wire [4:0]       stat_rx_pcsl_number_2,
  output wire [4:0]       stat_rx_pcsl_number_3,
  output wire [4:0]       stat_rx_pcsl_number_4,
  output wire [4:0]       stat_rx_pcsl_number_5,
  output wire [4:0]       stat_rx_pcsl_number_6,
  output wire [4:0]       stat_rx_pcsl_number_7,
  output wire [4:0]       stat_rx_pcsl_number_8,
  output wire [4:0]       stat_rx_pcsl_number_9,
  output wire             stat_tx_bad_fcs,
  output wire             stat_tx_broadcast,
  output wire             stat_tx_frame_error,
  output wire             stat_tx_local_fault,
  output wire             stat_tx_multicast,
  output wire             stat_tx_packet_1024_1518_bytes,
  output wire             stat_tx_packet_128_255_bytes,
  output wire             stat_tx_packet_1519_1522_bytes,
  output wire             stat_tx_packet_1523_1548_bytes,
  output wire             stat_tx_packet_1549_2047_bytes,
  output wire             stat_tx_packet_2048_4095_bytes,
  output wire             stat_tx_packet_256_511_bytes,
  output wire             stat_tx_packet_4096_8191_bytes,
  output wire             stat_tx_packet_512_1023_bytes,
  output wire             stat_tx_packet_64_bytes,
  output wire             stat_tx_packet_65_127_bytes,
  output wire             stat_tx_packet_8192_9215_bytes,
  output wire             stat_tx_packet_large,
  output wire             stat_tx_packet_small,
  output wire [5:0]       stat_tx_total_bytes,
  output wire [13:0]      stat_tx_total_good_bytes,
  output wire             stat_tx_total_good_packets,
  output wire             stat_tx_total_packets,
  output wire             stat_tx_unicast,
  output wire             stat_tx_vlan
);

  // ---- 仿真时钟（真实为 GT 输出 322.269MHz，仿真取 100MHz）----
  reg  sim_clk = 1'b0;
  always #5.0 sim_clk = ~sim_clk;
  assign gt_txusrclk2 = sim_clk;
  assign gt_rxusrclk2 = sim_clk;

  // ---- 上电复位：给下游 SLR/CDC FIFO 一个复位脉冲（真实 IP 由 GT 复位产生）----
  reg  [3:0] sim_rst_cnt = 4'd15;
  always @(posedge sim_clk) if (sim_rst_cnt != 4'd0) sim_rst_cnt <= sim_rst_cnt - 4'd1;
  wire       sim_rst_act = (sim_rst_cnt != 4'd0);

  // ---- RX 注入（TB 层次引用写；CMAC RX 无 tready，无流控）----
  reg  [511:0] sim_rx_data  = 512'd0;
  reg  [ 63:0] sim_rx_keep  = 64'd0;
  reg          sim_rx_last  = 1'b0;
  reg          sim_rx_valid = 1'b0;

  // ---- TX 捕获 ----
  reg  [511:0] sim_tx_data  = 512'd0;
  reg  [ 63:0] sim_tx_keep  = 64'd0;
  reg          sim_tx_last  = 1'b0;
  reg          sim_tx_valid = 1'b0;
  always @(posedge sim_clk) begin
    sim_tx_valid <= tx_axis_tvalid;
    if (tx_axis_tvalid) begin
      sim_tx_data <= tx_axis_tdata;
      sim_tx_keep <= tx_axis_tkeep;
      sim_tx_last <= tx_axis_tlast;
    end
  end

  // ---- 其余输出恒 0 ----
  assign gt_txp_out                       = 1'b0;
  assign gt_txn_out                       = 1'b0;
  assign gt_ref_clk_out                   = 1'b0;
  assign gt_rxrecclkout                   = 1'b0;
  assign gt_powergoodout                  = 1'b0;
  assign stat_rx_rsfec_am_lock0           = 1'b0;
  assign stat_rx_rsfec_am_lock1           = 1'b0;
  assign stat_rx_rsfec_am_lock2           = 1'b0;
  assign stat_rx_rsfec_am_lock3           = 1'b0;
  assign stat_rx_rsfec_corrected_cw_inc   = 1'b0;
  assign stat_rx_rsfec_cw_inc             = 1'b0;
  assign stat_rx_rsfec_err_count0_inc     = 1'b0;
  assign stat_rx_rsfec_err_count1_inc     = 1'b0;
  assign stat_rx_rsfec_err_count2_inc     = 1'b0;
  assign stat_rx_rsfec_err_count3_inc     = 1'b0;
  assign stat_rx_rsfec_hi_ser             = 1'b0;
  assign stat_rx_rsfec_lane_alignment_status = 1'b0;
  assign stat_rx_rsfec_lane_fill_0        = 1'b0;
  assign stat_rx_rsfec_lane_fill_1        = 1'b0;
  assign stat_rx_rsfec_lane_fill_2        = 1'b0;
  assign stat_rx_rsfec_lane_fill_3        = 1'b0;
  assign stat_rx_rsfec_lane_mapping       = 1'b0;
  assign stat_rx_rsfec_uncorrected_cw_inc = 1'b0;
  assign tx_ovfout                        = 1'b0;
  assign tx_unfout                        = 1'b0;
  assign rx_otn_bip8_0                    = 1'b0;
  assign rx_otn_bip8_1                    = 1'b0;
  assign rx_otn_bip8_2                    = 1'b0;
  assign rx_otn_bip8_3                    = 1'b0;
  assign rx_otn_bip8_4                    = 1'b0;
  assign rx_otn_data_0                    = 1'b0;
  assign rx_otn_data_1                    = 1'b0;
  assign rx_otn_data_2                    = 1'b0;
  assign rx_otn_data_3                    = 1'b0;
  assign rx_otn_data_4                    = 1'b0;
  assign rx_otn_ena                       = 1'b0;
  assign rx_otn_lane0                     = 1'b0;
  assign rx_otn_vlmarker                  = 1'b0;
  assign rx_preambleout                   = 1'b0;
  assign drp_do                           = 1'b0;
  assign drp_rdy                          = 1'b0;
  assign stat_rx_aligned_err              = 1'b0;
  assign stat_rx_bad_code                 = 1'b0;
  assign stat_rx_bad_fcs                  = 1'b0;
  assign stat_rx_bad_preamble             = 1'b0;
  assign stat_rx_bad_sfd                  = 1'b0;
  assign stat_rx_bip_err_0                = 1'b0;
  assign stat_rx_bip_err_1                = 1'b0;
  assign stat_rx_bip_err_10               = 1'b0;
  assign stat_rx_bip_err_11               = 1'b0;
  assign stat_rx_bip_err_12               = 1'b0;
  assign stat_rx_bip_err_13               = 1'b0;
  assign stat_rx_bip_err_14               = 1'b0;
  assign stat_rx_bip_err_15               = 1'b0;
  assign stat_rx_bip_err_16               = 1'b0;
  assign stat_rx_bip_err_17               = 1'b0;
  assign stat_rx_bip_err_18               = 1'b0;
  assign stat_rx_bip_err_19               = 1'b0;
  assign stat_rx_bip_err_2                = 1'b0;
  assign stat_rx_bip_err_3                = 1'b0;
  assign stat_rx_bip_err_4                = 1'b0;
  assign stat_rx_bip_err_5                = 1'b0;
  assign stat_rx_bip_err_6                = 1'b0;
  assign stat_rx_bip_err_7                = 1'b0;
  assign stat_rx_bip_err_8                = 1'b0;
  assign stat_rx_bip_err_9                = 1'b0;
  assign stat_rx_block_lock               = 1'b0;
  assign stat_rx_broadcast                = 1'b0;
  assign stat_rx_fragment                 = 1'b0;
  assign stat_rx_framing_err_0            = 1'b0;
  assign stat_rx_framing_err_1            = 1'b0;
  assign stat_rx_framing_err_10           = 1'b0;
  assign stat_rx_framing_err_11           = 1'b0;
  assign stat_rx_framing_err_12           = 1'b0;
  assign stat_rx_framing_err_13           = 1'b0;
  assign stat_rx_framing_err_14           = 1'b0;
  assign stat_rx_framing_err_15           = 1'b0;
  assign stat_rx_framing_err_16           = 1'b0;
  assign stat_rx_framing_err_17           = 1'b0;
  assign stat_rx_framing_err_18           = 1'b0;
  assign stat_rx_framing_err_19           = 1'b0;
  assign stat_rx_framing_err_2            = 1'b0;
  assign stat_rx_framing_err_3            = 1'b0;
  assign stat_rx_framing_err_4            = 1'b0;
  assign stat_rx_framing_err_5            = 1'b0;
  assign stat_rx_framing_err_6            = 1'b0;
  assign stat_rx_framing_err_7            = 1'b0;
  assign stat_rx_framing_err_8            = 1'b0;
  assign stat_rx_framing_err_9            = 1'b0;
  assign stat_rx_framing_err_valid_0      = 1'b0;
  assign stat_rx_framing_err_valid_1      = 1'b0;
  assign stat_rx_framing_err_valid_10     = 1'b0;
  assign stat_rx_framing_err_valid_11     = 1'b0;
  assign stat_rx_framing_err_valid_12     = 1'b0;
  assign stat_rx_framing_err_valid_13     = 1'b0;
  assign stat_rx_framing_err_valid_14     = 1'b0;
  assign stat_rx_framing_err_valid_15     = 1'b0;
  assign stat_rx_framing_err_valid_16     = 1'b0;
  assign stat_rx_framing_err_valid_17     = 1'b0;
  assign stat_rx_framing_err_valid_18     = 1'b0;
  assign stat_rx_framing_err_valid_19     = 1'b0;
  assign stat_rx_framing_err_valid_2      = 1'b0;
  assign stat_rx_framing_err_valid_3      = 1'b0;
  assign stat_rx_framing_err_valid_4      = 1'b0;
  assign stat_rx_framing_err_valid_5      = 1'b0;
  assign stat_rx_framing_err_valid_6      = 1'b0;
  assign stat_rx_framing_err_valid_7      = 1'b0;
  assign stat_rx_framing_err_valid_8      = 1'b0;
  assign stat_rx_framing_err_valid_9      = 1'b0;
  assign stat_rx_got_signal_os            = 1'b0;
  assign stat_rx_hi_ber                   = 1'b0;
  assign stat_rx_inrangeerr               = 1'b0;
  assign stat_rx_internal_local_fault     = 1'b0;
  assign stat_rx_jabber                   = 1'b0;
  assign stat_rx_local_fault              = 1'b0;
  assign stat_rx_mf_err                   = 1'b0;
  assign stat_rx_mf_len_err               = 1'b0;
  assign stat_rx_mf_repeat_err            = 1'b0;
  assign stat_rx_misaligned               = 1'b0;
  assign stat_rx_multicast                = 1'b0;
  assign stat_rx_oversize                 = 1'b0;
  assign stat_rx_packet_1024_1518_bytes   = 1'b0;
  assign stat_rx_packet_128_255_bytes     = 1'b0;
  assign stat_rx_packet_1519_1522_bytes   = 1'b0;
  assign stat_rx_packet_1523_1548_bytes   = 1'b0;
  assign stat_rx_packet_1549_2047_bytes   = 1'b0;
  assign stat_rx_packet_2048_4095_bytes   = 1'b0;
  assign stat_rx_packet_256_511_bytes     = 1'b0;
  assign stat_rx_packet_4096_8191_bytes   = 1'b0;
  assign stat_rx_packet_512_1023_bytes    = 1'b0;
  assign stat_rx_packet_64_bytes          = 1'b0;
  assign stat_rx_packet_65_127_bytes      = 1'b0;
  assign stat_rx_packet_8192_9215_bytes   = 1'b0;
  assign stat_rx_packet_bad_fcs           = 1'b0;
  assign stat_rx_packet_large             = 1'b0;
  assign stat_rx_packet_small             = 1'b0;
  assign stat_rx_received_local_fault     = 1'b0;
  assign stat_rx_remote_fault             = 1'b0;
  assign stat_rx_status                  = 1'b1;   // PCS 已对齐且非 HI_BER
  assign stat_rx_stomped_fcs              = 1'b0;
  assign stat_rx_synced                   = 1'b0;
  assign stat_rx_synced_err               = 1'b0;
  assign stat_rx_test_pattern_mismatch    = 1'b0;
  assign stat_rx_toolong                  = 1'b0;
  assign stat_rx_total_bytes              = 1'b0;
  assign stat_rx_total_good_bytes         = 1'b0;
  assign stat_rx_total_good_packets       = 1'b0;
  assign stat_rx_total_packets            = 1'b0;
  assign stat_rx_truncated                = 1'b0;
  assign stat_rx_undersize                = 1'b0;
  assign stat_rx_unicast                  = 1'b0;
  assign stat_rx_vlan                     = 1'b0;
  assign stat_rx_pcsl_demuxed             = 1'b0;
  assign stat_rx_pcsl_number_0            = 1'b0;
  assign stat_rx_pcsl_number_1            = 1'b0;
  assign stat_rx_pcsl_number_10           = 1'b0;
  assign stat_rx_pcsl_number_11           = 1'b0;
  assign stat_rx_pcsl_number_12           = 1'b0;
  assign stat_rx_pcsl_number_13           = 1'b0;
  assign stat_rx_pcsl_number_14           = 1'b0;
  assign stat_rx_pcsl_number_15           = 1'b0;
  assign stat_rx_pcsl_number_16           = 1'b0;
  assign stat_rx_pcsl_number_17           = 1'b0;
  assign stat_rx_pcsl_number_18           = 1'b0;
  assign stat_rx_pcsl_number_19           = 1'b0;
  assign stat_rx_pcsl_number_2            = 1'b0;
  assign stat_rx_pcsl_number_3            = 1'b0;
  assign stat_rx_pcsl_number_4            = 1'b0;
  assign stat_rx_pcsl_number_5            = 1'b0;
  assign stat_rx_pcsl_number_6            = 1'b0;
  assign stat_rx_pcsl_number_7            = 1'b0;
  assign stat_rx_pcsl_number_8            = 1'b0;
  assign stat_rx_pcsl_number_9            = 1'b0;
  assign stat_tx_bad_fcs                  = 1'b0;
  assign stat_tx_broadcast                = 1'b0;
  assign stat_tx_frame_error              = 1'b0;
  assign stat_tx_local_fault              = 1'b0;
  assign stat_tx_multicast                = 1'b0;
  assign stat_tx_packet_1024_1518_bytes   = 1'b0;
  assign stat_tx_packet_128_255_bytes     = 1'b0;
  assign stat_tx_packet_1519_1522_bytes   = 1'b0;
  assign stat_tx_packet_1523_1548_bytes   = 1'b0;
  assign stat_tx_packet_1549_2047_bytes   = 1'b0;
  assign stat_tx_packet_2048_4095_bytes   = 1'b0;
  assign stat_tx_packet_256_511_bytes     = 1'b0;
  assign stat_tx_packet_4096_8191_bytes   = 1'b0;
  assign stat_tx_packet_512_1023_bytes    = 1'b0;
  assign stat_tx_packet_64_bytes          = 1'b0;
  assign stat_tx_packet_65_127_bytes      = 1'b0;
  assign stat_tx_packet_8192_9215_bytes   = 1'b0;
  assign stat_tx_packet_large             = 1'b0;
  assign stat_tx_packet_small             = 1'b0;
  assign stat_tx_total_bytes              = 1'b0;
  assign stat_tx_total_good_bytes         = 1'b0;
  assign stat_tx_total_good_packets       = 1'b0;
  assign stat_tx_total_packets            = 1'b0;
  assign stat_tx_unicast                  = 1'b0;
  assign stat_tx_vlan                     = 1'b0;

  // ---- 功能引脚 ----
  assign gt_txusrclk2                     = sim_clk;
  assign gt_rxusrclk2                     = sim_clk;
  assign rx_axis_tvalid                   = sim_rx_valid;
  assign rx_axis_tdata                    = sim_rx_data;
  assign rx_axis_tlast                    = sim_rx_last;
  assign rx_axis_tkeep                    = sim_rx_keep;
  assign rx_axis_tuser                    = 1'b0;
  assign tx_axis_tready                   = 1'b1;
  assign usr_rx_reset                    = sim_rst_act;
  assign usr_tx_reset                    = sim_rst_act;
  assign stat_rx_aligned                  = 1'b1;

endmodule

// ============================================================================
// cmac_usplus_b —— CMAC US+ 仿真桩（仅 xsim，不参与综合）
//   端口表自 cmac_b_if 例化自动提取；链路恒 up、无 fault、无复位
// ============================================================================
module cmac_usplus_b (
  input  wire             sys_reset,
  input  wire             init_clk,
  input  wire             gt_ref_clk_p,
  input  wire             gt_ref_clk_n,
  output wire [3:0]       gt_txp_out,
  output wire [3:0]       gt_txn_out,
  input  wire [3:0]       gt_rxp_in,
  input  wire [3:0]       gt_rxn_in,
  output wire             gt_txusrclk2,
  output wire             gt_rxusrclk2,
  input  wire [11:0]      gt_loopback_in,
  output wire             gt_ref_clk_out,
  output wire [3:0]       gt_rxrecclkout,
  output wire [3:0]       gt_powergoodout,
  input  wire             gtwiz_reset_tx_datapath,
  input  wire             gtwiz_reset_rx_datapath,
  output wire             rx_axis_tvalid,
  output wire [511:0]     rx_axis_tdata,
  output wire             rx_axis_tlast,
  output wire [63:0]      rx_axis_tkeep,
  output wire             rx_axis_tuser,
  output wire             tx_axis_tready,
  input  wire             tx_axis_tvalid,
  input  wire [511:0]     tx_axis_tdata,
  input  wire             tx_axis_tlast,
  input  wire [63:0]      tx_axis_tkeep,
  input  wire             tx_axis_tuser,
  input  wire             ctl_tx_rsfec_enable,
  input  wire             ctl_rx_rsfec_enable,
  input  wire             ctl_rsfec_ieee_error_indication_mode,
  input  wire             ctl_rx_rsfec_enable_correction,
  input  wire             ctl_rx_rsfec_enable_indication,
  output wire             stat_rx_rsfec_am_lock0,
  output wire             stat_rx_rsfec_am_lock1,
  output wire             stat_rx_rsfec_am_lock2,
  output wire             stat_rx_rsfec_am_lock3,
  output wire             stat_rx_rsfec_corrected_cw_inc,
  output wire             stat_rx_rsfec_cw_inc,
  output wire [2:0]       stat_rx_rsfec_err_count0_inc,
  output wire [2:0]       stat_rx_rsfec_err_count1_inc,
  output wire [2:0]       stat_rx_rsfec_err_count2_inc,
  output wire [2:0]       stat_rx_rsfec_err_count3_inc,
  output wire             stat_rx_rsfec_hi_ser,
  output wire             stat_rx_rsfec_lane_alignment_status,
  output wire [13:0]      stat_rx_rsfec_lane_fill_0,
  output wire [13:0]      stat_rx_rsfec_lane_fill_1,
  output wire [13:0]      stat_rx_rsfec_lane_fill_2,
  output wire [13:0]      stat_rx_rsfec_lane_fill_3,
  output wire [7:0]       stat_rx_rsfec_lane_mapping,
  output wire             stat_rx_rsfec_uncorrected_cw_inc,
  input  wire             ctl_tx_enable,
  input  wire             ctl_tx_send_idle,
  input  wire             ctl_tx_send_rfi,
  input  wire             ctl_tx_send_lfi,
  input  wire             ctl_tx_test_pattern,
  input  wire             core_tx_reset,
  input  wire             ctl_rx_enable,
  input  wire             ctl_rx_force_resync,
  input  wire             ctl_rx_test_pattern,
  input  wire             core_rx_reset,
  input  wire             rx_clk,
  output wire             usr_rx_reset,
  output wire             usr_tx_reset,
  output wire             tx_ovfout,
  output wire             tx_unfout,
  output wire [7:0]       rx_otn_bip8_0,
  output wire [7:0]       rx_otn_bip8_1,
  output wire [7:0]       rx_otn_bip8_2,
  output wire [7:0]       rx_otn_bip8_3,
  output wire [7:0]       rx_otn_bip8_4,
  output wire [65:0]      rx_otn_data_0,
  output wire [65:0]      rx_otn_data_1,
  output wire [65:0]      rx_otn_data_2,
  output wire [65:0]      rx_otn_data_3,
  output wire [65:0]      rx_otn_data_4,
  output wire             rx_otn_ena,
  output wire             rx_otn_lane0,
  output wire             rx_otn_vlmarker,
  output wire [55:0]      rx_preambleout,
  input  wire [55:0]      tx_preamblein,
  input  wire             core_drp_reset,
  input  wire             drp_clk,
  input  wire [9:0]       drp_addr,
  input  wire [15:0]      drp_di,
  input  wire             drp_en,
  output wire [15:0]      drp_do,
  output wire             drp_rdy,
  input  wire             drp_we,
  output wire             stat_rx_aligned,
  output wire             stat_rx_aligned_err,
  output wire [2:0]       stat_rx_bad_code,
  output wire [2:0]       stat_rx_bad_fcs,
  output wire             stat_rx_bad_preamble,
  output wire             stat_rx_bad_sfd,
  output wire             stat_rx_bip_err_0,
  output wire             stat_rx_bip_err_1,
  output wire             stat_rx_bip_err_10,
  output wire             stat_rx_bip_err_11,
  output wire             stat_rx_bip_err_12,
  output wire             stat_rx_bip_err_13,
  output wire             stat_rx_bip_err_14,
  output wire             stat_rx_bip_err_15,
  output wire             stat_rx_bip_err_16,
  output wire             stat_rx_bip_err_17,
  output wire             stat_rx_bip_err_18,
  output wire             stat_rx_bip_err_19,
  output wire             stat_rx_bip_err_2,
  output wire             stat_rx_bip_err_3,
  output wire             stat_rx_bip_err_4,
  output wire             stat_rx_bip_err_5,
  output wire             stat_rx_bip_err_6,
  output wire             stat_rx_bip_err_7,
  output wire             stat_rx_bip_err_8,
  output wire             stat_rx_bip_err_9,
  output wire [19:0]      stat_rx_block_lock,
  output wire             stat_rx_broadcast,
  output wire [2:0]       stat_rx_fragment,
  output wire [1:0]       stat_rx_framing_err_0,
  output wire [1:0]       stat_rx_framing_err_1,
  output wire [1:0]       stat_rx_framing_err_10,
  output wire [1:0]       stat_rx_framing_err_11,
  output wire [1:0]       stat_rx_framing_err_12,
  output wire [1:0]       stat_rx_framing_err_13,
  output wire [1:0]       stat_rx_framing_err_14,
  output wire [1:0]       stat_rx_framing_err_15,
  output wire [1:0]       stat_rx_framing_err_16,
  output wire [1:0]       stat_rx_framing_err_17,
  output wire [1:0]       stat_rx_framing_err_18,
  output wire [1:0]       stat_rx_framing_err_19,
  output wire [1:0]       stat_rx_framing_err_2,
  output wire [1:0]       stat_rx_framing_err_3,
  output wire [1:0]       stat_rx_framing_err_4,
  output wire [1:0]       stat_rx_framing_err_5,
  output wire [1:0]       stat_rx_framing_err_6,
  output wire [1:0]       stat_rx_framing_err_7,
  output wire [1:0]       stat_rx_framing_err_8,
  output wire [1:0]       stat_rx_framing_err_9,
  output wire             stat_rx_framing_err_valid_0,
  output wire             stat_rx_framing_err_valid_1,
  output wire             stat_rx_framing_err_valid_10,
  output wire             stat_rx_framing_err_valid_11,
  output wire             stat_rx_framing_err_valid_12,
  output wire             stat_rx_framing_err_valid_13,
  output wire             stat_rx_framing_err_valid_14,
  output wire             stat_rx_framing_err_valid_15,
  output wire             stat_rx_framing_err_valid_16,
  output wire             stat_rx_framing_err_valid_17,
  output wire             stat_rx_framing_err_valid_18,
  output wire             stat_rx_framing_err_valid_19,
  output wire             stat_rx_framing_err_valid_2,
  output wire             stat_rx_framing_err_valid_3,
  output wire             stat_rx_framing_err_valid_4,
  output wire             stat_rx_framing_err_valid_5,
  output wire             stat_rx_framing_err_valid_6,
  output wire             stat_rx_framing_err_valid_7,
  output wire             stat_rx_framing_err_valid_8,
  output wire             stat_rx_framing_err_valid_9,
  output wire             stat_rx_got_signal_os,
  output wire             stat_rx_hi_ber,
  output wire             stat_rx_inrangeerr,
  output wire             stat_rx_internal_local_fault,
  output wire             stat_rx_jabber,
  output wire             stat_rx_local_fault,
  output wire [19:0]      stat_rx_mf_err,
  output wire [19:0]      stat_rx_mf_len_err,
  output wire [19:0]      stat_rx_mf_repeat_err,
  output wire             stat_rx_misaligned,
  output wire             stat_rx_multicast,
  output wire             stat_rx_oversize,
  output wire             stat_rx_packet_1024_1518_bytes,
  output wire             stat_rx_packet_128_255_bytes,
  output wire             stat_rx_packet_1519_1522_bytes,
  output wire             stat_rx_packet_1523_1548_bytes,
  output wire             stat_rx_packet_1549_2047_bytes,
  output wire             stat_rx_packet_2048_4095_bytes,
  output wire             stat_rx_packet_256_511_bytes,
  output wire             stat_rx_packet_4096_8191_bytes,
  output wire             stat_rx_packet_512_1023_bytes,
  output wire             stat_rx_packet_64_bytes,
  output wire             stat_rx_packet_65_127_bytes,
  output wire             stat_rx_packet_8192_9215_bytes,
  output wire             stat_rx_packet_bad_fcs,
  output wire             stat_rx_packet_large,
  output wire [2:0]       stat_rx_packet_small,
  output wire             stat_rx_received_local_fault,
  output wire             stat_rx_remote_fault,
  output wire             stat_rx_status,
  output wire [2:0]       stat_rx_stomped_fcs,
  output wire [19:0]      stat_rx_synced,
  output wire [19:0]      stat_rx_synced_err,
  output wire [2:0]       stat_rx_test_pattern_mismatch,
  output wire             stat_rx_toolong,
  output wire [6:0]       stat_rx_total_bytes,
  output wire [13:0]      stat_rx_total_good_bytes,
  output wire             stat_rx_total_good_packets,
  output wire [2:0]       stat_rx_total_packets,
  output wire             stat_rx_truncated,
  output wire [2:0]       stat_rx_undersize,
  output wire             stat_rx_unicast,
  output wire             stat_rx_vlan,
  output wire [19:0]      stat_rx_pcsl_demuxed,
  output wire [4:0]       stat_rx_pcsl_number_0,
  output wire [4:0]       stat_rx_pcsl_number_1,
  output wire [4:0]       stat_rx_pcsl_number_10,
  output wire [4:0]       stat_rx_pcsl_number_11,
  output wire [4:0]       stat_rx_pcsl_number_12,
  output wire [4:0]       stat_rx_pcsl_number_13,
  output wire [4:0]       stat_rx_pcsl_number_14,
  output wire [4:0]       stat_rx_pcsl_number_15,
  output wire [4:0]       stat_rx_pcsl_number_16,
  output wire [4:0]       stat_rx_pcsl_number_17,
  output wire [4:0]       stat_rx_pcsl_number_18,
  output wire [4:0]       stat_rx_pcsl_number_19,
  output wire [4:0]       stat_rx_pcsl_number_2,
  output wire [4:0]       stat_rx_pcsl_number_3,
  output wire [4:0]       stat_rx_pcsl_number_4,
  output wire [4:0]       stat_rx_pcsl_number_5,
  output wire [4:0]       stat_rx_pcsl_number_6,
  output wire [4:0]       stat_rx_pcsl_number_7,
  output wire [4:0]       stat_rx_pcsl_number_8,
  output wire [4:0]       stat_rx_pcsl_number_9,
  output wire             stat_tx_bad_fcs,
  output wire             stat_tx_broadcast,
  output wire             stat_tx_frame_error,
  output wire             stat_tx_local_fault,
  output wire             stat_tx_multicast,
  output wire             stat_tx_packet_1024_1518_bytes,
  output wire             stat_tx_packet_128_255_bytes,
  output wire             stat_tx_packet_1519_1522_bytes,
  output wire             stat_tx_packet_1523_1548_bytes,
  output wire             stat_tx_packet_1549_2047_bytes,
  output wire             stat_tx_packet_2048_4095_bytes,
  output wire             stat_tx_packet_256_511_bytes,
  output wire             stat_tx_packet_4096_8191_bytes,
  output wire             stat_tx_packet_512_1023_bytes,
  output wire             stat_tx_packet_64_bytes,
  output wire             stat_tx_packet_65_127_bytes,
  output wire             stat_tx_packet_8192_9215_bytes,
  output wire             stat_tx_packet_large,
  output wire             stat_tx_packet_small,
  output wire [5:0]       stat_tx_total_bytes,
  output wire [13:0]      stat_tx_total_good_bytes,
  output wire             stat_tx_total_good_packets,
  output wire             stat_tx_total_packets,
  output wire             stat_tx_unicast,
  output wire             stat_tx_vlan
);

  // ---- 仿真时钟（真实为 GT 输出 322.269MHz，仿真取 100MHz）----
  reg  sim_clk = 1'b0;
  always #5.0 sim_clk = ~sim_clk;
  assign gt_txusrclk2 = sim_clk;
  assign gt_rxusrclk2 = sim_clk;

  // ---- 上电复位：给下游 SLR/CDC FIFO 一个复位脉冲（真实 IP 由 GT 复位产生）----
  reg  [3:0] sim_rst_cnt = 4'd15;
  always @(posedge sim_clk) if (sim_rst_cnt != 4'd0) sim_rst_cnt <= sim_rst_cnt - 4'd1;
  wire       sim_rst_act = (sim_rst_cnt != 4'd0);

  // ---- RX 注入（TB 层次引用写；CMAC RX 无 tready，无流控）----
  reg  [511:0] sim_rx_data  = 512'd0;
  reg  [ 63:0] sim_rx_keep  = 64'd0;
  reg          sim_rx_last  = 1'b0;
  reg          sim_rx_valid = 1'b0;

  // ---- TX 捕获 ----
  reg  [511:0] sim_tx_data  = 512'd0;
  reg  [ 63:0] sim_tx_keep  = 64'd0;
  reg          sim_tx_last  = 1'b0;
  reg          sim_tx_valid = 1'b0;
  always @(posedge sim_clk) begin
    sim_tx_valid <= tx_axis_tvalid;
    if (tx_axis_tvalid) begin
      sim_tx_data <= tx_axis_tdata;
      sim_tx_keep <= tx_axis_tkeep;
      sim_tx_last <= tx_axis_tlast;
    end
  end

  // ---- 其余输出恒 0 ----
  assign gt_txp_out                       = 1'b0;
  assign gt_txn_out                       = 1'b0;
  assign gt_ref_clk_out                   = 1'b0;
  assign gt_rxrecclkout                   = 1'b0;
  assign gt_powergoodout                  = 1'b0;
  assign stat_rx_rsfec_am_lock0           = 1'b0;
  assign stat_rx_rsfec_am_lock1           = 1'b0;
  assign stat_rx_rsfec_am_lock2           = 1'b0;
  assign stat_rx_rsfec_am_lock3           = 1'b0;
  assign stat_rx_rsfec_corrected_cw_inc   = 1'b0;
  assign stat_rx_rsfec_cw_inc             = 1'b0;
  assign stat_rx_rsfec_err_count0_inc     = 1'b0;
  assign stat_rx_rsfec_err_count1_inc     = 1'b0;
  assign stat_rx_rsfec_err_count2_inc     = 1'b0;
  assign stat_rx_rsfec_err_count3_inc     = 1'b0;
  assign stat_rx_rsfec_hi_ser             = 1'b0;
  assign stat_rx_rsfec_lane_alignment_status = 1'b0;
  assign stat_rx_rsfec_lane_fill_0        = 1'b0;
  assign stat_rx_rsfec_lane_fill_1        = 1'b0;
  assign stat_rx_rsfec_lane_fill_2        = 1'b0;
  assign stat_rx_rsfec_lane_fill_3        = 1'b0;
  assign stat_rx_rsfec_lane_mapping       = 1'b0;
  assign stat_rx_rsfec_uncorrected_cw_inc = 1'b0;
  assign tx_ovfout                        = 1'b0;
  assign tx_unfout                        = 1'b0;
  assign rx_otn_bip8_0                    = 1'b0;
  assign rx_otn_bip8_1                    = 1'b0;
  assign rx_otn_bip8_2                    = 1'b0;
  assign rx_otn_bip8_3                    = 1'b0;
  assign rx_otn_bip8_4                    = 1'b0;
  assign rx_otn_data_0                    = 1'b0;
  assign rx_otn_data_1                    = 1'b0;
  assign rx_otn_data_2                    = 1'b0;
  assign rx_otn_data_3                    = 1'b0;
  assign rx_otn_data_4                    = 1'b0;
  assign rx_otn_ena                       = 1'b0;
  assign rx_otn_lane0                     = 1'b0;
  assign rx_otn_vlmarker                  = 1'b0;
  assign rx_preambleout                   = 1'b0;
  assign drp_do                           = 1'b0;
  assign drp_rdy                          = 1'b0;
  assign stat_rx_aligned_err              = 1'b0;
  assign stat_rx_bad_code                 = 1'b0;
  assign stat_rx_bad_fcs                  = 1'b0;
  assign stat_rx_bad_preamble             = 1'b0;
  assign stat_rx_bad_sfd                  = 1'b0;
  assign stat_rx_bip_err_0                = 1'b0;
  assign stat_rx_bip_err_1                = 1'b0;
  assign stat_rx_bip_err_10               = 1'b0;
  assign stat_rx_bip_err_11               = 1'b0;
  assign stat_rx_bip_err_12               = 1'b0;
  assign stat_rx_bip_err_13               = 1'b0;
  assign stat_rx_bip_err_14               = 1'b0;
  assign stat_rx_bip_err_15               = 1'b0;
  assign stat_rx_bip_err_16               = 1'b0;
  assign stat_rx_bip_err_17               = 1'b0;
  assign stat_rx_bip_err_18               = 1'b0;
  assign stat_rx_bip_err_19               = 1'b0;
  assign stat_rx_bip_err_2                = 1'b0;
  assign stat_rx_bip_err_3                = 1'b0;
  assign stat_rx_bip_err_4                = 1'b0;
  assign stat_rx_bip_err_5                = 1'b0;
  assign stat_rx_bip_err_6                = 1'b0;
  assign stat_rx_bip_err_7                = 1'b0;
  assign stat_rx_bip_err_8                = 1'b0;
  assign stat_rx_bip_err_9                = 1'b0;
  assign stat_rx_block_lock               = 1'b0;
  assign stat_rx_broadcast                = 1'b0;
  assign stat_rx_fragment                 = 1'b0;
  assign stat_rx_framing_err_0            = 1'b0;
  assign stat_rx_framing_err_1            = 1'b0;
  assign stat_rx_framing_err_10           = 1'b0;
  assign stat_rx_framing_err_11           = 1'b0;
  assign stat_rx_framing_err_12           = 1'b0;
  assign stat_rx_framing_err_13           = 1'b0;
  assign stat_rx_framing_err_14           = 1'b0;
  assign stat_rx_framing_err_15           = 1'b0;
  assign stat_rx_framing_err_16           = 1'b0;
  assign stat_rx_framing_err_17           = 1'b0;
  assign stat_rx_framing_err_18           = 1'b0;
  assign stat_rx_framing_err_19           = 1'b0;
  assign stat_rx_framing_err_2            = 1'b0;
  assign stat_rx_framing_err_3            = 1'b0;
  assign stat_rx_framing_err_4            = 1'b0;
  assign stat_rx_framing_err_5            = 1'b0;
  assign stat_rx_framing_err_6            = 1'b0;
  assign stat_rx_framing_err_7            = 1'b0;
  assign stat_rx_framing_err_8            = 1'b0;
  assign stat_rx_framing_err_9            = 1'b0;
  assign stat_rx_framing_err_valid_0      = 1'b0;
  assign stat_rx_framing_err_valid_1      = 1'b0;
  assign stat_rx_framing_err_valid_10     = 1'b0;
  assign stat_rx_framing_err_valid_11     = 1'b0;
  assign stat_rx_framing_err_valid_12     = 1'b0;
  assign stat_rx_framing_err_valid_13     = 1'b0;
  assign stat_rx_framing_err_valid_14     = 1'b0;
  assign stat_rx_framing_err_valid_15     = 1'b0;
  assign stat_rx_framing_err_valid_16     = 1'b0;
  assign stat_rx_framing_err_valid_17     = 1'b0;
  assign stat_rx_framing_err_valid_18     = 1'b0;
  assign stat_rx_framing_err_valid_19     = 1'b0;
  assign stat_rx_framing_err_valid_2      = 1'b0;
  assign stat_rx_framing_err_valid_3      = 1'b0;
  assign stat_rx_framing_err_valid_4      = 1'b0;
  assign stat_rx_framing_err_valid_5      = 1'b0;
  assign stat_rx_framing_err_valid_6      = 1'b0;
  assign stat_rx_framing_err_valid_7      = 1'b0;
  assign stat_rx_framing_err_valid_8      = 1'b0;
  assign stat_rx_framing_err_valid_9      = 1'b0;
  assign stat_rx_got_signal_os            = 1'b0;
  assign stat_rx_hi_ber                   = 1'b0;
  assign stat_rx_inrangeerr               = 1'b0;
  assign stat_rx_internal_local_fault     = 1'b0;
  assign stat_rx_jabber                   = 1'b0;
  assign stat_rx_local_fault              = 1'b0;
  assign stat_rx_mf_err                   = 1'b0;
  assign stat_rx_mf_len_err               = 1'b0;
  assign stat_rx_mf_repeat_err            = 1'b0;
  assign stat_rx_misaligned               = 1'b0;
  assign stat_rx_multicast                = 1'b0;
  assign stat_rx_oversize                 = 1'b0;
  assign stat_rx_packet_1024_1518_bytes   = 1'b0;
  assign stat_rx_packet_128_255_bytes     = 1'b0;
  assign stat_rx_packet_1519_1522_bytes   = 1'b0;
  assign stat_rx_packet_1523_1548_bytes   = 1'b0;
  assign stat_rx_packet_1549_2047_bytes   = 1'b0;
  assign stat_rx_packet_2048_4095_bytes   = 1'b0;
  assign stat_rx_packet_256_511_bytes     = 1'b0;
  assign stat_rx_packet_4096_8191_bytes   = 1'b0;
  assign stat_rx_packet_512_1023_bytes    = 1'b0;
  assign stat_rx_packet_64_bytes          = 1'b0;
  assign stat_rx_packet_65_127_bytes      = 1'b0;
  assign stat_rx_packet_8192_9215_bytes   = 1'b0;
  assign stat_rx_packet_bad_fcs           = 1'b0;
  assign stat_rx_packet_large             = 1'b0;
  assign stat_rx_packet_small             = 1'b0;
  assign stat_rx_received_local_fault     = 1'b0;
  assign stat_rx_remote_fault             = 1'b0;
  assign stat_rx_status                  = 1'b1;   // PCS 已对齐且非 HI_BER
  assign stat_rx_stomped_fcs              = 1'b0;
  assign stat_rx_synced                   = 1'b0;
  assign stat_rx_synced_err               = 1'b0;
  assign stat_rx_test_pattern_mismatch    = 1'b0;
  assign stat_rx_toolong                  = 1'b0;
  assign stat_rx_total_bytes              = 1'b0;
  assign stat_rx_total_good_bytes         = 1'b0;
  assign stat_rx_total_good_packets       = 1'b0;
  assign stat_rx_total_packets            = 1'b0;
  assign stat_rx_truncated                = 1'b0;
  assign stat_rx_undersize                = 1'b0;
  assign stat_rx_unicast                  = 1'b0;
  assign stat_rx_vlan                     = 1'b0;
  assign stat_rx_pcsl_demuxed             = 1'b0;
  assign stat_rx_pcsl_number_0            = 1'b0;
  assign stat_rx_pcsl_number_1            = 1'b0;
  assign stat_rx_pcsl_number_10           = 1'b0;
  assign stat_rx_pcsl_number_11           = 1'b0;
  assign stat_rx_pcsl_number_12           = 1'b0;
  assign stat_rx_pcsl_number_13           = 1'b0;
  assign stat_rx_pcsl_number_14           = 1'b0;
  assign stat_rx_pcsl_number_15           = 1'b0;
  assign stat_rx_pcsl_number_16           = 1'b0;
  assign stat_rx_pcsl_number_17           = 1'b0;
  assign stat_rx_pcsl_number_18           = 1'b0;
  assign stat_rx_pcsl_number_19           = 1'b0;
  assign stat_rx_pcsl_number_2            = 1'b0;
  assign stat_rx_pcsl_number_3            = 1'b0;
  assign stat_rx_pcsl_number_4            = 1'b0;
  assign stat_rx_pcsl_number_5            = 1'b0;
  assign stat_rx_pcsl_number_6            = 1'b0;
  assign stat_rx_pcsl_number_7            = 1'b0;
  assign stat_rx_pcsl_number_8            = 1'b0;
  assign stat_rx_pcsl_number_9            = 1'b0;
  assign stat_tx_bad_fcs                  = 1'b0;
  assign stat_tx_broadcast                = 1'b0;
  assign stat_tx_frame_error              = 1'b0;
  assign stat_tx_local_fault              = 1'b0;
  assign stat_tx_multicast                = 1'b0;
  assign stat_tx_packet_1024_1518_bytes   = 1'b0;
  assign stat_tx_packet_128_255_bytes     = 1'b0;
  assign stat_tx_packet_1519_1522_bytes   = 1'b0;
  assign stat_tx_packet_1523_1548_bytes   = 1'b0;
  assign stat_tx_packet_1549_2047_bytes   = 1'b0;
  assign stat_tx_packet_2048_4095_bytes   = 1'b0;
  assign stat_tx_packet_256_511_bytes     = 1'b0;
  assign stat_tx_packet_4096_8191_bytes   = 1'b0;
  assign stat_tx_packet_512_1023_bytes    = 1'b0;
  assign stat_tx_packet_64_bytes          = 1'b0;
  assign stat_tx_packet_65_127_bytes      = 1'b0;
  assign stat_tx_packet_8192_9215_bytes   = 1'b0;
  assign stat_tx_packet_large             = 1'b0;
  assign stat_tx_packet_small             = 1'b0;
  assign stat_tx_total_bytes              = 1'b0;
  assign stat_tx_total_good_bytes         = 1'b0;
  assign stat_tx_total_good_packets       = 1'b0;
  assign stat_tx_total_packets            = 1'b0;
  assign stat_tx_unicast                  = 1'b0;
  assign stat_tx_vlan                     = 1'b0;

  // ---- 功能引脚 ----
  assign gt_txusrclk2                     = sim_clk;
  assign gt_rxusrclk2                     = sim_clk;
  assign rx_axis_tvalid                   = sim_rx_valid;
  assign rx_axis_tdata                    = sim_rx_data;
  assign rx_axis_tlast                    = sim_rx_last;
  assign rx_axis_tkeep                    = sim_rx_keep;
  assign rx_axis_tuser                    = 1'b0;
  assign tx_axis_tready                   = 1'b1;
  assign usr_rx_reset                    = sim_rst_act;
  assign usr_tx_reset                    = sim_rst_act;
  assign stat_rx_aligned                  = 1'b1;

endmodule

