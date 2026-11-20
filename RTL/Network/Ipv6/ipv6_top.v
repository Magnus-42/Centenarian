// -----------------------------------------------------------------------------
// File Name   : ipv6_top.v
// Module Name : ipv6_top
// Author      : LiXintao
// Created     : 2026-10-11
// Version     : v7.0
// -----------------------------------------------------------------------------
// Description : IPv6收发顶层，连接解封装、分流、仲裁与查表封装。
// Note        : 接收输出共RxTypeCount+1路，末路为默认通道；无NDP。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv6_top #(
    parameter integer RxTypeCount = 3,
    parameter integer DstMacEntryCount = 8,
    parameter integer SrcMacEntryCount = 8,
    parameter integer TxChannelCount = 3,
    parameter integer TxReqWidth = 4,  // TX 侧仲裁值位宽
    localparam integer RxUsrWidth = 97,
    localparam integer TxUsrWidth = TxReqWidth
) (
    input wire clk,
    input wire rst,

    input wire cfg_stat_clear,

    input wire [RxTypeCount*8-1:0] cfg_rx_type_dict,

    input  wire [511:0] rx_axis_sdata,
    input  wire [ 63:0] rx_axis_skeep,
    input  wire         rx_axis_slast,
    input  wire         rx_axis_svalid,
    input  wire         rx_axis_susr,
    output wire         rx_axis_sready,

    output wire [       512*(RxTypeCount+1)-1:0] rx_axis_mdata,
    output wire [        64*(RxTypeCount+1)-1:0] rx_axis_mkeep,
    output wire [                 RxTypeCount:0] rx_axis_mlast,
    output wire [                 RxTypeCount:0] rx_axis_mvalid,
    output wire [RxUsrWidth*(RxTypeCount+1)-1:0] rx_axis_musr,
    input  wire [                 RxTypeCount:0] rx_axis_mready,

    input  wire [       512*TxChannelCount-1:0] tx_axis_sdata,
    input  wire [        64*TxChannelCount-1:0] tx_axis_skeep,
    input  wire [           TxChannelCount-1:0] tx_axis_slast,
    input  wire [           TxChannelCount-1:0] tx_axis_svalid,
    input  wire [TxUsrWidth*TxChannelCount-1:0] tx_axis_susr,
    output wire [           TxChannelCount-1:0] tx_axis_sready,

    output wire [         511:0] tx_axis_mdata,
    output wire [          63:0] tx_axis_mkeep,
    output wire                  tx_axis_mlast,
    output wire                  tx_axis_mvalid,
    output wire [TxUsrWidth-1:0] tx_axis_musr,
    input  wire                  tx_axis_mready,

    input wire [128*DstMacEntryCount-1:0] cfg_dst_ipv6,
    input wire [ 48*DstMacEntryCount-1:0] cfg_dst_mac,
    input wire [128*SrcMacEntryCount-1:0] cfg_src_ipv6,
    input wire [ 48*SrcMacEntryCount-1:0] cfg_src_mac,

    output wire stat_tx_drop
);

  // 接收通路剥离以太网头，按Next Header分流。
  // 发送通路依次完成仲裁、配置表查找和以太网封装。

  // 参数范围检查
  initial begin
    if (RxTypeCount < 1 || TxChannelCount < 1 || TxReqWidth < 1 || DstMacEntryCount < 1 ||
        SrcMacEntryCount < 1) begin
      $display("错误：ipv6_top：不支持的参数配置。");
      $finish;
    end
  end

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

  // 发送通路
  wire [         511:0] mux_data;
  wire [          63:0] mux_keep;
  wire                  mux_last;
  wire                  mux_valid;
  wire [TxUsrWidth-1:0] mux_usr;
  wire                  mux_ready;

  // 接收通路
  //// 以太网解封装
  ipv6_eth_rx ipv6_eth_rx_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (rx_axis_sdata),
      .axis_skeep (rx_axis_skeep),
      .axis_slast (rx_axis_slast),
      .axis_svalid(rx_axis_svalid),
      .axis_susr  (rx_axis_susr),
      .axis_sready(rx_axis_sready),
      .axis_mdata (rx_data),
      .axis_mkeep (rx_keep),
      .axis_mlast (rx_last),
      .axis_mvalid(rx_valid),
      .axis_mready(rx_ready),
      .axis_musr  (rx_usr[0]),
      .dst_mac    (dst_mac),
      .src_mac    (src_mac)
  );
  //// 接收边带
  assign rx_usr[RxUsrWidth-1:1] = {src_mac, dst_mac};
  //// 协议分流
  ipv6_proto_demux #(
      .TypeCount(RxTypeCount)
  ) ipv6_proto_demux_inst (
      .clk          (clk),
      .rst          (rst),
      .cfg_type_dict(cfg_rx_type_dict),
      .axis_sdata   (rx_data),
      .axis_skeep   (rx_keep),
      .axis_slast   (rx_last),
      .axis_svalid  (rx_valid),
      .axis_susr    (rx_usr),
      .axis_sready  (rx_ready),
      .axis_mdata   (rx_axis_mdata),
      .axis_mkeep   (rx_axis_mkeep),
      .axis_mlast   (rx_axis_mlast),
      .axis_mvalid  (rx_axis_mvalid),
      .axis_musr    (rx_axis_musr),
      .axis_mready  (rx_axis_mready)
  );

  // 发送通路
  //// 帧仲裁
  ipv6_tx_mux #(
      .TxChannelCount(TxChannelCount),
      .ReqWidth      (TxReqWidth)
  ) ipv6_tx_mux_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (tx_axis_sdata),
      .axis_skeep (tx_axis_skeep),
      .axis_slast (tx_axis_slast),
      .axis_svalid(tx_axis_svalid),
      .axis_susr  (tx_axis_susr),
      .axis_sready(tx_axis_sready),
      .axis_mdata (mux_data),
      .axis_mkeep (mux_keep),
      .axis_mlast (mux_last),
      .axis_mvalid(mux_valid),
      .axis_musr  (mux_usr),
      .axis_mready(mux_ready)
  );
  //// 查表与封装
  ipv6_eth_tx #(
      .DstMacEntryCount(DstMacEntryCount),
      .SrcMacEntryCount(SrcMacEntryCount),
      .ReqWidth(TxReqWidth)
  ) ipv6_eth_tx_inst (
      .clk           (clk),
      .rst           (rst),
      .cfg_stat_clear(cfg_stat_clear),
      .axis_sdata    (mux_data),
      .axis_skeep    (mux_keep),
      .axis_slast    (mux_last),
      .axis_svalid   (mux_valid),
      .axis_susr     (mux_usr),
      .axis_sready   (mux_ready),
      .cfg_dst_ipv6  (cfg_dst_ipv6),
      .cfg_dst_mac   (cfg_dst_mac),
      .cfg_src_ipv6  (cfg_src_ipv6),
      .cfg_src_mac   (cfg_src_mac),
      .axis_mdata    (tx_axis_mdata),
      .axis_mkeep    (tx_axis_mkeep),
      .axis_mlast    (tx_axis_mlast),
      .axis_mvalid   (tx_axis_mvalid),
      .axis_musr     (tx_axis_musr),
      .axis_mready   (tx_axis_mready),
      .stat_tx_drop  (stat_tx_drop)
  );

endmodule
`resetall
