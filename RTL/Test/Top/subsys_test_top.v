// -----------------------------------------------------------------------------
// File Name   : subsys_test_top.v
// Module Name : subsys_test_top
// Author      : LiXintao
// Created     : 2026-10-13
// -----------------------------------------------------------------------------
// Description : eth_stack_top 双口板级测试，A/B 经外部光缆对接。
// Note        : 每个测试器从本口发送，在对端对应的协议通道校验。
//               VIO probe_out0..22、24..27 控制27路使能，probe_out23 配置共享包间隔。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 1ps

module subsys_test_top (
    input wire sys_clk,

    // 网口A
    output wire [3:0] gt_txp_out_a,
    output wire [3:0] gt_txn_out_a,
    input  wire [3:0] gt_rxp_in_a,
    input  wire [3:0] gt_rxn_in_a,
    input  wire       gt_ref_clk_p_a,
    input  wire       gt_ref_clk_n_a,
    output wire       qsfp_rstn_port_a,
    output wire       qsfp_lp_mode_port_a,
    output wire       qsfp_seln_port_a,
    input  wire       qsfp_prsn_port_a,
    output wire       qsfp_led_port_a,

    // 网口B
    output wire [3:0] gt_txp_out_b,
    output wire [3:0] gt_txn_out_b,
    input  wire [3:0] gt_rxp_in_b,
    input  wire [3:0] gt_rxn_in_b,
    input  wire       gt_ref_clk_p_b,
    input  wire       gt_ref_clk_n_b,
    output wire       qsfp_rstn_port_b,
    output wire       qsfp_lp_mode_port_b,
    output wire       qsfp_seln_port_b,
    input  wire       qsfp_prsn_port_b,
    output wire       qsfp_led_port_b
);

  // 生成400MHz业务时钟，复位释放后由VIO独立启动27路测试流。
  // A/B口经外部光缆对接，每路测试器在对端对应通道校验。

  // 基础常量
  localparam AXIS_WIDTH = 512;
  localparam PKT_LEN_BEATS = 16;
  localparam ONE_SEC_CYCLES = 32'd400_000_000;
  localparam [15:0] CHK_PORT = 16'h0200;  // UDP 端口 2，低字节先上网

  // 两口 IPv4 地址和 MAC 取各自默认表的第 0 项。
  localparam [31:0] CFG_A_IP = 32'h1201_a8c0;
  localparam [31:0] CFG_B_IP = 32'h9101_a8c0;
  localparam [47:0] CFG_A_MAC = 48'h0300_3119_0000;
  localparam [47:0] CFG_B_MAC = 48'h8200_3119_0000;

  // IPv6 测试流使用两口默认源/目的表的第0项。
  localparam [127:0] SRC_IPV6_A = 128'h1200_3119_0000_0000_0000_0000_0000_80fe;
  localparam [127:0] DST_IPV6_A = 128'h2300_3119_0000_0000_0000_0000_0000_80fe;
  localparam [127:0] SRC_IPV6_B = DST_IPV6_A;
  localparam [127:0] DST_IPV6_B = SRC_IPV6_A;

  // 完整IPv4测试包的总长度。
  localparam [15:0] IP_LEN_FULL = PKT_LEN_BEATS * 64;
  localparam [15:0] IP_LEN_FULL_LE = {IP_LEN_FULL[7:0], IP_LEN_FULL[15:8]};

  // 发送优先级：user低4位，0禁用，1至15有效。
  // ARP默认优先级为15，可通过配置通路修改。
  localparam [3:0] PRIO_UDP_A = 4'd8;  // 口A UDP(v4)
  localparam [3:0] PRIO_UDP_B = 4'd9;  // 口B UDP(v4)
  localparam [3:0] PRIO_ICMP_A = 4'd12;  // 口A ICMPv4
  localparam [3:0] PRIO_ICMP_B = 4'd11;  // 口B ICMPv4
  localparam [3:0] PRIO_OSPF_A = 4'd13;  // 口A OSPF(v4)
  localparam [3:0] PRIO_OSPF_B = 4'd13;  // 口B OSPF(v4)
  localparam [3:0] PRIO_IP06_A = 4'd7;  // 口A 协议 0x06
  localparam [3:0] PRIO_IP06_B = 4'd6;  // 口B 协议 0x06
  localparam [3:0] PRIO_ICMPV6_A = 4'd14;  // 口A ICMPv6(NDP)
  localparam [3:0] PRIO_ICMPV6_B = 4'd14;  // 口B ICMPv6(NDP)
  localparam [3:0] PRIO_OSPFV3_A = 4'd13;  // 口A OSPFv3
  localparam [3:0] PRIO_OSPFV3_B = 4'd12;  // 口B OSPFv3
  localparam [3:0] PRIO_MAC88B5_A = 4'd6;  // 口A 自定义类型 0x88B5
  localparam [3:0] PRIO_MAC88B5_B = 4'd5;  // 口B 自定义类型 0x88B5
  localparam [3:0] PRIO_FB = 4'd2;  // 兜底探测流(最低, 不抢业务流)

  // UDP TX 每包元数据(108bit, {dst_ip,src_ip,dport,sport,ttl,prio})
  localparam [107:0] UDP_USR_DATA_A = {
    CFG_B_IP, CFG_A_IP, CHK_PORT[15:0], 16'h0000, 8'h40, PRIO_UDP_A
  };
  localparam [107:0] UDP_USR_FB_A = {CFG_B_IP, CFG_A_IP, 16'h3412, 16'h0000, 8'h40, PRIO_FB};
  localparam [107:0] UDP_USR_DATA_B = {
    CFG_A_IP, CFG_B_IP, CHK_PORT[15:0], 16'h0000, 8'h40, PRIO_UDP_B
  };
  localparam [107:0] UDP_USR_FB_B = {CFG_A_IP, CFG_B_IP, 16'h3412, 16'h0000, 8'h40, PRIO_FB};

  // UDP/IPv6 TX 每包元数据（300位），目的端口2命中档0，0x1234走兜底。
  localparam [299:0] UDP_IPV6_USR_DATA_A = {
    DST_IPV6_A, SRC_IPV6_A, CHK_PORT, 16'h0100, 8'h40, PRIO_UDP_A
  };
  localparam [299:0] UDP_IPV6_USR_FB_A = {
    DST_IPV6_A, SRC_IPV6_A, 16'h3412, 16'h0100, 8'h40, PRIO_FB
  };
  localparam [299:0] UDP_IPV6_USR_DATA_B = {
    DST_IPV6_B, SRC_IPV6_B, CHK_PORT, 16'h0100, 8'h40, PRIO_UDP_B
  };
  localparam [299:0] UDP_IPV6_USR_FB_B = {
    DST_IPV6_B, SRC_IPV6_B, 16'h3412, 16'h0100, 8'h40, PRIO_FB
  };

  // MAC与IPv4测试头：低字节为线上第一字节。
  // 以太帧头 14B: dst_mac(6) src_mac(6) type(2)
  localparam [159:0] HDR_MAC_88B5_A = {16'hB588, CFG_A_MAC, CFG_B_MAC};  // 自定义类型 0x88B5
  localparam [159:0] HDR_MAC_88B5_B = {16'hB588, CFG_B_MAC, CFG_A_MAC};
  // 自定义类型 0x88CC(仅 B 发, 只落 A 的用户档)
  localparam [159:0] HDR_MAC_88CC_B = {16'hCC88, CFG_B_MAC, CFG_A_MAC};
  // 0x88DD: 两口字典都没有 -> 落对端兜底档
  localparam [159:0] HDR_MAC_FB_A = {16'hDD88, CFG_A_MAC, CFG_B_MAC};
  localparam [159:0] HDR_MAC_FB_B = {16'hDD88, CFG_B_MAC, CFG_A_MAC};
  // IPv4首部20字节，ICMPv4 Echo Reply首部8字节。
  localparam [223:0] HDR_IP_ICMP_A = {
    32'd0,
    16'hFF87,
    16'h0000,
    CFG_B_IP,
    CFG_A_IP,
    16'h09B3,
    8'h01,
    8'h40,
    16'h0040,
    16'h0000,
    IP_LEN_FULL_LE,
    8'h00,
    8'h45
  };
  localparam [223:0] HDR_IP_ICMP_B = {
    32'd0,
    16'hFF87,
    16'h0000,
    CFG_A_IP,
    CFG_B_IP,
    16'h09B3,
    8'h01,
    8'h40,
    16'h0040,
    16'h0000,
    IP_LEN_FULL_LE,
    8'h00,
    8'h45
  };
  // 其他IPv4测试头（protocol: ospf=0x59 / 0x06 / 0x2F=兜底探测）
  localparam [159:0] HDR_IP_OSPF_A = {
    CFG_B_IP, CFG_A_IP, 16'h0000, 8'h59, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45
  };
  localparam [159:0] HDR_IP_OSPF_B = {
    CFG_A_IP, CFG_B_IP, 16'h0000, 8'h59, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45
  };
  localparam [159:0] HDR_IP_06_A = {
    CFG_B_IP, CFG_A_IP, 16'h0000, 8'h06, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45
  };
  localparam [159:0] HDR_IP_06_B = {
    CFG_A_IP, CFG_B_IP, 16'h0000, 8'h06, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45
  };
  localparam [159:0] HDR_IP_FB_A = {
    CFG_B_IP, CFG_A_IP, 16'h0000, 8'h2F, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45
  };
  localparam [159:0] HDR_IP_FB_B = {
    CFG_A_IP, CFG_B_IP, 16'h0000, 8'h2F, 8'h40, 16'h0040, 16'h0000, IP_LEN_FULL_LE, 8'h00, 8'h45
  };

  // IPv6测试头：固定40字节。
  //   ver/TC/FL(4B) payload_len(2B) next_hdr(1B) hop_limit(1B) src(16B) dst(16B)
  //   next_hdr: 0x3A=icmpv6 / 0x59=ospfv3 / 0x06=兜底探测(未匹配)
  localparam [15:0] IPV6_PL = PKT_LEN_BEATS * 64 - 40;  // IPv6 净载荷长度
  localparam [15:0] IPV6_PL_LE = {
    IPV6_PL[7:0], IPV6_PL[15:8]
  };  // 长度字段交换字节顺序后放入总线
  localparam [319:0] HDR_IP6_ICMP_A = {
    DST_IPV6_A, SRC_IPV6_A, 8'h40, 8'h3A, IPV6_PL_LE, 24'd0, 8'h60
  };
  localparam [319:0] HDR_IP6_ICMP_B = {
    DST_IPV6_B, SRC_IPV6_B, 8'h40, 8'h3A, IPV6_PL_LE, 24'd0, 8'h60
  };
  localparam [319:0] HDR_IP6_OSPF_A = {
    DST_IPV6_A, SRC_IPV6_A, 8'h40, 8'h59, IPV6_PL_LE, 24'd0, 8'h60
  };
  localparam [319:0] HDR_IP6_OSPF_B = {
    DST_IPV6_B, SRC_IPV6_B, 8'h40, 8'h59, IPV6_PL_LE, 24'd0, 8'h60
  };
  localparam [319:0] HDR_IP6_FB_A = {
    DST_IPV6_A, SRC_IPV6_A, 8'h40, 8'h06, IPV6_PL_LE, 24'd0, 8'h60
  };
  localparam [319:0] HDR_IP6_FB_B = {
    DST_IPV6_B, SRC_IPV6_B, 8'h40, 8'h06, IPV6_PL_LE, 24'd0, 8'h60
  };

  // 时钟与复位信号
  wire clk_400m;
  wire clk_locked;
  reg usr_rst;
  wire qsfp_gt_rst;
  (* ASYNC_REG = "true" *) reg [1:0] rst_sync = 2'b11;

  // 测试使能，VIO探针映射见末尾实例。
  wire [15:0] cfg_gap_cycles;
  wire en_a_udp;
  wire en_a_icmp;
  wire en_a_ospf;
  wire en_a_ipv4_06;
  wire en_a_mac_88b5;
  wire en_b_udp;
  wire en_b_icmp;
  wire en_b_ospf;
  wire en_b_ipv4_06;
  wire en_b_mac_88b5;
  wire en_a_ip6icmp;
  wire en_a_ip6ospf;
  wire en_b_ip6icmp;
  wire en_b_ip6ospf;
  wire en_a_fb_mac;
  wire en_a_fb_ipv4;
  wire en_a_fb_ipv6;
  wire en_a_fb_udp;
  wire en_b_mac_88cc;
  wire en_b_fb_mac;
  wire en_b_fb_ipv4;
  wire en_b_fb_ipv6;
  wire en_b_fb_udp;
  wire en_a_udp_ipv6;
  wire en_b_udp_ipv6;
  wire en_a_fb_udp_ipv6;
  wire en_b_fb_udp_ipv6;

  // A口MAC接收接口
  wire [1535:0] a_mac_axis_mdata;
  wire [191:0] a_mac_axis_mkeep;
  wire [2:0] a_mac_axis_musr;
  wire [2:0] a_mac_axis_mvalid;
  wire [2:0] a_mac_axis_mlast;
  wire [2:0] a_mac_axis_mready;

  // A口MAC发送接口
  wire [1023:0] a_mac_axis_sdata;
  wire [127:0] a_mac_axis_skeep;
  wire [2*4-1:0] a_mac_axis_susr;
  wire [1:0] a_mac_axis_svalid;
  wire [1:0] a_mac_axis_slast;
  wire [1:0] a_mac_axis_sready;

  // A口IPv4接收接口
  wire [2047:0] a_ipv4_axis_mdata;
  wire [255:0] a_ipv4_axis_mkeep;
  wire [3:0] a_ipv4_axis_mvalid;
  wire [3:0] a_ipv4_axis_mlast;
  wire [3:0] a_ipv4_axis_mready;

  // A口IPv4发送接口
  wire [2047:0] a_ipv4_axis_sdata;
  wire [255:0] a_ipv4_axis_skeep;
  wire [4*4-1:0] a_ipv4_axis_susr;
  wire [3:0] a_ipv4_axis_svalid;
  wire [3:0] a_ipv4_axis_slast;
  wire [3:0] a_ipv4_axis_sready;

  // A口ICMP接收接口
  wire [511:0] a_icmp_axis_mdata;
  wire [63:0] a_icmp_axis_mkeep;
  wire a_icmp_axis_mvalid;
  wire a_icmp_axis_mlast;
  wire a_icmp_axis_mready;

  // A口ICMPv4发送接口
  wire [511:0] a_icmp_axis_sdata;
  wire [63:0] a_icmp_axis_skeep;
  wire [3:0] a_icmp_axis_susr;
  wire a_icmp_axis_svalid;
  wire a_icmp_axis_slast;
  wire a_icmp_axis_sready;

  // A口IPv6接收接口
  wire [2047:0] a_ipv6_axis_mdata;
  wire [255:0] a_ipv6_axis_mkeep;
  wire [3:0] a_ipv6_axis_mvalid;
  wire [3:0] a_ipv6_axis_mlast;
  wire [3:0] a_ipv6_axis_mready;

  // A口IPv6发送接口
  wire [1535:0] a_ipv6_axis_sdata;
  wire [191:0] a_ipv6_axis_skeep;
  wire [3*4-1:0] a_ipv6_axis_susr;
  wire [2:0] a_ipv6_axis_svalid;
  wire [2:0] a_ipv6_axis_slast;
  wire [2:0] a_ipv6_axis_sready;

  // A口UDP(IPV4)接收接口
  wire [2047:0] a_udp_ipv4_axis_mdata;
  wire [255:0] a_udp_ipv4_axis_mkeep;
  wire [3:0] a_udp_ipv4_axis_mvalid;
  wire [3:0] a_udp_ipv4_axis_mlast;
  wire [3:0] a_udp_ipv4_axis_mready;

  // A口UDP(IPV4)发送接口
  wire [4095:0] a_udp_ipv4_axis_sdata;
  wire [511:0] a_udp_ipv4_axis_skeep;
  wire [8*108-1:0] a_udp_ipv4_axis_susr;
  wire [7:0] a_udp_ipv4_axis_svalid;
  wire [7:0] a_udp_ipv4_axis_slast;
  wire [7:0] a_udp_ipv4_axis_sready;

  // UDP(IPV6)接收
  wire [2047:0] a_udp_ipv6_axis_mdata;
  wire [255:0] a_udp_ipv6_axis_mkeep;
  wire [3:0] a_udp_ipv6_axis_mvalid;
  wire [3:0] a_udp_ipv6_axis_mlast;
  wire [3:0] a_udp_ipv6_axis_mready;

  // A口UDP(IPV6)发送接口
  wire [1023:0] a_udp_ipv6_axis_sdata;
  wire [127:0] a_udp_ipv6_axis_skeep;
  wire [2*300-1:0] a_udp_ipv6_axis_susr;
  wire [1:0] a_udp_ipv6_axis_svalid;
  wire [1:0] a_udp_ipv6_axis_slast;
  wire [1:0] a_udp_ipv6_axis_sready;

  // B口MAC接收接口
  wire [1023:0] b_mac_axis_mdata;
  wire [127:0] b_mac_axis_mkeep;
  wire [1:0] b_mac_axis_musr;
  wire [1:0] b_mac_axis_mvalid;
  wire [1:0] b_mac_axis_mlast;
  wire [1:0] b_mac_axis_mready;

  // B口MAC发送接口
  wire [1535:0] b_mac_axis_sdata;
  wire [191:0] b_mac_axis_skeep;
  wire [3*4-1:0] b_mac_axis_susr;
  wire [2:0] b_mac_axis_svalid;
  wire [2:0] b_mac_axis_slast;
  wire [2:0] b_mac_axis_sready;

  // B口IPv4接收接口
  wire [2047:0] b_ipv4_axis_mdata;
  wire [255:0] b_ipv4_axis_mkeep;
  wire [3:0] b_ipv4_axis_mvalid;
  wire [3:0] b_ipv4_axis_mlast;
  wire [3:0] b_ipv4_axis_mready;

  // B口IPv4发送接口
  wire [2047:0] b_ipv4_axis_sdata;
  wire [255:0] b_ipv4_axis_skeep;
  wire [4*4-1:0] b_ipv4_axis_susr;
  wire [3:0] b_ipv4_axis_svalid;
  wire [3:0] b_ipv4_axis_slast;
  wire [3:0] b_ipv4_axis_sready;

  // B口ICMP接收接口
  wire [511:0] b_icmp_axis_mdata;
  wire [63:0] b_icmp_axis_mkeep;
  wire b_icmp_axis_mvalid;
  wire b_icmp_axis_mlast;
  wire b_icmp_axis_mready;

  // B口ICMPv4发送接口
  wire [511:0] b_icmp_axis_sdata;
  wire [63:0] b_icmp_axis_skeep;
  wire [3:0] b_icmp_axis_susr;
  wire b_icmp_axis_svalid;
  wire b_icmp_axis_slast;
  wire b_icmp_axis_sready;

  // B口IPv6接收接口
  wire [2047:0] b_ipv6_axis_mdata;
  wire [255:0] b_ipv6_axis_mkeep;
  wire [3:0] b_ipv6_axis_mvalid;
  wire [3:0] b_ipv6_axis_mlast;
  wire [3:0] b_ipv6_axis_mready;

  // B口IPv6发送接口
  wire [1535:0] b_ipv6_axis_sdata;
  wire [191:0] b_ipv6_axis_skeep;
  wire [3*4-1:0] b_ipv6_axis_susr;
  wire [2:0] b_ipv6_axis_svalid;
  wire [2:0] b_ipv6_axis_slast;
  wire [2:0] b_ipv6_axis_sready;

  // B口UDP(IPV4)接收接口
  wire [2047:0] b_udp_ipv4_axis_mdata;
  wire [255:0] b_udp_ipv4_axis_mkeep;
  wire [3:0] b_udp_ipv4_axis_mvalid;
  wire [3:0] b_udp_ipv4_axis_mlast;
  wire [3:0] b_udp_ipv4_axis_mready;

  // B口UDP(IPV4)发送接口
  wire [2047:0] b_udp_ipv4_axis_sdata;
  wire [255:0] b_udp_ipv4_axis_skeep;
  wire [4*108-1:0] b_udp_ipv4_axis_susr;
  wire [3:0] b_udp_ipv4_axis_svalid;
  wire [3:0] b_udp_ipv4_axis_slast;
  wire [3:0] b_udp_ipv4_axis_sready;

  // UDP(IPV6)接收
  wire [2047:0] b_udp_ipv6_axis_mdata;
  wire [255:0] b_udp_ipv6_axis_mkeep;
  wire [3:0] b_udp_ipv6_axis_mvalid;
  wire [3:0] b_udp_ipv6_axis_mlast;
  wire [3:0] b_udp_ipv6_axis_mready;

  // B口UDP(IPV6)发送接口
  wire [1023:0] b_udp_ipv6_axis_sdata;
  wire [127:0] b_udp_ipv6_axis_skeep;
  wire [2*300-1:0] b_udp_ipv6_axis_susr;
  wire [1:0] b_udp_ipv6_axis_svalid;
  wire [1:0] b_udp_ipv6_axis_slast;
  wire [1:0] b_udp_ipv6_axis_sready;

  // 业务时钟生成
  clk_100_to_400m u_clk_100_to_400m (
      .clk_400m(clk_400m),
      .locked  (clk_locked),
      .clk_100m(sys_clk)
  );

  // 复位同步
  //// 异步置位，两级同步释放。
  always @(posedge clk_400m or posedge qsfp_gt_rst) begin
    if (qsfp_gt_rst) rst_sync <= 2'b11;
    else rst_sync <= {rst_sync[0], 1'b0};
  end

  //// 用户复位再寄存一拍。
  always @(posedge clk_400m) begin
    usr_rst <= rst_sync[1];
  end

  // 双口协议栈
  eth_stack_top u_eth_stack_top (
      .init_clk   (sys_clk),
      .clk        (clk_400m),
      .rst        (usr_rst),
      .clk_locked (clk_locked),
      .qsfp_gt_rst(qsfp_gt_rst),

      .a_gt_txp_out  (gt_txp_out_a),
      .a_gt_txn_out  (gt_txn_out_a),
      .a_gt_rxp_in   (gt_rxp_in_a),
      .a_gt_rxn_in   (gt_rxn_in_a),
      .a_gt_ref_clk_p(gt_ref_clk_p_a),
      .a_gt_ref_clk_n(gt_ref_clk_n_a),

      .a_qsfp_reset_n       (qsfp_rstn_port_a),
      .a_qsfp_low_power_mode(qsfp_lp_mode_port_a),
      .a_qsfp_select_n      (qsfp_seln_port_a),
      .a_qsfp_present_n     (qsfp_prsn_port_a),
      .a_qsfp_led           (qsfp_led_port_a),

      .a_mac_axis_mdata (a_mac_axis_mdata),
      .a_mac_axis_mkeep (a_mac_axis_mkeep),
      .a_mac_axis_musr  (a_mac_axis_musr),
      .a_mac_axis_mvalid(a_mac_axis_mvalid),
      .a_mac_axis_mlast (a_mac_axis_mlast),
      .a_mac_axis_mready(a_mac_axis_mready),

      .a_mac_axis_sdata (a_mac_axis_sdata),
      .a_mac_axis_skeep (a_mac_axis_skeep),
      .a_mac_axis_susr  (a_mac_axis_susr),
      .a_mac_axis_svalid(a_mac_axis_svalid),
      .a_mac_axis_slast (a_mac_axis_slast),
      .a_mac_axis_sready(a_mac_axis_sready),

      .a_ipv4_axis_mdata (a_ipv4_axis_mdata),
      .a_ipv4_axis_mkeep (a_ipv4_axis_mkeep),
      .a_ipv4_axis_musr  (),
      .a_ipv4_axis_mvalid(a_ipv4_axis_mvalid),
      .a_ipv4_axis_mlast (a_ipv4_axis_mlast),
      .a_ipv4_axis_mready(a_ipv4_axis_mready),

      .a_ipv4_axis_sdata (a_ipv4_axis_sdata),
      .a_ipv4_axis_skeep (a_ipv4_axis_skeep),
      .a_ipv4_axis_susr  (a_ipv4_axis_susr),
      .a_ipv4_axis_svalid(a_ipv4_axis_svalid),
      .a_ipv4_axis_slast (a_ipv4_axis_slast),
      .a_ipv4_axis_sready(a_ipv4_axis_sready),

      .a_icmp_axis_mdata (a_icmp_axis_mdata),
      .a_icmp_axis_mkeep (a_icmp_axis_mkeep),
      .a_icmp_axis_musr  (),
      .a_icmp_axis_mvalid(a_icmp_axis_mvalid),
      .a_icmp_axis_mlast (a_icmp_axis_mlast),
      .a_icmp_axis_mready(a_icmp_axis_mready),

      .a_icmp_axis_sdata (a_icmp_axis_sdata),
      .a_icmp_axis_skeep (a_icmp_axis_skeep),
      .a_icmp_axis_susr  (a_icmp_axis_susr),
      .a_icmp_axis_svalid(a_icmp_axis_svalid),
      .a_icmp_axis_slast (a_icmp_axis_slast),
      .a_icmp_axis_sready(a_icmp_axis_sready),

      .a_ipv6_axis_mdata (a_ipv6_axis_mdata),
      .a_ipv6_axis_mkeep (a_ipv6_axis_mkeep),
      .a_ipv6_axis_musr  (),
      .a_ipv6_axis_mvalid(a_ipv6_axis_mvalid),
      .a_ipv6_axis_mlast (a_ipv6_axis_mlast),
      .a_ipv6_axis_mready(a_ipv6_axis_mready),

      .a_ipv6_axis_sdata (a_ipv6_axis_sdata),
      .a_ipv6_axis_skeep (a_ipv6_axis_skeep),
      .a_ipv6_axis_susr  (a_ipv6_axis_susr),
      .a_ipv6_axis_svalid(a_ipv6_axis_svalid),
      .a_ipv6_axis_slast (a_ipv6_axis_slast),
      .a_ipv6_axis_sready(a_ipv6_axis_sready),

      .a_udp_ipv4_axis_mdata (a_udp_ipv4_axis_mdata),
      .a_udp_ipv4_axis_mkeep (a_udp_ipv4_axis_mkeep),
      .a_udp_ipv4_axis_musr  (),
      .a_udp_ipv4_axis_mvalid(a_udp_ipv4_axis_mvalid),
      .a_udp_ipv4_axis_mlast (a_udp_ipv4_axis_mlast),
      .a_udp_ipv4_axis_mready(a_udp_ipv4_axis_mready),

      .a_udp_ipv4_axis_sdata (a_udp_ipv4_axis_sdata),
      .a_udp_ipv4_axis_skeep (a_udp_ipv4_axis_skeep),
      .a_udp_ipv4_axis_susr  (a_udp_ipv4_axis_susr),
      .a_udp_ipv4_axis_svalid(a_udp_ipv4_axis_svalid),
      .a_udp_ipv4_axis_slast (a_udp_ipv4_axis_slast),
      .a_udp_ipv4_axis_sready(a_udp_ipv4_axis_sready),

      .a_udp_ipv6_axis_mdata (a_udp_ipv6_axis_mdata),
      .a_udp_ipv6_axis_mkeep (a_udp_ipv6_axis_mkeep),
      .a_udp_ipv6_axis_musr  (),
      .a_udp_ipv6_axis_mvalid(a_udp_ipv6_axis_mvalid),
      .a_udp_ipv6_axis_mlast (a_udp_ipv6_axis_mlast),
      .a_udp_ipv6_axis_mready(a_udp_ipv6_axis_mready),

      .a_udp_ipv6_axis_sdata (a_udp_ipv6_axis_sdata),
      .a_udp_ipv6_axis_skeep (a_udp_ipv6_axis_skeep),
      .a_udp_ipv6_axis_susr  (a_udp_ipv6_axis_susr),
      .a_udp_ipv6_axis_svalid(a_udp_ipv6_axis_svalid),
      .a_udp_ipv6_axis_slast (a_udp_ipv6_axis_slast),
      .a_udp_ipv6_axis_sready(a_udp_ipv6_axis_sready),

      .b_gt_txp_out  (gt_txp_out_b),
      .b_gt_txn_out  (gt_txn_out_b),
      .b_gt_rxp_in   (gt_rxp_in_b),
      .b_gt_rxn_in   (gt_rxn_in_b),
      .b_gt_ref_clk_p(gt_ref_clk_p_b),
      .b_gt_ref_clk_n(gt_ref_clk_n_b),

      .b_qsfp_reset_n       (qsfp_rstn_port_b),
      .b_qsfp_low_power_mode(qsfp_lp_mode_port_b),
      .b_qsfp_select_n      (qsfp_seln_port_b),
      .b_qsfp_present_n     (qsfp_prsn_port_b),
      .b_qsfp_led           (qsfp_led_port_b),

      .b_mac_axis_mdata (b_mac_axis_mdata),
      .b_mac_axis_mkeep (b_mac_axis_mkeep),
      .b_mac_axis_musr  (b_mac_axis_musr),
      .b_mac_axis_mvalid(b_mac_axis_mvalid),
      .b_mac_axis_mlast (b_mac_axis_mlast),
      .b_mac_axis_mready(b_mac_axis_mready),

      .b_mac_axis_sdata (b_mac_axis_sdata),
      .b_mac_axis_skeep (b_mac_axis_skeep),
      .b_mac_axis_susr  (b_mac_axis_susr),
      .b_mac_axis_svalid(b_mac_axis_svalid),
      .b_mac_axis_slast (b_mac_axis_slast),
      .b_mac_axis_sready(b_mac_axis_sready),

      .b_ipv4_axis_mdata (b_ipv4_axis_mdata),
      .b_ipv4_axis_mkeep (b_ipv4_axis_mkeep),
      .b_ipv4_axis_musr  (),
      .b_ipv4_axis_mvalid(b_ipv4_axis_mvalid),
      .b_ipv4_axis_mlast (b_ipv4_axis_mlast),
      .b_ipv4_axis_mready(b_ipv4_axis_mready),

      .b_ipv4_axis_sdata (b_ipv4_axis_sdata),
      .b_ipv4_axis_skeep (b_ipv4_axis_skeep),
      .b_ipv4_axis_susr  (b_ipv4_axis_susr),
      .b_ipv4_axis_svalid(b_ipv4_axis_svalid),
      .b_ipv4_axis_slast (b_ipv4_axis_slast),
      .b_ipv4_axis_sready(b_ipv4_axis_sready),

      .b_icmp_axis_mdata (b_icmp_axis_mdata),
      .b_icmp_axis_mkeep (b_icmp_axis_mkeep),
      .b_icmp_axis_musr  (),
      .b_icmp_axis_mvalid(b_icmp_axis_mvalid),
      .b_icmp_axis_mlast (b_icmp_axis_mlast),
      .b_icmp_axis_mready(b_icmp_axis_mready),

      .b_icmp_axis_sdata (b_icmp_axis_sdata),
      .b_icmp_axis_skeep (b_icmp_axis_skeep),
      .b_icmp_axis_susr  (b_icmp_axis_susr),
      .b_icmp_axis_svalid(b_icmp_axis_svalid),
      .b_icmp_axis_slast (b_icmp_axis_slast),
      .b_icmp_axis_sready(b_icmp_axis_sready),

      .b_ipv6_axis_mdata (b_ipv6_axis_mdata),
      .b_ipv6_axis_mkeep (b_ipv6_axis_mkeep),
      .b_ipv6_axis_musr  (),
      .b_ipv6_axis_mvalid(b_ipv6_axis_mvalid),
      .b_ipv6_axis_mlast (b_ipv6_axis_mlast),
      .b_ipv6_axis_mready(b_ipv6_axis_mready),

      .b_ipv6_axis_sdata (b_ipv6_axis_sdata),
      .b_ipv6_axis_skeep (b_ipv6_axis_skeep),
      .b_ipv6_axis_susr  (b_ipv6_axis_susr),
      .b_ipv6_axis_svalid(b_ipv6_axis_svalid),
      .b_ipv6_axis_slast (b_ipv6_axis_slast),
      .b_ipv6_axis_sready(b_ipv6_axis_sready),

      .b_udp_ipv4_axis_mdata (b_udp_ipv4_axis_mdata),
      .b_udp_ipv4_axis_mkeep (b_udp_ipv4_axis_mkeep),
      .b_udp_ipv4_axis_musr  (),
      .b_udp_ipv4_axis_mvalid(b_udp_ipv4_axis_mvalid),
      .b_udp_ipv4_axis_mlast (b_udp_ipv4_axis_mlast),
      .b_udp_ipv4_axis_mready(b_udp_ipv4_axis_mready),

      .b_udp_ipv4_axis_sdata (b_udp_ipv4_axis_sdata),
      .b_udp_ipv4_axis_skeep (b_udp_ipv4_axis_skeep),
      .b_udp_ipv4_axis_susr  (b_udp_ipv4_axis_susr),
      .b_udp_ipv4_axis_svalid(b_udp_ipv4_axis_svalid),
      .b_udp_ipv4_axis_slast (b_udp_ipv4_axis_slast),
      .b_udp_ipv4_axis_sready(b_udp_ipv4_axis_sready),

      .b_udp_ipv6_axis_mdata (b_udp_ipv6_axis_mdata),
      .b_udp_ipv6_axis_mkeep (b_udp_ipv6_axis_mkeep),
      .b_udp_ipv6_axis_musr  (),
      .b_udp_ipv6_axis_mvalid(b_udp_ipv6_axis_mvalid),
      .b_udp_ipv6_axis_mlast (b_udp_ipv6_axis_mlast),
      .b_udp_ipv6_axis_mready(b_udp_ipv6_axis_mready),

      .b_udp_ipv6_axis_sdata (b_udp_ipv6_axis_sdata),
      .b_udp_ipv6_axis_skeep (b_udp_ipv6_axis_skeep),
      .b_udp_ipv6_axis_susr  (b_udp_ipv6_axis_susr),
      .b_udp_ipv6_axis_svalid(b_udp_ipv6_axis_svalid),
      .b_udp_ipv6_axis_slast (b_udp_ipv6_axis_slast),
      .b_udp_ipv6_axis_sready(b_udp_ipv6_axis_sready)
  );

  // A口静态通道绑定
  //// 未测试接收通道持续接收。
  assign a_ipv4_axis_mready[0] = 1'b1;  // 协议 0xFD
  assign a_ipv6_axis_mready[0] = 1'b1;  // 原IPv6 UDP档，当前由内部UDP接收
  assign a_udp_ipv4_axis_mready[2:1] = 2'b11;
  assign a_udp_ipv6_axis_mready[2:1] = 2'b11;
  //// 空闲发送通道关闭。
  assign a_ipv4_axis_sdata[511:0] = 512'd0;
  assign a_ipv4_axis_skeep[63:0] = 64'd0;
  assign a_ipv4_axis_svalid[0] = 1'b0;
  assign a_ipv4_axis_slast[0] = 1'b0;
  assign a_udp_ipv4_axis_sdata[4095:1024] = 3072'd0;
  assign a_udp_ipv4_axis_skeep[511:128] = 384'd0;
  assign a_udp_ipv4_axis_svalid[7:2] = 6'd0;
  assign a_udp_ipv4_axis_slast[7:2] = 6'd0;
  //// 发送usr。
  assign a_mac_axis_susr = {PRIO_FB, PRIO_MAC88B5_A};
  assign a_ipv4_axis_susr = {PRIO_FB, PRIO_IP06_A, PRIO_OSPF_A, 4'd0};
  assign a_icmp_axis_susr = PRIO_ICMP_A;
  assign a_ipv6_axis_susr = {PRIO_OSPFV3_A, PRIO_ICMPV6_A, PRIO_FB};
  assign a_udp_ipv4_axis_susr = {648'd0, UDP_USR_FB_A, UDP_USR_DATA_A};
  assign a_udp_ipv6_axis_susr = {UDP_IPV6_USR_FB_A, UDP_IPV6_USR_DATA_A};

  // B口静态通道绑定
  //// 未测试接收通道持续接收。
  assign b_ipv4_axis_mready[1] = 1'b1;  // 协议 0xFD
  assign b_ipv6_axis_mready[0] = 1'b1;  // 原IPv6 UDP档，当前由内部UDP接收
  assign b_udp_ipv4_axis_mready[2:1] = 2'b11;
  assign b_udp_ipv6_axis_mready[2:1] = 2'b11;
  //// 空闲发送通道关闭。
  assign b_ipv4_axis_sdata[511:0] = 512'd0;
  assign b_ipv4_axis_skeep[63:0] = 64'd0;
  assign b_ipv4_axis_svalid[0] = 1'b0;
  assign b_ipv4_axis_slast[0] = 1'b0;
  assign b_udp_ipv4_axis_sdata[2047:1024] = 1024'd0;
  assign b_udp_ipv4_axis_skeep[255:128] = 128'd0;
  assign b_udp_ipv4_axis_svalid[3:2] = 2'd0;
  assign b_udp_ipv4_axis_slast[3:2] = 2'd0;
  //// 发送usr。
  assign b_mac_axis_susr = {PRIO_FB, PRIO_MAC88B5_B, PRIO_MAC88B5_B};
  assign b_ipv4_axis_susr = {PRIO_FB, PRIO_IP06_B, PRIO_OSPF_B, 4'd0};
  assign b_icmp_axis_susr = PRIO_ICMP_B;
  assign b_ipv6_axis_susr = {PRIO_OSPFV3_B, PRIO_ICMPV6_B, PRIO_FB};
  assign b_udp_ipv4_axis_susr = {216'd0, UDP_USR_FB_B, UDP_USR_DATA_B};
  assign b_udp_ipv6_axis_susr = {UDP_IPV6_USR_FB_B, UDP_IPV6_USR_DATA_B};

  // A口发送、B口校验
  //// UDP业务流
  ////// A 口 UDP 业务流(端口2) -> 口B 区间[0,8]
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (320'd0)           // UDP: 纯载荷(头由 DUT 按 usr 生成)
  ) u_ta_udp (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_udp),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_udp_ipv4_axis_sdata[0*512+:512]),
      .axis_mkeep (a_udp_ipv4_axis_skeep[0*64+:64]),
      .axis_mvalid(a_udp_ipv4_axis_svalid[0]),
      .axis_mlast (a_udp_ipv4_axis_slast[0]),
      .axis_mready(a_udp_ipv4_axis_sready[0]),

      .axis_sdata (b_udp_ipv4_axis_mdata[0*512+:512]),
      .axis_skeep (b_udp_ipv4_axis_mkeep[0*64+:64]),
      .axis_svalid(b_udp_ipv4_axis_mvalid[0]),
      .axis_slast (b_udp_ipv4_axis_mlast[0]),
      .axis_sready(b_udp_ipv4_axis_mready[0])
  );
  //// A口ICMPv4 TX发送Echo Reply，B口ICMPv4 RX校验数据和包长。
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP_ICMP_A)
  ) u_ta_icmp (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_icmp),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_icmp_axis_sdata),
      .axis_mkeep (a_icmp_axis_skeep),
      .axis_mvalid(a_icmp_axis_svalid),
      .axis_mlast (a_icmp_axis_slast),
      .axis_mready(a_icmp_axis_sready),

      .axis_sdata (b_icmp_axis_mdata),
      .axis_skeep (b_icmp_axis_mkeep),
      .axis_svalid(b_icmp_axis_mvalid),
      .axis_slast (b_icmp_axis_mlast),
      .axis_sready(b_icmp_axis_mready)
  );
  //// IPv4业务流
  ////// A 口 IPv4-ospf -> 口B ch2(0x59)
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP_OSPF_A)
  ) u_ta_ospf (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_ospf),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_ipv4_axis_sdata[1*512+:512]),
      .axis_mkeep (a_ipv4_axis_skeep[1*64+:64]),
      .axis_mvalid(a_ipv4_axis_svalid[1]),
      .axis_mlast (a_ipv4_axis_slast[1]),
      .axis_mready(a_ipv4_axis_sready[1]),

      .axis_sdata (b_ipv4_axis_mdata[2*512+:512]),
      .axis_skeep (b_ipv4_axis_mkeep[2*64+:64]),
      .axis_svalid(b_ipv4_axis_mvalid[2]),
      .axis_slast (b_ipv4_axis_mlast[2]),
      .axis_sready(b_ipv4_axis_mready[2])
  );
  ////// A 口 IPv4-协议0x06 -> 口B ch0(0x06)
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP_06_A)
  ) u_ta_ipv4_06 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_ipv4_06),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_ipv4_axis_sdata[2*512+:512]),
      .axis_mkeep (a_ipv4_axis_skeep[2*64+:64]),
      .axis_mvalid(a_ipv4_axis_svalid[2]),
      .axis_mlast (a_ipv4_axis_slast[2]),
      .axis_mready(a_ipv4_axis_sready[2]),

      .axis_sdata (b_ipv4_axis_mdata[0*512+:512]),
      .axis_skeep (b_ipv4_axis_mkeep[0*64+:64]),
      .axis_svalid(b_ipv4_axis_mvalid[0]),
      .axis_slast (b_ipv4_axis_mlast[0]),
      .axis_sready(b_ipv4_axis_mready[0])
  );
  //// MAC业务流
  ////// A 口 MAC-自定义类型 0x88B5 -> 口B ch0(0x88B5)
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_MAC_88B5_A)
  ) u_ta_mac_88b5 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_mac_88b5),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_mac_axis_sdata[0*512+:512]),
      .axis_mkeep (a_mac_axis_skeep[0*64+:64]),
      .axis_mvalid(a_mac_axis_svalid[0]),
      .axis_mlast (a_mac_axis_slast[0]),
      .axis_mready(a_mac_axis_sready[0]),

      .axis_sdata (b_mac_axis_mdata[0*512+:512]),
      .axis_skeep (b_mac_axis_mkeep[0*64+:64]),
      .axis_svalid(b_mac_axis_mvalid[0]),
      .axis_slast (b_mac_axis_mlast[0]),
      .axis_sready(b_mac_axis_mready[0])
  );
  //// IPv6业务流
  ////// A 口 IPv6-icmpv6 -> 口B ch2(0x3A)
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP6_ICMP_A)
  ) u_ta_ip6icmp (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_ip6icmp),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_ipv6_axis_sdata[1*512+:512]),
      .axis_mkeep (a_ipv6_axis_skeep[1*64+:64]),
      .axis_mvalid(a_ipv6_axis_svalid[1]),
      .axis_mlast (a_ipv6_axis_slast[1]),
      .axis_mready(a_ipv6_axis_sready[1]),

      .axis_sdata (b_ipv6_axis_mdata[2*512+:512]),
      .axis_skeep (b_ipv6_axis_mkeep[2*64+:64]),
      .axis_svalid(b_ipv6_axis_mvalid[2]),
      .axis_slast (b_ipv6_axis_mlast[2]),
      .axis_sready(b_ipv6_axis_mready[2])
  );
  ////// A 口 IPv6-ospfv3 -> 口B ch1(0x59)
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP6_OSPF_A)
  ) u_ta_ip6ospf (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_ip6ospf),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_ipv6_axis_sdata[2*512+:512]),
      .axis_mkeep (a_ipv6_axis_skeep[2*64+:64]),
      .axis_mvalid(a_ipv6_axis_svalid[2]),
      .axis_mlast (a_ipv6_axis_slast[2]),
      .axis_mready(a_ipv6_axis_sready[2]),

      .axis_sdata (b_ipv6_axis_mdata[1*512+:512]),
      .axis_skeep (b_ipv6_axis_mkeep[1*64+:64]),
      .axis_svalid(b_ipv6_axis_mvalid[1]),
      .axis_slast (b_ipv6_axis_mlast[1]),
      .axis_sready(b_ipv6_axis_mready[1])
  );
  //// 默认通道探测
  ////// A 发 0x88DD(两口字典都无) -> 口B MAC 兜底档
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_MAC_FB_A)
  ) u_ta_fb_mac (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_fb_mac),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_mac_axis_sdata[1*512+:512]),
      .axis_mkeep (a_mac_axis_skeep[1*64+:64]),
      .axis_mvalid(a_mac_axis_svalid[1]),
      .axis_mlast (a_mac_axis_slast[1]),
      .axis_mready(a_mac_axis_sready[1]),

      .axis_sdata (b_mac_axis_mdata[1*512+:512]),
      .axis_skeep (b_mac_axis_mkeep[1*64+:64]),
      .axis_svalid(b_mac_axis_mvalid[1]),
      .axis_slast (b_mac_axis_mlast[1]),
      .axis_sready(b_mac_axis_mready[1])
  );
  ////// A 发 IPv4 协议0x2F(未匹配) -> 口B IPv4 兜底档
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP_FB_A)
  ) u_ta_fb_ipv4 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_fb_ipv4),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_ipv4_axis_sdata[3*512+:512]),
      .axis_mkeep (a_ipv4_axis_skeep[3*64+:64]),
      .axis_mvalid(a_ipv4_axis_svalid[3]),
      .axis_mlast (a_ipv4_axis_slast[3]),
      .axis_mready(a_ipv4_axis_sready[3]),

      .axis_sdata (b_ipv4_axis_mdata[3*512+:512]),
      .axis_skeep (b_ipv4_axis_mkeep[3*64+:64]),
      .axis_svalid(b_ipv4_axis_mvalid[3]),
      .axis_slast (b_ipv4_axis_mlast[3]),
      .axis_sready(b_ipv4_axis_mready[3])
  );
  ////// A 发 IPv6 NH=0x06(未匹配) -> 口B IPv6 兜底档
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP6_FB_A)
  ) u_ta_fb_ipv6 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_fb_ipv6),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_ipv6_axis_sdata[0*512+:512]),
      .axis_mkeep (a_ipv6_axis_skeep[0*64+:64]),
      .axis_mvalid(a_ipv6_axis_svalid[0]),
      .axis_mlast (a_ipv6_axis_slast[0]),
      .axis_mready(a_ipv6_axis_sready[0]),

      .axis_sdata (b_ipv6_axis_mdata[3*512+:512]),
      .axis_skeep (b_ipv6_axis_mkeep[3*64+:64]),
      .axis_svalid(b_ipv6_axis_mvalid[3]),
      .axis_slast (b_ipv6_axis_mlast[3]),
      .axis_sready(b_ipv6_axis_mready[3])
  );
  ////// A 发 UDP 端口0x1234(不在区间) -> 口B UDP 兜底档
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (320'd0)           // UDP: 纯载荷
  ) u_ta_fb_udp (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_fb_udp),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_udp_ipv4_axis_sdata[1*512+:512]),
      .axis_mkeep (a_udp_ipv4_axis_skeep[1*64+:64]),
      .axis_mvalid(a_udp_ipv4_axis_svalid[1]),
      .axis_mlast (a_udp_ipv4_axis_slast[1]),
      .axis_mready(a_udp_ipv4_axis_sready[1]),

      .axis_sdata (b_udp_ipv4_axis_mdata[3*512+:512]),
      .axis_skeep (b_udp_ipv4_axis_mkeep[3*64+:64]),
      .axis_svalid(b_udp_ipv4_axis_mvalid[3]),
      .axis_slast (b_udp_ipv4_axis_mlast[3]),
      .axis_sready(b_udp_ipv4_axis_mready[3])
  );

  // B口发送、A口校验
  //// UDP业务流
  ////// B 口 UDP 业务流(端口2) -> 口A 区间[0,8]
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (320'd0)           // UDP: 纯载荷
  ) u_tb_udp (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_udp),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_udp_ipv4_axis_sdata[0*512+:512]),
      .axis_mkeep (b_udp_ipv4_axis_skeep[0*64+:64]),
      .axis_mvalid(b_udp_ipv4_axis_svalid[0]),
      .axis_mlast (b_udp_ipv4_axis_slast[0]),
      .axis_mready(b_udp_ipv4_axis_sready[0]),

      .axis_sdata (a_udp_ipv4_axis_mdata[0*512+:512]),
      .axis_skeep (a_udp_ipv4_axis_mkeep[0*64+:64]),
      .axis_svalid(a_udp_ipv4_axis_mvalid[0]),
      .axis_slast (a_udp_ipv4_axis_mlast[0]),
      .axis_sready(a_udp_ipv4_axis_mready[0])
  );
  //// B口ICMPv4 TX发送Echo Reply，A口ICMPv4 RX校验数据和包长。
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP_ICMP_B)
  ) u_tb_icmp (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_icmp),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_icmp_axis_sdata),
      .axis_mkeep (b_icmp_axis_skeep),
      .axis_mvalid(b_icmp_axis_svalid),
      .axis_mlast (b_icmp_axis_slast),
      .axis_mready(b_icmp_axis_sready),

      .axis_sdata (a_icmp_axis_mdata),
      .axis_skeep (a_icmp_axis_mkeep),
      .axis_svalid(a_icmp_axis_mvalid),
      .axis_slast (a_icmp_axis_mlast),
      .axis_sready(a_icmp_axis_mready)
  );
  //// IPv4业务流
  ////// B 口 IPv4-ospf -> 口A ch1(0x59)
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP_OSPF_B)
  ) u_tb_ospf (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_ospf),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_ipv4_axis_sdata[1*512+:512]),
      .axis_mkeep (b_ipv4_axis_skeep[1*64+:64]),
      .axis_mvalid(b_ipv4_axis_svalid[1]),
      .axis_mlast (b_ipv4_axis_slast[1]),
      .axis_mready(b_ipv4_axis_sready[1]),

      .axis_sdata (a_ipv4_axis_mdata[1*512+:512]),
      .axis_skeep (a_ipv4_axis_mkeep[1*64+:64]),
      .axis_svalid(a_ipv4_axis_mvalid[1]),
      .axis_slast (a_ipv4_axis_mlast[1]),
      .axis_sready(a_ipv4_axis_mready[1])
  );
  ////// B 口 IPv4-协议0x06 -> 口A ch2(0x06)
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP_06_B)
  ) u_tb_ipv4_06 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_ipv4_06),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_ipv4_axis_sdata[2*512+:512]),
      .axis_mkeep (b_ipv4_axis_skeep[2*64+:64]),
      .axis_mvalid(b_ipv4_axis_svalid[2]),
      .axis_mlast (b_ipv4_axis_slast[2]),
      .axis_mready(b_ipv4_axis_sready[2]),

      .axis_sdata (a_ipv4_axis_mdata[2*512+:512]),
      .axis_skeep (a_ipv4_axis_mkeep[2*64+:64]),
      .axis_svalid(a_ipv4_axis_mvalid[2]),
      .axis_slast (a_ipv4_axis_mlast[2]),
      .axis_sready(a_ipv4_axis_mready[2])
  );
  //// MAC业务流
  ////// B 口 MAC-自定义类型 0x88B5 -> 口A ch0(0x88B5)
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_MAC_88B5_B)
  ) u_tb_mac_88b5 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_mac_88b5),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_mac_axis_sdata[0*512+:512]),
      .axis_mkeep (b_mac_axis_skeep[0*64+:64]),
      .axis_mvalid(b_mac_axis_svalid[0]),
      .axis_mlast (b_mac_axis_slast[0]),
      .axis_mready(b_mac_axis_sready[0]),

      .axis_sdata (a_mac_axis_mdata[0*512+:512]),
      .axis_skeep (a_mac_axis_mkeep[0*64+:64]),
      .axis_svalid(a_mac_axis_mvalid[0]),
      .axis_slast (a_mac_axis_mlast[0]),
      .axis_sready(a_mac_axis_mready[0])
  );
  ////// B 口 MAC-自定义类型 0x88CC -> 口A ch1(0x88CC, 仅 A 配了该档)
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_MAC_88CC_B)
  ) u_tb_mac_88cc (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_mac_88cc),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_mac_axis_sdata[1*512+:512]),
      .axis_mkeep (b_mac_axis_skeep[1*64+:64]),
      .axis_mvalid(b_mac_axis_svalid[1]),
      .axis_mlast (b_mac_axis_slast[1]),
      .axis_mready(b_mac_axis_sready[1]),

      .axis_sdata (a_mac_axis_mdata[1*512+:512]),
      .axis_skeep (a_mac_axis_mkeep[1*64+:64]),
      .axis_svalid(a_mac_axis_mvalid[1]),
      .axis_slast (a_mac_axis_mlast[1]),
      .axis_sready(a_mac_axis_mready[1])
  );
  //// IPv6业务流
  ////// B 口 IPv6-icmpv6 -> 口A ch1(0x3A)
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP6_ICMP_B)
  ) u_tb_ip6icmp (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_ip6icmp),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_ipv6_axis_sdata[1*512+:512]),
      .axis_mkeep (b_ipv6_axis_skeep[1*64+:64]),
      .axis_mvalid(b_ipv6_axis_svalid[1]),
      .axis_mlast (b_ipv6_axis_slast[1]),
      .axis_mready(b_ipv6_axis_sready[1]),

      .axis_sdata (a_ipv6_axis_mdata[1*512+:512]),
      .axis_skeep (a_ipv6_axis_mkeep[1*64+:64]),
      .axis_svalid(a_ipv6_axis_mvalid[1]),
      .axis_slast (a_ipv6_axis_mlast[1]),
      .axis_sready(a_ipv6_axis_mready[1])
  );
  ////// B 口 IPv6-ospfv3 -> 口A ch2(0x59)
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP6_OSPF_B)
  ) u_tb_ip6ospf (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_ip6ospf),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_ipv6_axis_sdata[2*512+:512]),
      .axis_mkeep (b_ipv6_axis_skeep[2*64+:64]),
      .axis_mvalid(b_ipv6_axis_svalid[2]),
      .axis_mlast (b_ipv6_axis_slast[2]),
      .axis_mready(b_ipv6_axis_sready[2]),

      .axis_sdata (a_ipv6_axis_mdata[2*512+:512]),
      .axis_skeep (a_ipv6_axis_mkeep[2*64+:64]),
      .axis_svalid(a_ipv6_axis_mvalid[2]),
      .axis_slast (a_ipv6_axis_mlast[2]),
      .axis_sready(a_ipv6_axis_mready[2])
  );
  //// 默认通道探测
  ////// B 发 0x88DD(两口字典都无) -> 口A MAC 兜底档
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_MAC_FB_B)
  ) u_tb_fb_mac (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_fb_mac),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_mac_axis_sdata[2*512+:512]),
      .axis_mkeep (b_mac_axis_skeep[2*64+:64]),
      .axis_mvalid(b_mac_axis_svalid[2]),
      .axis_mlast (b_mac_axis_slast[2]),
      .axis_mready(b_mac_axis_sready[2]),

      .axis_sdata (a_mac_axis_mdata[2*512+:512]),
      .axis_skeep (a_mac_axis_mkeep[2*64+:64]),
      .axis_svalid(a_mac_axis_mvalid[2]),
      .axis_slast (a_mac_axis_mlast[2]),
      .axis_sready(a_mac_axis_mready[2])
  );
  ////// B 发 IPv4 协议0x2F(未匹配) -> 口A IPv4 兜底档
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP_FB_B)
  ) u_tb_fb_ipv4 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_fb_ipv4),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_ipv4_axis_sdata[3*512+:512]),
      .axis_mkeep (b_ipv4_axis_skeep[3*64+:64]),
      .axis_mvalid(b_ipv4_axis_svalid[3]),
      .axis_mlast (b_ipv4_axis_slast[3]),
      .axis_mready(b_ipv4_axis_sready[3]),

      .axis_sdata (a_ipv4_axis_mdata[3*512+:512]),
      .axis_skeep (a_ipv4_axis_mkeep[3*64+:64]),
      .axis_svalid(a_ipv4_axis_mvalid[3]),
      .axis_slast (a_ipv4_axis_mlast[3]),
      .axis_sready(a_ipv4_axis_mready[3])
  );
  ////// B 发 IPv6 NH=0x06(未匹配) -> 口A IPv6 兜底档
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (HDR_IP6_FB_B)
  ) u_tb_fb_ipv6 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_fb_ipv6),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_ipv6_axis_sdata[0*512+:512]),
      .axis_mkeep (b_ipv6_axis_skeep[0*64+:64]),
      .axis_mvalid(b_ipv6_axis_svalid[0]),
      .axis_mlast (b_ipv6_axis_slast[0]),
      .axis_mready(b_ipv6_axis_sready[0]),

      .axis_sdata (a_ipv6_axis_mdata[3*512+:512]),
      .axis_skeep (a_ipv6_axis_mkeep[3*64+:64]),
      .axis_svalid(a_ipv6_axis_mvalid[3]),
      .axis_slast (a_ipv6_axis_mlast[3]),
      .axis_sready(a_ipv6_axis_mready[3])
  );
  ////// B 发 UDP 端口0x1234(不在区间) -> 口A UDP 兜底档
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (320'd0)           // UDP: 纯载荷
  ) u_tb_fb_udp (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_fb_udp),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_udp_ipv4_axis_sdata[1*512+:512]),
      .axis_mkeep (b_udp_ipv4_axis_skeep[1*64+:64]),
      .axis_mvalid(b_udp_ipv4_axis_svalid[1]),
      .axis_mlast (b_udp_ipv4_axis_slast[1]),
      .axis_mready(b_udp_ipv4_axis_sready[1]),

      .axis_sdata (a_udp_ipv4_axis_mdata[3*512+:512]),
      .axis_skeep (a_udp_ipv4_axis_mkeep[3*64+:64]),
      .axis_svalid(a_udp_ipv4_axis_mvalid[3]),
      .axis_slast (a_udp_ipv4_axis_mlast[3]),
      .axis_sready(a_udp_ipv4_axis_mready[3])
  );

  // UDP(IPv6)业务与兜底测试
  //// A发端口2 → B档0
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (320'd0)           // UDP: 纯载荷
  ) u_ta_udp_ipv6 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_udp_ipv6),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_udp_ipv6_axis_sdata[0*512+:512]),
      .axis_mkeep (a_udp_ipv6_axis_skeep[0*64+:64]),
      .axis_mvalid(a_udp_ipv6_axis_svalid[0]),
      .axis_mlast (a_udp_ipv6_axis_slast[0]),
      .axis_mready(a_udp_ipv6_axis_sready[0]),

      .axis_sdata (b_udp_ipv6_axis_mdata[0*512+:512]),
      .axis_skeep (b_udp_ipv6_axis_mkeep[0*64+:64]),
      .axis_svalid(b_udp_ipv6_axis_mvalid[0]),
      .axis_slast (b_udp_ipv6_axis_mlast[0]),
      .axis_sready(b_udp_ipv6_axis_mready[0])
  );
  //// B发端口2 → A档0
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (320'd0)           // UDP: 纯载荷
  ) u_tb_udp_ipv6 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_udp_ipv6),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_udp_ipv6_axis_sdata[0*512+:512]),
      .axis_mkeep (b_udp_ipv6_axis_skeep[0*64+:64]),
      .axis_mvalid(b_udp_ipv6_axis_svalid[0]),
      .axis_mlast (b_udp_ipv6_axis_slast[0]),
      .axis_mready(b_udp_ipv6_axis_sready[0]),

      .axis_sdata (a_udp_ipv6_axis_mdata[0*512+:512]),
      .axis_skeep (a_udp_ipv6_axis_mkeep[0*64+:64]),
      .axis_svalid(a_udp_ipv6_axis_mvalid[0]),
      .axis_slast (a_udp_ipv6_axis_mlast[0]),
      .axis_sready(a_udp_ipv6_axis_mready[0])
  );
  //// A发端口0x1234 → B兜底
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (320'd0)           // UDP: 纯载荷
  ) u_ta_fb_udp_ipv6 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_a_fb_udp_ipv6),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (a_udp_ipv6_axis_sdata[1*512+:512]),
      .axis_mkeep (a_udp_ipv6_axis_skeep[1*64+:64]),
      .axis_mvalid(a_udp_ipv6_axis_svalid[1]),
      .axis_mlast (a_udp_ipv6_axis_slast[1]),
      .axis_mready(a_udp_ipv6_axis_sready[1]),

      .axis_sdata (b_udp_ipv6_axis_mdata[3*512+:512]),
      .axis_skeep (b_udp_ipv6_axis_mkeep[3*64+:64]),
      .axis_svalid(b_udp_ipv6_axis_mvalid[3]),
      .axis_slast (b_udp_ipv6_axis_mlast[3]),
      .axis_sready(b_udp_ipv6_axis_mready[3])
  );
  //// B发端口0x1234 → A兜底
  subsys_100g_tester #(
      .AXIS_WIDTH    (AXIS_WIDTH),
      .PKT_LEN_BEATS (PKT_LEN_BEATS),
      .ONE_SEC_CYCLES(ONE_SEC_CYCLES),
      .HDR_BYTES     (320'd0)           // UDP: 纯载荷
  ) u_tb_fb_udp_ipv6 (
      .clk           (clk_400m),
      .rst           (usr_rst),
      .test_enable   (en_b_fb_udp_ipv6),
      .cfg_gap_cycles(cfg_gap_cycles),

      .axis_mdata (b_udp_ipv6_axis_sdata[1*512+:512]),
      .axis_mkeep (b_udp_ipv6_axis_skeep[1*64+:64]),
      .axis_mvalid(b_udp_ipv6_axis_svalid[1]),
      .axis_mlast (b_udp_ipv6_axis_slast[1]),
      .axis_mready(b_udp_ipv6_axis_sready[1]),

      .axis_sdata (a_udp_ipv6_axis_mdata[3*512+:512]),
      .axis_skeep (a_udp_ipv6_axis_mkeep[3*64+:64]),
      .axis_svalid(a_udp_ipv6_axis_mvalid[3]),
      .axis_slast (a_udp_ipv6_axis_mlast[3]),
      .axis_sready(a_udp_ipv6_axis_mready[3])
  );

  // VIO测试使能
  vio_enable u_test_vio_enable (
      .clk        (clk_400m),
      .probe_out0 (en_a_udp),          // A 口 UDP(端口2)
      .probe_out1 (en_a_icmp),         // A 口 ICMPv4 TX
      .probe_out2 (en_a_ospf),         // A 口 IPv4-ospf
      .probe_out3 (en_a_ipv4_06),      // A 口 IPv4-协议0x06
      .probe_out4 (en_a_mac_88b5),     // A 口 MAC-自定义0x88B5
      .probe_out5 (en_b_udp),          // B 口 UDP(端口2)
      .probe_out6 (en_b_icmp),         // B 口 ICMPv4 TX
      .probe_out7 (en_b_ospf),         // B 口 IPv4-ospf
      .probe_out8 (en_b_ipv4_06),      // B 口 IPv4-协议0x06
      .probe_out9 (en_b_mac_88b5),     // B 口 MAC-自定义0x88B5
      .probe_out10(en_a_ip6icmp),      // A 口 IPv6-icmpv6
      .probe_out11(en_a_ip6ospf),      // A 口 IPv6-ospfv3
      .probe_out12(en_b_ip6icmp),      // B 口 IPv6-icmpv6
      .probe_out13(en_b_ip6ospf),      // B 口 IPv6-ospfv3
      .probe_out14(en_a_fb_mac),       // A 发 MAC兜底探测(0x88DD)->B兜底档
      .probe_out15(en_a_fb_ipv4),      // A 发 IPv4兜底探测(0x2F)->B兜底档
      .probe_out16(en_a_fb_ipv6),      // A 发 IPv6兜底探测(NH=06)->B兜底档
      .probe_out17(en_a_fb_udp),       // A 发 UDP兜底探测(端口0x1234)->B兜底档
      .probe_out18(en_b_mac_88cc),     // B 发 MAC-自定义0x88CC->A ch1
      .probe_out19(en_b_fb_mac),       // B 发 MAC兜底探测->A兜底档
      .probe_out20(en_b_fb_ipv4),      // B 发 IPv4兜底探测->A兜底档
      .probe_out21(en_b_fb_ipv6),      // B 发 IPv6兜底探测->A兜底档
      .probe_out22(en_b_fb_udp),       // B 发 UDP兜底探测->A兜底档
      .probe_out23(cfg_gap_cycles),    // 共享包间隔，默认0拍
      .probe_out24(en_a_udp_ipv6),
      .probe_out25(en_b_udp_ipv6),
      .probe_out26(en_a_fb_udp_ipv6),
      .probe_out27(en_b_fb_udp_ipv6)
  );

endmodule
`resetall
