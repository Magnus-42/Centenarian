`resetall
`default_nettype none
`timescale 1ns / 100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : dffce.v
// Module Name : dff with asynchronous reset
// Author      : LiXintao
// Date        : 2026-10-30
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 异步复位寄存器
//
// ============================================================================
module dffce#(
  parameter  WIDTH= 1
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,
  input  wire          [             WIDTH-1:0]        d               ,
  output wire          [             WIDTH-1:0]        q                
);
  reg                  [             WIDTH-1:0]        q_r              ;

  always @(posedge clk or posedge rst) begin
    if(rst) begin
      q_r <= {WIDTH{1'b0}};
    end
    else begin
      q_r <= d;
    end
  end

  assign q = q_r; 
endmodule
`resetall
