`resetall
`default_nettype none
`timescale 1ns/100ps
`include "cfg_map.vh"

// Language: Verilog 2001
// ============================================================================
// File Name   : cfg_set.v
// Module Name : cfg_set
// Author      : LiXintao
// Date        : 2026-10-23
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : TLV 命令设置，并返回设置结果
//
// 返回帧格式：
// +------+-------+-------+-------+-------+---------+
// |      | OP    | SEQ   | TAG1  | LEN1  | PADING  |
// |------+-------+-------+-------+-------+---------+
// | 大小 | 1字节 | 1字节 | 2字节 | 1字节 | 17字节  |
// +------+-------+-------+-------+-------+---------+
// ============================================================================

module cfg_set #(
  parameter CALLBACK_MSG = 1, // 控制是否返回写入的消息
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

  // 写入
  output wire                                           wr_en           ,
  output wire           [                   7:0]        wr_item         ,
  output wire           [                   3:0]        wr_set          ,
  output wire           [                   3:0]        wr_port         ,
  output wire           [     MAX_VALUE_BIT-1:0]        wr_val          ,

  // axis 返回消息
  output wire          [                 511:0]        callback_axis_mdata  ,
  output wire          [                  63:0]        callback_axis_mkeep  ,
  output wire                                          callback_axis_mlast  ,
  output wire                                          callback_axis_mvalid ,
  input  wire                                          callback_axis_mready ,
  output wire          [     CMD_USR_WIDTH-1:0]        callback_axis_musr
);
  localparam STATUS_WIDTH = 8;
  localparam [7:0] OP_SET_RSP =  `CFG_OP_SET_RSP;

  wire rec_handshake = rec_valid && rec_ready;

  generate
    if (CALLBACK_MSG) begin : gen_callback_msg
      reg          [                 511:0]        callback_axis_mdata_reg;
      reg          [                  63:0]        callback_axis_mkeep_reg;
      reg                                          callback_axis_mlast_reg;
      reg                                          callback_axis_mvalid_reg;
      reg          [     CMD_USR_WIDTH-1:0]        callback_axis_musr_reg;

      assign rec_ready = !callback_axis_mvalid_reg || callback_axis_mready;
      wire m_handshake = callback_axis_mready && callback_axis_mvalid;

      // callback_axis_mvalid_reg
      always @(posedge clk) begin
        if (rst) begin
          callback_axis_mvalid_reg <= 1'b0;
        end
        else begin
          if (rec_handshake) begin
            callback_axis_mvalid_reg <= 1'b1;
          end
          else if (m_handshake) begin
            callback_axis_mvalid_reg <= 1'b0;
          end
        end
      end

      always @(posedge clk) begin
        if (rec_handshake) begin
          callback_axis_mdata_reg <= {464'd0,rec_len,rec_set,rec_port,rec_item,{STATUS_WIDTH{1'b0}},rec_seq,OP_SET_RSP};
          callback_axis_mkeep_reg <= {{58{1'b0}},{6{1'b1}}};
          callback_axis_mlast_reg <= 1'b1;
          callback_axis_musr_reg  <= rec_usr;
        end
      end
      assign callback_axis_mdata  = callback_axis_mdata_reg;
      assign callback_axis_mkeep  = callback_axis_mkeep_reg;
      assign callback_axis_mlast  = callback_axis_mlast_reg;
      assign callback_axis_mvalid = callback_axis_mvalid_reg;
      assign callback_axis_musr   = callback_axis_musr_reg;
    end
    else begin : gen_default
      assign rec_ready            = 1'b1;
      assign callback_axis_mdata  = 'd0;
      assign callback_axis_mkeep  = 'd0;
      assign callback_axis_mlast  = 'd0;
      assign callback_axis_mvalid = 'd0;
      assign callback_axis_musr   = 'd0;
    end
  endgenerate

  reg                                           wr_en_reg;
  reg           [                   7:0]        wr_item_reg;
  reg           [                   3:0]        wr_set_reg;
  reg           [                   3:0]        wr_port_reg;
  reg           [     MAX_VALUE_BIT-1:0]        wr_val_reg;

  // wr_item_reg wr_port_reg wr_val_reg
  always @(posedge clk) begin
    if (rec_handshake) begin
      wr_item_reg <= rec_item;
      wr_set_reg <= rec_set;
      wr_port_reg <= rec_port;
      wr_val_reg <= rec_val;
    end
  end 

  // wr_en_reg
  always @(posedge clk) begin
    if (rst) begin
      wr_en_reg <= 'd0;
    end
    else if (rec_handshake) begin
      wr_en_reg <= 'd1;
    end
    else begin
      wr_en_reg <= 'd0;
    end
  end                                

  assign wr_en = wr_en_reg;
  assign wr_item = wr_item_reg;
  assign wr_set = wr_set_reg;
  assign wr_port = wr_port_reg;
  assign wr_val  = wr_val_reg;
endmodule
`resetall
