// -----------------------------------------------------------------------------
// File Name   : sdp_bram.v
// Module Name : sdp_bram
// Author      : LiXintao
// Created     : 2026-08-29
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 单时钟简单双口块RAM，支持可选输出寄存器、旁路和初始化
// Note        : A端口写入，B端口读取
//               DoReg=0时读延迟为1拍，DoReg=1时读延迟为2拍；
//               BypassEn=1时，同地址读写返回新写入的数据。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module sdp_bram #(
    parameter integer DataWidth = 36,
    parameter integer Depth = 1024,
    localparam integer AddrWidth = Depth == 1 ? 1 : $clog2(Depth),
    parameter integer DoReg = 1,
    parameter integer InitEn = 1,
    parameter integer InitUseFile = 0,
    parameter InitFileName = "init_data.txt",
    parameter integer BypassEn = 1  // 0: 关闭旁路, 1: 同地址读写时输出新值
) (
    input wire clk,
    input wire rst,

    // A 写端口
    input wire                 a_we,
    input wire [AddrWidth-1:0] a_addr,
    input wire [DataWidth-1:0] a_din,

    // B 读端口
    input  wire                 b_re,
    input  wire [AddrWidth-1:0] b_addr,
    output wire [DataWidth-1:0] b_dout
);

  // 参数范围检查
  initial begin
    if (DataWidth < 1 || Depth < 1) begin
      $display("错误：sdp_bram：不支持的参数配置。");
      $finish;
    end
    if ((InitEn != 0 && InitEn != 1) || (InitUseFile != 0 && InitUseFile != 1)) begin
      $display("错误：sdp_bram：不支持的参数配置。");
      $finish;
    end
    if ((DoReg != 0 && DoReg != 1)) begin
      $display("错误：sdp_bram：不支持的参数配置。");
      $finish;
    end
    if ((BypassEn != 0 && BypassEn != 1)) begin
      $display("错误：sdp_bram：不支持的参数配置。");
      $finish;
    end
  end

  // 存储体
  (* ram_style = "block" *)reg [DataWidth-1:0] bram          [0:Depth-1];

  // B端口读出与旁路
  reg                 b_re_d1;
  reg [DataWidth-1:0] b_dout_bram;
  reg [DataWidth-1:0] b_dout_bypass;
  reg                 b_bypass_sel;

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

  // A 端口写控制
  always @(posedge clk) begin
    if (a_we) bram[a_addr] <= a_din;
  end

  // 同地址读写旁路
  always @(posedge clk) begin
    if (rst) begin
      b_dout_bypass <= 'd0;
      b_bypass_sel  <= 1'b0;
    end else if (a_we && b_re && (a_addr == b_addr)) begin
      b_dout_bypass <= a_din;
      b_bypass_sel  <= (BypassEn != 0);
    end else if (b_re) begin
      b_bypass_sel <= 1'b0;
    end
  end

  // B 端口读控制
  always @(posedge clk) begin
    if (b_re) b_dout_bram <= bram[b_addr];
  end

  // 输出寄存器选择
  if (DoReg != 0) begin : gen_do_reg
    reg [DataWidth-1:0] b_dout_reg;
    reg [DataWidth-1:0] b_dout_bypass_d1;
    reg b_bypass_sel_d1;

    always @(posedge clk) begin
      if (rst) begin
        b_re_d1          <= 1'b0;
        b_dout_bypass_d1 <= 'd0;
        b_bypass_sel_d1  <= 1'b0;
      end else begin
        b_re_d1 <= b_re;
        if (b_re_d1) begin
          b_dout_bypass_d1 <= b_dout_bypass;
          b_bypass_sel_d1  <= b_bypass_sel;
        end
      end
    end
    always @(posedge clk) begin
      if (rst) b_dout_reg <= 'd0;
      else if (b_re_d1) b_dout_reg <= b_dout_bram;
    end
    assign b_dout = b_bypass_sel_d1 ? b_dout_bypass_d1 : b_dout_reg;
  end else begin : gen_do_direct
    assign b_dout = b_bypass_sel ? b_dout_bypass : b_dout_bram;
  end

endmodule
`resetall
