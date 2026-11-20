// -----------------------------------------------------------------------------
// File Name   : arp_cache_lookup.v
// Module Name : arp_cache_lookup
// Author      : LiXintao
// Created     : 2026-09-16
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : ARP缓存流水线查询，根据IP哈希读取各路并输出匹配结果
// Note        : cfg_enable关闭时清除查询有效流水线，查询结果以脉冲形式输出
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module arp_cache_lookup #(
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

    output wire [               HashWayCount-1:0] lookup_re,
    output wire [CacheAddrWidth*HashWayCount-1:0] lookup_addr,
    input  wire [     ItemWidth*HashWayCount-1:0] lookup_dout,

    input wire cfg_enable
);

  // p1发出读请求，p2/p3对齐缓存返回，p4寄存查询结果。

  // 参数范围检查
  initial begin
    if (CacheDepth < 2 || (CacheDepth & (CacheDepth - 1)) != 0 || HashWayCount < 1) begin
      $display(
          "错误：arp_cache_lookup：CacheDepth必须为不小于2的2次幂，HashWayCount必须不小于1");
      $finish;
    end
  end

  // 内部常量
  localparam integer QueryDelay = 3;

  // 查询流水
  wire [                 31:0] ip_hash;
  reg  [       QueryDelay-1:0] query_valid_shift;
  reg  [32*(QueryDelay-1)-1:0] query_ip_shift;
  (* shreg_extract = "no" *)reg  [                 31:0] query_ip_d3;
  wire                         p3_query_valid;

  // p4 查询结果
  reg                          p4_lookup_valid_pulse;
  reg                          p4_lookup_miss;
  reg  [                 31:0] p4_lookup_ip;
  reg  [                 47:0] p4_lookup_mac;

  // p3 匹配与MAC选择
  wire [     HashWayCount-1:0] matched_way_mask;
  reg                          has_match;
  reg  [                 47:0] selected_mac;
  wire [     HashWayCount-1:0] way_onehot;

  // 生成循环
  genvar g_read;
  genvar g_way;

  // 查询有效位
  assign p3_query_valid = query_valid_shift[QueryDelay-1] && cfg_enable;

  // 查询IP与有效位延迟
  always @(posedge clk) begin
    query_ip_shift <= {query_ip_shift[32*(QueryDelay-2)-1:0], query_ip};
    query_ip_d3    <= query_ip_shift[32*(QueryDelay-2)+:32];
    if (rst || !cfg_enable) begin
      query_valid_shift <= 'd0;
    end else begin
      query_valid_shift <= {query_valid_shift[QueryDelay-2:0], query_valid_pulse};
    end
  end

  // p1 读请求
  crc32_d32 crc32_d32_inst (
      .crc     (32'hFFFFFFFF),
      .data    (query_ip),
      .crc_next(ip_hash)
  );
  for (g_read = 0; g_read < HashWayCount; g_read = g_read + 1) begin : gen_read
    (* dont_touch = "true" *) reg p1_lookup_re;
    (* dont_touch = "true" *) reg [CacheAddrWidth-1:0] p1_lookup_addr;
    always @(posedge clk) begin
      if (rst || !cfg_enable) p1_lookup_re <= 1'b0;
      else p1_lookup_re <= query_valid_pulse;
      if (query_valid_pulse && cfg_enable && !rst) p1_lookup_addr <= ip_hash[CacheAddrWidth-1:0];
    end
    assign lookup_re[g_read]                                  = p1_lookup_re;
    assign lookup_addr[g_read*CacheAddrWidth+:CacheAddrWidth] = p1_lookup_addr;
  end

  // p3 匹配
  //// 计算匹配掩码
  for (g_way = 0; g_way < HashWayCount; g_way = g_way + 1) begin : gen_match
    assign matched_way_mask[g_way] = lookup_dout[g_way*ItemWidth+ItemWidth-1-:33]
        == {1'b1, query_ip_d3};
  end
  assign way_onehot = matched_way_mask & (~matched_way_mask + 1'b1);
  always @(*) begin : select_match
    integer way_index;
    has_match    = |matched_way_mask;
    selected_mac = 'd0;
    for (way_index = 0; way_index < HashWayCount; way_index = way_index + 1) begin
      if (way_onehot[way_index]) begin
        selected_mac = lookup_dout[way_index*ItemWidth+:48];
      end
    end
  end
  // p4 查询结果
  always @(posedge clk) begin
    if (rst) begin
      p4_lookup_valid_pulse <= 'd0;
    end else begin
      p4_lookup_valid_pulse <= p3_query_valid;
    end
  end
  always @(posedge clk) begin
    if (rst) begin
      p4_lookup_miss <= 'd0;
    end else begin
      p4_lookup_miss <= p3_query_valid && !has_match;
    end
  end
  always @(posedge clk) begin
    if (p3_query_valid) begin
      p4_lookup_ip  <= query_ip_d3;
      p4_lookup_mac <= selected_mac;
    end
  end

  assign lookup_valid_pulse = p4_lookup_valid_pulse;
  assign lookup_miss        = p4_lookup_miss;
  assign lookup_ip          = p4_lookup_ip;
  assign lookup_mac         = p4_lookup_mac;

endmodule
`resetall
