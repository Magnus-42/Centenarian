// -----------------------------------------------------------------------------
// File Name   : arp_cache_write.v
// Module Name : arp_cache_write
// Author      : LiXintao
// Created     : 2026-09-16
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : ARP缓存流水线写入，通过影子表选择更新、空位插入或轮转替换
// Note        : p1发起影子表读取，p4输出写请求，下一拍主表/影子表同步落地；
//               相邻请求发生哈希碰撞时，后写入的IP可能覆盖前一个IP，需要重新请求ARP
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module arp_cache_write #(
    localparam integer ItemWidth = 81,  // 有效位、IP和MAC，共81位
    parameter integer CacheDepth = 1024,
    localparam integer CacheAddrWidth = CacheDepth == 1 ? 1 : $clog2(CacheDepth),
    parameter integer HashWayCount = 4
) (
    input wire clk,
    input wire rst,

    input wire        write_valid_pulse,
    input wire [31:0] write_ip,
    input wire [47:0] write_mac,

    output wire [               HashWayCount-1:0] write_we,
    output wire [CacheAddrWidth*HashWayCount-1:0] write_addr,
    output wire [     ItemWidth*HashWayCount-1:0] write_din,

    input wire cfg_clear,

    output wire stat_clear_finish
);

  // p1读取影子表，p2/p3对齐返回数据，p4寄存写请求。
  // 清表期间按地址扫描，主表与影子表同步写入。

  // 参数范围检查
  initial begin
    if (CacheDepth < 2 || (CacheDepth & (CacheDepth - 1)) != 0 || HashWayCount < 1) begin
      $display(
          "错误：arp_cache_write：CacheDepth必须为不小于2的2次幂，HashWayCount必须不小于1");
      $finish;
    end
  end

  // 内部常量
  localparam integer HashWayIndexWidth = HashWayCount == 1 ? 1 : $clog2(HashWayCount);
  localparam integer WriteDelay = 3;

  // 写入流水
  wire    [                         31:0] ip_hash;
  reg     [               WriteDelay-1:0] write_valid_shift;
  reg     [            32*WriteDelay-1:0] write_ip_shift;
  reg     [            48*WriteDelay-1:0] write_mac_shift;
  reg     [CacheAddrWidth*WriteDelay-1:0] write_addr_shift;

  // p4 写请求
  reg     [             HashWayCount-1:0] p4_write_we;
  reg     [           CacheAddrWidth-1:0] p4_write_addr;
  reg     [                ItemWidth-1:0] p4_write_din;
  reg     [                         32:0] p4_shadow_din;

  // 匹配与替换选择
  reg     [             HashWayCount-1:0] replace_way_onehot;
  reg                                     has_match;
  reg                                     has_empty_way;
  reg     [        HashWayIndexWidth-1:0] matched_way_index;
  reg     [        HashWayIndexWidth-1:0] empty_way_index;
  reg     [             HashWayCount-1:0] way_onehot;
  integer                                 way_index;

  // 影子表读接口
  reg                                     p1_shadow_re;
  reg     [           CacheAddrWidth-1:0] p1_shadow_addr;
  wire    [          33*HashWayCount-1:0] shadow_dout;

  // 清表扫描
  reg                                     clear_finish;
  reg     [           CacheAddrWidth-1:0] clear_addr;

  // 生成循环
  genvar g_way_index;

  // 清表扫描
  always @(posedge clk) begin
    if (rst || cfg_clear) clear_addr <= 'd0;
    else clear_addr <= clear_addr + 1'b1;
    if (rst || cfg_clear) clear_finish <= 'd0;
    else if (clear_addr == {CacheAddrWidth{1'b1}}) clear_finish <= 1'b1;
  end

  // 写入载荷与有效位延迟
  always @(posedge clk) begin
    write_ip_shift <= {write_ip_shift[32*(WriteDelay-1)-1:0], write_ip};
    write_mac_shift <= {write_mac_shift[48*(WriteDelay-1)-1:0], write_mac};
    write_addr_shift <= {
      write_addr_shift[CacheAddrWidth*(WriteDelay-1)-1:0], ip_hash[CacheAddrWidth-1:0]
    };
  end
  always @(posedge clk) begin
    if (rst || cfg_clear || !clear_finish) begin
      write_valid_shift <= 'd0;
    end else begin
      write_valid_shift <= {write_valid_shift[WriteDelay-2:0], write_valid_pulse};
    end
  end

  // p1 影子表读请求
  //// 计算哈希
  crc32_d32 crc32_d32_inst (
      .crc     (32'hFFFFFFFF),
      .data    (write_ip),
      .crc_next(ip_hash)
  );
  always @(posedge clk) begin
    if (rst || cfg_clear || !clear_finish) begin
      p1_shadow_re <= 1'b0;
    end else begin
      p1_shadow_re <= write_valid_pulse;
    end
  end
  always @(posedge clk) begin
    if (write_valid_pulse) p1_shadow_addr <= ip_hash[CacheAddrWidth-1:0];
  end

  // 输出
  //// 替换候选每拍轮转
  if (HashWayCount == 1) begin : gen_single_way
    always @(posedge clk) begin
      replace_way_onehot <= 1'b1;
    end
  end else begin : gen_multi_way
    always @(posedge clk) begin
      if (rst) begin
        replace_way_onehot <= {{(HashWayCount - 1) {1'b0}}, 1'b1};
      end else begin
        replace_way_onehot <= {
          replace_way_onehot[HashWayCount-2:0], replace_way_onehot[HashWayCount-1]
        };
      end
    end
  end
  //// p3 选择写入路，匹配和空位均优先选择较大索引
  always @(*) begin
    has_match         = 1'b0;
    has_empty_way     = 1'b0;
    matched_way_index = 'd0;
    empty_way_index   = 'd0;
    for (way_index = 0; way_index < HashWayCount; way_index = way_index + 1) begin
      if (shadow_dout[way_index*33+:33] == {1'b1, write_ip_shift[32*(WriteDelay-1)+:32]}) begin
        has_match         = 1'b1;
        matched_way_index = way_index;
      end
      if (!shadow_dout[way_index*33+32]) begin
        has_empty_way   = 1'b1;
        empty_way_index = way_index;
      end
    end
    way_onehot = replace_way_onehot;
    if (has_match) begin
      way_onehot = {{(HashWayCount - 1) {1'b0}}, 1'b1} << matched_way_index;
    end else if (has_empty_way) begin
      way_onehot = {{(HashWayCount - 1) {1'b0}}, 1'b1} << empty_way_index;
    end
  end
  //// p4 写请求
  always @(posedge clk) begin
    if (rst) p4_write_we <= 'd0;
    else if (!clear_finish) p4_write_we <= {HashWayCount{1'b1}};
    else if (cfg_clear) p4_write_we <= 'd0;
    else if (write_valid_shift[WriteDelay-1]) p4_write_we <= way_onehot;
    else p4_write_we <= 'd0;
  end
  always @(posedge clk) begin
    if (write_valid_shift[WriteDelay-1] && clear_finish && !cfg_clear && !rst) begin
      p4_write_addr <= write_addr_shift[CacheAddrWidth*(WriteDelay-1)+:CacheAddrWidth];
      p4_write_din <= {
        1'b1, write_ip_shift[32*(WriteDelay-1)+:32], write_mac_shift[48*(WriteDelay-1)+:48]
      };
      p4_shadow_din <= {1'b1, write_ip_shift[32*(WriteDelay-1)+:32]};
    end else begin
      p4_write_addr <= clear_addr;
      p4_write_din  <= 'd0;
      p4_shadow_din <= 'd0;
    end
  end

  for (g_way_index = 0; g_way_index < HashWayCount; g_way_index = g_way_index + 1) begin : gen_way
    sdp_bram #(
        .DataWidth  (33),          // valid+ip
        .Depth      (CacheDepth),
        .DoReg      (1),
        .InitEn     (1),
        .InitUseFile(0),
        .BypassEn   (1)
    ) sdp_bram_inst (
        .clk   (clk),
        .rst   (rst),
        .a_we  (p4_write_we[g_way_index]),
        .a_addr(p4_write_addr),
        .a_din (p4_shadow_din),
        .b_re  (p1_shadow_re),
        .b_addr(p1_shadow_addr),
        .b_dout(shadow_dout[g_way_index*33+:33])
    );
  end

  assign write_we          = p4_write_we;
  assign write_addr        = {HashWayCount{p4_write_addr}};
  assign write_din         = {HashWayCount{p4_write_din}};
  assign stat_clear_finish = clear_finish;

endmodule
`resetall
