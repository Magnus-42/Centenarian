// -----------------------------------------------------------------------------
// File Name   : eth_frame_pad60.v
// Module Name : eth_frame_pad60
// Author      : LiXintao
// Created     : 2026-09-18
// Version     : 1.2
// -----------------------------------------------------------------------------
// Description : 以太网短帧补齐到60字节
// Note        : 仅首拍扩展keep，无效输入字节置零。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module eth_frame_pad60 (
    input wire clk,
    input wire rst,

    input  wire [511:0] axis_sdata,
    input  wire [ 63:0] axis_skeep,
    input  wire         axis_slast,
    input  wire         axis_svalid,
    output wire         axis_sready,

    output wire [511:0] axis_mdata,
    output wire [ 63:0] axis_mkeep,
    output wire         axis_mlast,
    output wire         axis_mvalid,
    input  wire         axis_mready
);

  // 入口skid缓存输入帧。
  // 组合逻辑将无效输入字节清零，并将首拍keep补齐到至少60字节。
  // 出口skid缓存输出，首拍标志跟随实际处理握手更新。

  // 内部常量
  localparam integer MinFrameBytes = 60;
  localparam [63:0] MinKeepMask = {4'd0, {MinFrameBytes{1'b1}}};

  // 入口skid接口
  wire [511:0] axis_sdata_skid;
  wire [ 63:0] axis_skeep_skid;
  wire         axis_slast_skid;
  wire         axis_svalid_skid;
  wire         axis_sready_skid;

  // 首拍与握手
  reg   is_first_beat;
  wire  s_handshake_skid;

  // 首拍补齐
  wire [63:0] axis_skeep_padded;

  // 出口skid接口
  wire [511:0] axis_mdata_skid;
  wire [ 63:0] axis_mkeep_skid;

  // 生成循环
  genvar byte_index;

  // 入口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (1)
  ) axis_skid_buffer_in (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_sready),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (1'b0),
      .axis_slast (axis_slast),
      .axis_svalid(axis_svalid),
      .axis_mready(axis_sready_skid),
      .axis_mdata (axis_sdata_skid),
      .axis_mkeep (axis_skeep_skid),
      .axis_musr  (),
      .axis_mlast (axis_slast_skid),
      .axis_mvalid(axis_svalid_skid)
  );

  // 处理握手
  assign s_handshake_skid = axis_svalid_skid && axis_sready_skid;

  // 短帧补齐
  //// 无效字节清零
  for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1) begin : gen_byte_mask
    assign axis_mdata_skid[byte_index*8+:8] =
        axis_skeep_skid[byte_index] ? axis_sdata_skid[byte_index*8+:8] : 8'h00;
  end
  //// 首拍keep补齐
  assign axis_skeep_padded = axis_skeep_skid[MinFrameBytes-1] == 1'b0
      ? MinKeepMask : axis_skeep_skid;
  assign axis_mkeep_skid = is_first_beat ? axis_skeep_padded : axis_skeep_skid;

  // 首拍标志
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;  // 复位后第一拍视为首拍
    end else begin
      if (s_handshake_skid) begin
        is_first_beat <= axis_slast_skid;
      end
    end
  end

  // 出口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (1)
  ) axis_skid_buffer_out (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_sready_skid),
      .axis_sdata (axis_mdata_skid),
      .axis_skeep (axis_mkeep_skid),
      .axis_susr  (1'b0),
      .axis_slast (axis_slast_skid),
      .axis_svalid(axis_svalid_skid),
      .axis_mready(axis_mready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid)
  );

endmodule
`resetall
