// -----------------------------------------------------------------------------
// File Name   : fifo_async_fwft.v
// Module Name : fifo_async_fwft
// Author      : LiXintao
// Created     : 2026-11-09
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 基于Block存储的异步首字直通FIFO。
// Note        : Depth必须为2的2次幂；
//               wr_arst/rd_arst释放前禁止读写。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module fifo_async_fwft #(
    parameter integer Depth = 512,
    parameter integer Width = 8,
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

  // 底层block FIFO完成跨时钟存储，读域按三项额度预取到skid。
  // 实际消费指针同步回写域，控制总占用、满空与阈值状态。

  // 参数范围检查
  initial begin
    if (Depth < 2 || (Depth & (Depth - 1)) != 0 || Width < 1) begin
      $display(
          "错误：fifo_async_fwft：Depth必须为不小于2的2次幂，Width必须不小于1");
      $finish;
    end
    if (ProgEmptyThresh < 0 || ProgEmptyThresh > Depth || ProgFullThresh < 0 ||
        ProgFullThresh > Depth) begin
      $display("错误：fifo_async_fwft：阈值必须位于0到Depth范围内");
      $finish;
    end
  end

  // 内部常量
  localparam integer AddrWidth = $clog2(Depth);
  localparam [AddrWidth:0] GrayTopTwoBitsMask = Depth | (Depth >> 1);

  // 写域指针与状态
  reg  [   AddrWidth:0] wr_ptr_bin;
  wire                  wr_block_full;
  reg                   wr_full_reg;
  reg                   wr_prog_full_reg;
  reg  [CountWidth-1:0] wr_data_count;
  wire                  wr_accept;
  wire [   AddrWidth:0] wr_ptr_bin_next;
  wire [   AddrWidth:0] wr_ptr_gray_next;
  wire                  wr_full_next;
  wire [CountWidth-1:0] wr_data_count_next;

  // 读域指针与状态
  reg  [   AddrWidth:0] rd_consume_ptr_bin;
  reg  [   AddrWidth:0] rd_consume_ptr_gray;
  wire [   AddrWidth:0] rd_consume_ptr_bin_plus_one;
  reg  [           1:0] rd_prefetch_count;
  reg                   rd_prog_empty_reg;
  reg  [CountWidth-1:0] rd_data_count;
  wire                  rd_accept;
  wire [CountWidth-1:0] rd_data_count_next;
  wire [CountWidth-1:0] rd_data_count_if_no_read;
  wire [CountWidth-1:0] rd_data_count_if_read;
  wire                  rd_prog_empty_if_no_read;
  wire                  rd_prog_empty_if_read;

  // Gray指针跨域同步
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)reg  [   AddrWidth:0] wr_consume_ptr_gray_sync_d1;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)reg  [   AddrWidth:0] wr_consume_ptr_gray_sync_d2;
  wire [   AddrWidth:0] wr_consume_ptr_bin_sync;

  // 读域底层FIFO接口
  wire                  rd_block_empty;
  wire                  rd_block_rd_en;
  wire [     Width-1:0] rd_block_data;
  wire [CountWidth-1:0] rd_block_count;
  reg                   rd_block_rd_en_d1;
  reg                   rd_block_valid;

  // 读域skid接口
  wire                  rd_skid_sready;
  wire                  rd_dout_valid;
  wire                  rd_skid_s_handshake;

  // 生成循环
  genvar g_gray;

  // 消费指针同步
  always @(posedge wr_clk or posedge wr_arst) begin
    if (wr_arst) begin
      wr_consume_ptr_gray_sync_d1 <= 'd0;
      wr_consume_ptr_gray_sync_d2 <= 'd0;
    end else begin
      wr_consume_ptr_gray_sync_d1 <= rd_consume_ptr_gray;
      wr_consume_ptr_gray_sync_d2 <= wr_consume_ptr_gray_sync_d1;
    end
  end
  //// 格雷码转二进制
  assign wr_consume_ptr_bin_sync[AddrWidth] = wr_consume_ptr_gray_sync_d2[AddrWidth];
  for (g_gray = 0; g_gray < AddrWidth; g_gray = g_gray + 1) begin : gen_gray_decode
    assign wr_consume_ptr_bin_sync[g_gray] = ^wr_consume_ptr_gray_sync_d2[AddrWidth:g_gray];
  end

  // 写入
  assign wr_accept        = !wr_arst && wr_en && !full;
  assign wr_ptr_bin_next  = wr_accept ? wr_ptr_bin + 1'b1 : wr_ptr_bin;
  assign wr_ptr_gray_next = (wr_ptr_bin_next >> 1) ^ wr_ptr_bin_next;
  always @(posedge wr_clk or posedge wr_arst) begin
    if (wr_arst) begin
      wr_ptr_bin <= 'd0;
    end else begin
      wr_ptr_bin <= wr_ptr_bin_next;
    end
  end

  // 读取
  //// 实际消费指针
  assign rd_accept                   = !rd_arst && rd_en && !empty;
  assign rd_consume_ptr_bin_plus_one = rd_consume_ptr_bin + 1'b1;
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) begin
      rd_consume_ptr_bin  <= 'd0;
      rd_consume_ptr_gray <= 'd0;
    end else if (rd_accept) begin
      rd_consume_ptr_bin  <= rd_consume_ptr_bin_plus_one;
      rd_consume_ptr_gray <= (rd_consume_ptr_bin_plus_one >> 1) ^ rd_consume_ptr_bin_plus_one;
    end
  end
  //// 底层FIFO预取
  assign rd_block_rd_en = !rd_arst && !rd_block_empty && ((rd_prefetch_count < 2'd3) || rd_accept);
  //// 预取计数器
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) begin
      rd_prefetch_count <= 2'd0;
    end else begin
      case ({
        rd_block_rd_en, rd_accept
      })
        2'b10: begin
          rd_prefetch_count <= rd_prefetch_count + 1'b1;
        end
        2'b01: begin
          rd_prefetch_count <= rd_prefetch_count - 1'b1;
        end
        default: begin
          rd_prefetch_count <= rd_prefetch_count;
        end
      endcase
    end
  end
  //// 底层读取返回
  assign rd_skid_s_handshake = rd_skid_sready && rd_block_valid;
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) rd_block_rd_en_d1 <= 1'b0;
    else rd_block_rd_en_d1 <= rd_block_rd_en;
  end
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) begin
      rd_block_valid <= 1'b0;
    end else if (rd_block_rd_en_d1) begin
      rd_block_valid <= 1'b1;
    end else if (rd_skid_s_handshake) begin
      rd_block_valid <= 1'b0;
    end
  end
  //// skid
  skid_buffer #(
      .DataWidth(Width)
  ) skid_buffer_inst (
      .clk   (rd_clk),
      .rst   (rd_arst),
      .sready(rd_skid_sready),
      .sdata (rd_block_data),
      .svalid(rd_block_valid),
      .mready(rd_accept),
      .mdata (dout),
      .mvalid(rd_dout_valid)
  );

  // 占用计数与满空标志
  //// 写域
  assign wr_full_next = wr_ptr_gray_next == (wr_consume_ptr_gray_sync_d2 ^ GrayTopTwoBitsMask);
  assign wr_data_count_next = wr_ptr_bin_next - wr_consume_ptr_bin_sync;
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
  //// 读域
  assign rd_data_count_if_no_read = rd_block_count + rd_prefetch_count;
  assign rd_data_count_if_read    = rd_data_count_if_no_read - 1'b1;
  assign rd_prog_empty_if_no_read = rd_data_count_if_no_read <= ProgEmptyThresh;
  assign rd_prog_empty_if_read    = rd_data_count_if_read <= ProgEmptyThresh;
  assign rd_data_count_next       = rd_accept ? rd_data_count_if_read : rd_data_count_if_no_read;
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) begin
      rd_data_count     <= 'd0;
      rd_prog_empty_reg <= {CountWidth{1'b0}} <= ProgEmptyThresh;
    end else begin
      rd_data_count     <= rd_data_count_next;
      rd_prog_empty_reg <= rd_accept ? rd_prog_empty_if_read : rd_prog_empty_if_no_read;
    end
  end
  assign full               = wr_block_full || wr_full_reg;
  assign empty              = !rd_dout_valid;
  assign stat_wr_data_count = wr_data_count;
  assign stat_rd_data_count = rd_data_count;
  assign prog_full          = wr_prog_full_reg;
  assign prog_empty         = rd_prog_empty_reg;

  // 底层FIFO
  fifo_async #(
      .Depth          (Depth),
      .Width          (Width),
      .MemoryType     ("block"),
      .ProgEmptyThresh(0),
      .ProgFullThresh (0)
  ) fifo_async_block (
      .wr_clk            (wr_clk),
      .rd_clk            (rd_clk),
      .wr_arst           (wr_arst),
      .rd_arst           (rd_arst),
      .wr_en             (wr_accept),
      .din               (din),
      .rd_en             (rd_block_rd_en),
      .dout              (rd_block_data),
      .full              (wr_block_full),
      .empty             (rd_block_empty),
      .prog_full         (),
      .prog_empty        (),
      .stat_wr_data_count(),
      .stat_rd_data_count(rd_block_count)
  );
endmodule
`resetall
