// -----------------------------------------------------------------------------
// File Name   : ipv4_proto_demux.v
// Module Name : ipv4_proto_demux
// Author      : LiXintao
// Created     : 2026-09-29
// Version     : v2.0
// -----------------------------------------------------------------------------
// Description : IPv4协议分流，按字典选择通道并按帧保持选择。
// Note        : 重复项选择最小索引，未匹配走末通道；TypeCount=0时全部走末通道。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv4_proto_demux #(
    parameter  integer TypeCount          = 3,
    localparam integer EffectiveTypeCount = (TypeCount > 0) ? TypeCount : 1,
    localparam integer UsrWidth           = 273
) (
    input wire clk,
    input wire rst,

    input wire [EffectiveTypeCount*8-1:0] cfg_type_dict,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire [UsrWidth-1:0] axis_susr,
    input  wire                axis_svalid,
    input  wire                axis_slast,
    output wire                axis_sready,

    output wire [     512*(TypeCount+1)-1:0] axis_mdata,
    output wire [      64*(TypeCount+1)-1:0] axis_mkeep,
    output wire [UsrWidth*(TypeCount+1)-1:0] axis_musr,
    output wire [               TypeCount:0] axis_mvalid,
    output wire [               TypeCount:0] axis_mlast,
    input  wire [               TypeCount:0] axis_mready
);

  // 字典寄存一拍
  // p1缓存输入数据，首拍匹配并锁定通道。
  // 各通道skid独立缓存输出。

  // 参数范围检查
  initial begin
    if (TypeCount < 0) begin
      $display("错误：ipv4_proto_demux：TypeCount必须不小于0。");
      $finish;
    end
  end

  // 字典配置
  reg [EffectiveTypeCount*8-1:0] cfg_type_dict_d1;

  // 接收usr中的首部字段位置
  localparam integer Ipv4HeaderOffset = 113;

  // 入口skid接口
  wire [       511:0] axis_sdata_skid;
  wire [        63:0] axis_skeep_skid;
  wire [UsrWidth-1:0] axis_susr_skid;
  wire                axis_slast_skid;
  wire                axis_svalid_skid;
  wire                axis_sready_skid;
  wire                s_handshake_skid;

  // p1 输入缓存
  reg  [       511:0] p1_axis_sdata;
  reg  [        63:0] p1_axis_skeep;
  reg                 p1_axis_slast;
  reg                 p1_axis_svalid;
  reg  [UsrWidth-1:0] p1_axis_susr;

  // 首拍标志
  reg                 is_first_beat;

  // 协议匹配与帧路由
  wire [ TypeCount:0] matched_channel_onehot;
  wire [ TypeCount:0] protocol_match;
  reg  [ TypeCount:0] channel_onehot_locked;

  // 流水控制
  wire                p1_ready;
  wire                p1_handshake;

  // 出口skid接口
  wire [ TypeCount:0] axis_mready_skid;

  // 生成循环
  genvar type_index;

  // 字典配置寄存
  always @(posedge clk) begin
    if (rst) begin
      cfg_type_dict_d1 <= 'd0;
    end else begin
      cfg_type_dict_d1 <= cfg_type_dict;
    end
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
  //// 数据
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

  // 协议匹配与出口skid
  for (type_index = 0; type_index <= TypeCount; type_index = type_index + 1) begin : gen_type
    if (type_index == TypeCount) begin : gen_default_type
      assign protocol_match[type_index] = 1'b0;
      // 未匹配送入默认通道；TypeCount=0时所有帧均进入该通道。
      if (TypeCount == 0) begin : gen_no_user_type
        assign matched_channel_onehot[type_index] = 1'b1;
      end else begin : gen_has_user_type
        assign matched_channel_onehot[type_index] = ~(|protocol_match[TypeCount-1:0]);
      end
    end else begin : gen_range_type
      assign protocol_match[type_index] = cfg_type_dict_d1[type_index*8+:8] ==
          axis_susr_skid[Ipv4HeaderOffset+72+:8];
      if (type_index == 0) begin : gen_first_match
        assign matched_channel_onehot[type_index] = protocol_match[type_index];
      end else begin : gen_later_match
        assign matched_channel_onehot[type_index] = protocol_match[type_index] &&
            !(|protocol_match[type_index-1:0]);
      end
    end

    //// 出口skid
    axis_skid_buffer #(
        .DataWidth(512),
        .UsrWidth (UsrWidth)
    ) axis_skid_buffer_out (
        .clk        (clk),
        .rst        (rst),
        .axis_sready(axis_mready_skid[type_index]),
        .axis_sdata (p1_axis_sdata),
        .axis_skeep (p1_axis_skeep),
        .axis_susr  (p1_axis_susr),
        .axis_slast (p1_axis_slast),
        .axis_svalid(p1_axis_svalid && channel_onehot_locked[type_index]),
        .axis_mready(axis_mready[type_index]),
        .axis_mdata (axis_mdata[type_index*512+:512]),
        .axis_mkeep (axis_mkeep[type_index*64+:64]),
        .axis_musr  (axis_musr[type_index*UsrWidth+:UsrWidth]),
        .axis_mlast (axis_mlast[type_index]),
        .axis_mvalid(axis_mvalid[type_index])
    );
  end

  // 帧路由锁定
  always @(posedge clk) begin
    if (rst) begin
      channel_onehot_locked <= 'd0;
    end else begin
      if (s_handshake_skid && is_first_beat) begin
        channel_onehot_locked <= matched_channel_onehot;
      end
    end
  end

  // 首拍标志
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
