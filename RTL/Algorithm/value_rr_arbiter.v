// -----------------------------------------------------------------------------
// File Name   : value_rr_arbiter.v
// Module Name : value_rr_arbiter
// Author      : LiXintao
// Created     : 2026-11-05
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 数值优先级仲裁器，相同优先级之间执行轮询仲裁。
// Note        : LowReqFirst=0时大值优先，每路值为0表示无效，合法最小值为1；
//               LowReqFirst=1时小值优先，每路值为全1表示无效，合法最大值为{ReqWidth{1'b1}}减1；
//               LowFirst=1时平局按编号递增轮询，否则按编号递减轮询；
//               IsInsertReg=1时，为寄存器输出，否则为组合逻辑输出；
//               onehot非0时，index才表示有效请求的位置。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module value_rr_arbiter #(
    parameter integer RequesterCount = 3,
    parameter integer ReqWidth = 6,
    parameter integer IsInsertReg = 1,
    parameter integer LowReqFirst = 0,  // 0: 数值大者胜; 1: 数值小者胜
    parameter integer LowFirst = 1,
    localparam integer IndexWidth = (RequesterCount <= 1) ? 1 : $clog2(RequesterCount)
) (
    input  wire                               clk,
    input  wire                               rst,
    input  wire [RequesterCount*ReqWidth-1:0] req,
    input  wire                               refresh,
    output wire [         RequesterCount-1:0] onehot,
    output wire [             IndexWidth-1:0] index
);

  // 逐路过滤无效码，并行比较请求数值，平局按轮询掩码选择。
  // 将获选独热码编码为索引，按IsInsertReg选择输出边界。
  // refresh控制结果保存，寄存输出模式通过refresh_d1前视轮询掩码。

  // 参数范围检查
  initial begin
    if (RequesterCount < 1 || ReqWidth < 1 ||
        (IsInsertReg != 0 && IsInsertReg != 1) ||
        (LowReqFirst != 0 && LowReqFirst != 1) ||
        (LowFirst != 0 && LowFirst != 1)) begin
      $display("错误：value_rr_arbiter：不支持的参数配置。");
      $finish;
    end
  end

  // 内部常量
  localparam [ReqWidth-1:0] InvalidReq = (LowReqFirst == 1) ? {ReqWidth{1'b1}} : {ReqWidth{1'b0}};

  // 轮询掩码
  reg  [RequesterCount-1:0] rr_mask;
  wire [RequesterCount-1:0] rr_mask_next;
  wire [RequesterCount-1:0] rr_mask_active;

  // 仲裁结果与保持
  wire [RequesterCount-1:0] arb_onehot;
  reg  [RequesterCount-1:0] arb_onehot_held;
  reg  [    IndexWidth-1:0] arb_index_held;
  wire [    IndexWidth-1:0] arb_index;

  // 生成循环
  genvar g_m;
  genvar g_i;
  genvar g_j;
  genvar g_b;
  genvar g_k;

  // 计算掩码
  for (g_m = 0; g_m < RequesterCount; g_m = g_m + 1) begin : gen_advance
    if (LowFirst == 1) begin : gen_low
      if (g_m == 0) begin : gen_endpoint
        assign rr_mask_next[g_m] = 1'b0;
      end else begin : gen_remaining
        assign rr_mask_next[g_m] = |onehot[g_m-1:0];
      end
    end else begin : gen_high
      if (g_m == RequesterCount - 1) begin : gen_endpoint
        assign rr_mask_next[g_m] = 1'b0;
      end else begin : gen_remaining
        assign rr_mask_next[g_m] = |onehot[RequesterCount-1:g_m+1];
      end
    end
  end

  // 计算仲裁独热码
  for (g_i = 0; g_i < RequesterCount; g_i = g_i + 1) begin : gen_candidate
    wire [ReqWidth-1:0] value_i;
    wire [RequesterCount-1:0] wins_against;

    assign value_i = req[g_i*ReqWidth+:ReqWidth];
    for (g_j = 0; g_j < RequesterCount; g_j = g_j + 1) begin : gen_opponent
      if (g_i == g_j) begin : gen_self
        assign wins_against[g_j] = 1'b1;
      end else begin : gen_other
        wire [ReqWidth-1:0] value_j;
        wire value_preferred, rr_preferred;

        assign value_j = req[g_j*ReqWidth+:ReqWidth];
        //// 计算数值大小
        if (LowReqFirst == 1) begin : gen_better_low
          assign value_preferred = (value_i < value_j);
        end else begin : gen_better_high
          assign value_preferred = (value_i > value_j);
        end
        //// 计算数值相同时，根据掩码和编号判断优先
        if ((LowFirst != 0 && g_i < g_j) || (LowFirst == 0 && g_i > g_j)) begin : gen_easy_prefer
          assign rr_preferred = rr_mask_active[g_i] || !rr_mask_active[g_j];
        end else begin : gen_hard_prefer
          assign rr_preferred = rr_mask_active[g_i] && !rr_mask_active[g_j];
        end
        //// 生成比较结果
        assign wins_against[g_j] = (value_j == InvalidReq) || value_preferred
            || ((value_i == value_j) && rr_preferred);
      end
    end
    // 生成最后的仲裁独热码
    assign arb_onehot[g_i] = (value_i != InvalidReq) && (&wins_against);
  end

  // 生成索引
  for (g_b = 0; g_b < IndexWidth; g_b = g_b + 1) begin : gen_index
    wire [RequesterCount-1:0] index_terms;
    for (g_k = 0; g_k < RequesterCount; g_k = g_k + 1) begin : gen_term
      assign index_terms[g_k] = arb_onehot[g_k] && (((g_k >> g_b) & 1) != 0);
    end
    assign arb_index[g_b] = |index_terms;
  end

  // 生成输出和缓存
  if (IsInsertReg == 1) begin : gen_registered
    reg refresh_d1;
    assign rr_mask_active = (refresh_d1 && (|arb_onehot_held)) ? rr_mask_next : rr_mask;
    always @(posedge clk) begin
      if (rst) begin
        rr_mask         <= 'd0;
        arb_onehot_held <= 'd0;
        arb_index_held  <= 'd0;
        refresh_d1      <= 'd0;
      end else begin
        refresh_d1      <= refresh;
        rr_mask         <= rr_mask_active;
        arb_onehot_held <= refresh ? arb_onehot : arb_onehot_held;
        arb_index_held  <= refresh ? arb_index : arb_index_held;
      end
    end
    assign onehot = arb_onehot_held;
    assign index  = arb_index_held;
  end else begin : gen_combinational
    assign rr_mask_active = rr_mask;
    always @(posedge clk) begin
      if (rst) begin
        rr_mask         <= 'd0;
        arb_onehot_held <= 'd0;
        arb_index_held  <= 'd0;
      end else begin
        arb_onehot_held <= refresh ? arb_onehot : arb_onehot_held;
        arb_index_held  <= refresh ? arb_index : arb_index_held;
        rr_mask         <= (refresh && (|arb_onehot)) ? rr_mask_next : rr_mask;
      end
    end
    assign onehot = refresh ? arb_onehot : arb_onehot_held;
    assign index  = refresh ? arb_index : arb_index_held;
  end
endmodule
`resetall
