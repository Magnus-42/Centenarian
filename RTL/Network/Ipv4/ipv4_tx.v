// -----------------------------------------------------------------------------
// File Name   : ipv4_tx.v
// Module Name : ipv4_tx
// Author      : Lixintao
// Created     : 2026-11-25
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : IPv4发送链，计算首部校验和并添加固定20字节IPv4头。
// Note        : 输入data为IPv4负载，usr为{IPv4首部,请求}。
//               输出data为完整IP报文，usr仅保留请求。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv4_tx #(
    parameter  integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth + 160
) (
    input wire clk,
    input wire rst,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire                axis_slast,
    input  wire                axis_svalid,
    input  wire [UsrWidth-1:0] axis_susr,
    output wire                axis_sready,

    output wire [       511:0] axis_mdata,
    output wire [        63:0] axis_mkeep,
    output wire                axis_mlast,
    output wire                axis_mvalid,
    output wire [ReqWidth-1:0] axis_musr,
    input  wire                axis_mready
);

  // 参数范围检查
  initial begin
    if (ReqWidth < 1) begin
      $display("错误：ipv4_tx：ReqWidth必须不小于1。");
      $finish;
    end
  end

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
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_slast (axis_slast),
      .axis_svalid(axis_svalid),
      .axis_sready(axis_sready),
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
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (axis_musr),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid),
      .axis_mready(axis_mready)
  );

endmodule
`resetall
