// -----------------------------------------------------------------------------
// File Name   : arp_cache.v
// Module Name : arp_cache
// Author      : LiXintao
// Created     : 2026-09-16
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 多路组相联ARP缓存存储阵列
// Note        : 各路独立读写，默认表项包含有效位、IP和MAC
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module arp_cache #(
    parameter integer ItemWidth = 81,
    parameter integer CacheDepth = 1024,
    localparam integer CacheAddrWidth = CacheDepth == 1 ? 1 : $clog2(CacheDepth),
    parameter integer HashWayCount = 4
) (
    input wire clk,
    input wire rst,

    input wire [               HashWayCount-1:0] write_we,
    input wire [CacheAddrWidth*HashWayCount-1:0] write_addr,
    input wire [     ItemWidth*HashWayCount-1:0] write_din,

    input  wire [               HashWayCount-1:0] lookup_re,
    input  wire [CacheAddrWidth*HashWayCount-1:0] lookup_addr,
    output wire [     ItemWidth*HashWayCount-1:0] lookup_dout
);

  // 各路独立接收读写请求，通过带输出寄存的存储阵列返回表项。

  // 参数范围检查
  initial begin
    if (ItemWidth < 1 || CacheDepth < 1 || HashWayCount < 1) begin
      $display("错误：arp_cache：ItemWidth、CacheDepth和HashWayCount必须不小于1");
      $finish;
    end
  end

  // 生成循环
  genvar g_way_index;

  // 缓存存储阵列
  for (g_way_index = 0; g_way_index < HashWayCount; g_way_index = g_way_index + 1) begin : gen_way
    sdp_bram #(
        .DataWidth  (ItemWidth),
        .Depth      (CacheDepth),
        .DoReg      (1),
        .InitEn     (1),
        .InitUseFile(0),
        .BypassEn   (1)
    ) sdp_bram_inst (
        .clk   (clk),
        .rst   (rst),
        .a_we  (write_we[g_way_index]),
        .a_addr(write_addr[g_way_index*CacheAddrWidth+:CacheAddrWidth]),
        .a_din (write_din[g_way_index*ItemWidth+:ItemWidth]),
        .b_re  (lookup_re[g_way_index]),
        .b_addr(lookup_addr[g_way_index*CacheAddrWidth+:CacheAddrWidth]),
        .b_dout(lookup_dout[g_way_index*ItemWidth+:ItemWidth])
    );
  end

endmodule
`resetall
