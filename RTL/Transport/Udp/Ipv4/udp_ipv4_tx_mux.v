// -----------------------------------------------------------------------------
// File Name   : udp_ipv4_tx_mux.v
// Module Name : udp_ipv4_tx_mux
// Author      : LiXintao
// Created     : 2026-10-12
// Version     : v1.0

// Description : UDP出口复用: IPV4帧仲裁复用到一路
// Note        : 低ReqWidth位大值优先，0无效；同值按通道编号递增轮询。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_ipv4_tx_mux #(
    parameter integer TxChannelCount = 4,
    parameter integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth + 104
) (
    input wire clk,
    input wire rst,

    input  wire [     512*TxChannelCount-1:0] axis_sdata,
    input  wire [      64*TxChannelCount-1:0] axis_skeep,
    input  wire [         TxChannelCount-1:0] axis_slast,
    input  wire [         TxChannelCount-1:0] axis_svalid,
    input  wire [UsrWidth*TxChannelCount-1:0] axis_susr,
    output wire [         TxChannelCount-1:0] axis_sready,

    output wire [       511:0] axis_mdata,
    output wire [        63:0] axis_mkeep,
    output wire                axis_mlast,
    output wire                axis_mvalid,
    output wire [UsrWidth-1:0] axis_musr,
    input  wire                axis_mready
);

  // 按帧进行数值优先级仲裁，完整usr随数据同步缓存。

  // 参数范围检查
  initial begin
    if (TxChannelCount < 1 || ReqWidth < 1) begin
      $display("错误：udp_ipv4_tx_mux：不支持的参数配置。");
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
