// -----------------------------------------------------------------------------
// File Name   : ipv4_tx.v
// Module Name : ipv4_tx
// Author      : Lixintao
// Created     : 2026-11-25
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : IPv4发送链，逐路计算首部校验和并加头，按完整报文仲裁。
// Note        : 各路输入data为IPv4负载，usr为{IPv4首部,请求}。
//               输出data为完整IP报文，usr仅保留请求。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv4_tx #(
    parameter  integer TxChannelCount = 1,
    parameter  integer ReqWidth       = 4,
    localparam integer UsrWidth       = ReqWidth + 160
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
      $display("错误：ipv4_tx：通道数量和请求位宽必须不小于1。");
      $finish;
    end
  end

  // 封装头部后的IP报文
  wire [     512*TxChannelCount-1:0] header_data;
  wire [      64*TxChannelCount-1:0] header_keep;
  wire [ReqWidth*TxChannelCount-1:0] header_usr;
  wire [         TxChannelCount-1:0] header_valid;
  wire [         TxChannelCount-1:0] header_last;
  wire [         TxChannelCount-1:0] header_ready;
  genvar tx_index;

  // 各路独立加头
  for (tx_index = 0; tx_index < TxChannelCount; tx_index = tx_index + 1) begin : gen_tx_header
    // 首部校验和接口
    wire [       511:0] checksum_data;
    wire [        63:0] checksum_keep;
    wire [UsrWidth-1:0] checksum_usr;
    wire                checksum_last;
    wire                checksum_valid;
    wire                checksum_ready;

    // IPv4首部校验和
    ipv4_header_checksum #(
        .ReqWidth(ReqWidth)
    ) ipv4_header_checksum_inst (
        .clk        (clk),
        .rst        (rst),
        .axis_sdata (axis_sdata[tx_index*512+:512]),
        .axis_skeep (axis_skeep[tx_index*64+:64]),
        .axis_susr  (axis_susr[tx_index*UsrWidth+:UsrWidth]),
        .axis_slast (axis_slast[tx_index]),
        .axis_svalid(axis_svalid[tx_index]),
        .axis_sready(axis_sready[tx_index]),
        .axis_mdata (checksum_data),
        .axis_mkeep (checksum_keep),
        .axis_musr  (checksum_usr),
        .axis_mlast (checksum_last),
        .axis_mvalid(checksum_valid),
        .axis_mready(checksum_ready)
    );

    // IPv4头插入
    ipv4_header_add #(
        .ReqWidth(ReqWidth)
    ) ipv4_header_add_inst (
        .clk        (clk),
        .rst        (rst),
        .axis_sdata (checksum_data),
        .axis_skeep (checksum_keep),
        .axis_susr  (checksum_usr),
        .axis_slast (checksum_last),
        .axis_svalid(checksum_valid),
        .axis_sready(checksum_ready),
        .axis_mdata (header_data[tx_index*512+:512]),
        .axis_mkeep (header_keep[tx_index*64+:64]),
        .axis_musr  (header_usr[tx_index*ReqWidth+:ReqWidth]),
        .axis_mlast (header_last[tx_index]),
        .axis_mvalid(header_valid[tx_index]),
        .axis_mready(header_ready[tx_index])
    );
  end

  // 发送仲裁
  ipv4_tx_mux #(
      .TxChannelCount(TxChannelCount),
      .ReqWidth      (ReqWidth)
  ) ipv4_tx_mux_inst (
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
