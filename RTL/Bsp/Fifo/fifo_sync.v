// -----------------------------------------------------------------------------
// File Name   : fifo_sync.v
// Module Name : fifo_sync
// Author      : LiXintao
// Created     : 2026-11-06
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 同步FIFO，支持任意不小于2的深度及两种存储类型。
// Note        : distributed模式组合输出当前队首，empty=0时有效；
//               block模式在有效读请求后延迟2拍输出数据。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module fifo_sync #(
    parameter integer Depth = 8,
    parameter integer Width = 8,
    parameter MemoryType = "distributed",  // distributed/block
    parameter integer ProgEmptyThresh = Depth / 4,
    parameter integer ProgFullThresh = Depth / 2,
    localparam integer CountWidth = $clog2(Depth) + 1
) (
    input wire clk,
    input wire rst,

    input  wire                  wr_en,
    input  wire [     Width-1:0] din,
    input  wire                  rd_en,
    output wire [     Width-1:0] dout,
    output wire                  full,
    output wire                  empty,
    output wire                  prog_full,
    output wire                  prog_empty,
    output wire [CountWidth-1:0] stat_data_count
);

  // 读写请求分别受满空和复位门控，指针按Depth回绕。
  // distributed组合输出队首，block通过两级寄存输出读数据。

  // 参数范围检查
  initial begin
    if (Depth < 2 || Width < 1) begin
      $display("错误：fifo_sync：Depth必须不小于2，Width必须不小于1");
      $finish;
    end
    if ((MemoryType != "distributed" && MemoryType != "block")) begin
      $display("错误：fifo_sync：MemoryType仅支持distributed或block");
      $finish;
    end
    if (ProgEmptyThresh < 0 || ProgEmptyThresh > Depth || ProgFullThresh < 0 ||
        ProgFullThresh > Depth) begin
      $display("错误：fifo_sync：阈值必须位于0到Depth范围内");
      $finish;
    end
  end

  // 内部常量
  localparam integer AddrWidth = $clog2(Depth);

  // 存储体
  (* ram_style = MemoryType *)reg  [     Width-1:0] mem            [0:Depth-1];

  // 写入控制
  reg  [ AddrWidth-1:0] wr_ptr;
  wire                  wr_accept;
  wire                  wr_ptr_wrap;

  // 读取控制
  reg  [ AddrWidth-1:0] rd_ptr;
  wire                  rd_accept;
  wire                  rd_ptr_wrap;

  // 占用与满空状态
  reg  [CountWidth-1:0] data_count;
  reg                   full_reg;
  reg                   empty_reg;
  reg                   prog_full_reg;
  reg                   prog_empty_reg;

  // 写入
  assign wr_accept   = wr_en && !full && !rst;
  assign wr_ptr_wrap = wr_ptr == (Depth - 1);
  always @(posedge clk) begin
    if (rst) begin
      wr_ptr <= 'd0;
    end else if (wr_accept) begin
      if (wr_ptr_wrap) wr_ptr <= 'd0;
      else wr_ptr <= wr_ptr + 1'b1;
    end
  end
  always @(posedge clk) begin
    if (wr_accept) mem[wr_ptr] <= din;
  end

  // 读取
  assign rd_accept   = rd_en && !empty && !rst;
  assign rd_ptr_wrap = rd_ptr == (Depth - 1);
  always @(posedge clk) begin
    if (rst) begin
      rd_ptr <= 'd0;
    end else if (rd_accept) begin
      if (rd_ptr_wrap) rd_ptr <= 'd0;
      else rd_ptr <= rd_ptr + 1'b1;
    end
  end
  if (MemoryType == "distributed") begin : gen_distributed
    assign dout = mem[rd_ptr];
  end else begin : gen_block
    reg [Width-1:0] p1_dout, p2_dout;
    reg rd_accept_d1;
    always @(posedge clk) begin
      if (rst) begin
        rd_accept_d1 <= 'd0;
      end else begin
        rd_accept_d1 <= rd_accept;
      end
    end
    always @(posedge clk) begin
      p1_dout <= mem[rd_ptr];
      if (rst) p2_dout <= 'd0;
      else if (rd_accept_d1) p2_dout <= p1_dout;
    end
    assign dout = p2_dout;
  end

  // 数据计数与状态更新
  always @(posedge clk) begin
    if (rst) begin
      data_count <= 'd0;
    end else begin
      case ({
        wr_accept, rd_accept
      })
        2'b10: begin
          data_count <= data_count + 1'b1;
        end
        2'b01: begin
          data_count <= data_count - 1'b1;
        end
        default: begin
          data_count <= data_count;
        end
      endcase
    end
  end
  always @(posedge clk) begin
    if (rst) begin
      full_reg       <= 1'b0;
      empty_reg      <= 1'b1;
      prog_full_reg  <= {CountWidth{1'b0}} >= ProgFullThresh;
      prog_empty_reg <= {CountWidth{1'b0}} <= ProgEmptyThresh;
    end else begin
      case ({
        wr_accept, rd_accept
      })
        2'b10: begin
          full_reg       <= data_count == (Depth - 1);
          empty_reg      <= 1'b0;
          prog_full_reg  <= prog_full_reg || (data_count == (ProgFullThresh - 1));
          prog_empty_reg <= data_count < ProgEmptyThresh;
        end
        2'b01: begin
          full_reg       <= 1'b0;
          empty_reg      <= data_count == 1;
          prog_full_reg  <= data_count > ProgFullThresh;
          prog_empty_reg <= prog_empty_reg || (data_count == (ProgEmptyThresh + 1));
        end
        default: begin
          full_reg       <= full_reg;
          empty_reg      <= empty_reg;
          prog_full_reg  <= prog_full_reg;
          prog_empty_reg <= prog_empty_reg;
        end
      endcase
    end
  end
  assign full            = full_reg;
  assign empty           = empty_reg;
  assign prog_empty      = prog_empty_reg;
  assign prog_full       = prog_full_reg;
  assign stat_data_count = data_count;

endmodule
`resetall
