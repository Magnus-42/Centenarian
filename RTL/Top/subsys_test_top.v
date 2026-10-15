`resetall
`default_nettype none
`timescale 1ns / 1ps

// Language: Verilog 2001
// ============================================================================
// File Name   : subsys_test_top.v
// Module Name : subsys_test_top
// Author      : LiXintao
// Date        : 2026-10-09
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : eth_subsys_top 板级实验顶层（全通道覆盖测试）
// NOTE        :
//   1. DUT = eth_subsys_top(ETH_PORT_NUM=2)；A/B 两片 CMAC 经外部光缆对接。
//   2. 每口 5 个 subsys_100g_tester，覆盖全部用户通道：
//      MAC other / IPv4 icmp / IPv4 ospf / IPv4 other / UDP（UDP 取第 CHK_PORT 路）。
//   3. 时钟/复位在本层做：clk_100_to_400m 产生 400M，rst_sync 同步后给 DUT。
//   4. cfg 全部按"值直通(小端)"约定给值：IP/MAC 用线序值，total_len 用 {len[7:0],len[15:8]}。
// ============================================================================
module subsys_test_top(
  input  wire                                          sys_clk         ,

  // ---- 网口 A ----
  output wire          [                   3: 0]       gt_txp_out_a    ,
  output wire          [                   3: 0]       gt_txn_out_a    ,
  input  wire          [                   3: 0]       gt_rxp_in_a     ,
  input  wire          [                   3: 0]       gt_rxn_in_a     ,
  input  wire                                          gt_ref_clk_p_a  ,
  input  wire                                          gt_ref_clk_n_a  ,
  output wire                                          qsfp_rstn_port_a,
  output wire                                          qsfp_lp_mode_port_a,
  output wire                                          qsfp_seln_port_a,
  input  wire                                          qsfp_prsn_port_a,
  output wire                                          qsfp_led_port_a ,

  // ---- 网口 B ----
  output wire          [                   3: 0]       gt_txp_out_b    ,
  output wire          [                   3: 0]       gt_txn_out_b    ,
  input  wire          [                   3: 0]       gt_rxp_in_b     ,
  input  wire          [                   3: 0]       gt_rxn_in_b     ,
  input  wire                                          gt_ref_clk_p_b  ,
  input  wire                                          gt_ref_clk_n_b  ,
  output wire                                          qsfp_rstn_port_b,
  output wire                                          qsfp_lp_mode_port_b,
  output wire                                          qsfp_seln_port_b,
  input  wire                                          qsfp_prsn_port_b,
  output wire                                          qsfp_led_port_b 
);

  // ============================================================================
  // 参数与配置
  // ============================================================================
  localparam ETH_PORT_NUM   = 2 ;
  localparam PORT_NUM       = 3 ;
  localparam [PORT_NUM*32-1:0] DST_PORT_RANGE = {32'h00080002, 32'h00010001, 32'h00000000};
  localparam AXIS_WIDTH     = 512;
  localparam PKT_LEN_BEATS  = 16;                               // 每包 16 拍 = 1024 字节
  localparam ONE_SEC_CYCLES = 32'd400_000_000;                  // 1s @400MHz
  localparam CHK_PORT       = 2 ;                               // UDP 校验第 2 路(区间[2,8])


  // ---- 本机配置（线序值：低字节 = 线上第一字节）----
  localparam [31:0] CFG_A_IP    = 32'h0901_A8C0;                // 192.168.1.9
  localparam [31:0] CFG_B_IP    = 32'h0801_A8C0;                // 192.168.1.8
  localparam [47:0] CFG_A_MAC   = 48'h010000311900;             // 00:19:31:00:00:01
  localparam [47:0] CFG_B_MAC   = 48'h020000311900;             // 00:19:31:00:00:02
  localparam [31:0] CFG_GATEWAY = 32'h0101_A8C0;                // 192.168.1.1
  localparam [31:0] CFG_SUBNET  = 32'h00FF_FFFF;                // 255.255.255.0

  // ---- UDP cfg ----
  localparam [15:0] UDP_LEN       = PKT_LEN_BEATS*64;                     // UDP 报文长度
  localparam [15:0] IP_LEN_UDP    = UDP_LEN + 16'd20;                     // UDP 通道 IP 总长(tester 发 UDP 报文, IP 头由 udp_top 补)
  localparam [15:0] IP_LEN_FULL   = PKT_LEN_BEATS*64;                     // 其余通道 IP 总长(tester 直接发完整 IP 包)
  localparam [15:0] IP_LEN_UDP_LE = {IP_LEN_UDP[7:0],  IP_LEN_UDP[15:8]};  // 值直通: 低字节先
  localparam [15:0] IP_LEN_FULL_LE= {IP_LEN_FULL[7:0], IP_LEN_FULL[15:8]};
  localparam [15:0] UDP_LEN_LE    = {UDP_LEN[7:0], UDP_LEN[15:8]};

  // ---- 各通道包头（低 160 位，低字节 = 线上第一字节）----
  // 以太帧头 14B: dst_mac(6) src_mac(6) type(2)=0x88B5
  localparam [159:0] HDR_MAC_A    = {16'hB588, CFG_A_MAC, CFG_B_MAC};
  localparam [159:0] HDR_MAC_B    = {16'hB588, CFG_B_MAC, CFG_A_MAC};
  // 纯 IPv4 头 20B（protocol: icmp=0x01 / ospf=0x59 / other=0x06）
  localparam [159:0] HDR_IP_ICMP_A= {CFG_B_IP, CFG_A_IP, 16'h0000, 8'h01, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [159:0] HDR_IP_ICMP_B= {CFG_A_IP, CFG_B_IP, 16'h0000, 8'h01, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [159:0] HDR_IP_OSPF_A= {CFG_B_IP, CFG_A_IP, 16'h0000, 8'h59, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [159:0] HDR_IP_OSPF_B= {CFG_A_IP, CFG_B_IP, 16'h0000, 8'h59, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [159:0] HDR_IP_OTHR_A= {CFG_B_IP, CFG_A_IP, 16'h0000, 8'h06, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [159:0] HDR_IP_OTHR_B= {CFG_A_IP, CFG_B_IP, 16'h0000, 8'h06, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  // UDP 头 8B: src_port(2) dst_port(2) len(2) cks(2)
  localparam [159:0] HDR_UDP_A    = {112'd0, 16'h0000, UDP_LEN_LE, CHK_PORT[15:0], 16'h0000};
  localparam [159:0] HDR_UDP_B    = {112'd0, 16'h0000, UDP_LEN_LE, CHK_PORT[15:0], 16'h0000};

  // ============================================================================
  // 时钟 / 复位（在本层做）
  // ============================================================================
  wire                                                 clk_400m        ;
  wire                                                 clk_locked      ;
  reg                                                  usr_rst         ;
  wire                                                 qsfp_gt_rst     ;
  wire                                                 en_a_udp        ;// VIO probe_out0
  wire                                                 en_a_icmp       ;// VIO probe_out1
  wire                                                 en_a_ospf       ;// VIO probe_out2
  wire                                                 en_a_ipother    ;// VIO probe_out3
  wire                                                 en_a_macother   ;// VIO probe_out4
  wire                                                 en_b_udp        ;// VIO probe_out5
  wire                                                 en_b_icmp       ;// VIO probe_out6
  wire                                                 en_b_ospf       ;// VIO probe_out7
  wire                                                 en_b_ipother    ;// VIO probe_out8
  wire                                                 en_b_macother   ;// VIO probe_out9

  clk_100_to_400m u_clk_100_to_400m (
    .clk_400m         (clk_400m         ),
    .locked           (clk_locked       ),
    .clk_100m         (sys_clk          ) 
  );

(* ASYNC_REG = "true" *)   reg  [1:0]  rst_sync = 2'b11;
  always @(posedge clk_400m or posedge qsfp_gt_rst) begin
    if (qsfp_gt_rst) rst_sync <= 2'b11;
    else             rst_sync <= {rst_sync[0], 1'b0};
  end

  always @(posedge clk_400m) begin
    usr_rst <= rst_sync[1];
  end

  // ============================================================================
  // DUT : eth_subsys_top（2 口，全通道引出）
  // ============================================================================
  wire [511:0]                    a_udp_s_data    ;  // tester_a -> DUT
  wire [ 63:0]                    a_udp_s_keep    ;
  wire                            a_udp_s_last    ;
  wire                            a_udp_s_valid   ;
  wire                            a_udp_s_ready   ;
  wire [511:0]                    a_udp_m_data    ;  // DUT 口A 输出(第 CHK_PORT 路) -> tester_b
  wire [ 63:0]                    a_udp_m_keep    ;
  wire                            a_udp_m_last    ;
  wire                            a_udp_m_valid   ;
  wire                            a_udp_m_ready   ;
  wire [511:0]                    a_icmp_s_data   , a_icmp_m_data   ;
  wire [ 63:0]                    a_icmp_s_keep   , a_icmp_m_keep   ;
  wire                            a_icmp_s_last   , a_icmp_s_valid  , a_icmp_s_ready  ;
  wire                            a_icmp_m_last   , a_icmp_m_valid  , a_icmp_m_ready  ;
  wire [511:0]                    a_ospf_s_data   , a_ospf_m_data   ;
  wire [ 63:0]                    a_ospf_s_keep   , a_ospf_m_keep   ;
  wire                            a_ospf_s_last   , a_ospf_s_valid  , a_ospf_s_ready  ;
  wire                            a_ospf_m_last   , a_ospf_m_valid  , a_ospf_m_ready  ;
  wire [511:0]                    a_ipot_s_data   , a_ipot_m_data   ;
  wire [ 63:0]                    a_ipot_s_keep   , a_ipot_m_keep   ;
  wire                            a_ipot_s_last   , a_ipot_s_valid  , a_ipot_s_ready  ;
  wire                            a_ipot_m_last   , a_ipot_m_valid  , a_ipot_m_ready  ;
  wire [511:0]                    a_maco_s_data   , a_maco_m_data   ;
  wire [ 63:0]                    a_maco_s_keep   , a_maco_m_keep   ;
  wire                            a_maco_s_last   , a_maco_s_valid  , a_maco_s_ready  ;
  wire                            a_maco_m_last   , a_maco_m_valid  , a_maco_m_ready  ;

  wire [511:0]                    b_udp_s_data    ;
  wire [ 63:0]                    b_udp_s_keep    ;
  wire                            b_udp_s_last    ;
  wire                            b_udp_s_valid   ;
  wire                            b_udp_s_ready   ;
  wire [511:0]                    b_udp_m_data    ;  // DUT 口B 输出(第 CHK_PORT 路) -> tester_a
  wire [ 63:0]                    b_udp_m_keep    ;
  wire                            b_udp_m_last    ;
  wire                            b_udp_m_valid   ;
  wire                            b_udp_m_ready   ;
  wire [511:0]                    b_icmp_s_data   , b_icmp_m_data   ;
  wire [ 63:0]                    b_icmp_s_keep   , b_icmp_m_keep   ;
  wire                            b_icmp_s_last   , b_icmp_s_valid  , b_icmp_s_ready  ;
  wire                            b_icmp_m_last   , b_icmp_m_valid  , b_icmp_m_ready  ;
  wire [511:0]                    b_ospf_s_data   , b_ospf_m_data   ;
  wire [ 63:0]                    b_ospf_s_keep   , b_ospf_m_keep   ;
  wire                            b_ospf_s_last   , b_ospf_s_valid  , b_ospf_s_ready  ;
  wire                            b_ospf_m_last   , b_ospf_m_valid  , b_ospf_m_ready  ;
  wire [511:0]                    b_ipot_s_data   , b_ipot_m_data   ;
  wire [ 63:0]                    b_ipot_s_keep   , b_ipot_m_keep   ;
  wire                            b_ipot_s_last   , b_ipot_s_valid  , b_ipot_s_ready  ;
  wire                            b_ipot_m_last   , b_ipot_m_valid  , b_ipot_m_ready  ;
  wire [511:0]                    b_maco_s_data   , b_maco_m_data   ;
  wire [ 63:0]                    b_maco_s_keep   , b_maco_m_keep   ;
  wire                            b_maco_s_last   , b_maco_s_valid  , b_maco_s_ready  ;
  wire                            b_maco_m_last   , b_maco_m_valid  , b_maco_m_ready  ;

  wire [512*(PORT_NUM+1)*ETH_PORT_NUM-1:0]  udp_axis_mdata  ;  // DUT 输出(全口全路)
  wire [ 64*(PORT_NUM+1)*ETH_PORT_NUM-1:0]  udp_axis_mkeep  ;
  wire [ (PORT_NUM+1)*ETH_PORT_NUM-1:0]     udp_axis_mlast  ;
  wire [ (PORT_NUM+1)*ETH_PORT_NUM-1:0]     udp_axis_mvalid ;
  wire [192*(PORT_NUM+1)*ETH_PORT_NUM-1:0]  udp_axis_musr   ;
  wire [ (PORT_NUM+1)*ETH_PORT_NUM-1:0]     udp_axis_mready ;

  wire [512*ETH_PORT_NUM-1:0]  icmp_axis_mdata  ;
  wire [ 64*ETH_PORT_NUM-1:0]  icmp_axis_mkeep  ;
  wire [ 96*ETH_PORT_NUM-1:0]  icmp_axis_musr  ;
  wire [ ETH_PORT_NUM-1:0]     icmp_axis_mlast , icmp_axis_mvalid, icmp_axis_mready;
  wire [512*ETH_PORT_NUM-1:0]  ospf_axis_mdata  ;
  wire [ 64*ETH_PORT_NUM-1:0]  ospf_axis_mkeep  ;
  wire [ 96*ETH_PORT_NUM-1:0]  ospf_axis_musr  ;
  wire [ ETH_PORT_NUM-1:0]     ospf_axis_mlast , ospf_axis_mvalid, ospf_axis_mready;
  wire [512*ETH_PORT_NUM-1:0]  ipot_axis_mdata  ;
  wire [ 64*ETH_PORT_NUM-1:0]  ipot_axis_mkeep  ;
  wire [ 96*ETH_PORT_NUM-1:0]  ipot_axis_musr  ;
  wire [ ETH_PORT_NUM-1:0]     ipot_axis_mlast , ipot_axis_mvalid, ipot_axis_mready;
  wire [512*ETH_PORT_NUM-1:0]  maco_axis_mdata  ;
  wire [ 64*ETH_PORT_NUM-1:0]  maco_axis_mkeep  ;
  wire [ ETH_PORT_NUM-1:0]     maco_axis_mlast , maco_axis_mvalid, maco_axis_mready;
  wire [512*ETH_PORT_NUM-1:0]  icmp_axis_sdata  ;
  wire [ 64*ETH_PORT_NUM-1:0]  icmp_axis_skeep  ;
  wire [ ETH_PORT_NUM-1:0]     icmp_axis_slast , icmp_axis_svalid, icmp_axis_sready;
  wire [512*ETH_PORT_NUM-1:0]  ospf_axis_sdata  ;
  wire [ 64*ETH_PORT_NUM-1:0]  ospf_axis_skeep  ;
  wire [ ETH_PORT_NUM-1:0]     ospf_axis_slast , ospf_axis_svalid, ospf_axis_sready;
  wire [512*ETH_PORT_NUM-1:0]  ipot_axis_sdata  ;
  wire [ 64*ETH_PORT_NUM-1:0]  ipot_axis_skeep  ;
  wire [ ETH_PORT_NUM-1:0]     ipot_axis_slast , ipot_axis_svalid, ipot_axis_sready;
  wire [512*ETH_PORT_NUM-1:0]  maco_axis_sdata  ;
  wire [ 64*ETH_PORT_NUM-1:0]  maco_axis_skeep  ;
  wire [ ETH_PORT_NUM-1:0]     maco_axis_slast , maco_axis_svalid, maco_axis_sready;
  wire [512*ETH_PORT_NUM-1:0]  udp_axis_sdata  ;
  wire [ 64*ETH_PORT_NUM-1:0]  udp_axis_skeep  ;
  wire [ ETH_PORT_NUM-1:0]     udp_axis_slast  , udp_axis_svalid, udp_axis_sready;

  eth_subsys_top #(
    .ETH_PORT_NUM     (ETH_PORT_NUM   ),
    .PORT_NUM         (PORT_NUM       ),
    .DST_PORT_RANGE   (DST_PORT_RANGE ),
    .AXIS_WIDTH       (AXIS_WIDTH     ),
    .AXIS_USER_WIDTH  (1              ),
    .LOCAL_IP_NUM     (1              ),
    .PENDING_TIME_WIDTH(57            ),
    .CFG_PENDING_TIME (57'd400_000_000)
  ) u_dut (
    .sys_clk          (sys_clk        ),
    .clk              (clk_400m       ),
    .clk_locked       (clk_locked     ),
    .qsfp_gt_rst      (qsfp_gt_rst    ),
    .usr_rst          (usr_rst        ),
    // GT / QSFP（口 0 = A 在低位）
    .gt_txp_out       ({gt_txp_out_b , gt_txp_out_a }),
    .gt_txn_out       ({gt_txn_out_b , gt_txn_out_a }),
    .gt_rxp_in        ({gt_rxp_in_b  , gt_rxp_in_a  }),
    .gt_rxn_in        ({gt_rxn_in_b  , gt_rxn_in_a  }),
    .gt_ref_clk_p     ({gt_ref_clk_p_b, gt_ref_clk_p_a}),
    .gt_ref_clk_n     ({gt_ref_clk_n_b, gt_ref_clk_n_a}),
    .qsfp_rstn_port   ({qsfp_rstn_port_b , qsfp_rstn_port_a }),
    .qsfp_lp_mode_port({qsfp_lp_mode_port_b, qsfp_lp_mode_port_a}),
    .qsfp_seln_port   ({qsfp_seln_port_b , qsfp_seln_port_a }),
    .qsfp_prsn_port   ({qsfp_prsn_port_b , qsfp_prsn_port_a }),
    .qsfp_led_port    ({qsfp_led_port_b  , qsfp_led_port_a  }),
    // ARP 本机配置
    .cfg_local_mac    ({CFG_B_MAC , CFG_A_MAC }),
    .cfg_local_ip     ({CFG_B_IP  , CFG_A_IP  }),
    .cfg_gateway_ip   ({CFG_GATEWAY, CFG_GATEWAY}),
    .cfg_subnet_mask  ({CFG_SUBNET, CFG_SUBNET}),
    // MAC other 通道
    .mac_other_axis_mdata  (maco_axis_mdata  ),
    .mac_other_axis_mkeep  (maco_axis_mkeep  ),
    .mac_other_axis_mlast  (maco_axis_mlast  ),
    .mac_other_axis_mvalid (maco_axis_mvalid ),
    .mac_other_axis_mready (maco_axis_mready ),
    .mac_other_axis_sdata  (maco_axis_sdata  ),
    .mac_other_axis_skeep  (maco_axis_skeep  ),
    .mac_other_axis_slast  (maco_axis_slast  ),
    .mac_other_axis_svalid (maco_axis_svalid ),
    .mac_other_axis_sready (maco_axis_sready ),
    // IPv4 icmp 通道
    .ipv4_icmp_axis_mdata  (icmp_axis_mdata  ),
    .ipv4_icmp_axis_mkeep  (icmp_axis_mkeep  ),
    .ipv4_icmp_axis_mlast  (icmp_axis_mlast  ),
    .ipv4_icmp_axis_mvalid (icmp_axis_mvalid ),
    .ipv4_icmp_axis_musr   (icmp_axis_musr   ),
    .ipv4_icmp_axis_mready (icmp_axis_mready ),
    .ipv4_icmp_axis_sdata  (icmp_axis_sdata  ),
    .ipv4_icmp_axis_skeep  (icmp_axis_skeep  ),
    .ipv4_icmp_axis_slast  (icmp_axis_slast  ),
    .ipv4_icmp_axis_svalid (icmp_axis_svalid ),
    .ipv4_icmp_axis_sready (icmp_axis_sready ),
    // IPv4 ospf 通道
    .ipv4_ospf_axis_mdata  (ospf_axis_mdata  ),
    .ipv4_ospf_axis_mkeep  (ospf_axis_mkeep  ),
    .ipv4_ospf_axis_mlast  (ospf_axis_mlast  ),
    .ipv4_ospf_axis_mvalid (ospf_axis_mvalid ),
    .ipv4_ospf_axis_musr   (ospf_axis_musr   ),
    .ipv4_ospf_axis_mready (ospf_axis_mready ),
    .ipv4_ospf_axis_sdata  (ospf_axis_sdata  ),
    .ipv4_ospf_axis_skeep  (ospf_axis_skeep  ),
    .ipv4_ospf_axis_slast  (ospf_axis_slast  ),
    .ipv4_ospf_axis_svalid (ospf_axis_svalid ),
    .ipv4_ospf_axis_sready (ospf_axis_sready ),
    // IPv4 other 通道
    .ipv4_other_axis_mdata (ipot_axis_mdata  ),
    .ipv4_other_axis_mkeep (ipot_axis_mkeep  ),
    .ipv4_other_axis_mlast (ipot_axis_mlast  ),
    .ipv4_other_axis_mvalid(ipot_axis_mvalid ),
    .ipv4_other_axis_musr  (ipot_axis_musr   ),
    .ipv4_other_axis_mready(ipot_axis_mready ),
    .ipv4_other_axis_sdata (ipot_axis_sdata  ),
    .ipv4_other_axis_skeep (ipot_axis_skeep  ),
    .ipv4_other_axis_slast (ipot_axis_slast  ),
    .ipv4_other_axis_svalid(ipot_axis_svalid ),
    .ipv4_other_axis_sready(ipot_axis_sready ),
    // UDP 通道
    .udp_axis_mdata   (udp_axis_mdata   ),
    .udp_axis_mkeep   (udp_axis_mkeep   ),
    .udp_axis_mlast   (udp_axis_mlast   ),
    .udp_axis_mvalid  (udp_axis_mvalid  ),
    .udp_axis_musr    (udp_axis_musr    ),
    .udp_axis_mready  (udp_axis_mready  ),
    .udp_axis_sdata   (udp_axis_sdata   ),
    .udp_axis_skeep   (udp_axis_skeep   ),
    .udp_axis_slast   (udp_axis_slast   ),
    .udp_axis_svalid  (udp_axis_svalid  ),
    .udp_axis_sready  (udp_axis_sready  ),
    .cfg_total_len    ({IP_LEN_UDP_LE, IP_LEN_UDP_LE}),
    .cfg_ttl          ({8'h40, 8'h40}),
    .cfg_head_checksum({16'h0000, 16'h0000}),
    .cfg_src_ip       ({CFG_B_IP, CFG_A_IP}),
    .cfg_dest_ip      ({CFG_A_IP, CFG_B_IP}),
    // 状态
    .stat_is_df            (                ),
    .stat_tx_active_port   (                ),
    .stat_tx_idle          (                ),
    .stat_arp_rx_error     (                ),
    .stat_arp_ack_ovf      (                ),
    .stat_arp_pend_ovf     (                ),
    .stat_arp_no_resp      (                ),
    .stat_arp_pend_clr     (                ),
    .stat_arp_cache_clr    (                ),
    .stat_arp_src_not_local(                )
  );

  // ============================================================================
  // UDP 通道接线：tester 发 -> DUT 收；DUT 输出取第 CHK_PORT 路 -> 对端口 tester 收(交叉)；
  //                 其余各路 mready 恒 1（丢弃）
  // ============================================================================
  assign  udp_axis_sdata            = {b_udp_s_data , a_udp_s_data };
  assign  udp_axis_skeep            = {b_udp_s_keep , a_udp_s_keep };
  assign  udp_axis_slast            = {b_udp_s_last , a_udp_s_last };
  assign  udp_axis_svalid           = {b_udp_s_valid, a_udp_s_valid};
  assign  a_udp_s_ready             = udp_axis_sready[0];
  assign  b_udp_s_ready             = udp_axis_sready[1];

  assign  a_udp_m_data  = udp_axis_mdata [(0*(PORT_NUM+1) + CHK_PORT)*512 +: 512];
  assign  a_udp_m_keep  = udp_axis_mkeep [(0*(PORT_NUM+1) + CHK_PORT)*64  +: 64 ];
  assign  a_udp_m_last  = udp_axis_mlast [ 0*(PORT_NUM+1) + CHK_PORT];
  assign  a_udp_m_valid = udp_axis_mvalid[ 0*(PORT_NUM+1) + CHK_PORT];
  assign  b_udp_m_data  = udp_axis_mdata [(1*(PORT_NUM+1) + CHK_PORT)*512 +: 512];
  assign  b_udp_m_keep  = udp_axis_mkeep [(1*(PORT_NUM+1) + CHK_PORT)*64  +: 64 ];
  assign  b_udp_m_last  = udp_axis_mlast [ 1*(PORT_NUM+1) + CHK_PORT];
  assign  b_udp_m_valid = udp_axis_mvalid[ 1*(PORT_NUM+1) + CHK_PORT];

  genvar gk;
  generate
  for (gk = 0; gk < (PORT_NUM+1)*ETH_PORT_NUM; gk = gk + 1) begin : gen_udp_rdy
    if ((gk % (PORT_NUM+1)) == CHK_PORT)
      assign udp_axis_mready[gk] = (gk < (PORT_NUM+1)) ? a_udp_m_ready : b_udp_m_ready;
    else
      assign udp_axis_mready[gk] = 1'b1;                                  // 非校验路: 收下即丢
  end
  endgenerate

  // ============================================================================
  // 每口 5 个测试机
  // 接收端交叉接法: 每台测试机的"收"接【对端口】的接收通道 —— 校验"本机发出的流在对端口
  //   还原出的样子"; 期望值 = 本机发出的 HDR+拍号, 与来包内容一致 ⇒ 全拍校验(含包头拍)。
  //   (若接本端口接收通道, 收到的是对端口发来的包, 包头源/目的地址方向相反 ⇒ 包头拍必然误报)
  // 统计口径: 使能某口打流后, 看【该口测试机】的 rx_* 计数 = 该流在对端口的接收情况。
  // ============================================================================
  // ---- 网口 A ----
  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_UDP_A)
  ) u_ta_udp (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_a_udp     ),
    .axis_mdata(a_udp_s_data), .axis_mkeep(a_udp_s_keep), .axis_mvalid(a_udp_s_valid),
    .axis_mlast(a_udp_s_last), .axis_mready(a_udp_s_ready),
    .axis_sdata(b_udp_m_data), .axis_skeep(b_udp_m_keep), .axis_svalid(b_udp_m_valid),
    .axis_slast(b_udp_m_last), .axis_sready(b_udp_m_ready)
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_IP_ICMP_A)
  ) u_ta_icmp (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_a_icmp    ),
    .axis_mdata(icmp_axis_sdata[0*512 +: 512]), .axis_mkeep(icmp_axis_skeep[0*64 +: 64]),
    .axis_mvalid(icmp_axis_svalid[0]), .axis_mlast(icmp_axis_slast[0]),
    .axis_mready(icmp_axis_sready[0]),
    .axis_sdata(icmp_axis_mdata[1*512 +: 512]), .axis_skeep(icmp_axis_mkeep[1*64 +: 64]),
    .axis_svalid(icmp_axis_mvalid[1]), .axis_slast(icmp_axis_mlast[1]),
    .axis_sready(icmp_axis_mready[1])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_IP_OSPF_A)
  ) u_ta_ospf (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_a_ospf    ),
    .axis_mdata(ospf_axis_sdata[0*512 +: 512]), .axis_mkeep(ospf_axis_skeep[0*64 +: 64]),
    .axis_mvalid(ospf_axis_svalid[0]), .axis_mlast(ospf_axis_slast[0]),
    .axis_mready(ospf_axis_sready[0]),
    .axis_sdata(ospf_axis_mdata[1*512 +: 512]), .axis_skeep(ospf_axis_mkeep[1*64 +: 64]),
    .axis_svalid(ospf_axis_mvalid[1]), .axis_slast(ospf_axis_mlast[1]),
    .axis_sready(ospf_axis_mready[1])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_IP_OTHR_A)
  ) u_ta_ipother (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_a_ipother ),
    .axis_mdata(ipot_axis_sdata[0*512 +: 512]), .axis_mkeep(ipot_axis_skeep[0*64 +: 64]),
    .axis_mvalid(ipot_axis_svalid[0]), .axis_mlast(ipot_axis_slast[0]),
    .axis_mready(ipot_axis_sready[0]),
    .axis_sdata(ipot_axis_mdata[1*512 +: 512]), .axis_skeep(ipot_axis_mkeep[1*64 +: 64]),
    .axis_svalid(ipot_axis_mvalid[1]), .axis_slast(ipot_axis_mlast[1]),
    .axis_sready(ipot_axis_mready[1])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_MAC_A)
  ) u_ta_macother (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_a_macother),
    .axis_mdata(maco_axis_sdata[0*512 +: 512]), .axis_mkeep(maco_axis_skeep[0*64 +: 64]),
    .axis_mvalid(maco_axis_svalid[0]), .axis_mlast(maco_axis_slast[0]),
    .axis_mready(maco_axis_sready[0]),
    .axis_sdata(maco_axis_mdata[1*512 +: 512]), .axis_skeep(maco_axis_mkeep[1*64 +: 64]),
    .axis_svalid(maco_axis_mvalid[1]), .axis_slast(maco_axis_mlast[1]),
    .axis_sready(maco_axis_mready[1])
  );

  // ---- 网口 B ----
  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_UDP_B)
  ) u_tb_udp (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_b_udp     ),
    .axis_mdata(b_udp_s_data), .axis_mkeep(b_udp_s_keep), .axis_mvalid(b_udp_s_valid),
    .axis_mlast(b_udp_s_last), .axis_mready(b_udp_s_ready),
    .axis_sdata(a_udp_m_data), .axis_skeep(a_udp_m_keep), .axis_svalid(a_udp_m_valid),
    .axis_slast(a_udp_m_last), .axis_sready(a_udp_m_ready)
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_IP_ICMP_B)
  ) u_tb_icmp (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_b_icmp    ),
    .axis_mdata(icmp_axis_sdata[1*512 +: 512]), .axis_mkeep(icmp_axis_skeep[1*64 +: 64]),
    .axis_mvalid(icmp_axis_svalid[1]), .axis_mlast(icmp_axis_slast[1]),
    .axis_mready(icmp_axis_sready[1]),
    .axis_sdata(icmp_axis_mdata[0*512 +: 512]), .axis_skeep(icmp_axis_mkeep[0*64 +: 64]),
    .axis_svalid(icmp_axis_mvalid[0]), .axis_slast(icmp_axis_mlast[0]),
    .axis_sready(icmp_axis_mready[0])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_IP_OSPF_B)
  ) u_tb_ospf (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_b_ospf    ),
    .axis_mdata(ospf_axis_sdata[1*512 +: 512]), .axis_mkeep(ospf_axis_skeep[1*64 +: 64]),
    .axis_mvalid(ospf_axis_svalid[1]), .axis_mlast(ospf_axis_slast[1]),
    .axis_mready(ospf_axis_sready[1]),
    .axis_sdata(ospf_axis_mdata[0*512 +: 512]), .axis_skeep(ospf_axis_mkeep[0*64 +: 64]),
    .axis_svalid(ospf_axis_mvalid[0]), .axis_slast(ospf_axis_mlast[0]),
    .axis_sready(ospf_axis_mready[0])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_IP_OTHR_B)
  ) u_tb_ipother (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_b_ipother ),
    .axis_mdata(ipot_axis_sdata[1*512 +: 512]), .axis_mkeep(ipot_axis_skeep[1*64 +: 64]),
    .axis_mvalid(ipot_axis_svalid[1]), .axis_mlast(ipot_axis_slast[1]),
    .axis_mready(ipot_axis_sready[1]),
    .axis_sdata(ipot_axis_mdata[0*512 +: 512]), .axis_skeep(ipot_axis_mkeep[0*64 +: 64]),
    .axis_svalid(ipot_axis_mvalid[0]), .axis_slast(ipot_axis_mlast[0]),
    .axis_sready(ipot_axis_mready[0])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_MAC_B)
  ) u_tb_macother (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_b_macother),
    .axis_mdata(maco_axis_sdata[1*512 +: 512]), .axis_mkeep(maco_axis_skeep[1*64 +: 64]),
    .axis_mvalid(maco_axis_svalid[1]), .axis_mlast(maco_axis_slast[1]),
    .axis_mready(maco_axis_sready[1]),
    .axis_sdata(maco_axis_mdata[0*512 +: 512]), .axis_skeep(maco_axis_mkeep[0*64 +: 64]),
    .axis_svalid(maco_axis_mvalid[0]), .axis_slast(maco_axis_mlast[0]),
    .axis_sready(maco_axis_mready[0])
  );

  // ============================================================================
  // VIO : 启动/停止打流（总开关）
  // ============================================================================
  vio_enable u_test_vio_enable (
    .clk              (clk_400m         ),// input wire clk
    .probe_out0       (en_a_udp         ),// A 口 UDP
    .probe_out1       (en_a_icmp        ),// A 口 IPv4-icmp
    .probe_out2       (en_a_ospf        ),// A 口 IPv4-ospf
    .probe_out3       (en_a_ipother     ),// A 口 IPv4-other
    .probe_out4       (en_a_macother    ),// A 口 MAC-other
    .probe_out5       (en_b_udp         ),// B 口 UDP
    .probe_out6       (en_b_icmp        ),// B 口 IPv4-icmp
    .probe_out7       (en_b_ospf        ),// B 口 IPv4-ospf
    .probe_out8       (en_b_ipother     ),// B 口 IPv4-other
    .probe_out9       (en_b_macother    ) // B 口 MAC-other
  );

endmodule
`resetall
