// -----------------------------------------------------------------------------
// File Name   : ipv6_tx.v
// Module Name : ipv6_tx
// Author      : Lixintao
// Created     : 2026-11-25
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : IPv6发送链，逐路添加基本头，按完整报文仲裁。
// Note        : 各路输入data为IPv6负载，usr为{IPv6首部,请求}。
//               输出data为完整IP报文，usr仅保留请求。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv6_tx #(
    parameter  integer TxChannelCount = 1,
    parameter  integer ReqWidth       = 4,
    localparam integer UsrWidth       = ReqWidth + 320
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
    output wire [ReqWidth-1:0] axis_musr,
    input  wire                axis_mready
);

  // 参数范围检查
  initial begin
    if (TxChannelCount < 1 || ReqWidth < 1) begin
      $display("错误：ipv6_tx：通道数量和请求位宽必须不小于1。");
      $finish;
    end
  end

  // 各路独立加头
  wire [     512*TxChannelCount-1:0] header_data;
  wire [      64*TxChannelCount-1:0] header_keep;
  wire [ReqWidth*TxChannelCount-1:0] header_usr;
  wire [         TxChannelCount-1:0] header_valid;
  wire [         TxChannelCount-1:0] header_last;
  wire [         TxChannelCount-1:0] header_ready;
  genvar tx_index;

  // 各路独立加头
  for (tx_index = 0; tx_index < TxChannelCount; tx_index = tx_index + 1) begin : gen_tx_header
    // IPv6头插入
    ipv6_header_add #(
        .ReqWidth(ReqWidth)
    ) ipv6_header_add_inst (
        .clk        (clk),
        .rst        (rst),
        .axis_sdata (axis_sdata[tx_index*512+:512]),
        .axis_skeep (axis_skeep[tx_index*64+:64]),
        .axis_susr  (axis_susr[tx_index*UsrWidth+:UsrWidth]),
        .axis_slast (axis_slast[tx_index]),
        .axis_svalid(axis_svalid[tx_index]),
        .axis_sready(axis_sready[tx_index]),
        .axis_mdata (header_data[tx_index*512+:512]),
        .axis_mkeep (header_keep[tx_index*64+:64]),
        .axis_musr  (header_usr[tx_index*ReqWidth+:ReqWidth]),
        .axis_mlast (header_last[tx_index]),
        .axis_mvalid(header_valid[tx_index]),
        .axis_mready(header_ready[tx_index])
    );
  end

  // 发送仲裁
  ipv6_tx_mux #(
      .TxChannelCount(TxChannelCount),
      .ReqWidth      (ReqWidth)
  ) ipv6_tx_mux_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (header_data),
      .axis_skeep (header_keep),
      .axis_susr  (header_usr),
      .axis_svalid(header_valid),
      .axis_slast (header_last),
      .axis_sready(header_ready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (axis_musr),
      .axis_mvalid(axis_mvalid),
      .axis_mlast (axis_mlast),
      .axis_mready(axis_mready)
  );

endmodule
`resetall
