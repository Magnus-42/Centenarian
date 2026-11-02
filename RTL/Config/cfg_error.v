`resetall
`default_nettype none
`timescale 1ns/100ps
`include "cfg_map.vh"

// Language: Verilog 2001
// ============================================================================
// File Name   : cfg_error.v
// Module Name : cfg_error
// Author      : LiXintao
// Date        : 2026-10-26
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 错误配置组帧
//
// ============================================================================

module cfg_error#(
  parameter  MAX_VALUE_BYTES= 16,
  localparam MAX_VALUE_BIT= MAX_VALUE_BYTES*8,
  parameter  CMD_USR_WIDTH= 96
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  output wire                                          err_ready       ,
  input  wire                                          err_valid       ,
  input  wire          [                   7:0]        err_op          ,
  input  wire          [                   7:0]        err_seq         ,
  input  wire          [                   7:0]        err_item        ,
  input  wire          [                   3:0]        err_set         ,
  input  wire          [                   3:0]        err_port        ,
  input  wire          [                   7:0]        err_len         ,
  input  wire          [     MAX_VALUE_BIT-1:0]        err_val         ,
  input  wire          [     CMD_USR_WIDTH-1:0]        err_usr         ,
  input  wire          [                   7:0]        err_status      ,
  
  // axis 返回消息
  output wire          [                 511:0]        err_axis_mdata  ,
  output wire          [                  63:0]        err_axis_mkeep  ,
  output wire                                          err_axis_mlast  ,
  output wire                                          err_axis_mvalid ,
  input  wire                                          err_axis_mready ,
  output wire          [     CMD_USR_WIDTH-1:0]        err_axis_musr   
);
  localparam [7:0] OP_ERR_RSP =  `CFG_OP_ERR_RSP;

  reg                  [                 511:0]        err_axis_mdata_reg;
  reg                  [                  63:0]        err_axis_mkeep_reg;
  reg                                                  err_axis_mlast_reg;
  reg                                                  err_axis_mvalid_reg;
  reg                  [     CMD_USR_WIDTH-1:0]        err_axis_musr_reg;

  wire                                                 err_handshake     = err_valid && err_ready            ;
  wire                                                 m_handshake       = err_axis_mvalid && err_axis_mready;
  assign  err_ready        = !err_axis_mvalid_reg || err_axis_mready;

  // valid
  always @(posedge clk) begin
    if(rst) begin
      err_axis_mvalid_reg  <= 'd0;
    end
    else begin
      if(err_handshake) begin
        err_axis_mvalid_reg  <= 1'b1;
      end
      else if(m_handshake) begin
        err_axis_mvalid_reg  <= 1'b0;
      end
    end
  end

  // data
  always @(posedge clk) begin
    if(err_handshake) begin
      err_axis_mdata_reg  <= {464'd0, err_len, err_set,err_port, err_item, err_status, err_seq, OP_ERR_RSP};
      err_axis_mkeep_reg  <= {{58{1'b0}}, 6'b111111};
      err_axis_mlast_reg  <= 1'b1;
      err_axis_musr_reg   <= err_usr;
    end
  end

  assign  err_axis_mdata   = err_axis_mdata_reg;
  assign  err_axis_mkeep   = err_axis_mkeep_reg;
  assign  err_axis_mlast   = err_axis_mlast_reg;
  assign  err_axis_mvalid  = err_axis_mvalid_reg;
  assign  err_axis_musr    = err_axis_musr_reg;
endmodule
