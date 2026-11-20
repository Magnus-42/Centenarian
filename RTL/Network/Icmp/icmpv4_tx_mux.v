// -----------------------------------------------------------------------------
// File Name   : icmpv4_tx_mux.v
// Module Name : icmpv4_tx_mux
// Author      : LiXintao
// Created     : 2026-10-19
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : ICMPv4发送仲裁，将用户报文与回显应答合并。
// Note        : usr低ReqWidth位大值优先，0为无效；同优先级按编号递增轮询，帧内保持选择。
//               有效请求的优先级须非零；0不参与仲裁，不作为自动丢包标志。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module icmpv4_tx_mux #(
    parameter  integer PortCount = 2,
    parameter  integer ReqWidth  = 4,
    localparam integer UsrWidth  = ReqWidth
) (
    input wire clk,
    input wire rst,

    input  wire [     512*PortCount-1:0] axis_sdata,
    input  wire [      64*PortCount-1:0] axis_skeep,
    input  wire [UsrWidth*PortCount-1:0] axis_susr,
    input  wire [         PortCount-1:0] axis_svalid,
    input  wire [         PortCount-1:0] axis_slast,
    output wire [         PortCount-1:0] axis_sready,

    output wire [       511:0] axis_mdata,
    output wire [        63:0] axis_mkeep,
    output wire [UsrWidth-1:0] axis_musr,
    output wire                axis_mvalid,
    output wire                axis_mlast,
    input  wire                axis_mready
);

  // 用户报文与回显应答按数值优先级和帧边界仲裁。

  // 参数范围检查
  initial begin
    if (PortCount < 1 || UsrWidth < 1 || ReqWidth < 1 || ReqWidth > UsrWidth) begin
      $display("错误：icmpv4_tx_mux：不支持的参数配置。");
      $finish;
    end
  end

  // 数值优先级仲裁
  axis_value_rr_arbiter #(
      .RequesterCount(PortCount),
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
