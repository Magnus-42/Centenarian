// -----------------------------------------------------------------------------
// File Name   : ipv6_mac_lookup.v
// Module Name : ipv6_mac_lookup
// Author      : LiXintao
// Created     : 2026-10-11
// Version     : v2.0
// -----------------------------------------------------------------------------
// Description : IPv6配置表查找，任一地址未命中则过滤整帧。
// Note        : 重复地址取最大索引，MAC仅首拍有效；不进行NDP。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv6_mac_lookup #(
    parameter integer DstMacEntryCount = 8,
    parameter integer SrcMacEntryCount = 8,
    parameter integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth
) (
    input wire clk,
    input wire rst,

    input wire cfg_stat_clear,
    input wire [128*DstMacEntryCount-1:0] cfg_dst_ipv6,
    input wire [48*DstMacEntryCount-1 : 0] cfg_dst_mac,
    input wire [128*SrcMacEntryCount-1:0] cfg_src_ipv6,
    input wire [48*SrcMacEntryCount-1 : 0] cfg_src_mac,
    input wire [511:0] axis_sdata,
    input wire [63:0] axis_skeep,
    input wire [UsrWidth-1:0] axis_susr,
    input wire axis_slast,
    input wire axis_svalid,
    output wire axis_sready,
    output wire [511:0] axis_mdata,
    output wire [63:0] axis_mkeep,
    output wire [UsrWidth-1:0] axis_musr,
    output wire axis_mlast,
    output wire axis_mvalid,
    input wire axis_mready,
    output wire [47:0] src_mac,
    output wire [47:0] dst_mac,
    output wire stat_tx_drop
);
  // 入口skid缓存输入数据。
  // p1缓存地址匹配结果、数据和首拍信息。
  // 组合优先编码选择MAC，并按首拍命中结果过滤整帧。
  // 出口skid缓存输出数据和MAC地址。

  // 参数范围检查
  initial begin
    if (DstMacEntryCount < 1 || SrcMacEntryCount < 1 || ReqWidth < 1) begin
      $display("错误：ipv6_mac_lookup：表项数和ReqWidth必须不小于1。");
      $finish;
    end
  end

  // 配置寄存
  reg [128*DstMacEntryCount-1:0] cfg_dst_ipv6_d1;
  reg [48*DstMacEntryCount-1:0] cfg_dst_mac_d1;
  reg [128*SrcMacEntryCount-1:0] cfg_src_ipv6_d1;
  reg [48*SrcMacEntryCount-1:0] cfg_src_mac_d1;

  // 入口skid接口
  wire [511:0] axis_sdata_skid;
  wire [63:0] axis_skeep_skid;
  wire [UsrWidth-1:0] axis_susr_skid;
  wire axis_slast_skid, axis_svalid_skid, axis_sready_skid;
  wire s_handshake_skid;

  // 地址匹配
  wire src_hit_comb, dst_hit_comb;
  wire [DstMacEntryCount-1:0] dst_match;
  wire [SrcMacEntryCount-1:0] src_match;
  genvar dst_index, src_index;

  // p1输入缓存
  reg [511:0] p1_axis_sdata;
  reg [63:0] p1_axis_skeep;
  reg [UsrWidth-1:0] p1_axis_susr;
  reg p1_axis_slast, p1_axis_svalid, p1_is_first_beat;
  reg p1_src_hit, p1_dst_hit;
  wire p1_ready;
  reg [DstMacEntryCount-1:0] p1_dst_match;
  reg [SrcMacEntryCount-1:0] p1_src_match;

  // MAC优先选择
  reg [47:0] src_mac_comb, dst_mac_comb;
  integer dst_entry_index;
  integer src_entry_index;

  // 状态清除配置
  reg cfg_stat_clear_d1;

  // 帧控制
  reg is_first_beat;
  reg drop_remaining_beats;
  reg drop_seen;

  // 帧过滤与输出
  wire axis_mready_skid;
  wire current_drop, current_first, current_last, current_valid, current_take;
  wire [511:0] current_data;
  wire [63:0] current_keep;
  wire [UsrWidth-1:0] current_usr;
  wire [47:0] current_src_mac, current_dst_mac;

  // 状态清除配置寄存
  always @(posedge clk) begin
    if (rst) begin
      cfg_stat_clear_d1 <= 1'b0;
    end else begin
      cfg_stat_clear_d1 <= cfg_stat_clear;
    end
  end

  // 配置寄存
  //// 目的地址表
  always @(posedge clk) begin
    cfg_dst_ipv6_d1 <= cfg_dst_ipv6;
    cfg_dst_mac_d1  <= cfg_dst_mac;
  end
  //// 源地址表
  always @(posedge clk) begin
    cfg_src_ipv6_d1 <= cfg_src_ipv6;
    cfg_src_mac_d1  <= cfg_src_mac;
  end

  // 入口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth)
  ) axis_skid_buffer_in (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_slast (axis_slast),
      .axis_svalid(axis_svalid),
      .axis_sready(axis_sready),
      .axis_mdata (axis_sdata_skid),
      .axis_mkeep (axis_skeep_skid),
      .axis_musr  (axis_susr_skid),
      .axis_mlast (axis_slast_skid),
      .axis_mvalid(axis_svalid_skid),
      .axis_mready(axis_sready_skid)
  );

  // 地址匹配
  //// 目的地址
  for (
      dst_index = 0; dst_index < DstMacEntryCount; dst_index = dst_index + 1
  ) begin : gen_dst_compare
    assign dst_match[dst_index] = axis_sdata_skid[192+:128] == cfg_dst_ipv6_d1[dst_index*128+:128];
  end
  //// 源地址
  for (
      src_index = 0; src_index < SrcMacEntryCount; src_index = src_index + 1
  ) begin : gen_src_compare
    assign src_match[src_index] = axis_sdata_skid[64+:128] == cfg_src_ipv6_d1[src_index*128+:128];
  end
  assign src_hit_comb = |src_match;
  assign dst_hit_comb = |dst_match;

  // MAC优先选择
  //// 目的MAC
  always @* begin
    dst_mac_comb = 48'd0;
    for (
        dst_entry_index = 0;
        dst_entry_index < DstMacEntryCount;
        dst_entry_index = dst_entry_index + 1
    ) begin
      if (p1_dst_match[dst_entry_index]) begin
        dst_mac_comb = cfg_dst_mac_d1[dst_entry_index*48+:48];
      end
    end
  end
  //// 源MAC
  always @* begin
    src_mac_comb = 48'd0;
    for (
        src_entry_index = 0;
        src_entry_index < SrcMacEntryCount;
        src_entry_index = src_entry_index + 1
    ) begin
      if (p1_src_match[src_entry_index]) begin
        src_mac_comb = cfg_src_mac_d1[src_entry_index*48+:48];
      end
    end
  end

  // p1 输入缓存
  //// 握手
  assign p1_ready         = !p1_axis_svalid || axis_mready_skid;
  assign axis_sready_skid = p1_ready;
  assign s_handshake_skid = axis_svalid_skid && axis_sready_skid;

  //// 数据与匹配结果
  always @(posedge clk) begin
    if (s_handshake_skid) begin
      p1_axis_sdata    <= axis_sdata_skid;
      p1_axis_skeep    <= axis_skeep_skid;
      p1_axis_susr     <= axis_susr_skid;
      p1_axis_slast    <= axis_slast_skid;
      p1_is_first_beat <= is_first_beat;

      p1_src_match     <= src_match;
      p1_dst_match     <= dst_match;
      p1_src_hit       <= src_hit_comb;
      p1_dst_hit       <= dst_hit_comb;
    end
  end
  //// 有效位
  always @(posedge clk) begin
    if (rst) p1_axis_svalid <= 1'b0;
    else if (p1_ready) p1_axis_svalid <= axis_svalid_skid;
  end

  // 帧过滤与输出
  assign current_data    = p1_axis_sdata;
  assign current_keep    = p1_axis_skeep;
  assign current_usr     = p1_axis_susr;
  assign current_last    = p1_axis_slast;
  assign current_valid   = p1_axis_svalid;
  assign current_first   = p1_is_first_beat;
  assign current_src_mac = src_mac_comb;
  assign current_dst_mac = dst_mac_comb;
  assign current_drop    = current_first ? !(p1_src_hit && p1_dst_hit) : drop_remaining_beats;

  assign current_take    = current_valid && axis_mready_skid;

  // 帧控制与统计
  //// 首拍标志
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;
    end else if (s_handshake_skid) begin
      is_first_beat <= axis_slast_skid;
    end
  end
  //// 丢弃状态
  always @(posedge clk) begin
    if (rst) begin
      drop_remaining_beats <= 1'b0;
    end else if (current_take) begin
      if (current_last) drop_remaining_beats <= 1'b0;
      else if (current_first) drop_remaining_beats <= current_drop;
    end
  end
  //// 丢包锁存状态
  assign stat_tx_drop = drop_seen;
  always @(posedge clk) begin
    if (rst || cfg_stat_clear_d1) begin
      drop_seen <= 1'b0;
    end else if (current_take && current_first && current_drop) begin
      drop_seen <= 1'b1;
    end
  end

  // 出口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth + 96)
  ) axis_skid_buffer_out (
      .clk(clk),
      .rst(rst),
      .axis_sdata(current_data),
      .axis_skeep(current_keep),
      .axis_susr({
        (current_first ? current_src_mac : 48'd0),
        (current_first ? current_dst_mac : 48'd0),
        current_usr
      }),
      .axis_slast(current_last),
      .axis_svalid(current_valid && !current_drop),
      .axis_sready(axis_mready_skid),
      .axis_mdata(axis_mdata),
      .axis_mkeep(axis_mkeep),
      .axis_musr({src_mac, dst_mac, axis_musr}),
      .axis_mlast(axis_mlast),
      .axis_mvalid(axis_mvalid),
      .axis_mready(axis_mready)
  );
endmodule
`resetall
