// -----------------------------------------------------------------------------
// File Name   : udp_ipv6_top.v
// Module Name : udp_ipv6_top
// Author      : LiXintao
// Created     : 2026-11-22
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : UDP over IPv6收发顶层，连接现有IPv6网络层的AXIS接口。
// Note        : 支持固定40字节IPv6头，Next Header直接为UDP，不解析扩展头。
//               TX输出UDP报文与IPv6头元数据。
//               TX输入usr从高到低为{UDP首部, IPv6首部, 请求}。
//               RX usr为{UDP首部,IPv6首部,MAC首部,末拍坏帧标志}。
//               多字节字段首个网络字节在低位；未匹配端口走末路，无载荷报文丢弃。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_ipv6_top #(
    parameter  integer RxPortCount          = 3,
    parameter  integer TxChannelCount       = 4,
    parameter  integer TxReqWidth           = 4,
    localparam integer EffectiveRxPortCount = (RxPortCount > 0) ? RxPortCount : 1,
    localparam integer TxUsrWidth           = TxReqWidth + 384,
    localparam integer RxUsrWidth           = 497,
    localparam integer Ipv6RxUsrWidth       = 433
) (
    input wire clk,
    input wire rst,

    input wire [EffectiveRxPortCount*32-1:0] cfg_dst_port_range,

    // rx
    input  wire [             511:0] rx_axis_sdata,
    input  wire [              63:0] rx_axis_skeep,
    input  wire                      rx_axis_slast,
    input  wire                      rx_axis_svalid,
    input  wire [Ipv6RxUsrWidth-1:0] rx_axis_susr,
    output wire                      rx_axis_sready,

    output wire [       512*(RxPortCount+1)-1:0] rx_axis_mdata,
    output wire [        64*(RxPortCount+1)-1:0] rx_axis_mkeep,
    output wire [                 RxPortCount:0] rx_axis_mlast,
    output wire [                 RxPortCount:0] rx_axis_mvalid,
    output wire [RxUsrWidth*(RxPortCount+1)-1:0] rx_axis_musr,
    input  wire [                 RxPortCount:0] rx_axis_mready,

    // tx
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
    output wire [TxReqWidth+320-1:0] tx_axis_musr,
    input  wire                      tx_axis_mready
);

  // 接收剥离UDP头，按目的端口分流。
  // 发送依次仲裁、计算长度和校验和、插入UDP头，并向网络层提供IPv6元数据。

  // 参数范围检查
  initial begin
    if (RxPortCount < 0 || TxChannelCount < 1 || TxReqWidth < 1) begin
      $display("错误：udp_ipv6_top：不支持的参数配置。");
      $finish;
    end
  end

  // 接收通路
  udp_ipv6_rx #(
      .RxPortCount(RxPortCount)
  ) udp_ipv6_rx_inst (
      .clk               (clk),
      .rst               (rst),
      .cfg_dst_port_range(cfg_dst_port_range),
      .axis_sdata        (rx_axis_sdata),
      .axis_skeep        (rx_axis_skeep),
      .axis_susr         (rx_axis_susr),
      .axis_svalid       (rx_axis_svalid),
      .axis_slast        (rx_axis_slast),
      .axis_sready       (rx_axis_sready),
      .axis_mdata        (rx_axis_mdata),
      .axis_mkeep        (rx_axis_mkeep),
      .axis_musr         (rx_axis_musr),
      .axis_mvalid       (rx_axis_mvalid),
      .axis_mlast        (rx_axis_mlast),
      .axis_mready       (rx_axis_mready)
  );

  // 发送通路
  udp_ipv6_tx #(
      .TxChannelCount(TxChannelCount),
      .ReqWidth      (TxReqWidth)
  ) udp_ipv6_tx_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (tx_axis_sdata),
      .axis_skeep (tx_axis_skeep),
      .axis_susr  (tx_axis_susr),
      .axis_svalid(tx_axis_svalid),
      .axis_slast (tx_axis_slast),
      .axis_sready(tx_axis_sready),
      .axis_mdata (tx_axis_mdata),
      .axis_mkeep (tx_axis_mkeep),
      .axis_musr  (tx_axis_musr),
      .axis_mvalid(tx_axis_mvalid),
      .axis_mlast (tx_axis_mlast),
      .axis_mready(tx_axis_mready)
  );

endmodule
`resetall
