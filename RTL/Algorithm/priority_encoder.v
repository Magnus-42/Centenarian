// -----------------------------------------------------------------------------
// File Name   : priority_encoder.v
// Module Name : priority_encoder
// Author      : LiXintao
// Created     : 2026-11-04
// Version     : 1.2
// -----------------------------------------------------------------------------
// Description : 优先级编码器，输出获选请求的独热码和二进制索引。
// Note        : 纯组合逻辑输出；
//               LowFirst=1时低位优先，LowFirst=0时高位优先；
//               req全0时，onehot和index均为0；
//               仅当onehot非0时，index才表示有效请求的位置。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module priority_encoder #(
    parameter integer Width = 6,
    parameter integer LowFirst = 1,
    localparam integer IndexWidth = (Width <= 1) ? 1 : $clog2(Width)
) (
    input  wire [     Width-1:0] req,
    output wire [IndexWidth-1:0] index,
    output wire [     Width-1:0] onehot
);

  // 按LowFirst提取最高或最低编号的有效请求。
  // 将独热码并行归约为索引，无请求时两者均为零。

  // 参数范围检查
  initial begin
    if (Width < 1 || (LowFirst != 0 && LowFirst != 1)) begin
      $display("错误：priority_encoder：不支持的参数配置。");
      $finish;
    end
  end

  // 生成循环
  genvar g_i;
  genvar g_j;

  // 独热码
  if (LowFirst == 1) begin : gen_onehot_low
    assign onehot = req & (~req + 1'b1);  // 补码特性 req  & (~req  + 1'b1) 提取最低位的 1
  end else begin : gen_onehot_high
    wire [Width-1:0] req_reversed;
    wire [Width-1:0] onehot_reversed;
    genvar reverse_bit;
    for (
        reverse_bit = 0; reverse_bit < Width; reverse_bit = reverse_bit + 1
    ) begin : gen_bit_reverse
      assign req_reversed[reverse_bit]   = req[Width-1-reverse_bit];
      assign onehot[Width-1-reverse_bit] = onehot_reversed[reverse_bit];
    end
    assign onehot_reversed = req_reversed & (~req_reversed + 1'b1);
  end

  // 将获选请求的独热码编码为二进制索引
  for (g_i = 0; g_i < IndexWidth; g_i = g_i + 1) begin : gen_index
    wire [Width-1:0] index_terms;
    for (g_j = 0; g_j < Width; g_j = g_j + 1) begin : gen_index_terms
      assign index_terms[g_j] = onehot[g_j] && (((g_j >> g_i) & 1) != 0);
    end
    assign index[g_i] = |index_terms;
  end

endmodule
`resetall
