// -----------------------------------------------------------------------------
// File Name   : cmac_b_if.v
// Module Name : cmac_b_if
// Author      : LiXintao
// Created     : 2026-09-13
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : CMAC B接口封装，连接GT、AXIS和QSFP控制信号
// Note        : 启用硬核RS-FEC，RX usr输出帧错误标志
//               stat_link_up=0可能原因：
//                 1. 上电初始化、系统/GT复位或恢复中。
//                 2. QSFP模块未插入、未插牢，或在位检测引脚接触异常。
//                 3. PCS未对齐或处于高误码率状态；检查线缆、模块、对端电源/发送状态、双方速率/模式及信号质量。
//                 4. FEC未对齐：建链中、双方RS-FEC配置不一致或部分lane异常。
//                 5. local_fault=1：本端RX对齐/误码故障，或收到LF故障码字。
//                 6. remote_fault=1：收到对端RF；检查本端TX到对端RX方向及对端状态。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module cmac_b_if #(
    parameter integer LedHalfPeriodCycles = 50_000_000
) (
    input wire init_clk,
    input wire arst,

    output wire [3:0] gt_txp_out,
    output wire [3:0] gt_txn_out,
    input  wire [3:0] gt_rxp_in,
    input  wire [3:0] gt_rxn_in,

    input  wire gt_ref_clk_p,
    input  wire gt_ref_clk_n,
    output wire gt_txusrclk,
    output wire gt_rxusrclk,

    output wire         axis_mvalid,
    output wire [511:0] axis_mdata,
    output wire         axis_mlast,
    output wire [ 63:0] axis_mkeep,
    output wire         axis_musr,

    input  wire         axis_svalid,
    input  wire [511:0] axis_sdata,
    input  wire         axis_slast,
    input  wire [ 63:0] axis_skeep,
    input  wire         axis_susr,
    output wire         axis_sready,

    output wire gt_tx_arst,
    output wire gt_rx_arst,

    output wire qsfp_reset_n,
    output wire qsfp_low_power_mode,
    output wire qsfp_select_n,
    input  wire qsfp_present_n,
    output wire qsfp_led,

    output wire stat_link_up  // gt_rxusrclk域链路状态
);

  // CMAC硬核提供GT及AXIS收发接口，启用RS-FEC。
  // gt_rxusrclk域同步模块在位信号，并组合PCS、FEC与故障状态生成链路指示。
  // init_clk域同步模块在位信号，计数生成QSFP指示灯。

  // 参数范围检查
  initial begin
    if (LedHalfPeriodCycles < 0) begin
      $display("错误：cmac_b_if：LedHalfPeriodCycles必须不小于0");
      $finish;
    end
  end

  // 内部常量
  localparam integer LedCountWidth = (LedHalfPeriodCycles <= 1) ? 1 : $clog2(LedHalfPeriodCycles);
  localparam [LedCountWidth-1:0] LedCountMax =
      (LedHalfPeriodCycles <= 1) ? {LedCountWidth{1'b0}} : (LedHalfPeriodCycles - 1);

  // init_clk域指示灯
  reg  [LedCountWidth-1:0] init_led_count;
  reg                      init_led_level;
  (* ASYNC_REG = "TRUE" *)reg  [              1:0] init_qsfp_present_sync;

  // gt_rxusrclk域链路状态
  wire                     stat_gt_rx_pcs_up;
  wire                     stat_gt_rx_local_fault;
  wire                     stat_gt_rx_remote_fault;
  wire                     stat_gt_rx_fec_aligned;
  wire                     gt_rx_link_arst;
  (* ASYNC_REG = "TRUE" *)reg  [              1:0] gt_rx_qsfp_present_sync;

  // gt_rxusrclk域链路状态
  assign gt_rx_link_arst = arst | gt_rx_arst;
  always @(posedge gt_rxusrclk or posedge gt_rx_link_arst) begin
    if (gt_rx_link_arst) gt_rx_qsfp_present_sync <= 2'b00;
    else gt_rx_qsfp_present_sync <= {gt_rx_qsfp_present_sync[0], !qsfp_present_n};
  end
  assign stat_link_up = gt_rx_qsfp_present_sync[1] & stat_gt_rx_pcs_up &
                        stat_gt_rx_fec_aligned &
                        ~stat_gt_rx_local_fault & ~stat_gt_rx_remote_fault;

  // init_clk域指示灯
  //// 同步模块在位信号
  always @(posedge init_clk) begin
    if (arst) begin
      init_qsfp_present_sync <= 2'b00;
    end else begin
      init_qsfp_present_sync <= {init_qsfp_present_sync[0], !qsfp_present_n};
    end
  end
  //// 计数器
  always @(posedge init_clk) begin
    if (arst || !init_qsfp_present_sync[1]) begin
      init_led_count <= {LedCountWidth{1'b0}};
      init_led_level <= 1'b0;
    end else if (init_led_count == LedCountMax) begin
      init_led_count <= {LedCountWidth{1'b0}};
      init_led_level <= ~init_led_level;
    end else begin
      init_led_count <= init_led_count + 1'b1;
    end
  end
  assign qsfp_led            = init_led_level;

  // QSFP固定控制
  assign qsfp_reset_n        = 1'b1;  // 默认模块不复位
  assign qsfp_low_power_mode = 1'b0;  // 默认高功耗模式
  assign qsfp_select_n       = 1'b1;  // 默认屏蔽IIC通信

  // CMAC硬核接口
  cmac_usplus_b cmac_usplus_b_inst (
      // 系统时钟与复位
      .sys_reset(arst),
      .init_clk (init_clk),

      // GT接口与用户时钟
      .gt_ref_clk_p           (gt_ref_clk_p),
      .gt_ref_clk_n           (gt_ref_clk_n),
      .gt_txp_out             (gt_txp_out),
      .gt_txn_out             (gt_txn_out),
      .gt_rxp_in              (gt_rxp_in),
      .gt_rxn_in              (gt_rxn_in),
      .gt_txusrclk2           (gt_txusrclk),
      .gt_rxusrclk2           (gt_rxusrclk),
      .gt_loopback_in         (12'd0),
      .gt_ref_clk_out         (),
      .gt_rxrecclkout         (),
      .gt_powergoodout        (),
      .gtwiz_reset_tx_datapath(1'b0),
      .gtwiz_reset_rx_datapath(1'b0),

      // AXIS收发接口
      .rx_axis_tvalid(axis_mvalid),
      .rx_axis_tdata (axis_mdata),
      .rx_axis_tlast (axis_mlast),
      .rx_axis_tkeep (axis_mkeep),
      .rx_axis_tuser (axis_musr),
      .tx_axis_tready(axis_sready),
      .tx_axis_tvalid(axis_svalid),
      .tx_axis_tdata (axis_sdata),
      .tx_axis_tlast (axis_slast),
      .tx_axis_tkeep (axis_skeep),
      .tx_axis_tuser (axis_susr),

      // RS-FEC控制与状态
      .ctl_tx_rsfec_enable                 (1'b1),
      .ctl_rx_rsfec_enable                 (1'b1),
      .ctl_rsfec_ieee_error_indication_mode(1'b0),
      .ctl_rx_rsfec_enable_correction      (1'b1),
      .ctl_rx_rsfec_enable_indication      (1'b1),
      .stat_rx_rsfec_am_lock0              (),
      .stat_rx_rsfec_am_lock1              (),
      .stat_rx_rsfec_am_lock2              (),
      .stat_rx_rsfec_am_lock3              (),
      .stat_rx_rsfec_corrected_cw_inc      (),
      .stat_rx_rsfec_cw_inc                (),
      .stat_rx_rsfec_err_count0_inc        (),
      .stat_rx_rsfec_err_count1_inc        (),
      .stat_rx_rsfec_err_count2_inc        (),
      .stat_rx_rsfec_err_count3_inc        (),
      .stat_rx_rsfec_hi_ser                (),
      .stat_rx_rsfec_lane_alignment_status (stat_gt_rx_fec_aligned),
      .stat_rx_rsfec_lane_fill_0           (),
      .stat_rx_rsfec_lane_fill_1           (),
      .stat_rx_rsfec_lane_fill_2           (),
      .stat_rx_rsfec_lane_fill_3           (),
      .stat_rx_rsfec_lane_mapping          (),
      .stat_rx_rsfec_uncorrected_cw_inc    (),

      // 收发控制
      .ctl_tx_enable      (1'b1),
      .ctl_tx_send_idle   (1'b0),
      .ctl_tx_send_rfi    (1'b0),
      .ctl_tx_send_lfi    (1'b0),
      .ctl_tx_test_pattern(1'b0),
      .core_tx_reset      (1'b0),
      .ctl_rx_enable      (1'b1),
      .ctl_rx_force_resync(1'b0),
      .ctl_rx_test_pattern(1'b0),
      .core_rx_reset      (1'b0),
      .rx_clk             (gt_rxusrclk),

      // 用户复位与发送FIFO状态
      .usr_rx_reset(gt_rx_arst),
      .usr_tx_reset(gt_tx_arst),
      .tx_ovfout   (),
      .tx_unfout   (),

      // OTN / 前导码接口
      .rx_otn_bip8_0  (),
      .rx_otn_bip8_1  (),
      .rx_otn_bip8_2  (),
      .rx_otn_bip8_3  (),
      .rx_otn_bip8_4  (),
      .rx_otn_data_0  (),
      .rx_otn_data_1  (),
      .rx_otn_data_2  (),
      .rx_otn_data_3  (),
      .rx_otn_data_4  (),
      .rx_otn_ena     (),
      .rx_otn_lane0   (),
      .rx_otn_vlmarker(),
      .rx_preambleout (),
      .tx_preamblein  (56'd0),

      // DRP
      .core_drp_reset(arst),
      .drp_clk       (init_clk),
      .drp_addr      (10'd0),
      .drp_di        (16'd0),
      .drp_en        (1'b0),
      .drp_do        (),
      .drp_rdy       (),
      .drp_we        (1'b0),

      // RX 链路 / PCS 状态
      .stat_rx_aligned               (),
      .stat_rx_aligned_err           (),
      .stat_rx_bad_code              (),
      .stat_rx_bad_fcs               (),
      .stat_rx_bad_preamble          (),
      .stat_rx_bad_sfd               (),
      .stat_rx_bip_err_0             (),
      .stat_rx_bip_err_1             (),
      .stat_rx_bip_err_10            (),
      .stat_rx_bip_err_11            (),
      .stat_rx_bip_err_12            (),
      .stat_rx_bip_err_13            (),
      .stat_rx_bip_err_14            (),
      .stat_rx_bip_err_15            (),
      .stat_rx_bip_err_16            (),
      .stat_rx_bip_err_17            (),
      .stat_rx_bip_err_18            (),
      .stat_rx_bip_err_19            (),
      .stat_rx_bip_err_2             (),
      .stat_rx_bip_err_3             (),
      .stat_rx_bip_err_4             (),
      .stat_rx_bip_err_5             (),
      .stat_rx_bip_err_6             (),
      .stat_rx_bip_err_7             (),
      .stat_rx_bip_err_8             (),
      .stat_rx_bip_err_9             (),
      .stat_rx_block_lock            (),
      .stat_rx_broadcast             (),
      .stat_rx_fragment              (),
      .stat_rx_framing_err_0         (),
      .stat_rx_framing_err_1         (),
      .stat_rx_framing_err_10        (),
      .stat_rx_framing_err_11        (),
      .stat_rx_framing_err_12        (),
      .stat_rx_framing_err_13        (),
      .stat_rx_framing_err_14        (),
      .stat_rx_framing_err_15        (),
      .stat_rx_framing_err_16        (),
      .stat_rx_framing_err_17        (),
      .stat_rx_framing_err_18        (),
      .stat_rx_framing_err_19        (),
      .stat_rx_framing_err_2         (),
      .stat_rx_framing_err_3         (),
      .stat_rx_framing_err_4         (),
      .stat_rx_framing_err_5         (),
      .stat_rx_framing_err_6         (),
      .stat_rx_framing_err_7         (),
      .stat_rx_framing_err_8         (),
      .stat_rx_framing_err_9         (),
      .stat_rx_framing_err_valid_0   (),
      .stat_rx_framing_err_valid_1   (),
      .stat_rx_framing_err_valid_10  (),
      .stat_rx_framing_err_valid_11  (),
      .stat_rx_framing_err_valid_12  (),
      .stat_rx_framing_err_valid_13  (),
      .stat_rx_framing_err_valid_14  (),
      .stat_rx_framing_err_valid_15  (),
      .stat_rx_framing_err_valid_16  (),
      .stat_rx_framing_err_valid_17  (),
      .stat_rx_framing_err_valid_18  (),
      .stat_rx_framing_err_valid_19  (),
      .stat_rx_framing_err_valid_2   (),
      .stat_rx_framing_err_valid_3   (),
      .stat_rx_framing_err_valid_4   (),
      .stat_rx_framing_err_valid_5   (),
      .stat_rx_framing_err_valid_6   (),
      .stat_rx_framing_err_valid_7   (),
      .stat_rx_framing_err_valid_8   (),
      .stat_rx_framing_err_valid_9   (),
      .stat_rx_got_signal_os         (),
      .stat_rx_hi_ber                (),
      .stat_rx_inrangeerr            (),
      .stat_rx_internal_local_fault  (),
      .stat_rx_jabber                (),
      .stat_rx_local_fault           (stat_gt_rx_local_fault),
      .stat_rx_mf_err                (),
      .stat_rx_mf_len_err            (),
      .stat_rx_mf_repeat_err         (),
      .stat_rx_misaligned            (),
      .stat_rx_multicast             (),
      .stat_rx_oversize              (),
      .stat_rx_packet_1024_1518_bytes(),
      .stat_rx_packet_128_255_bytes  (),
      .stat_rx_packet_1519_1522_bytes(),
      .stat_rx_packet_1523_1548_bytes(),
      .stat_rx_packet_1549_2047_bytes(),
      .stat_rx_packet_2048_4095_bytes(),
      .stat_rx_packet_256_511_bytes  (),
      .stat_rx_packet_4096_8191_bytes(),
      .stat_rx_packet_512_1023_bytes (),
      .stat_rx_packet_64_bytes       (),
      .stat_rx_packet_65_127_bytes   (),
      .stat_rx_packet_8192_9215_bytes(),
      .stat_rx_packet_bad_fcs        (),
      .stat_rx_packet_large          (),
      .stat_rx_packet_small          (),
      .stat_rx_received_local_fault  (),
      .stat_rx_remote_fault          (stat_gt_rx_remote_fault),
      .stat_rx_status                (stat_gt_rx_pcs_up),
      .stat_rx_stomped_fcs           (),
      .stat_rx_synced                (),
      .stat_rx_synced_err            (),
      .stat_rx_test_pattern_mismatch (),
      .stat_rx_toolong               (),
      .stat_rx_total_bytes           (),
      .stat_rx_total_good_bytes      (),
      .stat_rx_total_good_packets    (),
      .stat_rx_total_packets         (),
      .stat_rx_truncated             (),
      .stat_rx_undersize             (),
      .stat_rx_unicast               (),
      .stat_rx_vlan                  (),
      .stat_rx_pcsl_demuxed          (),
      .stat_rx_pcsl_number_0         (),
      .stat_rx_pcsl_number_1         (),
      .stat_rx_pcsl_number_10        (),
      .stat_rx_pcsl_number_11        (),
      .stat_rx_pcsl_number_12        (),
      .stat_rx_pcsl_number_13        (),
      .stat_rx_pcsl_number_14        (),
      .stat_rx_pcsl_number_15        (),
      .stat_rx_pcsl_number_16        (),
      .stat_rx_pcsl_number_17        (),
      .stat_rx_pcsl_number_18        (),
      .stat_rx_pcsl_number_19        (),
      .stat_rx_pcsl_number_2         (),
      .stat_rx_pcsl_number_3         (),
      .stat_rx_pcsl_number_4         (),
      .stat_rx_pcsl_number_5         (),
      .stat_rx_pcsl_number_6         (),
      .stat_rx_pcsl_number_7         (),
      .stat_rx_pcsl_number_8         (),
      .stat_rx_pcsl_number_9         (),
      .stat_tx_bad_fcs               (),
      .stat_tx_broadcast             (),
      .stat_tx_frame_error           (),
      .stat_tx_local_fault           (),
      .stat_tx_multicast             (),
      .stat_tx_packet_1024_1518_bytes(),
      .stat_tx_packet_128_255_bytes  (),
      .stat_tx_packet_1519_1522_bytes(),
      .stat_tx_packet_1523_1548_bytes(),
      .stat_tx_packet_1549_2047_bytes(),
      .stat_tx_packet_2048_4095_bytes(),
      .stat_tx_packet_256_511_bytes  (),
      .stat_tx_packet_4096_8191_bytes(),
      .stat_tx_packet_512_1023_bytes (),
      .stat_tx_packet_64_bytes       (),
      .stat_tx_packet_65_127_bytes   (),
      .stat_tx_packet_8192_9215_bytes(),
      .stat_tx_packet_large          (),
      .stat_tx_packet_small          (),
      .stat_tx_total_bytes           (),
      .stat_tx_total_good_bytes      (),
      .stat_tx_total_good_packets    (),
      .stat_tx_total_packets         (),
      .stat_tx_unicast               (),
      .stat_tx_vlan                  ()
  );

endmodule
`resetall
