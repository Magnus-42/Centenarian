// -----------------------------------------------------------------------------
// File Name   : ipv6_top.v
// Module Name : ipv6_top
// Author      : LiXintao
// Created     : 2026-10-11
// Version     : v7.0
// -----------------------------------------------------------------------------
// Description : IPv6收发顶层，连接收发链、发送仲裁与MAC查表。
// Note        : 接收输出共RxTypeCount+1路，末路为默认通道；无NDP。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv6_top #(
    localparam integer MacRxUsrWidth    = 113,
    parameter  integer RxTypeCount      = 3,
    parameter  integer DstMacEntryCount = 8,
    parameter  integer SrcMacEntryCount = 8,
    parameter  integer TxChannelCount   = 3,
    parameter  integer TxReqWidth       = 4,                // TX 侧仲裁值位宽
    localparam integer RxUsrWidth       = 433,
    localparam integer TxUsrWidth       = TxReqWidth + 320
) (
    input wire clk,
    input wire rst,

    input wire cfg_stat_clear,

    input wire [RxTypeCount*8-1:0] cfg_rx_type_dict,

    input  wire [            511:0] rx_axis_sdata,
    input  wire [             63:0] rx_axis_skeep,
    input  wire                     rx_axis_slast,
    input  wire                     rx_axis_svalid,
    input  wire [MacRxUsrWidth-1:0] rx_axis_susr,
    output wire                     rx_axis_sready,

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

    output wire [             511:0] tx_axis_mdata,
    output wire [              63:0] tx_axis_mkeep,
    output wire                      tx_axis_mlast,
    output wire                      tx_axis_mvalid,
    output wire [TxReqWidth+112-1:0] tx_axis_musr,
    input  wire                      tx_axis_mready,

    input wire [128*DstMacEntryCount-1:0] cfg_dst_ipv6,
    input wire [ 48*DstMacEntryCount-1:0] cfg_dst_mac,
    input wire [128*SrcMacEntryCount-1:0] cfg_src_ipv6,
    input wire [ 48*SrcMacEntryCount-1:0] cfg_src_mac,

    output wire stat_tx_drop
);

  // 接收通路剥离本层IP头，按Next Header分流。
  // 发送通路逐路封装IP报文，再完成仲裁、配置表查找并输出MAC首部侧带。

  // 参数范围检查
  initial begin
    if (RxTypeCount < 1 || TxChannelCount < 1 || TxReqWidth < 1 || DstMacEntryCount < 1 ||
        SrcMacEntryCount < 1) begin
      $display("错误：ipv6_top：不支持的参数配置。");
      $finish;
    end
  end

  // IP发送输出
  wire [         511:0] mux_data;
  wire [          63:0] mux_keep;
  wire                  mux_last;
  wire                  mux_valid;
  wire [TxReqWidth-1:0] mux_usr;
  wire                  mux_ready;

  // 接收通路
  ipv6_rx #(
      .TypeCount(RxTypeCount)
  ) ipv6_rx_inst (
      .clk          (clk),
      .rst          (rst),
      .cfg_type_dict(cfg_rx_type_dict),
      .axis_sdata   (rx_axis_sdata),
      .axis_skeep   (rx_axis_skeep),
      .axis_susr    (rx_axis_susr),
      .axis_svalid  (rx_axis_svalid),
      .axis_slast   (rx_axis_slast),
      .axis_sready  (rx_axis_sready),
      .axis_mdata   (rx_axis_mdata),
      .axis_mkeep   (rx_axis_mkeep),
      .axis_musr    (rx_axis_musr),
      .axis_mvalid  (rx_axis_mvalid),
      .axis_mlast   (rx_axis_mlast),
      .axis_mready  (rx_axis_mready)
  );

  // 发送通路
  ipv6_tx #(
      .TxChannelCount(TxChannelCount),
      .ReqWidth      (TxReqWidth)
  ) ipv6_tx_inst (
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

  // 查表与MAC首部侧带
  ipv6_mac_lookup #(
      .DstMacEntryCount(DstMacEntryCount),
      .SrcMacEntryCount(SrcMacEntryCount),
      .ReqWidth        (TxReqWidth)
  ) ipv6_mac_lookup_inst (
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
