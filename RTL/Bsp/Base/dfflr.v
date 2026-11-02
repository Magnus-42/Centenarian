`resetall
`default_nettype none
`timescale 1ns / 100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : dffre.v
// Module Name : dff with synchronous reset and clock enable
// Author      : LiXintao
// Date        : 2026-10-30
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 带复位置0的D触发器
//
// ============================================================================

module example#(
  parameter  WIDTH= 32
)(
  input  wire                                          clk             ,
  input  wire          [             WIDTH-1:0]        a               ,
  input  wire          [             WIDTH-1:0]        b               ,
  output wire          [             WIDTH-1:0]        c                
);
  wire [WIDTH-1:0] c_r; // _r结尾标识来自寄存器的输出

  wire [WIDTH-1:0] a_add_b = a + b;
  dffse #(WIDTH) dscratch_dfflr (clk,1'b0, a_add_b, c_r);

  assign c = c_r;
endmodule
`resetall
