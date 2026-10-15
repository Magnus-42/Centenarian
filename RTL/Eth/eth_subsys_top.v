`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : eth_subsys_top.v
// Module Name : eth_subsys_top
// Author      : LiXintao
// Date        : 2026-10-09
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 以太网子系统顶层（协议栈 : MAC + ARP + IPv4 + UDP，口数参数化）
// NOTE        :
//   1. ETH_PORT_NUM 个网口，每口独立一套 eth_top + arp_engine_top + ipv4_top
//      + udp_top；eth_top 的 PORT_SEL 逐口递增(0,1,2,...)。
//      未来新增 cmac_c_if 等后，只需在 eth_top 内补一条 PORT_SEL 分支
//      （并把原 else 兜底改成 else if + 末尾 $error），本文件不用改结构。
//   2. 所有多口信号按"口序"打包为扁平总线，第 i 口占 [i*W +: W]。
//   3. 全通道引出：mac_other / ipv4_icmp / ipv4_ospf / ipv4_other /
//      udp(每口 PORT_NUM+1 路收 + 1 路发)。
//   4. ipv4_top 的 udp 通道 usr 不接 udp_top（其内部自行提取 IP 头字段），
//      故该端口留空。
// ============================================================================

module eth_subsys_top#(
  parameter  ETH_PORT_NUM= 2 ,
  parameter  PORT_NUM= 3 ,
  parameter  [       PORT_NUM*32-1: 0]       DST_PORT_RANGE= {32'h00080002,32'h00010001,32'h00000000}, // 端口禁止重叠
  parameter  AXIS_WIDTH= 512,
  parameter  AXIS_USER_WIDTH= 1 ,
  parameter  LOCAL_IP_NUM= 2 ,
  parameter  PENDING_TIME_WIDTH= 57, // 57位，10年以上
  parameter  [PENDING_TIME_WIDTH-1: 0]       CFG_PENDING_TIME= 57'd400_000_000// 1s @400MHz
)(
  input  wire                                          sys_clk         ,
  input  wire                                          clk             ,// 用户时钟(顶层生成)
  input  wire                                          clk_locked      ,// 时钟锁定指示(顶层提供)
  output wire                                          qsfp_gt_rst     ,// 交由顶层做复位同步
  input  wire                                          usr_rst         ,// 顶层生成的复位

  // ============================================================================
  // GT / QSFP : 每口 4 lane，按口序打包
  // ============================================================================
  output wire          [    4*ETH_PORT_NUM-1: 0]       gt_txp_out      ,
  output wire          [    4*ETH_PORT_NUM-1: 0]       gt_txn_out      ,
  input  wire          [    4*ETH_PORT_NUM-1: 0]       gt_rxp_in       ,
  input  wire          [    4*ETH_PORT_NUM-1: 0]       gt_rxn_in       ,
  input  wire          [      ETH_PORT_NUM-1: 0]       gt_ref_clk_p    ,
  input  wire          [      ETH_PORT_NUM-1: 0]       gt_ref_clk_n    ,
  output wire          [      ETH_PORT_NUM-1: 0]       qsfp_rstn_port  ,
  output wire          [      ETH_PORT_NUM-1: 0]       qsfp_lp_mode_port,
  output wire          [      ETH_PORT_NUM-1: 0]       qsfp_seln_port  ,
  input  wire          [      ETH_PORT_NUM-1: 0]       qsfp_prsn_port  ,
  output wire          [      ETH_PORT_NUM-1: 0]       qsfp_led_port   ,

  // ============================================================================
  // ARP : 本机配置（每口 LOCAL_IP_NUM 套，按口序打包）
  // ============================================================================
  input  wire          [48*LOCAL_IP_NUM*ETH_PORT_NUM-1: 0]cfg_local_mac   ,
  input  wire          [32*LOCAL_IP_NUM*ETH_PORT_NUM-1: 0]cfg_local_ip    ,
  input  wire          [32*LOCAL_IP_NUM*ETH_PORT_NUM-1: 0]cfg_gateway_ip  ,
  input  wire          [32*LOCAL_IP_NUM*ETH_PORT_NUM-1: 0]cfg_subnet_mask ,

  // ============================================================================
  // MAC 层 other 通道（非 ARP / 非 IPv4 的以太帧）
  // ============================================================================
  output wire          [AXIS_WIDTH*ETH_PORT_NUM-1: 0]  mac_other_axis_mdata,
  output wire          [AXIS_WIDTH/8*ETH_PORT_NUM-1: 0]mac_other_axis_mkeep,
  output wire          [      ETH_PORT_NUM-1: 0]       mac_other_axis_mlast,
  output wire          [      ETH_PORT_NUM-1: 0]       mac_other_axis_mvalid,
  input  wire          [      ETH_PORT_NUM-1: 0]       mac_other_axis_mready,
  input  wire          [AXIS_WIDTH*ETH_PORT_NUM-1: 0]  mac_other_axis_sdata,
  input  wire          [AXIS_WIDTH/8*ETH_PORT_NUM-1: 0]mac_other_axis_skeep,
  input  wire          [      ETH_PORT_NUM-1: 0]       mac_other_axis_slast,
  input  wire          [      ETH_PORT_NUM-1: 0]       mac_other_axis_svalid,
  output wire          [      ETH_PORT_NUM-1: 0]       mac_other_axis_sready,

  // ============================================================================
  // IPv4 层 icmp 通道
  // ============================================================================
  output wire          [AXIS_WIDTH*ETH_PORT_NUM-1: 0]  ipv4_icmp_axis_mdata,
  output wire          [AXIS_WIDTH/8*ETH_PORT_NUM-1: 0]ipv4_icmp_axis_mkeep,
  output wire          [      ETH_PORT_NUM-1: 0]       ipv4_icmp_axis_mlast,
  output wire          [      ETH_PORT_NUM-1: 0]       ipv4_icmp_axis_mvalid,
  output wire          [   96*ETH_PORT_NUM-1: 0]       ipv4_icmp_axis_musr,
  input  wire          [      ETH_PORT_NUM-1: 0]       ipv4_icmp_axis_mready,
  input  wire          [AXIS_WIDTH*ETH_PORT_NUM-1: 0]  ipv4_icmp_axis_sdata,
  input  wire          [AXIS_WIDTH/8*ETH_PORT_NUM-1: 0]ipv4_icmp_axis_skeep,
  input  wire          [      ETH_PORT_NUM-1: 0]       ipv4_icmp_axis_slast,
  input  wire          [      ETH_PORT_NUM-1: 0]       ipv4_icmp_axis_svalid,
  output wire          [      ETH_PORT_NUM-1: 0]       ipv4_icmp_axis_sready,

  // ============================================================================
  // IPv4 层 ospf 通道
  // ============================================================================
  output wire          [AXIS_WIDTH*ETH_PORT_NUM-1: 0]  ipv4_ospf_axis_mdata,
  output wire          [AXIS_WIDTH/8*ETH_PORT_NUM-1: 0]ipv4_ospf_axis_mkeep,
  output wire          [      ETH_PORT_NUM-1: 0]       ipv4_ospf_axis_mlast,
  output wire          [      ETH_PORT_NUM-1: 0]       ipv4_ospf_axis_mvalid,
  output wire          [   96*ETH_PORT_NUM-1: 0]       ipv4_ospf_axis_musr,
  input  wire          [      ETH_PORT_NUM-1: 0]       ipv4_ospf_axis_mready,
  input  wire          [AXIS_WIDTH*ETH_PORT_NUM-1: 0]  ipv4_ospf_axis_sdata,
  input  wire          [AXIS_WIDTH/8*ETH_PORT_NUM-1: 0]ipv4_ospf_axis_skeep,
  input  wire          [      ETH_PORT_NUM-1: 0]       ipv4_ospf_axis_slast,
  input  wire          [      ETH_PORT_NUM-1: 0]       ipv4_ospf_axis_svalid,
  output wire          [      ETH_PORT_NUM-1: 0]       ipv4_ospf_axis_sready,

  // ============================================================================
  // IPv4 层 other 通道
  // ============================================================================
  output wire          [AXIS_WIDTH*ETH_PORT_NUM-1: 0]  ipv4_other_axis_mdata,
  output wire          [AXIS_WIDTH/8*ETH_PORT_NUM-1: 0]ipv4_other_axis_mkeep,
  output wire          [      ETH_PORT_NUM-1: 0]       ipv4_other_axis_mlast,
  output wire          [      ETH_PORT_NUM-1: 0]       ipv4_other_axis_mvalid,
  output wire          [   96*ETH_PORT_NUM-1: 0]       ipv4_other_axis_musr,
  input  wire          [      ETH_PORT_NUM-1: 0]       ipv4_other_axis_mready,
  input  wire          [AXIS_WIDTH*ETH_PORT_NUM-1: 0]  ipv4_other_axis_sdata,
  input  wire          [AXIS_WIDTH/8*ETH_PORT_NUM-1: 0]ipv4_other_axis_skeep,
  input  wire          [      ETH_PORT_NUM-1: 0]       ipv4_other_axis_slast,
  input  wire          [      ETH_PORT_NUM-1: 0]       ipv4_other_axis_svalid,
  output wire          [      ETH_PORT_NUM-1: 0]       ipv4_other_axis_sready,

  // ============================================================================
  // UDP 层 : 每口 PORT_NUM+1 路收 + 1 路发（按口序打包）
  // ============================================================================
  output wire          [512*(PORT_NUM+1)*ETH_PORT_NUM-1: 0]udp_axis_mdata  ,
  output wire          [64*(PORT_NUM+1)*ETH_PORT_NUM-1: 0]udp_axis_mkeep  ,
  output wire          [(PORT_NUM+1)*ETH_PORT_NUM-1: 0]udp_axis_mlast  ,
  output wire          [(PORT_NUM+1)*ETH_PORT_NUM-1: 0]udp_axis_mvalid ,
  output wire          [192*(PORT_NUM+1)*ETH_PORT_NUM-1: 0]udp_axis_musr  ,
  input  wire          [(PORT_NUM+1)*ETH_PORT_NUM-1: 0]udp_axis_mready ,

  input  wire          [AXIS_WIDTH*ETH_PORT_NUM-1: 0]  udp_axis_sdata  ,
  input  wire          [AXIS_WIDTH/8*ETH_PORT_NUM-1: 0]udp_axis_skeep  ,
  input  wire          [      ETH_PORT_NUM-1: 0]       udp_axis_slast  ,
  input  wire          [      ETH_PORT_NUM-1: 0]       udp_axis_svalid ,
  output wire          [      ETH_PORT_NUM-1: 0]       udp_axis_sready ,

  input  wire          [   16*ETH_PORT_NUM-1: 0]       cfg_total_len   ,
  input  wire          [    8*ETH_PORT_NUM-1: 0]       cfg_ttl         ,
  input  wire          [   16*ETH_PORT_NUM-1: 0]       cfg_head_checksum,
  input  wire          [   32*ETH_PORT_NUM-1: 0]       cfg_src_ip      ,
  input  wire          [   32*ETH_PORT_NUM-1: 0]       cfg_dest_ip     ,

  // ============================================================================
  // 状态观测（mark_debug，供 ILA）
  // ============================================================================
  output wire          [      ETH_PORT_NUM-1: 0]       stat_is_df      ,
  output wire          [    2*ETH_PORT_NUM-1: 0]       stat_tx_active_port,
  output wire          [      ETH_PORT_NUM-1: 0]       stat_tx_idle    ,
  output wire          [      ETH_PORT_NUM-1: 0]       stat_arp_rx_error,
  output wire          [      ETH_PORT_NUM-1: 0]       stat_arp_ack_ovf,
  output wire          [      ETH_PORT_NUM-1: 0]       stat_arp_pend_ovf,
  output wire          [      ETH_PORT_NUM-1: 0]       stat_arp_no_resp,
  output wire          [      ETH_PORT_NUM-1: 0]       stat_arp_pend_clr,
  output wire          [      ETH_PORT_NUM-1: 0]       stat_arp_cache_clr,
  output wire          [      ETH_PORT_NUM-1: 0]       stat_arp_src_not_local 
);

  genvar gi;

  // ============================================================================
  // 时钟 / 复位（照搬 ipv4_test_top 的组织方式）
  // ============================================================================
  wire                 [      ETH_PORT_NUM-1: 0]       usr_tx_reset       ;
  wire                 [      ETH_PORT_NUM-1: 0]       usr_rx_reset       ;
  wire                 [      ETH_PORT_NUM-1: 0]       gt_txusrclk        ;
  wire                 [      ETH_PORT_NUM-1: 0]       gt_rxusrclk        ;

  assign  qsfp_gt_rst      = |usr_tx_reset | |usr_rx_reset;

  // ============================================================================
  // 每口 : eth_top + arp_engine_top + ipv4_top + udp_top
  // ============================================================================
  generate
  for (gi = 0; gi < ETH_PORT_NUM; gi = gi + 1) begin : gen_port

    // ---- eth_top <-> arp_engine_top ----
  wire                 [        AXIS_WIDTH-1: 0]       mac_arp_rx_data    ;
  wire                 [      AXIS_WIDTH/8-1: 0]       mac_arp_rx_keep    ;
  wire                                                 mac_arp_rx_last    ;
  wire                                                 mac_arp_rx_valid   ;
  wire                                                 mac_arp_rx_ready   ;
  wire                 [        AXIS_WIDTH-1: 0]       mac_arp_tx_data    ;
  wire                 [      AXIS_WIDTH/8-1: 0]       mac_arp_tx_keep    ;
  wire                                                 mac_arp_tx_last    ;
  wire                                                 mac_arp_tx_valid   ;
  wire                                                 mac_arp_tx_ready   ;

    // ---- eth_top <-> ipv4_top ----
  wire                 [        AXIS_WIDTH-1: 0]       mac_ipv4_rx_data   ;
  wire                 [      AXIS_WIDTH/8-1: 0]       mac_ipv4_rx_keep   ;
  wire                                                 mac_ipv4_rx_last   ;
  wire                                                 mac_ipv4_rx_valid  ;
  wire                                                 mac_ipv4_rx_ready  ;
  wire                 [        AXIS_WIDTH-1: 0]       mac_ipv4_tx_data   ;
  wire                 [      AXIS_WIDTH/8-1: 0]       mac_ipv4_tx_keep   ;
  wire                                                 mac_ipv4_tx_last   ;
  wire                                                 mac_ipv4_tx_valid  ;
  wire                                                 mac_ipv4_tx_ready  ;

    // ---- ipv4_top <-> udp_top ----
  wire                 [        AXIS_WIDTH-1: 0]       ip_udp_rx_data     ;
  wire                 [      AXIS_WIDTH/8-1: 0]       ip_udp_rx_keep     ;
  wire                                                 ip_udp_rx_last     ;
  wire                                                 ip_udp_rx_valid    ;
  wire                                                 ip_udp_rx_ready    ;
  wire                 [                  95: 0]       ip_udp_rx_usr      ;
  wire                 [        AXIS_WIDTH-1: 0]       ip_udp_tx_data     ;
  wire                 [      AXIS_WIDTH/8-1: 0]       ip_udp_tx_keep     ;
  wire                                                 ip_udp_tx_last     ;
  wire                                                 ip_udp_tx_valid    ;
  wire                                                 ip_udp_tx_ready    ;

    // ---- ipv4_top <-> arp_engine_top (查询握手) ----
  wire                 [                  31: 0]       arp_q_src_ip       ;
  wire                 [                  31: 0]       arp_q_dst_ip       ;
  wire                                                 arp_q_valid        ;
  wire                 [                  47: 0]       arp_r_dst_mac      ;
  wire                 [                  47: 0]       arp_r_src_mac      ;
  wire                                                 arp_r_miss         ;
  wire                                                 arp_r_valid        ;

    // ------------------------------------------------------------------------
    // 1) MAC 层 : 按 PORT_SEL 选片，收三类 / 发三类
    // ------------------------------------------------------------------------
    eth_top #(
    .PORT_SEL         (gi               ),// 0=cmac_a_if, 1=cmac_b_if, ...
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ) 
    ) u_eth_top (
    .init_clk         (sys_clk          ),
    .sys_reset        (~clk_locked      ),// 时钟未锁定期间复位 CMAC
    .gt_txusrclk      (gt_txusrclk[gi]  ),
    .gt_rxusrclk      (gt_rxusrclk[gi]  ),
    .usr_tx_reset     (usr_tx_reset[gi] ),
    .usr_rx_reset     (usr_rx_reset[gi] ),
    .gt_txp_out       (gt_txp_out[gi*4 +: 4]),
    .gt_txn_out       (gt_txn_out[gi*4 +: 4]),
    .gt_rxp_in        (gt_rxp_in [gi*4 +: 4]),
    .gt_rxn_in        (gt_rxn_in [gi*4 +: 4]),
    .gt_ref_clk_p     (gt_ref_clk_p[gi] ),
    .gt_ref_clk_n     (gt_ref_clk_n[gi] ),
    .qsfp_rstn_port   (qsfp_rstn_port[gi]),
    .qsfp_lp_mode_port(qsfp_lp_mode_port[gi]),
    .qsfp_seln_port   (qsfp_seln_port[gi]),
    .qsfp_prsn_port   (qsfp_prsn_port[gi]),
    .qsfp_led_port    (qsfp_led_port[gi]),
    .clk              (clk         ),
    .rst              (usr_rst          ),
    .fifo_tx_rst      (usr_rst          ),
      // RX 三类流输出
    .arp_axis_mdata   (mac_arp_rx_data  ),
    .arp_axis_mkeep   (mac_arp_rx_keep  ),
    .arp_axis_mlast   (mac_arp_rx_last  ),
    .arp_axis_mvalid  (mac_arp_rx_valid ),
    .arp_axis_mready  (mac_arp_rx_ready ),
    .other_axis_mdata (mac_other_axis_mdata[gi*AXIS_WIDTH +: AXIS_WIDTH]),
    .other_axis_mkeep (mac_other_axis_mkeep[gi*(AXIS_WIDTH/8) +: AXIS_WIDTH/8]),
    .other_axis_mlast (mac_other_axis_mlast[gi]),
    .other_axis_mvalid(mac_other_axis_mvalid[gi]),
    .other_axis_mready(mac_other_axis_mready[gi]),
    .ipv4_axis_mdata  (mac_ipv4_rx_data ),
    .ipv4_axis_mkeep  (mac_ipv4_rx_keep ),
    .ipv4_axis_mlast  (mac_ipv4_rx_last ),
    .ipv4_axis_mvalid (mac_ipv4_rx_valid),
    .ipv4_axis_mready (mac_ipv4_rx_ready),
      // TX 三类流入口
    .arp_axis_sdata   (mac_arp_tx_data  ),
    .arp_axis_skeep   (mac_arp_tx_keep  ),
    .arp_axis_slast   (mac_arp_tx_last  ),
    .arp_axis_svalid  (mac_arp_tx_valid ),
    .arp_axis_sready  (mac_arp_tx_ready ),
    .other_axis_sdata (mac_other_axis_sdata[gi*AXIS_WIDTH +: AXIS_WIDTH]),
    .other_axis_skeep (mac_other_axis_skeep[gi*(AXIS_WIDTH/8) +: AXIS_WIDTH/8]),
    .other_axis_slast (mac_other_axis_slast[gi]),
    .other_axis_svalid(mac_other_axis_svalid[gi]),
    .other_axis_sready(mac_other_axis_sready[gi]),
    .ipv4_axis_sdata  (mac_ipv4_tx_data ),
    .ipv4_axis_skeep  (mac_ipv4_tx_keep ),
    .ipv4_axis_slast  (mac_ipv4_tx_last ),
    .ipv4_axis_svalid (mac_ipv4_tx_valid),
    .ipv4_axis_sready (mac_ipv4_tx_ready),
    .stat_tx_active_port(stat_tx_active_port[gi*2 +: 2]),
    .stat_tx_idle     (stat_tx_idle[gi] ) 
    );

    // ------------------------------------------------------------------------
    // 2) ARP 引擎（每口一个）
    // ------------------------------------------------------------------------
    arp_engine_top #(
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .LOCAL_IP_NUM     (LOCAL_IP_NUM     ) 
    ) u_arp_eng (
    .clk              (clk         ),
    .rst              (usr_rst          ),
    .query_src_ip     (arp_q_src_ip     ),
    .query_dst_ip     (arp_q_dst_ip     ),
    .query_valid_pulse(arp_q_valid      ),
    .arp_dst_mac      (arp_r_dst_mac    ),
    .arp_src_mac      (arp_r_src_mac    ),
    .arp_miss         (arp_r_miss       ),
    .arp_valid        (arp_r_valid      ),
    .arp_axis_sdata   (mac_arp_rx_data  ),
    .arp_axis_skeep   (mac_arp_rx_keep  ),
    .arp_axis_svalid  (mac_arp_rx_valid ),
    .arp_axis_slast   (mac_arp_rx_last  ),
    .arp_axis_sready  (mac_arp_rx_ready ),
    .arp_axis_mdata   (mac_arp_tx_data  ),
    .arp_axis_mkeep   (mac_arp_tx_keep  ),
    .arp_axis_mvalid  (mac_arp_tx_valid ),
    .arp_axis_mlast   (mac_arp_tx_last  ),
    .arp_axis_mready  (mac_arp_tx_ready ),
    .cfg_local_ip     (cfg_local_ip[gi*32*LOCAL_IP_NUM +: 32*LOCAL_IP_NUM]),
    .cfg_local_mac    (cfg_local_mac[gi*48*LOCAL_IP_NUM +: 48*LOCAL_IP_NUM]),
    .cfg_gateway_ip   (cfg_gateway_ip[gi*32*LOCAL_IP_NUM +: 32*LOCAL_IP_NUM]),
    .cfg_subnet_mask  (cfg_subnet_mask[gi*32*LOCAL_IP_NUM +: 32*LOCAL_IP_NUM]),
    .cfg_pending_time (CFG_PENDING_TIME ),
    .cfg_clear_cache  (1'b0             ),
    .cfg_clear_pending(1'b0             ),
    .stat_rx_error    (stat_arp_rx_error[gi]),
    .stat_ack_fifo_overflow_error(stat_arp_ack_ovf[gi]),
    .stat_pending_fifo_overflow_error(stat_arp_pend_ovf[gi]),
    .stat_lookup_no_resp_error(stat_arp_no_resp[gi]),
    .stat_pending_clear_finish(stat_arp_pend_clr[gi]),
    .stat_cache_clear_finish(stat_arp_cache_clr[gi]),
    .stat_query_src_not_local(stat_arp_src_not_local[gi]) 
    );

    // ------------------------------------------------------------------------
    // 3) IPv4 层 : icmp/ospf/other 全引出, udp 通道接 udp_top
    // ------------------------------------------------------------------------
    ipv4_top #(
    .AXIS_WIDTH       (AXIS_WIDTH       ) 
    ) u_ipv4_top (
    .clk              (clk         ),
    .rst              (usr_rst          ),
      // RX : eth_top 分出的 IPv4 以太帧
    .eth_ipv4_axis_sdata(mac_ipv4_rx_data ),
    .eth_ipv4_axis_skeep(mac_ipv4_rx_keep ),
    .eth_ipv4_axis_slast(mac_ipv4_rx_last ),
    .eth_ipv4_axis_svalid(mac_ipv4_rx_valid),
    .eth_ipv4_axis_sready(mac_ipv4_rx_ready),
      // RX 输出 : udp 通道 -> udp_top (usr 不接, udp_top 内部自行提取)
    .ipv4_udp_axis_mdata(ip_udp_rx_data   ),
    .ipv4_udp_axis_mkeep(ip_udp_rx_keep   ),
    .ipv4_udp_axis_mlast(ip_udp_rx_last   ),
    .ipv4_udp_axis_mvalid(ip_udp_rx_valid  ),
    .ipv4_udp_axis_musr(ip_udp_rx_usr    ),
    .ipv4_udp_axis_mready(ip_udp_rx_ready  ),
      // RX 输出 : icmp / ospf / other -> 顶层
    .ipv4_icmp_axis_mdata(ipv4_icmp_axis_mdata[gi*AXIS_WIDTH +: AXIS_WIDTH]),
    .ipv4_icmp_axis_mkeep(ipv4_icmp_axis_mkeep[gi*(AXIS_WIDTH/8) +: AXIS_WIDTH/8]),
    .ipv4_icmp_axis_mlast(ipv4_icmp_axis_mlast[gi]),
    .ipv4_icmp_axis_mvalid(ipv4_icmp_axis_mvalid[gi]),
    .ipv4_icmp_axis_musr(ipv4_icmp_axis_musr[gi*96 +: 96]),
    .ipv4_icmp_axis_mready(ipv4_icmp_axis_mready[gi]),
    .ipv4_ospf_axis_mdata(ipv4_ospf_axis_mdata[gi*AXIS_WIDTH +: AXIS_WIDTH]),
    .ipv4_ospf_axis_mkeep(ipv4_ospf_axis_mkeep[gi*(AXIS_WIDTH/8) +: AXIS_WIDTH/8]),
    .ipv4_ospf_axis_mlast(ipv4_ospf_axis_mlast[gi]),
    .ipv4_ospf_axis_mvalid(ipv4_ospf_axis_mvalid[gi]),
    .ipv4_ospf_axis_musr(ipv4_ospf_axis_musr[gi*96 +: 96]),
    .ipv4_ospf_axis_mready(ipv4_ospf_axis_mready[gi]),
    .ipv4_other_axis_mdata(ipv4_other_axis_mdata[gi*AXIS_WIDTH +: AXIS_WIDTH]),
    .ipv4_other_axis_mkeep(ipv4_other_axis_mkeep[gi*(AXIS_WIDTH/8) +: AXIS_WIDTH/8]),
    .ipv4_other_axis_mlast(ipv4_other_axis_mlast[gi]),
    .ipv4_other_axis_mvalid(ipv4_other_axis_mvalid[gi]),
    .ipv4_other_axis_musr(ipv4_other_axis_musr[gi*96 +: 96]),
    .ipv4_other_axis_mready(ipv4_other_axis_mready[gi]),
      // TX : icmp / ospf / other 来自顶层
    .ipv4_icmp_axis_sdata(ipv4_icmp_axis_sdata[gi*AXIS_WIDTH +: AXIS_WIDTH]),
    .ipv4_icmp_axis_skeep(ipv4_icmp_axis_skeep[gi*(AXIS_WIDTH/8) +: AXIS_WIDTH/8]),
    .ipv4_icmp_axis_slast(ipv4_icmp_axis_slast[gi]),
    .ipv4_icmp_axis_svalid(ipv4_icmp_axis_svalid[gi]),
    .ipv4_icmp_axis_sready(ipv4_icmp_axis_sready[gi]),
    .ipv4_ospf_axis_sdata(ipv4_ospf_axis_sdata[gi*AXIS_WIDTH +: AXIS_WIDTH]),
    .ipv4_ospf_axis_skeep(ipv4_ospf_axis_skeep[gi*(AXIS_WIDTH/8) +: AXIS_WIDTH/8]),
    .ipv4_ospf_axis_slast(ipv4_ospf_axis_slast[gi]),
    .ipv4_ospf_axis_svalid(ipv4_ospf_axis_svalid[gi]),
    .ipv4_ospf_axis_sready(ipv4_ospf_axis_sready[gi]),
    .ipv4_other_axis_sdata(ipv4_other_axis_sdata[gi*AXIS_WIDTH +: AXIS_WIDTH]),
    .ipv4_other_axis_skeep(ipv4_other_axis_skeep[gi*(AXIS_WIDTH/8) +: AXIS_WIDTH/8]),
    .ipv4_other_axis_slast(ipv4_other_axis_slast[gi]),
    .ipv4_other_axis_svalid(ipv4_other_axis_svalid[gi]),
    .ipv4_other_axis_sready(ipv4_other_axis_sready[gi]),
      // TX : udp 通道 <- udp_top
    .ipv4_udp_axis_sdata(ip_udp_tx_data   ),
    .ipv4_udp_axis_skeep(ip_udp_tx_keep   ),
    .ipv4_udp_axis_slast(ip_udp_tx_last   ),
    .ipv4_udp_axis_svalid(ip_udp_tx_valid  ),
    .ipv4_udp_axis_sready(ip_udp_tx_ready  ),
      // TX 输出 : 完整以太帧 -> eth_top
    .eth_tx_axis_mdata(mac_ipv4_tx_data ),
    .eth_tx_axis_mkeep(mac_ipv4_tx_keep ),
    .eth_tx_axis_mlast(mac_ipv4_tx_last ),
    .eth_tx_axis_mvalid(mac_ipv4_tx_valid),
    .eth_tx_axis_mready(mac_ipv4_tx_ready),
      // ARP 查询握手 -> arp_engine_top
    .query_src_ip     (arp_q_src_ip     ),
    .query_dst_ip     (arp_q_dst_ip     ),
    .query_valid_pulse(arp_q_valid      ),
    .arp_dst_mac      (arp_r_dst_mac    ),
    .arp_src_mac      (arp_r_src_mac    ),
    .arp_miss         (arp_r_miss       ),
    .arp_valid        (arp_r_valid      ),
    .stat_active_port (                 ),
    .stat_idle        (                 ) 
    );

    // ------------------------------------------------------------------------
    // 4) UDP 层 : 去 IPv4 头 + 按端口分流 / 加 IPv4 头
    // ------------------------------------------------------------------------
    udp_top #(
    .PORT_NUM         (PORT_NUM         ),
    .DST_PORT_RANGE   (DST_PORT_RANGE   ) 
    ) u_udp_top (
    .clk              (clk         ),
    .rst              (usr_rst          ),
      // RX : ipv4_top 剥以太头后的纯 IP 包
    .ipv4_udp_axis_sdata(ip_udp_rx_data   ),
    .ipv4_udp_axis_skeep(ip_udp_rx_keep   ),
    .ipv4_udp_axis_slast(ip_udp_rx_last   ),
    .ipv4_udp_axis_svalid(ip_udp_rx_valid  ),
    .ipv4_udp_axis_susr  (ip_udp_rx_usr    ),
    .ipv4_udp_axis_sready(ip_udp_rx_ready  ),
      // RX 输出 : (PORT_NUM+1) 路 -> 顶层
    .udp_axis_mdata   (udp_axis_mdata[gi*512*(PORT_NUM+1) +: 512*(PORT_NUM+1)]),
    .udp_axis_mkeep   (udp_axis_mkeep[gi*64*(PORT_NUM+1) +: 64*(PORT_NUM+1)]),
    .udp_axis_mlast   (udp_axis_mlast[gi*(PORT_NUM+1) +: (PORT_NUM+1)]),
    .udp_axis_mvalid  (udp_axis_mvalid[gi*(PORT_NUM+1) +: (PORT_NUM+1)]),
    .udp_axis_musr    (udp_axis_musr[gi*192*(PORT_NUM+1) +: 192*(PORT_NUM+1)]),
    .udp_axis_mready  (udp_axis_mready[gi*(PORT_NUM+1) +: (PORT_NUM+1)]),
      // TX : 待发送 UDP 报文 <- 顶层
    .udp_axis_sdata   (udp_axis_sdata[gi*AXIS_WIDTH +: AXIS_WIDTH]),
    .udp_axis_skeep   (udp_axis_skeep[gi*(AXIS_WIDTH/8) +: AXIS_WIDTH/8]),
    .udp_axis_slast   (udp_axis_slast[gi]),
    .udp_axis_svalid  (udp_axis_svalid[gi]),
    .udp_axis_sready  (udp_axis_sready[gi]),
    .cfg_total_len    (cfg_total_len[gi*16 +: 16]),
    .cfg_ttl          (cfg_ttl[gi*8 +: 8]),
    .cfg_head_checksum(cfg_head_checksum[gi*16 +: 16]),
    .cfg_src_ip       (cfg_src_ip[gi*32 +: 32]),
    .cfg_dest_ip      (cfg_dest_ip[gi*32 +: 32]),
      // TX 输出 : 加完 IPv4 头的纯 IP 包 -> ipv4_top
    .ipv4_axis_mdata  (ip_udp_tx_data   ),
    .ipv4_axis_mkeep  (ip_udp_tx_keep   ),
    .ipv4_axis_mlast  (ip_udp_tx_last   ),
    .ipv4_axis_mvalid (ip_udp_tx_valid  ),
    .ipv4_axis_mready (ip_udp_tx_ready  ),
    .stat_is_df       (stat_is_df[gi]   ) 
    );

  end
  endgenerate

endmodule
`resetall
