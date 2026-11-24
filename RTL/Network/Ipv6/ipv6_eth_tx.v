// -----------------------------------------------------------------------------
// File Name   : ipv6_eth_tx.v
// Module Name : ipv6_eth_tx
// Author      : LiXintao
// Created     : 2026-10-11
// Version     : v2.0
// -----------------------------------------------------------------------------
// Description : IPv6发送通路，连接配置表查找与MAC首部元数据输出。
// Note        : 任一地址未命中则丢弃整帧，不进行NDP查询。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv6_eth_tx #(
    parameter  integer DstMacEntryCount = 8,
    parameter  integer SrcMacEntryCount = 8,
    parameter  integer ReqWidth         = 4,
    localparam integer UsrWidth         = ReqWidth,
    localparam integer MacUsrWidth      = ReqWidth + 112
) (
    input wire clk,
    input wire rst,

    input wire cfg_stat_clear,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire                axis_slast,
    input  wire                axis_svalid,
    input  wire [UsrWidth-1:0] axis_susr,
    output wire                axis_sready,

    input wire [128*DstMacEntryCount-1:0] cfg_dst_ipv6,
    input wire [ 48*DstMacEntryCount-1:0] cfg_dst_mac,
    input wire [128*SrcMacEntryCount-1:0] cfg_src_ipv6,
    input wire [ 48*SrcMacEntryCount-1:0] cfg_src_mac,

    output wire [          511:0] axis_mdata,
    output wire [           63:0] axis_mkeep,
    output wire                   axis_mlast,
    output wire                   axis_mvalid,
    output wire [MacUsrWidth-1:0] axis_musr,
    input  wire                   axis_mready,

    output wire stat_tx_drop
);

  // 配置表查找过滤未命中的帧。
  // 命中帧输出完整IP包与MAC首部元数据。

  // 参数范围检查
  initial begin
    if (DstMacEntryCount < 1 || SrcMacEntryCount < 1 || ReqWidth < 1) begin
      $display("错误：ipv6_eth_tx：不支持的参数配置。");
      $finish;
    end
  end

  // 配置表查找与整帧过滤
  ipv6_mac_lookup #(
      .DstMacEntryCount(DstMacEntryCount),
      .SrcMacEntryCount(SrcMacEntryCount),
      .ReqWidth(ReqWidth)
  ) ipv6_mac_lookup_inst (
      .clk           (clk),
      .rst           (rst),
      .cfg_stat_clear(cfg_stat_clear),
      .cfg_dst_ipv6  (cfg_dst_ipv6),
      .cfg_dst_mac   (cfg_dst_mac),
      .cfg_src_ipv6  (cfg_src_ipv6),
      .cfg_src_mac   (cfg_src_mac),
      .axis_sdata    (axis_sdata),
      .axis_skeep    (axis_skeep),
      .axis_slast    (axis_slast),
      .axis_svalid   (axis_svalid),
      .axis_susr     (axis_susr),
      .axis_sready   (axis_sready),
      .axis_mdata    (axis_mdata),
      .axis_mkeep    (axis_mkeep),
      .axis_mlast    (axis_mlast),
      .axis_mvalid   (axis_mvalid),
      .axis_musr     (axis_musr),
      .axis_mready   (axis_mready),
      .stat_tx_drop  (stat_tx_drop)
  );

endmodule
`resetall
