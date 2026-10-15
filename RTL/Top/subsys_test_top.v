`resetall
`default_nettype none
`timescale 1ns / 1ps

// Language: Verilog 2001
// ============================================================================
// File Name   : subsys_test_top.v
// Module Name : subsys_test_top
// Author      : LiXintao
// Date        : 2026-10-13
// Version     : v4.1（适配 eth_subsys_top v5.0：参数/字典语义/位宽/usr 全量对齐）
// ----------------------------------------------------------------------------
// Description : eth_subsys_top 板级实验顶层（全通道覆盖测试）
// NOTE        :
//   1. DUT = eth_subsys_top(ETH_PORT_NUM=2)；A/B 两片 CMAC 经外部光缆对接。
//   2. 本层负责"通道配置"：各层 RX/TX 的 TYPE_NUM/TYPE_DICT 在此定义并透传给 DUT。
//      RX_TYPE_NUM = 用户自定义档数(>=0, 不含内部档/兜底); TX_TYPE_NUM = 用户自定义口数(>=0)。
//      内部档由代码直连: MAC 层 {arp,ipv4,ipv6} + other 兜底; IPv4 层 {udp} + other 兜底。
//      DICT 仅填用户项(禁含内部类型: MAC 禁 0806/0800/86DD; IPv4 禁 0x11), 其余通道同规则。
//      书写序{左..右}, 最右=ch0。默认配置（ch/口 索引从低位起, A/B 两口一致）:
//        MAC : RX: [0]=0x88B5 [1]=other               TX: [0]=0x88B5
//        IPv4: RX: [0]=icmp [1]=ospf [2]=0x06 [3]=other
//              TX: [0]=icmp [1]=ospf [2]=0x06
//        IPv6: RX: [0]=udp  [1]=icmpv6 [2]=ospf [3]=other
//              TX: [0]=udp  [1]=icmpv6 [2]=ospf（暂 tie-off, 未接测试机）
//        UDP : RX: [0..2]=端口区间档 [3]=other        TX: 8 路用户口, 本期仅用第 [0] 路
//   3. 每口 5 个 subsys_100g_tester，覆盖对外通道：
//      MAC-other / IPv4-icmp / IPv4-ospf / IPv4-other / UDP（发用第 0 路, 收校验第 CHK_PORT 路）。
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
  localparam ETH_PORT_NUM     = 2 ;                             // 与 DUT 一致
  localparam UDP_RX_PORT_NUM  = 3 ;                             // 用户 UDP 收端口数(不含兜底)
  localparam UDP_TX_PORT_NUM  = 8 ;                             // 用户 UDP 发端口数
  localparam UDP_TX_N         = (UDP_TX_PORT_NUM > 0) ? UDP_TX_PORT_NUM : 1; // 与 DUT 相同占位规则
  localparam [UDP_RX_PORT_NUM*32-1:0] UDP_DST_PORT_RANGE = {32'h00080002, 32'h00010001, 32'h00000000};
  localparam AXIS_WIDTH       = 512;
  localparam PRIORITY_WIDTH   = 4 ;                             // usr 位宽, 与 DUT 一致
  localparam PKT_LEN_BEATS    = 16;                             // 每包 16 拍 = 1024 字节
  localparam ONE_SEC_CYCLES   = 32'd400_000_000;                // 1s @400MHz
  localparam CHK_PORT         = 2 ;                             // UDP 校验第 2 路(区间[2,8])


  // ---- 本机配置（线序值：低字节 = 线上第一字节）----
  localparam [31:0] CFG_A_IP    = 32'h0901_A8C0;                // 192.168.1.9
  localparam [31:0] CFG_B_IP    = 32'h0801_A8C0;                // 192.168.1.8
  localparam [47:0] CFG_A_MAC   = 48'h010000311900;             // 00:19:31:00:00:01
  localparam [47:0] CFG_B_MAC   = 48'h020000311900;             // 00:19:31:00:00:02
  localparam [31:0] CFG_GATEWAY = 32'h0101_A8C0;                // 192.168.1.1
  localparam [31:0] CFG_SUBNET  = 32'h00FF_FFFF;                // 255.255.255.0

  // ---- IPv6 配置（线序值：低字节 = 线上第一字节）----
  localparam LOCAL_DST_IPV6_MAC_NUM = 2;    // 每口 dest(对端)表项数
  localparam LOCAL_SRC_IPV6_MAC_NUM = 2;    // 每口 src(本机)表项数
  localparam LOCAL_IPV4_MAC_NUM     = 1;    // 每口 ARP 本机 IP/MAC 套数

  // ---- 各层通道字典配置（全链透传给 DUT; 仅用户项 —— 内部档 {arp,ipv4,ipv6}/{udp} 由代码直连）----
  localparam MAC_RX_TYPE_NUM  = 1;   // 用户侧档数: ch0=0x88B5
  localparam MAC_TX_TYPE_NUM  = 1;   // 用户发送口数: 口0=0x88B5
  localparam MAC_TX_N         = (MAC_TX_TYPE_NUM > 0) ? MAC_TX_TYPE_NUM : 1;  // 与 DUT 相同占位规则
  localparam [MAC_RX_TYPE_NUM*16-1:0] MAC_RX_TYPE_DICT = {16'hB588};                       // 88B5
  localparam IPV4_RX_TYPE_NUM = 3;   // 用户侧档数: ch0=icmp ch1=ospf ch2=0x06
  localparam IPV4_TX_TYPE_NUM = 3;   // 用户发送口数: 口0=icmp 口1=ospf 口2=0x06
  localparam IPV4_TX_N        = (IPV4_TX_TYPE_NUM > 0) ? IPV4_TX_TYPE_NUM : 1;  // 与 DUT 相同占位规则
  localparam [IPV4_RX_TYPE_NUM*8-1:0] IPV4_RX_TYPE_DICT = {8'h06, 8'h59, 8'h01};           // 06/ospf/icmp
  localparam IPV6_RX_TYPE_NUM = 3;   // 用户侧档数: ch0=udp ch1=icmpv6 ch2=ospf
  localparam IPV6_TX_TYPE_NUM = 3;   // 用户发送口数: 口0=udp 口1=icmpv6 口2=ospf
  localparam IPV6_TX_TOT      = (IPV6_TX_TYPE_NUM > 0) ? IPV6_TX_TYPE_NUM : 1;  // 与 DUT 相同占位规则
  localparam [IPV6_RX_TYPE_NUM*8-1:0] IPV6_RX_TYPE_DICT = {8'h59, 8'h3A, 8'h11};           // ospf/icmpv6/udp
  // 2001:db8::1 / 2001:db8::2（占位地址，测试机接入时可改）
  localparam [127:0] CFG_A_IPV6 = {8'h01, {11{8'h00}}, 8'hb8, 8'h0d, 8'h01, 8'h20};
  localparam [127:0] CFG_B_IPV6 = {8'h02, {11{8'h00}}, 8'hb8, 8'h0d, 8'h01, 8'h20};

  // ---- UDP cfg ----
  localparam [15:0] UDP_LEN       = PKT_LEN_BEATS*64;                     // UDP 报文长度
  localparam [15:0] IP_LEN_UDP    = UDP_LEN + 16'd20;                     // UDP 通道 IP 总长(tester 发 UDP 报文, IP 头由 udp_top 补)
  localparam [15:0] IP_LEN_FULL   = PKT_LEN_BEATS*64;                     // 其余通道 IP 总长(tester 直接发完整 IP 包)
  localparam [15:0] IP_LEN_UDP_LE = {IP_LEN_UDP[7:0],  IP_LEN_UDP[15:8]};  // 值直通: 低字节先
  localparam [15:0] IP_LEN_FULL_LE= {IP_LEN_FULL[7:0], IP_LEN_FULL[15:8]};
  localparam [15:0] UDP_LEN_LE    = {UDP_LEN[7:0], UDP_LEN[15:8]};

  // ---- TX 优先级(user[3:0])常量 : 0=禁用 / 1~15 有效 (可按需改为 VIO 动态控制) ----
  //   ARP 优先级在 eth_subsys_top 内部固定 4'd15, 不在此处配置
  localparam [3:0] PRIO_UDP     = 4'd8 ;  // UDP(v4)
  localparam [3:0] PRIO_ICMP    = 4'd12;  // ICMPv4
  localparam [3:0] PRIO_OSPF    = 4'd13;  // OSPF(v4)
  localparam [3:0] PRIO_IPOTHER = 4'd7 ;  // 0x06 数据口(v4)
  localparam [3:0] PRIO_UDP6    = 4'd8 ;  // UDP(v6)
  localparam [3:0] PRIO_ICMPV6  = 4'd14;  // ICMPv6(NDP)
  localparam [3:0] PRIO_OSPFV3  = 4'd13;  // OSPFv3
  localparam [3:0] PRIO_MACOTH  = 4'd6 ;  // MAC 对外试验流(0x88B5)

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
  localparam [159:0] HDR_UDP_A    = {96'd0, 16'h0000, UDP_LEN_LE, CHK_PORT[15:0], 16'h0000};
  localparam [159:0] HDR_UDP_B    = {96'd0, 16'h0000, UDP_LEN_LE, CHK_PORT[15:0], 16'h0000};

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

  wire [512*(UDP_RX_PORT_NUM+1)*ETH_PORT_NUM-1:0]  udp_axis_mdata  ;  // DUT 输出(全口全路)
  wire [ 64*(UDP_RX_PORT_NUM+1)*ETH_PORT_NUM-1:0]  udp_axis_mkeep  ;
  wire [ (UDP_RX_PORT_NUM+1)*ETH_PORT_NUM-1:0]     udp_axis_mlast  ;
  wire [ (UDP_RX_PORT_NUM+1)*ETH_PORT_NUM-1:0]     udp_axis_mvalid ;
  wire [193*(UDP_RX_PORT_NUM+1)*ETH_PORT_NUM-1:0]  udp_axis_musr   ;
  wire [ (UDP_RX_PORT_NUM+1)*ETH_PORT_NUM-1:0]     udp_axis_mready ;

  wire [512*(MAC_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]  mac_axis_mdata  ;
  wire [ 64*(MAC_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]  mac_axis_mkeep  ;
  wire [ (MAC_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]     mac_axis_mlast , mac_axis_mready;
  wire [ (MAC_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]     mac_axis_mvalid;
  wire [512*MAC_TX_N*ETH_PORT_NUM-1:0]  mac_axis_sdata  ;
  wire [ 64*MAC_TX_N*ETH_PORT_NUM-1:0]  mac_axis_skeep  ;
  wire [ MAC_TX_N*ETH_PORT_NUM-1:0]     mac_axis_slast , mac_axis_svalid, mac_axis_sready;
  wire [ PRIORITY_WIDTH*MAC_TX_N*ETH_PORT_NUM-1:0]  mac_axis_susr ;

  wire [512*(IPV4_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]  ipv4_axis_mdata  ;
  wire [ 64*(IPV4_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]  ipv4_axis_mkeep  ;
  wire [ 97*(IPV4_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]  ipv4_axis_musr   ;
  wire [ (IPV4_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]     ipv4_axis_mlast , ipv4_axis_mvalid, ipv4_axis_mready;
  wire [512*IPV4_TX_N*ETH_PORT_NUM-1:0]  ipv4_axis_sdata  ;
  wire [ 64*IPV4_TX_N*ETH_PORT_NUM-1:0]  ipv4_axis_skeep  ;
  wire [ IPV4_TX_N*ETH_PORT_NUM-1:0]     ipv4_axis_slast , ipv4_axis_svalid, ipv4_axis_sready;
  wire [ PRIORITY_WIDTH*IPV4_TX_N*ETH_PORT_NUM-1:0]  ipv4_axis_susr;
  wire [512*UDP_TX_N*ETH_PORT_NUM-1:0]  udp_axis_sdata  ;
  wire [ 64*UDP_TX_N*ETH_PORT_NUM-1:0]  udp_axis_skeep  ;
  wire [ UDP_TX_N*ETH_PORT_NUM-1:0]     udp_axis_slast  , udp_axis_svalid, udp_axis_sready;
  wire [ PRIORITY_WIDTH*UDP_TX_N*ETH_PORT_NUM-1:0]  udp_axis_susr ;

  // ---- IPv6 flat 通道（待接 IPv6 测试机；当前接收 mready 恒 1、发送 svalid 恒 0）----
  wire [512*(IPV6_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]  ipv6_axis_mdata  ;
  wire [ 64*(IPV6_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]  ipv6_axis_mkeep  ;
  wire [ 97*(IPV6_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]  ipv6_axis_musr   ;
  wire [ (IPV6_RX_TYPE_NUM+1)*ETH_PORT_NUM-1:0]     ipv6_axis_mlast  , ipv6_axis_mvalid, ipv6_axis_mready;
  wire [512*IPV6_TX_TOT*ETH_PORT_NUM-1:0]  ipv6_axis_sdata  ;
  wire [ 64*IPV6_TX_TOT*ETH_PORT_NUM-1:0]  ipv6_axis_skeep  ;
  wire [ IPV6_TX_TOT*ETH_PORT_NUM-1:0]     ipv6_axis_slast  , ipv6_axis_svalid, ipv6_axis_sready;
  wire [ PRIORITY_WIDTH*IPV6_TX_TOT*ETH_PORT_NUM-1:0]  ipv6_axis_susr  ;

  eth_subsys_top #(
    .ETH_PORT_NUM     (ETH_PORT_NUM     ),
    .LOCAL_IPV4_MAC_NUM(LOCAL_IPV4_MAC_NUM),
    .LOCAL_DST_IPV6_MAC_NUM(LOCAL_DST_IPV6_MAC_NUM),
    .LOCAL_SRC_IPV6_MAC_NUM(LOCAL_SRC_IPV6_MAC_NUM),
    .UDP_RX_PORT_NUM  (UDP_RX_PORT_NUM  ),
    .UDP_DST_PORT_RANGE(UDP_DST_PORT_RANGE),
    .UDP_TX_PORT_NUM  (UDP_TX_PORT_NUM  ),
    .PRIORITY_WIDTH   (PRIORITY_WIDTH   ),
    .MAC_RX_TYPE_NUM  (MAC_RX_TYPE_NUM  ),
    .MAC_RX_TYPE_DICT (MAC_RX_TYPE_DICT ),
    .MAC_TX_TYPE_NUM  (MAC_TX_TYPE_NUM  ),
    .IPV4_RX_TYPE_NUM (IPV4_RX_TYPE_NUM ),
    .IPV4_RX_TYPE_DICT(IPV4_RX_TYPE_DICT),
    .IPV4_TX_TYPE_NUM (IPV4_TX_TYPE_NUM ),
    .IPV6_RX_TYPE_NUM (IPV6_RX_TYPE_NUM ),
    .IPV6_RX_TYPE_DICT(IPV6_RX_TYPE_DICT),
    .IPV6_TX_TYPE_NUM (IPV6_TX_TYPE_NUM ),
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
    // MAC flat 通道（RX 对外段: idx0=0x88B5, idx1=兜底; TX 对外段: idx0=0x88B5）
    .mac_axis_mdata  (mac_axis_mdata  ),
    .mac_axis_mkeep  (mac_axis_mkeep  ),
    .mac_axis_mlast  (mac_axis_mlast  ),
    .mac_axis_mvalid (mac_axis_mvalid ),
    .mac_axis_mready (mac_axis_mready ),
    .mac_axis_sdata  (mac_axis_sdata  ),
    .mac_axis_skeep  (mac_axis_skeep  ),
    .mac_axis_slast  (mac_axis_slast  ),
    .mac_axis_svalid (mac_axis_svalid ),
    .mac_axis_susr  (mac_axis_susr  ),
    .mac_axis_sready (mac_axis_sready ),
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
    .ipv4_axis_susr  (ipv4_axis_susr  ),
    .ipv4_axis_sready (ipv4_axis_sready ),
    // IPv6 IP->MAC 映射表（dest=对端表 / src=本机表; 每口项0 有效, 项1 空）
    //   A 口: dest={0,B} src={0,A};  B 口: dest={0,A} src={0,B}
    .cfg_dest_match_ipv6({ {128'd0,CFG_A_IPV6}, {128'd0,CFG_B_IPV6} }),
    .cfg_dest_match_mac ({ { 48'd0,CFG_A_MAC }, { 48'd0,CFG_B_MAC } }),
    .cfg_src_match_ipv6 ({ {128'd0,CFG_B_IPV6}, {128'd0,CFG_A_IPV6} }),
    .cfg_src_match_mac  ({ { 48'd0,CFG_B_MAC }, { 48'd0,CFG_A_MAC } }),
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
    .ipv6_axis_susr  (ipv6_axis_susr  ),
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
    .udp_axis_susr   (udp_axis_susr   ),
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
    .stat_arp_src_not_local(                ),
    .stat_ipv6_drop_pulse  (                )
  );

  // ============================================================================
  // IPv6 通道 : 暂未接测试机 —— 接收侧 mready 恒 1（收下即丢）,
  //            发送侧 svalid 恒 0（DUT 内 ipv6_top 仲裁器无请求）
  // ============================================================================
  assign  ipv6_axis_mready = {(IPV6_RX_TYPE_NUM+1)*ETH_PORT_NUM{1'b1}};
  assign  mac_axis_mready [0*(MAC_RX_TYPE_NUM+1)+1] = 1'b1;   // 口A MAC-other
  assign  mac_axis_mready [1*(MAC_RX_TYPE_NUM+1)+1] = 1'b1;   // 口B MAC-other
  assign  ipv4_axis_mready[0*(IPV4_RX_TYPE_NUM+1)+3] = 1'b1;  // 口A IPv4-other
  assign  ipv4_axis_mready[1*(IPV4_RX_TYPE_NUM+1)+3] = 1'b1;  // 口B IPv4-other
  assign  ipv6_axis_sdata  = {(512*IPV6_TX_TOT*ETH_PORT_NUM){1'b0}};
  assign  ipv6_axis_skeep  = {(64*IPV6_TX_TOT*ETH_PORT_NUM){1'b0}};
  assign  ipv6_axis_slast  = {IPV6_TX_TOT*ETH_PORT_NUM{1'b0}};
  assign  ipv6_axis_svalid = {IPV6_TX_TOT*ETH_PORT_NUM{1'b0}};

  // ============================================================================
  // UDP 通道接线：TX(每口 UDP_TX_N 路用户口) 仅第 0 路接 tester, 其余路恒 0(哑, 不参与仲裁);
  //             DUT 输出取第 CHK_PORT 路 -> 对端口 tester 收(交叉); 其余各路 mready 恒 1（丢弃）
  // ============================================================================
  genvar gu;
  generate
  for (gu = 0; gu < UDP_TX_N*ETH_PORT_NUM; gu = gu + 1) begin : gen_udp_tx_conn
    if (gu == 0) begin : gen_p0_l0                                    // 口A 第 0 路 ← A 口 UDP 测试机
      assign udp_axis_sdata[gu*512 +: 512] = a_udp_s_data ;
      assign udp_axis_skeep[gu* 64 +:  64] = a_udp_s_keep ;
      assign udp_axis_slast[gu]            = a_udp_s_last ;
      assign udp_axis_svalid[gu]           = a_udp_s_valid;
      assign udp_axis_susr [gu*PRIORITY_WIDTH +: PRIORITY_WIDTH] = PRIO_UDP;
      assign a_udp_s_ready                 = udp_axis_sready[gu];
    end else if (gu == UDP_TX_N) begin : gen_p1_l0                    // 口B 第 0 路 ← B 口 UDP 测试机
      assign udp_axis_sdata[gu*512 +: 512] = b_udp_s_data ;
      assign udp_axis_skeep[gu* 64 +:  64] = b_udp_s_keep ;
      assign udp_axis_slast[gu]            = b_udp_s_last ;
      assign udp_axis_svalid[gu]           = b_udp_s_valid;
      assign udp_axis_susr [gu*PRIORITY_WIDTH +: PRIORITY_WIDTH] = PRIO_UDP;
      assign b_udp_s_ready                 = udp_axis_sready[gu];
    end else begin : gen_tie0                                         // 其余路: 恒 0
      assign udp_axis_sdata[gu*512 +: 512] = 512'd0;
      assign udp_axis_skeep[gu* 64 +:  64] = 64'd0;
      assign udp_axis_slast[gu]            = 1'b0;
      assign udp_axis_svalid[gu]           = 1'b0;
      assign udp_axis_susr [gu*PRIORITY_WIDTH +: PRIORITY_WIDTH] = {PRIORITY_WIDTH{1'b0}};
    end
  end
  endgenerate

  assign  a_udp_m_data  = udp_axis_mdata [(0*(UDP_RX_PORT_NUM+1) + CHK_PORT)*512 +: 512];
  assign  a_udp_m_keep  = udp_axis_mkeep [(0*(UDP_RX_PORT_NUM+1) + CHK_PORT)*64  +: 64 ];
  assign  a_udp_m_last  = udp_axis_mlast [ 0*(UDP_RX_PORT_NUM+1) + CHK_PORT];
  assign  a_udp_m_valid = udp_axis_mvalid[ 0*(UDP_RX_PORT_NUM+1) + CHK_PORT];
  assign  b_udp_m_data  = udp_axis_mdata [(1*(UDP_RX_PORT_NUM+1) + CHK_PORT)*512 +: 512];
  assign  b_udp_m_keep  = udp_axis_mkeep [(1*(UDP_RX_PORT_NUM+1) + CHK_PORT)*64  +: 64 ];
  assign  b_udp_m_last  = udp_axis_mlast [ 1*(UDP_RX_PORT_NUM+1) + CHK_PORT];
  assign  b_udp_m_valid = udp_axis_mvalid[ 1*(UDP_RX_PORT_NUM+1) + CHK_PORT];

  genvar gk;
  generate
  for (gk = 0; gk < (UDP_RX_PORT_NUM+1)*ETH_PORT_NUM; gk = gk + 1) begin : gen_udp_rdy
    if ((gk % (UDP_RX_PORT_NUM+1)) == CHK_PORT)
      assign udp_axis_mready[gk] = (gk < (UDP_RX_PORT_NUM+1)) ? a_udp_m_ready : b_udp_m_ready;
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
    .axis_mdata(ipv4_axis_sdata[(0*IPV4_TX_N+0)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(0*IPV4_TX_N+0)*64 +: 64]),
    .axis_mvalid(ipv4_axis_svalid[0*IPV4_TX_N+0]), .axis_mlast(ipv4_axis_slast[0*IPV4_TX_N+0]),
    .axis_mready(ipv4_axis_sready[0*IPV4_TX_N+0]),
    .axis_sdata(ipv4_axis_mdata[(1*(IPV4_RX_TYPE_NUM+1)+0)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(1*(IPV4_RX_TYPE_NUM+1)+0)*64 +: 64]),
    .axis_svalid(ipv4_axis_mvalid[1*(IPV4_RX_TYPE_NUM+1)+0]), .axis_slast(ipv4_axis_mlast[1*(IPV4_RX_TYPE_NUM+1)+0]),
    .axis_sready(ipv4_axis_mready[1*(IPV4_RX_TYPE_NUM+1)+0])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_IP_OSPF_A)
  ) u_ta_ospf (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_a_ospf    ),
    .axis_mdata(ipv4_axis_sdata[(0*IPV4_TX_N+1)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(0*IPV4_TX_N+1)*64 +: 64]),
    .axis_mvalid(ipv4_axis_svalid[0*IPV4_TX_N+1]), .axis_mlast(ipv4_axis_slast[0*IPV4_TX_N+1]),
    .axis_mready(ipv4_axis_sready[0*IPV4_TX_N+1]),
    .axis_sdata(ipv4_axis_mdata[(1*(IPV4_RX_TYPE_NUM+1)+1)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(1*(IPV4_RX_TYPE_NUM+1)+1)*64 +: 64]),
    .axis_svalid(ipv4_axis_mvalid[1*(IPV4_RX_TYPE_NUM+1)+1]), .axis_slast(ipv4_axis_mlast[1*(IPV4_RX_TYPE_NUM+1)+1]),
    .axis_sready(ipv4_axis_mready[1*(IPV4_RX_TYPE_NUM+1)+1])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_IP_OTHR_A)
  ) u_ta_ipother (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_a_ipother ),
    .axis_mdata(ipv4_axis_sdata[(0*IPV4_TX_N+2)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(0*IPV4_TX_N+2)*64 +: 64]),
    .axis_mvalid(ipv4_axis_svalid[0*IPV4_TX_N+2]), .axis_mlast(ipv4_axis_slast[0*IPV4_TX_N+2]),
    .axis_mready(ipv4_axis_sready[0*IPV4_TX_N+2]),
    .axis_sdata(ipv4_axis_mdata[(1*(IPV4_RX_TYPE_NUM+1)+2)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(1*(IPV4_RX_TYPE_NUM+1)+2)*64 +: 64]),
    .axis_svalid(ipv4_axis_mvalid[1*(IPV4_RX_TYPE_NUM+1)+2]), .axis_slast(ipv4_axis_mlast[1*(IPV4_RX_TYPE_NUM+1)+2]),
    .axis_sready(ipv4_axis_mready[1*(IPV4_RX_TYPE_NUM+1)+2])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_MAC_A)
  ) u_ta_macother (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_a_macother),
    .axis_mdata(mac_axis_sdata[(0*MAC_TX_N+0)*512 +: 512]), .axis_mkeep(mac_axis_skeep[(0*MAC_TX_N+0)*64 +: 64]),
    .axis_mvalid(mac_axis_svalid[0*MAC_TX_N+0]), .axis_mlast(mac_axis_slast[0*MAC_TX_N+0]),
    .axis_mready(mac_axis_sready[0*MAC_TX_N+0]),
    .axis_sdata(mac_axis_mdata[(1*(MAC_RX_TYPE_NUM+1)+0)*512 +: 512]), .axis_skeep(mac_axis_mkeep[(1*(MAC_RX_TYPE_NUM+1)+0)*64 +: 64]),
    .axis_svalid(mac_axis_mvalid[1*(MAC_RX_TYPE_NUM+1)+0]), .axis_slast(mac_axis_mlast[1*(MAC_RX_TYPE_NUM+1)+0]),
    .axis_sready(mac_axis_mready[1*(MAC_RX_TYPE_NUM+1)+0])
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
    .axis_mdata(ipv4_axis_sdata[(1*IPV4_TX_N+0)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(1*IPV4_TX_N+0)*64 +: 64]),
    .axis_mvalid(ipv4_axis_svalid[1*IPV4_TX_N+0]), .axis_mlast(ipv4_axis_slast[1*IPV4_TX_N+0]),
    .axis_mready(ipv4_axis_sready[1*IPV4_TX_N+0]),
    .axis_sdata(ipv4_axis_mdata[(0*(IPV4_RX_TYPE_NUM+1)+0)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(0*(IPV4_RX_TYPE_NUM+1)+0)*64 +: 64]),
    .axis_svalid(ipv4_axis_mvalid[0*(IPV4_RX_TYPE_NUM+1)+0]), .axis_slast(ipv4_axis_mlast[0*(IPV4_RX_TYPE_NUM+1)+0]),
    .axis_sready(ipv4_axis_mready[0*(IPV4_RX_TYPE_NUM+1)+0])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_IP_OSPF_B)
  ) u_tb_ospf (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_b_ospf    ),
    .axis_mdata(ipv4_axis_sdata[(1*IPV4_TX_N+1)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(1*IPV4_TX_N+1)*64 +: 64]),
    .axis_mvalid(ipv4_axis_svalid[1*IPV4_TX_N+1]), .axis_mlast(ipv4_axis_slast[1*IPV4_TX_N+1]),
    .axis_mready(ipv4_axis_sready[1*IPV4_TX_N+1]),
    .axis_sdata(ipv4_axis_mdata[(0*(IPV4_RX_TYPE_NUM+1)+1)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(0*(IPV4_RX_TYPE_NUM+1)+1)*64 +: 64]),
    .axis_svalid(ipv4_axis_mvalid[0*(IPV4_RX_TYPE_NUM+1)+1]), .axis_slast(ipv4_axis_mlast[0*(IPV4_RX_TYPE_NUM+1)+1]),
    .axis_sready(ipv4_axis_mready[0*(IPV4_RX_TYPE_NUM+1)+1])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_IP_OTHR_B)
  ) u_tb_ipother (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_b_ipother ),
    .axis_mdata(ipv4_axis_sdata[(1*IPV4_TX_N+2)*512 +: 512]), .axis_mkeep(ipv4_axis_skeep[(1*IPV4_TX_N+2)*64 +: 64]),
    .axis_mvalid(ipv4_axis_svalid[1*IPV4_TX_N+2]), .axis_mlast(ipv4_axis_slast[1*IPV4_TX_N+2]),
    .axis_mready(ipv4_axis_sready[1*IPV4_TX_N+2]),
    .axis_sdata(ipv4_axis_mdata[(0*(IPV4_RX_TYPE_NUM+1)+2)*512 +: 512]), .axis_skeep(ipv4_axis_mkeep[(0*(IPV4_RX_TYPE_NUM+1)+2)*64 +: 64]),
    .axis_svalid(ipv4_axis_mvalid[0*(IPV4_RX_TYPE_NUM+1)+2]), .axis_slast(ipv4_axis_mlast[0*(IPV4_RX_TYPE_NUM+1)+2]),
    .axis_sready(ipv4_axis_mready[0*(IPV4_RX_TYPE_NUM+1)+2])
  );

  subsys_100g_tester #(
    .AXIS_WIDTH(AXIS_WIDTH), .PKT_LEN_BEATS(PKT_LEN_BEATS), .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
    .HDR_BYTES(HDR_MAC_B)
  ) u_tb_macother (
    .clk(clk_400m), .rst(usr_rst), .test_enable(en_b_macother),
    .axis_mdata(mac_axis_sdata[(1*MAC_TX_N+0)*512 +: 512]), .axis_mkeep(mac_axis_skeep[(1*MAC_TX_N+0)*64 +: 64]),
    .axis_mvalid(mac_axis_svalid[1*MAC_TX_N+0]), .axis_mlast(mac_axis_slast[1*MAC_TX_N+0]),
    .axis_mready(mac_axis_sready[1*MAC_TX_N+0]),
    .axis_sdata(mac_axis_mdata[(0*(MAC_RX_TYPE_NUM+1)+0)*512 +: 512]), .axis_skeep(mac_axis_mkeep[(0*(MAC_RX_TYPE_NUM+1)+0)*64 +: 64]),
    .axis_svalid(mac_axis_mvalid[0*(MAC_RX_TYPE_NUM+1)+0]), .axis_slast(mac_axis_mlast[0*(MAC_RX_TYPE_NUM+1)+0]),
    .axis_sready(mac_axis_mready[0*(MAC_RX_TYPE_NUM+1)+0])
  );

  // ============================================================================
  // TX 优先级(user)接线 : 位序 = 每口位段 [gi*W +: W], 口内路序 = 路0 在最低段
  //   A/B 两口同值; MAC 对外段每口 1 路; IPv4 每口 3 路(0=icmp,1=ospf,2=06);
  //   IPv6 每口 3 路(0=udp,1=icmpv6,2=ospf, 暂 tie-off); UDP 见 gen_udp_tx_conn
  // ============================================================================
  assign  mac_axis_susr   = { PRIO_MACOTH, PRIO_MACOTH };                         // [口B, 口A]
  assign  ipv4_axis_susr  = { PRIO_IPOTHER, PRIO_OSPF, PRIO_ICMP,                 // 口B: 06/ospf/icmp
                              PRIO_IPOTHER, PRIO_OSPF, PRIO_ICMP };               // 口A: 06/ospf/icmp
  assign  ipv6_axis_susr  = { PRIO_OSPFV3, PRIO_ICMPV6, PRIO_UDP6,                // 口B: ospf/icmpv6/udp
                              PRIO_OSPFV3, PRIO_ICMPV6, PRIO_UDP6 };              // 口A: ospf/icmpv6/udp

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
