`resetall
`default_nettype none
`timescale 1ns / 100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : arbiter.v
// Module Name : arbiter
// Author      : LiXintao
// Date        : 2026-08-14
// Last Modify : 2026-09-17
// Version     : 2.0
// ----------------------------------------------------------------------------
// Description : 基于 priority_encoder 的 N 选 1 仲裁器 (轮询 / 严格优先级)
// Note        : RR 由掩码环回, 无候选时回退到全量优先编码结果
//               不锁定结果时，支持流水线设计
//               ARB_SOUT_REG拉低，强制退化Strict Priority，拉高则输出延迟一拍以满足时序
// ============================================================================
module arbiter #(
    parameter ARB_TYPE = 0,  // 0=RR, 1=Strict Priority
    parameter ARB_SOUT_REG = 1,  // RR Priority输出自带一拍延时
    parameter ARB_BLOCK = 1,  // 锁定结果(即输出添加门控，需要已经获得仲裁权的拉低或者ACK输出才变化) ARB_SOUT_REG 为0时失效
    parameter ARB_BLOCK_BY_ACK = 1,  // 0 依靠Request 1依靠ACK
    parameter WIDTH = 8,  // 输入位宽
    parameter LOW_FIRST = 1,  // 1: 从低位找第一个 1; 0: 从高位找
    parameter IDX_W = (WIDTH <= 1) ? 1 : $clog2(WIDTH)  // 索引输出位宽
) (
    input wire rst,
    input wire clk,

    // --- 请求输入 ---
    input wire [WIDTH-1:0] din,

    // --- 授予输出 / 应答 ---
    output wire [WIDTH-1:0] dout_onehot,
    output wire [IDX_W-1:0] index,
    output wire             valid, // 输入全为0，有效位全为0
    input  wire             ack // 仅在ARB_SOUT_REG = 1握手才有效
);

  // ----------------------------------------------------------------------------
  // 复位 / 状态寄存器
  // ----------------------------------------------------------------------------
  reg [IDX_W-1:0] index_reg;
  reg [WIDTH-1:0] dout_onehot_reg;
  reg             valid_reg;

  // ----------------------------------------------------------------------------
  // 优先级编码结果 (来自两个 priority_encoder 例化)
  // ----------------------------------------------------------------------------
  wire [IDX_W-1:0] p_index;
  wire [WIDTH-1:0] p_dout_onehot;
  wire             p_valid;
  wire [IDX_W-1:0] p_mask_index;
  wire [WIDTH-1:0] p_mask_dout_onehot;
  wire             p_mask_valid;

  // ----------------------------------------------------------------------------
  // 轮询掩码
  // ----------------------------------------------------------------------------
  wire [WIDTH-1:0] mask;
  wire [WIDTH-1:0] din_mask;

  // ----------------------------------------------------------------------------
  // 输出选择 / 更新控制
  // ----------------------------------------------------------------------------
  // 更新使能
  reg can_update;

  wire             handshake  = valid_reg && ack;
  wire [IDX_W-1:0] next_index  = (ARB_TYPE == 'd0) ? (p_mask_valid ? p_mask_index : p_index) : p_index;
  wire [WIDTH-1:0] next_dout_onehot = (ARB_TYPE == 'd0) ? (p_mask_valid ? p_mask_dout_onehot : p_dout_onehot) : p_dout_onehot;
  wire             next_valid = (ARB_TYPE == 'd0) ? (p_mask_valid ? 1'b1 : p_valid) : p_valid;

  // ============================================================================
  // 轮询掩码: 屏蔽已服务过的位, 从当前指针后一位开始找 (环形轮询)
  // ============================================================================
  assign mask = LOW_FIRST ? ({WIDTH{1'b1}} << (index_reg + 'd1))
                          : ({WIDTH{1'b1}} >> (WIDTH - index_reg));
  assign din_mask = mask & din;

  // ============================================================================
  // 输出选择: 严格优先级且非寄存模式时直接用编码结果, 否则用寄存结果
  // ============================================================================
  assign index  = (ARB_SOUT_REG == 'd0) ? p_index : index_reg;
  assign dout_onehot  =(ARB_SOUT_REG == 'd0) ? p_dout_onehot : dout_onehot_reg;
  assign valid = (ARB_SOUT_REG == 'd0) ? p_valid : valid_reg;

  // ============================================================================
  // 更新使能 (锁定)
  // ============================================================================
  always @(*) begin
    if (ARB_BLOCK) begin
      if (valid_reg) begin
        if (ARB_BLOCK_BY_ACK) begin
          can_update = handshake;  // 收到 ACK 解锁
        end else begin
          can_update = ~din[index_reg];  // Request 撤销解锁
        end
      end else begin
        can_update = 1'b1;
      end
    end else begin
      can_update = 1'b1;
    end
  end

  // ============================================================================
  // 结果寄存器
  // ============================================================================
  always @(posedge clk) begin
    if (rst) begin
      valid_reg <= 1'b0;
      index_reg  <= 'd0;
      dout_onehot_reg <= 'd0;
    end else if (can_update) begin
      valid_reg <= next_valid;
      if (next_valid) begin   // 仅当有新请求时才更新指针
        dout_onehot_reg <= next_dout_onehot;
        index_reg <= next_index;
      end
    end
  end

  // ============================================================================
  // 优先级编码例化
  // ============================================================================
  priority_encoder #(
      .WIDTH    (WIDTH),
      .LOW_FIRST(LOW_FIRST),
      .IDX_W    (IDX_W)
  ) u_priority_encoder_inst (
      .din  (din),
      .index (p_index),
      .dout_onehot(p_dout_onehot),
      .valid(p_valid)
  );

  priority_encoder #(
      .WIDTH    (WIDTH),
      .LOW_FIRST(LOW_FIRST),
      .IDX_W    (IDX_W)
  ) u_priority_encoder_mask (
      .din  (din_mask),
      .index (p_mask_index),
      .dout_onehot(p_mask_dout_onehot),
      .valid(p_mask_valid)
  );

endmodule
`resetall
