// -----------------------------------------------------------------------------
// File Name   : sp_bram.v
// Module Name : sp_bram
// Author      : LiXintao
// Created     : 2026-08-29
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 单时钟单端口块RAM，支持可选输出寄存器、读写模式和初始化。
// Note        : DoReg=0时读延迟为1拍，DoReg=1时读延迟为2拍
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module sp_bram #(
    parameter integer DataWidth = 36,
    parameter integer Depth = 1024,
    localparam integer AddrWidth = Depth == 1 ? 1 : $clog2(Depth),
    parameter integer DoReg = 1,
    parameter integer InitEn = 1,
    parameter integer InitUseFile = 0,
    parameter InitFileName = "init_data.txt",
    parameter WriteMode = "WRITE_FIRST"  // WRITE_FIRST / READ_FIRST / NO_CHANGE
) (
    input wire clk,
    input wire rst,

    input  wire                 we,
    input  wire [AddrWidth-1:0] addr,
    input  wire [DataWidth-1:0] din,
    input  wire                 re,
    output wire [DataWidth-1:0] dout
);

  // 参数范围检查
  initial begin
    if (DataWidth < 1 || Depth < 1) begin
      $display("错误：sp_bram：不支持的参数配置。");
      $finish;
    end
    if ((InitEn != 0 && InitEn != 1) || (InitUseFile != 0 && InitUseFile != 1)) begin
      $display("错误：sp_bram：不支持的参数配置。");
      $finish;
    end
    if ((DoReg != 0 && DoReg != 1)) begin
      $display("错误：sp_bram：不支持的参数配置。");
      $finish;
    end
    if ((WriteMode != "WRITE_FIRST" && WriteMode != "READ_FIRST" && WriteMode != "NO_CHANGE")) begin
      $display("错误：sp_bram：不支持的参数配置。");
      $finish;
    end
  end

  // 存储体
  (* ram_style = "block" *) reg [DataWidth-1:0] bram[0:Depth-1];

  // 端口访问控制
  wire en;

  // 同步读出
  reg [DataWidth-1:0] dout_bram;

  // 存储器初始化
  if (InitEn != 0) begin : gen_init
    if (InitUseFile != 0) begin : gen_init_file
      initial begin
        // 加载十六进制文件，文件需加入 Vivado 工程的仿真或综合源
        $readmemh(InitFileName, bram);
      end
    end else begin : gen_init_clear
      integer init_index;
      initial begin
        for (init_index = 0; init_index < Depth; init_index = init_index + 1) begin
          bram[init_index] = 'd0;
        end
      end
    end
  end

  // 端口使能
  assign en = we | re;

  // 单端口读写控制
  // 写入时的读出行为由WriteMode决定
  if (WriteMode == "WRITE_FIRST") begin : gen_write_first
    always @(posedge clk) begin
      if (en) begin
        if (we) begin
          bram[addr] <= din;
          dout_bram  <= din;
        end else begin
          dout_bram <= bram[addr];
        end
      end
    end
  end else if (WriteMode == "READ_FIRST") begin : gen_read_first
    always @(posedge clk) begin
      if (en) begin
        if (we) begin
          bram[addr] <= din;
        end
        dout_bram <= bram[addr];
      end
    end
  end else begin : gen_no_change
    always @(posedge clk) begin
      if (en) begin
        if (we) begin
          bram[addr] <= din;
        end else begin
          dout_bram <= bram[addr];
        end
      end
    end
  end

  // 输出寄存器选择
  if (DoReg != 0) begin : gen_do_reg
    reg en_d1;
    reg [DataWidth-1:0] dout_reg;

    always @(posedge clk) begin
      if (rst) en_d1 <= 1'b0;
      else en_d1 <= en;
    end
    always @(posedge clk) begin
      if (rst) dout_reg <= 'd0;
      else if (en_d1) dout_reg <= dout_bram;
    end
    assign dout = dout_reg;
  end else begin : gen_do_direct
    assign dout = dout_bram;
  end

endmodule
`resetall
