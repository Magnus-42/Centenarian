`resetall
`default_nettype none
`timescale 1ns / 1ps
`include "../../Config/cfg_map.vh"

// Language: Verilog 2001
// ============================================================================
// File Name   : subsys_test_top.v
// Module Name : subsys_test_top
// Author      : LiXintao
// Date        : 2026-10-13
// Version     : v4.2（新增 IPv6 通道测试：ICMPv6 + OSPFv3 各口一台测试机）
// ----------------------------------------------------------------------------
// Description : net_stack_top 板级实验顶层
// NOTE        :
//   1. DUT = net_stack_top(ETH_PORT_NUM=2)；A/B 两片 CMAC 经外部光缆对接。
//   2. 本层负责"通道配置"：各层 RX/TX 的 TYPE_NUM/TYPE_DICT 在此定义并透传给 DUT。
//      RX_TYPE_NUM = 用户自定义档数(>=0); TX_TYPE_NUM = 用户自定义口数(>=0)。
//      内部档由代码直连: MAC 层 {arp,ipv4,ipv6} + other 兜底; IPv4 层 {udp} + other 兜底。
//      DICT 仅填用户项(禁含内部类型: MAC 禁 0806/0800/86DD; IPv4 禁 0x11)。
//        MAC : RX: [0]=0x88B5 [1]=other               TX: [0]=0x88B5
//        IPv4: RX: [0]=icmp [1]=ospf [2]=0x06 [3]=other
//              TX: [0]=icmp [1]=ospf [2]=0x06
//        IPv6: RX: [0]=icmpv6 [1]=ospf [2]=other
//              TX: [0]=icmpv6 [1]=ospf
//        UDP : RX: [0..2]=端口区间档 [3]=other        TX: 8 路用户口, 本期仅用第 [0] 路
//   3. 每口 7 个 subsys_100g_tester，覆盖对外通道：
//      MAC-other / IPv4-icmp / IPv4-ospf / IPv4-other / UDP / IPv6-icmpv6 / IPv6-ospfv3。。
// ============================================================================
module subsys_test_top(
  input  wire                                          sys_clk         ,

  // ---- 网口 A ----
  output wire          [                   3:0]        gt_txp_out_a    ,
  output wire          [                   3:0]        gt_txn_out_a    ,
  input  wire          [                   3:0]        gt_rxp_in_a     ,
  input  wire          [                   3:0]        gt_rxn_in_a     ,
  input  wire                                          gt_ref_clk_p_a  ,
  input  wire                                          gt_ref_clk_n_a  ,
  output wire                                          qsfp_rstn_port_a,
  output wire                                          qsfp_lp_mode_port_a,
  output wire                                          qsfp_seln_port_a,
  input  wire                                          qsfp_prsn_port_a,
  output wire                                          qsfp_led_port_a ,

  // ---- 网口 B ----
  output wire          [                   3:0]        gt_txp_out_b    ,
  output wire          [                   3:0]        gt_txn_out_b    ,
  input  wire          [                   3:0]        gt_rxp_in_b     ,
  input  wire          [                   3:0]        gt_rxn_in_b     ,
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
  localparam ETH_PORT_NUM       = `CFG_NUM_PORT;               // 网口数
  localparam CFG_NUM_WIDTH      = `CFG_COUNT_WIDTH;            // 档数/套数计数字段位宽
  localparam PENDING_TIME_WIDTH = `CFG_MAX_PENDING_TIME_WIDTH; // ARP pending 超时位宽
  localparam ARBITER_VAL_WIDTH  = `CFG_MAX_ARBITER_VAL_WIDTH;  // usr 仲裁值位宽

  localparam AXIS_WIDTH= 512;
  // usr 每通道/每路位宽（必须与 net_stack_top 内的同名常量保持一致）
  localparam MAC_RX_USR_WIDTH = 1;
  localparam IPV4_RX_USR_WIDTH= 48 + 48 + MAC_RX_USR_WIDTH;
  localparam IPV6_RX_USR_WIDTH= IPV4_RX_USR_WIDTH;
  localparam UDP_RX_USR_WIDTH = IPV4_RX_USR_WIDTH + 32+32+8+16+8 + 16+16+16;  // + UDP 首部字段(dst_port/src_port/udp_len)
  localparam UDP_TX_USR_WIDTH = 4 + 8 + 16 + 16 + 32 + 32;   // UDP TX 每包元数据: prio/ttl/sport/dport/src_ip/dst_ip
  localparam PKT_LEN_BEATS= 16;                             // 每包 16 拍 = 1024 字节
  localparam ONE_SEC_CYCLES= 32'd400_000_000;                // 1s @400MHz
  localparam CHK_PORT= 2 ;                             // UDP 校验第 2 路(区间[2,8])


  // ---- 本机配置（线序值：低字节 = 线上第一字节；口A = port0 / 口B = port1）----
  localparam [                  31:0]        CFG_A_IP    = `CFG_DEF_IPV4_IP_P0;  
  localparam [                  31:0]        CFG_B_IP    = `CFG_DEF_IPV4_IP_P1;  
  localparam [                  47:0]        CFG_A_MAC   = `CFG_DEF_IPV4_MAC_P0; 
  localparam [                  47:0]        CFG_B_MAC   = `CFG_DEF_IPV4_MAC_P1; 
  localparam [                  31:0]        CFG_GATEWAY = `CFG_DEF_IPV4_GW_P0;  
  localparam [                  31:0]        CFG_SUBNET  = `CFG_DEF_IPV4_MASK_P0;

  // ---- 各层档数/套数上限（MAX，来自 cfg_map）----
  localparam [     CFG_NUM_WIDTH-1:0]        MAC_RX_TYPE_NUM_MAX= `CFG_MAX_MAC_RX_NUM;
  localparam [     CFG_NUM_WIDTH-1:0]        MAC_TX_TYPE_NUM_MAX= `CFG_MAX_MAC_TX_NUM;
  localparam [     CFG_NUM_WIDTH-1:0]        IPV4_RX_TYPE_NUM_MAX= `CFG_MAX_IPV4_RX_NUM;
  localparam [     CFG_NUM_WIDTH-1:0]        IPV4_TX_TYPE_NUM_MAX= `CFG_MAX_IPV4_TX_NUM;
  localparam [     CFG_NUM_WIDTH-1:0]        ICMP_TX_TYPE_NUM_MAX= `CFG_MAX_ICMP_TX_NUM;
  localparam [     CFG_NUM_WIDTH-1:0]        IPV6_RX_TYPE_NUM_MAX= `CFG_MAX_IPV6_RX_NUM;
  localparam [     CFG_NUM_WIDTH-1:0]        IPV6_TX_TYPE_NUM_MAX= `CFG_MAX_IPV6_TX_NUM;
  localparam [     CFG_NUM_WIDTH-1:0]        UDP_RX_PORT_NUM_MAX= `CFG_MAX_UDP_RX_NUM;
  localparam [     CFG_NUM_WIDTH-1:0]        UDP_TX_PORT_NUM_MAX= `CFG_MAX_UDP_TX_NUM;
  localparam [     CFG_NUM_WIDTH-1:0]        LOCAL_IPV4_MAC_NUM_MAX= `CFG_MAX_V4_SET_NUM;
  localparam [     CFG_NUM_WIDTH-1:0]        LOCAL_DST_IPV6_MAC_NUM_MAX= `CFG_MAX_V6_DST_SET_NUM;
  localparam [     CFG_NUM_WIDTH-1:0]        LOCAL_SRC_IPV6_MAC_NUM_MAX= `CFG_MAX_V6_SRC_SET_NUM;
  localparam MAC_TX_N_MAX= (MAC_TX_TYPE_NUM_MAX > 0) ? MAC_TX_TYPE_NUM_MAX : 1;
  localparam IPV4_TX_N_MAX= (IPV4_TX_TYPE_NUM_MAX > 0) ? IPV4_TX_TYPE_NUM_MAX : 1;
  localparam IPV6_TX_TOT_MAX= (IPV6_TX_TYPE_NUM_MAX > 0) ? IPV6_TX_TYPE_NUM_MAX : 1;
  localparam UDP_TX_N_MAX= (UDP_TX_PORT_NUM_MAX > 0) ? UDP_TX_PORT_NUM_MAX : 1;
  localparam [ARBITER_VAL_WIDTH*ETH_PORT_NUM-1:0] CFG_ARP_PRIO_ARR = `CFG_DEF_ARP_PRIO;
  localparam [ARBITER_VAL_WIDTH*ETH_PORT_NUM-1:0] CFG_ICMP_PRIO_ARR= `CFG_DEF_ICMP_PRIO;
  localparam [ARBITER_VAL_WIDTH-1:0] ARP_PRIORITY    = CFG_ARP_PRIO_ARR [ARBITER_VAL_WIDTH-1:0];
  localparam [ARBITER_VAL_WIDTH-1:0] ICMPV4_PRIORITY = CFG_ICMP_PRIO_ARR[ARBITER_VAL_WIDTH-1:0];
  // ---- 逐口实际档数/套数（口1 在高位、口0 在低位；来自 cfg_map）----
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]MAC_RX_TYPE_NUM_ARR       = `CFG_DEF_MAC_RX_NUM_ARR;
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]MAC_TX_TYPE_NUM_ARR       = `CFG_DEF_MAC_TX_NUM_ARR;
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV4_RX_TYPE_NUM_ARR      = `CFG_DEF_IPV4_RX_NUM_ARR;
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV4_TX_TYPE_NUM_ARR      = `CFG_DEF_IPV4_TX_NUM_ARR;
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]ICMP_TX_TYPE_NUM_ARR      = `CFG_DEF_ICMP_TX_NUM_ARR;
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV6_RX_TYPE_NUM_ARR      = `CFG_DEF_IPV6_RX_NUM_ARR;
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV6_TX_TYPE_NUM_ARR      = `CFG_DEF_IPV6_TX_NUM_ARR;
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]UDP_RX_PORT_NUM_ARR       = `CFG_DEF_UDP_RX_NUM_ARR;
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]UDP_TX_PORT_NUM_ARR       = `CFG_DEF_UDP_TX_NUM_ARR;
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_IPV4_MAC_NUM_ARR    = `CFG_DEF_V4_SET_NUM_ARR;
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_DST_IPV6_MAC_NUM_ARR= `CFG_DEF_V6_DST_NUM_ARR;
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_SRC_IPV6_MAC_NUM_ARR= `CFG_DEF_V6_SRC_NUM_ARR;

  // ---- 分流表（仅用户项；内部 arp/ipv4/ipv6/udp/icmp 由 net_stack_top 内部拼接）----
  localparam [(MAC_RX_TYPE_NUM_MAX*16)*ETH_PORT_NUM-1:0]MAC_RX_TYPE_DICT_ARR  = `CFG_DEF_MAC_RX_DICT_ARR;
  localparam [(IPV4_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0]IPV4_RX_TYPE_DICT_ARR = `CFG_DEF_IPV4_RX_DICT_ARR;
  localparam [(IPV6_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0]IPV6_RX_TYPE_DICT_ARR = `CFG_DEF_IPV6_RX_DICT_ARR;
  localparam [(UDP_RX_PORT_NUM_MAX*32)*ETH_PORT_NUM-1:0]UDP_DST_PORT_RANGE_ARR= `CFG_DEF_UDP_PORT_RANGE_ARR;

  // ---- 行为参数 ----
  localparam [PENDING_TIME_WIDTH*ETH_PORT_NUM-1:0]CFG_PENDING_TIME_ARR= `CFG_DEF_PENDING;

  // ============================================================================
  // 每口 lane 索引表
  // ============================================================================
  localparam IDX_MAC_RX_A_88B5= 0*(MAC_RX_TYPE_NUM_MAX+1)+0;   // 口A ch0 = 0x88B5
  localparam IDX_MAC_RX_A_88CC= 0*(MAC_RX_TYPE_NUM_MAX+1)+1;   // 口A ch1 = 0x88CC (仅 A 有)
  localparam IDX_MAC_RX_A_FB  = 0*(MAC_RX_TYPE_NUM_MAX+1)+2;   // 口A 兜底 (=N_A=2)
  localparam IDX_MAC_RX_B_88B5= 1*(MAC_RX_TYPE_NUM_MAX+1)+0;   // 口B ch0 = 0x88B5
  localparam IDX_MAC_RX_B_FB  = 1*(MAC_RX_TYPE_NUM_MAX+1)+1;   // 口B 兜底 (=N_B=1)
  localparam IDX_MAC_TX_A_88B5= 0*MAC_TX_N_MAX+0;              // 口A lane0 -> 0x88B5
  localparam IDX_MAC_TX_A_FB  = 0*MAC_TX_N_MAX+1;              // 口A lane1 -> 0x88DD(兜底探测)
  localparam IDX_MAC_TX_B_88B5= 1*MAC_TX_N_MAX+0;              // 口B lane0 -> 0x88B5
  localparam IDX_MAC_TX_B_88CC= 1*MAC_TX_N_MAX+1;              // 口B lane1 -> 0x88CC
  localparam IDX_MAC_TX_B_FB  = 1*MAC_TX_N_MAX+2;              // 口B lane2 -> 0x88DD(兜底探测)
  localparam IDX_ICMP_RX_A    = 0;                            // 口A ICMPv4 独立口(只含非 echo 的 ICMP)
  localparam IDX_IP4_RX_A_OSPF= 0*(IPV4_RX_TYPE_NUM_MAX+1)+1;  // 口A ch1 = 0x59
  localparam IDX_IP4_RX_A_06  = 0*(IPV4_RX_TYPE_NUM_MAX+1)+2;  // 口A ch2 = 0x06
  localparam IDX_IP4_RX_A_FB  = 0*(IPV4_RX_TYPE_NUM_MAX+1)+3;  // 口A 兜底
  localparam IDX_IP4_RX_B_06  = 1*(IPV4_RX_TYPE_NUM_MAX+1)+0;  // 口B ch0 = 0x06
  localparam IDX_ICMP_RX_B    = 1;                            // 口B ICMPv4 独立口(只含非 echo 的 ICMP)
  localparam IDX_IP4_RX_B_OSPF= 1*(IPV4_RX_TYPE_NUM_MAX+1)+2;  // 口B ch2 = 0x59
  localparam IDX_IP4_RX_B_FB  = 1*(IPV4_RX_TYPE_NUM_MAX+1)+3;  // 口B 兜底
  localparam IDX_IP4_TX_A_ICMP= 0*IPV4_TX_N_MAX+0;             // 口A lane0
  localparam IDX_IP4_TX_A_OSPF= 0*IPV4_TX_N_MAX+1;             // 口A lane1
  localparam IDX_IP4_TX_A_06  = 0*IPV4_TX_N_MAX+2;             // 口A lane2
  localparam IDX_IP4_TX_A_FB  = 0*IPV4_TX_N_MAX+3;             // 口A lane3 -> 0x2F(兜底探测)
  localparam IDX_IP4_TX_B_ICMP= 1*IPV4_TX_N_MAX+0;             // 口B lane0
  localparam IDX_IP4_TX_B_OSPF= 1*IPV4_TX_N_MAX+1;             // 口B lane1
  localparam IDX_IP4_TX_B_06  = 1*IPV4_TX_N_MAX+2;             // 口B lane2
  localparam IDX_IP4_TX_B_FB  = 1*IPV4_TX_N_MAX+3;             // 口B lane3 -> 0x2F(兜底探测)
  localparam IDX_IP6_RX_A_UDP = 0*(IPV6_RX_TYPE_NUM_MAX+1)+0;  // 口A ch0 = 0x11(未接机, 排水)
  localparam IDX_IP6_RX_A_ICMP= 0*(IPV6_RX_TYPE_NUM_MAX+1)+1;  // 口A ch1 = 0x3A
  localparam IDX_IP6_RX_A_OSPF= 0*(IPV6_RX_TYPE_NUM_MAX+1)+2;  // 口A ch2 = 0x59
  localparam IDX_IP6_RX_A_FB  = 0*(IPV6_RX_TYPE_NUM_MAX+1)+3;  // 口A 兜底
  localparam IDX_IP6_RX_B_UDP = 1*(IPV6_RX_TYPE_NUM_MAX+1)+0;  // 口B ch0 = 0x11(未接机, 排水)
  localparam IDX_IP6_RX_B_OSPF= 1*(IPV6_RX_TYPE_NUM_MAX+1)+1;  // 口B ch1 = 0x59
  localparam IDX_IP6_RX_B_ICMP= 1*(IPV6_RX_TYPE_NUM_MAX+1)+2;  // 口B ch2 = 0x3A
  localparam IDX_IP6_RX_B_FB  = 1*(IPV6_RX_TYPE_NUM_MAX+1)+3;  // 口B 兜底
  localparam IDX_IP6_TX_A_FB  = 0*IPV6_TX_TOT_MAX+0;           // 口A lane0 -> NH=0x06(兜底探测)
  localparam IDX_IP6_TX_A_ICMP= 0*IPV6_TX_TOT_MAX+1;           // 口A lane1
  localparam IDX_IP6_TX_A_OSPF= 0*IPV6_TX_TOT_MAX+2;           // 口A lane2
  localparam IDX_IP6_TX_B_FB  = 1*IPV6_TX_TOT_MAX+0;           // 口B lane0 -> NH=0x06(兜底探测)
  localparam IDX_IP6_TX_B_ICMP= 1*IPV6_TX_TOT_MAX+1;           // 口B lane1
  localparam IDX_IP6_TX_B_OSPF= 1*IPV6_TX_TOT_MAX+2;           // 口B lane2
  localparam IDX_UDP_RX_A_P0  = 0*(UDP_RX_PORT_NUM_MAX+1)+0;   // 口A 区间[0,0] (未接机, 排水)
  localparam IDX_UDP_RX_A_P1  = 0*(UDP_RX_PORT_NUM_MAX+1)+1;   // 口A 区间[1,1] (未接机, 排水)
  localparam IDX_UDP_RX_A_P2  = 0*(UDP_RX_PORT_NUM_MAX+1)+2;   // 口A 区间[2,8] -> u_tb_udp 收
  localparam IDX_UDP_RX_A_FB  = 0*(UDP_RX_PORT_NUM_MAX+1)+3;   // 口A 兜底 -> u_tb_fb_udp 收
  localparam IDX_UDP_RX_B_P2  = 1*(UDP_RX_PORT_NUM_MAX+1)+0;   // 口B 区间[2,2] -> u_ta_udp 收
  localparam IDX_UDP_RX_B_P48 = 1*(UDP_RX_PORT_NUM_MAX+1)+1;   // 口B 区间[4,8] (未接机, 排水)
  localparam IDX_UDP_RX_B_FB  = 1*(UDP_RX_PORT_NUM_MAX+1)+2;   // 口B 兜底 -> u_ta_fb_udp 收
  localparam IDX_UDP_TX_A_DATA= 0*UDP_TX_N_MAX+0;              // 口A lane0 -> 业务流(端口2)
  localparam IDX_UDP_TX_A_FB  = 0*UDP_TX_N_MAX+1;              // 口A lane1 -> 兜底探测(端口0x1234)
  localparam IDX_UDP_TX_B_DATA= 1*UDP_TX_N_MAX+0;              // 口B lane0 -> 业务流(端口2)
  localparam IDX_UDP_TX_B_FB  = 1*UDP_TX_N_MAX+1;              // 口B lane1 -> 兜底探测(端口0x1234)


  // ---- IPv6 配置（线序值：低字节 = 线上第一字节）----
  // 2001:db8::1 / 2001:db8::2（占位地址，测试机接入时可改）
  localparam [128*LOCAL_SRC_IPV6_MAC_NUM_MAX-1:0] CFG_SRC_V6_P0 = `CFG_DEF_IPV6_SRC_P0;
  localparam [128*LOCAL_SRC_IPV6_MAC_NUM_MAX-1:0] CFG_SRC_V6_P1 = `CFG_DEF_IPV6_SRC_P1;
  localparam [                 127:0]        CFG_A_IPV6= CFG_SRC_V6_P0[127:0];   // 口A set0
  localparam [                 127:0]        CFG_B_IPV6= CFG_SRC_V6_P1[127:0];   // 口B set0

  // ---- UDP cfg ----
  localparam [                  15:0]        IP_LEN_FULL= PKT_LEN_BEATS*64;                     // 其余通道 IP 总长(tester 直接发完整 IP 包)
  localparam [                  15:0]        IP_LEN_FULL_LE= {IP_LEN_FULL[7:0], IP_LEN_FULL[15:8]};

  // ---- TX 优先级(user[3:0])常量 : 0=禁用 / 1~15 有效 ----
  //   ARP 优先级在 net_stack_top 内部固定 4'd15, 不在此处配置
  localparam [                   3:0]        PRIO_UDP_A= 4'd8;   // 口A UDP(v4)
  localparam [                   3:0]        PRIO_UDP_B= 4'd9;   // 口B UDP(v4)
  localparam [                   3:0]        PRIO_ICMP_A= 4'd12; // 口A ICMPv4
  localparam [                   3:0]        PRIO_ICMP_B= 4'd11; // 口B ICMPv4
  localparam [                   3:0]        PRIO_OSPF_A= 4'd13; // 口A OSPF(v4)
  localparam [                   3:0]        PRIO_OSPF_B= 4'd13; // 口B OSPF(v4)
  localparam [                   3:0]        PRIO_IP06_A= 4'd7;  // 口A 协议 0x06
  localparam [                   3:0]        PRIO_IP06_B= 4'd6;  // 口B 协议 0x06
  localparam [                   3:0]        PRIO_ICMPV6_A= 4'd14;// 口A ICMPv6(NDP)
  localparam [                   3:0]        PRIO_ICMPV6_B= 4'd14;// 口B ICMPv6(NDP)
  localparam [                   3:0]        PRIO_OSPFV3_A= 4'd13;// 口A OSPFv3
  localparam [                   3:0]        PRIO_OSPFV3_B= 4'd12;// 口B OSPFv3
  localparam [                   3:0]        PRIO_MAC88B5_A= 4'd6;// 口A 自定义类型 0x88B5
  localparam [                   3:0]        PRIO_MAC88B5_B= 4'd5;// 口B 自定义类型 0x88B5
  localparam [                   3:0]        PRIO_FB= 4'd2;       // 兜底探测流(最低, 不抢业务流)

  // UDP TX 每包元数据(108bit, {dst_ip,src_ip,dport,sport,ttl,prio})
  localparam [                 107:0]        UDP_USR_DATA_A= { CFG_B_IP, CFG_A_IP, CHK_PORT[15:0], 16'h0000, 8'h40, PRIO_UDP_A };
  localparam [                 107:0]        UDP_USR_FB_A  = { CFG_B_IP, CFG_A_IP, 16'h1234,       16'h0000, 8'h40, PRIO_FB    };
  localparam [                 107:0]        UDP_USR_DATA_B= { CFG_A_IP, CFG_B_IP, CHK_PORT[15:0], 16'h0000, 8'h40, PRIO_UDP_B };
  localparam [                 107:0]        UDP_USR_FB_B  = { CFG_A_IP, CFG_B_IP, 16'h1234,       16'h0000, 8'h40, PRIO_FB    };

  // ---- 各通道包头（低 160 位，低字节 = 线上第一字节）----
  // 以太帧头 14B: dst_mac(6) src_mac(6) type(2)
  localparam [                 159:0]        HDR_MAC_88B5_A= {16'hB588, CFG_A_MAC, CFG_B_MAC}; // 自定义类型 0x88B5
  localparam [                 159:0]        HDR_MAC_88B5_B= {16'hB588, CFG_B_MAC, CFG_A_MAC};
  localparam [                 159:0]        HDR_MAC_88CC_B= {16'hCC88, CFG_B_MAC, CFG_A_MAC}; // 自定义类型 0x88CC(仅 B 发, 只落 A 的用户档)
  localparam [                 159:0]        HDR_MAC_FB_A  = {16'hDD88, CFG_A_MAC, CFG_B_MAC}; // 0x88DD: 两口字典都没有 -> 落对端兜底档
  localparam [                 159:0]        HDR_MAC_FB_B  = {16'hDD88, CFG_B_MAC, CFG_A_MAC};
  // 纯 IPv4 头 20B（protocol: icmp=0x01 / ospf=0x59 / 0x06 / 0x2F=兜底探测）
  localparam [                 159:0]        HDR_IP_ICMP_A= {CFG_B_IP, CFG_A_IP, 16'h0000, 8'h01, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [                 159:0]        HDR_IP_ICMP_B= {CFG_A_IP, CFG_B_IP, 16'h0000, 8'h01, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [                 159:0]        HDR_IP_OSPF_A= {CFG_B_IP, CFG_A_IP, 16'h0000, 8'h59, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [                 159:0]        HDR_IP_OSPF_B= {CFG_A_IP, CFG_B_IP, 16'h0000, 8'h59, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [                 159:0]        HDR_IP_06_A  = {CFG_B_IP, CFG_A_IP, 16'h0000, 8'h06, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [                 159:0]        HDR_IP_06_B  = {CFG_A_IP, CFG_B_IP, 16'h0000, 8'h06, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [                 159:0]        HDR_IP_FB_A  = {CFG_B_IP, CFG_A_IP, 16'h0000, 8'h2F, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};
  localparam [                 159:0]        HDR_IP_FB_B  = {CFG_A_IP, CFG_B_IP, 16'h0000, 8'h2F, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45};

  // ---- IPv6 固定头 40B（低 320 位）----
  //   ver/TC/FL(4B) payload_len(2B) next_hdr(1B) hop_limit(1B) src(16B) dst(16B)
  //   next_hdr: 0x3A=icmpv6 / 0x59=ospfv3 / 0x06=兜底探测(未匹配)
  localparam [                  15:0]        IPV6_PL= PKT_LEN_BEATS*64 - 40;                      // IPv6 净载荷长度
  localparam [                  15:0]        IPV6_PL_LE= {IPV6_PL[7:0], IPV6_PL[15:8]};           // 值直通: 低字节先
  localparam [                 319:0]        HDR_IP6_ICMP_A= {CFG_B_IPV6, CFG_A_IPV6, 8'h40, 8'h3A, IPV6_PL_LE, 24'd0, 8'h60};
  localparam [                 319:0]        HDR_IP6_ICMP_B= {CFG_A_IPV6, CFG_B_IPV6, 8'h40, 8'h3A, IPV6_PL_LE, 24'd0, 8'h60};
  localparam [                 319:0]        HDR_IP6_OSPF_A= {CFG_B_IPV6, CFG_A_IPV6, 8'h40, 8'h59, IPV6_PL_LE, 24'd0, 8'h60};
  localparam [                 319:0]        HDR_IP6_OSPF_B= {CFG_A_IPV6, CFG_B_IPV6, 8'h40, 8'h59, IPV6_PL_LE, 24'd0, 8'h60};
  localparam [                 319:0]        HDR_IP6_FB_A  = {CFG_B_IPV6, CFG_A_IPV6, 8'h40, 8'h06, IPV6_PL_LE, 24'd0, 8'h60};
  localparam [                 319:0]        HDR_IP6_FB_B  = {CFG_A_IPV6, CFG_B_IPV6, 8'h40, 8'h06, IPV6_PL_LE, 24'd0, 8'h60};


  // ============================================================================
  // 时钟 / 复位（在本层做）
  // ============================================================================
  wire                                                 clk_400m         ;
  wire                                                 clk_locked       ;
  reg                                                  usr_rst          ;
  wire                                                 qsfp_gt_rst      ;

  clk_100_to_400m u_clk_100_to_400m (
    .clk_400m         (clk_400m         ),
    .locked           (clk_locked       ),
    .clk_100m         (sys_clk          ) 
  );

(* ASYNC_REG = "true" *)   reg                  [                   1:0]        rst_sync          = 2'b11                                                                                     ;
  always @(posedge clk_400m or posedge qsfp_gt_rst) begin
    if (qsfp_gt_rst) rst_sync <= 2'b11;
    else             rst_sync <= {rst_sync[0], 1'b0};
  end

  always @(posedge clk_400m) begin
    usr_rst <= rst_sync[1];
  end

  // ============================================================================
  // DUT : net_stack_top（2 口，全通道引出）
  // ============================================================================

  // ---- 打流机使能（VIO probe_out；共 23 位，见文件末尾 VIO 例化）----
  wire                                                 en_a_udp;             // VIO probe_out0 : A 口 UDP(端口2)
  wire                                                 en_a_icmp;            // VIO probe_out1 : A 口 IPv4-icmp
  wire                                                 en_a_ospf;            // VIO probe_out2 : A 口 IPv4-ospf
  wire                                                 en_a_ipv4_06;         // VIO probe_out3 : A 口 IPv4-协议0x06
  wire                                                 en_a_mac_88b5;        // VIO probe_out4 : A 口 MAC-自定义0x88B5
  wire                                                 en_b_udp;             // VIO probe_out5 : B 口 UDP(端口2)
  wire                                                 en_b_icmp;            // VIO probe_out6 : B 口 IPv4-icmp
  wire                                                 en_b_ospf;            // VIO probe_out7 : B 口 IPv4-ospf
  wire                                                 en_b_ipv4_06;         // VIO probe_out8 : B 口 IPv4-协议0x06
  wire                                                 en_b_mac_88b5;        // VIO probe_out9 : B 口 MAC-自定义0x88B5
  wire                                                 en_a_ip6icmp;         // VIO probe_out10 : A 口 IPv6-icmpv6
  wire                                                 en_a_ip6ospf;         // VIO probe_out11 : A 口 IPv6-ospfv3
  wire                                                 en_b_ip6icmp;         // VIO probe_out12 : B 口 IPv6-icmpv6
  wire                                                 en_b_ip6ospf;         // VIO probe_out13 : B 口 IPv6-ospfv3
  wire                                                 en_a_fb_mac;          // VIO probe_out14 : A 发 MAC兜底探测(0x88DD)->B兜底档
  wire                                                 en_a_fb_ipv4;         // VIO probe_out15 : A 发 IPv4兜底探测(0x2F)->B兜底档
  wire                                                 en_a_fb_ipv6;         // VIO probe_out16 : A 发 IPv6兜底探测(NH=06)->B兜底档
  wire                                                 en_a_fb_udp;          // VIO probe_out17 : A 发 UDP兜底探测(端口0x1234)->B兜底档
  wire                                                 en_b_mac_88cc;        // VIO probe_out18 : B 发 MAC-自定义0x88CC->A ch1
  wire                                                 en_b_fb_mac;          // VIO probe_out19 : B 发 MAC兜底探测->A兜底档
  wire                                                 en_b_fb_ipv4;         // VIO probe_out20 : B 发 IPv4兜底探测->A兜底档
  wire                                                 en_b_fb_ipv6;         // VIO probe_out21 : B 发 IPv6兜底探测->A兜底档
  wire                                                 en_b_fb_udp;          // VIO probe_out22 : B 发 UDP兜底探测->A兜底档

  wire                 [512*(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_mdata   ;// DUT 输出(全口全路)
  wire                 [64*(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_mkeep   ;
  wire                 [(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_mlast   ;
  wire                 [(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_mvalid  ;
  wire                 [UDP_RX_USR_WIDTH*(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_musr    ;
  wire                 [(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_mready  ;
  wire                 [512*(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mdata   ;
  wire                 [64*(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mkeep   ;
  wire                 [(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mlast   , mac_axis_mready;
  wire                 [(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mvalid  ;
  wire                 [512*MAC_TX_N_MAX*ETH_PORT_NUM-1:0]mac_axis_sdata   ;
  wire                 [64*MAC_TX_N_MAX*ETH_PORT_NUM-1:0]mac_axis_skeep   ;
  wire                 [MAC_TX_N_MAX*ETH_PORT_NUM-1:0] mac_axis_slast   , mac_axis_svalid, mac_axis_sready;
  wire                 [ARBITER_VAL_WIDTH*MAC_TX_N_MAX*ETH_PORT_NUM-1:0]mac_axis_susr    ;
  wire                 [512*(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_mdata  ;
  wire                 [64*(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_mkeep  ;
  wire                 [IPV4_RX_USR_WIDTH*(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_musr   ;
  wire                 [(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_mlast  , ipv4_axis_mvalid, ipv4_axis_mready;
  // ---- ICMPv4 flat 通道（每口 1 路；只含非 echo 的 ICMP，echo 由内部应答)----
  wire                 [512*ETH_PORT_NUM-1:0]          icmp_axis_mdata  ;
  wire                 [64*ETH_PORT_NUM-1:0]           icmp_axis_mkeep  ;
  wire                 [IPV4_RX_USR_WIDTH*ETH_PORT_NUM-1:0] icmp_axis_musr   ;
  wire                 [ETH_PORT_NUM-1:0]              icmp_axis_mlast  , icmp_axis_mvalid, icmp_axis_mready;
  wire                 [512*IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_sdata  ;
  wire                 [64*IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_skeep  ;
  wire                 [IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_slast  , ipv4_axis_svalid, ipv4_axis_sready;
  wire                 [ARBITER_VAL_WIDTH*IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_susr   ;
  wire                 [512*UDP_TX_N_MAX*ETH_PORT_NUM-1:0]udp_axis_sdata   ;
  wire                 [64*UDP_TX_N_MAX*ETH_PORT_NUM-1:0]udp_axis_skeep   ;
  wire                 [UDP_TX_N_MAX*ETH_PORT_NUM-1:0] udp_axis_slast   , udp_axis_svalid, udp_axis_sready;
  wire                 [UDP_TX_USR_WIDTH*UDP_TX_N_MAX*ETH_PORT_NUM-1:0]udp_axis_susr    ;
  // ---- IPv6 flat 通道 ----
  wire                 [512*(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_mdata  ;
  wire                 [64*(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_mkeep  ;
  wire                 [IPV6_RX_USR_WIDTH*(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_musr   ;
  wire                 [(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_mlast  , ipv6_axis_mvalid, ipv6_axis_mready;
  wire                 [512*IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_sdata  ;
  wire                 [64*IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_skeep  ;
  wire                 [IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_slast  , ipv6_axis_svalid, ipv6_axis_sready;
  wire                 [ARBITER_VAL_WIDTH*IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_susr   ;
  // ============================================================================
  // 配置子系统互联
  // ============================================================================
  localparam CMD_PORT_SEL   = `CFG_CMD_PORT_SEL;         // 命令通道绑定口（与 net_stack_top 同源）
  localparam CMD_USR_WIDTH  = 96;                        // cfg 内部请求四元组位宽
  localparam CMD_TTL        = 8'd64;                     // 应答固定 TTL
  localparam CMD_FIFO_DEPTH = 512;                       // 命令帧缓冲深度（拍）
  localparam MAC_TX_TOT_MAX = MAC_TX_N_MAX + 3;
  localparam TX_IDX_WIDTH   = (MAC_TX_TOT_MAX <= 1) ? 1 : $clog2(MAC_TX_TOT_MAX);

  // ---- UDP 命令档（每口一套，仅 CMD_PORT_SEL 口有效）----
  wire                 [512*ETH_PORT_NUM-1:0]              udp_cmd_axis_mdata  ;
  wire                 [64*ETH_PORT_NUM-1:0]               udp_cmd_axis_mkeep  ;
  wire                 [ETH_PORT_NUM-1:0]                  udp_cmd_axis_mlast  ;
  wire                 [ETH_PORT_NUM-1:0]                  udp_cmd_axis_mvalid ;
  wire                 [UDP_RX_USR_WIDTH*ETH_PORT_NUM-1:0] udp_cmd_axis_musr   ;
  wire                 [ETH_PORT_NUM-1:0]                  udp_cmd_axis_mready ;
  wire                 [512*ETH_PORT_NUM-1:0]              udp_cmd_axis_sdata  ;
  wire                 [64*ETH_PORT_NUM-1:0]               udp_cmd_axis_skeep  ;
  wire                 [ETH_PORT_NUM-1:0]                  udp_cmd_axis_slast  ;
  wire                 [ETH_PORT_NUM-1:0]                  udp_cmd_axis_svalid ;
  wire                 [UDP_TX_USR_WIDTH*ETH_PORT_NUM-1:0] udp_cmd_axis_susr   ;
  wire                 [ETH_PORT_NUM-1:0]                  udp_cmd_axis_sready ;

  // ---- cfg_cmd_top 输出：生效配置 ----
  wire                 [48 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]    cfg_local_mac        ;
  wire                 [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]    cfg_local_ip         ;
  wire                 [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]    cfg_gateway_ip       ;
  wire                 [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]    cfg_subnet_mask      ;
  wire                 [128*LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_src_ipv6         ;
  wire                 [48 *LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_src_mac          ;
  wire                 [128*LOCAL_DST_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_dst_ipv6         ;
  wire                 [48 *LOCAL_DST_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_dst_mac          ;
  wire                 [16 *MAC_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]       cfg_eth_type         ;
  wire                 [8  *IPV4_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]      cfg_ipv4_proto       ;
  wire                 [8  *IPV6_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]      cfg_ipv6_nh          ;
  wire                 [32 *UDP_RX_PORT_NUM_MAX*ETH_PORT_NUM-1:0]       cfg_udp_port         ;
  wire                 [16 *ETH_PORT_NUM-1:0]                           cfg_cmd_udp_port     ;
  wire                 [PENDING_TIME_WIDTH*ETH_PORT_NUM-1:0]            cfg_pending_time     ;
  wire                 [ARBITER_VAL_WIDTH*ETH_PORT_NUM-1:0]             cfg_arp_prio         ;
  wire                 [ARBITER_VAL_WIDTH*ETH_PORT_NUM-1:0]             cfg_icmp_prio        ;
  wire                 [ETH_PORT_NUM-1:0]                               cfg_arp_cache_clear  ;
  wire                 [ETH_PORT_NUM-1:0]                               cfg_arp_pending_clear;
  wire                 [ETH_PORT_NUM-1:0]                               cfg_stat_clear       ;

  // ---- cfg_cmd_top 状态输入（来自 net_stack_top，按口打包）----
  wire                 [ETH_PORT_NUM-1:0]                  stat_link_status        ;
  wire                 [ETH_PORT_NUM-1:0]                  stat_tx_idle            ;
  wire                 [TX_IDX_WIDTH*ETH_PORT_NUM-1:0]     stat_tx_active_port     ;
  wire                 [ETH_PORT_NUM-1:0]                  stat_is_df              ;
  wire                 [ETH_PORT_NUM-1:0]                  stat_arp_rx_error       ;
  wire                 [ETH_PORT_NUM-1:0]                  stat_arp_ack_ovf        ;
  wire                 [ETH_PORT_NUM-1:0]                  stat_arp_pend_ovf       ;
  wire                 [ETH_PORT_NUM-1:0]                  stat_arp_no_resp        ;
  wire                 [ETH_PORT_NUM-1:0]                  stat_arp_pend_clr       ;
  wire                 [ETH_PORT_NUM-1:0]                  stat_arp_cache_clr      ;
  wire                 [ETH_PORT_NUM-1:0]                  stat_arp_src_not_local  ;
  wire                 [ETH_PORT_NUM-1:0]                  stat_icmp_drop          ;
  wire                 [3*ETH_PORT_NUM-1:0]                stat_icmp_drop_reason   ;
  wire                 [7*ETH_PORT_NUM-1:0]                stat_arp                ;// {src_not_local,cache_clr,pend_clr,no_resp,pend_ovf,ack_ovf,rx_error}
  wire                 [4*ETH_PORT_NUM-1:0]                stat_icmp               ;// {drop_reason[2:0], drop}

  // 逐口打包成 cfg 侧格式（ITEM 0x60 / 0x61 直接读回）
  genvar gs;
  generate
    for (gs = 0; gs < ETH_PORT_NUM; gs = gs + 1) begin : g_stat_pack
  assign  stat_arp [gs*7 +: 7] = { stat_arp_src_not_local[gs],
                                   stat_arp_cache_clr    [gs],
                                   stat_arp_pend_clr     [gs],
                                   stat_arp_no_resp      [gs],
                                   stat_arp_pend_ovf     [gs],
                                   stat_arp_ack_ovf      [gs],
                                   stat_arp_rx_error     [gs] };
  assign  stat_icmp[gs*4 +: 4] = { stat_icmp_drop_reason[gs*3 +: 3],
                                   stat_icmp_drop       [gs] };
    end
  endgenerate

  // ---- 命令帧 FIFO 与应答流 ----
  wire                 [                   512-1:0]        cmd_fifo_mdata          ;
  wire                 [                    64-1:0]        cmd_fifo_mkeep          ;
  wire                 [                        1-1:0]      cmd_fifo_mlast          ;
  wire                                                     cmd_fifo_mvalid         ;
  wire                                                     cmd_fifo_sready         ;
  wire                                                     cmd_in_ready            ;
  wire                 [      UDP_RX_USR_WIDTH-1:0]        cmd_fifo_musr           ;

  wire                 [                   512-1:0]        cmd_rsp_data            ;
  wire                 [                    64-1:0]        cmd_rsp_keep            ;
  wire                                                     cmd_rsp_last            ;
  wire                                                     cmd_rsp_valid           ;
  wire                                                     cmd_rsp_ready           ;
  wire                 [     UDP_TX_USR_WIDTH-1:0]         cmd_rsp_usr             ;

  // 逐口拼装：只有 CMD_PORT_SEL 口接真实数据，其余口恒 0 / 悬空不消费
  //   约束：CMD_PORT_SEL 必须 < ETH_PORT_NUM（否则 cmd_rsp_ready 无驱动，且命令通道全程不工作）
  genvar gc;
  generate
    for (gc = 0; gc < ETH_PORT_NUM; gc = gc + 1) begin : g_cmd_port
      if (gc == CMD_PORT_SEL) begin : g_sel
  assign  udp_cmd_axis_mready [gc]        = cmd_fifo_sready                    ;
  assign  udp_cmd_axis_sdata  [gc*512 +: 512] = cmd_rsp_data                   ;
  assign  udp_cmd_axis_skeep  [gc*64  +:  64] = cmd_rsp_keep                   ;
  assign  udp_cmd_axis_slast  [gc]        = cmd_rsp_last                       ;
  assign  udp_cmd_axis_svalid [gc]        = cmd_rsp_valid                      ;
  assign  udp_cmd_axis_susr   [gc*UDP_TX_USR_WIDTH +: UDP_TX_USR_WIDTH] = cmd_rsp_usr ;
  assign  cmd_rsp_ready                   = udp_cmd_axis_sready[gc]            ;
      end
      else begin : g_nosel
  assign  udp_cmd_axis_mready [gc]        = 1'b0                               ;
  assign  udp_cmd_axis_sdata  [gc*512 +: 512] = 512'd0                         ;
  assign  udp_cmd_axis_skeep  [gc*64  +:  64] = 64'd0                          ;
  assign  udp_cmd_axis_slast  [gc]        = 1'b0                               ;
  assign  udp_cmd_axis_svalid [gc]        = 1'b0                               ;
  assign  udp_cmd_axis_susr   [gc*UDP_TX_USR_WIDTH +: UDP_TX_USR_WIDTH] = {UDP_TX_USR_WIDTH{1'b0}} ;
      end
    end
  endgenerate

  // ============================================================================
  // DUT : net_stack_top（2 口，全通道引出）
  // ============================================================================

  net_stack_top #(
    .ETH_PORT_NUM     (ETH_PORT_NUM     ),
    .CMD_PORT_SEL     (`CFG_CMD_PORT_SEL),// 命令通道绑定口，与 cfg_map 一致
    .CFG_NUM_WIDTH    (CFG_NUM_WIDTH    ),
    .MAC_RX_TYPE_NUM_ARR(MAC_RX_TYPE_NUM_ARR),
    .MAC_TX_TYPE_NUM_ARR(MAC_TX_TYPE_NUM_ARR),
    .IPV4_RX_TYPE_NUM_ARR(IPV4_RX_TYPE_NUM_ARR),
    .IPV4_TX_TYPE_NUM_ARR(IPV4_TX_TYPE_NUM_ARR),
    .ICMP_TX_TYPE_NUM_ARR(ICMP_TX_TYPE_NUM_ARR),
    .IPV6_RX_TYPE_NUM_ARR(IPV6_RX_TYPE_NUM_ARR),
    .IPV6_TX_TYPE_NUM_ARR(IPV6_TX_TYPE_NUM_ARR),
    .UDP_RX_PORT_NUM_ARR(UDP_RX_PORT_NUM_ARR),
    .UDP_TX_PORT_NUM_ARR(UDP_TX_PORT_NUM_ARR),
    .LOCAL_IPV4_MAC_NUM_ARR(LOCAL_IPV4_MAC_NUM_ARR),
    .LOCAL_DST_IPV6_MAC_NUM_ARR(LOCAL_DST_IPV6_MAC_NUM_ARR),
    .LOCAL_SRC_IPV6_MAC_NUM_ARR(LOCAL_SRC_IPV6_MAC_NUM_ARR),
    .MAC_RX_TYPE_NUM_MAX(MAC_RX_TYPE_NUM_MAX),
    .MAC_TX_TYPE_NUM_MAX(MAC_TX_TYPE_NUM_MAX),
    .IPV4_RX_TYPE_NUM_MAX(IPV4_RX_TYPE_NUM_MAX),
    .IPV4_TX_TYPE_NUM_MAX(IPV4_TX_TYPE_NUM_MAX),
    .ICMP_TX_TYPE_NUM_MAX(ICMP_TX_TYPE_NUM_MAX),
    .IPV6_RX_TYPE_NUM_MAX(IPV6_RX_TYPE_NUM_MAX),
    .IPV6_TX_TYPE_NUM_MAX(IPV6_TX_TYPE_NUM_MAX),
    .UDP_RX_PORT_NUM_MAX(UDP_RX_PORT_NUM_MAX),
    .UDP_TX_PORT_NUM_MAX(UDP_TX_PORT_NUM_MAX),
    .LOCAL_IPV4_MAC_NUM_MAX(LOCAL_IPV4_MAC_NUM_MAX),
    .LOCAL_DST_IPV6_MAC_NUM_MAX(LOCAL_DST_IPV6_MAC_NUM_MAX),
    .LOCAL_SRC_IPV6_MAC_NUM_MAX(LOCAL_SRC_IPV6_MAC_NUM_MAX),
    .ARBITER_VAL_WIDTH   (ARBITER_VAL_WIDTH   ),
    .PENDING_TIME_WIDTH  (PENDING_TIME_WIDTH  )
  ) u_dut (
    .sys_clk          (sys_clk          ),
    .clk              (clk_400m         ),
    .clk_locked       (clk_locked       ),
    .qsfp_gt_rst      (qsfp_gt_rst      ),
    .usr_rst          (usr_rst          ),
    // ---- 运行期配置：批次 B 接入 cfg_cmd_top 之前，先用 cfg_map 默认值驱动（行为与改前一致）----
    .cfg_eth_type           (cfg_eth_type         ),
    .cfg_ipv4_proto         (cfg_ipv4_proto       ),
    .cfg_ipv6_nh            (cfg_ipv6_nh          ),
    .cfg_udp_port           (cfg_udp_port         ),
    .cfg_pending_time       (cfg_pending_time     ),
    .cfg_arp_prio           (cfg_arp_prio         ),
    .cfg_icmp_prio          (cfg_icmp_prio        ),
    .cfg_arp_cache_clear    (cfg_arp_cache_clear  ),
    .cfg_arp_pending_clear  (cfg_arp_pending_clear),
    .cfg_stat_clear         (cfg_stat_clear       ),
    // ---- UDP 命令档（接 cfg_cmd_top：命令帧收 / 应答发）----
    .cfg_cmd_udp_port       (cfg_cmd_udp_port     ),
    .udp_cmd_axis_mdata     (udp_cmd_axis_mdata   ),
    .udp_cmd_axis_mkeep     (udp_cmd_axis_mkeep   ),
    .udp_cmd_axis_mlast     (udp_cmd_axis_mlast   ),
    .udp_cmd_axis_mvalid    (udp_cmd_axis_mvalid  ),
    .udp_cmd_axis_musr      (udp_cmd_axis_musr    ),
    .udp_cmd_axis_mready    (udp_cmd_axis_mready  ),
    .udp_cmd_axis_sdata     (udp_cmd_axis_sdata   ),
    .udp_cmd_axis_skeep     (udp_cmd_axis_skeep   ),
    .udp_cmd_axis_slast     (udp_cmd_axis_slast   ),
    .udp_cmd_axis_svalid    (udp_cmd_axis_svalid  ),
    .udp_cmd_axis_susr      (udp_cmd_axis_susr    ),
    .udp_cmd_axis_sready    (udp_cmd_axis_sready  ),
    .stat_link_status       (stat_link_status     ),
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
    .cfg_local_mac    (cfg_local_mac    ),
    .cfg_local_ip     (cfg_local_ip     ),
    .cfg_gateway_ip   (cfg_gateway_ip   ),
    .cfg_subnet_mask  (cfg_subnet_mask  ),
    // MAC flat 通道（RX 对外段: idx0=0x88B5, idx1=兜底; TX 对外段: idx0=0x88B5）
    .mac_axis_mdata   (mac_axis_mdata   ),
    .mac_axis_mkeep   (mac_axis_mkeep   ),
    .mac_axis_mlast   (mac_axis_mlast   ),
    .mac_axis_mvalid  (mac_axis_mvalid  ),
    .mac_axis_mready  (mac_axis_mready  ),
    .mac_axis_sdata   (mac_axis_sdata   ),
    .mac_axis_skeep   (mac_axis_skeep   ),
    .mac_axis_slast   (mac_axis_slast   ),
    .mac_axis_svalid  (mac_axis_svalid  ),
    .mac_axis_susr    (mac_axis_susr    ),
    .mac_axis_sready  (mac_axis_sready  ),
    // IPv4 flat 通道（对外段索引: 0=icmp, 1=ospf, 2=0x06, 3=兜底）
    .ipv4_axis_mdata  (ipv4_axis_mdata  ),
    .ipv4_axis_mkeep  (ipv4_axis_mkeep  ),
    .ipv4_axis_mlast  (ipv4_axis_mlast  ),
    .ipv4_axis_mvalid (ipv4_axis_mvalid ),
    .ipv4_axis_musr   (ipv4_axis_musr   ),
    .ipv4_axis_mready (ipv4_axis_mready ),
    // ICMPv4 flat 通道（每口 1 路，只含非 echo 的 ICMP）
    .icmp_axis_mdata  (icmp_axis_mdata  ),
    .icmp_axis_mkeep  (icmp_axis_mkeep  ),
    .icmp_axis_mlast  (icmp_axis_mlast  ),
    .icmp_axis_mvalid (icmp_axis_mvalid ),
    .icmp_axis_musr   (icmp_axis_musr   ),
    .icmp_axis_mready (icmp_axis_mready ),
    // ICMP 发送: 本测试用 0 路(ICMP_TX_TYPE_NUM_ARR=0)，占位 1 路恒 0
    .icmp_axis_sdata  (1024'd0),
    .icmp_axis_skeep  (128'd0),
    .icmp_axis_slast  (2'd0),
    .icmp_axis_svalid (2'd0),
    .icmp_axis_susr   (8'd0),
    .icmp_axis_sready (       ),
    .ipv4_axis_sdata  (ipv4_axis_sdata  ),
    .ipv4_axis_skeep  (ipv4_axis_skeep  ),
    .ipv4_axis_slast  (ipv4_axis_slast  ),
    .ipv4_axis_svalid (ipv4_axis_svalid ),
    .ipv4_axis_susr   (ipv4_axis_susr   ),
    .ipv4_axis_sready (ipv4_axis_sready ),
    // IPv6 IP->MAC 映射表（dest=对端表 / src=本机表; 每口项0 有效, 项1 空）
    //   A 口: dest={0,B} src={0,A};  B 口: dest={0,A} src={0,B}
    .cfg_dst_ipv6 (cfg_dst_ipv6 ),
    .cfg_dst_mac  (cfg_dst_mac  ),
    .cfg_src_ipv6 (cfg_src_ipv6 ),
    .cfg_src_mac  (cfg_src_mac  ),
    // IPv6 flat 通道（ch0=udp / ch1=icmpv6 / ch2=ospf / ch3=other）
    .ipv6_axis_mdata  (ipv6_axis_mdata  ),
    .ipv6_axis_mkeep  (ipv6_axis_mkeep  ),
    .ipv6_axis_mlast  (ipv6_axis_mlast  ),
    .ipv6_axis_mvalid (ipv6_axis_mvalid ),
    .ipv6_axis_musr   (ipv6_axis_musr   ),
    .ipv6_axis_mready (ipv6_axis_mready ),
    .ipv6_axis_sdata  (ipv6_axis_sdata  ),
    .ipv6_axis_skeep  (ipv6_axis_skeep  ),
    .ipv6_axis_slast  (ipv6_axis_slast  ),
    .ipv6_axis_svalid (ipv6_axis_svalid ),
    .ipv6_axis_susr   (ipv6_axis_susr   ),
    .ipv6_axis_sready (ipv6_axis_sready ),
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
    .udp_axis_susr    (udp_axis_susr    ),
    .udp_axis_sready  (udp_axis_sready  ),
    // 状态
    .stat_is_df          (stat_is_df         ),
    .stat_tx_active_port (stat_tx_active_port),
    .stat_tx_idle        (stat_tx_idle       ),
    .stat_arp_rx_error   (stat_arp_rx_error  ),
    .stat_arp_ack_ovf    (stat_arp_ack_ovf   ),
    .stat_arp_pend_ovf   (stat_arp_pend_ovf  ),
    .stat_arp_no_resp    (stat_arp_no_resp   ),
    .stat_arp_pend_clr   (stat_arp_pend_clr  ),
    .stat_arp_cache_clr  (stat_arp_cache_clr ),
    .stat_arp_src_not_local(stat_arp_src_not_local),
    .stat_ipv6_drop_pulse(                   ),
    .stat_icmp_drop      (stat_icmp_drop     ),
    .stat_icmp_drop_reason(stat_icmp_drop_reason)
  );

  // ============================================================================
  // RX 未使用
  // ============================================================================
  assign  ipv6_axis_mready[IDX_IP6_RX_A_UDP]= 1'b1             ;// 口A IPv6 ch0(NH=0x11, 无校验机)
  assign  ipv6_axis_mready[IDX_IP6_RX_B_UDP]= 1'b1             ;// 口B IPv6 ch0(NH=0x11, 无校验机)
  assign  udp_axis_mready [IDX_UDP_RX_A_P0]= 1'b1             ;// 口A 区间[0,0] 未接机
  assign  udp_axis_mready [IDX_UDP_RX_A_P1]= 1'b1             ;// 口A 区间[1,1] 未接机
  assign  udp_axis_mready [IDX_UDP_RX_B_P48]= 1'b1             ;// 口B 区间[4,8] 未接机

  // PAD位清空
  genvar tp;
  generate
  for (tp = 0; tp < ETH_PORT_NUM; tp = tp + 1) begin : g_slot_pad
    localparam [     CFG_NUM_WIDTH-1:0]        P_MAC_RX_N= MAC_RX_TYPE_NUM_ARR [tp*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
    localparam [     CFG_NUM_WIDTH-1:0]        P_MAC_TX_N= MAC_TX_TYPE_NUM_ARR [tp*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
    localparam [     CFG_NUM_WIDTH-1:0]        P_IPV4_RX_N= IPV4_RX_TYPE_NUM_ARR[tp*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
    localparam [     CFG_NUM_WIDTH-1:0]        P_IPV4_TX_N= IPV4_TX_TYPE_NUM_ARR[tp*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
    localparam [     CFG_NUM_WIDTH-1:0]        P_IPV6_RX_N= IPV6_RX_TYPE_NUM_ARR[tp*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
    localparam [     CFG_NUM_WIDTH-1:0]        P_UDP_RX_N= UDP_RX_PORT_NUM_ARR [tp*CFG_NUM_WIDTH +: CFG_NUM_WIDTH];
    genvar k1, k2, k3, k4, k5, k6;
    // ---- 槽内填充 lane（MAX > 本口实际档数时）: RX 侧收下即丢 ----
    for (k1 = P_MAC_RX_N+1;  k1 <= MAC_RX_TYPE_NUM_MAX;  k1 = k1+1) begin : g_mac_rx_pad
  assign  mac_axis_mready [(tp*(MAC_RX_TYPE_NUM_MAX+1)+k1)]= 1'b1             ;
    end
    for (k2 = P_IPV4_RX_N+1; k2 <= IPV4_RX_TYPE_NUM_MAX; k2 = k2+1) begin : g_ipv4_rx_pad
  assign  ipv4_axis_mready[(tp*(IPV4_RX_TYPE_NUM_MAX+1)+k2)]= 1'b1             ;
    end
    for (k3 = P_IPV6_RX_N+1; k3 <= IPV6_RX_TYPE_NUM_MAX; k3 = k3+1) begin : g_ipv6_rx_pad
  assign  ipv6_axis_mready[(tp*(IPV6_RX_TYPE_NUM_MAX+1)+k3)]= 1'b1             ;
    end
    for (k4 = P_UDP_RX_N+1;  k4 <= UDP_RX_PORT_NUM_MAX;  k4 = k4+1) begin : g_udp_rx_pad
  assign  udp_axis_mready [(tp*(UDP_RX_PORT_NUM_MAX+1)+k4)]= 1'b1             ;
    end
    // ---- 槽内填充路（TX 侧）: 恒 0, 不参与仲裁 ----
    for (k5 = P_MAC_TX_N;   k5 <  MAC_TX_N_MAX;   k5 = k5+1) begin : g_mac_tx_pad
  assign  mac_axis_svalid [tp*MAC_TX_N_MAX+k5]= 1'b0             ;
  assign  mac_axis_slast [tp*MAC_TX_N_MAX+k5]= 1'b0             ;
  assign  mac_axis_sdata [(tp*MAC_TX_N_MAX+k5)*512 +: 512]= 512'd0           ;
  assign  mac_axis_skeep [(tp*MAC_TX_N_MAX+k5)* 64 +:  64]= 64'd0            ;
    end
    for (k6 = P_IPV4_TX_N;  k6 <  IPV4_TX_N_MAX;  k6 = k6+1) begin : g_ipv4_tx_pad
  assign  ipv4_axis_svalid[tp*IPV4_TX_N_MAX+k6]= 1'b0             ;
  assign  ipv4_axis_slast[tp*IPV4_TX_N_MAX+k6]= 1'b0             ;
  assign  ipv4_axis_sdata[(tp*IPV4_TX_N_MAX+k6)*512 +: 512]= 512'd0           ;
  assign  ipv4_axis_skeep[(tp*IPV4_TX_N_MAX+k6)* 64 +:  64]= 64'd0            ;
    end
  end
  endgenerate

  // ============================================================================
  // UDP TX 未使用
  // ============================================================================
  genvar gu;
  generate
  for (gu = 0; gu < UDP_TX_N_MAX*ETH_PORT_NUM; gu = gu + 1) begin : gen_udp_tx_conn
    localparam G_LANE = gu % UDP_TX_N_MAX;                      // 口内路号
    if (G_LANE >= 2) begin : gen_tie0                           // 第 2 路及以后: 恒 0
  assign  udp_axis_sdata[gu*512 +: 512]= 512'd0           ;
  assign  udp_axis_skeep[gu* 64 +:  64]= 64'd0            ;
  assign  udp_axis_slast[gu]= 1'b0             ;
  assign  udp_axis_svalid[gu]= 1'b0             ;
    end
  end
  endgenerate

  // ============================================================================
  // 打流模块
  // ============================================================================
  // ---- 网口 A ----
  // A 口 UDP 业务流(端口2) -> 口B 区间[2,2]
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (320'd0)          // UDP: 纯载荷(头由 DUT 按 usr 生成)
  ) u_ta_udp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_udp),
    .axis_mdata       (udp_axis_sdata[(IDX_UDP_TX_A_DATA)*512 +: 512]), .axis_mkeep(udp_axis_skeep[(IDX_UDP_TX_A_DATA)*64 +: 64]),
    .axis_mvalid      (udp_axis_svalid[IDX_UDP_TX_A_DATA]), .axis_mlast(udp_axis_slast[IDX_UDP_TX_A_DATA]),
    .axis_mready      (udp_axis_sready[IDX_UDP_TX_A_DATA]),
    .axis_sdata       (udp_axis_mdata[(IDX_UDP_RX_B_P2)*512 +: 512]), .axis_skeep(udp_axis_mkeep[(IDX_UDP_RX_B_P2)*64 +: 64]),
    .axis_svalid      (udp_axis_mvalid[IDX_UDP_RX_B_P2]), .axis_slast(udp_axis_mlast[IDX_UDP_RX_B_P2]),
    .axis_sready      (udp_axis_mready[IDX_UDP_RX_B_P2]) 
  );

  // A 口 IPv4-icmp(非 echo) -> 口B ICMPv4 独立口 icmp_axis_m*(不含 echo)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP_ICMP_A)
  ) u_ta_icmp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_icmp),
    .axis_mdata       (ipv4_axis_sdata[(IDX_IP4_TX_A_ICMP)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(IDX_IP4_TX_A_ICMP)*64 +: 64]),
    .axis_mvalid      (ipv4_axis_svalid[IDX_IP4_TX_A_ICMP]), .axis_mlast(ipv4_axis_slast[IDX_IP4_TX_A_ICMP]),
    .axis_mready      (ipv4_axis_sready[IDX_IP4_TX_A_ICMP]),
    .axis_sdata       (icmp_axis_mdata[IDX_ICMP_RX_B*512 +: 512]), .axis_skeep(icmp_axis_mkeep[IDX_ICMP_RX_B*64 +: 64]),
    .axis_svalid      (icmp_axis_mvalid[IDX_ICMP_RX_B]), .axis_slast(icmp_axis_mlast[IDX_ICMP_RX_B]),
    .axis_sready      (icmp_axis_mready[IDX_ICMP_RX_B]) 
  );

  // A 口 IPv4-ospf -> 口B ch2(0x59)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP_OSPF_A)
  ) u_ta_ospf (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_ospf),
    .axis_mdata       (ipv4_axis_sdata[(IDX_IP4_TX_A_OSPF)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(IDX_IP4_TX_A_OSPF)*64 +: 64]),
    .axis_mvalid      (ipv4_axis_svalid[IDX_IP4_TX_A_OSPF]), .axis_mlast(ipv4_axis_slast[IDX_IP4_TX_A_OSPF]),
    .axis_mready      (ipv4_axis_sready[IDX_IP4_TX_A_OSPF]),
    .axis_sdata       (ipv4_axis_mdata[(IDX_IP4_RX_B_OSPF)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(IDX_IP4_RX_B_OSPF)*64 +: 64]),
    .axis_svalid      (ipv4_axis_mvalid[IDX_IP4_RX_B_OSPF]), .axis_slast(ipv4_axis_mlast[IDX_IP4_RX_B_OSPF]),
    .axis_sready      (ipv4_axis_mready[IDX_IP4_RX_B_OSPF]) 
  );

  // A 口 IPv4-协议0x06 -> 口B ch0(0x06)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP_06_A)
  ) u_ta_ipv4_06 (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_ipv4_06),
    .axis_mdata       (ipv4_axis_sdata[(IDX_IP4_TX_A_06)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(IDX_IP4_TX_A_06)*64 +: 64]),
    .axis_mvalid      (ipv4_axis_svalid[IDX_IP4_TX_A_06]), .axis_mlast(ipv4_axis_slast[IDX_IP4_TX_A_06]),
    .axis_mready      (ipv4_axis_sready[IDX_IP4_TX_A_06]),
    .axis_sdata       (ipv4_axis_mdata[(IDX_IP4_RX_B_06)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(IDX_IP4_RX_B_06)*64 +: 64]),
    .axis_svalid      (ipv4_axis_mvalid[IDX_IP4_RX_B_06]), .axis_slast(ipv4_axis_mlast[IDX_IP4_RX_B_06]),
    .axis_sready      (ipv4_axis_mready[IDX_IP4_RX_B_06]) 
  );

  // A 口 MAC-自定义类型 0x88B5 -> 口B ch0(0x88B5)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_MAC_88B5_A)
  ) u_ta_mac_88b5 (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_mac_88b5),
    .axis_mdata       (mac_axis_sdata[(IDX_MAC_TX_A_88B5)*512 +: 512]), .axis_mkeep(mac_axis_skeep[(IDX_MAC_TX_A_88B5)*64 +: 64]),
    .axis_mvalid      (mac_axis_svalid[IDX_MAC_TX_A_88B5]), .axis_mlast(mac_axis_slast[IDX_MAC_TX_A_88B5]),
    .axis_mready      (mac_axis_sready[IDX_MAC_TX_A_88B5]),
    .axis_sdata       (mac_axis_mdata[(IDX_MAC_RX_B_88B5)*512 +: 512]), .axis_skeep(mac_axis_mkeep[(IDX_MAC_RX_B_88B5)*64 +: 64]),
    .axis_svalid      (mac_axis_mvalid[IDX_MAC_RX_B_88B5]), .axis_slast(mac_axis_mlast[IDX_MAC_RX_B_88B5]),
    .axis_sready      (mac_axis_mready[IDX_MAC_RX_B_88B5]) 
  );

  // A 口 IPv6-icmpv6 -> 口B ch2(0x3A)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP6_ICMP_A)
  ) u_ta_ip6icmp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_ip6icmp),
    .axis_mdata       (ipv6_axis_sdata[(IDX_IP6_TX_A_ICMP)*512 +: 512]), .axis_mkeep(ipv6_axis_skeep[(IDX_IP6_TX_A_ICMP)*64 +: 64]),
    .axis_mvalid      (ipv6_axis_svalid[IDX_IP6_TX_A_ICMP]), .axis_mlast(ipv6_axis_slast[IDX_IP6_TX_A_ICMP]),
    .axis_mready      (ipv6_axis_sready[IDX_IP6_TX_A_ICMP]),
    .axis_sdata       (ipv6_axis_mdata[(IDX_IP6_RX_B_ICMP)*512 +: 512]), .axis_skeep(ipv6_axis_mkeep[(IDX_IP6_RX_B_ICMP)*64 +: 64]),
    .axis_svalid      (ipv6_axis_mvalid[IDX_IP6_RX_B_ICMP]), .axis_slast(ipv6_axis_mlast[IDX_IP6_RX_B_ICMP]),
    .axis_sready      (ipv6_axis_mready[IDX_IP6_RX_B_ICMP]) 
  );

  // A 口 IPv6-ospfv3 -> 口B ch1(0x59)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP6_OSPF_A)
  ) u_ta_ip6ospf (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_ip6ospf),
    .axis_mdata       (ipv6_axis_sdata[(IDX_IP6_TX_A_OSPF)*512 +: 512]), .axis_mkeep(ipv6_axis_skeep[(IDX_IP6_TX_A_OSPF)*64 +: 64]),
    .axis_mvalid      (ipv6_axis_svalid[IDX_IP6_TX_A_OSPF]), .axis_mlast(ipv6_axis_slast[IDX_IP6_TX_A_OSPF]),
    .axis_mready      (ipv6_axis_sready[IDX_IP6_TX_A_OSPF]),
    .axis_sdata       (ipv6_axis_mdata[(IDX_IP6_RX_B_OSPF)*512 +: 512]), .axis_skeep(ipv6_axis_mkeep[(IDX_IP6_RX_B_OSPF)*64 +: 64]),
    .axis_svalid      (ipv6_axis_mvalid[IDX_IP6_RX_B_OSPF]), .axis_slast(ipv6_axis_mlast[IDX_IP6_RX_B_OSPF]),
    .axis_sready      (ipv6_axis_mready[IDX_IP6_RX_B_OSPF]) 
  );

  // ---- A -> B 兜底档探测（4 层）----
  // A 发 0x88DD(两口字典都无) -> 口B MAC 兜底档
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_MAC_FB_A)
  ) u_ta_fb_mac (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_fb_mac),
    .axis_mdata       (mac_axis_sdata[(IDX_MAC_TX_A_FB)*512 +: 512]), .axis_mkeep(mac_axis_skeep[(IDX_MAC_TX_A_FB)*64 +: 64]),
    .axis_mvalid      (mac_axis_svalid[IDX_MAC_TX_A_FB]), .axis_mlast(mac_axis_slast[IDX_MAC_TX_A_FB]),
    .axis_mready      (mac_axis_sready[IDX_MAC_TX_A_FB]),
    .axis_sdata       (mac_axis_mdata[(IDX_MAC_RX_B_FB)*512 +: 512]), .axis_skeep(mac_axis_mkeep[(IDX_MAC_RX_B_FB)*64 +: 64]),
    .axis_svalid      (mac_axis_mvalid[IDX_MAC_RX_B_FB]), .axis_slast(mac_axis_mlast[IDX_MAC_RX_B_FB]),
    .axis_sready      (mac_axis_mready[IDX_MAC_RX_B_FB]) 
  );

  // A 发 IPv4 协议0x2F(未匹配) -> 口B IPv4 兜底档
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP_FB_A)
  ) u_ta_fb_ipv4 (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_fb_ipv4),
    .axis_mdata       (ipv4_axis_sdata[(IDX_IP4_TX_A_FB)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(IDX_IP4_TX_A_FB)*64 +: 64]),
    .axis_mvalid      (ipv4_axis_svalid[IDX_IP4_TX_A_FB]), .axis_mlast(ipv4_axis_slast[IDX_IP4_TX_A_FB]),
    .axis_mready      (ipv4_axis_sready[IDX_IP4_TX_A_FB]),
    .axis_sdata       (ipv4_axis_mdata[(IDX_IP4_RX_B_FB)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(IDX_IP4_RX_B_FB)*64 +: 64]),
    .axis_svalid      (ipv4_axis_mvalid[IDX_IP4_RX_B_FB]), .axis_slast(ipv4_axis_mlast[IDX_IP4_RX_B_FB]),
    .axis_sready      (ipv4_axis_mready[IDX_IP4_RX_B_FB]) 
  );

  // A 发 IPv6 NH=0x06(未匹配) -> 口B IPv6 兜底档
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP6_FB_A)
  ) u_ta_fb_ipv6 (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_fb_ipv6),
    .axis_mdata       (ipv6_axis_sdata[(IDX_IP6_TX_A_FB)*512 +: 512]), .axis_mkeep(ipv6_axis_skeep[(IDX_IP6_TX_A_FB)*64 +: 64]),
    .axis_mvalid      (ipv6_axis_svalid[IDX_IP6_TX_A_FB]), .axis_mlast(ipv6_axis_slast[IDX_IP6_TX_A_FB]),
    .axis_mready      (ipv6_axis_sready[IDX_IP6_TX_A_FB]),
    .axis_sdata       (ipv6_axis_mdata[(IDX_IP6_RX_B_FB)*512 +: 512]), .axis_skeep(ipv6_axis_mkeep[(IDX_IP6_RX_B_FB)*64 +: 64]),
    .axis_svalid      (ipv6_axis_mvalid[IDX_IP6_RX_B_FB]), .axis_slast(ipv6_axis_mlast[IDX_IP6_RX_B_FB]),
    .axis_sready      (ipv6_axis_mready[IDX_IP6_RX_B_FB]) 
  );

  // A 发 UDP 端口0x1234(不在区间) -> 口B UDP 兜底档
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (320'd0)          // UDP: 纯载荷
  ) u_ta_fb_udp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_fb_udp),
    .axis_mdata       (udp_axis_sdata[(IDX_UDP_TX_A_FB)*512 +: 512]), .axis_mkeep(udp_axis_skeep[(IDX_UDP_TX_A_FB)*64 +: 64]),
    .axis_mvalid      (udp_axis_svalid[IDX_UDP_TX_A_FB]), .axis_mlast(udp_axis_slast[IDX_UDP_TX_A_FB]),
    .axis_mready      (udp_axis_sready[IDX_UDP_TX_A_FB]),
    .axis_sdata       (udp_axis_mdata[(IDX_UDP_RX_B_FB)*512 +: 512]), .axis_skeep(udp_axis_mkeep[(IDX_UDP_RX_B_FB)*64 +: 64]),
    .axis_svalid      (udp_axis_mvalid[IDX_UDP_RX_B_FB]), .axis_slast(udp_axis_mlast[IDX_UDP_RX_B_FB]),
    .axis_sready      (udp_axis_mready[IDX_UDP_RX_B_FB]) 
  );

  // ---- 网口 B ----
  // B 口 UDP 业务流(端口2) -> 口A 区间[2,8]
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (320'd0)          // UDP: 纯载荷
  ) u_tb_udp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_udp),
    .axis_mdata       (udp_axis_sdata[(IDX_UDP_TX_B_DATA)*512 +: 512]), .axis_mkeep(udp_axis_skeep[(IDX_UDP_TX_B_DATA)*64 +: 64]),
    .axis_mvalid      (udp_axis_svalid[IDX_UDP_TX_B_DATA]), .axis_mlast(udp_axis_slast[IDX_UDP_TX_B_DATA]),
    .axis_mready      (udp_axis_sready[IDX_UDP_TX_B_DATA]),
    .axis_sdata       (udp_axis_mdata[(IDX_UDP_RX_A_P2)*512 +: 512]), .axis_skeep(udp_axis_mkeep[(IDX_UDP_RX_A_P2)*64 +: 64]),
    .axis_svalid      (udp_axis_mvalid[IDX_UDP_RX_A_P2]), .axis_slast(udp_axis_mlast[IDX_UDP_RX_A_P2]),
    .axis_sready      (udp_axis_mready[IDX_UDP_RX_A_P2]) 
  );

  // B 口 IPv4-icmp(非 echo) -> 口A ICMPv4 独立口 icmp_axis_m*(不含 echo)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP_ICMP_B)
  ) u_tb_icmp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_icmp),
    .axis_mdata       (ipv4_axis_sdata[(IDX_IP4_TX_B_ICMP)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(IDX_IP4_TX_B_ICMP)*64 +: 64]),
    .axis_mvalid      (ipv4_axis_svalid[IDX_IP4_TX_B_ICMP]), .axis_mlast(ipv4_axis_slast[IDX_IP4_TX_B_ICMP]),
    .axis_mready      (ipv4_axis_sready[IDX_IP4_TX_B_ICMP]),
    .axis_sdata       (icmp_axis_mdata[IDX_ICMP_RX_A*512 +: 512]), .axis_skeep(icmp_axis_mkeep[IDX_ICMP_RX_A*64 +: 64]),
    .axis_svalid      (icmp_axis_mvalid[IDX_ICMP_RX_A]), .axis_slast(icmp_axis_mlast[IDX_ICMP_RX_A]),
    .axis_sready      (icmp_axis_mready[IDX_ICMP_RX_A]) 
  );

  // B 口 IPv4-ospf -> 口A ch1(0x59)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP_OSPF_B)
  ) u_tb_ospf (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_ospf),
    .axis_mdata       (ipv4_axis_sdata[(IDX_IP4_TX_B_OSPF)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(IDX_IP4_TX_B_OSPF)*64 +: 64]),
    .axis_mvalid      (ipv4_axis_svalid[IDX_IP4_TX_B_OSPF]), .axis_mlast(ipv4_axis_slast[IDX_IP4_TX_B_OSPF]),
    .axis_mready      (ipv4_axis_sready[IDX_IP4_TX_B_OSPF]),
    .axis_sdata       (ipv4_axis_mdata[(IDX_IP4_RX_A_OSPF)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(IDX_IP4_RX_A_OSPF)*64 +: 64]),
    .axis_svalid      (ipv4_axis_mvalid[IDX_IP4_RX_A_OSPF]), .axis_slast(ipv4_axis_mlast[IDX_IP4_RX_A_OSPF]),
    .axis_sready      (ipv4_axis_mready[IDX_IP4_RX_A_OSPF]) 
  );

  // B 口 IPv4-协议0x06 -> 口A ch2(0x06)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP_06_B)
  ) u_tb_ipv4_06 (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_ipv4_06),
    .axis_mdata       (ipv4_axis_sdata[(IDX_IP4_TX_B_06)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(IDX_IP4_TX_B_06)*64 +: 64]),
    .axis_mvalid      (ipv4_axis_svalid[IDX_IP4_TX_B_06]), .axis_mlast(ipv4_axis_slast[IDX_IP4_TX_B_06]),
    .axis_mready      (ipv4_axis_sready[IDX_IP4_TX_B_06]),
    .axis_sdata       (ipv4_axis_mdata[(IDX_IP4_RX_A_06)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(IDX_IP4_RX_A_06)*64 +: 64]),
    .axis_svalid      (ipv4_axis_mvalid[IDX_IP4_RX_A_06]), .axis_slast(ipv4_axis_mlast[IDX_IP4_RX_A_06]),
    .axis_sready      (ipv4_axis_mready[IDX_IP4_RX_A_06]) 
  );

  // B 口 MAC-自定义类型 0x88B5 -> 口A ch0(0x88B5)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_MAC_88B5_B)
  ) u_tb_mac_88b5 (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_mac_88b5),
    .axis_mdata       (mac_axis_sdata[(IDX_MAC_TX_B_88B5)*512 +: 512]), .axis_mkeep(mac_axis_skeep[(IDX_MAC_TX_B_88B5)*64 +: 64]),
    .axis_mvalid      (mac_axis_svalid[IDX_MAC_TX_B_88B5]), .axis_mlast(mac_axis_slast[IDX_MAC_TX_B_88B5]),
    .axis_mready      (mac_axis_sready[IDX_MAC_TX_B_88B5]),
    .axis_sdata       (mac_axis_mdata[(IDX_MAC_RX_A_88B5)*512 +: 512]), .axis_skeep(mac_axis_mkeep[(IDX_MAC_RX_A_88B5)*64 +: 64]),
    .axis_svalid      (mac_axis_mvalid[IDX_MAC_RX_A_88B5]), .axis_slast(mac_axis_mlast[IDX_MAC_RX_A_88B5]),
    .axis_sready      (mac_axis_mready[IDX_MAC_RX_A_88B5]) 
  );

  // B 口 MAC-自定义类型 0x88CC -> 口A ch1(0x88CC, 仅 A 配了该档)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_MAC_88CC_B)
  ) u_tb_mac_88cc (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_mac_88cc),
    .axis_mdata       (mac_axis_sdata[(IDX_MAC_TX_B_88CC)*512 +: 512]), .axis_mkeep(mac_axis_skeep[(IDX_MAC_TX_B_88CC)*64 +: 64]),
    .axis_mvalid      (mac_axis_svalid[IDX_MAC_TX_B_88CC]), .axis_mlast(mac_axis_slast[IDX_MAC_TX_B_88CC]),
    .axis_mready      (mac_axis_sready[IDX_MAC_TX_B_88CC]),
    .axis_sdata       (mac_axis_mdata[(IDX_MAC_RX_A_88CC)*512 +: 512]), .axis_skeep(mac_axis_mkeep[(IDX_MAC_RX_A_88CC)*64 +: 64]),
    .axis_svalid      (mac_axis_mvalid[IDX_MAC_RX_A_88CC]), .axis_slast(mac_axis_mlast[IDX_MAC_RX_A_88CC]),
    .axis_sready      (mac_axis_mready[IDX_MAC_RX_A_88CC]) 
  );

  // B 口 IPv6-icmpv6 -> 口A ch1(0x3A)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP6_ICMP_B)
  ) u_tb_ip6icmp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_ip6icmp),
    .axis_mdata       (ipv6_axis_sdata[(IDX_IP6_TX_B_ICMP)*512 +: 512]), .axis_mkeep(ipv6_axis_skeep[(IDX_IP6_TX_B_ICMP)*64 +: 64]),
    .axis_mvalid      (ipv6_axis_svalid[IDX_IP6_TX_B_ICMP]), .axis_mlast(ipv6_axis_slast[IDX_IP6_TX_B_ICMP]),
    .axis_mready      (ipv6_axis_sready[IDX_IP6_TX_B_ICMP]),
    .axis_sdata       (ipv6_axis_mdata[(IDX_IP6_RX_A_ICMP)*512 +: 512]), .axis_skeep(ipv6_axis_mkeep[(IDX_IP6_RX_A_ICMP)*64 +: 64]),
    .axis_svalid      (ipv6_axis_mvalid[IDX_IP6_RX_A_ICMP]), .axis_slast(ipv6_axis_mlast[IDX_IP6_RX_A_ICMP]),
    .axis_sready      (ipv6_axis_mready[IDX_IP6_RX_A_ICMP]) 
  );

  // B 口 IPv6-ospfv3 -> 口A ch2(0x59)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP6_OSPF_B)
  ) u_tb_ip6ospf (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_ip6ospf),
    .axis_mdata       (ipv6_axis_sdata[(IDX_IP6_TX_B_OSPF)*512 +: 512]), .axis_mkeep(ipv6_axis_skeep[(IDX_IP6_TX_B_OSPF)*64 +: 64]),
    .axis_mvalid      (ipv6_axis_svalid[IDX_IP6_TX_B_OSPF]), .axis_mlast(ipv6_axis_slast[IDX_IP6_TX_B_OSPF]),
    .axis_mready      (ipv6_axis_sready[IDX_IP6_TX_B_OSPF]),
    .axis_sdata       (ipv6_axis_mdata[(IDX_IP6_RX_A_OSPF)*512 +: 512]), .axis_skeep(ipv6_axis_mkeep[(IDX_IP6_RX_A_OSPF)*64 +: 64]),
    .axis_svalid      (ipv6_axis_mvalid[IDX_IP6_RX_A_OSPF]), .axis_slast(ipv6_axis_mlast[IDX_IP6_RX_A_OSPF]),
    .axis_sready      (ipv6_axis_mready[IDX_IP6_RX_A_OSPF]) 
  );

  // ---- B -> A 兜底档探测（4 层）----
  // B 发 0x88DD(两口字典都无) -> 口A MAC 兜底档
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_MAC_FB_B)
  ) u_tb_fb_mac (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_fb_mac),
    .axis_mdata       (mac_axis_sdata[(IDX_MAC_TX_B_FB)*512 +: 512]), .axis_mkeep(mac_axis_skeep[(IDX_MAC_TX_B_FB)*64 +: 64]),
    .axis_mvalid      (mac_axis_svalid[IDX_MAC_TX_B_FB]), .axis_mlast(mac_axis_slast[IDX_MAC_TX_B_FB]),
    .axis_mready      (mac_axis_sready[IDX_MAC_TX_B_FB]),
    .axis_sdata       (mac_axis_mdata[(IDX_MAC_RX_A_FB)*512 +: 512]), .axis_skeep(mac_axis_mkeep[(IDX_MAC_RX_A_FB)*64 +: 64]),
    .axis_svalid      (mac_axis_mvalid[IDX_MAC_RX_A_FB]), .axis_slast(mac_axis_mlast[IDX_MAC_RX_A_FB]),
    .axis_sready      (mac_axis_mready[IDX_MAC_RX_A_FB]) 
  );

  // B 发 IPv4 协议0x2F(未匹配) -> 口A IPv4 兜底档
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP_FB_B)
  ) u_tb_fb_ipv4 (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_fb_ipv4),
    .axis_mdata       (ipv4_axis_sdata[(IDX_IP4_TX_B_FB)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(IDX_IP4_TX_B_FB)*64 +: 64]),
    .axis_mvalid      (ipv4_axis_svalid[IDX_IP4_TX_B_FB]), .axis_mlast(ipv4_axis_slast[IDX_IP4_TX_B_FB]),
    .axis_mready      (ipv4_axis_sready[IDX_IP4_TX_B_FB]),
    .axis_sdata       (ipv4_axis_mdata[(IDX_IP4_RX_A_FB)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(IDX_IP4_RX_A_FB)*64 +: 64]),
    .axis_svalid      (ipv4_axis_mvalid[IDX_IP4_RX_A_FB]), .axis_slast(ipv4_axis_mlast[IDX_IP4_RX_A_FB]),
    .axis_sready      (ipv4_axis_mready[IDX_IP4_RX_A_FB]) 
  );

  // B 发 IPv6 NH=0x06(未匹配) -> 口A IPv6 兜底档
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP6_FB_B)
  ) u_tb_fb_ipv6 (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_fb_ipv6),
    .axis_mdata       (ipv6_axis_sdata[(IDX_IP6_TX_B_FB)*512 +: 512]), .axis_mkeep(ipv6_axis_skeep[(IDX_IP6_TX_B_FB)*64 +: 64]),
    .axis_mvalid      (ipv6_axis_svalid[IDX_IP6_TX_B_FB]), .axis_mlast(ipv6_axis_slast[IDX_IP6_TX_B_FB]),
    .axis_mready      (ipv6_axis_sready[IDX_IP6_TX_B_FB]),
    .axis_sdata       (ipv6_axis_mdata[(IDX_IP6_RX_A_FB)*512 +: 512]), .axis_skeep(ipv6_axis_mkeep[(IDX_IP6_RX_A_FB)*64 +: 64]),
    .axis_svalid      (ipv6_axis_mvalid[IDX_IP6_RX_A_FB]), .axis_slast(ipv6_axis_mlast[IDX_IP6_RX_A_FB]),
    .axis_sready      (ipv6_axis_mready[IDX_IP6_RX_A_FB]) 
  );

  // B 发 UDP 端口0x1234(不在区间) -> 口A UDP 兜底档
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (320'd0)          // UDP: 纯载荷
  ) u_tb_fb_udp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_fb_udp),
    .axis_mdata       (udp_axis_sdata[(IDX_UDP_TX_B_FB)*512 +: 512]), .axis_mkeep(udp_axis_skeep[(IDX_UDP_TX_B_FB)*64 +: 64]),
    .axis_mvalid      (udp_axis_svalid[IDX_UDP_TX_B_FB]), .axis_mlast(udp_axis_slast[IDX_UDP_TX_B_FB]),
    .axis_mready      (udp_axis_sready[IDX_UDP_TX_B_FB]),
    .axis_sdata       (udp_axis_mdata[(IDX_UDP_RX_A_FB)*512 +: 512]), .axis_skeep(udp_axis_mkeep[(IDX_UDP_RX_A_FB)*64 +: 64]),
    .axis_svalid      (udp_axis_mvalid[IDX_UDP_RX_A_FB]), .axis_slast(udp_axis_mlast[IDX_UDP_RX_A_FB]),
    .axis_sready      (udp_axis_mready[IDX_UDP_RX_A_FB]) 
  );

  // ============================================================================
  // TX 优先级(user)接线
  // ============================================================================
  assign  mac_axis_susr   = { PRIO_FB, PRIO_MAC88B5_B, PRIO_MAC88B5_B,   // 口B: 填充/88CC/88B5
                              {ARBITER_VAL_WIDTH{1'b0}}, PRIO_FB, PRIO_MAC88B5_A }; // 口A: 填充/兜底探测/88B5
  assign  ipv4_axis_susr  = { PRIO_FB, PRIO_IP06_B,  PRIO_OSPF_B, PRIO_ICMP_B,    // 口B: 2F/06/ospf/icmp
                              PRIO_FB, PRIO_IP06_A,  PRIO_OSPF_A, PRIO_ICMP_A };  // 口A: 2F/06/ospf/icmp
  assign  ipv6_axis_susr  = { PRIO_FB, PRIO_OSPFV3_B, PRIO_ICMPV6_B,     // 口B: 兜底探测/ospfv3/icmpv6
                              PRIO_FB, PRIO_OSPFV3_A, PRIO_ICMPV6_A };   // 口A: 兜底探测/ospfv3/icmpv6
  assign  udp_axis_susr   = { {UDP_TX_USR_WIDTH{1'b0}},{UDP_TX_USR_WIDTH{1'b0}},{UDP_TX_USR_WIDTH{1'b0}},{UDP_TX_USR_WIDTH{1'b0}},{UDP_TX_USR_WIDTH{1'b0}},{UDP_TX_USR_WIDTH{1'b0}}, UDP_USR_FB_B, UDP_USR_DATA_B,
                              {UDP_TX_USR_WIDTH{1'b0}},{UDP_TX_USR_WIDTH{1'b0}},{UDP_TX_USR_WIDTH{1'b0}},{UDP_TX_USR_WIDTH{1'b0}},{UDP_TX_USR_WIDTH{1'b0}},{UDP_TX_USR_WIDTH{1'b0}}, UDP_USR_FB_A, UDP_USR_DATA_A };

  // ============================================================================
  // VIO : 启动/停止打流（每台测试机一位）
  // ============================================================================
  vio_enable u_test_vio_enable (
    .clk              (clk_400m         ),// input wire clk
    .probe_out0        (en_a_udp           ),// A 口 UDP(端口2)
    .probe_out1        (en_a_icmp          ),// A 口 IPv4-icmp
    .probe_out2        (en_a_ospf          ),// A 口 IPv4-ospf
    .probe_out3        (en_a_ipv4_06       ),// A 口 IPv4-协议0x06
    .probe_out4        (en_a_mac_88b5      ),// A 口 MAC-自定义0x88B5
    .probe_out5        (en_b_udp           ),// B 口 UDP(端口2)
    .probe_out6        (en_b_icmp          ),// B 口 IPv4-icmp
    .probe_out7        (en_b_ospf          ),// B 口 IPv4-ospf
    .probe_out8        (en_b_ipv4_06       ),// B 口 IPv4-协议0x06
    .probe_out9        (en_b_mac_88b5      ),// B 口 MAC-自定义0x88B5
    .probe_out10       (en_a_ip6icmp       ),// A 口 IPv6-icmpv6
    .probe_out11       (en_a_ip6ospf       ),// A 口 IPv6-ospfv3
    .probe_out12       (en_b_ip6icmp       ),// B 口 IPv6-icmpv6
    .probe_out13       (en_b_ip6ospf       ),// B 口 IPv6-ospfv3
    .probe_out14       (en_a_fb_mac        ),// A 发 MAC兜底探测(0x88DD)->B兜底档
    .probe_out15       (en_a_fb_ipv4       ),// A 发 IPv4兜底探测(0x2F)->B兜底档
    .probe_out16       (en_a_fb_ipv6       ),// A 发 IPv6兜底探测(NH=06)->B兜底档
    .probe_out17       (en_a_fb_udp        ),// A 发 UDP兜底探测(端口0x1234)->B兜底档
    .probe_out18       (en_b_mac_88cc      ),// B 发 MAC-自定义0x88CC->A ch1
    .probe_out19       (en_b_fb_mac        ),// B 发 MAC兜底探测->A兜底档
    .probe_out20       (en_b_fb_ipv4       ),// B 发 IPv4兜底探测->A兜底档
    .probe_out21       (en_b_fb_ipv6       ),// B 发 IPv6兜底探测->A兜底档
    .probe_out22       (en_b_fb_udp        ) // B 发 UDP兜底探测->A兜底档
  );

  // ============================================================================
  // 命令通道 FIFO : 隔离 UDP 命令档与 cfg 解析
  // ============================================================================
  axis_fifo_sync #(
    .FIFO_DEPTH      (CMD_FIFO_DEPTH      ),
    .AXIS_WIDTH      (AXIS_WIDTH          ),
    .AXIS_USER_WIDTH (UDP_RX_USR_WIDTH    ),
    .AXIS_ID_WIDTH   (1                   ),
    .AXIS_DEST_WIDTH (1                   ),
    .PACKET_FIFO     (0                   ),
    .FIFO_MEMORY_TYPE("auto"              ),
    .BRAM_DO_REG     (2                   ),
    .DEADLOCK_RISK   (1                   )
  ) u_cmd_fifo (
    .rst             (usr_rst             ),
    .clk             (clk_400m            ),
    // 上游 : net_stack_top 命令档 RX（只取 CMD_PORT_SEL 口）
    .axis_sdata      (udp_cmd_axis_mdata [CMD_PORT_SEL*AXIS_WIDTH +: AXIS_WIDTH]),
    .axis_skeep      (udp_cmd_axis_mkeep [CMD_PORT_SEL*(AXIS_WIDTH/8) +: (AXIS_WIDTH/8)]),
    .axis_svalid     (udp_cmd_axis_mvalid[CMD_PORT_SEL]),
    .axis_slast      (udp_cmd_axis_mlast [CMD_PORT_SEL]),
    .axis_sready     (cmd_fifo_sready     ),
    .axis_susr       (udp_cmd_axis_musr  [CMD_PORT_SEL*UDP_RX_USR_WIDTH +: UDP_RX_USR_WIDTH]),
    .axis_sstrb      ({AXIS_WIDTH/8{1'b0}}),
    .axis_sid        (1'b0                ),
    .axis_sdest      (1'b0                ),
    // 下游 : cfg_cmd_top
    .axis_mdata      (cmd_fifo_mdata      ),
    .axis_mkeep      (cmd_fifo_mkeep      ),
    .axis_mvalid     (cmd_fifo_mvalid     ),
    .axis_mlast      (cmd_fifo_mlast      ),
    .axis_mready     (cmd_in_ready        ),
    .axis_musr       (cmd_fifo_musr       ),
    .axis_mstrb      (                    ),
    .axis_mid        (                    ),
    .axis_mdest      (                    ),
    // 状态
    .prog_empty      (                    ),
    .prog_full       (                    ),
    .empty           (                    ),
    .full            (                    ),
    .remain_count    (                    )
  );

  // ============================================================================
  // 配置命令子系统 : 命令帧解析 + 配置寄存器堆 + 应答组帧
  // ============================================================================
  cfg_cmd_top #(
    .AXIS_WIDTH        (AXIS_WIDTH        ),
    .CMD_PORT_SEL      (CMD_PORT_SEL      ),
    .CMD_USR_WIDTH     (CMD_USR_WIDTH     ),
    .UDP_RX_USR_WIDTH  (UDP_RX_USR_WIDTH  ),
    .UDP_TX_USR_WIDTH  (UDP_TX_USR_WIDTH  ),
    .CMD_TTL           (CMD_TTL           ),
    .ETH_PORT_NUM      (ETH_PORT_NUM      ),
    .CFG_NUM_WIDTH     (CFG_NUM_WIDTH     ),
    // 上限
    .MAC_RX_TYPE_NUM_MAX       (MAC_RX_TYPE_NUM_MAX       ),
    .MAC_TX_TYPE_NUM_MAX       (MAC_TX_TYPE_NUM_MAX       ),
    .IPV4_RX_TYPE_NUM_MAX      (IPV4_RX_TYPE_NUM_MAX      ),
    .IPV4_TX_TYPE_NUM_MAX      (IPV4_TX_TYPE_NUM_MAX      ),
    .ICMP_TX_TYPE_NUM_MAX      (ICMP_TX_TYPE_NUM_MAX      ),
    .IPV6_RX_TYPE_NUM_MAX      (IPV6_RX_TYPE_NUM_MAX      ),
    .IPV6_TX_TYPE_NUM_MAX      (IPV6_TX_TYPE_NUM_MAX      ),
    .UDP_RX_PORT_NUM_MAX       (UDP_RX_PORT_NUM_MAX       ),
    .UDP_TX_PORT_NUM_MAX       (UDP_TX_PORT_NUM_MAX       ),
    .LOCAL_IPV4_MAC_NUM_MAX    (LOCAL_IPV4_MAC_NUM_MAX    ),
    .LOCAL_DST_IPV6_MAC_NUM_MAX(LOCAL_DST_IPV6_MAC_NUM_MAX),
    .LOCAL_SRC_IPV6_MAC_NUM_MAX(LOCAL_SRC_IPV6_MAC_NUM_MAX),
    // 逐口实际档数/套数
    .MAC_RX_TYPE_NUM_ARR       (MAC_RX_TYPE_NUM_ARR       ),
    .MAC_TX_TYPE_NUM_ARR       (MAC_TX_TYPE_NUM_ARR       ),
    .IPV4_RX_TYPE_NUM_ARR      (IPV4_RX_TYPE_NUM_ARR      ),
    .IPV4_TX_TYPE_NUM_ARR      (IPV4_TX_TYPE_NUM_ARR      ),
    .ICMP_TX_TYPE_NUM_ARR      (ICMP_TX_TYPE_NUM_ARR      ),
    .IPV6_RX_TYPE_NUM_ARR      (IPV6_RX_TYPE_NUM_ARR      ),
    .IPV6_TX_TYPE_NUM_ARR      (IPV6_TX_TYPE_NUM_ARR      ),
    .UDP_RX_PORT_NUM_ARR       (UDP_RX_PORT_NUM_ARR       ),
    .UDP_TX_PORT_NUM_ARR       (UDP_TX_PORT_NUM_ARR       ),
    .LOCAL_IPV4_MAC_NUM_ARR    (LOCAL_IPV4_MAC_NUM_ARR    ),
    .LOCAL_DST_IPV6_MAC_NUM_ARR(LOCAL_DST_IPV6_MAC_NUM_ARR),
    .LOCAL_SRC_IPV6_MAC_NUM_ARR(LOCAL_SRC_IPV6_MAC_NUM_ARR),
    // 分流表默认值
    .DEF_MAC_RX_TYPE_DICT_ARR  (MAC_RX_TYPE_DICT_ARR      ),
    .DEF_IPV4_RX_TYPE_DICT_ARR (IPV4_RX_TYPE_DICT_ARR     ),
    .DEF_IPV6_RX_TYPE_DICT_ARR (IPV6_RX_TYPE_DICT_ARR     ),
    .DEF_UDP_DST_PORT_RANGE_ARR(UDP_DST_PORT_RANGE_ARR    ),
    .DEF_PENDING_TIME          (CFG_PENDING_TIME_ARR      ),
    .DEF_ARP_PRIORITY          (CFG_ARP_PRIO_ARR          ),
    .DEF_ICMPV4_PRIORITY       (CFG_ICMP_PRIO_ARR         )
  ) u_cfg_cmd_top (
    .clk             (clk_400m            ),
    .rst             (usr_rst             ),
    // 命令输入（经 FIFO 隔离）
    .s_axis_cmd_data (cmd_fifo_mdata      ),
    .s_axis_cmd_keep (cmd_fifo_mkeep      ),
    .s_axis_cmd_last (cmd_fifo_mlast      ),
    .s_axis_cmd_valid(cmd_fifo_mvalid     ),
    .s_axis_cmd_ready(cmd_in_ready        ),
    .s_axis_cmd_usr  (cmd_fifo_musr       ),
    // 应答输出 -> 命令档 TX
    .m_axis_data     (cmd_rsp_data        ),
    .m_axis_keep     (cmd_rsp_keep        ),
    .m_axis_last     (cmd_rsp_last        ),
    .m_axis_valid    (cmd_rsp_valid       ),
    .m_axis_ready    (cmd_rsp_ready       ),
    .m_axis_udp_usr  (cmd_rsp_usr         ),
    // 生效配置 -> net_stack_top
    .cfg_local_mac       (cfg_local_mac        ),
    .cfg_local_ip        (cfg_local_ip         ),
    .cfg_gateway_ip      (cfg_gateway_ip       ),
    .cfg_subnet_mask     (cfg_subnet_mask      ),
    .cfg_src_ipv6        (cfg_src_ipv6         ),
    .cfg_src_mac         (cfg_src_mac          ),
    .cfg_dst_ipv6        (cfg_dst_ipv6         ),
    .cfg_dst_mac         (cfg_dst_mac          ),
    .cfg_eth_type        (cfg_eth_type         ),
    .cfg_ipv4_proto      (cfg_ipv4_proto       ),
    .cfg_ipv6_nh         (cfg_ipv6_nh          ),
    .cfg_udp_port        (cfg_udp_port         ),
    .cfg_pending_time    (cfg_pending_time     ),
    .cfg_arp_prio        (cfg_arp_prio         ),
    .cfg_icmp_prio       (cfg_icmp_prio        ),
    .cfg_cmd_udp_port    (cfg_cmd_udp_port     ),
    .cfg_arp_cache_clear (cfg_arp_cache_clear  ),
    .cfg_arp_pending_clear(cfg_arp_pending_clear),
    .cfg_stat_clear      (cfg_stat_clear       ),
    // 只读状态 <- net_stack_top
    .stat_link_status (stat_link_status    ),
    .stat_tx_idle     (stat_tx_idle        ),
    .stat_tx_active   (stat_tx_active_port ),
    .stat_is_df       (stat_is_df          ),
    .stat_arp         (stat_arp            ),
    .stat_icmp        (stat_icmp           )
  );

endmodule
`resetall
