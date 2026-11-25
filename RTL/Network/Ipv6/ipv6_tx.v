// -----------------------------------------------------------------------------
// File Name   : ipv6_tx.v
// Module Name : ipv6_tx
// Author      : Lixintao
// Created     : 2026-11-25
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : IPv6发送链，根据首部侧带添加固定40字节IPv6头。
// Note        : 输入data为IPv6负载，usr为{IPv6首部,请求}。
//               输出data为完整IP报文，usr仅保留请求。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv6_tx #(
    parameter  integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth + 320
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
      $display("错误：ipv6_tx：ReqWidth必须不小于1。");
      $finish;
    end
  end

  // IPv6头插入
  ipv6_header_add #(
      .ReqWidth(ReqWidth)
  ) ipv6_header_add_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_slast (axis_slast),
      .axis_svalid(axis_svalid),
      .axis_sready(axis_sready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (axis_musr),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid),
      .axis_mready(axis_mready)
  );

endmodule
`resetall
