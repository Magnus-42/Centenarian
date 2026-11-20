// -----------------------------------------------------------------------------
// File Name   : ipv6_tx_mux.v
// Module Name : ipv6_tx_mux
// Author      : LiXintao
// Created     : 2026-09-29
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : IPv6发送仲裁，将多路IPv6帧合并到一路。
// Note        : usr低ReqWidth位为优先级，大值优先，0无效，同优先级按编号递增轮询。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv6_tx_mux #(
    parameter integer TxChannelCount = 4,
    parameter integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth
) (
    input wire clk,
    input wire rst,

    // 入口
    input  wire [     512*TxChannelCount-1:0] axis_sdata,
    input  wire [      64*TxChannelCount-1:0] axis_skeep,
    input  wire [UsrWidth*TxChannelCount-1:0] axis_susr,
    input  wire [         TxChannelCount-1:0] axis_svalid,
    input  wire [         TxChannelCount-1:0] axis_slast,
    output wire [         TxChannelCount-1:0] axis_sready,

    // 出口
    output wire [       511:0] axis_mdata,
    output wire [        63:0] axis_mkeep,
    output wire [UsrWidth-1:0] axis_musr,
    output wire                axis_mvalid,
    output wire                axis_mlast,
    input  wire                axis_mready
);

  // 多路输入按数值优先级和帧边界仲裁，合并为一路输出。

  // 参数范围检查
  initial begin
    if (TxChannelCount < 1 || ReqWidth < 1) begin
      $display("错误：ipv6_tx_mux：TxChannelCount和ReqWidth必须不小于1。");
      $finish;
    end
  end

  // 数值优先级仲裁
  axis_value_rr_arbiter #(
      .RequesterCount(TxChannelCount),
      .DataWidth     (512),
      .UsrWidth      (UsrWidth),
      .ReqWidth      (ReqWidth),
      .LowReqFirst   (0),
      .LowFirst      (1)
  ) axis_value_rr_arbiter_inst (
      .clk        (clk),
      .rst        (rst),
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
      .axis_mready(axis_mready)
  );

endmodule
`resetall
