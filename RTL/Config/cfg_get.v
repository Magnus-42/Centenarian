`resetall
`default_nettype none
`timescale 1ns/100ps
`include "cfg_map.vh"

// Language: Verilog 2001
// ============================================================================
// File Name   : cfg_get.v
// Module Name : cfg_get
// Author      : LiXintao
// Date        : 2026-10-23
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : TLV GET命令，返回设置结果
//               1. 仅支持单拍返回，即 MAX_VALUE_BYTES<= 58
//               2. 仅支持单条命令返回
//
// 可读取表项：
// 返回帧格式：
// ============================================================================

module cfg_get#(
  parameter  MAX_VALUE_BYTES= 16,
  localparam MAX_VALUE_BIT= MAX_VALUE_BYTES*8,
  parameter  CMD_USR_WIDTH= 96
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // TLV命令
  input  wire                                          rec_valid       ,
  output wire                                          rec_ready       ,
  input  wire          [                   7:0]        rec_op          ,
  input  wire          [                   7:0]        rec_seq         ,
  input  wire          [                   7:0]        rec_item        ,
  input  wire          [                   3:0]        rec_set         ,
  input  wire          [                   3:0]        rec_port        ,
  input  wire          [                   7:0]        rec_len         ,
  input  wire          [     MAX_VALUE_BIT-1:0]        rec_val         ,
  input  wire          [     CMD_USR_WIDTH-1:0]        rec_usr         ,

  // 读回 读取时延为1 
  output wire                                          rd_req          ,
  output wire          [                   7:0]        rd_item         ,
  output wire          [                   3:0]        rd_set          ,
  output wire          [                   3:0]        rd_port         ,
  input  wire          [                   7:0]        rd_len          ,
  input  wire          [     MAX_VALUE_BIT-1:0]        rd_val          ,

  // axis 返回消息
  output wire          [                 511:0]        rd_axis_mdata   ,
  output wire          [                  63:0]        rd_axis_mkeep   ,
  output wire                                          rd_axis_mlast   ,
  output wire                                          rd_axis_mvalid  ,
  input  wire                                          rd_axis_mready  ,
  output wire          [     CMD_USR_WIDTH-1:0]        rd_axis_musr    
);
  localparam STATUS_WIDTH = 8;
  localparam TLV_LEN = MAX_VALUE_BIT + 40;
  localparam AXIS_PADING_LEN = 512 - TLV_LEN - STATUS_WIDTH;
  localparam [63:0] AXIS_PADING_KEEP = {{(AXIS_PADING_LEN/8){1'b0}},{(64- AXIS_PADING_LEN/8){1'b1}}};
  localparam [7:0] OP_GET_RSP =  `CFG_OP_GET_RSP;

  reg                                                  rd_req_s1        ;
  reg                  [                   7:0]        rec_op_s1        ;
  reg                  [                   7:0]        rec_seq_s1       ;
  reg                  [                   7:0]        rd_item_s1       ;
  reg                  [                   3:0]        rd_set_s1        ;
  reg                  [                   3:0]        rd_port_s1       ;
  reg                  [     CMD_USR_WIDTH-1:0]        rec_usr_s1       ;
  
  reg                                                  rd_req_s2        ;
  reg                  [                   7:0]        rec_op_s2        ;
  reg                  [                   7:0]        rec_seq_s2       ;
  reg                  [                   7:0]        rd_item_s2       ;
  reg                  [                   3:0]        rd_set_s2        ;
  reg                  [                   3:0]        rd_port_s2       ;
  reg                  [     CMD_USR_WIDTH-1:0]        rec_usr_s2       ;

  reg          [                 511:0]        rd_axis_mdata_reg;
  reg          [                  63:0]        rd_axis_mkeep_reg;
  reg                                          rd_axis_mlast_reg;
  reg                                          rd_axis_mvalid_reg;
  reg          [     CMD_USR_WIDTH-1:0]        rd_axis_musr_reg;

  wire                                                 rec_handshake     = rec_valid && rec_ready;
  wire m_handshake = rd_axis_mvalid && rd_axis_mready;
  wire s1_ready = !rd_axis_mvalid_reg || rd_axis_mready;
  assign rec_ready = !rd_req_s1 && !rd_req_s2 && s1_ready;

  // rd_req_s1
  always @(posedge clk) begin
    if (rst) begin
      rd_req_s1 <= 'd0;
    end
    else if (rec_handshake) begin
      rd_req_s1 <= 'd1;
    end
    else begin
      rd_req_s1 <= 'd0;
    end
  end

  // rec_op_s1 rec_seq_s1 rd_item_s1 rd_port_s1
  always @(posedge clk) begin
    if (rec_handshake) begin
      rec_op_s1 <= rec_op;
      rec_seq_s1 <= rec_seq;
      rd_item_s1 <= rec_item;
      rd_set_s1  <= rec_set;
      rd_port_s1 <= rec_port;
      rec_usr_s1 <= rec_usr;
    end
  end

  assign rd_req = rd_req_s1;
  assign rd_item = rd_item_s1;
  assign rd_set = rd_set_s1;
  assign rd_port = rd_port_s1;
  
  // rd_req_s2
  always @(posedge clk) begin
    if (rst) begin
      rd_req_s2 <= 'd0;
    end
    else if (rd_req_s1) begin
      rd_req_s2 <= 'd1;
    end
    else begin
      rd_req_s2 <= 'd0;
    end
  end

  // rec_op_s2 rec_seq_s1 rd_item_s2 rd_port_s2
  always @(posedge clk) begin
    if (rd_req_s1) begin
      rec_op_s2 <= rec_op_s1;
      rec_seq_s2 <= rec_seq_s1;
      rd_item_s2 <= rd_item_s1;
      rd_set_s2 <= rd_set_s1;
      rd_port_s2 <= rd_port_s1;
      rec_usr_s2 <= rec_usr_s1;
    end
  end

  // rd_axis_mvalid_reg
  always @(posedge clk) begin
    if (rst) begin
      rd_axis_mvalid_reg <= 'd0;
    end
    else if (rd_req_s2) begin
      rd_axis_mvalid_reg <= 'd1;
    end
    else if(m_handshake) begin
      rd_axis_mvalid_reg <= 'd0;
    end
  end

  // rd_axis_mdata_reg rd_axis_mkeep_reg rd_axis_mlast_reg
  always @(posedge clk) begin
    if (rd_req_s2) begin
      rd_axis_mdata_reg <= {{AXIS_PADING_LEN{1'b0}},rd_val,rd_len,rd_set_s2,rd_port_s2,rd_item_s2,{STATUS_WIDTH{1'b0}},rec_seq_s2,OP_GET_RSP};
      rd_axis_mkeep_reg <= AXIS_PADING_KEEP;
      rd_axis_mlast_reg <= 1'b1;
      rd_axis_musr_reg  <= rec_usr_s2;
    end
  end
  assign rd_axis_mdata  = rd_axis_mdata_reg;
  assign rd_axis_mkeep  = rd_axis_mkeep_reg;
  assign rd_axis_mlast  = rd_axis_mlast_reg;
  assign rd_axis_mvalid = rd_axis_mvalid_reg;
  assign rd_axis_musr   = rd_axis_musr_reg;
 
endmodule
`resetall
