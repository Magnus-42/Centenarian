// -----------------------------------------------------------------------------
// File Name   : cfg_port_top.v
// Module Name : cfg_port_top
// Author      : Codex
// Created     : 2026-11-19
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 连接单口UDP命令、配置寄存器及业务状态。
// Note        :
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module cfg_port_top #(
    parameter integer LocalIpv4Count = 3,  // 小于255
    parameter integer SrcIpv6Count = 2,
    parameter integer DstIpv6Count = 3,
    parameter integer UdpIpv4RxCount = 3,
    parameter integer UdpIpv6RxCount = 3,
    parameter integer ReqWidth = 4,
    parameter integer PendingTimeWidth = 24,
    parameter [32*LocalIpv4Count-1:0] DefaultLocalIp = {
      32'h1001_a8c0, 32'h1101_a8c0, 32'h1201_a8c0
    },
    parameter [48*LocalIpv4Count-1:0] DefaultLocalMac = {
      48'h0100_3119_0000, 48'h0200_3119_0000, 48'h0300_3119_0000
    },
    parameter [32*LocalIpv4Count-1:0] DefaultGatewayIp = {
      32'h0101_a8c0, 32'h0101_a8c0, 32'h0101_a8c0
    },
    parameter [32*LocalIpv4Count-1:0] DefaultSubnetMask = {
      32'h00ff_ffff, 32'h00ff_ffff, 32'h00ff_ffff
    },
    parameter [128*SrcIpv6Count-1:0] DefaultSrcIpv6 = {
      128'h1100_3119_0000_0000_0000_0000_0000_80FE, 128'h1200_3119_0000_0000_0000_0000_0000_80FE
    },
    parameter [48*SrcIpv6Count-1:0] DefaultSrcMac = {48'h1100_3119_0000, 48'h1200_3119_0000},
    parameter [128*DstIpv6Count-1:0] DefaultDstIpv6 = {
      128'h2100_3119_0000_0000_0000_0000_0000_80FE,
      128'h2200_3119_0000_0000_0000_0000_0000_80FE,
      128'h2300_3119_0000_0000_0000_0000_0000_80FE
    },
    parameter [48*DstIpv6Count-1:0] DefaultDstMac = {
      48'h2100_3119_0000, 48'h2200_3119_0000, 48'h2300_3119_0000
    },
    parameter [32*UdpIpv4RxCount-1:0] DefaultUdpIpv4Range = {
      32'h3000_2000, 32'h1000_1000, 32'h0800_0000
    },
    parameter [32*UdpIpv6RxCount-1:0] DefaultUdpIpv6Range = {
      32'h3000_2000, 32'h1100_1100, 32'h0900_0000
    },
    parameter [PendingTimeWidth-1:0] DefaultPendingTime = 24'd1000,
    parameter [ReqWidth-1:0] DefaultArpPriority = 4'd15,
    parameter [ReqWidth-1:0] DefaultIcmpPriority = 4'd13,
    parameter [31:0] DefaultMgmtIpv4Addr = 32'h0901_a8c0,
    parameter [15:0] DefaultMgmtUdpPort = 16'h0600,
    parameter [47:0] DefaultMgmtMac = 48'hf100_3119_0000,
    parameter [7:0] ReplyTtl = 8'd64,
    parameter [ReqWidth-1:0] ReplyPriority = 4'd14,
    localparam integer TxUsrWidth = 104 + ReqWidth
) (
    input wire clk,
    input wire rst,

    input  wire [511:0] axis_sdata,
    input  wire [ 63:0] axis_skeep,
    input  wire [240:0] axis_susr,
    input  wire         axis_svalid,
    input  wire         axis_slast,
    output wire         axis_sready,

    output wire [         511:0] axis_mdata,
    output wire [          63:0] axis_mkeep,
    output wire [TxUsrWidth-1:0] axis_musr,
    output wire                  axis_mvalid,
    output wire                  axis_mlast,
    input  wire                  axis_mready,

    // IPv4地址配置
    output wire [32*LocalIpv4Count-1:0] cfg_local_ip,
    output wire [48*LocalIpv4Count-1:0] cfg_local_mac,
    output wire [32*LocalIpv4Count-1:0] cfg_gateway_ip,
    output wire [32*LocalIpv4Count-1:0] cfg_subnet_mask,

    // IPv6地址配置
    output wire [128*SrcIpv6Count-1:0] cfg_src_ipv6,
    output wire [ 48*SrcIpv6Count-1:0] cfg_src_mac,
    output wire [128*DstIpv6Count-1:0] cfg_dst_ipv6,
    output wire [ 48*DstIpv6Count-1:0] cfg_dst_mac,

    // UDP接收端口配置
    output wire [32*UdpIpv4RxCount-1:0] cfg_udp_ipv4_dst_port_range,
    output wire [32*UdpIpv6RxCount-1:0] cfg_udp_ipv6_dst_port_range,

    // ARP与ICMP配置
    output wire [PendingTimeWidth-1:0] cfg_pending_time,
    output wire [ReqWidth-1:0] cfg_arp_priority,
    output wire [ReqWidth-1:0] cfg_icmp_priority,

    // 管理地址与端口配置
    output wire [31:0] cfg_mgmt_ipv4_addr,
    output wire [15:0] cfg_mgmt_udp_port,
    output wire [47:0] cfg_mgmt_mac,

    // 清除命令
    output wire cfg_arp_clear_cache,
    output wire cfg_arp_clear_pending,
    output wire cfg_stat_clear,

    // 免费ARP
    output wire [LocalIpv4Count:0] cfg_arp_announce_mask,
    output wire                    cfg_arp_announce_valid,
    input  wire                    cfg_arp_announce_ready,

    // 业务状态
    input wire stat_link_up,
    input wire stat_arp_rx_error,
    input wire stat_arp_ack_fifo_overflow_error,
    input wire stat_arp_pending_fifo_overflow_error,
    input wire stat_arp_query_src_not_local,
    input wire stat_arp_cache_clear_finish,
    input wire stat_arp_pending_clear_finish,
    input wire stat_ipv4_tx_drop,
    input wire stat_ipv6_tx_drop,
    input wire stat_icmp_ttl_error
);

  // cfg_cmd接收UDP配置请求并生成应答。
  // cfg_regs执行配置读写，保存配置并采样业务状态。

  // 配置执行请求
  wire         exec_valid;
  wire [  2:0] req_op;
  wire [  7:0] req_item;
  wire [  7:0] req_index;
  wire [  7:0] req_len;
  wire [127:0] req_value;

  // 配置执行应答
  wire [  7:0] rsp_status;
  wire [  7:0] rsp_len;
  wire [127:0] rsp_value;

  // UDP配置命令
  cfg_cmd #(
      .ReplyTtl     (ReplyTtl),
      .ReplyPriority(ReplyPriority),
      .ReqWidth     (ReqWidth)
  ) cfg_cmd_inst (
      .clk(clk),
      .rst(rst),

      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_svalid(axis_svalid),
      .axis_slast (axis_slast),
      .axis_sready(axis_sready),

      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (axis_musr),
      .axis_mvalid(axis_mvalid),
      .axis_mlast (axis_mlast),
      .axis_mready(axis_mready),

      .cfg_mgmt_ipv4_addr(cfg_mgmt_ipv4_addr),
      .cfg_mgmt_udp_port (cfg_mgmt_udp_port),

      .exec_valid(exec_valid),
      .req_op    (req_op),
      .req_item  (req_item),
      .req_index (req_index),
      .req_len   (req_len),
      .req_value (req_value),

      .rsp_status(rsp_status),
      .rsp_len   (rsp_len),
      .rsp_value (rsp_value)
  );

  // 配置寄存器与业务状态
  cfg_regs #(
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
      .DefaultMgmtMac     (DefaultMgmtMac)
  ) cfg_regs_inst (
      .clk(clk),
      .rst(rst),

      .exec_valid(exec_valid),
      .req_op    (req_op),
      .req_item  (req_item),
      .req_index (req_index),
      .req_len   (req_len),
      .req_value (req_value),

      .rsp_status(rsp_status),
      .rsp_len   (rsp_len),
      .rsp_value (rsp_value),

      .cfg_local_ip   (cfg_local_ip),
      .cfg_local_mac  (cfg_local_mac),
      .cfg_gateway_ip (cfg_gateway_ip),
      .cfg_subnet_mask(cfg_subnet_mask),

      .cfg_src_ipv6(cfg_src_ipv6),
      .cfg_src_mac (cfg_src_mac),
      .cfg_dst_ipv6(cfg_dst_ipv6),
      .cfg_dst_mac (cfg_dst_mac),

      .cfg_udp_ipv4_dst_port_range(cfg_udp_ipv4_dst_port_range),
      .cfg_udp_ipv6_dst_port_range(cfg_udp_ipv6_dst_port_range),

      .cfg_pending_time (cfg_pending_time),
      .cfg_arp_priority (cfg_arp_priority),
      .cfg_icmp_priority(cfg_icmp_priority),

      .cfg_mgmt_ipv4_addr(cfg_mgmt_ipv4_addr),
      .cfg_mgmt_udp_port (cfg_mgmt_udp_port),
      .cfg_mgmt_mac      (cfg_mgmt_mac),

      .cfg_arp_clear_cache   (cfg_arp_clear_cache),
      .cfg_arp_clear_pending (cfg_arp_clear_pending),
      .cfg_stat_clear        (cfg_stat_clear),
      .cfg_arp_announce_mask (cfg_arp_announce_mask),
      .cfg_arp_announce_valid(cfg_arp_announce_valid),
      .cfg_arp_announce_ready(cfg_arp_announce_ready),

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
