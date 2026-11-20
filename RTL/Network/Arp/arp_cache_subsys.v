// -----------------------------------------------------------------------------
// File Name   : arp_cache_subsys.v
// Module Name : arp_cache_subsys
// Author      : LiXintao
// Created     : 2026-09-14
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : ARP缓存子系统，连接缓存阵列、流水线查询和写入控制
// Note        : 清表完成且未发起新清表请求时使能查询
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module arp_cache_subsys #(
    localparam integer ItemWidth = 81,  // 有效位、IP和MAC，共81位
    parameter integer CacheDepth = 1024,
    localparam integer CacheAddrWidth = CacheDepth == 1 ? 1 : $clog2(CacheDepth),
    parameter integer HashWayCount = 4
) (
    input wire clk,
    input wire rst,

    input wire        query_valid_pulse,
    input wire [31:0] query_ip,

    output wire        lookup_valid_pulse,
    output wire        lookup_miss,
    output wire [31:0] lookup_ip,
    output wire [47:0] lookup_mac,

    input wire        write_valid_pulse,
    input wire [31:0] write_ip,
    input wire [47:0] write_mac,

    input wire cfg_clear,

    output wire stat_clear_finish
);

  // 写入控制读取影子表，选择更新、空位插入或轮转替换。
  // 缓存阵列保存表项，查询流水输出匹配结果；清表期间关闭查询。

  // 参数范围检查
  initial begin
    if (CacheDepth < 2 || (CacheDepth & (CacheDepth - 1)) != 0 || HashWayCount < 1) begin
      $display(
          "错误：arp_cache_subsys：CacheDepth必须为不小于2的2次幂，HashWayCount必须不小于1");
      $finish;
    end
  end

  // 缓存读接口
  wire [               HashWayCount-1:0] lookup_re;
  wire [CacheAddrWidth*HashWayCount-1:0] lookup_addr;
  wire [     ItemWidth*HashWayCount-1:0] lookup_dout;

  // 缓存写接口
  wire [               HashWayCount-1:0] write_we;
  wire [CacheAddrWidth*HashWayCount-1:0] write_addr;
  wire [     ItemWidth*HashWayCount-1:0] write_din;

  // 缓存存储阵列
  arp_cache #(
      .ItemWidth   (ItemWidth),
      .CacheDepth  (CacheDepth),
      .HashWayCount(HashWayCount)
  ) arp_cache_inst (
      .clk        (clk),
      .rst        (rst),
      .write_we   (write_we),
      .write_addr (write_addr),
      .write_din  (write_din),
      .lookup_re  (lookup_re),
      .lookup_addr(lookup_addr),
      .lookup_dout(lookup_dout)
  );

  arp_cache_write #(
      .CacheDepth  (CacheDepth),
      .HashWayCount(HashWayCount)
  ) arp_cache_write_inst (
      .clk              (clk),
      .rst              (rst),
      .write_valid_pulse(write_valid_pulse),
      .write_ip         (write_ip),
      .write_mac        (write_mac),
      .write_we         (write_we),
      .write_addr       (write_addr),
      .write_din        (write_din),
      .cfg_clear        (cfg_clear),
      .stat_clear_finish(stat_clear_finish)
  );

  arp_cache_lookup #(
      .CacheDepth  (CacheDepth),
      .HashWayCount(HashWayCount)
  ) arp_cache_lookup_inst (
      .clk               (clk),
      .rst               (rst),
      .query_valid_pulse (query_valid_pulse),
      .query_ip          (query_ip),
      .lookup_valid_pulse(lookup_valid_pulse),
      .lookup_miss       (lookup_miss),
      .lookup_ip         (lookup_ip),
      .lookup_mac        (lookup_mac),
      .lookup_re         (lookup_re),
      .lookup_addr       (lookup_addr),
      .lookup_dout       (lookup_dout),
      .cfg_enable        (stat_clear_finish && !cfg_clear)
  );

endmodule
`resetall
