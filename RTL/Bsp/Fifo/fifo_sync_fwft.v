// -----------------------------------------------------------------------------
// File Name   : fifo_sync_fwft.v
// Module Name : fifo_sync_fwft
// Author      : LiXintao
// Created     : 2026-11-09
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 基于Block存储的同步首字直通FIFO。
// Note        : Depth包含3项预取缓存，必须不小于5。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module fifo_sync_fwft #(
    parameter integer Depth = 5,
    parameter integer Width = 3
) (
    input wire clk,
    input wire rst,

    input  wire             wr_en,
    input  wire [Width-1:0] din,
    input  wire             rd_en,
    output wire [Width-1:0] dout,
    output wire             full,
    output wire             empty
);

  // 底层block FIFO保存数据，读侧按三项额度提前预取。
  // 返回有效位与skid缓存对齐，队首可用时直接呈现。

  // 参数范围检查
  initial begin
    if (Depth < 5 || Width < 1) begin
      $display("错误：fifo_sync_fwft：Depth必须不小于5，Width必须不小于1");
      $finish;
    end
  end

  // 底层block FIFO接口
  wire             block_fifo_rd_en;
  reg              block_fifo_rd_en_d1;
  wire [Width-1:0] block_fifo_dout;
  wire             block_fifo_full;
  wire             block_fifo_empty;
  reg              block_fifo_valid;

  // 读侧skid接口
  wire             skid_sready;
  wire             dout_valid;
  wire             skid_s_handshake;

  // 预取与消费控制
  reg  [      1:0] prefetch_count;
  wire             rd_accept;

  // 预取与消费控制
  assign rd_accept        = rd_en && !empty && !rst;

  assign skid_s_handshake = skid_sready && block_fifo_valid;

  assign block_fifo_rd_en = !block_fifo_empty && ((prefetch_count < 2'd3) || rd_accept);

  // 满空标志
  assign full             = block_fifo_full;
  assign empty            = !dout_valid;

  // 读取
  //// 预取计数器
  always @(posedge clk) begin
    if (rst) begin
      prefetch_count <= 2'd0;
    end else begin
      case ({
        block_fifo_rd_en, rd_accept
      })
        2'b10: begin
          prefetch_count <= prefetch_count + 1'b1;
        end
        2'b01: begin
          prefetch_count <= prefetch_count - 1'b1;
        end
        default: begin
          prefetch_count <= prefetch_count;
        end
      endcase
    end
  end
  //// 底层读取返回
  always @(posedge clk) begin
    if (rst) block_fifo_rd_en_d1 <= 'd0;
    else block_fifo_rd_en_d1 <= block_fifo_rd_en;
  end
  always @(posedge clk) begin
    if (rst) begin
      block_fifo_valid <= 'd0;
    end else if (block_fifo_rd_en_d1) begin
      block_fifo_valid <= 1'b1;
    end else if (skid_s_handshake) begin
      block_fifo_valid <= 1'b0;
    end
  end
  //// skid
  skid_buffer #(
      .DataWidth(Width)
  ) skid_buffer_inst (
      .clk   (clk),
      .rst   (rst),
      .sready(skid_sready),
      .sdata (block_fifo_dout),
      .svalid(block_fifo_valid),
      .mready(rd_accept),
      .mdata (dout),
      .mvalid(dout_valid)
  );
  //// 底层FIFO
  fifo_sync #(
      .Depth          (Depth - 3),
      .Width          (Width),
      .MemoryType     ("block"),
      .ProgEmptyThresh(0),
      .ProgFullThresh (0)
  ) fifo_sync_block (
      .clk            (clk),
      .rst            (rst),
      .wr_en          (wr_en),
      .din            (din),
      .rd_en          (block_fifo_rd_en),
      .dout           (block_fifo_dout),
      .full           (block_fifo_full),
      .empty          (block_fifo_empty),
      .prog_full      (),
      .prog_empty     (),
      .stat_data_count()
  );

endmodule
`resetall
