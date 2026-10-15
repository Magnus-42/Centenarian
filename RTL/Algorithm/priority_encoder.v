`resetall
`default_nettype none
`timescale 1ns / 100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : priority_encoder.v
// Module Name : priority_encoder
// Author      : LiXintao
// Date        : 2026-08-14
// Last Modify : 2026-09-17
// Version     : 2.0
// ----------------------------------------------------------------------------
// Description : 树形分级压缩优先级编码器, 找出输入中第一个 1 的位置
// Note        : 组合逻辑, 深度 O(log2 WIDTH); 全 0 时 valid=0, index 无效
// ============================================================================
module priority_encoder #(
    parameter WIDTH = 8,  // 输入位宽
    parameter LOW_FIRST = 1,  // 1: 从低位找第一个 1; 0: 从高位找
    parameter IDX_W = (WIDTH <= 1) ? 1 : $clog2(WIDTH)  // 索引输出位宽
) (
    input  wire [WIDTH-1:0] din,
    output wire [IDX_W-1:0] index,
    output wire [WIDTH-1:0] dout_onehot,
    output wire             valid
);

  localparam P2 = 1 << $clog2(WIDTH);  // 补齐到 2 的幂 (满二叉树)
  localparam P2_PAD = P2 - WIDTH;
  localparam LEVELS = $clog2(WIDTH);  // 压缩级数 (树高)

  wire [P2-1:0] din_pad;
  
  // 高位补 0
  generate
    if (P2_PAD == 0) begin : gen_no_pad
      assign din_pad = din;
    end else begin : gen_pad
      assign din_pad = {{P2_PAD{1'b0}}, din};
    end
  endgenerate

  // ----------------------------------------------------------------------------
  // 树形压缩中间量: 每级一个有效向量 + 一个索引向量
  // ----------------------------------------------------------------------------
  reg  [      P2-1:0] valid_tree                    [0:LEVELS];
  reg  [P2*IDX_W-1:0] idx_tree                      [0:LEVELS];

  integer l, j;

  // ============================================================================
  // 树形分级压缩: 叶子 -> 逐级两两合并 -> 根
  // ============================================================================
  always @* begin
    for (l = 0; l <= LEVELS; l = l + 1) begin
      valid_tree[l] = 'd0;
      idx_tree[l]   = 'd0;
    end

    // 第 0 级 (叶子): 每位对应 din 的 1 bit, 索引即该位序号
    for (j = 0; j < P2; j = j + 1) begin
      valid_tree[0][j]            = din_pad[j];
      /* verilator lint_off WIDTH */
      idx_tree[0][j*IDX_W+:IDX_W] = j;
      /* verilator lint_on WIDTH */
    end

    // 第 l 级 -> 第 l+1 级: 两两合并, 保留优先级高的一侧
    for (l = 0; l < LEVELS; l = l + 1) begin
      for (j = 0; j < (P2 >> (l + 1)); j = j + 1) begin
        valid_tree[l+1][j] = valid_tree[l][2*j] | valid_tree[l][2*j+1];
        if (LOW_FIRST)
          idx_tree[l+1][j*IDX_W +: IDX_W] = valid_tree[l][2*j]
                                          ? idx_tree[l][(2*j)*IDX_W +: IDX_W]
                                          : idx_tree[l][(2*j + 1)*IDX_W +: IDX_W];
        else
          idx_tree[l+1][j*IDX_W +: IDX_W] = valid_tree[l][2*j + 1]
                                          ? idx_tree[l][(2*j + 1)*IDX_W +: IDX_W]
                                          : idx_tree[l][(2*j)*IDX_W +: IDX_W];
      end
    end
  end

  // 根节点即结果
  assign valid = valid_tree[LEVELS][0];
  assign index  = idx_tree[LEVELS][IDX_W-1:0];
 
 
  // ============================================================================
  // 并行生成独热码
  // ============================================================================
  generate
    if (LOW_FIRST) begin : gen_onehot_low
      // 从低位找：利用补码特性 (din & (~din + 1))，直接提取最低位的 1
      assign dout_onehot = din & (-din);
    end else begin : gen_onehot_high
      // 从高位找：先将位翻转，利用补码提取，再翻转回原本的位置
      wire [WIDTH-1:0] din_rev;
      wire [WIDTH-1:0] onehot_rev;
      genvar i;
      for (i = 0; i < WIDTH; i = i + 1) begin : bit_reverse
        assign din_rev[i] = din[WIDTH-1-i];
        assign dout_onehot[WIDTH-1-i] = onehot_rev[i];
      end
      assign onehot_rev = din_rev & (-din_rev);
    end
  endgenerate

endmodule
`resetall
