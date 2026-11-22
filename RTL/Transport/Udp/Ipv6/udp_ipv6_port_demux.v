// -----------------------------------------------------------------------------
// File Name   : udp_ipv6_port_demux.v
// Module Name : udp_ipv6_port_demux
// Author      : LiXintao
// Created     : 2026-11-22
// Version     : v1.0

// Description : 支持流水线设计，根据端口将数据分流
// Note        : 1. 端口 i(i<PortCount)的匹配区间 = cfg_dst_port_range 第 i 个 word：
//                 [15:0]下界、[31:16]上界；重叠取索引小者，空洞落末路
//               2. PortCount ≥ 0
//               3. 只匹配目的端口
//
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_ipv6_port_demux #(
    parameter integer PortCount = 3,
    localparam integer EffectivePortCount = (PortCount > 0) ? PortCount : 1,
    localparam integer UsrWidth = 433,
    localparam integer UsrDstPortLsb = 385
) (
    input wire clk,
    input wire rst,

    input wire [EffectivePortCount*32-1:0] cfg_dst_port_range,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire                axis_slast,
    input  wire                axis_svalid,
    input  wire [UsrWidth-1:0] axis_susr,
    output wire                axis_sready,

    output wire [     512*(PortCount+1)-1:0] axis_mdata,
    output wire [      64*(PortCount+1)-1:0] axis_mkeep,
    output wire [               PortCount:0] axis_mlast,
    output wire [               PortCount:0] axis_mvalid,
    output wire [UsrWidth*(PortCount+1)-1:0] axis_musr,
    input  wire [               PortCount:0] axis_mready
);

  // 入口skid缓存数据与usr
  // p1缓存数据并锁定首个命中区间，出口skid按通道独立保持。

  // 参数范围检查
  initial begin
    if (PortCount < 0) begin
      $display("错误：udp_ipv6_port_demux：不支持的参数配置。");
      $finish;
    end
  end

  // 区间配置
  reg  [EffectivePortCount*32-1:0] cfg_dst_port_range_d1;

  // 入口skid接口
  wire [                    511:0] axis_sdata_skid;
  wire [                     63:0] axis_skeep_skid;
  wire [             UsrWidth-1:0] axis_susr_skid;
  wire                             axis_slast_skid;
  wire                             axis_svalid_skid;
  wire                             axis_sready_skid;
  wire                             s_handshake_skid;

  // 出口skid接口
  wire [              PortCount:0] axis_mready_skid;

  // 首拍标志
  reg                              is_first_beat;

  // p1 数据与边带
  reg  [                    511:0] p1_axis_sdata;
  reg  [                     63:0] p1_axis_skeep;
  reg                              p1_axis_slast;
  reg                              p1_axis_svalid;
  reg  [             UsrWidth-1:0] p1_axis_susr;

  // 区间匹配与帧路由
  wire [              PortCount:0] matched_channel_onehot;
  wire [              PortCount:0] port_match;
  reg  [              PortCount:0] channel_onehot_locked;

  // 流水控制
  wire                             p1_ready;
  wire                             p1_handshake;

  // 循环变量
  genvar port_index;

  // 区间配置寄存
  always @(posedge clk) begin
    if (rst) cfg_dst_port_range_d1 <= 'd0;
    else cfg_dst_port_range_d1 <= cfg_dst_port_range;
  end

  // 入口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth)
  ) axis_skid_buffer_in (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_sready),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_slast (axis_slast),
      .axis_svalid(axis_svalid),
      .axis_mready(axis_sready_skid),
      .axis_mdata (axis_sdata_skid),
      .axis_mkeep (axis_skeep_skid),
      .axis_musr  (axis_susr_skid),
      .axis_mlast (axis_slast_skid),
      .axis_mvalid(axis_svalid_skid)
  );

  // 流水控制
  assign s_handshake_skid = axis_svalid_skid && axis_sready_skid;
  assign p1_ready         = |(channel_onehot_locked & axis_mready_skid);
  assign p1_handshake     = p1_ready && p1_axis_svalid;
  assign axis_sready_skid = !p1_axis_svalid || p1_ready;
  // p1 输入缓存
  //// 数据与边带
  always @(posedge clk) begin
    if (s_handshake_skid) begin
      p1_axis_sdata <= axis_sdata_skid;
      p1_axis_skeep <= axis_skeep_skid;
      p1_axis_slast <= axis_slast_skid;
      p1_axis_susr  <= axis_susr_skid;
    end
  end
  //// 有效位
  always @(posedge clk) begin
    if (rst) begin
      p1_axis_svalid <= 1'd0;
    end else begin
      if (s_handshake_skid) begin
        p1_axis_svalid <= 1'b1;
      end else if (p1_handshake) begin
        p1_axis_svalid <= 1'b0;
      end
    end
  end

  // 区间匹配与独立出口skid
  for (port_index = 0; port_index <= PortCount; port_index = port_index + 1) begin : gen_port
    if (port_index == PortCount) begin : gen_default_port
      assign port_match[port_index] = 1'b0;
      // other(兜底)档命中逻辑：PortCount=0 ⇒ 无用户档，所有帧全部落 other
      if (PortCount == 0) begin : gen_no_user_port
        assign matched_channel_onehot[port_index] = 1'b1;
      end else begin : gen_has_user_port
        assign matched_channel_onehot[port_index] = ~(|port_match[PortCount-1:0]);
      end
    end else begin : gen_range_port

      wire [15:0] dst_port_value;
      wire is_low_port_bound;
      wire is_high_port_bound;

      assign dst_port_value = {
        axis_susr_skid[UsrDstPortLsb+:8], axis_susr_skid[UsrDstPortLsb+8+:8]
      };
      assign is_low_port_bound =
        ({cfg_dst_port_range_d1[port_index*32+:8],cfg_dst_port_range_d1[port_index*32+8+:8]}
          <= dst_port_value);
      assign is_high_port_bound =
      ({cfg_dst_port_range_d1[port_index*32+16+:8],cfg_dst_port_range_d1[port_index*32+24+:8]}
          >= dst_port_value);
      assign port_match[port_index] = is_low_port_bound && is_high_port_bound;
      if (port_index == 0) begin : gen_first_match
        assign matched_channel_onehot[port_index] = port_match[port_index];
      end else begin : gen_later_match
        assign matched_channel_onehot[port_index] = port_match[port_index] &&
            !(|port_match[port_index-1:0]);
      end
    end

    // 各通道独立出口skid
    axis_skid_buffer #(
        .DataWidth(512),
        .UsrWidth (UsrWidth)
    ) axis_skid_buffer_out (
        .clk        (clk),
        .rst        (rst),
        .axis_sdata (p1_axis_sdata),
        .axis_skeep (p1_axis_skeep),
        .axis_susr  (p1_axis_susr),
        .axis_slast (p1_axis_slast),
        .axis_svalid(p1_axis_svalid && channel_onehot_locked[port_index]),
        .axis_sready(axis_mready_skid[port_index]),
        .axis_mdata (axis_mdata[port_index*512+:512]),
        .axis_mkeep (axis_mkeep[port_index*64+:64]),
        .axis_musr  (axis_musr[port_index*UsrWidth+:UsrWidth]),
        .axis_mlast (axis_mlast[port_index]),
        .axis_mvalid(axis_mvalid[port_index]),
        .axis_mready(axis_mready[port_index])
    );
  end

  // 首拍路由锁定
  always @(posedge clk) begin
    if (rst) begin
      channel_onehot_locked <= 'd0;
    end else begin
      if (s_handshake_skid && is_first_beat) begin
        channel_onehot_locked <= matched_channel_onehot;
      end
    end
  end

  // 输入首拍标志
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;
    end else begin
      if (s_handshake_skid) begin
        is_first_beat <= axis_slast_skid;
      end
    end
  end

endmodule
`resetall
