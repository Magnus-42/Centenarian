// -----------------------------------------------------------------------------
// File Name   : fifo_async.v
// Module Name : fifo_async
// Author      : LiXintao
// Created     : 2026-11-09
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : Gray指针异步FIFO，支持distributed/block两种存储类型。
// Note        : Depth必须为2的2次幂；
//               distributed组合输出队首，empty=0时有效；
//               block在有效读请求后延迟2个rd_clk周期输出。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module fifo_async #(
    parameter integer Depth = 512,
    parameter integer Width = 8,
    parameter MemoryType = "distributed",  // distributed/block
    parameter integer ProgEmptyThresh = Depth / 4,
    parameter integer ProgFullThresh = Depth / 2,
    localparam integer CountWidth = $clog2(Depth) + 1
) (
    input wire wr_clk,
    input wire rd_clk,
    input wire wr_arst,
    input wire rd_arst,

    input  wire                  wr_en,
    input  wire [     Width-1:0] din,
    output wire                  full,
    output wire                  prog_full,
    output wire [CountWidth-1:0] stat_wr_data_count,

    input  wire                  rd_en,
    output wire [     Width-1:0] dout,
    output wire                  empty,
    output wire                  prog_empty,
    output wire [CountWidth-1:0] stat_rd_data_count
);

  // 使用上游分域复位，Gray指针经两级寄存跨域。
  // 写域控制写入和满标志，读域控制读取和空标志。
  // 存储模式决定组合队首或两拍读返回，占用与阈值状态分域更新。

  // 参数范围检查
  initial begin
    if (Depth < 2 || (Depth & (Depth - 1)) != 0 || Width < 1) begin
      $display("错误：fifo_async：Depth必须为不小于2的2次幂，Width必须不小于1");
      $finish;
    end
    if (MemoryType != "distributed" && MemoryType != "block") begin
      $display("错误：fifo_async：MemoryType仅支持distributed或block");
      $finish;
    end
    if (ProgEmptyThresh < 0 || ProgEmptyThresh > Depth || ProgFullThresh < 0 ||
        ProgFullThresh > Depth) begin
      $display("错误：fifo_async：阈值必须位于0到Depth范围内");
      $finish;
    end
  end

  // 内部常量
  localparam integer AddrWidth = $clog2(Depth);
  localparam [AddrWidth:0] GrayTopTwoBitsMask = Depth | (Depth >> 1);

  // 存储体
  (* ram_style = MemoryType *)reg  [     Width-1:0] mem                      [0:Depth-1];

  // 写域指针与状态
  reg  [   AddrWidth:0] wr_ptr_bin;
  reg  [   AddrWidth:0] wr_ptr_gray;
  reg                   wr_full_reg;
  reg                   wr_prog_full_reg;
  reg  [CountWidth-1:0] wr_data_count;
  wire [CountWidth-1:0] wr_data_count_next;
  wire                  wr_full_next;
  wire                  wr_accept;
  wire [   AddrWidth:0] wr_ptr_bin_next;
  wire [   AddrWidth:0] wr_ptr_gray_next;

  // 读域指针与状态
  reg  [   AddrWidth:0] rd_ptr_bin;
  reg  [   AddrWidth:0] rd_ptr_gray;
  reg                   rd_empty_reg;
  reg                   rd_prog_empty_reg;
  reg  [CountWidth-1:0] rd_data_count;
  wire [CountWidth-1:0] rd_data_count_next;
  wire                  rd_empty_next;
  wire [CountWidth-1:0] rd_data_count_if_no_read;
  wire [CountWidth-1:0] rd_data_count_if_read;
  wire                  rd_prog_empty_if_no_read;
  wire                  rd_prog_empty_if_read;
  wire                  rd_empty_if_no_read;
  wire                  rd_empty_if_read;
  wire                  rd_accept;
  wire [   AddrWidth:0] rd_ptr_bin_next;
  wire [   AddrWidth:0] rd_ptr_gray_next;
  wire [   AddrWidth:0] rd_ptr_bin_plus_one;
  wire [   AddrWidth:0] rd_ptr_gray_plus_one;

  // Gray指针跨域同步
  wire [   AddrWidth:0] wr_rd_ptr_bin_sync;
  wire [   AddrWidth:0] rd_wr_ptr_bin_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)reg  [   AddrWidth:0] wr_rd_ptr_gray_sync_d1;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)reg  [   AddrWidth:0] wr_rd_ptr_gray_sync_d2;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)reg  [   AddrWidth:0] rd_wr_ptr_gray_sync_d1;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)reg  [   AddrWidth:0] rd_wr_ptr_gray_sync_d2;

  // 生成循环
  genvar g_gray;

  // 读写指针格雷码同步
  //// 两级同步
  always @(posedge wr_clk or posedge wr_arst) begin
    if (wr_arst) begin
      wr_rd_ptr_gray_sync_d1 <= 'd0;
      wr_rd_ptr_gray_sync_d2 <= 'd0;
    end else begin
      wr_rd_ptr_gray_sync_d1 <= rd_ptr_gray;
      wr_rd_ptr_gray_sync_d2 <= wr_rd_ptr_gray_sync_d1;
    end
  end
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) begin
      rd_wr_ptr_gray_sync_d1 <= 'd0;
      rd_wr_ptr_gray_sync_d2 <= 'd0;
    end else begin
      rd_wr_ptr_gray_sync_d1 <= wr_ptr_gray;
      rd_wr_ptr_gray_sync_d2 <= rd_wr_ptr_gray_sync_d1;
    end
  end
  //// 格雷码转二进制
  assign wr_rd_ptr_bin_sync[AddrWidth] = wr_rd_ptr_gray_sync_d2[AddrWidth];
  assign rd_wr_ptr_bin_sync[AddrWidth] = rd_wr_ptr_gray_sync_d2[AddrWidth];
  for (g_gray = 0; g_gray < AddrWidth; g_gray = g_gray + 1) begin : gen_gray_decode
    assign wr_rd_ptr_bin_sync[g_gray] = ^wr_rd_ptr_gray_sync_d2[AddrWidth:g_gray];
    assign rd_wr_ptr_bin_sync[g_gray] = ^rd_wr_ptr_gray_sync_d2[AddrWidth:g_gray];
  end

  // 写入
  assign wr_accept        = wr_en && !full && !wr_arst;
  assign wr_ptr_bin_next  = wr_accept ? wr_ptr_bin + 1'b1 : wr_ptr_bin;
  assign wr_ptr_gray_next = (wr_ptr_bin_next >> 1) ^ wr_ptr_bin_next;
  always @(posedge wr_clk or posedge wr_arst) begin
    if (wr_arst) begin
      wr_ptr_bin  <= 'd0;
      wr_ptr_gray <= 'd0;
    end else begin
      wr_ptr_bin  <= wr_ptr_bin_next;
      wr_ptr_gray <= wr_ptr_gray_next;
    end
  end
  always @(posedge wr_clk) begin
    if (wr_accept) mem[wr_ptr_bin[AddrWidth-1:0]] <= din;
  end

  // 读取
  assign rd_accept            = rd_en && !empty && !rd_arst;
  assign rd_ptr_bin_plus_one  = rd_ptr_bin + 1'b1;
  assign rd_ptr_gray_plus_one = (rd_ptr_bin_plus_one >> 1) ^ rd_ptr_bin_plus_one;
  assign rd_ptr_bin_next      = rd_accept ? rd_ptr_bin_plus_one : rd_ptr_bin;
  assign rd_ptr_gray_next     = (rd_ptr_bin_next >> 1) ^ rd_ptr_bin_next;
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) begin
      rd_ptr_bin  <= 'd0;
      rd_ptr_gray <= 'd0;
    end else begin
      rd_ptr_bin  <= rd_ptr_bin_next;
      rd_ptr_gray <= rd_ptr_gray_next;
    end
  end
  if (MemoryType == "distributed") begin : gen_distributed
    assign dout = mem[rd_ptr_bin[AddrWidth-1:0]];
  end else begin : gen_block
    reg [Width-1:0] rd_p1_dout, rd_p2_dout;
    reg rd_accept_d1;
    always @(posedge rd_clk or posedge rd_arst) begin
      if (rd_arst) rd_accept_d1 <= 1'b0;
      else rd_accept_d1 <= rd_accept;
    end
    always @(posedge rd_clk) begin
      rd_p1_dout <= mem[rd_ptr_bin[AddrWidth-1:0]];
      if (rd_arst) rd_p2_dout <= 'd0;
      else if (rd_accept_d1) rd_p2_dout <= rd_p1_dout;
    end
    assign dout = rd_p2_dout;
  end

  // 占用计数与满空标志
  //// 写域，占用量保守偏大
  assign wr_data_count_next = wr_ptr_bin_next - wr_rd_ptr_bin_sync;
  assign wr_full_next       = wr_ptr_gray_next == (wr_rd_ptr_gray_sync_d2 ^ GrayTopTwoBitsMask);
  always @(posedge wr_clk or posedge wr_arst) begin
    if (wr_arst) begin
      wr_full_reg      <= 1'b0;
      wr_data_count    <= 'd0;
      wr_prog_full_reg <= {CountWidth{1'b0}} >= ProgFullThresh;
    end else begin
      wr_full_reg      <= wr_full_next;
      wr_data_count    <= wr_data_count_next;
      wr_prog_full_reg <= wr_data_count_next >= ProgFullThresh;
    end
  end
  //// 读域，占用量保守偏小
  assign rd_data_count_if_no_read = rd_wr_ptr_bin_sync - rd_ptr_bin;
  assign rd_data_count_if_read    = rd_wr_ptr_bin_sync - rd_ptr_bin_plus_one;
  assign rd_data_count_next       = rd_accept ? rd_data_count_if_read : rd_data_count_if_no_read;
  assign rd_prog_empty_if_no_read = rd_data_count_if_no_read <= ProgEmptyThresh;
  assign rd_prog_empty_if_read    = rd_data_count_if_read <= ProgEmptyThresh;
  assign rd_empty_if_no_read      = rd_ptr_gray == rd_wr_ptr_gray_sync_d2;
  assign rd_empty_if_read         = rd_ptr_gray_plus_one == rd_wr_ptr_gray_sync_d2;
  assign rd_empty_next            = rd_accept ? rd_empty_if_read : rd_empty_if_no_read;
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) begin
      rd_empty_reg      <= 1'b1;
      rd_data_count     <= 'd0;
      rd_prog_empty_reg <= {CountWidth{1'b0}} <= ProgEmptyThresh;
    end else begin
      rd_empty_reg      <= rd_empty_next;
      rd_data_count     <= rd_data_count_next;
      rd_prog_empty_reg <= rd_accept ? rd_prog_empty_if_read : rd_prog_empty_if_no_read;
    end
  end

  assign full               = wr_full_reg;
  assign empty              = rd_empty_reg;
  assign stat_wr_data_count = wr_data_count;
  assign stat_rd_data_count = rd_data_count;
  assign prog_full          = wr_prog_full_reg;
  assign prog_empty         = rd_prog_empty_reg;
endmodule
`resetall
