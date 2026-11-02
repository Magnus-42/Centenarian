`resetall
`default_nettype none
`timescale 1ns / 100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : dffre.v
// Module Name : dff with synchronous reset
// Author      : LiXintao
// Date        : 2026-10-30
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 同步复位寄存器
//
// ============================================================================
module dffre#(
  parameter  WIDTH= 1 
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,
  input  wire          [             WIDTH-1:0]        d               ,
  output wire          [             WIDTH-1:0]        q                
);
  reg                  [             WIDTH-1:0]        q_r              ;

  always @(posedge clk) begin
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
