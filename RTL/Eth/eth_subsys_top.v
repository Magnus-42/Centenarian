`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : eth_subsys_top.v
// Module Name : eth_subsys_top
// Author      : LiXintao
// Date        : 2026-10-12
// Version     : v6.0
// ----------------------------------------------------------------------------
// Description : 以太网子系统顶层（协议栈 : MAC + ARP + IPv4 + UDP + IPv6）
//
//   TX（每口）:
//     udp 应用  ─→ udp_tx_mux ──────→ udp_ipv4_tx ┐
//     用户自定义ipv4 ─────────────────────────────┴→ ipv4_tx_mux ──────→ lane1 ──────┐
//     用户自定义ipv6 ────────────────→ ipv6_tx_mux ──────→ lane2 ────────────────────┼→ eth_tx_mux
//     arp 引擎(arp_axis_m*, MAC 层完整帧, usr=ARP_PRIORITY 自带) ─→ lane0 ───────────┤      ↓
//     用户自定义mac ────────────────────────────────────────────────→ lane3 ─────────┘   pad60 → TX CDC → SLR → CMAC
//        
//   RX（每口）:
//     CMAC → SLR → RX CDC → skid → eth_type_demux → flat(RX_TYPE_NUM+1 路)
//       ch0=arp → arp_engine_top（收）
//       ch1=ipv4 → ipv4_eth_rx → ipv4_type_demux → flat(RX_TYPE_NUM+1 路)
//                ch0=udp → udp_ipv4_rx → udp_type_demux → (UDP_RX_PORT_NUM_MAX+1) 路 → 边界
//                ch1..ch4(icmp/ospf/0x06/other) → 边界
//       ch2=ipv6 → ipv6_eth_rx → ipv6_type_demux → flat(RX_TYPE_NUM+1 路) → 边界(全档)
//       ch3=用户自定义
//       ch4=other(兜底) → 边界
//
// ============================================================================

module eth_subsys_top#(
  parameter  ETH_PORT_NUM= 2 ,
  parameter  PENDING_TIME_WIDTH= 57, // 57位，10年以上
  parameter  PRIORITY_WIDTH= 4 ,
  parameter  CFG_NUM_WIDTH= 8 , // 每端口槽位中"档数/路数"计数项的表示位宽
  // ==========================================================================
  // 宽度主参数(MAX)，为所有端口的最大值
  // ==========================================================================
  parameter  [     CFG_NUM_WIDTH-1:0]        MAC_RX_TYPE_NUM_MAX= 1 ,
  parameter  [     CFG_NUM_WIDTH-1:0]        MAC_TX_TYPE_NUM_MAX= 1 ,
  parameter  [     CFG_NUM_WIDTH-1:0]        IPV4_RX_TYPE_NUM_MAX= 3 ,
  parameter  [     CFG_NUM_WIDTH-1:0]        IPV4_TX_TYPE_NUM_MAX= 3 ,
  parameter  [     CFG_NUM_WIDTH-1:0]        IPV6_RX_TYPE_NUM_MAX= 3 ,
  parameter  [     CFG_NUM_WIDTH-1:0]        IPV6_TX_TYPE_NUM_MAX= 3 ,
  parameter  [     CFG_NUM_WIDTH-1:0]        UDP_RX_PORT_NUM_MAX= 3 ,
  parameter  [     CFG_NUM_WIDTH-1:0]        UDP_TX_PORT_NUM_MAX= 8 ,
  parameter  [     CFG_NUM_WIDTH-1:0]        LOCAL_IPV4_MAC_NUM_MAX= 1 ,
  parameter  [     CFG_NUM_WIDTH-1:0]        LOCAL_DST_IPV6_MAC_NUM_MAX= 2 ,
  parameter  [     CFG_NUM_WIDTH-1:0]        LOCAL_SRC_IPV6_MAC_NUM_MAX= 2 ,
  // ==========================================================================
  // 每个网口的具体参数设置
  //   *_NUM_ARR : 每口 CFG_NUM_WIDTH bit；  *_DICT_ARR : 每口一个 MAX 宽槽位(口内取低 N 项)
  //   *_RANGE_ARR: 每口 UDP_RX_PORT_NUM_MAX 个 32bit 区间项
  // 注意: *_NUM_ARR 的每项必须写足 CFG_NUM_WIDTH 位才能不错位; 推荐零扩展写法
  //       {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'dN }} 强制指定了参数，等价于 CFG_NUM_WIDTH‘dN
  // ==========================================================================
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]MAC_RX_TYPE_NUM_ARR= {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd1 }},
  parameter  [(MAC_RX_TYPE_NUM_MAX*16)*ETH_PORT_NUM-1:0]MAC_RX_TYPE_DICT_ARR= {ETH_PORT_NUM{16'hB588}}, // 仅用户项，不能为arp\ipv4\ipv6
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]MAC_TX_TYPE_NUM_ARR= {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd1 }},
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV4_RX_TYPE_NUM_ARR= {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd3 }},
  parameter  [(IPV4_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0]IPV4_RX_TYPE_DICT_ARR= {ETH_PORT_NUM{8'h06, 8'h59, 8'h01}} ,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV4_TX_TYPE_NUM_ARR= {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd3 }},
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV6_RX_TYPE_NUM_ARR= {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd3 }},
  parameter  [(IPV6_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0]IPV6_RX_TYPE_DICT_ARR= {ETH_PORT_NUM{8'h59, 8'h3A, 8'h11}} ,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV6_TX_TYPE_NUM_ARR= {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd3 }},
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]UDP_RX_PORT_NUM_ARR= {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd3 }},
  parameter  [(UDP_RX_PORT_NUM_MAX*32)*ETH_PORT_NUM-1:0]UDP_DST_PORT_RANGE_ARR= {ETH_PORT_NUM{32'h00080002, 32'h00010001, 32'h00000000}} , // 端口禁止重叠
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]UDP_TX_PORT_NUM_ARR= {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd8 }},
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_IPV4_MAC_NUM_ARR= {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd1 }},
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_DST_IPV6_MAC_NUM_ARR= {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd2 }},
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_SRC_IPV6_MAC_NUM_ARR= {ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd2 }},
  parameter  [PENDING_TIME_WIDTH-1:0]        PENDING_TIME_DFL= 57'd400_000_000, // 1s @400MHz
  parameter  [(PENDING_TIME_WIDTH)*ETH_PORT_NUM-1:0]CFG_PENDING_TIME_ARR= {ETH_PORT_NUM{PENDING_TIME_DFL}},
  // ---- 内部推导（不对外暴露；均由 MAX 推导）----
  localparam MAC_TX_N_MAX= (MAC_TX_TYPE_NUM_MAX > 0) ? MAC_TX_TYPE_NUM_MAX : 1,
  localparam MAC_TX_TOT_MAX= MAC_TX_N_MAX + 3,
  localparam IPV4_TX_N_MAX= (IPV4_TX_TYPE_NUM_MAX > 0) ? IPV4_TX_TYPE_NUM_MAX : 1,
  localparam IPV4_TX_TOT_MAX= IPV4_TX_N_MAX + 1,
  localparam IPV6_TX_N_MAX= (IPV6_TX_TYPE_NUM_MAX > 0) ? IPV6_TX_TYPE_NUM_MAX : 1,
  localparam IPV6_TX_TOT_MAX= IPV6_TX_N_MAX,
  localparam UDP_TX_N_MAX= (UDP_TX_PORT_NUM_MAX > 0) ? UDP_TX_PORT_NUM_MAX : 1,
  localparam TX_IDX_W= (MAC_TX_TOT_MAX <= 1) ? 1 : $clog2(MAC_TX_TOT_MAX),
  localparam [    PRIORITY_WIDTH-1:0]        ARP_PRIORITY= {PRIORITY_WIDTH{1'b1}}// ARP 帧固定最高优先级（由 arp_eth_tx 写入 arp_axis_musr）
)(
  input  wire                                          sys_clk         ,
  input  wire                                          clk             ,// 用户时钟(400M, 顶层生成)
  input  wire                                          clk_locked      ,// 时钟锁定指示(顶层提供)
  output wire                                          qsfp_gt_rst     ,// 交由顶层做复位同步
  input  wire                                          usr_rst         ,// 顶层生成的复位

  // ============================================================================
  // GT / QSFP : 每口 4 lane，按口序打包
  // ============================================================================
  output wire          [    4*ETH_PORT_NUM-1:0]        gt_txp_out      ,
  output wire          [    4*ETH_PORT_NUM-1:0]        gt_txn_out      ,
  input  wire          [    4*ETH_PORT_NUM-1:0]        gt_rxp_in       ,
  input  wire          [    4*ETH_PORT_NUM-1:0]        gt_rxn_in       ,
  input  wire          [      ETH_PORT_NUM-1:0]        gt_ref_clk_p    ,
  input  wire          [      ETH_PORT_NUM-1:0]        gt_ref_clk_n    ,
  output wire          [      ETH_PORT_NUM-1:0]        qsfp_rstn_port  ,
  output wire          [      ETH_PORT_NUM-1:0]        qsfp_lp_mode_port,
  output wire          [      ETH_PORT_NUM-1:0]        qsfp_seln_port  ,
  input  wire          [      ETH_PORT_NUM-1:0]        qsfp_prsn_port  ,
  output wire          [      ETH_PORT_NUM-1:0]        qsfp_led_port   ,

  // ============================================================================
  // ARP : 本机配置（每口 P_LOC_IPV4_N 套，按口序打包）
  // ============================================================================
  input  wire          [48*LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_local_mac   ,
  input  wire          [32*LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_local_ip    ,
  input  wire          [32*LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_gateway_ip  ,
  input  wire          [32*LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_subnet_mask ,

  // ============================================================================
  // IPv6 : IP->MAC 映射表
  // ============================================================================
  input  wire          [128*LOCAL_DST_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_dest_match_ipv6,
  input  wire          [48*LOCAL_DST_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_dest_match_mac,
  input  wire          [128*LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_src_match_ipv6,
  input  wire          [48*LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_src_match_mac,

  // ============================================================================
  // MAC 层 flat 通道
  // ============================================================================
  output wire          [512*(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mdata  ,
  output wire          [64*(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mkeep  ,
  output wire          [(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mlast  ,
  output wire          [(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mvalid ,
  input  wire          [(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mready ,

  input  wire          [512*MAC_TX_N_MAX*ETH_PORT_NUM-1:0]mac_axis_sdata  ,
  input  wire          [64*MAC_TX_N_MAX*ETH_PORT_NUM-1:0]mac_axis_skeep  ,
  input  wire          [MAC_TX_N_MAX*ETH_PORT_NUM-1:0] mac_axis_slast  ,
  input  wire          [MAC_TX_N_MAX*ETH_PORT_NUM-1:0] mac_axis_svalid ,
  input  wire          [PRIORITY_WIDTH*MAC_TX_N_MAX*ETH_PORT_NUM-1:0]mac_axis_susr   ,
  output wire          [MAC_TX_N_MAX*ETH_PORT_NUM-1:0] mac_axis_sready ,

  // ============================================================================
  // IPv4 层 flat 通道
  // ============================================================================
  output wire          [512*(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_mdata ,
  output wire          [64*(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_mkeep ,
  output wire          [(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_mlast ,
  output wire          [(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_mvalid,
  output wire          [97*(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_musr  ,
  input  wire          [(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_mready,

  input  wire          [512*IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_sdata ,
  input  wire          [64*IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_skeep ,
  input  wire          [IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_slast ,
  input  wire          [IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_svalid,
  input  wire          [PRIORITY_WIDTH*IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_susr  ,
  output wire          [IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_sready,

  // ============================================================================
  // IPv6 层 flat 通道
  // ============================================================================
  output wire          [512*(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_mdata ,
  output wire          [64*(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_mkeep ,
  output wire          [(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_mlast ,
  output wire          [(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_mvalid,
  output wire          [97*(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_musr  ,
  input  wire          [(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_mready,

  input  wire          [512*IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_sdata ,
  input  wire          [64*IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_skeep ,
  input  wire          [IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_slast ,
  input  wire          [IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_svalid,
  input  wire          [PRIORITY_WIDTH*IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_susr  ,
  output wire          [IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_sready,

  // ============================================================================
  // UDP 层 flat 通道
  // ============================================================================
  output wire          [512*(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_mdata  ,
  output wire          [64*(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_mkeep  ,
  output wire          [(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_mlast  ,
  output wire          [(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_mvalid ,
  output wire          [193*(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_musr   ,
  input  wire          [(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_mready ,

  input  wire          [512*UDP_TX_N_MAX*ETH_PORT_NUM-1:0]udp_axis_sdata  ,
  input  wire          [64*UDP_TX_N_MAX*ETH_PORT_NUM-1:0]udp_axis_skeep  ,
  input  wire          [UDP_TX_N_MAX*ETH_PORT_NUM-1:0] udp_axis_slast  ,
  input  wire          [UDP_TX_N_MAX*ETH_PORT_NUM-1:0] udp_axis_svalid ,
  input  wire          [PRIORITY_WIDTH*UDP_TX_N_MAX*ETH_PORT_NUM-1:0]udp_axis_susr   ,
  output wire          [UDP_TX_N_MAX*ETH_PORT_NUM-1:0] udp_axis_sready ,

  input  wire          [   16*ETH_PORT_NUM-1:0]        cfg_total_len   ,
  input  wire          [    8*ETH_PORT_NUM-1:0]        cfg_ttl         ,
  input  wire          [   16*ETH_PORT_NUM-1:0]        cfg_head_checksum,
  input  wire          [   32*ETH_PORT_NUM-1:0]        cfg_src_ip      ,
  input  wire          [   32*ETH_PORT_NUM-1:0]        cfg_dest_ip     ,

  // ============================================================================
  // 状态（按口序打包）
  // ============================================================================
  output wire          [      ETH_PORT_NUM-1:0]        stat_is_df      ,
  output wire          [TX_IDX_W*ETH_PORT_NUM-1:0]     stat_tx_active_port,
  output wire          [      ETH_PORT_NUM-1:0]        stat_tx_idle    ,
  output wire          [      ETH_PORT_NUM-1:0]        stat_arp_rx_error,
  output wire          [      ETH_PORT_NUM-1:0]        stat_arp_ack_ovf,
  output wire          [      ETH_PORT_NUM-1:0]        stat_arp_pend_ovf,
  output wire          [      ETH_PORT_NUM-1:0]        stat_arp_no_resp,
  output wire          [      ETH_PORT_NUM-1:0]        stat_arp_pend_clr,
  output wire          [      ETH_PORT_NUM-1:0]        stat_arp_cache_clr,
  output wire          [      ETH_PORT_NUM-1:0]        stat_arp_src_not_local,
  output wire          [      ETH_PORT_NUM-1:0]        stat_ipv6_drop_pulse 
);
  // ============================================================================
  // 时钟 / 复位
  // ============================================================================
  wire                 [      ETH_PORT_NUM-1:0]        gt_txusrclk      ;
  wire                 [      ETH_PORT_NUM-1:0]        gt_rxusrclk      ;
  wire                 [      ETH_PORT_NUM-1:0]        usr_tx_reset     ;
  wire                 [      ETH_PORT_NUM-1:0]        usr_rx_reset     ;

  assign  qsfp_gt_rst      = |usr_tx_reset | |usr_rx_reset;

  genvar gi;
  generate
  for (gi = 0; gi < ETH_PORT_NUM; gi = gi + 1) begin : gen_port

    // -----------------------------------------------------------------------
    // 本口配置(从槽位向量解包；口内只用低 N_i 项, N=0 走 NEFF 占位)
    // -----------------------------------------------------------------------
  localparam [     CFG_NUM_WIDTH-1:0]        P_MAC_RX_N= MAC_RX_TYPE_NUM_ARR [gi*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
  localparam [     CFG_NUM_WIDTH-1:0]        P_MAC_RX_NEFF= (P_MAC_RX_N    > 0) ? P_MAC_RX_N    : 1;
  localparam [     CFG_NUM_WIDTH-1:0]        P_MAC_TX_N= MAC_TX_TYPE_NUM_ARR [gi*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
  localparam [     CFG_NUM_WIDTH-1:0]        P_MAC_TX_NEFF= (P_MAC_TX_N    > 0) ? P_MAC_TX_N    : 1;
  localparam [     CFG_NUM_WIDTH-1:0]        P_IPV4_RX_N= IPV4_RX_TYPE_NUM_ARR[gi*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
  localparam [     CFG_NUM_WIDTH-1:0]        P_IPV4_RX_NEFF= (P_IPV4_RX_N   > 0) ? P_IPV4_RX_N   : 1;
  localparam [     CFG_NUM_WIDTH-1:0]        P_IPV4_TX_N= IPV4_TX_TYPE_NUM_ARR[gi*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
  localparam [     CFG_NUM_WIDTH-1:0]        P_IPV4_TX_NEFF= (P_IPV4_TX_N   > 0) ? P_IPV4_TX_N   : 1;
  localparam [     CFG_NUM_WIDTH-1:0]        P_IPV6_RX_N= IPV6_RX_TYPE_NUM_ARR[gi*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
  localparam [     CFG_NUM_WIDTH-1:0]        P_IPV6_RX_NEFF= (P_IPV6_RX_N   > 0) ? P_IPV6_RX_N   : 1;
  localparam [     CFG_NUM_WIDTH-1:0]        P_IPV6_TX_N= IPV6_TX_TYPE_NUM_ARR[gi*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
  localparam [     CFG_NUM_WIDTH-1:0]        P_IPV6_TX_NEFF= (P_IPV6_TX_N   > 0) ? P_IPV6_TX_N   : 1;
  localparam [     CFG_NUM_WIDTH-1:0]        P_UDP_RX_N= UDP_RX_PORT_NUM_ARR[gi*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
  localparam [     CFG_NUM_WIDTH-1:0]        P_UDP_RX_NEFF= (P_UDP_RX_N    > 0) ? P_UDP_RX_N    : 1;
  localparam [     CFG_NUM_WIDTH-1:0]        P_UDP_TX_N= UDP_TX_PORT_NUM_ARR[gi*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
  localparam [     CFG_NUM_WIDTH-1:0]        P_LOC_IPV4_N= LOCAL_IPV4_MAC_NUM_ARR[gi*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
  localparam [     CFG_NUM_WIDTH-1:0]        P_LOC_DST6_N= LOCAL_DST_IPV6_MAC_NUM_ARR[gi*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
  localparam [     CFG_NUM_WIDTH-1:0]        P_LOC_SRC6_N= LOCAL_SRC_IPV6_MAC_NUM_ARR[gi*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
    // 本口派生(内部 flat 位宽)
  localparam P_MAC_RX_TOT= P_MAC_RX_N + 3;
  localparam P_MAC_TX_TOT= P_MAC_TX_NEFF + 3;
  localparam P_IPV4_RX_TOT= P_IPV4_RX_N + 1;
  localparam P_IPV4_TX_TOT= P_IPV4_TX_NEFF + 1;
  localparam P_IPV6_TX_TOT= P_IPV6_TX_NEFF;
    // 本口槽位(MAX 宽)与拼装后的完整 DICT(本口宽)
  localparam [MAC_RX_TYPE_NUM_MAX*16-1:0]    p_mac_rx_dict= MAC_RX_TYPE_DICT_ARR [gi*(MAC_RX_TYPE_NUM_MAX*16) +: MAC_RX_TYPE_NUM_MAX*16];
  localparam [IPV4_RX_TYPE_NUM_MAX*8-1:0]    p_ipv4_rx_dict= IPV4_RX_TYPE_DICT_ARR[gi*(IPV4_RX_TYPE_NUM_MAX*8)  +: IPV4_RX_TYPE_NUM_MAX*8];
  localparam [IPV6_RX_TYPE_NUM_MAX*8-1:0]    p_ipv6_rx_dict= IPV6_RX_TYPE_DICT_ARR[gi*(IPV6_RX_TYPE_NUM_MAX*8)  +: IPV6_RX_TYPE_NUM_MAX*8];
  localparam [UDP_RX_PORT_NUM_MAX*32-1:0]    p_udp_range= UDP_DST_PORT_RANGE_ARR [gi*(UDP_RX_PORT_NUM_MAX*32) +: UDP_RX_PORT_NUM_MAX*32];
  localparam [PENDING_TIME_WIDTH-1:0]        p_pending_t= CFG_PENDING_TIME_ARR  [gi*PENDING_TIME_WIDTH +: PENDING_TIME_WIDTH];
  localparam [   P_MAC_RX_TOT*16-1:0]        p_mac_rx_dict_int= { p_mac_rx_dict [P_MAC_RX_NEFF*16-1:0], 16'hDD86, 16'h0008, 16'h0608 };
  localparam [   P_IPV4_RX_TOT*8-1:0]        p_ipv4_rx_dict_int= { p_ipv4_rx_dict[P_IPV4_RX_NEFF*8-1:0], 8'h11 };

    // ------------------------------------------------------------------------
    // 每口内部连线
    // ------------------------------------------------------------------------
    // eth_top RX flat 输出（P_MAC_RX_TOT+1 档: ch0=arp ch1=ipv4 ch2=ipv6 | ch3..=用户段 | 末档=other）
  wire                 [512*(P_MAC_RX_TOT+1)-1:0]      macflat_rx_data  ;
  wire                 [64*(P_MAC_RX_TOT+1)-1:0]       macflat_rx_keep  ;
  wire                 [  (P_MAC_RX_TOT+1)-1:0]        macflat_rx_last  ;
  wire                 [  (P_MAC_RX_TOT+1)-1:0]        macflat_rx_valid ;
  wire                 [  (P_MAC_RX_TOT+1)-1:0]        macflat_rx_ready ;
  wire                 [  (P_MAC_RX_TOT+1)-1:0]        macflat_rx_usr   ;// 每档 1bit 流标记（首拍）

    // eth_top TX flat 输入（T-B: lane0=arp lane1=ipv4 lane2=ipv6 | lane3..=用户段）
  wire                 [  512*P_MAC_TX_TOT-1:0]        eth_tx_s_data    ;
  wire                 [   64*P_MAC_TX_TOT-1:0]        eth_tx_s_keep    ;
  wire                 [      P_MAC_TX_TOT-1:0]        eth_tx_s_last    ;
  wire                 [      P_MAC_TX_TOT-1:0]        eth_tx_s_valid   ;
  wire                 [PRIORITY_WIDTH*P_MAC_TX_TOT-1:0]eth_tx_s_usr     ;
  wire                 [      P_MAC_TX_TOT-1:0]        eth_tx_s_ready   ;

    // ipv4_top RX flat 输出（P_IPV4_RX_TOT+1 档: ch0=udp(内部) | ch1..=用户段 | 末档=other）
  wire                 [512*(P_IPV4_RX_TOT+1)-1:0]     ipv4flat_rx_data ;
  wire                 [64*(P_IPV4_RX_TOT+1)-1:0]      ipv4flat_rx_keep ;
  wire                 [ (P_IPV4_RX_TOT+1)-1:0]        ipv4flat_rx_last ;
  wire                 [ (P_IPV4_RX_TOT+1)-1:0]        ipv4flat_rx_valid;
  wire                 [97*(P_IPV4_RX_TOT+1)-1:0]      ipv4flat_rx_usr  ;
  wire                 [ (P_IPV4_RX_TOT+1)-1:0]        ipv4flat_rx_ready;

    // ipv6_top RX flat 输出（RX_TYPE_NUM+1 路: ch0=udp ch1=icmpv6 ch2=ospf ch3=other）
  wire                 [512*(P_IPV6_RX_N+1)-1:0]       ipv6flat_rx_data ;
  wire                 [64*(P_IPV6_RX_N+1)-1:0]        ipv6flat_rx_keep ;
  wire                 [   (P_IPV6_RX_N+1)-1:0]        ipv6flat_rx_last ;
  wire                 [   (P_IPV6_RX_N+1)-1:0]        ipv6flat_rx_valid;
  wire                 [97*(P_IPV6_RX_N+1)-1:0]        ipv6flat_rx_usr  ;
  wire                 [   (P_IPV6_RX_N+1)-1:0]        ipv6flat_rx_ready;

    // ipv4_top TX flat 输入（lane0=udp(内部) | lane1..=用户段）
  wire                 [ 512*P_IPV4_TX_TOT-1:0]        ipv4_tx_s_data   ;
  wire                 [  64*P_IPV4_TX_TOT-1:0]        ipv4_tx_s_keep   ;
  wire                 [     P_IPV4_TX_TOT-1:0]        ipv4_tx_s_last   ;
  wire                 [     P_IPV4_TX_TOT-1:0]        ipv4_tx_s_valid  ;
  wire                 [PRIORITY_WIDTH*P_IPV4_TX_TOT-1:0]ipv4_tx_s_usr    ;
  wire                 [     P_IPV4_TX_TOT-1:0]        ipv4_tx_s_ready  ;

    // udp_top TX flat 输入（P_UDP_TX_N 路：与边界 1:1 直连）
  wire                 [    512*P_UDP_TX_N-1:0]        udp_tx_s_data    ;
  wire                 [     64*P_UDP_TX_N-1:0]        udp_tx_s_keep    ;
  wire                 [        P_UDP_TX_N-1:0]        udp_tx_s_last    ;
  wire                 [        P_UDP_TX_N-1:0]        udp_tx_s_valid   ;
  wire                 [PRIORITY_WIDTH*P_UDP_TX_N-1:0] udp_tx_s_usr     ;
  wire                 [        P_UDP_TX_N-1:0]        udp_tx_s_ready   ;

  wire                 [ 512*P_IPV6_TX_TOT-1:0]        ipv6_tx_s_data   ;
  wire                 [  64*P_IPV6_TX_TOT-1:0]        ipv6_tx_s_keep   ;
  wire                 [     P_IPV6_TX_TOT-1:0]        ipv6_tx_s_last   ;
  wire                 [     P_IPV6_TX_TOT-1:0]        ipv6_tx_s_valid  ;
  wire                 [PRIORITY_WIDTH*P_IPV6_TX_TOT-1:0]ipv6_tx_s_usr    ;
  wire                 [     P_IPV6_TX_TOT-1:0]        ipv6_tx_s_ready  ;

    // 单路（各链的出口 / ARP 的收发）
  wire                 [                 511:0]        ip_udp_tx_data   ;
  wire                 [                  63:0]        ip_udp_tx_keep   ;
  wire                                                 ip_udp_tx_last   ;
  wire                                                 ip_udp_tx_valid  ;
  wire                 [    PRIORITY_WIDTH-1:0]        ip_udp_tx_usr    ;
  wire                                                 ip_udp_tx_ready  ;
  wire                 [                 511:0]        ip_udp_rx_data   ;
  wire                 [                  63:0]        ip_udp_rx_keep   ;
  wire                                                 ip_udp_rx_last   ;
  wire                                                 ip_udp_rx_valid  ;
  wire                 [                  96:0]        ip_udp_rx_usr    ;
  wire                                                 ip_udp_rx_ready  ;
  wire                 [                 511:0]        mac_arp_rx_data  ;
  wire                 [                  63:0]        mac_arp_rx_keep  ;
  wire                                                 mac_arp_rx_last  ;
  wire                                                 mac_arp_rx_valid ;
  wire                                                 mac_arp_rx_usr   ;
  wire                                                 mac_arp_rx_ready ;
  wire                 [                 511:0]        arp_tx_data      ;
  wire                 [                  63:0]        arp_tx_keep      ;
  wire                                                 arp_tx_last      ;
  wire                                                 arp_tx_valid     ;
  wire                 [    PRIORITY_WIDTH-1:0]        arp_tx_usr       ;
  wire                                                 arp_tx_ready     ;
  wire                 [                 511:0]        ipv4_tx_m_data   ;
  wire                 [                  63:0]        ipv4_tx_m_keep   ;
  wire                                                 ipv4_tx_m_last   ;
  wire                                                 ipv4_tx_m_valid  ;
  wire                 [    PRIORITY_WIDTH-1:0]        ipv4_tx_m_usr    ;
  wire                                                 ipv4_tx_m_ready  ;
  wire                 [                 511:0]        ipv6_tx_m_data   ;
  wire                 [                  63:0]        ipv6_tx_m_keep   ;
  wire                                                 ipv6_tx_m_last   ;
  wire                                                 ipv6_tx_m_valid  ;
  wire                 [    PRIORITY_WIDTH-1:0]        ipv6_tx_m_usr    ;
  wire                                                 ipv6_tx_m_ready  ;
  wire                 [                 511:0]        mac_ipv4_rx_data ;
  wire                 [                  63:0]        mac_ipv4_rx_keep ;
  wire                                                 mac_ipv4_rx_last ;
  wire                                                 mac_ipv4_rx_valid;
  wire                                                 mac_ipv4_rx_usr  ;
  wire                                                 mac_ipv4_rx_ready;
  wire                 [                 511:0]        mac_ipv6_rx_data ;
  wire                 [                  63:0]        mac_ipv6_rx_keep ;
  wire                                                 mac_ipv6_rx_last ;
  wire                                                 mac_ipv6_rx_valid;
  wire                                                 mac_ipv6_rx_usr  ;
  wire                                                 mac_ipv6_rx_ready;
    // ARP 查询握手（控制通路, 非数据）
  wire                 [                  31:0]        arp_q_src_ip     ;
  wire                 [                  31:0]        arp_q_dst_ip     ;
  wire                                                 arp_q_valid      ;
  wire                 [                  47:0]        arp_r_dst_mac    ;
  wire                 [                  47:0]        arp_r_src_mac    ;
  wire                                                 arp_r_miss       ;
  wire                                                 arp_r_valid      ;

    // ------------------------------------------------------------------------
    // 1) MAC 层（每口一套）
    // ------------------------------------------------------------------------
    eth_top #(
    .PORT_SEL         (gi               ),// 0=cmac_a_if, 1=cmac_b_if, ...
    .RX_TYPE_NUM      (P_MAC_RX_TOT     ),// 总档数 = 用户档数 + 3(内部 arp/ipv4/ipv6)
    .RX_TYPE_DICT     (p_mac_rx_dict_int),// 用户 DICT + 内部三项(最右端=ch0)
    .TX_TYPE_NUM      (P_MAC_TX_TOT     ),// 总路数 = 用户路数 + 3(内部 arp/ipv4/ipv6)
    .AXIS_TX_USER_WIDTH(PRIORITY_WIDTH   ),
    .CDC_FIFO_DEPTH   (512              ) 
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
    .clk              (clk              ),
    .rst              (usr_rst          ),
    .fifo_tx_rst      (usr_rst          ),
    // RX flat 流输出
    .mac_axis_mdata   (macflat_rx_data  ),
    .mac_axis_mkeep   (macflat_rx_keep  ),
    .mac_axis_mlast   (macflat_rx_last  ),
    .mac_axis_mvalid  (macflat_rx_valid ),
    .mac_axis_musr    (macflat_rx_usr   ),
    .mac_axis_mready  (macflat_rx_ready ),
    // TX flat 流入口（P_MAC_TX_TOT 路，lane0=arp(内部) / lane1=ipv4 帧(内部) / lane2=ipv6 帧(内部) / lane3..=用户自定义段）
    .mac_axis_sdata   (eth_tx_s_data    ),
    .mac_axis_skeep   (eth_tx_s_keep    ),
    .mac_axis_slast   (eth_tx_s_last    ),
    .mac_axis_svalid  (eth_tx_s_valid   ),
    .mac_axis_susr    (eth_tx_s_usr     ),
    .mac_axis_sready  (eth_tx_s_ready   ),
    .stat_tx_active_port(stat_tx_active_port[gi*TX_IDX_W +: TX_IDX_W]),
    .stat_tx_idle     (stat_tx_idle[gi] ) 
    );

  // ------------------------------------------------------------------------
  //     lane0=arp(内部) / lane1=ipv4(内部) / lane2=ipv6(内部) / lane3..=用户自定义段(P_MAC_TX_N 路)
  // ------------------------------------------------------------------------
  assign eth_tx_s_data  = { mac_axis_sdata[gi*(512*MAC_TX_N_MAX) +: 512*P_MAC_TX_N],
                            ipv6_tx_m_data,
                            ipv4_tx_m_data,
                            arp_tx_data };
  assign eth_tx_s_keep  = { mac_axis_skeep[gi*( 64*MAC_TX_N_MAX) +:  64*P_MAC_TX_N],
                            ipv6_tx_m_keep,
                            ipv4_tx_m_keep,
                            arp_tx_keep };
  assign eth_tx_s_last  = { mac_axis_slast[gi*MAC_TX_N_MAX +: P_MAC_TX_N],
                            ipv6_tx_m_last,
                            ipv4_tx_m_last,
                            arp_tx_last };
  assign eth_tx_s_valid = { (P_MAC_TX_N > 0) ? mac_axis_svalid[gi*MAC_TX_N_MAX +: P_MAC_TX_N] : {P_MAC_TX_N{1'b0}},
                            ipv6_tx_m_valid,
                            ipv4_tx_m_valid,
                            arp_tx_valid };
  assign eth_tx_s_usr   = { (P_MAC_TX_N > 0) ? mac_axis_susr[gi*(PRIORITY_WIDTH*MAC_TX_N_MAX) +: PRIORITY_WIDTH*P_MAC_TX_N] : {PRIORITY_WIDTH*P_MAC_TX_N{1'b0}},
                            ipv6_tx_m_usr,
                            ipv4_tx_m_usr,
                            arp_tx_usr };
  // ready 解包（lane0=arp / lane1=ipv4 / lane2=ipv6 / lane3..=用户段）
  assign  arp_tx_ready     = eth_tx_s_ready[0];
  assign  ipv4_tx_m_ready  = eth_tx_s_ready[1];
  assign  ipv6_tx_m_ready  = eth_tx_s_ready[2];
  assign  mac_axis_sready[gi*MAC_TX_N_MAX +: P_MAC_TX_N]= eth_tx_s_ready[3 +: P_MAC_TX_N];

  // ------------------------------------------------------------------------
  //     ch0=arp → arp 引擎 | ch1=ipv4 → ipv4_top | ch2=ipv6 → ipv6_top
  // ------------------------------------------------------------------------
  assign  mac_arp_rx_data  = macflat_rx_data [0*512 +: 512];
  assign  mac_arp_rx_keep  = macflat_rx_keep [0* 64 +:  64];
  assign  mac_arp_rx_last  = macflat_rx_last [0];
  assign  mac_arp_rx_valid = macflat_rx_valid[0];
  assign  mac_arp_rx_usr   = macflat_rx_usr[0];
  assign  macflat_rx_ready[0]= mac_arp_rx_ready ;

  assign  mac_ipv4_rx_data = macflat_rx_data [1*512 +: 512];
  assign  mac_ipv4_rx_keep = macflat_rx_keep [1* 64 +:  64];
  assign  mac_ipv4_rx_last = macflat_rx_last [1];
  assign  mac_ipv4_rx_valid= macflat_rx_valid[1];
  assign  mac_ipv4_rx_usr  = macflat_rx_usr[1];
  assign  macflat_rx_ready[1]= mac_ipv4_rx_ready;

  assign  mac_ipv6_rx_data = macflat_rx_data [2*512 +: 512];
  assign  mac_ipv6_rx_keep = macflat_rx_keep [2* 64 +:  64];
  assign  mac_ipv6_rx_last = macflat_rx_last [2];
  assign  mac_ipv6_rx_valid= macflat_rx_valid[2];
  assign  mac_ipv6_rx_usr  = macflat_rx_usr[2];
  assign  macflat_rx_ready[2]= mac_ipv6_rx_ready;

  assign  mac_axis_mdata [gi*(512*(MAC_RX_TYPE_NUM_MAX+1)) +: 512*(P_MAC_RX_N+1)]= macflat_rx_data [3*512 +: (P_MAC_RX_N+1)*512];// 用户段 + other
  assign  mac_axis_mkeep [gi*( 64*(MAC_RX_TYPE_NUM_MAX+1)) +:  64*(P_MAC_RX_N+1)]= macflat_rx_keep [3* 64 +: (P_MAC_RX_N+1)* 64];
  assign  mac_axis_mlast [gi*(MAC_RX_TYPE_NUM_MAX+1) +: (P_MAC_RX_N+1)]= macflat_rx_last [3 +: (P_MAC_RX_N+1)];
  assign  mac_axis_mvalid[gi*(MAC_RX_TYPE_NUM_MAX+1) +: (P_MAC_RX_N+1)]= macflat_rx_valid[3 +: (P_MAC_RX_N+1)];
  assign  macflat_rx_ready[3 +: (P_MAC_RX_N+1)]= mac_axis_mready[gi*(MAC_RX_TYPE_NUM_MAX+1) +: (P_MAC_RX_N+1)];
  genvar pk;
  for (pk = P_MAC_RX_N+1; pk <= MAC_RX_TYPE_NUM_MAX; pk = pk + 1) begin : g_pad_mac_rx
  assign  mac_axis_mdata [(gi*(MAC_RX_TYPE_NUM_MAX+1)+pk)*512 +: 512]= 512'd0           ;
  assign  mac_axis_mkeep [(gi*(MAC_RX_TYPE_NUM_MAX+1)+pk)* 64 +:  64]= 64'd0            ;
  assign  mac_axis_mlast [ gi*(MAC_RX_TYPE_NUM_MAX+1)+pk]= 1'b0             ;
  assign  mac_axis_mvalid[gi*(MAC_RX_TYPE_NUM_MAX+1)+pk]= 1'b0             ;
  end

  arp_engine_top #(
    .AXIS_WIDTH       (512              ),
    .LOCAL_IP_NUM     (P_LOC_IPV4_N     ),
    .PENDING_TIME_WIDTH(PENDING_TIME_WIDTH),
    .AXIS_TX_USR_WID  (PRIORITY_WIDTH   ),
    .ARP_PRIORITY     (ARP_PRIORITY     ) 
  ) u_arp_eng (
    .clk              (clk              ),
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
    .arp_axis_susr    (mac_arp_rx_usr   ),
    .arp_axis_sready  (mac_arp_rx_ready ),
    .arp_axis_mdata   (arp_tx_data      ),
    .arp_axis_mkeep   (arp_tx_keep      ),
    .arp_axis_mvalid  (arp_tx_valid     ),
    .arp_axis_mlast   (arp_tx_last      ),
    .arp_axis_musr    (arp_tx_usr       ),
    .arp_axis_mready  (arp_tx_ready     ),
    .cfg_local_ip     (cfg_local_ip   [gi*32*P_LOC_IPV4_N +: 32*P_LOC_IPV4_N]),
    .cfg_local_mac    (cfg_local_mac  [gi*48*P_LOC_IPV4_N +: 48*P_LOC_IPV4_N]),
    .cfg_gateway_ip   (cfg_gateway_ip [gi*32*P_LOC_IPV4_N +: 32*P_LOC_IPV4_N]),
    .cfg_subnet_mask  (cfg_subnet_mask[gi*32*P_LOC_IPV4_N +: 32*P_LOC_IPV4_N]),
    .cfg_pending_time (p_pending_t      ),
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


  ipv4_top #(
    .RX_TYPE_NUM      (P_IPV4_RX_TOT    ),
    .RX_TYPE_DICT     (p_ipv4_rx_dict_int),
    .TX_TYPE_NUM      (P_IPV4_TX_TOT    ),
    .AXIS_USER_WIDTH  (PRIORITY_WIDTH   ) 
  ) u_ipv4_top (
    .clk              (clk              ),
    .rst              (usr_rst          ),
    // RX : eth_top 分出的 IPv4 以太帧
    .eth_ipv4_axis_sdata(mac_ipv4_rx_data ),
    .eth_ipv4_axis_skeep(mac_ipv4_rx_keep ),
    .eth_ipv4_axis_slast(mac_ipv4_rx_last ),
    .eth_ipv4_axis_svalid(mac_ipv4_rx_valid),
    .eth_ipv4_axis_susr(mac_ipv4_rx_usr  ),
    .eth_ipv4_axis_sready(mac_ipv4_rx_ready),
    // RX flat 输出
    .ipv4_axis_mdata  (ipv4flat_rx_data ),
    .ipv4_axis_mkeep  (ipv4flat_rx_keep ),
    .ipv4_axis_mlast  (ipv4flat_rx_last ),
    .ipv4_axis_mvalid (ipv4flat_rx_valid),
    .ipv4_axis_musr   (ipv4flat_rx_usr  ),
    .ipv4_axis_mready (ipv4flat_rx_ready),
    // TX flat 输入
    .ipv4_axis_sdata  (ipv4_tx_s_data   ),
    .ipv4_axis_skeep  (ipv4_tx_s_keep   ),
    .ipv4_axis_slast  (ipv4_tx_s_last   ),
    .ipv4_axis_svalid (ipv4_tx_s_valid  ),
    .ipv4_axis_susr   (ipv4_tx_s_usr    ),
    .ipv4_axis_sready (ipv4_tx_s_ready  ),
    // TX 输出 : 完整以太帧（已插 14B 以太头
    .eth_tx_axis_mdata(ipv4_tx_m_data   ),
    .eth_tx_axis_mkeep(ipv4_tx_m_keep   ),
    .eth_tx_axis_mlast(ipv4_tx_m_last   ),
    .eth_tx_axis_mvalid(ipv4_tx_m_valid  ),
    .eth_tx_axis_musr (ipv4_tx_m_usr    ),
    .eth_tx_axis_mready(ipv4_tx_m_ready  ),
    // ARP 查询握手（控制）⇄ arp_engine_top
    .query_src_ip     (arp_q_src_ip     ),
    .query_dst_ip     (arp_q_dst_ip     ),
    .query_valid_pulse(arp_q_valid      ),
    .arp_dst_mac      (arp_r_dst_mac    ),
    .arp_src_mac      (arp_r_src_mac    ),
    .arp_miss         (arp_r_miss       ),
    .arp_valid        (arp_r_valid      ),
    .stat_tx_active_port(                 ),// 调试口, 预留
    .stat_tx_idle     (                 ) // 调试口, 预留
  );

  assign  ipv4_tx_s_data   = { ipv4_axis_sdata[gi*(512*IPV4_TX_N_MAX) +: 512*P_IPV4_TX_N], ip_udp_tx_data };
  assign  ipv4_tx_s_keep   = { ipv4_axis_skeep[gi*( 64*IPV4_TX_N_MAX) +:  64*P_IPV4_TX_N], ip_udp_tx_keep };
  assign  ipv4_tx_s_last   = { ipv4_axis_slast[gi*IPV4_TX_N_MAX +: P_IPV4_TX_N], ip_udp_tx_last };
  assign  ipv4_tx_s_valid  = { (P_IPV4_TX_N > 0) ? ipv4_axis_svalid[gi*IPV4_TX_N_MAX +: P_IPV4_TX_N] : {P_IPV4_TX_N{1'b0}}, ip_udp_tx_valid };
  assign  ipv4_tx_s_usr    = { (P_IPV4_TX_N > 0) ? ipv4_axis_susr[gi*(PRIORITY_WIDTH*IPV4_TX_N_MAX) +: PRIORITY_WIDTH*P_IPV4_TX_N] : {PRIORITY_WIDTH*P_IPV4_TX_N{1'b0}}, ip_udp_tx_usr };
  assign  ip_udp_tx_ready  = ipv4_tx_s_ready[0];
  assign  ipv4_axis_sready[gi*IPV4_TX_N_MAX +: P_IPV4_TX_N]= ipv4_tx_s_ready[1 +: P_IPV4_TX_N];


  assign  ip_udp_rx_data   = ipv4flat_rx_data [0*512 +: 512];
  assign  ip_udp_rx_keep   = ipv4flat_rx_keep [0* 64 +:  64];
  assign  ip_udp_rx_last   = ipv4flat_rx_last [0];
  assign  ip_udp_rx_valid  = ipv4flat_rx_valid[0];
  assign  ip_udp_rx_usr    = ipv4flat_rx_usr  [0* 97 +:  97];
  assign  ipv4flat_rx_ready[0]= ip_udp_rx_ready  ;

  assign  ipv4_axis_mdata [gi*(512*(IPV4_RX_TYPE_NUM_MAX+1)) +: 512*(P_IPV4_RX_N+1)]= ipv4flat_rx_data [1*512 +: (P_IPV4_RX_N+1)*512];// 用户段 + other
  assign  ipv4_axis_mkeep [gi*( 64*(IPV4_RX_TYPE_NUM_MAX+1)) +:  64*(P_IPV4_RX_N+1)]= ipv4flat_rx_keep [1* 64 +: (P_IPV4_RX_N+1)* 64];
  assign  ipv4_axis_mlast [gi*(IPV4_RX_TYPE_NUM_MAX+1) +: (P_IPV4_RX_N+1)]= ipv4flat_rx_last [1 +: (P_IPV4_RX_N+1)];
  assign  ipv4_axis_mvalid[gi*(IPV4_RX_TYPE_NUM_MAX+1) +: (P_IPV4_RX_N+1)]= ipv4flat_rx_valid[1 +: (P_IPV4_RX_N+1)];
  assign  ipv4_axis_musr  [gi*(97*(IPV4_RX_TYPE_NUM_MAX+1)) +: 97*(P_IPV4_RX_N+1)]= ipv4flat_rx_usr  [1* 97 +: 97*(P_IPV4_RX_N+1)];
  assign  ipv4flat_rx_ready[1 +: (P_IPV4_RX_N+1)]= ipv4_axis_mready[gi*(IPV4_RX_TYPE_NUM_MAX+1) +: (P_IPV4_RX_N+1)];
  genvar pk4;
  for (pk4 = P_IPV4_RX_N+1; pk4 <= IPV4_RX_TYPE_NUM_MAX; pk4 = pk4 + 1) begin : g_pad_ipv4_rx
  assign  ipv4_axis_mdata [(gi*(IPV4_RX_TYPE_NUM_MAX+1)+pk4)*512 +: 512]= 512'd0           ;
  assign  ipv4_axis_mkeep [(gi*(IPV4_RX_TYPE_NUM_MAX+1)+pk4)* 64 +:  64]= 64'd0            ;
  assign  ipv4_axis_mlast [ gi*(IPV4_RX_TYPE_NUM_MAX+1)+pk4]= 1'b0             ;
  assign  ipv4_axis_mvalid[gi*(IPV4_RX_TYPE_NUM_MAX+1)+pk4]= 1'b0             ;
  assign  ipv4_axis_musr [(gi*(IPV4_RX_TYPE_NUM_MAX+1)+pk4)*97 +: 97]= 97'd0            ;
  end

  genvar pku;
  for (pku = P_UDP_RX_N+1; pku <= UDP_RX_PORT_NUM_MAX; pku = pku + 1) begin : g_pad_udp_rx
  assign  udp_axis_mdata [(gi*(UDP_RX_PORT_NUM_MAX+1)+pku)*512 +: 512]= 512'd0           ;
  assign  udp_axis_mkeep [(gi*(UDP_RX_PORT_NUM_MAX+1)+pku)* 64 +:  64]= 64'd0            ;
  assign  udp_axis_mlast [ gi*(UDP_RX_PORT_NUM_MAX+1)+pku]= 1'b0             ;
  assign  udp_axis_mvalid[gi*(UDP_RX_PORT_NUM_MAX+1)+pku]= 1'b0             ;
  assign  udp_axis_musr  [(gi*(UDP_RX_PORT_NUM_MAX+1)+pku)*193 +: 193]= 193'd0           ;
  end

  udp_top #(
    .RX_PORT_NUM      (P_UDP_RX_N       ),
    .DST_PORT_RANGE   (p_udp_range[P_UDP_RX_NEFF*32-1:0]),
    .TX_PORT_NUM      (P_UDP_TX_N       ),
    .AXIS_TX_USER_WIDTH(PRIORITY_WIDTH   ) 
  ) u_udp_top (
    .clk              (clk              ),
    .rst              (usr_rst          ),
    // RX : ipv4_top 剥以太头后的纯 IP 包
    .ipv4_udp_axis_sdata(ip_udp_rx_data   ),
    .ipv4_udp_axis_skeep(ip_udp_rx_keep   ),
    .ipv4_udp_axis_slast(ip_udp_rx_last   ),
    .ipv4_udp_axis_svalid(ip_udp_rx_valid  ),
    .ipv4_udp_axis_susr(ip_udp_rx_usr    ),
    .ipv4_udp_axis_sready(ip_udp_rx_ready  ),
    // RX 输出
    .udp_axis_mdata   (udp_axis_mdata[gi*(512*(UDP_RX_PORT_NUM_MAX+1)) +: 512*(P_UDP_RX_N+1)]),
    .udp_axis_mkeep   (udp_axis_mkeep[gi*( 64*(UDP_RX_PORT_NUM_MAX+1)) +:  64*(P_UDP_RX_N+1)]),
    .udp_axis_mlast   (udp_axis_mlast[gi*(UDP_RX_PORT_NUM_MAX+1) +: (P_UDP_RX_N+1)]),
    .udp_axis_mvalid  (udp_axis_mvalid[gi*(UDP_RX_PORT_NUM_MAX+1) +: (P_UDP_RX_N+1)]),
    .udp_axis_musr    (udp_axis_musr[gi*(193*(UDP_RX_PORT_NUM_MAX+1)) +: 193*(P_UDP_RX_N+1)]),
    .udp_axis_mready  (udp_axis_mready[gi*(UDP_RX_PORT_NUM_MAX+1) +: (P_UDP_RX_N+1)]),
    // TX : 待发送 UDP 报文
    .udp_axis_sdata   (udp_tx_s_data    ),
    .udp_axis_skeep   (udp_tx_s_keep    ),
    .udp_axis_slast   (udp_tx_s_last    ),
    .udp_axis_svalid  (udp_tx_s_valid   ),
    .udp_axis_susr    (udp_tx_s_usr     ),
    .udp_axis_sready  (udp_tx_s_ready   ),
    .cfg_total_len    (cfg_total_len[gi*16 +: 16]),
    .cfg_ttl          (cfg_ttl[gi* 8 +:  8]),
    .cfg_head_checksum(cfg_head_checksum[gi*16 +: 16]),
    .cfg_src_ip       (cfg_src_ip[gi*32 +: 32]),
    .cfg_dest_ip      (cfg_dest_ip[gi*32 +: 32]),
    // TX 输出 : 加完 IPv4 头的纯 IP 包
    .ipv4_axis_mdata  (ip_udp_tx_data   ),
    .ipv4_axis_mkeep  (ip_udp_tx_keep   ),
    .ipv4_axis_mlast  (ip_udp_tx_last   ),
    .ipv4_axis_mvalid (ip_udp_tx_valid  ),
    .ipv4_axis_musr   (ip_udp_tx_usr    ),
    .ipv4_axis_mready (ip_udp_tx_ready  ),
    .stat_is_df       (stat_is_df[gi]   ),
    .stat_tx_active_port(                 ),// 调试口, 预留
    .stat_tx_idle     (                 ) // 调试口, 预留
  );

  // udp_top TX 入口装配
  assign  udp_tx_s_data    = udp_axis_sdata[gi*(512*UDP_TX_N_MAX) +: 512*P_UDP_TX_N];
  assign  udp_tx_s_keep    = udp_axis_skeep[gi*( 64*UDP_TX_N_MAX) +:  64*P_UDP_TX_N];
  assign  udp_tx_s_last    = udp_axis_slast [gi*UDP_TX_N_MAX +: P_UDP_TX_N];
  assign  udp_tx_s_valid   = (P_UDP_TX_N > 0) ? udp_axis_svalid[gi*UDP_TX_N_MAX +: P_UDP_TX_N] : {P_UDP_TX_N{1'b0}};
  assign  udp_tx_s_usr     = (P_UDP_TX_N > 0) ? udp_axis_susr  [gi*(PRIORITY_WIDTH*UDP_TX_N_MAX) +: PRIORITY_WIDTH*P_UDP_TX_N] : {PRIORITY_WIDTH*P_UDP_TX_N{1'b0}};
  assign  udp_axis_sready[gi*UDP_TX_N_MAX +: P_UDP_TX_N]= udp_tx_s_ready   ;

  ipv6_top #(
    .RX_TYPE_NUM      (P_IPV6_RX_N      ),
    .RX_TYPE_DICT     (p_ipv6_rx_dict[P_IPV6_RX_NEFF*8-1:0]),
    .DEST_MAC_ENTRY_NUM(P_LOC_DST6_N     ),
    .SRC_MAC_ENTRY_NUM(P_LOC_SRC6_N     ),
    .TX_TYPE_NUM      (P_IPV6_TX_TOT    ),
    .AXIS_TX_USER_WIDTH(PRIORITY_WIDTH   ) 
  ) u_ipv6_top (
    .clk              (clk              ),
    .rst              (usr_rst          ),
    // RX : eth_top 分出的 IPv6 以太帧
    .eth_ipv6_axis_sdata(mac_ipv6_rx_data ),
    .eth_ipv6_axis_skeep(mac_ipv6_rx_keep ),
    .eth_ipv6_axis_slast(mac_ipv6_rx_last ),
    .eth_ipv6_axis_svalid(mac_ipv6_rx_valid),
    .eth_ipv6_axis_susr(mac_ipv6_rx_usr  ),
    .eth_ipv6_axis_sready(mac_ipv6_rx_ready),
    // RX flat 输出（全档对外）
    .ipv6_axis_mdata  (ipv6flat_rx_data ),
    .ipv6_axis_mkeep  (ipv6flat_rx_keep ),
    .ipv6_axis_mlast  (ipv6flat_rx_last ),
    .ipv6_axis_mvalid (ipv6flat_rx_valid),
    .ipv6_axis_musr   (ipv6flat_rx_usr  ),
    .ipv6_axis_mready (ipv6flat_rx_ready),
    // TX flat 输入
    .ipv6_axis_sdata  (ipv6_tx_s_data   ),
    .ipv6_axis_skeep  (ipv6_tx_s_keep   ),
    .ipv6_axis_slast  (ipv6_tx_s_last   ),
    .ipv6_axis_svalid (ipv6_tx_s_valid  ),
    .ipv6_axis_susr   (ipv6_tx_s_usr    ),
    .ipv6_axis_sready (ipv6_tx_s_ready  ),
    // TX 输出 : 完整以太帧（已插 14B 以太头
    .eth_tx_axis_mdata(ipv6_tx_m_data   ),
    .eth_tx_axis_mkeep(ipv6_tx_m_keep   ),
    .eth_tx_axis_mlast(ipv6_tx_m_last   ),
    .eth_tx_axis_mvalid(ipv6_tx_m_valid  ),
    .eth_tx_axis_musr (ipv6_tx_m_usr    ),
    .eth_tx_axis_mready(ipv6_tx_m_ready  ),
    // IP->MAC 映射表（上游统一配置: dest=对端表 / src=本机表）
    .cfg_dest_match_ipv6(cfg_dest_match_ipv6[gi*(128*P_LOC_DST6_N) +: 128*P_LOC_DST6_N]),
    .cfg_dest_match_mac(cfg_dest_match_mac [gi*( 48*P_LOC_DST6_N) +:  48*P_LOC_DST6_N]),
    .cfg_src_match_ipv6(cfg_src_match_ipv6 [gi*(128*P_LOC_SRC6_N ) +: 128*P_LOC_SRC6_N ]),
    .cfg_src_match_mac(cfg_src_match_mac  [gi*( 48*P_LOC_SRC6_N ) +:  48*P_LOC_SRC6_N ]),
    .stat_tx_drop_pulse(stat_ipv6_drop_pulse[gi]),
    .stat_tx_active_port(                 ),// 调试口, 预留
    .stat_tx_idle     (                 ) // 调试口, 预留
  );

  assign  ipv6_tx_s_data   = ipv6_axis_sdata[gi*(512*IPV6_TX_TOT_MAX) +: 512*P_IPV6_TX_TOT];
  assign  ipv6_tx_s_keep   = ipv6_axis_skeep[gi*( 64*IPV6_TX_TOT_MAX) +:  64*P_IPV6_TX_TOT];
  assign  ipv6_tx_s_last   = ipv6_axis_slast[gi*IPV6_TX_TOT_MAX +: P_IPV6_TX_TOT];
  assign  ipv6_tx_s_valid  = (P_IPV6_TX_N > 0) ? ipv6_axis_svalid[gi*IPV6_TX_TOT_MAX +: P_IPV6_TX_TOT] : {P_IPV6_TX_TOT{1'b0}};
  assign  ipv6_tx_s_usr    = (P_IPV6_TX_N > 0) ? ipv6_axis_susr[gi*(PRIORITY_WIDTH*IPV6_TX_TOT_MAX) +: PRIORITY_WIDTH*P_IPV6_TX_TOT] : {PRIORITY_WIDTH*P_IPV6_TX_TOT{1'b0}};
  assign  ipv6_axis_sready[gi*IPV6_TX_TOT_MAX +: P_IPV6_TX_TOT]= ipv6_tx_s_ready  ;

  assign  ipv6_axis_mdata [gi*(512*(IPV6_RX_TYPE_NUM_MAX+1)) +: 512*(P_IPV6_RX_N+1)]= ipv6flat_rx_data ;
  assign  ipv6_axis_mkeep [gi*( 64*(IPV6_RX_TYPE_NUM_MAX+1)) +:  64*(P_IPV6_RX_N+1)]= ipv6flat_rx_keep ;
  assign  ipv6_axis_mlast [gi*(IPV6_RX_TYPE_NUM_MAX+1) +: (P_IPV6_RX_N+1)]= ipv6flat_rx_last ;
  assign  ipv6_axis_mvalid[gi*(IPV6_RX_TYPE_NUM_MAX+1) +: (P_IPV6_RX_N+1)]= ipv6flat_rx_valid;
  assign  ipv6_axis_musr  [gi*(97*(IPV6_RX_TYPE_NUM_MAX+1)) +: 97*(P_IPV6_RX_N+1)]= ipv6flat_rx_usr  ;
  assign  ipv6flat_rx_ready= ipv6_axis_mready[gi*(IPV6_RX_TYPE_NUM_MAX+1) +: (P_IPV6_RX_N+1)];
  genvar pk6;
  for (pk6 = P_IPV6_RX_N+1; pk6 <= IPV6_RX_TYPE_NUM_MAX; pk6 = pk6 + 1) begin : g_pad_ipv6_rx
  assign  ipv6_axis_mdata [(gi*(IPV6_RX_TYPE_NUM_MAX+1)+pk6)*512 +: 512]= 512'd0           ;
  assign  ipv6_axis_mkeep [(gi*(IPV6_RX_TYPE_NUM_MAX+1)+pk6)* 64 +:  64]= 64'd0            ;
  assign  ipv6_axis_mlast [ gi*(IPV6_RX_TYPE_NUM_MAX+1)+pk6]= 1'b0             ;
  assign  ipv6_axis_mvalid[gi*(IPV6_RX_TYPE_NUM_MAX+1)+pk6]= 1'b0             ;
  assign  ipv6_axis_musr [(gi*(IPV6_RX_TYPE_NUM_MAX+1)+pk6)*97 +: 97]= 97'd0            ;
  end
end
endgenerate

endmodule
`resetall
