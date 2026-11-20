// -----------------------------------------------------------------------------
// File Name   : rr_arbiter.v
// Module Name : rr_arbiter
// Author      : LiXintao
// Created     : 2026-11-05
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 轮询仲裁器，输出获选请求的独热码和二进制索引。
// Note        : refresh=1时，组合输出当前仲裁结果；
//               refresh=0时，输出保持上次保存的结果；
//               LowFirst=1时按编号递增轮询，否则按编号递减轮询；
//               onehot非0时，index才表示有效请求的位置。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module rr_arbiter #(
    parameter integer Width = 6,
    parameter integer LowFirst = 1,
    localparam integer IndexWidth = (Width <= 1) ? 1 : $clog2(Width)  // 索引输出位宽
) (
    input wire clk,
    input wire rst,

    input  wire [     Width-1:0] req,
    input  wire                  refresh,
    output wire [     Width-1:0] onehot,
    output wire [IndexWidth-1:0] index
);

  // 分别编码原始请求与掩码请求，优先选取当前轮询区间。
  // refresh时呈现并保存新结果，有效仲裁后更新轮询掩码。

  // 参数范围检查
  initial begin
    if (Width < 1 || (LowFirst != 0 && LowFirst != 1)) begin
      $display("错误：rr_arbiter：不支持的参数配置。");
      $finish;
    end
  end

  // 原始请求编码
  wire [IndexWidth-1:0] unmasked_index;
  wire [     Width-1:0] unmasked_onehot;

  // 掩码请求编码
  wire [IndexWidth-1:0] masked_index;
  wire [     Width-1:0] masked_onehot;
  wire                  has_masked_req;

  // 轮询掩码
  reg  [     Width-1:0] req_mask;
  wire [     Width-1:0] req_mask_next;
  wire [     Width-1:0] req_masked;

  // 仲裁结果与保持
  wire [     Width-1:0] arb_onehot;
  wire [IndexWidth-1:0] arb_index;
  reg  [     Width-1:0] arb_onehot_held;
  reg  [IndexWidth-1:0] arb_index_held;

  // 生成循环
  genvar g_i;

  // 输出
  //// 仲裁器输出选择
  assign has_masked_req = |req_masked;
  assign arb_index      = has_masked_req ? masked_index : unmasked_index;
  assign arb_onehot     = has_masked_req ? masked_onehot : unmasked_onehot;

  //// 仲裁器输出保持
  always @(posedge clk) begin
    if (rst) begin
      arb_index_held  <= 'd0;
      arb_onehot_held <= 'd0;
    end else begin
      arb_index_held  <= refresh ? arb_index : arb_index_held;
      arb_onehot_held <= refresh ? arb_onehot : arb_onehot_held;
    end
  end

  //// 输出
  assign index  = refresh ? arb_index : arb_index_held;
  assign onehot = refresh ? arb_onehot : arb_onehot_held;

  // 轮询掩码生成与请求过滤
  //// 计算掩码
  for (g_i = 0; g_i < Width; g_i = g_i + 1) begin : gen_req_mask
    if (LowFirst == 1) begin : gen_low_mask
      if (g_i == 0) begin : gen_endpoint
        assign req_mask_next[g_i] = 1'b0;
      end else begin : gen_remaining
        assign req_mask_next[g_i] = |arb_onehot[g_i-1:0];
      end
    end else begin : gen_high_mask
      if (g_i == Width - 1) begin : gen_endpoint
        assign req_mask_next[g_i] = 1'b0;
      end else begin : gen_remaining
        assign req_mask_next[g_i] = |arb_onehot[Width-1:g_i+1];
      end
    end
  end
  always @(posedge clk) begin
    if (rst) begin
      req_mask <= {Width{1'b0}};
    end else begin
      if (refresh && (|req)) begin
        req_mask <= req_mask_next;
      end
    end
  end
  assign req_masked = req_mask & req;

  priority_encoder #(
      .Width   (Width),
      .LowFirst(LowFirst)
  ) priority_encoder (
      .req   (req),
      .index (unmasked_index),
      .onehot(unmasked_onehot)
  );

  priority_encoder #(
      .Width   (Width),
      .LowFirst(LowFirst)
  ) priority_encoder_mask (
      .req   (req_masked),
      .index (masked_index),
      .onehot(masked_onehot)
  );

endmodule
`resetall
