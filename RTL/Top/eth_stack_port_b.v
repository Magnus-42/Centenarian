// -----------------------------------------------------------------------------
// File Name   : eth_stack_port_b.v
// Module Name : eth_stack_port_b
// Author      : Codex
// Created     : 2026-11-19
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : B口以太网协议栈的固定接线和默认值。
// Note        : 新增用户通道时修改本文件和整机顶层的对应接口。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module eth_stack_port_b #(
    // 数量与请求位宽
    parameter integer LocalIpv4Count = 2,
    parameter integer SrcIpv6Count   = 2,
    parameter integer DstIpv6Count   = 2,
    parameter integer UdpIpv4RxCount = 3,
    parameter integer ReqWidth       = 4,

    // IPv4默认配置
    parameter [32*LocalIpv4Count-1:0] DefaultLocalIp    = {32'h9001_a8c0, 32'h9101_a8c0},
    parameter [48*LocalIpv4Count-1:0] DefaultLocalMac   = {48'h8100_3119_0000, 48'h8200_3119_0000},
    parameter [32*LocalIpv4Count-1:0] DefaultGatewayIp  = {32'h0101_a8c0, 32'h0101_a8c0},
    parameter [32*LocalIpv4Count-1:0] DefaultSubnetMask = {32'h00ff_ffff, 32'h00ff_ffff},

    // IPv6默认配置
    parameter [128*SrcIpv6Count-1:0] DefaultSrcIpv6 = {
      128'h2200_3119_0000_0000_0000_0000_0000_80fe, 128'h2300_3119_0000_0000_0000_0000_0000_80fe
    },
    parameter [48*SrcIpv6Count-1:0] DefaultSrcMac = {48'h2200_3119_0000, 48'h2300_3119_0000},
    parameter [128*DstIpv6Count-1:0] DefaultDstIpv6 = {
      128'h1100_3119_0000_0000_0000_0000_0000_80fe, 128'h1200_3119_0000_0000_0000_0000_0000_80fe
    },
    parameter [48*DstIpv6Count-1:0] DefaultDstMac = {48'h1100_3119_0000, 48'h1200_3119_0000},

    // UDP接收端口范围
    parameter [32*UdpIpv4RxCount-1:0] DefaultUdpIpv4Range = {
      32'h3000_2000, 32'h1000_1000, 32'h0800_0000
    },

    // ARP与ICMP策略
    parameter integer                        PendingTimeWidth    = 24,
    parameter         [PendingTimeWidth-1:0] DefaultPendingTime  = 24'd2000,
    parameter         [        ReqWidth-1:0] DefaultArpPriority  = {ReqWidth{1'b1}},
    parameter         [        ReqWidth-1:0] DefaultIcmpPriority = 4'd12,

    // 管理配置
    parameter [31:0] DefaultMgmtIpv4Addr = 32'h8901_a8c0,
    parameter [15:0] DefaultMgmtUdpPort  = 16'h8600,
    parameter [47:0] DefaultMgmtMac      = 48'hf180_3119_0000,

    // 固定通道数与发送usr位宽
    localparam integer MacRxCount     = 1,
    localparam integer MacTxCount     = 3,
    localparam integer Ipv4RxCount    = 3,
    localparam integer Ipv4TxCount    = 4,
    localparam integer Ipv6RxCount    = 3,
    localparam integer Ipv6TxCount    = 3,
    localparam integer UdpIpv4TxCount = 4,
    localparam integer UdpTxUsrWidth  = 104 + ReqWidth
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
    output wire [512*(MacRxCount+1)-1:0] mac_axis_mdata,
    output wire [ 64*(MacRxCount+1)-1:0] mac_axis_mkeep,
    output wire [    (MacRxCount+1)-1:0] mac_axis_mvalid,
    output wire [    (MacRxCount+1)-1:0] mac_axis_mlast,
    input  wire [    (MacRxCount+1)-1:0] mac_axis_mready,

    // MAC发送
    input  wire [   512*(MacTxCount)-1:0] mac_axis_sdata,
    input  wire [    64*(MacTxCount)-1:0] mac_axis_skeep,
    input  wire [ReqWidth*MacTxCount-1:0] mac_axis_susr,
    input  wire [         MacTxCount-1:0] mac_axis_svalid,
    input  wire [         MacTxCount-1:0] mac_axis_slast,
    output wire [         MacTxCount-1:0] mac_axis_sready,

    // IPv4接收
    output wire [512*(Ipv4RxCount+1)-1:0] ipv4_axis_mdata,
    output wire [ 64*(Ipv4RxCount+1)-1:0] ipv4_axis_mkeep,
    output wire [ 97*(Ipv4RxCount+1)-1:0] ipv4_axis_musr,
    output wire [    (Ipv4RxCount+1)-1:0] ipv4_axis_mvalid,
    output wire [    (Ipv4RxCount+1)-1:0] ipv4_axis_mlast,
    input  wire [    (Ipv4RxCount+1)-1:0] ipv4_axis_mready,

    // IPv4发送
    input  wire [   512*(Ipv4TxCount)-1:0] ipv4_axis_sdata,
    input  wire [    64*(Ipv4TxCount)-1:0] ipv4_axis_skeep,
    input  wire [ReqWidth*Ipv4TxCount-1:0] ipv4_axis_susr,
    input  wire [         Ipv4TxCount-1:0] ipv4_axis_svalid,
    input  wire [         Ipv4TxCount-1:0] ipv4_axis_slast,
    output wire [         Ipv4TxCount-1:0] ipv4_axis_sready,

    // ICMP接收
    output wire [511:0] icmp_axis_mdata,
    output wire [ 63:0] icmp_axis_mkeep,
    output wire [ 96:0] icmp_axis_musr,
    output wire         icmp_axis_mvalid,
    output wire         icmp_axis_mlast,
    input  wire         icmp_axis_mready,

    // IPv6接收
    output wire [512*(Ipv6RxCount+1)-1:0] ipv6_axis_mdata,
    output wire [ 64*(Ipv6RxCount+1)-1:0] ipv6_axis_mkeep,
    output wire [ 97*(Ipv6RxCount+1)-1:0] ipv6_axis_musr,
    output wire [    (Ipv6RxCount+1)-1:0] ipv6_axis_mvalid,
    output wire [    (Ipv6RxCount+1)-1:0] ipv6_axis_mlast,
    input  wire [    (Ipv6RxCount+1)-1:0] ipv6_axis_mready,

    // IPv6发送
    input  wire [   512*(Ipv6TxCount)-1:0] ipv6_axis_sdata,
    input  wire [    64*(Ipv6TxCount)-1:0] ipv6_axis_skeep,
    input  wire [ReqWidth*Ipv6TxCount-1:0] ipv6_axis_susr,
    input  wire [         Ipv6TxCount-1:0] ipv6_axis_svalid,
    input  wire [         Ipv6TxCount-1:0] ipv6_axis_slast,
    output wire [         Ipv6TxCount-1:0] ipv6_axis_sready,

    // UDP接收
    output wire [512*(UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_mdata,
    output wire [ 64*(UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_mkeep,
    output wire [241*(UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_musr,
    output wire [    (UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_mvalid,
    output wire [    (UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_mlast,
    input  wire [    (UdpIpv4RxCount+1)-1:0] udp_ipv4_axis_mready,

    // UDP发送
    input  wire [        512*(UdpIpv4TxCount)-1:0] udp_ipv4_axis_sdata,
    input  wire [         64*(UdpIpv4TxCount)-1:0] udp_ipv4_axis_skeep,
    input  wire [UdpTxUsrWidth*UdpIpv4TxCount-1:0] udp_ipv4_axis_susr,
    input  wire [              UdpIpv4TxCount-1:0] udp_ipv4_axis_svalid,
    input  wire [              UdpIpv4TxCount-1:0] udp_ipv4_axis_slast,
    output wire [              UdpIpv4TxCount-1:0] udp_ipv4_axis_sready
);

  // 给出B口固定接收字典与管理路由，连接公共单口协议栈。

  // 固定接收字典：IPv4的内置UDP、ICMPv4由公共单口封装添加。
  localparam [16*MacRxCount-1:0] MacTypeDict = 16'hb588;
  localparam [8*Ipv4RxCount-1:0] Ipv4TypeDict = {8'h59, 8'hfd, 8'h06};
  localparam [8*Ipv6RxCount-1:0] Ipv6TypeDict = {8'h3a, 8'h59, 8'h11};

  // 管理地址槽使用本口的固定网关和掩码。
  localparam [31:0] MgmtGatewayIp = 32'h0101_a8c0;
  localparam [31:0] MgmtSubnetMask = 32'h00ff_ffff;

  // B口协议栈
  eth_stack_port #(
      .CmacSelect(1),
      .ReqWidth  (ReqWidth),

      .MacRxCount    (MacRxCount),
      .MacTxCount    (MacTxCount),
      .Ipv4RxCount   (Ipv4RxCount),
      .Ipv4TxCount   (Ipv4TxCount),
      .Ipv6RxCount   (Ipv6RxCount),
      .Ipv6TxCount   (Ipv6TxCount),
      .UdpIpv4RxCount(UdpIpv4RxCount),
      .UdpIpv4TxCount(UdpIpv4TxCount),

      .LocalIpv4Count(LocalIpv4Count),
      .SrcIpv6Count  (SrcIpv6Count),
      .DstIpv6Count  (DstIpv6Count),

      .MacTypeDict (MacTypeDict),
      .Ipv4TypeDict(Ipv4TypeDict),
      .Ipv6TypeDict(Ipv6TypeDict),

      .MgmtMac       (DefaultMgmtMac),
      .MgmtGatewayIp (MgmtGatewayIp),
      .MgmtSubnetMask(MgmtSubnetMask),

      .DefaultLocalIp   (DefaultLocalIp),
      .DefaultLocalMac  (DefaultLocalMac),
      .DefaultGatewayIp (DefaultGatewayIp),
      .DefaultSubnetMask(DefaultSubnetMask),

      .DefaultSrcIpv6(DefaultSrcIpv6),
      .DefaultDstIpv6(DefaultDstIpv6),
      .DefaultSrcMac (DefaultSrcMac),
      .DefaultDstMac (DefaultDstMac),

      .PendingTimeWidth(PendingTimeWidth),
      .DefaultPendingTime(DefaultPendingTime),
      .DefaultArpPriority(DefaultArpPriority),
      .DefaultIcmpPriority(DefaultIcmpPriority),

      .DefaultMgmtIpv4Addr(DefaultMgmtIpv4Addr),
      .DefaultMgmtUdpPort (DefaultMgmtUdpPort),

      .DefaultUdpIpv4Range(DefaultUdpIpv4Range)
  ) eth_stack_port_inst (
      .init_clk  (init_clk),
      .clk       (clk),
      .rst       (rst),
      .clk_locked(clk_locked),

      .gt_txp_out  (gt_txp_out),
      .gt_txn_out  (gt_txn_out),
      .gt_rxp_in   (gt_rxp_in),
      .gt_rxn_in   (gt_rxn_in),
      .gt_ref_clk_p(gt_ref_clk_p),
      .gt_ref_clk_n(gt_ref_clk_n),

      .qsfp_reset_n       (qsfp_reset_n),
      .qsfp_low_power_mode(qsfp_low_power_mode),
      .qsfp_select_n      (qsfp_select_n),
      .qsfp_present_n     (qsfp_present_n),
      .qsfp_led           (qsfp_led),
      .qsfp_gt_rst        (qsfp_gt_rst),

      .mac_axis_mdata (mac_axis_mdata),
      .mac_axis_mkeep (mac_axis_mkeep),
      .mac_axis_mvalid(mac_axis_mvalid),
      .mac_axis_mlast (mac_axis_mlast),
      .mac_axis_mready(mac_axis_mready),

      .mac_axis_sdata (mac_axis_sdata),
      .mac_axis_skeep (mac_axis_skeep),
      .mac_axis_susr  (mac_axis_susr),
      .mac_axis_svalid(mac_axis_svalid),
      .mac_axis_slast (mac_axis_slast),
      .mac_axis_sready(mac_axis_sready),

      .ipv4_axis_mdata (ipv4_axis_mdata),
      .ipv4_axis_mkeep (ipv4_axis_mkeep),
      .ipv4_axis_musr  (ipv4_axis_musr),
      .ipv4_axis_mvalid(ipv4_axis_mvalid),
      .ipv4_axis_mlast (ipv4_axis_mlast),
      .ipv4_axis_mready(ipv4_axis_mready),

      .ipv4_axis_sdata (ipv4_axis_sdata),
      .ipv4_axis_skeep (ipv4_axis_skeep),
      .ipv4_axis_susr  (ipv4_axis_susr),
      .ipv4_axis_svalid(ipv4_axis_svalid),
      .ipv4_axis_slast (ipv4_axis_slast),
      .ipv4_axis_sready(ipv4_axis_sready),

      .icmp_axis_mdata (icmp_axis_mdata),
      .icmp_axis_mkeep (icmp_axis_mkeep),
      .icmp_axis_musr  (icmp_axis_musr),
      .icmp_axis_mvalid(icmp_axis_mvalid),
      .icmp_axis_mlast (icmp_axis_mlast),
      .icmp_axis_mready(icmp_axis_mready),

      .ipv6_axis_mdata (ipv6_axis_mdata),
      .ipv6_axis_mkeep (ipv6_axis_mkeep),
      .ipv6_axis_musr  (ipv6_axis_musr),
      .ipv6_axis_mvalid(ipv6_axis_mvalid),
      .ipv6_axis_mlast (ipv6_axis_mlast),
      .ipv6_axis_mready(ipv6_axis_mready),

      .ipv6_axis_sdata (ipv6_axis_sdata),
      .ipv6_axis_skeep (ipv6_axis_skeep),
      .ipv6_axis_susr  (ipv6_axis_susr),
      .ipv6_axis_svalid(ipv6_axis_svalid),
      .ipv6_axis_slast (ipv6_axis_slast),
      .ipv6_axis_sready(ipv6_axis_sready),

      .udp_ipv4_axis_mdata (udp_ipv4_axis_mdata),
      .udp_ipv4_axis_mkeep (udp_ipv4_axis_mkeep),
      .udp_ipv4_axis_musr  (udp_ipv4_axis_musr),
      .udp_ipv4_axis_mvalid(udp_ipv4_axis_mvalid),
      .udp_ipv4_axis_mlast (udp_ipv4_axis_mlast),
      .udp_ipv4_axis_mready(udp_ipv4_axis_mready),

      .udp_ipv4_axis_sdata (udp_ipv4_axis_sdata),
      .udp_ipv4_axis_skeep (udp_ipv4_axis_skeep),
      .udp_ipv4_axis_susr  (udp_ipv4_axis_susr),
      .udp_ipv4_axis_svalid(udp_ipv4_axis_svalid),
      .udp_ipv4_axis_slast (udp_ipv4_axis_slast),
      .udp_ipv4_axis_sready(udp_ipv4_axis_sready)
  );

endmodule
`resetall
