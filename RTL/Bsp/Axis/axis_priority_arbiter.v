// -----------------------------------------------------------------------------
// File Name   : axis_priority_arbiter.v
// Module Name : axis_priority_arbiter
// Author      : LiXintao
// Created     : 2026-11-06
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 严格优先级AXIS仲裁器，按帧选择输入通道。
// Note        : LowFirst=1时低编号优先，否则高编号优先；
//               帧内保持通道选择，输入输出均进行寄存器化。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module axis_priority_arbiter #(
    parameter  integer RequesterCount = 6,
    parameter  integer DataWidth      = 64,
    parameter  integer UsrWidth       = 8,
    parameter  integer LowFirst       = 1,
    localparam integer KeepWidth      = DataWidth / 8
) (
    input wire clk,
    input wire rst,

    input  wire [RequesterCount*DataWidth-1:0] axis_sdata,
    input  wire [RequesterCount*KeepWidth-1:0] axis_skeep,
    input  wire [ RequesterCount*UsrWidth-1:0] axis_susr,
    input  wire [          RequesterCount-1:0] axis_svalid,
    input  wire [          RequesterCount-1:0] axis_slast,
    output wire [          RequesterCount-1:0] axis_sready,

    output wire [DataWidth-1:0] axis_mdata,
    output wire [KeepWidth-1:0] axis_mkeep,
    output wire [ UsrWidth-1:0] axis_musr,
    output wire                 axis_mvalid,
    output wire                 axis_mlast,
    input  wire                 axis_mready
);

  // 各通道入口skid缓存输入，p1保存待仲裁帧拍。
  // 按编号优先级选择并锁定帧通道，出口skid缓存选中数据。

  // 参数范围检查
  initial begin
    if (RequesterCount < 1 || DataWidth < 8 || DataWidth % 8 != 0 || UsrWidth < 1 ||
        (LowFirst != 0 && LowFirst != 1)) begin
      $display("错误：axis_priority_arbiter：不支持的参数配置。");
      $finish;
    end
  end

  // 内部常量
  localparam integer IndexWidth = (RequesterCount <= 1) ? 1 : $clog2(RequesterCount);

  // 入口skid接口
  wire [RequesterCount*DataWidth-1:0] axis_sdata_skid;
  wire [RequesterCount*KeepWidth-1:0] axis_skeep_skid;
  wire [ RequesterCount*UsrWidth-1:0] axis_susr_skid;
  wire [          RequesterCount-1:0] axis_svalid_skid;
  wire [          RequesterCount-1:0] axis_slast_skid;
  wire [          RequesterCount-1:0] axis_sready_skid;

  // p1 输入缓存
  reg  [RequesterCount*DataWidth-1:0] p1_axis_sdata;
  reg  [RequesterCount*KeepWidth-1:0] p1_axis_skeep;
  reg  [ RequesterCount*UsrWidth-1:0] p1_axis_susr;
  reg  [          RequesterCount-1:0] p1_axis_svalid;
  reg  [          RequesterCount-1:0] p1_axis_slast;

  // 仲裁请求与通道锁定
  wire [          RequesterCount-1:0] arb_onehot;
  wire [              IndexWidth-1:0] arb_index;
  reg  [          RequesterCount-1:0] arb_onehot_locked;
  reg  [              IndexWidth-1:0] arb_index_locked;
  wire                                arb_refresh;
  reg  [          RequesterCount-1:0] arb_req;
  wire                                has_locked_channel;

  // 出口skid接口
  wire [               DataWidth-1:0] axis_mdata_skid;
  wire [               KeepWidth-1:0] axis_mkeep_skid;
  wire [                UsrWidth-1:0] axis_musr_skid;
  wire                                axis_mvalid_skid;
  wire                                axis_mlast_skid;
  wire                                axis_mready_skid;

  // 流水握手
  wire [          RequesterCount-1:0] p1_ready;
  wire [          RequesterCount-1:0] s_handshake_skid;
  wire [          RequesterCount-1:0] p1_handshake;

  // 生成循环
  genvar g_i;

  // 仲裁状态与流水握手
  assign has_locked_channel = |arb_onehot_locked;

  assign p1_ready           = axis_mready_skid ? arb_onehot_locked : 'd0;
  assign axis_sready_skid   = ~p1_axis_svalid | p1_ready;
  assign s_handshake_skid   = axis_svalid_skid & axis_sready_skid;
  assign p1_handshake       = p1_axis_svalid & p1_ready;

  // 对上游ready寄存器化
  for (g_i = 0; g_i < RequesterCount; g_i = g_i + 1) begin : gen_skid
    axis_skid_buffer #(
        .DataWidth(DataWidth),
        .UsrWidth (UsrWidth)
    ) axis_skid_buffer_s (
        .clk        (clk),
        .rst        (rst),
        .axis_sready(axis_sready[g_i]),
        .axis_sdata (axis_sdata[g_i*DataWidth+:DataWidth]),
        .axis_skeep (axis_skeep[g_i*KeepWidth+:KeepWidth]),
        .axis_susr  (axis_susr[g_i*UsrWidth+:UsrWidth]),
        .axis_slast (axis_slast[g_i]),
        .axis_svalid(axis_svalid[g_i]),
        .axis_mready(axis_sready_skid[g_i]),
        .axis_mdata (axis_sdata_skid[g_i*DataWidth+:DataWidth]),
        .axis_mkeep (axis_skeep_skid[g_i*KeepWidth+:KeepWidth]),
        .axis_musr  (axis_susr_skid[g_i*UsrWidth+:UsrWidth]),
        .axis_mlast (axis_slast_skid[g_i]),
        .axis_mvalid(axis_svalid_skid[g_i])
    );
  end

  // p1流水线
  always @(posedge clk) begin : pipeline_p1
    integer i;
    if (rst) begin
      p1_axis_svalid <= 'd0;
      p1_axis_susr   <= 'd0;
    end else begin
      for (i = 0; i < RequesterCount; i = i + 1) begin
        p1_axis_sdata[i*DataWidth+:DataWidth] <=  s_handshake_skid[i]
            ? axis_sdata_skid[i*DataWidth+:DataWidth] : p1_axis_sdata[i*DataWidth+:DataWidth];
        p1_axis_skeep[i*KeepWidth+:KeepWidth] <= s_handshake_skid[i]
            ? axis_skeep_skid[i*KeepWidth+:KeepWidth] : p1_axis_skeep[i*KeepWidth+:KeepWidth];
        p1_axis_susr[i*UsrWidth+:UsrWidth] <= s_handshake_skid[i]
            ? axis_susr_skid[i*UsrWidth+:UsrWidth] : p1_axis_susr[i*UsrWidth+:UsrWidth];
        p1_axis_slast[i] <= s_handshake_skid[i] ? axis_slast_skid[i] : p1_axis_slast[i];
        p1_axis_svalid[i] <= s_handshake_skid[i] ? 1'b1
            : (p1_handshake[i] ? 1'b0 : p1_axis_svalid[i]);
      end
    end
  end

  // 仲裁
  //// 计算req
  always @* begin : get_arb_req
    integer i;
    for (i = 0; i < RequesterCount; i = i + 1) begin
      // 当前通道检查补入p1的新拍，其他通道检查已有缓存
      arb_req[i] = arb_onehot_locked[i]
          ? (s_handshake_skid[i] ? axis_svalid_skid[i] : 1'b0)
          : (p1_axis_svalid[i] ? p1_axis_svalid[i] : 1'b0);
    end
  end
  //// 计算refresh
  assign arb_refresh = (!has_locked_channel) || (|(p1_handshake & p1_axis_slast));
  priority_encoder #(
      .Width(RequesterCount),
      .LowFirst(LowFirst)
  ) priority_encoder_inst (
      .req   (arb_req),
      .index (arb_index),
      .onehot(arb_onehot)
  );
  //// 寄存输出
  always @(posedge clk) begin
    if (rst) begin
      arb_onehot_locked <= 'd0;
      arb_index_locked  <= 'd0;
    end else begin
      arb_onehot_locked <= arb_refresh ? arb_onehot : arb_onehot_locked;
      arb_index_locked  <= arb_refresh ? arb_index : arb_index_locked;
    end
  end

  // p2 输出skid
  assign axis_mdata_skid  = p1_axis_sdata[arb_index_locked*DataWidth+:DataWidth];
  assign axis_mkeep_skid  = p1_axis_skeep[arb_index_locked*KeepWidth+:KeepWidth];
  assign axis_musr_skid   = p1_axis_susr[arb_index_locked*UsrWidth+:UsrWidth];
  assign axis_mvalid_skid = p1_axis_svalid[arb_index_locked] && has_locked_channel;
  assign axis_mlast_skid  = p1_axis_slast[arb_index_locked];

  axis_skid_buffer #(
      .DataWidth(DataWidth),
      .UsrWidth (UsrWidth)
  ) axis_skid_buffer_m (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_mready_skid),
      .axis_sdata (axis_mdata_skid),
      .axis_skeep (axis_mkeep_skid),
      .axis_susr  (axis_musr_skid),
      .axis_slast (axis_mlast_skid),
      .axis_svalid(axis_mvalid_skid),
      .axis_mready(axis_mready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (axis_musr),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid)
  );

endmodule
`resetall
