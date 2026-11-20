// -----------------------------------------------------------------------------
// File Name   : ipv4_top.v
// Module Name : ipv4_top
// Author      : LiXintao
// Created     : 2026-10-11
// Version     : v4.0
// -----------------------------------------------------------------------------
// Description : IPv4收发顶层，连接以太网封装、协议分流与发送仲裁。
// Note        : 接收输出共RxTypeCount+1路，末路为默认通道
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv4_top #(
    parameter integer RxTypeCount = 4,
    localparam integer RxUsrWidth = 97,
    parameter integer TxChannelCount = 3,
    parameter integer TxReqWidth = 4,
    localparam integer TxUsrWidth = TxReqWidth
) (
    input wire clk,
    input wire rst,

    input wire cfg_stat_clear,

    input wire [RxTypeCount*8-1:0] cfg_rx_type_dict,

    input  wire [511:0] rx_axis_sdata,
    input  wire [ 63:0] rx_axis_skeep,
    input  wire         rx_axis_susr,
    input  wire         rx_axis_svalid,
    input  wire         rx_axis_slast,
    output wire         rx_axis_sready,

    output wire [       512*(RxTypeCount+1)-1:0] rx_axis_mdata,
    output wire [        64*(RxTypeCount+1)-1:0] rx_axis_mkeep,
    output wire [RxUsrWidth*(RxTypeCount+1)-1:0] rx_axis_musr,
    output wire [                 RxTypeCount:0] rx_axis_mvalid,
    output wire [                 RxTypeCount:0] rx_axis_mlast,
    input  wire [                 RxTypeCount:0] rx_axis_mready,

    input  wire [       512*TxChannelCount-1:0] tx_axis_sdata,
    input  wire [        64*TxChannelCount-1:0] tx_axis_skeep,
    input  wire [TxUsrWidth*TxChannelCount-1:0] tx_axis_susr,
    input  wire [           TxChannelCount-1:0] tx_axis_svalid,
    input  wire [           TxChannelCount-1:0] tx_axis_slast,
    output wire [           TxChannelCount-1:0] tx_axis_sready,

    output wire [         511:0] tx_axis_mdata,
    output wire [          63:0] tx_axis_mkeep,
    output wire [TxUsrWidth-1:0] tx_axis_musr,
    output wire                  tx_axis_mvalid,
    output wire                  tx_axis_mlast,
    input  wire                  tx_axis_mready,

    output wire [31:0] query_src_ip,
    output wire [31:0] query_dst_ip,
    output wire        query_valid_pulse,
    input  wire [47:0] arp_dst_mac,
    input  wire [47:0] arp_src_mac,
    input  wire        arp_miss,
    input  wire        arp_valid,

    output wire stat_tx_drop
);

  // 接收通路剥离以太网头，按IPv4协议字段分流。
  // 发送通路依次完成仲裁、ARP查询和以太网封装。

  // 接收通路
  wire [         511:0] rx_data;
  wire [          63:0] rx_keep;
  wire                  rx_last;
  wire                  rx_valid;
  wire [RxUsrWidth-1:0] rx_usr;
  wire                  rx_ready;

  // 接收MAC地址
  wire [          47:0] dst_mac;
  wire [          47:0] src_mac;

  // 发送仲裁接口
  wire [         511:0] mux_data;
  wire [          63:0] mux_keep;
  wire                  mux_last;
  wire                  mux_valid;
  wire [TxUsrWidth-1:0] mux_usr;
  wire                  mux_ready;

  // 接收通路
  //// 以太网解封装
  ipv4_eth_rx ipv4_eth_rx_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (rx_axis_sdata),
      .axis_skeep (rx_axis_skeep),
      .axis_susr  (rx_axis_susr),
      .axis_svalid(rx_axis_svalid),
      .axis_slast (rx_axis_slast),
      .axis_sready(rx_axis_sready),
      .axis_mdata (rx_data),
      .axis_mkeep (rx_keep),
      .axis_musr  (rx_usr[0]),
      .axis_mvalid(rx_valid),
      .axis_mlast (rx_last),
      .axis_mready(rx_ready),
      .dst_mac    (dst_mac),
      .src_mac    (src_mac)
  );
  //// 接收边带
  assign rx_usr[RxUsrWidth-1:1] = {src_mac, dst_mac};
  //// 协议分流
  ipv4_proto_demux #(
      .TypeCount(RxTypeCount)
  ) ipv4_proto_demux_inst (
      .clk          (clk),
      .rst          (rst),
      .cfg_type_dict(cfg_rx_type_dict),
      .axis_sdata   (rx_data),
      .axis_skeep   (rx_keep),
      .axis_susr    (rx_usr),
      .axis_svalid  (rx_valid),
      .axis_slast   (rx_last),
      .axis_sready  (rx_ready),
      .axis_mdata   (rx_axis_mdata),
      .axis_mkeep   (rx_axis_mkeep),
      .axis_musr    (rx_axis_musr),
      .axis_mvalid  (rx_axis_mvalid),
      .axis_mlast   (rx_axis_mlast),
      .axis_mready  (rx_axis_mready)
  );

  // 发送通路
  //// 发送仲裁
  ipv4_tx_mux #(
      .TxChannelCount(TxChannelCount),
      .ReqWidth      (TxReqWidth)
  ) ipv4_tx_mux_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (tx_axis_sdata),
      .axis_skeep (tx_axis_skeep),
      .axis_susr  (tx_axis_susr),
      .axis_svalid(tx_axis_svalid),
      .axis_slast (tx_axis_slast),
      .axis_sready(tx_axis_sready),
      .axis_mdata (mux_data),
      .axis_mkeep (mux_keep),
      .axis_musr  (mux_usr),
      .axis_mvalid(mux_valid),
      .axis_mlast (mux_last),
      .axis_mready(mux_ready)
  );
  //// ARP查询与以太网封装
  ipv4_eth_tx #(
      .ReqWidth(TxReqWidth)
  ) ipv4_eth_tx_inst (
      .clk              (clk),
      .rst              (rst),
      .cfg_stat_clear   (cfg_stat_clear),
      .axis_sdata       (mux_data),
      .axis_skeep       (mux_keep),
      .axis_susr        (mux_usr),
      .axis_svalid      (mux_valid),
      .axis_slast       (mux_last),
      .axis_sready      (mux_ready),
      .query_src_ip     (query_src_ip),
      .query_dst_ip     (query_dst_ip),
      .query_valid_pulse(query_valid_pulse),
      .arp_dst_mac      (arp_dst_mac),
      .arp_src_mac      (arp_src_mac),
      .arp_miss         (arp_miss),
      .arp_valid        (arp_valid),
      .axis_mdata       (tx_axis_mdata),
      .axis_mkeep       (tx_axis_mkeep),
      .axis_musr        (tx_axis_musr),
      .axis_mvalid      (tx_axis_mvalid),
      .axis_mlast       (tx_axis_mlast),
      .axis_mready      (tx_axis_mready),
      .stat_tx_drop     (stat_tx_drop)
  );

endmodule
`resetall
