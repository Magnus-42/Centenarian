`resetall
`default_nettype none
`timescale 1ns / 100ps
// Language: Verilog 2001
// ============================================================================
// File Name   : skid_buffer.v
// Module Name : skid_buffer
// Author      : LiXintao
// Date        : 2026-09-20
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : skid_buffer 阻断下游ready信号传递
// ============================================================================

module skid_buffer#(
  parameter  DATA_WIDTH= 1 
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  output wire                                          sready          ,
  input  wire          [        DATA_WIDTH-1: 0]       sdata           ,
  input  wire                                          svalid          ,

  input  wire                                          mready          ,
  output wire          [        DATA_WIDTH-1: 0]       mdata           ,
  output wire                                          mvalid           
);

  reg                  [        DATA_WIDTH-1: 0]       mdata_reg          ;
  reg                                                  mvalid_reg         ;

  reg                  [        DATA_WIDTH-1: 0]       mdata_skid         ;
  reg                                                  mvalid_skid        ;
  wire                                                 mready_skid        ;

  wire                                                 s_handshake      =svalid&&sready;
  wire                                                 m_handshake      =mready&&mvalid;
  assign  sready           = !mvalid_skid     ;

  wire                                                 reg_can_take     =!mvalid_reg||m_handshake;
  wire                                                 skid_to_reg      =mvalid_skid&&reg_can_take;// skid 顶上
  wire                                                 s_to_reg         =s_handshake&&reg_can_take;// s7 直入 reg
  wire                                                 s_to_skid        =s_handshake&&!reg_can_take;// s7 存入 skid

  always @(posedge clk) begin
    if (rst) begin
      mvalid_reg <= 'd0;
      mvalid_skid <= 'd0;
    end
    else begin
      if (s_to_reg || skid_to_reg) begin
        mvalid_reg <= 1'b1;
      end
      else if (m_handshake) begin
        mvalid_reg <= 1'b0;
      end

      if (s_to_skid) begin
        mvalid_skid <= 1'b1;
      end
      else if (skid_to_reg) begin
        mvalid_skid <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (skid_to_reg) begin
      mdata_reg <= mdata_skid;
    end
    else if (s_to_reg) begin
      mdata_reg <= sdata;
    end
  end

  always @(posedge clk) begin
    if (s_to_skid) begin
      mdata_skid <= sdata;
    end
  end

  assign  mdata            = mdata_reg        ;
  assign  mvalid           = mvalid_reg       ;

endmodule
`resetall
