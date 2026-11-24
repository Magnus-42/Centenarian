// -----------------------------------------------------------------------------
// File Name   : arp_eth_tx.v
// Module Name : arp_eth_tx
// Author      : LiXintao
// Created     : 2026-09-14
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 将28字节ARP报文及MAC首部元数据送入MAC层
// Note        : 输出usr为{EtherType,源MAC,目的MAC,请求}。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module arp_eth_tx #(
    parameter  integer DataWidth = 512,
    parameter  integer ReqWidth  = 4,
    localparam integer UsrWidth  = ReqWidth + 112
) (
    input wire clk,
    input wire rst,

    input wire [ReqWidth-1:0] cfg_arp_priority,

    input  wire        frame_valid,
    output wire        frame_ready,
    input  wire [47:0] eth_dest_mac,
    input  wire [47:0] eth_src_mac,
    input  wire [15:0] eth_type,
    input  wire [15:0] arp_htype,
    input  wire [15:0] arp_ptype,
    input  wire [ 7:0] arp_hlen,
    input  wire [ 7:0] arp_plen,
    input  wire [15:0] arp_oper,
    input  wire [47:0] arp_sha,       // 发送方MAC地址
    input  wire [31:0] arp_spa,       // 发送方IP地址
    input  wire [47:0] arp_tha,       // 目标MAC地址
    input  wire [31:0] arp_tpa,       // 目标IP地址

    output wire [  DataWidth-1:0] axis_mdata,
    output wire [DataWidth/8-1:0] axis_mkeep,
    output wire                   axis_mvalid,
    output wire                   axis_mlast,
    output wire [   UsrWidth-1:0] axis_musr,
    input  wire                   axis_mready
);

  // 报文字段顺序：ARP类型与长度、操作码、发送方和目标地址。
  // ARP报文共28字节，MAC地址与EtherType放入usr，data高位补零。
  // 配置优先级寄存一拍，出口skid同步缓存ARP报文与MAC元数据并支持背压。

  // 参数范围检查
  initial begin
    if (DataWidth < 224 || DataWidth % 8 != 0 || ReqWidth < 1) begin
      $display(
          "错误：arp_eth_tx：DataWidth须不小于224且为8的倍数，ReqWidth须大于0");
      $finish;
    end
  end

  // 内部常量
  localparam integer HeaderBytes = 28;
  localparam integer HeaderWidth = HeaderBytes * 8;
  localparam [DataWidth/8-1:0] ArpKeepMask = {
    {(DataWidth / 8 - HeaderBytes) {1'b0}}, {HeaderBytes{1'b1}}
  };

  // 发送优先级
  reg  [ ReqWidth-1:0] cfg_arp_priority_d1;

  // 帧组装
  wire [DataWidth-1:0] axis_mdata_skid;

  // 帧组装
  assign axis_mdata_skid = {
    {(DataWidth - HeaderWidth) {1'b0}},
    arp_tpa,
    arp_tha,
    arp_spa,
    arp_sha,
    arp_oper,
    arp_plen,
    arp_hlen,
    arp_ptype,
    arp_htype
  };

  // 配置寄存
  always @(posedge clk) begin
    if (rst) cfg_arp_priority_d1 <= 'd0;
    else cfg_arp_priority_d1 <= cfg_arp_priority;
  end
  // 出口skid
  axis_skid_buffer #(
      .DataWidth(DataWidth),
      .UsrWidth (UsrWidth)
  ) axis_skid_buffer_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(frame_ready),
      .axis_sdata (axis_mdata_skid),
      .axis_skeep (ArpKeepMask),
      .axis_susr  ({eth_type, eth_src_mac, eth_dest_mac, cfg_arp_priority_d1}),
      .axis_slast (1'b1),
      .axis_svalid(frame_valid),
      .axis_mready(axis_mready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (axis_musr),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid)
  );

endmodule
`resetall
