// -----------------------------------------------------------------------------
// File Name   : eth_tx_mux.v
// Module Name : eth_tx_mux
// Author      : LiXintao
// Created     : 2026-09-24
// Version     : 2.1
// -----------------------------------------------------------------------------
// Description : 将多路以太网发送帧仲裁复用到一路
// Note        : usr数值越大越优先，同优先级按帧轮询；usr=0为无效请求
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module eth_tx_mux #(
    parameter  integer ChannelCount = 4,
    parameter  integer TxReqWidth   = 4,
    localparam integer TxUsrWidth   = TxReqWidth
) (
    input wire clk,
    input wire rst,

    input  wire [       512*ChannelCount-1:0] axis_sdata,
    input  wire [        64*ChannelCount-1:0] axis_skeep,
    input  wire [           ChannelCount-1:0] axis_slast,
    input  wire [           ChannelCount-1:0] axis_svalid,
    input  wire [TxUsrWidth*ChannelCount-1:0] axis_susr,
    output wire [           ChannelCount-1:0] axis_sready,

    output wire [         511:0] axis_mdata,
    output wire [          63:0] axis_mkeep,
    output wire                  axis_mlast,
    output wire                  axis_mvalid,
    output wire [TxUsrWidth-1:0] axis_musr,
    input  wire                  axis_mready
);

  // 多路发送帧按usr数值优先级仲裁，同优先级按帧轮询。

  // 参数范围检查
  initial begin
    if (ChannelCount < 1 || TxUsrWidth < 1) begin
      $display("错误：eth_tx_mux：ChannelCount和UsrWidth必须不小于1");
      $finish;
    end
  end

  // 发送帧仲裁
  axis_value_rr_arbiter #(
      .RequesterCount(ChannelCount),
      .DataWidth     (512),
      .UsrWidth      (TxUsrWidth),
      .ReqWidth      (TxReqWidth),
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
