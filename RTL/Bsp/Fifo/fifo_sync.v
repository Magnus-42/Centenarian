`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : fifo_sync.v
// Module Name : fifo_sync
// Author      : LiXintao
// Date        : 2026-08-27
// Last Modify : 2026-09-16
// Version     : v3.0
// ----------------------------------------------------------------------------
// Description : 单时钟 FIFO，支持可编程阈值及分布式或块 RAM 存储
// Note        :
//   1. FIFO_DEPTH 必须为 2 的幂
//   2. 允许自动推断FIFO类型
// ============================================================================
module fifo_sync #(
    parameter FIFO_DEPTH = 32,  // FIFO 深度, 需为 2 的幂
    parameter DATA_WIDTH = 64,  // 数据位宽 (字节整数倍)
    parameter FIFO_MEMORY_TYPE = "distributed",  // 存储类型: distributed / block / auto
    parameter PROG_EMPTY_THRESH  = FIFO_DEPTH/4,          // 可编程空阈值 (剩余 <= 该值拉高 prog_empty)
    parameter PROG_FULL_THRESH   = FIFO_DEPTH/2,          // 可编程满阈值 (剩余 >= 该值拉高 prog_full)
    parameter REMAIN_COUNT_WIDTH = $clog2(FIFO_DEPTH) + 1,  // 剩余深度计数输出位宽
    parameter BRAM_DO_REG= 2 // BRAM的输出流水线级数，推荐为2，可以提高时序
) (
    // ============================================================================
    // 时钟与复位
    // ============================================================================
    input wire rst,
    input wire clk,

    // ============================================================================
    // FIFO 数据接口
    // ============================================================================
    input  wire [        DATA_WIDTH-1:0] din,
    input  wire                          wr_en,
    input  wire                          rd_en,
    output wire [        DATA_WIDTH-1:0] dout,
    output wire                          full,
    output wire                          empty,
    output wire                          prog_full,
    output wire                          prog_empty,
    output wire [REMAIN_COUNT_WIDTH-1:0] remain_count
);

  // --- 参数 ---
  localparam ADDR_WIDTH = $clog2(FIFO_DEPTH);

  // 基于容量/位宽/深度 设计ram类型
  // ≤ 64	任意	分布式 RAM
  // ≤1K 且	≤9Kb	分布式 RAM
  // > 1K	任意	BRAM
  // 任意	> 18Kb	BRAM
  // 任意（浅）	位宽 ≥ 256	BRAM	超宽位宽分布式要成片 LUT
  function is_distributed;
  input                                                integer width   ;
  input                                                integer depth   ;
    begin
      is_distributed = (depth <= 64 || (depth <= 1024 && width*depth <= 9216)) && width < 256;
    end
  endfunction

  localparam DATA_AUTO_TYPE= is_distributed(DATA_WIDTH,      FIFO_DEPTH) ? "distributed" : "block";
  localparam DATA_MEMORY_TYPE= FIFO_MEMORY_TYPE == "auto" ? DATA_AUTO_TYPE : FIFO_MEMORY_TYPE;

  // --- 读写指针 ---
  reg [ADDR_WIDTH:0] wr_ptr;
  reg [ADDR_WIDTH:0] rd_ptr;

  // --- FIFO 状态 ---
  wire fifo_full;
  wire fifo_empty;

  // --- FIFO 存储体 ---
  (* ram_style = DATA_MEMORY_TYPE *) reg [DATA_WIDTH-1:0] fifo_mem[0:FIFO_DEPTH-1];

  // ============================================================================
  // FIFO 状态与计数
  // ============================================================================
  assign fifo_full = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) &&
                     (wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0]);
  assign fifo_empty = wr_ptr == rd_ptr;
  assign remain_count = wr_ptr - rd_ptr;
  assign full = fifo_full;
  assign empty = fifo_empty;
  assign prog_full = remain_count >= PROG_FULL_THRESH;
  assign prog_empty = remain_count <= PROG_EMPTY_THRESH;

  // ============================================================================
  // 写指针更新
  // ============================================================================
  always @(posedge clk) begin
    if (rst) begin
      wr_ptr <= 'd0;
    end else if (wr_en && !fifo_full) begin
      wr_ptr <= wr_ptr + 1'b1;
    end
  end

  // ============================================================================
  // FIFO 内存写入
  // ============================================================================
  always @(posedge clk) begin
    if (wr_en && !fifo_full) begin
      fifo_mem[wr_ptr[ADDR_WIDTH-1:0]] <= din;
    end
  end

  // ============================================================================
  // 读指针更新
  // ============================================================================
  always @(posedge clk) begin
    if (rst) begin
      rd_ptr <= 'd0;
    end else if (rd_en && !fifo_empty) begin
      rd_ptr <= rd_ptr + 1'b1;
    end
  end

  generate
    if (DATA_MEMORY_TYPE == "distributed") begin : g_distributed
      assign dout = fifo_mem[rd_ptr[ADDR_WIDTH-1:0]];
    end else if (DATA_MEMORY_TYPE == "block") begin : g_block
      if (BRAM_DO_REG == 1) begin
        reg [DATA_WIDTH-1:0] dout_reg;
        // ========================================================================
        // 块 RAM 注册输出
        // ========================================================================
        always @(posedge clk) begin
          if (rd_en && !fifo_empty) begin
            dout_reg <= fifo_mem[rd_ptr[ADDR_WIDTH-1:0]];
          end
        end
        assign dout = dout_reg;
      end
      else if (BRAM_DO_REG == 2) begin
        reg [DATA_WIDTH-1:0] dout_direct_reg;
        reg [DATA_WIDTH-1:0] dout_reg;
        // ========================================================================
        // 块 RAM 注册输出
        // ========================================================================
        always @(posedge clk) begin
          if (rd_en && !fifo_empty) begin
            dout_direct_reg <= fifo_mem[rd_ptr[ADDR_WIDTH-1:0]];
          end
        end

        always @(posedge clk) begin
          if (rst) begin
            dout_reg <= 'd0;
          end else if (rd_en && !fifo_empty) begin
            dout_reg <= dout_direct_reg;
          end
        end
        assign dout = dout_reg;
      end
    end
  endgenerate

endmodule
`resetall
