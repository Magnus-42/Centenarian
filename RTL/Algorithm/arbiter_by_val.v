`resetall
`default_nettype none
`timescale 1ns / 100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : arbiter_by_val.v
// Module Name : arbiter_by_val
// Author      : LiXintao
// Date        : 2026-10-11
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持数字值进行仲裁的仲裁器
// Note        : 相同数值之间进行RR仲裁，不同数值之间进行严格仲裁
//
// ============================================================================

module arbiter_by_val #(
  parameter  N = 8 ,      // 请求者数量
  parameter  WIDTH= 8 ,      // 优先级数值位宽
  parameter  PIPELINE= 1 ,      // 0: 组合输出; 1: 单级寄存; 2: 两级流水
  parameter  LOW_FIRST= 0 ,       // 0: 高位先行; 1: 低位先行
  parameter  IDX_W= (N <= 1) ? 1 : $clog2(N)// 索引输出位宽
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,
  input  wire          [           N*WIDTH-1:0]        req_val         ,// 0 无效，非 0 有效
  output wire          [                 N-1:0]        grant_onehot    ,// 独热码授权
  output wire          [             WIDTH-1:0]        grant_val       ,// 被授权的数值
  input  wire                                          grant_ack       ,
  output wire                                          grant_valid      
);

  // =========================================================
  // 0. 参数与寄存器
  // =========================================================
  localparam LVLS= (N > 1) ? $clog2(N) : 1;
  localparam LEAVES= 1 << LVLS;
  localparam [                 N-1:0]        PTR_RST_VAL= 1 ;

  localparam [                 N-1:0]        RST_PRI_MASK= LOW_FIRST
      ? ((PTR_RST_VAL << 1) - 1'b1)                                 // bits [0, 0]
      : ~(PTR_RST_VAL - 1'b1);                                      // bits [0, N-1]

  reg                  [                 N-1:0]        pri_mask_reg     ;

  reg                  [                 N-1:0]        grant_onehot_reg ;// 独热码授权
  reg                  [             WIDTH-1:0]        grant_val_reg    ;// 被授权的数值
  reg                                                  grant_valid_reg  ;

  genvar g;

  // =========================================================
  // Stage 1 组合：解包 + 最大值树 + eq_mask
  // =========================================================
  wire                 [             WIDTH-1:0]        vals  [0:LEAVES-1];

  generate
    for (g = 0; g < LEAVES; g = g + 1) begin : gen_unpack
      if (g < N) begin
  assign  vals[g]          = req_val[g*WIDTH +: WIDTH];
      end else begin
  assign  vals[g]          = {WIDTH{1'b0}}    ;
      end
    end
  endgenerate

  // ---- 最大值树 ----
  wire                 [             WIDTH-1:0]        mtree [0:LVLS][0:LEAVES-1];
  generate
    for (g = 0; g < LEAVES; g = g + 1) begin : gen_leaf
  assign  mtree[0][g]      = vals[g]          ;
    end

    for (genvar lvl = 1; lvl <= LVLS; lvl = lvl + 1) begin : gen_lvl
      for (g = 0; g < (LEAVES >> lvl); g = g + 1) begin : gen_node
        assign mtree[lvl][g] =
          (mtree[lvl-1][2*g] >= mtree[lvl-1][2*g+1])
          ? mtree[lvl-1][2*g]
          : mtree[lvl-1][2*g+1];
      end
    end
  endgenerate

  wire                 [             WIDTH-1:0]        max_val           = mtree[LVLS][0]                           ;
  wire                                                 any_req           = |max_val                                ;

  // ---- eq_mask ----
  wire                 [                 N-1:0]        eq_mask          ;
  generate
    for (g = 0; g < N; g = g + 1) begin : gen_eq_mask
  assign  eq_mask[g]       = (vals[g] == max_val) & any_req;
    end
  endgenerate

  // =========================================================
  // Stage 1 / Stage 2 之间的流水寄存器（PIPELINE=2 时启用）
  // =========================================================
  wire                 [                 N-1:0]        eq_mask_s2       ;
  wire                 [             WIDTH-1:0]        max_val_s2       ;

  generate
    if (PIPELINE < 2) begin : gen_s1_bypass
      // 直通：Stage 2 使用组合结果
  assign  eq_mask_s2       = eq_mask          ;
  assign  max_val_s2       = max_val          ;
    end 
    else begin : gen_s1_reg
  reg                  [                 N-1:0]        eq_mask_q        ;
  reg                  [             WIDTH-1:0]        max_val_q        ;

      always @(posedge clk) begin
        if (rst) begin
          eq_mask_q <= {N{1'b0}};
          max_val_q <= {WIDTH{1'b0}};
        end else begin
          eq_mask_q <= eq_mask;
          max_val_q <= max_val;
        end
      end

  assign  eq_mask_s2       = eq_mask_q        ;
  assign  max_val_s2       = max_val_q        ;
    end
  endgenerate

  // =========================================================
  // Stage 2 组合：RR 选择 + 独热提取 + 下一状态
  // =========================================================
  wire                 [                 N-1:0]        sel_hi_s2         = eq_mask_s2 & pri_mask_reg                ;
  wire                                                 any_hi_s2         = |sel_hi_s2                               ;
  wire                                                 any_sel_s2        = |eq_mask_s2                              ;

  // ---- 独热提取（方向随 LOW_FIRST）----
  wire                 [                 N-1:0]        onehot_hi_s2     , onehot_base_s2;

  generate
    if (!LOW_FIRST) begin : gen_low_onehot
      // 高位先行：段内取【最低】位
  assign  onehot_hi_s2     = sel_hi_s2  & (~sel_hi_s2  + 1'b1);
  assign  onehot_base_s2   = eq_mask_s2 & (~eq_mask_s2 + 1'b1);
    end else begin : gen_high_onehot
        // 低位先行：段内取【最高】位（位反转技巧）
  wire                 [                 N-1:0]        sel_hi_rev       , eq_rev;
  wire                 [                 N-1:0]        low_hi_rev       , low_base_rev;

      for (g = 0; g < N; g = g + 1) begin : gen_rev
  assign  sel_hi_rev[g]    = sel_hi_s2[N-1-g] ;
  assign  eq_rev[g]        = eq_mask_s2[N-1-g];
      end

  assign  low_hi_rev       = sel_hi_rev & (~sel_hi_rev + 1'b1);
  assign  low_base_rev     = eq_rev     & (~eq_rev     + 1'b1);

      for (g = 0; g < N; g = g + 1) begin : gen_rev_bk
  assign  onehot_hi_s2[g]  = low_hi_rev[N-1-g];
  assign  onehot_base_s2[g]= low_base_rev[N-1-g];
      end
    end
  endgenerate

  wire                 [                 N-1:0]        grant_next_s2     = any_hi_s2 ? onehot_hi_s2 : onehot_base_s2;

  // ---- 指针轮转方向 ----
  wire                 [                 N-1:0]        next_pointer_oh_s2;
  generate
    if (N == 1)
  assign  next_pointer_oh_s2= grant_next_s2    ;
    else if (LOW_FIRST)
  assign  next_pointer_oh_s2= {grant_next_s2[0], grant_next_s2[N-1:1]};
    else
  assign  next_pointer_oh_s2= {grant_next_s2[N-2:0], grant_next_s2[N-1]};
  endgenerate

  // ---- 下一拍 pri_mask ----
  wire                 [                 N-1:0]        next_pri_mask_s2 ;
  generate
    if (LOW_FIRST)
  assign  next_pri_mask_s2 = (next_pointer_oh_s2 << 1) - 1'b1;
    else
  assign  next_pri_mask_s2 = ~(next_pointer_oh_s2 - 1'b1);
  endgenerate

  // =========================================================
  // 轮转指针(基于"已寄存的上次授权" grant_onehot_reg)
  //   用途: PIPELINE>=1 输出级用它更新 pri_mask; 与组合版(next_pri_mask_s2)等价 ——
  //   在包级锁定(can_update)语义下, "重新仲裁"的那一拍读到的正是"刚服务完的源"。
  //   关键收益: 绕开 max树/eq/RR/独热提取整条组合链, 大幅缩短 pri_mask 关键路径。
  // =========================================================
  wire                 [                 N-1:0]        next_pointer_oh_r;
  generate
    if (N == 1)
  assign  next_pointer_oh_r= grant_onehot_reg  ;
    else if (LOW_FIRST)
  assign  next_pointer_oh_r= {grant_onehot_reg[0], grant_onehot_reg[N-1:1]};
    else
  assign  next_pointer_oh_r= {grant_onehot_reg[N-2:0], grant_onehot_reg[N-1]};
  endgenerate

  wire                 [                 N-1:0]        next_pri_mask_r  ;
  generate
    if (LOW_FIRST)
  assign  next_pri_mask_r = (next_pointer_oh_r << 1) - 1'b1;
    else
  assign  next_pri_mask_r = ~(next_pointer_oh_r - 1'b1);
  endgenerate

  // =========================================================
  // 输出级
  // =========================================================
  // 当未锁定，或者收到下游 ack 解锁时，允许更新状态
  wire                                                 can_update        = !grant_valid_reg || grant_ack                     ;

  generate
    if (PIPELINE == 0) begin : gen_comb_out
      // -------- 组合输出 --------
      always @(*) begin
        grant_onehot_reg     = grant_next_s2;
        grant_val_reg = max_val_s2;
        // 等价于 |grant_next_s2: eq_mask 非空 ⇒ 独热提取必产生恰好一个 1;
        // 用 any_sel_s2(仅 |eq_mask) 可绕开 RR 掩码/独热提取链, 显著缩短关键路径
        grant_valid_reg = any_sel_s2;
      end

      always @(posedge clk) begin
        if (rst) begin
            pri_mask_reg <= RST_PRI_MASK;
        end else if (any_sel_s2) begin
            pri_mask_reg <= next_pri_mask_s2;
        end
      end
    end else begin : gen_reg_out
      // -------- 1 级 / 2 级流水线共用输出寄存器 --------
      always @(posedge clk) begin
        if (rst) begin
          grant_onehot_reg        <= {N{1'b0}};
          grant_val_reg    <= {WIDTH{1'b0}};
          grant_valid_reg <= 'd0;
          pri_mask_reg <= RST_PRI_MASK;
        end else if(can_update) begin
          grant_onehot_reg     <= grant_next_s2;
          grant_val_reg <= max_val_s2;
          // 等价于 |grant_next_s2 (见上: eq_mask 非空 ⇔ 授权有效)
          grant_valid_reg <= any_sel_s2;
          // 注意: 此处必须用组合的 next_pri_mask_s2(基于本拍 grant_next_s2)。
          // 曾用 next_pri_mask_r(基于已寄存的 grant_onehot_reg) 试图绕开组合链 ——
          // 仿真证实【不等价】: 包级锁定下 pri_mask 只在 ack 拍刷新, 用寄存值会滞后一包,
          // 导致同值轮转退化成 "AA BB"(SC3 switches 25→13)。故回退。
          if (any_sel_s2) begin
            pri_mask_reg <= next_pri_mask_s2;
          end
        end
      end
    end
  endgenerate

  assign  grant_onehot     = grant_onehot_reg ;
  assign  grant_val        = grant_val_reg    ;
  assign  grant_valid      = grant_valid_reg  ;

endmodule
`resetall
