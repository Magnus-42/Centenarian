`resetall
`default_nettype none
`timescale 1ns/100ps
`include "cfg_map.vh"

// Language: Verilog 2001
// ============================================================================
// File Name   : cfg_reg_bank.v
// Module Name : cfg_reg_bank
// Author      : LiXintao
// Date        : 2026-10-22
// Version     : v1.1
// ----------------------------------------------------------------------------
// Description : 配置寄存器组
// ============================================================================
module cfg_reg_bank#(
  parameter  ETH_PORT_NUM= `CFG_NUM_PORT,
  parameter  MAX_VALUE_BYTES= `CFG_MAX_VALUE_BYTES,

  // 宽度主参数(MAX)，为所有端口的最大值
  parameter  CFG_NUM_WIDTH= `CFG_COUNT_WIDTH,
  parameter  [     CFG_NUM_WIDTH-1:0]        MAC_RX_TYPE_NUM_MAX= `CFG_MAX_MAC_RX_NUM,
  parameter  [     CFG_NUM_WIDTH-1:0]        MAC_TX_TYPE_NUM_MAX= `CFG_MAX_MAC_TX_NUM,
  parameter  [     CFG_NUM_WIDTH-1:0]        IPV4_RX_TYPE_NUM_MAX= `CFG_MAX_IPV4_RX_NUM,
  parameter  [     CFG_NUM_WIDTH-1:0]        IPV4_TX_TYPE_NUM_MAX= `CFG_MAX_IPV4_TX_NUM,
  parameter  [     CFG_NUM_WIDTH-1:0]        ICMP_TX_TYPE_NUM_MAX= `CFG_MAX_ICMP_TX_NUM,
  parameter  [     CFG_NUM_WIDTH-1:0]        IPV6_RX_TYPE_NUM_MAX= `CFG_MAX_IPV6_RX_NUM,
  parameter  [     CFG_NUM_WIDTH-1:0]        IPV6_TX_TYPE_NUM_MAX= `CFG_MAX_IPV6_TX_NUM,
  parameter  [     CFG_NUM_WIDTH-1:0]        UDP_RX_PORT_NUM_MAX= `CFG_MAX_UDP_RX_NUM,
  parameter  [     CFG_NUM_WIDTH-1:0]        UDP_TX_PORT_NUM_MAX= `CFG_MAX_UDP_TX_NUM,

  parameter  [     CFG_NUM_WIDTH-1:0]        LOCAL_IPV4_MAC_NUM_MAX= `CFG_MAX_V4_SET_NUM,
  parameter  [     CFG_NUM_WIDTH-1:0]        LOCAL_DST_IPV6_MAC_NUM_MAX= `CFG_MAX_V6_DST_SET_NUM,
  parameter  [     CFG_NUM_WIDTH-1:0]        LOCAL_SRC_IPV6_MAC_NUM_MAX= `CFG_MAX_V6_SRC_SET_NUM,

  parameter  [     CFG_NUM_WIDTH-1:0]        PENDING_TIME_WIDTH_MAX= `CFG_MAX_PENDING_TIME_WIDTH,
  parameter  [     CFG_NUM_WIDTH-1:0]        ARBITER_VAL_WIDTH_MAX= `CFG_MAX_ARBITER_VAL_WIDTH,

  // 实际的使用宽度
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]MAC_RX_TYPE_NUM_ARR= `CFG_DEF_MAC_RX_NUM_ARR,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]MAC_TX_TYPE_NUM_ARR= `CFG_DEF_MAC_TX_NUM_ARR,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV4_RX_TYPE_NUM_ARR= `CFG_DEF_IPV4_RX_NUM_ARR,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV4_TX_TYPE_NUM_ARR= `CFG_DEF_IPV4_TX_NUM_ARR,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]ICMP_TX_TYPE_NUM_ARR= `CFG_DEF_ICMP_TX_NUM_ARR,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV6_RX_TYPE_NUM_ARR= `CFG_DEF_IPV6_RX_NUM_ARR,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV6_TX_TYPE_NUM_ARR= `CFG_DEF_IPV6_TX_NUM_ARR,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]UDP_RX_PORT_NUM_ARR= `CFG_DEF_UDP_RX_NUM_ARR,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]UDP_TX_PORT_NUM_ARR= `CFG_DEF_UDP_TX_NUM_ARR,

  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_IPV4_MAC_NUM_ARR= `CFG_DEF_V4_SET_NUM_ARR,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_DST_IPV6_MAC_NUM_ARR= `CFG_DEF_V6_DST_NUM_ARR,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_SRC_IPV6_MAC_NUM_ARR= `CFG_DEF_V6_SRC_NUM_ARR,

  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]PENDING_TIME_WIDTH_ARR= `CFG_DEF_PT_WIDTH_ARR,
  parameter  [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]ARBITER_VAL_WIDTH_ARR= `CFG_DEF_ARB_VAL_WIDTH_ARR,

  // 设定值
  parameter  [(MAC_RX_TYPE_NUM_MAX*16)*ETH_PORT_NUM-1:0]DEF_MAC_RX_TYPE_DICT_ARR= `CFG_DEF_MAC_RX_DICT_ARR,   // 仅用户项，不能为 arp/ipv4/ipv6
  parameter  [(IPV4_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0]DEF_IPV4_RX_TYPE_DICT_ARR= `CFG_DEF_IPV4_RX_DICT_ARR, // 仅用户项，不能为 icmp(0x01)/udp(0x11)
  parameter  [(IPV6_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0]DEF_IPV6_RX_TYPE_DICT_ARR= `CFG_DEF_IPV6_RX_DICT_ARR,  // 仅用户项，不能为 udp(0x11)/icmpv6(0x3A)
  parameter  [(UDP_RX_PORT_NUM_MAX*32)*ETH_PORT_NUM-1:0]DEF_UDP_DST_PORT_RANGE_ARR= `CFG_DEF_UDP_PORT_RANGE_ARR, // 端口禁止重叠

  parameter  [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]DEF_V4_ARR= { `CFG_DEF_IPV4_IP_P1, `CFG_DEF_IPV4_IP_P0 } ,
  parameter  [48 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]DEF_MAC_ARR= { `CFG_DEF_IPV4_MAC_P1, `CFG_DEF_IPV4_MAC_P0 } ,
  parameter  [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]DEF_GW_ARR= { `CFG_DEF_IPV4_GW_P1, `CFG_DEF_IPV4_GW_P0 } ,
  parameter  [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]DEF_MK_ARR= { `CFG_DEF_IPV4_MASK_P1, `CFG_DEF_IPV4_MASK_P0 } ,
  parameter  [128*LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]DEF_SRC_V6_ARR= { `CFG_DEF_IPV6_SRC_P1, `CFG_DEF_IPV6_SRC_P0 } ,
  parameter  [48 *LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]DEF_SRC_MAC_ARR= { `CFG_DEF_IPV6_SRC_MAC_P1, `CFG_DEF_IPV6_SRC_MAC_P0 } ,
  parameter  [128*LOCAL_DST_IPV6_MAC_NUM_MAX *ETH_PORT_NUM-1:0]DEF_DST_V6_ARR= { `CFG_DEF_IPV6_DST_P1, `CFG_DEF_IPV6_DST_P0 } ,
  parameter  [48 *LOCAL_DST_IPV6_MAC_NUM_MAX *ETH_PORT_NUM-1:0]DEF_DST_MAC_ARR= { `CFG_DEF_IPV6_DST_MAC_P1, `CFG_DEF_IPV6_DST_MAC_P0 } ,

  parameter  [PENDING_TIME_WIDTH_MAX*ETH_PORT_NUM-1:0]DEF_PENDING_TIME= `CFG_DEF_PENDING,
  parameter  [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0]DEF_ARP_PRIORITY= `CFG_DEF_ARP_PRIO,  // 取低 4 位，默认 15
  parameter  [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0]DEF_ICMPV4_PRIORITY= `CFG_DEF_ICMP_PRIO,  // 取低 4 位，默认 12
  parameter  [               16*ETH_PORT_NUM-1:0]DEF_CMD_UDP_PORT  = `CFG_DEF_CMD_UDP_PORT, // 每口一份，默认 0xC0DE
  parameter  [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0]DEF_CMD_UDP_PRIO= `CFG_DEF_CMD_UDP_PRIO, // 取低 4 位，默认 9

  // ---- 内部推导（不对外暴露；均由 MAX 推导）----
  localparam MAC_TX_N_MAX= (MAC_TX_TYPE_NUM_MAX > 0) ? MAC_TX_TYPE_NUM_MAX : 1,
  localparam MAC_TX_TOT_MAX= MAC_TX_N_MAX + 3,
  localparam IPV4_TX_N_MAX= (IPV4_TX_TYPE_NUM_MAX > 0) ? IPV4_TX_TYPE_NUM_MAX : 1,
  localparam IPV4_TX_TOT_MAX= IPV4_TX_N_MAX + 1,
  localparam ICMP_TX_N_MAX= (ICMP_TX_TYPE_NUM_MAX > 0) ? ICMP_TX_TYPE_NUM_MAX : 1,
  localparam IPV6_TX_N_MAX= (IPV6_TX_TYPE_NUM_MAX > 0) ? IPV6_TX_TYPE_NUM_MAX : 1,
  localparam IPV6_TX_TOT_MAX= IPV6_TX_N_MAX,
  localparam UDP_TX_N_MAX= (UDP_TX_PORT_NUM_MAX > 0) ? UDP_TX_PORT_NUM_MAX : 1,
  localparam TX_IDX_WIDTH= (MAC_TX_TOT_MAX <= 1) ? 1 : $clog2(MAC_TX_TOT_MAX)
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // 写
  input  wire                                          wr_en           ,
  input  wire          [                   7:0]        wr_item         ,
  input  wire          [                   3:0]        wr_set          ,
  input  wire          [                   3:0]        wr_port         ,
  input  wire          [ MAX_VALUE_BYTES*8-1:0]        wr_val          ,

  // 读
  input  wire                                          rd_req          ,
  input  wire          [                   7:0]        rd_item         ,
  input  wire          [                   3:0]        rd_set          ,
  input  wire          [                   3:0]        rd_port         ,
  output reg           [                   7:0]        rd_len          ,
  output reg           [ MAX_VALUE_BYTES*8-1:0]        rd_val          ,
  output reg                                           rd_valid        ,

  // ---------------- 生效配置输出 ----------------
  output wire          [48 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_local_mac   ,
  output wire          [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_local_ip    ,
  output wire          [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_gateway_ip  ,
  output wire          [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_subnet_mask ,
  output wire          [128*LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_src_ipv6    ,
  output wire          [48 *LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_src_mac     ,
  output wire          [128*LOCAL_DST_IPV6_MAC_NUM_MAX *ETH_PORT_NUM-1:0]cfg_dst_ipv6    ,
  output wire          [48 *LOCAL_DST_IPV6_MAC_NUM_MAX *ETH_PORT_NUM-1:0]cfg_dst_mac     ,

  output wire          [16 *MAC_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]cfg_eth_type    ,
  output wire          [8  *IPV4_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]cfg_ipv4_proto  ,
  output wire          [8  *IPV6_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]cfg_ipv6_nh     ,
  output wire          [32 *UDP_RX_PORT_NUM_MAX*ETH_PORT_NUM-1:0]cfg_udp_port    ,

  output wire          [PENDING_TIME_WIDTH_MAX*ETH_PORT_NUM-1:0]cfg_pending_time,
  output wire          [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0]cfg_arp_prio    ,
  output wire          [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0]cfg_icmp_prio   ,
  output wire          [               16*ETH_PORT_NUM-1:0]cfg_cmd_udp_port,
  output wire          [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0]cfg_cmd_udp_prio,

  output wire          [      ETH_PORT_NUM-1:0]        cfg_arp_cache_clear,
  output wire          [      ETH_PORT_NUM-1:0]        cfg_arp_pending_clear,
  output wire          [      ETH_PORT_NUM-1:0]        cfg_stat_clear  ,

  // ---------------- 状态输入（只读） ----------------
  // 以太网帧长
  input  wire          [      ETH_PORT_NUM-1:0]        stat_link_status,
  input  wire          [      ETH_PORT_NUM-1:0]        stat_tx_idle    ,
  input  wire          [TX_IDX_WIDTH*ETH_PORT_NUM-1:0] stat_tx_active  ,
  input  wire          [      ETH_PORT_NUM-1:0]        stat_is_df      ,
  input  wire          [    7*ETH_PORT_NUM-1:0]        stat_arp        ,
  input  wire          [    4*ETH_PORT_NUM-1:0]        stat_icmp
);

  // 数组规模
  localparam V4_NUM  = ((LOCAL_IPV4_MAC_NUM_MAX     > 0) ? LOCAL_IPV4_MAC_NUM_MAX     : 1) * ETH_PORT_NUM;
  localparam V6S_NUM = ((LOCAL_SRC_IPV6_MAC_NUM_MAX > 0) ? LOCAL_SRC_IPV6_MAC_NUM_MAX : 1) * ETH_PORT_NUM;
  localparam V6D_NUM = ((LOCAL_DST_IPV6_MAC_NUM_MAX > 0) ? LOCAL_DST_IPV6_MAC_NUM_MAX : 1) * ETH_PORT_NUM;
  localparam ETH_NUM = ((MAC_RX_TYPE_NUM_MAX       > 0) ? MAC_RX_TYPE_NUM_MAX       : 1) * ETH_PORT_NUM;
  localparam V4P_NUM = ((IPV4_RX_TYPE_NUM_MAX      > 0) ? IPV4_RX_TYPE_NUM_MAX      : 1) * ETH_PORT_NUM;
  localparam V6NH_NUM= ((IPV6_RX_TYPE_NUM_MAX      > 0) ? IPV6_RX_TYPE_NUM_MAX      : 1) * ETH_PORT_NUM;
  localparam UDP_NUM = ((UDP_RX_PORT_NUM_MAX       > 0) ? UDP_RX_PORT_NUM_MAX       : 1) * ETH_PORT_NUM;

  // 配置存储
  reg [                   47:0] ipv4_local_mac  [0:V4_NUM-1]  ;
  reg [                   31:0] ipv4_local_ip   [0:V4_NUM-1]  ;
  reg [                   31:0] ipv4_gateway_ip [0:V4_NUM-1]  ;
  reg [                   31:0] ipv4_subnet_mask[0:V4_NUM-1]  ;
  reg [                  127:0] ipv6_src_ip     [0:V6S_NUM-1] ;
  reg [                   47:0] ipv6_src_mac    [0:V6S_NUM-1] ;
  reg [                  127:0] ipv6_dest_ip    [0:V6D_NUM-1] ;
  reg [                   47:0] ipv6_dest_mac   [0:V6D_NUM-1] ;
  reg [                   15:0] eth_type        [0:ETH_NUM-1] ;
  reg [                    7:0] ipv4_proto      [0:V4P_NUM-1] ;
  reg [                    7:0] ipv6_nh         [0:V6NH_NUM-1];
  reg [                   31:0] udp_port        [0:UDP_NUM-1] ;

  reg [PENDING_TIME_WIDTH_MAX-1:0] pending_time [0:ETH_PORT_NUM-1];
  reg [ARBITER_VAL_WIDTH_MAX -1:0] arp_prio     [0:ETH_PORT_NUM-1];
  reg [ARBITER_VAL_WIDTH_MAX -1:0] icmp_prio    [0:ETH_PORT_NUM-1];
  reg [                   15:0] cmd_udp_port [0:ETH_PORT_NUM-1];
  reg [ARBITER_VAL_WIDTH_MAX -1:0] cmd_udp_prio [0:ETH_PORT_NUM-1];

  reg                  [      ETH_PORT_NUM-1:0]        arp_cache_clear  ;
  reg                  [      ETH_PORT_NUM-1:0]        arp_pending_clear;
  reg                  [      ETH_PORT_NUM-1:0]        stat_clear       ;

  // 索引
  wire [7:0] wr_idx_v4   = wr_port * LOCAL_IPV4_MAC_NUM_MAX      + wr_set;
  wire [7:0] wr_idx_v6s  = wr_port * LOCAL_SRC_IPV6_MAC_NUM_MAX  + wr_set;
  wire [7:0] wr_idx_v6d  = wr_port * LOCAL_DST_IPV6_MAC_NUM_MAX  + wr_set;
  wire [7:0] wr_idx_eth  = wr_port * MAC_RX_TYPE_NUM_MAX         + wr_set;
  wire [7:0] wr_idx_v4p  = wr_port * IPV4_RX_TYPE_NUM_MAX        + wr_set;
  wire [7:0] wr_idx_v6nh = wr_port * IPV6_RX_TYPE_NUM_MAX        + wr_set;
  wire [7:0] wr_idx_udp  = wr_port * UDP_RX_PORT_NUM_MAX         + wr_set;

  wire [7:0] rd_idx_v4   = rd_port * LOCAL_IPV4_MAC_NUM_MAX      + rd_set;
  wire [7:0] rd_idx_v6s  = rd_port * LOCAL_SRC_IPV6_MAC_NUM_MAX  + rd_set;
  wire [7:0] rd_idx_v6d  = rd_port * LOCAL_DST_IPV6_MAC_NUM_MAX  + rd_set;
  wire [7:0] rd_idx_eth  = rd_port * MAC_RX_TYPE_NUM_MAX         + rd_set;
  wire [7:0] rd_idx_v4p  = rd_port * IPV4_RX_TYPE_NUM_MAX        + rd_set;
  wire [7:0] rd_idx_v6nh = rd_port * IPV6_RX_TYPE_NUM_MAX        + rd_set;
  wire [7:0] rd_idx_udp  = rd_port * UDP_RX_PORT_NUM_MAX         + rd_set;

  // rst 与 CFG_W_RESET_DEF 共用复位路径
  wire do_reset_def = wr_en && (wr_item == `CFG_W_RESET_DEF);

  // 写
  // IPv4 地址类
  always @(posedge clk) begin : p_wr_ipv4
    integer i;
    if (rst || do_reset_def) begin
      for (i = 0; i < V4_NUM; i = i + 1) begin
        ipv4_local_mac  [i] <= DEF_MAC_ARR[i*48 +: 48];
        ipv4_local_ip   [i] <= DEF_V4_ARR [i*32 +: 32];
        ipv4_gateway_ip [i] <= DEF_GW_ARR [i*32 +: 32];
        ipv4_subnet_mask[i] <= DEF_MK_ARR [i*32 +: 32];
      end
    end
    else if (wr_en) begin
      case (wr_item)
        `CFG_RW_IPV4_LOCAL_MAC: ipv4_local_mac  [wr_idx_v4] <= wr_val[47:0];
        `CFG_RW_IPV4_LOCAL_IP : ipv4_local_ip   [wr_idx_v4] <= wr_val[31:0];
        `CFG_RW_IPV4_GATEWAY  : ipv4_gateway_ip [wr_idx_v4] <= wr_val[31:0];
        `CFG_RW_IPV4_MASK     : ipv4_subnet_mask[wr_idx_v4] <= wr_val[31:0];
        default: ;
      endcase
    end
  end

  // IPv6 本机地址类
  always @(posedge clk) begin : p_wr_ipv6_src
    integer i;
    if (rst || do_reset_def) begin
      for (i = 0; i < V6S_NUM; i = i + 1) begin
        ipv6_src_ip [i] <= DEF_SRC_V6_ARR [i*128 +: 128];
        ipv6_src_mac[i] <= DEF_SRC_MAC_ARR[i*48  +: 48 ];
      end
    end
    else if (wr_en) begin
      case (wr_item)
        `CFG_RW_IPV6_SRC_LOCAL: ipv6_src_ip [wr_idx_v6s] <= wr_val[127:0];
        `CFG_RW_IPV6_SRC_MAC  : ipv6_src_mac[wr_idx_v6s] <= wr_val[47:0];
        default: ;
      endcase
    end
  end

  // IPv6 邻居地址类
  always @(posedge clk) begin : p_wr_ipv6_dst
    integer i;
    if (rst || do_reset_def) begin
      for (i = 0; i < V6D_NUM; i = i + 1) begin
        ipv6_dest_ip [i] <= DEF_DST_V6_ARR [i*128 +: 128];
        ipv6_dest_mac[i] <= DEF_DST_MAC_ARR[i*48  +: 48 ];
      end
    end
    else if (wr_en) begin
      case (wr_item)
        `CFG_RW_IPV6_DST_LOCAL: ipv6_dest_ip [wr_idx_v6d] <= wr_val[127:0];
        `CFG_RW_IPV6_DST_MAC  : ipv6_dest_mac[wr_idx_v6d] <= wr_val[47:0];
        default: ;
      endcase
    end
  end

  // 分流表
  always @(posedge clk) begin : p_wr_eth_type
    integer i;
    if (rst || do_reset_def) begin
      for (i = 0; i < ETH_NUM; i = i + 1)
        eth_type[i] <= DEF_MAC_RX_TYPE_DICT_ARR[i*16 +: 16];
    end
    else if (wr_en && (wr_item == `CFG_RW_ETH_TYPE_DICT)) begin
      eth_type[wr_idx_eth] <= wr_val[15:0];
    end
  end

  always @(posedge clk) begin : p_wr_ipv4_proto
    integer i;
    if (rst || do_reset_def) begin
      for (i = 0; i < V4P_NUM; i = i + 1)
        ipv4_proto[i] <= DEF_IPV4_RX_TYPE_DICT_ARR[i*8 +: 8];
    end
    else if (wr_en && (wr_item == `CFG_RW_IPV4_PROTO_DICT)) begin
      ipv4_proto[wr_idx_v4p] <= wr_val[7:0];
    end
  end

  always @(posedge clk) begin : p_wr_ipv6_nh
    integer i;
    if (rst || do_reset_def) begin
      for (i = 0; i < V6NH_NUM; i = i + 1)
        ipv6_nh[i] <= DEF_IPV6_RX_TYPE_DICT_ARR[i*8 +: 8];
    end
    else if (wr_en && (wr_item == `CFG_RW_IPV6_NH_DICT)) begin
      ipv6_nh[wr_idx_v6nh] <= wr_val[7:0];
    end
  end

  always @(posedge clk) begin : p_wr_udp_port
    integer i;
    if (rst || do_reset_def) begin
      for (i = 0; i < UDP_NUM; i = i + 1)
        udp_port[i] <= DEF_UDP_DST_PORT_RANGE_ARR[i*32 +: 32];
    end
    else if (wr_en && (wr_item == `CFG_RW_UDP_PORT_RANGE)) begin
      udp_port[wr_idx_udp] <= wr_val[31:0];
    end
  end

  // 行为参数
  always @(posedge clk) begin : p_wr_param
    integer i;
    if (rst || do_reset_def) begin
      for (i = 0; i < ETH_PORT_NUM; i = i + 1) begin
        pending_time[i] <= DEF_PENDING_TIME     [i*PENDING_TIME_WIDTH_MAX +: PENDING_TIME_WIDTH_MAX];
        arp_prio    [i] <= DEF_ARP_PRIORITY     [i*ARBITER_VAL_WIDTH_MAX  +: ARBITER_VAL_WIDTH_MAX ];
        icmp_prio   [i] <= DEF_ICMPV4_PRIORITY  [i*ARBITER_VAL_WIDTH_MAX  +: ARBITER_VAL_WIDTH_MAX ];
        cmd_udp_port[i] <= DEF_CMD_UDP_PORT     [i*16                    +: 16                    ];
        cmd_udp_prio[i] <= DEF_CMD_UDP_PRIO     [i*ARBITER_VAL_WIDTH_MAX  +: ARBITER_VAL_WIDTH_MAX ];
      end
    end
    else if (wr_en) begin
      case (wr_item)
        `CFG_RW_PENDING_TIME: pending_time[wr_port] <= wr_val[PENDING_TIME_WIDTH_MAX-1:0];
        `CFG_RW_ARP_PRIO    : arp_prio    [wr_port] <= wr_val[ARBITER_VAL_WIDTH_MAX -1:0];
        `CFG_RW_ICMP_PRIO   : icmp_prio   [wr_port] <= wr_val[ARBITER_VAL_WIDTH_MAX -1:0];
        `CFG_RW_CMD_UDP_PORT: cmd_udp_port[wr_port] <= wr_val[15:0];
        `CFG_RW_CMD_UDP_PRIO: cmd_udp_prio[wr_port] <= wr_val[ARBITER_VAL_WIDTH_MAX -1:0];
        default: ;
      endcase
    end
  end

  // 清空脉冲
  always @(posedge clk) begin : p_wr_clear
    if (rst) begin
      arp_cache_clear   <= 'd0;
      arp_pending_clear <= 'd0;
      stat_clear        <= 'd0;
    end
    else begin
      arp_cache_clear   <= 'd0;
      arp_pending_clear <= 'd0;
      stat_clear        <= 'd0;
      if (wr_en) begin
        case (wr_item)
          `CFG_W_CACHE_CLEAR: arp_cache_clear  [wr_port] <= 1'b1;
          `CFG_W_PEND_CLEAR : arp_pending_clear[wr_port] <= 1'b1;
          `CFG_W_STAT_CLEAR : stat_clear       [wr_port] <= 1'b1;
          default: ;
        endcase
      end
    end
  end

  assign cfg_arp_cache_clear   = arp_cache_clear  ;
  assign cfg_arp_pending_clear = arp_pending_clear;
  assign cfg_stat_clear        = stat_clear       ;

  // 输出
  genvar gi_v4, gi_v6s, gi_v6d, gi_eth, gi_v4p, gi_v6nh, gi_udp, gi_pt;
  generate
    for (gi_v4 = 0; gi_v4 < V4_NUM; gi_v4 = gi_v4 + 1) begin : g_pack_v4
      assign cfg_local_mac   [gi_v4*48 +: 48] = ipv4_local_mac  [gi_v4];
      assign cfg_local_ip    [gi_v4*32 +: 32] = ipv4_local_ip   [gi_v4];
      assign cfg_gateway_ip  [gi_v4*32 +: 32] = ipv4_gateway_ip [gi_v4];
      assign cfg_subnet_mask [gi_v4*32 +: 32] = ipv4_subnet_mask[gi_v4];
    end
    for (gi_v6s = 0; gi_v6s < V6S_NUM; gi_v6s = gi_v6s + 1) begin : g_pack_v6s
      assign cfg_src_ipv6[gi_v6s*128 +: 128] = ipv6_src_ip [gi_v6s];
      assign cfg_src_mac [gi_v6s*48  +: 48 ] = ipv6_src_mac[gi_v6s];
    end
    for (gi_v6d = 0; gi_v6d < V6D_NUM; gi_v6d = gi_v6d + 1) begin : g_pack_v6d
      assign cfg_dst_ipv6[gi_v6d*128 +: 128] = ipv6_dest_ip [gi_v6d];
      assign cfg_dst_mac [gi_v6d*48  +: 48 ] = ipv6_dest_mac[gi_v6d];
    end
    for (gi_eth = 0; gi_eth < ETH_NUM; gi_eth = gi_eth + 1) begin : g_pack_eth
      assign cfg_eth_type[gi_eth*16 +: 16] = eth_type[gi_eth];
    end
    for (gi_v4p = 0; gi_v4p < V4P_NUM; gi_v4p = gi_v4p + 1) begin : g_pack_v4p
      assign cfg_ipv4_proto[gi_v4p*8 +: 8] = ipv4_proto[gi_v4p];
    end
    for (gi_v6nh = 0; gi_v6nh < V6NH_NUM; gi_v6nh = gi_v6nh + 1) begin : g_pack_v6nh
      assign cfg_ipv6_nh[gi_v6nh*8 +: 8] = ipv6_nh[gi_v6nh];
    end
    for (gi_udp = 0; gi_udp < UDP_NUM; gi_udp = gi_udp + 1) begin : g_pack_udp
      assign cfg_udp_port[gi_udp*32 +: 32] = udp_port[gi_udp];
    end
    for (gi_pt = 0; gi_pt < ETH_PORT_NUM; gi_pt = gi_pt + 1) begin : g_pack_pt
      assign cfg_pending_time[gi_pt*PENDING_TIME_WIDTH_MAX +: PENDING_TIME_WIDTH_MAX] = pending_time[gi_pt];
      assign cfg_arp_prio    [gi_pt*ARBITER_VAL_WIDTH_MAX  +: ARBITER_VAL_WIDTH_MAX ] = arp_prio    [gi_pt];
      assign cfg_icmp_prio   [gi_pt*ARBITER_VAL_WIDTH_MAX  +: ARBITER_VAL_WIDTH_MAX ] = icmp_prio   [gi_pt];
      assign cfg_cmd_udp_port[gi_pt*16                    +: 16                    ] = cmd_udp_port[gi_pt];
      assign cfg_cmd_udp_prio[gi_pt*ARBITER_VAL_WIDTH_MAX  +: ARBITER_VAL_WIDTH_MAX ] = cmd_udp_prio[gi_pt];
    end
  endgenerate

  // 读回
  reg                  [                   7:0]        rd_len_c         ;
  reg                  [ MAX_VALUE_BYTES*8-1:0]        rd_val_c         ;

  always @(*) begin
    rd_len_c = 8'd0;
    rd_val_c = {MAX_VALUE_BYTES*8{1'b0}};
    case (rd_item)
      // ---- 地址类 ----
      `CFG_RW_IPV4_LOCAL_IP  : begin rd_len_c = 4; rd_val_c[32 -1:0] = ipv4_local_ip   [rd_idx_v4]; end
      `CFG_RW_IPV4_LOCAL_MAC : begin rd_len_c = 6; rd_val_c[48 -1:0] = ipv4_local_mac  [rd_idx_v4]; end
      `CFG_RW_IPV4_GATEWAY   : begin rd_len_c = 4; rd_val_c[32 -1:0] = ipv4_gateway_ip [rd_idx_v4]; end
      `CFG_RW_IPV4_MASK      : begin rd_len_c = 4; rd_val_c[32 -1:0] = ipv4_subnet_mask[rd_idx_v4]; end
      `CFG_RW_IPV6_SRC_LOCAL : begin rd_len_c = 16; rd_val_c[128 -1:0] = ipv6_src_ip  [rd_idx_v6s]; end
      `CFG_RW_IPV6_SRC_MAC   : begin rd_len_c = 6 ; rd_val_c[48  -1:0] = ipv6_src_mac [rd_idx_v6s]; end
      `CFG_RW_IPV6_DST_LOCAL : begin rd_len_c = 16; rd_val_c[128 -1:0] = ipv6_dest_ip [rd_idx_v6d]; end
      `CFG_RW_IPV6_DST_MAC   : begin rd_len_c = 6 ; rd_val_c[48  -1:0] = ipv6_dest_mac[rd_idx_v6d]; end
      // ---- 分流规则 ----
      `CFG_RW_ETH_TYPE_DICT  : begin rd_len_c = 2; rd_val_c[16-1:0] = eth_type  [rd_idx_eth ]; end
      `CFG_RW_IPV4_PROTO_DICT: begin rd_len_c = 1; rd_val_c[8 -1:0] = ipv4_proto[rd_idx_v4p ]; end
      `CFG_RW_IPV6_NH_DICT   : begin rd_len_c = 1; rd_val_c[8 -1:0] = ipv6_nh   [rd_idx_v6nh]; end
      `CFG_RW_UDP_PORT_RANGE : begin rd_len_c = 4; rd_val_c[32-1:0] = udp_port  [rd_idx_udp ]; end
      // ---- 行为参数 ----
      `CFG_RW_PENDING_TIME: begin rd_len_c = (PENDING_TIME_WIDTH_MAX+7)/8; rd_val_c[PENDING_TIME_WIDTH_MAX-1:0] = pending_time[rd_port]; end
      `CFG_RW_ARP_PRIO    : begin rd_len_c = (ARBITER_VAL_WIDTH_MAX+7)/8;  rd_val_c[ARBITER_VAL_WIDTH_MAX -1:0] = arp_prio    [rd_port]; end
      `CFG_RW_ICMP_PRIO   : begin rd_len_c = (ARBITER_VAL_WIDTH_MAX+7)/8;  rd_val_c[ARBITER_VAL_WIDTH_MAX -1:0] = icmp_prio   [rd_port]; end
      `CFG_RW_CMD_UDP_PORT: begin rd_len_c = 2; rd_val_c[15:0] = cmd_udp_port[rd_port]; end
      `CFG_RW_CMD_UDP_PRIO: begin rd_len_c = (ARBITER_VAL_WIDTH_MAX+7)/8; rd_val_c[ARBITER_VAL_WIDTH_MAX-1:0] = cmd_udp_prio[rd_port]; end
      // ---- 全局信息 ----
      `CFG_R_VERSION   : begin rd_len_c = 4; rd_val_c[31:0] = `CFG_VERSION_WORD; end
      // ---- 全局状态 ----
      `CFG_R_LINK_STATUS: begin rd_len_c = 1; rd_val_c[0] = stat_link_status[rd_port]; end
      `CFG_R_TX_IDLE    : begin rd_len_c = 1; rd_val_c[0] = stat_tx_idle[rd_port]; end
      `CFG_R_TX_ACTIVE  : begin rd_len_c = 1; rd_val_c[TX_IDX_WIDTH-1:0] = stat_tx_active[rd_port*TX_IDX_WIDTH +: TX_IDX_WIDTH]; end
      `CFG_R_IS_DF      : begin rd_len_c = 1; rd_val_c[0] = stat_is_df[rd_port]; end
      // ---- 逐口统计 ----
      `CFG_R_ARP_STAT   : begin rd_len_c = 4; rd_val_c[31:0] = {25'd0, stat_arp[rd_port*7 +: 7]}; end
      `CFG_R_ICMP_STAT  : begin rd_len_c = 1; rd_val_c[7:0]  = {4'd0,  stat_icmp[rd_port*4 +: 4]}; end
      // ---- 配置边界 ----
      `CFG_R_GEOMETRY  : begin
        rd_len_c = (9*CFG_NUM_WIDTH+7)/8;
        rd_val_c[9*CFG_NUM_WIDTH-1 : 0] = {UDP_RX_PORT_NUM_ARR [rd_port*CFG_NUM_WIDTH +: CFG_NUM_WIDTH],
                            IPV6_RX_TYPE_NUM_ARR[rd_port*CFG_NUM_WIDTH +: CFG_NUM_WIDTH],
                            IPV4_RX_TYPE_NUM_ARR[rd_port*CFG_NUM_WIDTH +: CFG_NUM_WIDTH],
                            MAC_RX_TYPE_NUM_ARR [rd_port*CFG_NUM_WIDTH +: CFG_NUM_WIDTH],

                            LOCAL_DST_IPV6_MAC_NUM_ARR[rd_port*CFG_NUM_WIDTH +: CFG_NUM_WIDTH],
                            LOCAL_SRC_IPV6_MAC_NUM_ARR[rd_port*CFG_NUM_WIDTH +: CFG_NUM_WIDTH],
                            LOCAL_IPV4_MAC_NUM_ARR[rd_port*CFG_NUM_WIDTH +: CFG_NUM_WIDTH],

                            PENDING_TIME_WIDTH_ARR[rd_port*CFG_NUM_WIDTH +: CFG_NUM_WIDTH],
                            ARBITER_VAL_WIDTH_ARR[rd_port*CFG_NUM_WIDTH +: CFG_NUM_WIDTH]};
      end
      `CFG_R_GEOMETRY_MAX: begin
        rd_len_c = (9*CFG_NUM_WIDTH+7)/8;
        rd_val_c[9*CFG_NUM_WIDTH-1 : 0] = {UDP_RX_PORT_NUM_MAX, IPV6_RX_TYPE_NUM_MAX, IPV4_RX_TYPE_NUM_MAX, MAC_RX_TYPE_NUM_MAX, LOCAL_DST_IPV6_MAC_NUM_MAX, LOCAL_SRC_IPV6_MAC_NUM_MAX, LOCAL_IPV4_MAC_NUM_MAX,PENDING_TIME_WIDTH_MAX,ARBITER_VAL_WIDTH_MAX};
      end
      `CFG_R_PORT_NUM  : begin rd_len_c = 1; rd_val_c[3:0] = ETH_PORT_NUM; end
      default          : begin rd_len_c = 8'd0; end
    endcase
  end

  always @(posedge clk) begin
    if (rst) begin
      rd_valid <= 1'b0;
      rd_len   <= 8'd0;
      rd_val   <= {MAX_VALUE_BYTES*8{1'b0}};
    end
    else begin
      rd_valid <= rd_req;
      if (rd_req) begin
        rd_len <= rd_len_c;
        rd_val <= rd_val_c;
      end
    end
  end

endmodule
`resetall
