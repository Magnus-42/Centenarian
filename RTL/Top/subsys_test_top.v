`resetall
`default_nettype none
`timescale 1ns / 1ps

// Language: Verilog 2001
// ============================================================================
// File Name   : subsys_test_top.v
// Module Name : subsys_test_top
// Author      : LiXintao
// Date        : 2026-10-13
// Version     : v4.2（新增 IPv6 通道测试：ICMPv6 + OSPFv3 各口一台测试机）
// ----------------------------------------------------------------------------
// Description : eth_subsys_top 板级实验顶层
// NOTE        :
//   1. DUT = eth_subsys_top(ETH_PORT_NUM=2)；A/B 两片 CMAC 经外部光缆对接。
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
  localparam ETH_PORT_NUM= 2 ;                             // 与 DUT 一致

  localparam AXIS_WIDTH= 512;
  localparam PRIORITY_WIDTH= 4 ;                             // usr 位宽, 与 DUT 一致
  localparam PKT_LEN_BEATS= 16;                             // 每包 16 拍 = 1024 字节
  localparam ONE_SEC_CYCLES= 32'd400_000_000;                // 1s @400MHz
  localparam CHK_PORT= 2 ;                             // UDP 校验第 2 路(区间[2,8])


  // ---- 本机配置（线序值：低字节 = 线上第一字节）----
  localparam [                  31:0]        CFG_A_IP= 32'h0901_A8C0;                // 192.168.1.9
  localparam [                  31:0]        CFG_B_IP= 32'h0801_A8C0;                // 192.168.1.8
  localparam [                  47:0]        CFG_A_MAC= 48'h010000311900;             // 00:19:31:00:00:01
  localparam [                  47:0]        CFG_B_MAC= 48'h020000311900;             // 00:19:31:00:00:02
  localparam [                  31:0]        CFG_GATEWAY= 32'h0101_A8C0;                // 192.168.1.1
  localparam [                  31:0]        CFG_SUBNET= 32'h00FF_FFFF;                // 255.255.255.0

  // ---- 逐口配置(与 DUT 同名参数：槽位打包 + MAX 定宽) ----
  localparam CFG_NUM_WIDTH= 8 ;
  localparam PENDING_TIME_WIDTH= 57;
  localparam [     CFG_NUM_WIDTH-1:0]        MAC_RX_TYPE_NUM_MAX= 2 ;        // A: 88B5/88CC           B: 88B5
  localparam [     CFG_NUM_WIDTH-1:0]        MAC_TX_TYPE_NUM_MAX= 3 ;        // A: 88B5/88DD           B: 88B5/0x88CC/0x88DD
  localparam [     CFG_NUM_WIDTH-1:0]        IPV4_RX_TYPE_NUM_MAX= 3 ;       // A: icmp/ospf/0x06      B：0x06/icmp/ospf
  localparam [     CFG_NUM_WIDTH-1:0]        IPV4_TX_TYPE_NUM_MAX= 4 ;       // A: icmp/ospf/0x06/0x2F B：0x06/icmp/ospf/0x2F
  localparam [     CFG_NUM_WIDTH-1:0]        IPV6_RX_TYPE_NUM_MAX= 3 ;       // A: udp/icmp/ospf       B: udp/ospf/icmp
  localparam [     CFG_NUM_WIDTH-1:0]        IPV6_TX_TYPE_NUM_MAX= 3 ;       // A: udp/icmp/ospf       B: udp/ospf/icmp
  localparam [     CFG_NUM_WIDTH-1:0]        UDP_RX_PORT_NUM_MAX= 3 ;        // A: [0,0] [1,1] [2,8]   B: [2,2] [4,8]
  localparam [     CFG_NUM_WIDTH-1:0]        UDP_TX_PORT_NUM_MAX= 8 ;        // A: 2/1234              B: 2/1234
  localparam [     CFG_NUM_WIDTH-1:0]        LOCAL_IPV4_MAC_NUM_MAX= 1 ;
  localparam [     CFG_NUM_WIDTH-1:0]        LOCAL_DST_IPV6_MAC_NUM_MAX= 2 ;
  localparam [     CFG_NUM_WIDTH-1:0]        LOCAL_SRC_IPV6_MAC_NUM_MAX= 2 ;
  localparam MAC_TX_N_MAX= (MAC_TX_TYPE_NUM_MAX > 0) ? MAC_TX_TYPE_NUM_MAX : 1;
  localparam IPV4_TX_N_MAX= (IPV4_TX_TYPE_NUM_MAX > 0) ? IPV4_TX_TYPE_NUM_MAX : 1;
  localparam IPV6_TX_TOT_MAX= (IPV6_TX_TYPE_NUM_MAX > 0) ? IPV6_TX_TYPE_NUM_MAX : 1;
  localparam UDP_TX_N_MAX= (UDP_TX_PORT_NUM_MAX > 0) ? UDP_TX_PORT_NUM_MAX : 1;
  //                                                                              [ 口B 槽位 , 口A 槽位 ]
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]MAC_RX_TYPE_NUM_ARR= { {CFG_NUM_WIDTH{1'b0}} | 4'd1  , {CFG_NUM_WIDTH{1'b0}} | 4'd2  };
  localparam [(MAC_RX_TYPE_NUM_MAX*16)*ETH_PORT_NUM-1:0]MAC_RX_TYPE_DICT_ARR= { {16'h0000,16'hB588} , {16'hCC88,16'hB588} }; // B:ch0=88B5 ; A:ch0=88B5,ch1=88CC
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]MAC_TX_TYPE_NUM_ARR= { {CFG_NUM_WIDTH{1'b0}} | 4'd3  , {CFG_NUM_WIDTH{1'b0}} | 4'd2  };
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV4_RX_TYPE_NUM_ARR= { {CFG_NUM_WIDTH{1'b0}} | 4'd3 , {CFG_NUM_WIDTH{1'b0}} | 4'd3  };
  localparam [(IPV4_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0]IPV4_RX_TYPE_DICT_ARR= { {8'h59,8'h01,8'h06} , {8'h06,8'h59,8'h01} }; // B:ch0=06,ch1=01,ch2=59 ; A:ch0=01,ch1=59,ch2=06
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV4_TX_TYPE_NUM_ARR= { {CFG_NUM_WIDTH{1'b0}} | 4'd4 , {CFG_NUM_WIDTH{1'b0}} | 4'd4  };
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV6_RX_TYPE_NUM_ARR= { {CFG_NUM_WIDTH{1'b0}} | 4'd3 , {CFG_NUM_WIDTH{1'b0}} | 4'd3  };
  localparam [(IPV6_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0]IPV6_RX_TYPE_DICT_ARR= { {8'h3A,8'h59,8'h11} , {8'h59,8'h3A,8'h11} }; // B:ch0=11,ch1=59,ch2=3A ; A:ch0=11,ch1=3A,ch2=59
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]IPV6_TX_TYPE_NUM_ARR= { {CFG_NUM_WIDTH{1'b0}} | 4'd3 , {CFG_NUM_WIDTH{1'b0}} | 4'd3  };
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]UDP_RX_PORT_NUM_ARR= { {CFG_NUM_WIDTH{1'b0}} | 4'd2  , {CFG_NUM_WIDTH{1'b0}} | 4'd3  };
  localparam [(UDP_RX_PORT_NUM_MAX*32)*ETH_PORT_NUM-1:0]UDP_DST_PORT_RANGE_ARR= { {32'd0,32'h00080004,32'h00020002} , {32'h00080002,32'h00010001,32'h00000000} };
  //     口B: ch0=[2,2] ch1=[4,8]        ; 口A: ch0=[0,0] ch1=[1,1] ch2=[2,8]
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]UDP_TX_PORT_NUM_ARR= { {CFG_NUM_WIDTH{1'b0}} | 4'd4  , {CFG_NUM_WIDTH{1'b0}} | 4'd8  };
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_IPV4_MAC_NUM_ARR= { {CFG_NUM_WIDTH{1'b0}} | 4'd1 , {CFG_NUM_WIDTH{1'b0}} | 4'd1 };
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_DST_IPV6_MAC_NUM_ARR= { {CFG_NUM_WIDTH{1'b0}} | 4'd2 , {CFG_NUM_WIDTH{1'b0}} | 4'd2 };
  localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0]LOCAL_SRC_IPV6_MAC_NUM_ARR= { {CFG_NUM_WIDTH{1'b0}} | 4'd2 , {CFG_NUM_WIDTH{1'b0}} | 4'd2 };
  localparam [PENDING_TIME_WIDTH-1:0] CFG_PENDING_TIME_A= 57'd400_000_000; // 1.0s @400MHz
  localparam [PENDING_TIME_WIDTH-1:0] CFG_PENDING_TIME_B= 57'd200_000_000; // 0.5s @400MHz
  localparam [(PENDING_TIME_WIDTH)*ETH_PORT_NUM-1:0]CFG_PENDING_TIME_ARR= { CFG_PENDING_TIME_B, CFG_PENDING_TIME_A };

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
  localparam IDX_IP4_RX_A_ICMP= 0*(IPV4_RX_TYPE_NUM_MAX+1)+0;  // 口A ch0 = 0x01
  localparam IDX_IP4_RX_A_OSPF= 0*(IPV4_RX_TYPE_NUM_MAX+1)+1;  // 口A ch1 = 0x59
  localparam IDX_IP4_RX_A_06  = 0*(IPV4_RX_TYPE_NUM_MAX+1)+2;  // 口A ch2 = 0x06
  localparam IDX_IP4_RX_A_FB  = 0*(IPV4_RX_TYPE_NUM_MAX+1)+3;  // 口A 兜底
  localparam IDX_IP4_RX_B_06  = 1*(IPV4_RX_TYPE_NUM_MAX+1)+0;  // 口B ch0 = 0x06
  localparam IDX_IP4_RX_B_ICMP= 1*(IPV4_RX_TYPE_NUM_MAX+1)+1;  // 口B ch1 = 0x01
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
  localparam [                 127:0]        CFG_A_IPV6= {8'h01, {11{8'h00}}, 8'hb8, 8'h0d, 8'h01, 8'h20};
  localparam [                 127:0]        CFG_B_IPV6= {8'h02, {11{8'h00}}, 8'hb8, 8'h0d, 8'h01, 8'h20};

  // ---- UDP cfg ----
  localparam [                  15:0]        UDP_LEN= PKT_LEN_BEATS*64;                     // UDP 报文长度
  localparam [                  15:0]        IP_LEN_UDP= UDP_LEN + 16'd20;                     // UDP 通道 IP 总长(tester 发 UDP 报文, IP 头由 udp_top 补)
  localparam [                  15:0]        IP_LEN_FULL= PKT_LEN_BEATS*64;                     // 其余通道 IP 总长(tester 直接发完整 IP 包)
  localparam [                  15:0]        IP_LEN_UDP_LE= {IP_LEN_UDP[7:0],  IP_LEN_UDP[15:8]};  // 值直通: 低字节先
  localparam [                  15:0]        IP_LEN_FULL_LE= {IP_LEN_FULL[7:0], IP_LEN_FULL[15:8]};
  localparam [                  15:0]        UDP_LEN_LE= {UDP_LEN[7:0], UDP_LEN[15:8]};

  // ---- TX 优先级(user[3:0])常量 : 0=禁用 / 1~15 有效 ----
  //   ARP 优先级在 eth_subsys_top 内部固定 4'd15, 不在此处配置
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
  // UDP 头 8B: src_port(2) dst_port(2) len(2) cks(2)   -> dst_port 决定落哪一档
  localparam [                 159:0]        HDR_UDP_A    = {96'd0, 16'h0000, UDP_LEN_LE, CHK_PORT[15:0], 16'h0000}; // 端口2 -> 口B ch0[2,2]
  localparam [                 159:0]        HDR_UDP_B    = {96'd0, 16'h0000, UDP_LEN_LE, CHK_PORT[15:0], 16'h0000}; // 端口2 -> 口A ch2[2,8]
  localparam [                 159:0]        HDR_UDP_FB_A = {96'd0, 16'h0000, UDP_LEN_LE, 16'h1234, 16'h0000}; // 0x1234 两口区间都不含 -> 兜底档
  localparam [                 159:0]        HDR_UDP_FB_B = {96'd0, 16'h0000, UDP_LEN_LE, 16'h1234, 16'h0000};

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

  clk_100_to_200m u_clk_100_to_400m (
    .clk_200m         (clk_400m         ),
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
  // DUT : eth_subsys_top（2 口，全通道引出）
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
  wire                 [193*(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_musr    ;
  wire                 [(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]udp_axis_mready  ;
  wire                 [512*(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mdata   ;
  wire                 [64*(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mkeep   ;
  wire                 [(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mlast   , mac_axis_mready;
  wire                 [(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]mac_axis_mvalid  ;
  wire                 [512*MAC_TX_N_MAX*ETH_PORT_NUM-1:0]mac_axis_sdata   ;
  wire                 [64*MAC_TX_N_MAX*ETH_PORT_NUM-1:0]mac_axis_skeep   ;
  wire                 [MAC_TX_N_MAX*ETH_PORT_NUM-1:0] mac_axis_slast   , mac_axis_svalid, mac_axis_sready;
  wire                 [PRIORITY_WIDTH*MAC_TX_N_MAX*ETH_PORT_NUM-1:0]mac_axis_susr    ;
  wire                 [512*(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_mdata  ;
  wire                 [64*(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_mkeep  ;
  wire                 [97*(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_musr   ;
  wire                 [(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv4_axis_mlast  , ipv4_axis_mvalid, ipv4_axis_mready;
  wire                 [512*IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_sdata  ;
  wire                 [64*IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_skeep  ;
  wire                 [IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_slast  , ipv4_axis_svalid, ipv4_axis_sready;
  wire                 [PRIORITY_WIDTH*IPV4_TX_N_MAX*ETH_PORT_NUM-1:0]ipv4_axis_susr   ;
  wire                 [512*UDP_TX_N_MAX*ETH_PORT_NUM-1:0]udp_axis_sdata   ;
  wire                 [64*UDP_TX_N_MAX*ETH_PORT_NUM-1:0]udp_axis_skeep   ;
  wire                 [UDP_TX_N_MAX*ETH_PORT_NUM-1:0] udp_axis_slast   , udp_axis_svalid, udp_axis_sready;
  wire                 [PRIORITY_WIDTH*UDP_TX_N_MAX*ETH_PORT_NUM-1:0]udp_axis_susr    ;
  // ---- IPv6 flat 通道 ----
  wire                 [512*(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_mdata  ;
  wire                 [64*(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_mkeep  ;
  wire                 [97*(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_musr   ;
  wire                 [(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]ipv6_axis_mlast  , ipv6_axis_mvalid, ipv6_axis_mready;
  wire                 [512*IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_sdata  ;
  wire                 [64*IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_skeep  ;
  wire                 [IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_slast  , ipv6_axis_svalid, ipv6_axis_sready;
  wire                 [PRIORITY_WIDTH*IPV6_TX_TOT_MAX*ETH_PORT_NUM-1:0]ipv6_axis_susr   ;
  // ============================================================================
  // DUT : eth_subsys_top（2 口，全通道引出）
  // ============================================================================

  eth_subsys_top #(
    .ETH_PORT_NUM     (ETH_PORT_NUM     ),
    .CFG_NUM_WIDTH    (CFG_NUM_WIDTH    ),
    .MAC_RX_TYPE_NUM_ARR(MAC_RX_TYPE_NUM_ARR),
    .MAC_RX_TYPE_DICT_ARR(MAC_RX_TYPE_DICT_ARR),
    .MAC_TX_TYPE_NUM_ARR(MAC_TX_TYPE_NUM_ARR),
    .IPV4_RX_TYPE_NUM_ARR(IPV4_RX_TYPE_NUM_ARR),
    .IPV4_RX_TYPE_DICT_ARR(IPV4_RX_TYPE_DICT_ARR),
    .IPV4_TX_TYPE_NUM_ARR(IPV4_TX_TYPE_NUM_ARR),
    .IPV6_RX_TYPE_NUM_ARR(IPV6_RX_TYPE_NUM_ARR),
    .IPV6_RX_TYPE_DICT_ARR(IPV6_RX_TYPE_DICT_ARR),
    .IPV6_TX_TYPE_NUM_ARR(IPV6_TX_TYPE_NUM_ARR),
    .UDP_RX_PORT_NUM_ARR(UDP_RX_PORT_NUM_ARR),
    .UDP_DST_PORT_RANGE_ARR(UDP_DST_PORT_RANGE_ARR),
    .UDP_TX_PORT_NUM_ARR(UDP_TX_PORT_NUM_ARR),
    .LOCAL_IPV4_MAC_NUM_ARR(LOCAL_IPV4_MAC_NUM_ARR),
    .LOCAL_DST_IPV6_MAC_NUM_ARR(LOCAL_DST_IPV6_MAC_NUM_ARR),
    .LOCAL_SRC_IPV6_MAC_NUM_ARR(LOCAL_SRC_IPV6_MAC_NUM_ARR),
    .MAC_RX_TYPE_NUM_MAX(MAC_RX_TYPE_NUM_MAX),
    .MAC_TX_TYPE_NUM_MAX(MAC_TX_TYPE_NUM_MAX),
    .IPV4_RX_TYPE_NUM_MAX(IPV4_RX_TYPE_NUM_MAX),
    .IPV4_TX_TYPE_NUM_MAX(IPV4_TX_TYPE_NUM_MAX),
    .IPV6_RX_TYPE_NUM_MAX(IPV6_RX_TYPE_NUM_MAX),
    .IPV6_TX_TYPE_NUM_MAX(IPV6_TX_TYPE_NUM_MAX),
    .UDP_RX_PORT_NUM_MAX(UDP_RX_PORT_NUM_MAX),
    .UDP_TX_PORT_NUM_MAX(UDP_TX_PORT_NUM_MAX),
    .LOCAL_IPV4_MAC_NUM_MAX(LOCAL_IPV4_MAC_NUM_MAX),
    .LOCAL_DST_IPV6_MAC_NUM_MAX(LOCAL_DST_IPV6_MAC_NUM_MAX),
    .LOCAL_SRC_IPV6_MAC_NUM_MAX(LOCAL_SRC_IPV6_MAC_NUM_MAX),
    .PRIORITY_WIDTH   (PRIORITY_WIDTH   ),
    .PENDING_TIME_WIDTH(57               ),
    .CFG_PENDING_TIME_ARR({ETH_PORT_NUM{57'd400_000_000}}) 
  ) u_dut (
    .sys_clk          (sys_clk          ),
    .clk              (clk_400m         ),
    .clk_locked       (clk_locked       ),
    .qsfp_gt_rst      (qsfp_gt_rst      ),
    .usr_rst          (usr_rst          ),
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
    .ipv4_axis_sdata  (ipv4_axis_sdata  ),
    .ipv4_axis_skeep  (ipv4_axis_skeep  ),
    .ipv4_axis_slast  (ipv4_axis_slast  ),
    .ipv4_axis_svalid (ipv4_axis_svalid ),
    .ipv4_axis_susr   (ipv4_axis_susr   ),
    .ipv4_axis_sready (ipv4_axis_sready ),
    // IPv6 IP->MAC 映射表（dest=对端表 / src=本机表; 每口项0 有效, 项1 空）
    //   A 口: dest={0,B} src={0,A};  B 口: dest={0,A} src={0,B}
    .cfg_dest_match_ipv6({ {128'd0,CFG_A_IPV6}, {128'd0,CFG_B_IPV6} }),
    .cfg_dest_match_mac({ { 48'd0,CFG_A_MAC }, { 48'd0,CFG_B_MAC } }),
    .cfg_src_match_ipv6({ {128'd0,CFG_B_IPV6}, {128'd0,CFG_A_IPV6} }),
    .cfg_src_match_mac({ { 48'd0,CFG_B_MAC }, { 48'd0,CFG_A_MAC } }),
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
    .cfg_total_len    ({IP_LEN_UDP_LE, IP_LEN_UDP_LE}),
    .cfg_ttl          ({8'h40, 8'h40}   ),
    .cfg_head_checksum({16'h0000, 16'h0000}),
    .cfg_src_ip       ({CFG_B_IP, CFG_A_IP}),
    .cfg_dest_ip      ({CFG_A_IP, CFG_B_IP}),
    // 状态
    .stat_is_df       (                 ),
    .stat_tx_active_port(                 ),
    .stat_tx_idle     (                 ),
    .stat_arp_rx_error(                 ),
    .stat_arp_ack_ovf (                 ),
    .stat_arp_pend_ovf(                 ),
    .stat_arp_no_resp (                 ),
    .stat_arp_pend_clr(                 ),
    .stat_arp_cache_clr(                 ),
    .stat_arp_src_not_local(                 ),
    .stat_ipv6_drop_pulse(                 ) 
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
    .HDR_BYTES        (HDR_UDP_A)
  ) u_ta_udp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_udp),
    .axis_mdata       (udp_axis_sdata[(IDX_UDP_TX_A_DATA)*512 +: 512]), .axis_mkeep(udp_axis_skeep[(IDX_UDP_TX_A_DATA)*64 +: 64]),
    .axis_mvalid      (udp_axis_svalid[IDX_UDP_TX_A_DATA]), .axis_mlast(udp_axis_slast[IDX_UDP_TX_A_DATA]),
    .axis_mready      (udp_axis_sready[IDX_UDP_TX_A_DATA]),
    .axis_sdata       (udp_axis_mdata[(IDX_UDP_RX_B_P2)*512 +: 512]), .axis_skeep(udp_axis_mkeep[(IDX_UDP_RX_B_P2)*64 +: 64]),
    .axis_svalid      (udp_axis_mvalid[IDX_UDP_RX_B_P2]), .axis_slast(udp_axis_mlast[IDX_UDP_RX_B_P2]),
    .axis_sready      (udp_axis_mready[IDX_UDP_RX_B_P2]) 
  );

  // A 口 IPv4-icmp -> 口B ch1(0x01)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP_ICMP_A)
  ) u_ta_icmp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_a_icmp),
    .axis_mdata       (ipv4_axis_sdata[(IDX_IP4_TX_A_ICMP)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(IDX_IP4_TX_A_ICMP)*64 +: 64]),
    .axis_mvalid      (ipv4_axis_svalid[IDX_IP4_TX_A_ICMP]), .axis_mlast(ipv4_axis_slast[IDX_IP4_TX_A_ICMP]),
    .axis_mready      (ipv4_axis_sready[IDX_IP4_TX_A_ICMP]),
    .axis_sdata       (ipv4_axis_mdata[(IDX_IP4_RX_B_ICMP)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(IDX_IP4_RX_B_ICMP)*64 +: 64]),
    .axis_svalid      (ipv4_axis_mvalid[IDX_IP4_RX_B_ICMP]), .axis_slast(ipv4_axis_mlast[IDX_IP4_RX_B_ICMP]),
    .axis_sready      (ipv4_axis_mready[IDX_IP4_RX_B_ICMP]) 
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
    .HDR_BYTES        (HDR_UDP_FB_A)
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
    .HDR_BYTES        (HDR_UDP_B)
  ) u_tb_udp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_udp),
    .axis_mdata       (udp_axis_sdata[(IDX_UDP_TX_B_DATA)*512 +: 512]), .axis_mkeep(udp_axis_skeep[(IDX_UDP_TX_B_DATA)*64 +: 64]),
    .axis_mvalid      (udp_axis_svalid[IDX_UDP_TX_B_DATA]), .axis_mlast(udp_axis_slast[IDX_UDP_TX_B_DATA]),
    .axis_mready      (udp_axis_sready[IDX_UDP_TX_B_DATA]),
    .axis_sdata       (udp_axis_mdata[(IDX_UDP_RX_A_P2)*512 +: 512]), .axis_skeep(udp_axis_mkeep[(IDX_UDP_RX_A_P2)*64 +: 64]),
    .axis_svalid      (udp_axis_mvalid[IDX_UDP_RX_A_P2]), .axis_slast(udp_axis_mlast[IDX_UDP_RX_A_P2]),
    .axis_sready      (udp_axis_mready[IDX_UDP_RX_A_P2]) 
  );

  // B 口 IPv4-icmp -> 口A ch0(0x01)
  subsys_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES        (HDR_IP_ICMP_B)
  ) u_tb_icmp (
    .clk              (clk_400m), .rst(usr_rst), .test_enable(en_b_icmp),
    .axis_mdata       (ipv4_axis_sdata[(IDX_IP4_TX_B_ICMP)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(IDX_IP4_TX_B_ICMP)*64 +: 64]),
    .axis_mvalid      (ipv4_axis_svalid[IDX_IP4_TX_B_ICMP]), .axis_mlast(ipv4_axis_slast[IDX_IP4_TX_B_ICMP]),
    .axis_mready      (ipv4_axis_sready[IDX_IP4_TX_B_ICMP]),
    .axis_sdata       (ipv4_axis_mdata[(IDX_IP4_RX_A_ICMP)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(IDX_IP4_RX_A_ICMP)*64 +: 64]),
    .axis_svalid      (ipv4_axis_mvalid[IDX_IP4_RX_A_ICMP]), .axis_slast(ipv4_axis_mlast[IDX_IP4_RX_A_ICMP]),
    .axis_sready      (ipv4_axis_mready[IDX_IP4_RX_A_ICMP]) 
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
    .HDR_BYTES        (HDR_UDP_FB_B)
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
                              {PRIORITY_WIDTH{1'b0}}, PRIO_FB, PRIO_MAC88B5_A }; // 口A: 填充/兜底探测/88B5
  assign  ipv4_axis_susr  = { PRIO_FB, PRIO_IP06_B,  PRIO_OSPF_B, PRIO_ICMP_B,    // 口B: 2F/06/ospf/icmp
                              PRIO_FB, PRIO_IP06_A,  PRIO_OSPF_A, PRIO_ICMP_A };  // 口A: 2F/06/ospf/icmp
  assign  ipv6_axis_susr  = { PRIO_FB, PRIO_OSPFV3_B, PRIO_ICMPV6_B,     // 口B: 兜底探测/ospfv3/icmpv6
                              PRIO_FB, PRIO_OSPFV3_A, PRIO_ICMPV6_A };   // 口A: 兜底探测/ospfv3/icmpv6
  assign  udp_axis_susr   = { {PRIORITY_WIDTH{1'b0}},{(PRIORITY_WIDTH*5){1'b0}}, PRIO_FB, PRIO_UDP_B,
                              {PRIORITY_WIDTH{1'b0}},{(PRIORITY_WIDTH*5){1'b0}}, PRIO_FB, PRIO_UDP_A };

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

endmodule
`resetall
