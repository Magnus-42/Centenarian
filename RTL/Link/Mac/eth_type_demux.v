// -----------------------------------------------------------------------------
// File Name   : eth_type_demux.v
// Module Name : eth_type_demux
// Author      : LiXintao
// Created     : 2026-09-19
// Version     : 2.1
// -----------------------------------------------------------------------------
// Description : 按以太网类型字典分流，未匹配的帧送入默认（TypeCount）通道
// Note        : 入口skid -> 首拍匹配/帧通道锁定 -> 各通道出口skid
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module eth_type_demux #(
    parameter  integer TypeCount    = 2,
    localparam integer TypeCountEff = (TypeCount > 0) ? TypeCount : 1,
    parameter  integer UsrWidth     = 113
) (
    input wire clk,
    input wire rst,

    input wire [TypeCountEff*16-1:0] cfg_type_dict,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire                axis_slast,
    input  wire                axis_svalid,
    input  wire [UsrWidth-1:0] axis_susr,
    output wire                axis_sready,

    output wire [     512*(TypeCount+1)-1:0] axis_mdata,
    output wire [      64*(TypeCount+1)-1:0] axis_mkeep,
    output wire [               TypeCount:0] axis_mlast,
    output wire [               TypeCount:0] axis_mvalid,
    output wire [UsrWidth*(TypeCount+1)-1:0] axis_musr,
    input  wire [               TypeCount:0] axis_mready
);

  // 字典寄存一拍后用于匹配
  // 首拍匹配以太网类型并锁定帧路由，后续拍沿用锁定通道。
  // 各通道出口skid独立缓存输出。

  // 参数范围检查
  initial begin
    if (TypeCount < 0 || UsrWidth < 1) begin
      $display("错误：eth_type_demux：TypeCount必须不小于0，UsrWidth必须不小于1");
      $finish;
    end
  end

  // 接收usr中的首部字段位置
  localparam integer EthHeaderOffset = 1;

  // 字典配置
  reg  [TypeCountEff*16-1:0] cfg_type_dict_d1;

  // 入口skid接口
  wire [              511:0] axis_sdata_skid;
  wire [               63:0] axis_skeep_skid;
  wire [       UsrWidth-1:0] axis_susr_skid;
  wire                       axis_slast_skid;
  wire                       axis_svalid_skid;
  wire                       axis_sready_skid;

  // 首拍与握手
  reg                        is_first_beat;
  wire                       s_handshake_skid;

  // 类型匹配与帧路由
  reg  [        TypeCount:0] locked_channel_onehot;
  wire [        TypeCount:0] matched_channel_onehot;
  wire [        TypeCount:0] has_prior_type_match;
  wire [        TypeCount:0] selected_channel_onehot;
  wire [        TypeCount:0] axis_mready_skid;

  // 生成循环
  genvar type_index;
  genvar out_index;

  // 字典配置寄存
  always @(posedge clk) begin
    if (rst) cfg_type_dict_d1 <= 'd0;
    else cfg_type_dict_d1 <= cfg_type_dict;
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

  // 处理握手
  assign s_handshake_skid        = axis_svalid_skid && axis_sready_skid;

  // 计算匹配
  assign has_prior_type_match[0] = 1'b0;
  assign selected_channel_onehot = is_first_beat ? matched_channel_onehot : locked_channel_onehot;
  assign axis_sready_skid        = |(selected_channel_onehot & axis_mready_skid);
  //// 计算类型匹配和去重
  for (type_index = 0; type_index <= TypeCount; type_index = type_index + 1) begin : gen_type
    if (type_index == TypeCount) begin : gen_default_type
      assign matched_channel_onehot[type_index] = !has_prior_type_match[type_index];
    end else begin : gen_range_type
      wire type_matches_header;
      assign type_matches_header =
        cfg_type_dict_d1[type_index*16+:16] == axis_susr_skid[EthHeaderOffset+96+:16];
      assign matched_channel_onehot[type_index] =
          type_matches_header && !has_prior_type_match[type_index];
      assign has_prior_type_match[type_index+1] =
          has_prior_type_match[type_index] || type_matches_header;
    end
  end
  // 帧路由锁定
  always @(posedge clk) begin
    if (rst) begin
      locked_channel_onehot <= 'd0;
    end else if (s_handshake_skid) begin
      if (is_first_beat) begin
        locked_channel_onehot <= matched_channel_onehot;
      end
    end
  end
  // 首拍标志
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;
    end else if (s_handshake_skid) begin
      is_first_beat <= axis_slast_skid;
    end
  end

  // 出口skid
  for (out_index = 0; out_index <= TypeCount; out_index = out_index + 1) begin : gen_output
    axis_skid_buffer #(
        .DataWidth(512),
        .UsrWidth (UsrWidth)
    ) axis_skid_buffer_out (
        .clk        (clk),
        .rst        (rst),
        .axis_sready(axis_mready_skid[out_index]),
        .axis_sdata (axis_sdata_skid),
        .axis_skeep (axis_skeep_skid),
        .axis_susr  (axis_susr_skid),
        .axis_slast (axis_slast_skid),
        .axis_svalid(axis_svalid_skid && selected_channel_onehot[out_index]),
        .axis_mready(axis_mready[out_index]),
        .axis_mdata (axis_mdata[out_index*512+:512]),
        .axis_mkeep (axis_mkeep[out_index*64+:64]),
        .axis_musr  (axis_musr[out_index*UsrWidth+:UsrWidth]),
        .axis_mlast (axis_mlast[out_index]),
        .axis_mvalid(axis_mvalid[out_index])
    );
  end

endmodule
`resetall
