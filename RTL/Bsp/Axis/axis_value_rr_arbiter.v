// -----------------------------------------------------------------------------
// File Name   : axis_value_rr_arbiter.v
// Module Name : axis_value_rr_arbiter
// Author      : LiXintao
// Created     : 2026-11-05
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 数值优先级AXIS仲裁器，相同优先级之间按帧轮询。
// Note        : usr低ReqWidth位表示优先级；
//               LowReqFirst=0时大值优先，0表示无效；
//               LowReqFirst=1时小值优先，全1表示无效；
//               LowFirst=1时平局按编号递增轮询，否则按编号递减轮询；
//               帧内保持通道选择，输入输出均进行寄存器化。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module axis_value_rr_arbiter #(
    parameter  integer RequesterCount   = 6,
    parameter  integer DataWidth        = 64,
    parameter  integer UsrWidth         = 10,
    parameter  integer ReqWidth         = 7,
    parameter  integer LowReqFirst      = 0,
    parameter  integer LowFirst         = 1,
    parameter  integer SelectGroupWidth = 128,
    localparam integer KeepWidth        = DataWidth / 8
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

  // 各通道入口skid缓存输入，p1保存数据与完整usr。
  // 仅比较usr低ReqWidth位，平局按帧轮询并锁定通道。
  // 并行比较产生独热选择，出口skid缓存选中数据。
  // data、对应keep与usr按SelectGroupWidth分组，第0组同时用于仲裁控制。

  // 参数范围检查
  initial begin
    if (RequesterCount < 1 || DataWidth < 8 || DataWidth % 8 != 0 || UsrWidth < 1 ||
        (LowFirst != 0 && LowFirst != 1) || ReqWidth < 1 || ReqWidth > UsrWidth ||
        (LowReqFirst != 0 && LowReqFirst != 1) ||
        SelectGroupWidth < 8 || SelectGroupWidth % 8 != 0) begin
      $display("错误：axis_value_rr_arbiter：不支持的参数配置。");
      $finish;
    end
  end

  // 内部常量
  localparam [ReqWidth-1:0] InvalidReq = (LowReqFirst == 1) ? {ReqWidth{1'b1}} : {ReqWidth{1'b0}};
  localparam integer SelectPayloadWidth = DataWidth > UsrWidth ? DataWidth : UsrWidth;
  localparam integer SelectGroupCount =
      SelectGroupWidth >= 8 ? (SelectPayloadWidth - 1) / SelectGroupWidth + 1 : 1;

  // 入口skid接口
  wire [     RequesterCount*DataWidth-1:0] axis_sdata_skid;
  wire [     RequesterCount*KeepWidth-1:0] axis_skeep_skid;
  wire [      RequesterCount*UsrWidth-1:0] axis_susr_skid;
  wire [               RequesterCount-1:0] axis_svalid_skid;
  wire [               RequesterCount-1:0] axis_slast_skid;
  wire [               RequesterCount-1:0] axis_sready_skid;

  // p1 输入缓存
  reg  [     RequesterCount*DataWidth-1:0] p1_axis_sdata;
  reg  [     RequesterCount*KeepWidth-1:0] p1_axis_skeep;
  reg  [      RequesterCount*UsrWidth-1:0] p1_axis_susr;
  reg  [               RequesterCount-1:0] p1_axis_svalid;
  reg  [               RequesterCount-1:0] p1_axis_slast;

  // 出口skid接口
  wire [                    DataWidth-1:0] axis_mdata_skid;
  wire [                    KeepWidth-1:0] axis_mkeep_skid;
  wire [                     UsrWidth-1:0] axis_musr_skid;
  wire                                     axis_mvalid_skid;
  wire                                     axis_mlast_skid;
  wire                                     axis_mready_skid;
  wire [               RequesterCount-1:0] last_terms;
  wire [               RequesterCount-1:0] valid_terms;

  // 仲裁请求与通道锁定
  wire                                     arb_refresh;
  wire [               RequesterCount-1:0] arb_onehot_locked;
  wire [               RequesterCount-1:0] arb_onehot_group   [0:SelectGroupCount-1];
  wire                                     has_locked_channel;
  wire [               RequesterCount-1:0] p1_req_valid;
  wire [               RequesterCount-1:0] skid_req_valid;
  wire [               RequesterCount-1:0] arb_onehot;
  wire [               RequesterCount-1:0] arb_req_valid;
  wire [RequesterCount*RequesterCount-1:0] wins_against;

  // 轮询状态
  reg                                      refresh_d1;
  reg  [               RequesterCount-1:0] rr_mask;
  wire [               RequesterCount-1:0] rr_mask_next;
  wire [               RequesterCount-1:0] rr_mask_active;

  // 流水握手
  wire [               RequesterCount-1:0] p1_ready;
  wire [               RequesterCount-1:0] s_handshake_skid;
  wire [               RequesterCount-1:0] p1_handshake;

  // 生成循环
  genvar g_i;
  genvar g_m;
  genvar g_j;
  genvar g_bit;
  genvar g_lane;
  genvar g_group;

  // 仲裁状态与流水握手
  assign arb_onehot_locked  = arb_onehot_group[0];
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

  // p1 流水线
  always @(posedge clk) begin : pipeline_p1
    integer i;
    if (rst) begin
      p1_axis_svalid <= 'd0;
      p1_axis_susr   <= 'd0;
    end else begin
      for (i = 0; i < RequesterCount; i = i + 1) begin
        p1_axis_sdata[i*DataWidth+:DataWidth] <= s_handshake_skid[i] ?
            axis_sdata_skid[i*DataWidth+:DataWidth] : p1_axis_sdata[i*DataWidth+:DataWidth];
        p1_axis_skeep[i*KeepWidth+:KeepWidth] <= s_handshake_skid[i] ?
            axis_skeep_skid[i*KeepWidth+:KeepWidth] : p1_axis_skeep[i*KeepWidth+:KeepWidth];
        p1_axis_susr[i*UsrWidth+:UsrWidth] <= s_handshake_skid[i] ?
            axis_susr_skid[i*UsrWidth+:UsrWidth] : p1_axis_susr[i*UsrWidth+:UsrWidth];
        p1_axis_slast[i] <= s_handshake_skid[i] ? axis_slast_skid[i] : p1_axis_slast[i];
        p1_axis_svalid[i] <= s_handshake_skid[i] ?
            1'b1 : (p1_handshake[i] ? 1'b0 : p1_axis_svalid[i]);
      end
    end
  end

  // 并行仲裁，面积换时序
  //// 计算请求有效标志
  for (g_i = 0; g_i < RequesterCount; g_i = g_i + 1) begin : gen_valid
    assign p1_req_valid[g_i] = p1_axis_svalid[g_i] &&
        (p1_axis_susr[g_i*UsrWidth+:ReqWidth] != InvalidReq);
    assign skid_req_valid[g_i] = axis_svalid_skid[g_i] && (!p1_axis_svalid[g_i] || axis_mready_skid)
        && (axis_susr_skid[g_i*UsrWidth+:ReqWidth] != InvalidReq);
  end
  //// 计算refresh
  assign arb_refresh = (!has_locked_channel) || (|(p1_handshake & p1_axis_slast));
  //// 计算掩码
  for (g_m = 0; g_m < RequesterCount; g_m = g_m + 1) begin : gen_advance
    if (LowFirst == 1) begin : gen_low
      if (g_m == 0) begin : gen_endpoint
        assign rr_mask_next[g_m] = 1'b0;
      end else begin : gen_remaining
        assign rr_mask_next[g_m] = |arb_onehot_locked[g_m-1:0];
      end
    end else begin : gen_high
      if (g_m == RequesterCount - 1) begin : gen_endpoint
        assign rr_mask_next[g_m] = 1'b0;
      end else begin : gen_remaining
        assign rr_mask_next[g_m] = |arb_onehot_locked[RequesterCount-1:g_m+1];
      end
    end
  end
  assign rr_mask_active = (refresh_d1 && has_locked_channel) ? rr_mask_next : rr_mask;
  //// 计算仲裁独热码
  for (g_i = 0; g_i < RequesterCount; g_i = g_i + 1) begin : gen_candidate
    assign arb_req_valid[g_i] = arb_onehot_locked[g_i] ? skid_req_valid[g_i] : p1_req_valid[g_i];
    for (g_j = 0; g_j < RequesterCount; g_j = g_j + 1) begin : gen_opponent
      if (g_i == g_j) begin : gen_self
        assign wins_against[g_i*RequesterCount+g_j] = 1'b1;
      end else if (g_i < g_j) begin : gen_pair
        wire [ReqWidth-1:0] value_i_p1;
        wire [ReqWidth-1:0] value_i_skid;
        wire [ReqWidth-1:0] value_j_p1;
        wire [ReqWidth-1:0] value_j_skid;
        wire value_preferred_p1_p1, value_preferred_p1_skid, value_preferred_skid_p1, rr_preferred;
        wire wins_p1_p1, wins_p1_skid, wins_skid_p1, wins;
        localparam [RequesterCount-1:0] BetweenMask = (LowFirst == 1) ?
            (({RequesterCount{1'b1}} << g_i) & ({RequesterCount{1'b1}} >> (RequesterCount - g_j))) :
            (({RequesterCount{1'b1}} << (g_i + 1)) &
             ({RequesterCount{1'b1}} >> (RequesterCount - g_j - 1)));
        wire grant_between;
        wire grant_outside;
        wire rr_preferred_saved;

        assign value_i_p1   = p1_axis_susr[g_i*UsrWidth+:ReqWidth];
        assign value_i_skid = axis_susr_skid[g_i*UsrWidth+:ReqWidth];
        assign value_j_p1   = p1_axis_susr[g_j*UsrWidth+:ReqWidth];
        assign value_j_skid = axis_susr_skid[g_j*UsrWidth+:ReqWidth];
        // 并行预比较：阶段后缀依次对应候选通道i和对手通道j的数据来源
        if (LowReqFirst == 1) begin : gen_better_low_first
          assign value_preferred_p1_p1   = (value_i_p1 < value_j_p1);
          assign value_preferred_p1_skid = (value_i_p1 < value_j_skid);
          assign value_preferred_skid_p1 = (value_i_skid < value_j_p1);
        end else begin : gen_better_high_first
          assign value_preferred_p1_p1   = (value_i_p1 > value_j_p1);
          assign value_preferred_p1_skid = (value_i_p1 > value_j_skid);
          assign value_preferred_skid_p1 = (value_i_skid > value_j_p1);
        end
        // 直接按当前grant所在区间前视RR
        assign grant_between = |(arb_onehot_locked & BetweenMask);
        assign grant_outside = |(arb_onehot_locked & ~BetweenMask);
        if (LowFirst == 1) begin : gen_low_prefer
          assign rr_preferred_saved = rr_mask[g_i] || !rr_mask[g_j];
          assign rr_preferred = (refresh_d1 && grant_outside)  // refresh_d1拍的前视
              || (rr_preferred_saved && !(refresh_d1 && grant_between));  // 非refresh_d1拍使用RR掩码
        end else begin : gen_high_prefer
          assign rr_preferred_saved = rr_mask[g_i] && !rr_mask[g_j];
          assign rr_preferred = (refresh_d1 && grant_between) ||
              (rr_preferred_saved && !(refresh_d1 && grant_outside));
        end
        assign wins_p1_p1 = value_preferred_p1_p1 || ((value_i_p1 == value_j_p1) && rr_preferred);
        assign wins_p1_skid = value_preferred_p1_skid ||
            ((value_i_p1 == value_j_skid) && rr_preferred);
        assign wins_skid_p1 = value_preferred_skid_p1 ||
            ((value_i_skid == value_j_p1) && rr_preferred);

        assign wins = arb_onehot_locked[g_i] ?
            wins_skid_p1 : (arb_onehot_locked[g_j] ? wins_p1_skid : wins_p1_p1);
        assign wins_against[g_i*RequesterCount+g_j] = !arb_req_valid[g_j] || wins;
        assign wins_against[g_j*RequesterCount+g_i] = !arb_req_valid[g_i] || !wins;
      end
    end
    assign arb_onehot[g_i] =
      arb_req_valid[g_i] && (&wins_against[g_i*RequesterCount+:RequesterCount]);
  end
  //// 生成输出和缓存
  always @(posedge clk) begin
    if (rst) begin
      refresh_d1 <= 'd0;
      rr_mask    <= 'd0;
    end else begin
      refresh_d1 <= arb_refresh;
      rr_mask    <= rr_mask_active;
    end
  end
  //// 复制arb_onehot_locked寄存器
  for (g_group = 0; g_group < SelectGroupCount; g_group = g_group + 1) begin : gen_select_group
    if (SelectGroupCount == 1) begin : gen_shared
      reg [RequesterCount-1:0] arb_onehot_locked_group;

      always @(posedge clk) begin
        if (rst) begin
          arb_onehot_locked_group <= 'd0;
        end else if (arb_refresh) begin
          arb_onehot_locked_group <= arb_onehot;
        end
      end
      assign arb_onehot_group[g_group] = arb_onehot_locked_group;
    end else begin : gen_replica
      (* dont_touch = "true" *) reg [RequesterCount-1:0] arb_onehot_locked_group;

      always @(posedge clk) begin
        if (rst) begin
          arb_onehot_locked_group <= 'd0;
        end else if (arb_refresh) begin
          arb_onehot_locked_group <= arb_onehot;
        end
      end
      assign arb_onehot_group[g_group] = arb_onehot_locked_group;
    end
  end

  // p2 输出skid
  for (g_bit = 0; g_bit < DataWidth; g_bit = g_bit + 1) begin : gen_data
    wire [RequesterCount-1:0] terms;
    for (g_lane = 0; g_lane < RequesterCount; g_lane = g_lane + 1) begin : gen_terms
      assign terms[g_lane] = arb_onehot_group[((g_bit/8)*SelectGroupCount)/KeepWidth][g_lane] &
          p1_axis_sdata[g_lane*DataWidth+g_bit];
    end
    assign axis_mdata_skid[g_bit] = |terms;
  end

  for (g_bit = 0; g_bit < KeepWidth; g_bit = g_bit + 1) begin : gen_keep
    wire [RequesterCount-1:0] terms;
    for (g_lane = 0; g_lane < RequesterCount; g_lane = g_lane + 1) begin : gen_terms
      assign terms[g_lane] = arb_onehot_group[(g_bit*SelectGroupCount)/KeepWidth][g_lane] &
          p1_axis_skeep[g_lane*KeepWidth+g_bit];
    end
    assign axis_mkeep_skid[g_bit] = |terms;
  end

  for (g_bit = 0; g_bit < UsrWidth; g_bit = g_bit + 1) begin : gen_usr
    wire [RequesterCount-1:0] terms;
    for (g_lane = 0; g_lane < RequesterCount; g_lane = g_lane + 1) begin : gen_terms
      assign terms[g_lane] = arb_onehot_group[(g_bit*SelectGroupCount)/UsrWidth][g_lane] &
          p1_axis_susr[g_lane*UsrWidth+g_bit];
    end
    assign axis_musr_skid[g_bit] = |terms;
  end

  for (g_lane = 0; g_lane < RequesterCount; g_lane = g_lane + 1) begin : gen_last_terms
    assign last_terms[g_lane] = arb_onehot_locked[g_lane] & p1_axis_slast[g_lane];
  end
  assign axis_mlast_skid = |last_terms;
  for (g_lane = 0; g_lane < RequesterCount; g_lane = g_lane + 1) begin : gen_valid_terms
    assign valid_terms[g_lane] = arb_onehot_locked[g_lane] & p1_axis_svalid[g_lane];
  end
  assign axis_mvalid_skid = |valid_terms;

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
