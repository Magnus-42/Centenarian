// -----------------------------------------------------------------------------
// File Name   : eth_stack_port.v
// Module Name : eth_stack_port
// Author      : Lixintao
// Created     : 2026-11-19
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 连接单网口链路层、IP、ARP、ICMPv4、UDP和配置。
// Note        : 配置通路为本口UDP/IPv4；物理口封装给出固定通道数及默认值。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module eth_stack_port #(
    // 物理口选择
    parameter integer CmacSelect = 0,

    // 用户通道数量
    parameter  integer MacRxCount     = 2,
    parameter  integer MacTxCount     = 2,
    parameter  integer Ipv4RxCount    = 3,
    parameter  integer Ipv4TxCount    = 4,
    parameter  integer Ipv6RxCount    = 3,
    parameter  integer Ipv6TxCount    = 3,
    parameter  integer UdpIpv4RxCount = 3,
    parameter  integer UdpIpv6RxCount = 3,
    parameter  integer UdpIpv4TxCount = 8,
    parameter  integer UdpIpv6TxCount = 2,
    localparam integer IcmpRxCount    = 1,
    parameter  integer IcmpTxCount    = 1,

    // 地址表规模
    parameter integer LocalIpv4Count = 3,
    parameter integer SrcIpv6Count   = 2,
    parameter integer DstIpv6Count   = 3,

    // 时钟与请求位宽
    parameter  integer InitClkFreqHz     = 100000000,
    parameter  integer ClkFreqHz         = 400000000,
    parameter  integer ReqWidth          = 4,
    localparam integer MacTxUsrWidth     = 112 + ReqWidth,
    localparam integer Ipv4TxUsrWidth    = 160 + ReqWidth,
    localparam integer Ipv6TxUsrWidth    = 320 + ReqWidth,
    localparam integer MacRxUsrWidth     = 113,
    localparam integer Ipv4RxUsrWidth    = 273,
    localparam integer Ipv6RxUsrWidth    = 433,
    localparam integer IcmpRxUsrWidth    = 337,
    localparam integer UdpIpv4RxUsrWidth = 337,
    localparam integer UdpIpv6RxUsrWidth = 497,
    localparam integer IcmpTxUsrWidth    = 224 + ReqWidth,
    localparam integer UdpTxUsrWidth     = 224 + ReqWidth,
    localparam integer UdpIpv6TxUsrWidth = 384 + ReqWidth,

    // 固定接收字典
    parameter [16*MacRxCount-1:0] MacTypeDict  = {16'hcc88, 16'hb588},
    parameter [8*Ipv4RxCount-1:0] Ipv4TypeDict = {8'h06, 8'h59, 8'hfd},
    parameter [8*Ipv6RxCount-1:0] Ipv6TypeDict = {8'h59, 8'h3a, 8'h11},

    // 管理地址与路由
    parameter [47:0] MgmtMac        = 48'h010000_311900,
    parameter [31:0] MgmtGatewayIp  = 32'h0101_a8c0,
    parameter [31:0] MgmtSubnetMask = 32'h00ff_ffff,

    // IPv4默认配置
    parameter [32*LocalIpv4Count-1:0] DefaultLocalIp    = 32'h1401_a8c0,
    parameter [48*LocalIpv4Count-1:0] DefaultLocalMac   = 'd0,
    parameter [32*LocalIpv4Count-1:0] DefaultGatewayIp  = 'd0,
    parameter [32*LocalIpv4Count-1:0] DefaultSubnetMask = 'd0,

    // IPv6默认配置
    parameter [128*SrcIpv6Count-1:0] DefaultSrcIpv6 = 'd0,
    parameter [ 48*SrcIpv6Count-1:0] DefaultSrcMac  = 'd0,
    parameter [128*DstIpv6Count-1:0] DefaultDstIpv6 = 'd0,
    parameter [ 48*DstIpv6Count-1:0] DefaultDstMac  = 'd0,

    // UDP接收端口范围
    parameter [32*UdpIpv4RxCount-1:0] DefaultUdpIpv4Range = 'd0,
    parameter [32*UdpIpv6RxCount-1:0] DefaultUdpIpv6Range = 'd0,

    // ARP与ICMP策略
    parameter integer                        ArpStartupDelayMs   = 15000,
    parameter integer                        PendingTimeWidth    = 24,
    parameter         [PendingTimeWidth-1:0] DefaultPendingTime  = 24'd1000,
    parameter         [        ReqWidth-1:0] DefaultArpPriority  = 4'd15,
    parameter         [        ReqWidth-1:0] DefaultIcmpPriority = 4'd13,

    // 管理IP与端口默认值
    parameter [        31:0] DefaultMgmtIpv4Addr = 32'h0901_a8c0,
    parameter [        15:0] DefaultMgmtUdpPort  = 16'hc0de,
    parameter [ReqWidth-1:0] DefaultMgmtPriority = 4'd14
) (
    // 时钟与复位
    input wire init_clk,
    input wire clk,
    input wire rst,
    input wire clk_locked,

    // GT接口
    output wire [3:0] gt_txp_out,
    output wire [3:0] gt_txn_out,
    input  wire [3:0] gt_rxp_in,
    input  wire [3:0] gt_rxn_in,
    input  wire       gt_ref_clk_p,
    input  wire       gt_ref_clk_n,

    // QSFP控制
    output wire qsfp_reset_n,
    output wire qsfp_low_power_mode,
    output wire qsfp_select_n,
    input  wire qsfp_present_n,
    output wire qsfp_led,
    output wire qsfp_gt_rst,

    // MAC接收
    output wire [          512*(MacRxCount+1)-1:0] mac_axis_mdata,
    output wire [           64*(MacRxCount+1)-1:0] mac_axis_mkeep,
    output wire [MacRxUsrWidth*(MacRxCount+1)-1:0] mac_axis_musr,
    output wire [              (MacRxCount+1)-1:0] mac_axis_mvalid,
    output wire [              (MacRxCount+1)-1:0] mac_axis_mlast,
    input  wire [              (MacRxCount+1)-1:0] mac_axis_mready,

    // MAC发送
    input  wire [        512*(MacTxCount)-1:0] mac_axis_sdata,
    input  wire [         64*(MacTxCount)-1:0] mac_axis_skeep,
    input  wire [MacTxUsrWidth*MacTxCount-1:0] mac_axis_susr,
    input  wire [              MacTxCount-1:0] mac_axis_svalid,
    input  wire [              MacTxCount-1:0] mac_axis_slast,
    output wire [              MacTxCount-1:0] mac_axis_sready,

    // IPv4接收
    output wire [           512*(Ipv4RxCount+1)-1:0] ipv4_axis_mdata,
    output wire [            64*(Ipv4RxCount+1)-1:0] ipv4_axis_mkeep,
    output wire [Ipv4RxUsrWidth*(Ipv4RxCount+1)-1:0] ipv4_axis_musr,
    output wire [               (Ipv4RxCount+1)-1:0] ipv4_axis_mvalid,
    output wire [               (Ipv4RxCount+1)-1:0] ipv4_axis_mlast,
    input  wire [               (Ipv4RxCount+1)-1:0] ipv4_axis_mready,

    // IPv4发送
    input  wire [         512*(Ipv4TxCount)-1:0] ipv4_axis_sdata,
    input  wire [          64*(Ipv4TxCount)-1:0] ipv4_axis_skeep,
    input  wire [Ipv4TxUsrWidth*Ipv4TxCount-1:0] ipv4_axis_susr,
    input  wire [               Ipv4TxCount-1:0] ipv4_axis_svalid,
    input  wire [               Ipv4TxCount-1:0] ipv4_axis_slast,
    output wire [               Ipv4TxCount-1:0] ipv4_axis_sready,

    // ICMPv4接收
    output wire [           512*IcmpRxCount-1:0] icmp_axis_mdata,
    output wire [            64*IcmpRxCount-1:0] icmp_axis_mkeep,
    output wire [IcmpRxUsrWidth*IcmpRxCount-1:0] icmp_axis_musr,
    output wire [               IcmpRxCount-1:0] icmp_axis_mvalid,
    output wire [               IcmpRxCount-1:0] icmp_axis_mlast,
    input  wire [               IcmpRxCount-1:0] icmp_axis_mready,

    // ICMPv4发送
    input  wire [           512*IcmpTxCount-1:0] icmp_axis_sdata,
    input  wire [            64*IcmpTxCount-1:0] icmp_axis_skeep,
    input  wire [IcmpTxUsrWidth*IcmpTxCount-1:0] icmp_axis_susr,
    input  wire [               IcmpTxCount-1:0] icmp_axis_svalid,
    input  wire [               IcmpTxCount-1:0] icmp_axis_slast,
    output wire [               IcmpTxCount-1:0] icmp_axis_sready,

    // IPv6接收
    output wire [           512*(Ipv6RxCount+1)-1:0] ipv6_axis_mdata,
    output wire [            64*(Ipv6RxCount+1)-1:0] ipv6_axis_mkeep,
    output wire [Ipv6RxUsrWidth*(Ipv6RxCount+1)-1:0] ipv6_axis_musr,
    output wire [               (Ipv6RxCount+1)-1:0] ipv6_axis_mvalid,
    output wire [               (Ipv6RxCount+1)-1:0] ipv6_axis_mlast,
    input  wire [               (Ipv6RxCount+1)-1:0] ipv6_axis_mready,

    // IPv6发送
    input  wire [         512*(Ipv6TxCount)-1:0] ipv6_axis_sdata,
    input  wire [          64*(Ipv6TxCount)-1:0] ipv6_axis_skeep,
    input  wire [Ipv6TxUsrWidth*Ipv6TxCount-1:0] ipv6_axis_susr,
    input  wire [               Ipv6TxCount-1:0] ipv6_axis_svalid,
    input  wire [               Ipv6TxCount-1:0] ipv6_axis_slast,
    output wire [               Ipv6TxCount-1:0] ipv6_axis_sready,

    // UDP(IPV4) 接收
    output wire [              512*(UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_mdata,
    output wire [               64*(UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_mkeep,
    output wire [UdpIpv4RxUsrWidth*(UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_musr,
    output wire [                  (UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_mvalid,
    output wire [                  (UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_mlast,
    input  wire [                  (UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_mready,

    // UDPP(IPV4) 发送
    input  wire [        512*(UdpIpv4TxCount)-1:0] udp_ipv4_axis_sdata,
    input  wire [         64*(UdpIpv4TxCount)-1:0] udp_ipv4_axis_skeep,
    input  wire [UdpTxUsrWidth*UdpIpv4TxCount-1:0] udp_ipv4_axis_susr,
    input  wire [              UdpIpv4TxCount-1:0] udp_ipv4_axis_svalid,
    input  wire [              UdpIpv4TxCount-1:0] udp_ipv4_axis_slast,
    output wire [              UdpIpv4TxCount-1:0] udp_ipv4_axis_sready,

    // UDP(IPv6) 接收
    output wire [              512*(UdpIpv6RxCount+1)-1:0] udp_ipv6_axis_mdata,
    output wire [               64*(UdpIpv6RxCount+1)-1:0] udp_ipv6_axis_mkeep,
    output wire [UdpIpv6RxUsrWidth*(UdpIpv6RxCount+1)-1:0] udp_ipv6_axis_musr,
    output wire [                  (UdpIpv6RxCount+1)-1:0] udp_ipv6_axis_mvalid,
    output wire [                  (UdpIpv6RxCount+1)-1:0] udp_ipv6_axis_mlast,
    input  wire [                  (UdpIpv6RxCount+1)-1:0] udp_ipv6_axis_mready,

    // UDP(IPv6) 发送
    input  wire [            512*(UdpIpv6TxCount)-1:0] udp_ipv6_axis_sdata,
    input  wire [             64*(UdpIpv6TxCount)-1:0] udp_ipv6_axis_skeep,
    input  wire [UdpIpv6TxUsrWidth*UdpIpv6TxCount-1:0] udp_ipv6_axis_susr,
    input  wire [                  UdpIpv6TxCount-1:0] udp_ipv6_axis_svalid,
    input  wire [                  UdpIpv6TxCount-1:0] udp_ipv6_axis_slast,
    output wire [                  UdpIpv6TxCount-1:0] udp_ipv6_axis_sready
);

  // MAC分流ARP、IPv4和IPv6，各协议连接用户通道。
  // UDP配置通道更新本口配置并读取业务状态。
  // 汇总GT复位，将链路状态同步到clk域。

  // 参数范围检查
  initial begin
    if (MacRxCount < 1 || MacTxCount < 1 || Ipv4RxCount < 1 || Ipv4TxCount < 1 || Ipv6RxCount < 1 ||
        Ipv6TxCount < 1 || UdpIpv4RxCount < 1 || UdpIpv4TxCount < 1 ||
        UdpIpv6RxCount < 1 || UdpIpv6TxCount < 1 || IcmpTxCount < 1 || ClkFreqHz < 1000) begin
      $display("错误：eth_stack_port：不支持的通道数量或时钟频率。");
      $finish;
    end
    if (ArpStartupDelayMs < 0) begin
      $display("错误：eth_stack_port：启动免费ARP延时不能为负数。");
      $finish;
    end
  end

  // 内部常量
  localparam integer AnnounceMaskWidth = LocalIpv4Count + 1;
  localparam integer ArpStartupCyclesPerMs = ClkFreqHz / 1000;
  localparam integer ArpStartupCycleCountWidth = (ArpStartupCyclesPerMs <= 1) ? 1 : $clog2(
      ArpStartupCyclesPerMs
  );
  localparam [ArpStartupCycleCountWidth-1:0] ArpStartupCycleLast = ArpStartupCyclesPerMs - 1;
  localparam integer ArpStartupMsCountWidth = (ArpStartupDelayMs <= 1) ? 1 : $clog2(
      ArpStartupDelayMs + 32'd1
  );

  // 链路复位和状态同步
  wire                                 gt_tx_arst;
  wire                                 gt_rx_arst;
  wire                                 gt_rx_link_up;
  (* ASYNC_REG = "TRUE" *)reg                                  link_up_d1;
  (* ASYNC_REG = "TRUE" *)reg                                  link_up_d2;

  // 本口配置
  //// IPv4地址配置
  wire [        32*LocalIpv4Count-1:0] cfg_local_ip;
  wire [        48*LocalIpv4Count-1:0] cfg_local_mac;
  wire [        32*LocalIpv4Count-1:0] cfg_gateway_ip;
  wire [        32*LocalIpv4Count-1:0] cfg_subnet_mask;
  //// IPv6地址配置
  wire [         128*SrcIpv6Count-1:0] cfg_src_ipv6;
  wire [          48*SrcIpv6Count-1:0] cfg_src_mac;
  wire [         128*DstIpv6Count-1:0] cfg_dst_ipv6;
  wire [          48*DstIpv6Count-1:0] cfg_dst_mac;
  //// UDP接收端口配置
  wire [        32*UdpIpv4RxCount-1:0] cfg_udp_ipv4_dst_port_range;
  wire [        32*UdpIpv6RxCount-1:0] cfg_udp_ipv6_dst_port_range;
  //// ARP与ICMP策略
  wire [         PendingTimeWidth-1:0] cfg_pending_time;
  wire [                 ReqWidth-1:0] cfg_arp_priority;
  wire [        AnnounceMaskWidth-1:0] cfg_arp_announce_mask;
  wire                                 cfg_arp_announce_valid;
  wire                                 cfg_arp_announce_ready;
  wire [                 ReqWidth-1:0] cfg_icmp_priority;
  //// 管理配置
  wire [                         31:0] cfg_mgmt_ipv4_addr;
  wire [                         15:0] cfg_mgmt_udp_port;
  wire [                         47:0] cfg_mgmt_mac;
  //// 清除命令
  wire                                 cfg_arp_clear_cache;
  wire                                 cfg_arp_clear_pending;
  wire                                 cfg_stat_clear;

  // 业务状态
  wire                                 stat_link_up;
  wire                                 stat_arp_rx_error;
  wire                                 stat_arp_ack_fifo_overflow_error;
  wire                                 stat_arp_pending_fifo_overflow_error;
  wire                                 stat_arp_query_src_not_local;
  wire                                 stat_arp_cache_clear_finish;
  wire                                 stat_arp_pending_clear_finish;
  wire                                 stat_ipv4_tx_drop;
  wire                                 stat_ipv6_tx_drop;
  wire                                 stat_icmp_ttl_error;

  // IPv4查询与ARP应答
  wire [                         31:0] query_src_ip;
  wire [                         31:0] query_dst_ip;
  wire                                 query_valid_pulse;
  wire [                         47:0] arp_dst_mac;
  wire [                         47:0] arp_src_mac;
  wire                                 arp_miss;
  wire                                 arp_valid;
  //// 免费ARP
  reg  [ArpStartupCycleCountWidth-1:0] arp_startup_cycle_count;
  reg  [   ArpStartupMsCountWidth-1:0] arp_startup_ms_count;
  wire                                 arp_startup_ms_tick;
  wire                                 arp_startup_delay_done;
  wire                                 arp_startup_take;
  reg                                  arp_startup_submitted;
  wire                                 arp_announce_valid;
  wire                                 arp_announce_ready;
  wire [        AnnounceMaskWidth-1:0] arp_announce_mask;

  // 帧通路
  //// ARP接收
  wire [                        511:0] arp_rx_data;
  wire [                         63:0] arp_rx_keep;
  wire [            MacRxUsrWidth-1:0] arp_rx_usr;
  wire                                 arp_rx_valid;
  wire                                 arp_rx_last;
  wire                                 arp_rx_ready;
  //// ARP发送
  wire [                        511:0] arp_tx_data;
  wire [                         63:0] arp_tx_keep;
  wire [            MacTxUsrWidth-1:0] arp_tx_usr;
  wire                                 arp_tx_valid;
  wire                                 arp_tx_last;
  wire                                 arp_tx_ready;
  //// IPv4以太网接收
  wire [                        511:0] ipv4_eth_rx_data;
  wire [                         63:0] ipv4_eth_rx_keep;
  wire [            MacRxUsrWidth-1:0] ipv4_eth_rx_usr;
  wire                                 ipv4_eth_rx_valid;
  wire                                 ipv4_eth_rx_last;
  wire                                 ipv4_eth_rx_ready;
  //// IPv4以太网发送
  wire [                        511:0] ipv4_eth_tx_data;
  wire [                         63:0] ipv4_eth_tx_keep;
  wire [            MacTxUsrWidth-1:0] ipv4_eth_tx_usr;
  wire                                 ipv4_eth_tx_valid;
  wire                                 ipv4_eth_tx_last;
  wire                                 ipv4_eth_tx_ready;
  //// IPv6以太网接收
  wire [                        511:0] ipv6_eth_rx_data;
  wire [                         63:0] ipv6_eth_rx_keep;
  wire [            MacRxUsrWidth-1:0] ipv6_eth_rx_usr;
  wire                                 ipv6_eth_rx_valid;
  wire                                 ipv6_eth_rx_last;
  wire                                 ipv6_eth_rx_ready;
  //// IPv6以太网发送
  wire [                        511:0] ipv6_eth_tx_data;
  wire [                         63:0] ipv6_eth_tx_keep;
  wire [            MacTxUsrWidth-1:0] ipv6_eth_tx_usr;
  wire                                 ipv6_eth_tx_valid;
  wire                                 ipv6_eth_tx_last;
  wire                                 ipv6_eth_tx_ready;
  //// UDP接收
  wire [                        511:0] ipv4_udp_rx_data;
  wire [                         63:0] ipv4_udp_rx_keep;
  wire [           Ipv4RxUsrWidth-1:0] ipv4_udp_rx_usr;
  wire                                 ipv4_udp_rx_valid;
  wire                                 ipv4_udp_rx_last;
  wire                                 ipv4_udp_rx_ready;
  //// UDP发送
  wire [                        511:0] ipv4_udp_tx_data;
  wire [                         63:0] ipv4_udp_tx_keep;
  wire [           Ipv4TxUsrWidth-1:0] ipv4_udp_tx_usr;
  wire                                 ipv4_udp_tx_valid;
  wire                                 ipv4_udp_tx_last;
  wire                                 ipv4_udp_tx_ready;
  //// UDP/IPv6接收
  wire [                        511:0] ipv6_udp_rx_data;
  wire [                         63:0] ipv6_udp_rx_keep;
  wire [           Ipv6RxUsrWidth-1:0] ipv6_udp_rx_usr;
  wire                                 ipv6_udp_rx_valid;
  wire                                 ipv6_udp_rx_last;
  wire                                 ipv6_udp_rx_ready;
  //// UDP/IPv6发送
  wire [                        511:0] ipv6_udp_tx_data;
  wire [                         63:0] ipv6_udp_tx_keep;
  wire [           Ipv6TxUsrWidth-1:0] ipv6_udp_tx_usr;
  wire                                 ipv6_udp_tx_valid;
  wire                                 ipv6_udp_tx_last;
  wire                                 ipv6_udp_tx_ready;
  //// ICMP接收
  wire [                        511:0] ipv4_icmp_rx_data;
  wire [                         63:0] ipv4_icmp_rx_keep;
  wire [           Ipv4RxUsrWidth-1:0] ipv4_icmp_rx_usr;
  wire                                 ipv4_icmp_rx_valid;
  wire                                 ipv4_icmp_rx_last;
  wire                                 ipv4_icmp_rx_ready;
  //// ICMP发送
  wire [                        511:0] ipv4_icmp_tx_data;
  wire [                         63:0] ipv4_icmp_tx_keep;
  wire [           Ipv4TxUsrWidth-1:0] ipv4_icmp_tx_usr;
  wire                                 ipv4_icmp_tx_valid;
  wire                                 ipv4_icmp_tx_last;
  wire                                 ipv4_icmp_tx_ready;
  //// 配置命令接收
  wire [                        511:0] cmd_rx_data;
  wire [                         63:0] cmd_rx_keep;
  wire [        UdpIpv4RxUsrWidth-1:0] cmd_rx_usr;
  wire                                 cmd_rx_valid;
  wire                                 cmd_rx_last;
  wire                                 cmd_rx_ready;
  //// 配置应答发送
  wire [                        511:0] cmd_tx_data;
  wire [                         63:0] cmd_tx_keep;
  wire [            UdpTxUsrWidth-1:0] cmd_tx_usr;
  wire                                 cmd_tx_valid;
  wire                                 cmd_tx_last;
  wire                                 cmd_tx_ready;

  // GT复位汇总
  assign qsfp_gt_rst = gt_tx_arst || gt_rx_arst;

  // 链路状态同步
  always @(posedge clk) begin
    if (rst) begin
      link_up_d1 <= 1'b0;
      link_up_d2 <= 1'b0;
    end else begin
      link_up_d1 <= gt_rx_link_up;
      link_up_d2 <= link_up_d1;
    end
  end
  assign stat_link_up = link_up_d2;

  // 免费ARP
  //// 链路持续就绪达到延时后公告全表，配置命令优先受理。
  assign arp_startup_ms_tick = arp_startup_cycle_count == ArpStartupCycleLast;
  assign arp_startup_delay_done =
      arp_startup_ms_count == ArpStartupDelayMs[ArpStartupMsCountWidth-1:0];
  assign arp_startup_take = !arp_startup_submitted && stat_link_up &&
      arp_startup_delay_done && !cfg_arp_announce_valid && arp_announce_ready;
  assign arp_announce_valid = cfg_arp_announce_valid || arp_startup_take;
  assign arp_announce_mask = arp_startup_take ? {AnnounceMaskWidth{1'b1}} : cfg_arp_announce_mask;
  assign cfg_arp_announce_ready = arp_announce_ready;
  always @(posedge clk) begin
    if (rst || !stat_link_up) begin
      arp_startup_cycle_count <= 'd0;
      arp_startup_ms_count    <= 'd0;
    end else if (!arp_startup_delay_done) begin
      if (arp_startup_ms_tick) begin
        arp_startup_cycle_count <= 'd0;
        arp_startup_ms_count    <= arp_startup_ms_count + 1'b1;
      end else begin
        arp_startup_cycle_count <= arp_startup_cycle_count + 1'b1;
      end
    end
  end
  always @(posedge clk) begin
    if (rst) arp_startup_submitted <= 1'b0;
    else if (arp_startup_take) arp_startup_submitted <= 1'b1;
  end

  // MAC：用户槽位在三个内部通道之后，接收末路为兜底。
  eth_port_top #(
      .CmacSelect         (CmacSelect),
      .RxTypeCount        (MacRxCount + 3),
      .TxChannelCount     (MacTxCount + 3),
      .TxReqWidth         (ReqWidth),
      .LedHalfPeriodCycles(InitClkFreqHz / 2)
  ) eth_port_top_inst (
      .init_clk           (init_clk),
      .arst               (!clk_locked),
      .gt_txusrclk        (),
      .gt_rxusrclk        (),
      .gt_tx_arst         (gt_tx_arst),
      .gt_rx_arst         (gt_rx_arst),
      .gt_txp_out         (gt_txp_out),
      .gt_txn_out         (gt_txn_out),
      .gt_rxp_in          (gt_rxp_in),
      .gt_rxn_in          (gt_rxn_in),
      .gt_ref_clk_p       (gt_ref_clk_p),
      .gt_ref_clk_n       (gt_ref_clk_n),
      .qsfp_reset_n       (qsfp_reset_n),
      .qsfp_low_power_mode(qsfp_low_power_mode),
      .qsfp_select_n      (qsfp_select_n),
      .qsfp_present_n     (qsfp_present_n),
      .qsfp_led           (qsfp_led),
      .stat_link_up       (gt_rx_link_up),
      .clk                (clk),
      .rst                (rst),
      .tx_fifo_arst       (rst),
      .cfg_type_dict      ({MacTypeDict, 16'hdd86, 16'h0008, 16'h0608}),
      .axis_mdata         ({mac_axis_mdata, ipv6_eth_rx_data, ipv4_eth_rx_data, arp_rx_data}),
      .axis_mkeep         ({mac_axis_mkeep, ipv6_eth_rx_keep, ipv4_eth_rx_keep, arp_rx_keep}),
      .axis_musr          ({mac_axis_musr, ipv6_eth_rx_usr, ipv4_eth_rx_usr, arp_rx_usr}),
      .axis_mvalid        ({mac_axis_mvalid, ipv6_eth_rx_valid, ipv4_eth_rx_valid, arp_rx_valid}),
      .axis_mlast         ({mac_axis_mlast, ipv6_eth_rx_last, ipv4_eth_rx_last, arp_rx_last}),
      .axis_mready        ({mac_axis_mready, ipv6_eth_rx_ready, ipv4_eth_rx_ready, arp_rx_ready}),
      .axis_sdata         ({mac_axis_sdata, ipv6_eth_tx_data, ipv4_eth_tx_data, arp_tx_data}),
      .axis_skeep         ({mac_axis_skeep, ipv6_eth_tx_keep, ipv4_eth_tx_keep, arp_tx_keep}),
      .axis_susr          ({mac_axis_susr, ipv6_eth_tx_usr, ipv4_eth_tx_usr, arp_tx_usr}),
      .axis_svalid        ({mac_axis_svalid, ipv6_eth_tx_valid, ipv4_eth_tx_valid, arp_tx_valid}),
      .axis_slast         ({mac_axis_slast, ipv6_eth_tx_last, ipv4_eth_tx_last, arp_tx_last}),
      .axis_sready        ({mac_axis_sready, ipv6_eth_tx_ready, ipv4_eth_tx_ready, arp_tx_ready})
  );

  // ARP：管理地址位于低位槽0，业务地址从槽1开始。
  arp_engine_top #(
      .PendingTimeWidth(PendingTimeWidth),
      .LocalIpCount    (LocalIpv4Count + 1),
      .ClkFreqHz       (ClkFreqHz),
      .ReqWidth        (ReqWidth)
  ) arp_engine_top_inst (
      .clk                             (clk),
      .rst                             (rst),
      .announce_mask                   (arp_announce_mask),
      .announce_valid                  (arp_announce_valid),
      .announce_ready                  (arp_announce_ready),
      .query_src_ip                    (query_src_ip),
      .query_dst_ip                    (query_dst_ip),
      .query_valid_pulse               (query_valid_pulse),
      .arp_dst_mac                     (arp_dst_mac),
      .arp_src_mac                     (arp_src_mac),
      .arp_miss                        (arp_miss),
      .arp_valid                       (arp_valid),
      .axis_sdata                      (arp_rx_data),
      .axis_skeep                      (arp_rx_keep),
      .axis_susr                       (arp_rx_usr),
      .axis_svalid                     (arp_rx_valid),
      .axis_slast                      (arp_rx_last),
      .axis_sready                     (arp_rx_ready),
      .axis_mdata                      (arp_tx_data),
      .axis_mkeep                      (arp_tx_keep),
      .axis_musr                       (arp_tx_usr),
      .axis_mvalid                     (arp_tx_valid),
      .axis_mlast                      (arp_tx_last),
      .axis_mready                     (arp_tx_ready),
      .cfg_arp_priority                (cfg_arp_priority),
      .cfg_local_ip                    ({cfg_local_ip, cfg_mgmt_ipv4_addr}),
      .cfg_local_mac                   ({cfg_local_mac, cfg_mgmt_mac}),
      .cfg_gateway_ip                  ({cfg_gateway_ip, MgmtGatewayIp}),
      .cfg_subnet_mask                 ({cfg_subnet_mask, MgmtSubnetMask}),
      .cfg_pending_time                (cfg_pending_time),
      .cfg_clear_cache                 (cfg_arp_clear_cache),
      .cfg_clear_pending               (cfg_arp_clear_pending),
      .cfg_stat_clear                  (cfg_stat_clear),
      .stat_rx_error                   (stat_arp_rx_error),
      .stat_ack_fifo_overflow_error    (stat_arp_ack_fifo_overflow_error),
      .stat_pending_fifo_overflow_error(stat_arp_pending_fifo_overflow_error),
      .stat_pending_clear_finish       (stat_arp_pending_clear_finish),
      .stat_cache_clear_finish         (stat_arp_cache_clear_finish),
      .stat_query_src_not_local        (stat_arp_query_src_not_local)
  );

  // IPv4：UDP在档0，ICMPv4在档1。
  ipv4_top #(
      .RxTypeCount   (Ipv4RxCount + 2),
      .TxChannelCount(Ipv4TxCount + 2),
      .TxReqWidth    (ReqWidth)
  ) ipv4_top_inst (
      .clk              (clk),
      .rst              (rst),
      .cfg_stat_clear   (cfg_stat_clear),
      .cfg_rx_type_dict ({Ipv4TypeDict, 8'h01, 8'h11}),
      .rx_axis_sdata    (ipv4_eth_rx_data),
      .rx_axis_skeep    (ipv4_eth_rx_keep),
      .rx_axis_susr     (ipv4_eth_rx_usr),
      .rx_axis_svalid   (ipv4_eth_rx_valid),
      .rx_axis_slast    (ipv4_eth_rx_last),
      .rx_axis_sready   (ipv4_eth_rx_ready),
      .rx_axis_mdata    ({ipv4_axis_mdata, ipv4_icmp_rx_data, ipv4_udp_rx_data}),
      .rx_axis_mkeep    ({ipv4_axis_mkeep, ipv4_icmp_rx_keep, ipv4_udp_rx_keep}),
      .rx_axis_musr     ({ipv4_axis_musr, ipv4_icmp_rx_usr, ipv4_udp_rx_usr}),
      .rx_axis_mvalid   ({ipv4_axis_mvalid, ipv4_icmp_rx_valid, ipv4_udp_rx_valid}),
      .rx_axis_mlast    ({ipv4_axis_mlast, ipv4_icmp_rx_last, ipv4_udp_rx_last}),
      .rx_axis_mready   ({ipv4_axis_mready, ipv4_icmp_rx_ready, ipv4_udp_rx_ready}),
      .tx_axis_sdata    ({ipv4_axis_sdata, ipv4_icmp_tx_data, ipv4_udp_tx_data}),
      .tx_axis_skeep    ({ipv4_axis_skeep, ipv4_icmp_tx_keep, ipv4_udp_tx_keep}),
      .tx_axis_susr     ({ipv4_axis_susr, ipv4_icmp_tx_usr, ipv4_udp_tx_usr}),
      .tx_axis_svalid   ({ipv4_axis_svalid, ipv4_icmp_tx_valid, ipv4_udp_tx_valid}),
      .tx_axis_slast    ({ipv4_axis_slast, ipv4_icmp_tx_last, ipv4_udp_tx_last}),
      .tx_axis_sready   ({ipv4_axis_sready, ipv4_icmp_tx_ready, ipv4_udp_tx_ready}),
      .tx_axis_mdata    (ipv4_eth_tx_data),
      .tx_axis_mkeep    (ipv4_eth_tx_keep),
      .tx_axis_musr     (ipv4_eth_tx_usr),
      .tx_axis_mvalid   (ipv4_eth_tx_valid),
      .tx_axis_mlast    (ipv4_eth_tx_last),
      .tx_axis_mready   (ipv4_eth_tx_ready),
      .query_src_ip     (query_src_ip),
      .query_dst_ip     (query_dst_ip),
      .query_valid_pulse(query_valid_pulse),
      .arp_dst_mac      (arp_dst_mac),
      .arp_src_mac      (arp_src_mac),
      .arp_miss         (arp_miss),
      .arp_valid        (arp_valid),
      .stat_tx_drop     (stat_ipv4_tx_drop)
  );

  // ICMPv4：业务发送与内部回显应答仲裁，其他接收报文交给用户。
  icmpv4_top #(
      .ReqWidth      (ReqWidth),
      .TxChannelCount(IcmpTxCount)
  ) icmpv4_top_inst (
      .clk              (clk),
      .rst              (rst),
      .cfg_arbiter_value(cfg_icmp_priority),
      .cfg_clear_error  (cfg_stat_clear),
      .rx_axis_sdata    (ipv4_icmp_rx_data),
      .rx_axis_skeep    (ipv4_icmp_rx_keep),
      .rx_axis_susr     (ipv4_icmp_rx_usr),
      .rx_axis_svalid   (ipv4_icmp_rx_valid),
      .rx_axis_slast    (ipv4_icmp_rx_last),
      .rx_axis_sready   (ipv4_icmp_rx_ready),
      .other_axis_mdata (icmp_axis_mdata),
      .other_axis_mkeep (icmp_axis_mkeep),
      .other_axis_musr  (icmp_axis_musr),
      .other_axis_mvalid(icmp_axis_mvalid),
      .other_axis_mlast (icmp_axis_mlast),
      .other_axis_mready(icmp_axis_mready),
      .tx_axis_sdata    (icmp_axis_sdata),
      .tx_axis_skeep    (icmp_axis_skeep),
      .tx_axis_susr     (icmp_axis_susr),
      .tx_axis_svalid   (icmp_axis_svalid),
      .tx_axis_slast    (icmp_axis_slast),
      .tx_axis_sready   (icmp_axis_sready),
      .tx_axis_mdata    (ipv4_icmp_tx_data),
      .tx_axis_mkeep    (ipv4_icmp_tx_keep),
      .tx_axis_musr     (ipv4_icmp_tx_usr),
      .tx_axis_mvalid   (ipv4_icmp_tx_valid),
      .tx_axis_mlast    (ipv4_icmp_tx_last),
      .tx_axis_mready   (ipv4_icmp_tx_ready),
      .stat_ttl_error   (stat_icmp_ttl_error)
  );

  // IPv6：内部档0接收UDP，其余用户通道保持原索引。
  ipv6_top #(
      .RxTypeCount     (Ipv6RxCount + 1),
      .DstMacEntryCount(DstIpv6Count),
      .SrcMacEntryCount(SrcIpv6Count),
      .TxChannelCount  (Ipv6TxCount + 1),
      .TxReqWidth      (ReqWidth)
  ) ipv6_top_inst (
      .clk             (clk),
      .rst             (rst),
      .cfg_stat_clear  (cfg_stat_clear),
      .cfg_rx_type_dict({Ipv6TypeDict, 8'h11}),
      .rx_axis_sdata   (ipv6_eth_rx_data),
      .rx_axis_skeep   (ipv6_eth_rx_keep),
      .rx_axis_susr    (ipv6_eth_rx_usr),
      .rx_axis_svalid  (ipv6_eth_rx_valid),
      .rx_axis_slast   (ipv6_eth_rx_last),
      .rx_axis_sready  (ipv6_eth_rx_ready),
      .rx_axis_mdata   ({ipv6_axis_mdata, ipv6_udp_rx_data}),
      .rx_axis_mkeep   ({ipv6_axis_mkeep, ipv6_udp_rx_keep}),
      .rx_axis_musr    ({ipv6_axis_musr, ipv6_udp_rx_usr}),
      .rx_axis_mvalid  ({ipv6_axis_mvalid, ipv6_udp_rx_valid}),
      .rx_axis_mlast   ({ipv6_axis_mlast, ipv6_udp_rx_last}),
      .rx_axis_mready  ({ipv6_axis_mready, ipv6_udp_rx_ready}),
      .tx_axis_sdata   ({ipv6_axis_sdata, ipv6_udp_tx_data}),
      .tx_axis_skeep   ({ipv6_axis_skeep, ipv6_udp_tx_keep}),
      .tx_axis_susr    ({ipv6_axis_susr, ipv6_udp_tx_usr}),
      .tx_axis_svalid  ({ipv6_axis_svalid, ipv6_udp_tx_valid}),
      .tx_axis_slast   ({ipv6_axis_slast, ipv6_udp_tx_last}),
      .tx_axis_sready  ({ipv6_axis_sready, ipv6_udp_tx_ready}),
      .tx_axis_mdata   (ipv6_eth_tx_data),
      .tx_axis_mkeep   (ipv6_eth_tx_keep),
      .tx_axis_musr    (ipv6_eth_tx_usr),
      .tx_axis_mvalid  (ipv6_eth_tx_valid),
      .tx_axis_mlast   (ipv6_eth_tx_last),
      .tx_axis_mready  (ipv6_eth_tx_ready),
      .cfg_dst_ipv6    (cfg_dst_ipv6),
      .cfg_dst_mac     (cfg_dst_mac),
      .cfg_src_ipv6    (cfg_src_ipv6),
      .cfg_src_mac     (cfg_src_mac),
      .stat_tx_drop    (stat_ipv6_tx_drop)
  );

  // UDP(IPv6)：端口字典独立配置，末路为兜底。
  udp_ipv6_top #(
      .RxPortCount   (UdpIpv6RxCount),
      .TxChannelCount(UdpIpv6TxCount),
      .TxReqWidth    (ReqWidth)
  ) udp_ipv6_top_inst (
      .clk               (clk),
      .rst               (rst),
      .cfg_dst_port_range(cfg_udp_ipv6_dst_port_range),
      .rx_axis_sdata     (ipv6_udp_rx_data),
      .rx_axis_skeep     (ipv6_udp_rx_keep),
      .rx_axis_susr      (ipv6_udp_rx_usr),
      .rx_axis_svalid    (ipv6_udp_rx_valid),
      .rx_axis_slast     (ipv6_udp_rx_last),
      .rx_axis_sready    (ipv6_udp_rx_ready),
      .rx_axis_mdata     (udp_ipv6_axis_mdata),
      .rx_axis_mkeep     (udp_ipv6_axis_mkeep),
      .rx_axis_musr      (udp_ipv6_axis_musr),
      .rx_axis_mvalid    (udp_ipv6_axis_mvalid),
      .rx_axis_mlast     (udp_ipv6_axis_mlast),
      .rx_axis_mready    (udp_ipv6_axis_mready),
      .tx_axis_sdata     (udp_ipv6_axis_sdata),
      .tx_axis_skeep     (udp_ipv6_axis_skeep),
      .tx_axis_susr      (udp_ipv6_axis_susr),
      .tx_axis_svalid    (udp_ipv6_axis_svalid),
      .tx_axis_slast     (udp_ipv6_axis_slast),
      .tx_axis_sready    (udp_ipv6_axis_sready),
      .tx_axis_mdata     (ipv6_udp_tx_data),
      .tx_axis_mkeep     (ipv6_udp_tx_keep),
      .tx_axis_musr      (ipv6_udp_tx_usr),
      .tx_axis_mvalid    (ipv6_udp_tx_valid),
      .tx_axis_mlast     (ipv6_udp_tx_last),
      .tx_axis_mready    (ipv6_udp_tx_ready)
  );

  // UDP(IPv4)：命令RX占档0，命令TX接在业务档后。
  udp_ipv4_top #(
      .RxPortCount   (UdpIpv4RxCount + 1),
      .TxChannelCount(UdpIpv4TxCount + 1),
      .TxReqWidth    (ReqWidth)
  ) udp_ipv4_top_inst (
      .clk               (clk),
      .rst               (rst),
      .cfg_dst_port_range({cfg_udp_ipv4_dst_port_range, {cfg_mgmt_udp_port, cfg_mgmt_udp_port}}),
      .rx_axis_sdata     (ipv4_udp_rx_data),
      .rx_axis_skeep     (ipv4_udp_rx_keep),
      .rx_axis_susr      (ipv4_udp_rx_usr),
      .rx_axis_svalid    (ipv4_udp_rx_valid),
      .rx_axis_slast     (ipv4_udp_rx_last),
      .rx_axis_sready    (ipv4_udp_rx_ready),
      .rx_axis_mdata     ({udp_ipv4_axis_mdata, cmd_rx_data}),
      .rx_axis_mkeep     ({udp_ipv4_axis_mkeep, cmd_rx_keep}),
      .rx_axis_musr      ({udp_ipv4_axis_musr, cmd_rx_usr}),
      .rx_axis_mvalid    ({udp_ipv4_axis_mvalid, cmd_rx_valid}),
      .rx_axis_mlast     ({udp_ipv4_axis_mlast, cmd_rx_last}),
      .rx_axis_mready    ({udp_ipv4_axis_mready, cmd_rx_ready}),
      .tx_axis_sdata     ({cmd_tx_data, udp_ipv4_axis_sdata}),
      .tx_axis_skeep     ({cmd_tx_keep, udp_ipv4_axis_skeep}),
      .tx_axis_susr      ({cmd_tx_usr, udp_ipv4_axis_susr}),
      .tx_axis_svalid    ({cmd_tx_valid, udp_ipv4_axis_svalid}),
      .tx_axis_slast     ({cmd_tx_last, udp_ipv4_axis_slast}),
      .tx_axis_sready    ({cmd_tx_ready, udp_ipv4_axis_sready}),
      .tx_axis_mdata     (ipv4_udp_tx_data),
      .tx_axis_mkeep     (ipv4_udp_tx_keep),
      .tx_axis_musr      (ipv4_udp_tx_usr),
      .tx_axis_mvalid    (ipv4_udp_tx_valid),
      .tx_axis_mlast     (ipv4_udp_tx_last),
      .tx_axis_mready    (ipv4_udp_tx_ready)
  );

  // 本口配置与状态管理
  cfg_port_top #(
      .PendingTimeWidth   (PendingTimeWidth),
      .LocalIpv4Count     (LocalIpv4Count),
      .SrcIpv6Count       (SrcIpv6Count),
      .DstIpv6Count       (DstIpv6Count),
      .UdpIpv4RxCount     (UdpIpv4RxCount),
      .UdpIpv6RxCount     (UdpIpv6RxCount),
      .ReqWidth           (ReqWidth),
      .DefaultLocalIp     (DefaultLocalIp),
      .DefaultLocalMac    (DefaultLocalMac),
      .DefaultGatewayIp   (DefaultGatewayIp),
      .DefaultSubnetMask  (DefaultSubnetMask),
      .DefaultSrcIpv6     (DefaultSrcIpv6),
      .DefaultSrcMac      (DefaultSrcMac),
      .DefaultDstIpv6     (DefaultDstIpv6),
      .DefaultDstMac      (DefaultDstMac),
      .DefaultUdpIpv4Range(DefaultUdpIpv4Range),
      .DefaultUdpIpv6Range(DefaultUdpIpv6Range),
      .DefaultPendingTime (DefaultPendingTime),
      .DefaultArpPriority (DefaultArpPriority),
      .DefaultIcmpPriority(DefaultIcmpPriority),
      .DefaultMgmtIpv4Addr(DefaultMgmtIpv4Addr),
      .DefaultMgmtUdpPort (DefaultMgmtUdpPort),
      .DefaultMgmtMac     (MgmtMac),
      .ReplyTtl           (8'd64),
      .DefaultMgmtPriority(DefaultMgmtPriority)
  ) cfg_port_top_inst (
      .clk                                 (clk),
      .rst                                 (rst),
      .axis_sdata                          (cmd_rx_data),
      .axis_skeep                          (cmd_rx_keep),
      .axis_susr                           (cmd_rx_usr),
      .axis_svalid                         (cmd_rx_valid),
      .axis_slast                          (cmd_rx_last),
      .axis_sready                         (cmd_rx_ready),
      .axis_mdata                          (cmd_tx_data),
      .axis_mkeep                          (cmd_tx_keep),
      .axis_musr                           (cmd_tx_usr),
      .axis_mvalid                         (cmd_tx_valid),
      .axis_mlast                          (cmd_tx_last),
      .axis_mready                         (cmd_tx_ready),
      .cfg_local_ip                        (cfg_local_ip),
      .cfg_local_mac                       (cfg_local_mac),
      .cfg_gateway_ip                      (cfg_gateway_ip),
      .cfg_subnet_mask                     (cfg_subnet_mask),
      .cfg_src_ipv6                        (cfg_src_ipv6),
      .cfg_src_mac                         (cfg_src_mac),
      .cfg_dst_ipv6                        (cfg_dst_ipv6),
      .cfg_dst_mac                         (cfg_dst_mac),
      .cfg_udp_ipv4_dst_port_range         (cfg_udp_ipv4_dst_port_range),
      .cfg_udp_ipv6_dst_port_range         (cfg_udp_ipv6_dst_port_range),
      .cfg_pending_time                    (cfg_pending_time),
      .cfg_arp_priority                    (cfg_arp_priority),
      .cfg_icmp_priority                   (cfg_icmp_priority),
      .cfg_mgmt_ipv4_addr                  (cfg_mgmt_ipv4_addr),
      .cfg_mgmt_udp_port                   (cfg_mgmt_udp_port),
      .cfg_mgmt_mac                        (cfg_mgmt_mac),
      .cfg_arp_clear_cache                 (cfg_arp_clear_cache),
      .cfg_arp_clear_pending               (cfg_arp_clear_pending),
      .cfg_stat_clear                      (cfg_stat_clear),
      .cfg_arp_announce_mask               (cfg_arp_announce_mask),
      .cfg_arp_announce_valid              (cfg_arp_announce_valid),
      .cfg_arp_announce_ready              (cfg_arp_announce_ready),
      .stat_link_up                        (stat_link_up),
      .stat_arp_rx_error                   (stat_arp_rx_error),
      .stat_arp_ack_fifo_overflow_error    (stat_arp_ack_fifo_overflow_error),
      .stat_arp_pending_fifo_overflow_error(stat_arp_pending_fifo_overflow_error),
      .stat_arp_query_src_not_local        (stat_arp_query_src_not_local),
      .stat_arp_cache_clear_finish         (stat_arp_cache_clear_finish),
      .stat_arp_pending_clear_finish       (stat_arp_pending_clear_finish),
      .stat_ipv4_tx_drop                   (stat_ipv4_tx_drop),
      .stat_ipv6_tx_drop                   (stat_ipv6_tx_drop),
      .stat_icmp_ttl_error                 (stat_icmp_ttl_error)
  );

endmodule
`resetall
