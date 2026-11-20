// -----------------------------------------------------------------------------
// File Name   : ipv4_eth_tx.v
// Module Name : ipv4_eth_tx
// Author      : LiXintao
// Created     : 2026-09-18
// Version     : v2.0
// -----------------------------------------------------------------------------
// Description : IPv4发送通路，连接ARP查询与以太网头插入。
// Note        : ARP结果须满足ipv4_arp_service的应答时序。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv4_eth_tx #(
    parameter  integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth
) (
    input wire clk,
    input wire rst,

    input wire cfg_stat_clear,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire [UsrWidth-1:0] axis_susr,
    input  wire                axis_svalid,
    input  wire                axis_slast,
    output wire                axis_sready,

    output wire [31:0] query_src_ip,
    output wire [31:0] query_dst_ip,
    output wire        query_valid_pulse,
    input  wire [47:0] arp_dst_mac,
    input  wire [47:0] arp_src_mac,
    input  wire        arp_miss,
    input  wire        arp_valid,

    output wire [       511:0] axis_mdata,
    output wire [        63:0] axis_mkeep,
    output wire [UsrWidth-1:0] axis_musr,
    output wire                axis_mvalid,
    output wire                axis_mlast,
    input  wire                axis_mready,

    output wire stat_tx_drop
);

  // ARP查询服务缓存应答并过滤未命中的帧。
  // 命中帧插入以太网头后输出。

  // ARP处理后的帧
  wire [       511:0] arp_frame_data;
  wire [        63:0] arp_frame_keep;
  wire                arp_frame_last;
  wire                arp_frame_valid;
  wire                arp_frame_ready;
  wire [UsrWidth-1:0] arp_frame_usr;

  // 首拍MAC地址
  wire [        47:0] dst_mac;
  wire [        47:0] src_mac;

  // ARP查询与未命中帧过滤
  ipv4_arp_service #(
      .ReqWidth(ReqWidth)
  ) ipv4_arp_service_inst (
      .clk              (clk),
      .rst              (rst),
      .cfg_stat_clear   (cfg_stat_clear),
      .axis_sdata       (axis_sdata),
      .axis_skeep       (axis_skeep),
      .axis_susr        (axis_susr),
      .axis_svalid      (axis_svalid),
      .axis_slast       (axis_slast),
      .axis_sready      (axis_sready),
      .axis_mdata       (arp_frame_data),
      .axis_mkeep       (arp_frame_keep),
      .axis_musr        (arp_frame_usr),
      .axis_mvalid      (arp_frame_valid),
      .axis_mlast       (arp_frame_last),
      .axis_mready      (arp_frame_ready),
      .dst_mac          (dst_mac),
      .src_mac          (src_mac),
      .query_dst_ip     (query_dst_ip),
      .query_src_ip     (query_src_ip),
      .query_valid_pulse(query_valid_pulse),
      .arp_dst_mac      (arp_dst_mac),
      .arp_src_mac      (arp_src_mac),
      .arp_miss         (arp_miss),
      .arp_valid        (arp_valid),
      .stat_tx_drop     (stat_tx_drop)
  );

  // 以太网头插入
  ipv4_eth_header_add #(
      .ReqWidth(ReqWidth)
  ) ipv4_eth_header_add_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (arp_frame_data),
      .axis_skeep (arp_frame_keep),
      .axis_susr  (arp_frame_usr),
      .axis_svalid(arp_frame_valid),
      .axis_slast (arp_frame_last),
      .axis_sready(arp_frame_ready),
      .dst_mac    (dst_mac),
      .src_mac    (src_mac),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (axis_musr),
      .axis_mvalid(axis_mvalid),
      .axis_mlast (axis_mlast),
      .axis_mready(axis_mready)
  );

endmodule
`resetall
