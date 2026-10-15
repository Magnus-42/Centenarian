`resetall
`default_nettype none
`timescale 1ns / 100ps
// Language: Verilog 2001
// ============================================================================
// File Name   : axis_skid_buffer.v
// Module Name : axis_skid_buffer
// Author      : LiXintao
// Date        : 2026-09-20
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : axis_skid_buffer 阻断下游ready信号传递
// ============================================================================

module axis_skid_buffer#(
  parameter  AXIS_DATA_WIDTH= 1 ,
  parameter  AXIS_USER_WIDTH= 1 ,
  parameter  AXIS_ID_WIDTH= 1 ,
  parameter  AXIS_DEST_WIDTH= 1 
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  output wire                                          axis_sready     ,
  input  wire          [   AXIS_DATA_WIDTH-1: 0]       axis_sdata      ,
  input  wire          [ AXIS_DATA_WIDTH/8-1: 0]       axis_skeep      ,
  input  wire          [   AXIS_USER_WIDTH-1: 0]       axis_suser      ,
  input  wire          [     AXIS_ID_WIDTH-1: 0]       axis_sid        ,
  input  wire          [   AXIS_DEST_WIDTH-1: 0]       axis_sdest      ,
  input  wire          [ AXIS_DATA_WIDTH/8-1: 0]       axis_sstrb      ,
  input  wire                                          axis_slast      ,
  input  wire                                          axis_svalid     ,

  input  wire                                          axis_mready     ,
  output wire          [   AXIS_DATA_WIDTH-1: 0]       axis_mdata      ,
  output wire          [ AXIS_DATA_WIDTH/8-1: 0]       axis_mkeep      ,
  output wire          [   AXIS_USER_WIDTH-1: 0]       axis_muser      ,
  output wire          [     AXIS_ID_WIDTH-1: 0]       axis_mid        ,
  output wire          [   AXIS_DEST_WIDTH-1: 0]       axis_mdest      ,
  output wire          [ AXIS_DATA_WIDTH/8-1: 0]       axis_mstrb      ,
  output wire                                          axis_mlast      ,
  output wire                                          axis_mvalid      
);

  reg                  [   AXIS_DATA_WIDTH-1: 0]       axis_mdata_reg     ;
  reg                  [ AXIS_DATA_WIDTH/8-1: 0]       axis_mkeep_reg     ;
  reg                  [   AXIS_USER_WIDTH-1: 0]       axis_muser_reg     ;
  reg                  [     AXIS_ID_WIDTH-1: 0]       axis_mid_reg       ;
  reg                  [   AXIS_DEST_WIDTH-1: 0]       axis_mdest_reg     ;
  reg                  [ AXIS_DATA_WIDTH/8-1: 0]       axis_mstrb_reg     ;
  reg                                                  axis_mlast_reg     ;
  reg                                                  axis_mvalid_reg    ;

  reg                  [   AXIS_DATA_WIDTH-1: 0]       axis_mdata_skid    ;
  reg                  [ AXIS_DATA_WIDTH/8-1: 0]       axis_mkeep_skid    ;
  reg                  [   AXIS_USER_WIDTH-1: 0]       axis_muser_skid    ;
  reg                  [     AXIS_ID_WIDTH-1: 0]       axis_mid_skid      ;
  reg                  [   AXIS_DEST_WIDTH-1: 0]       axis_mdest_skid    ;
  reg                  [ AXIS_DATA_WIDTH/8-1: 0]       axis_mstrb_skid    ;
  reg                                                  axis_mlast_skid    ;
  reg                                                  axis_mvalid_skid   ;

  wire                                                 s_handshake      =axis_svalid&&axis_sready;
  wire                                                 m_handshake      =axis_mready&&axis_mvalid;
  assign  axis_sready      = !axis_mvalid_skid;

  wire                                                 reg_can_take     =!axis_mvalid_reg||m_handshake;
  wire                                                 skid_to_reg      =axis_mvalid_skid&&reg_can_take;// skid 顶上
  wire                                                 s_to_reg         =s_handshake&&reg_can_take;// s7 直入 reg
  wire                                                 s_to_skid        =s_handshake&&!reg_can_take;// s7 存入 skid

  always @(posedge clk) begin
    if (rst) begin
      axis_mvalid_reg <= 'd0;
      axis_mvalid_skid <= 'd0;
    end
    else begin
      if (s_to_reg || skid_to_reg) begin
        axis_mvalid_reg <= 1'b1;
      end
      else if (m_handshake) begin
        axis_mvalid_reg <= 1'b0;
      end

      if (s_to_skid) begin
        axis_mvalid_skid <= 1'b1;
      end
      else if (skid_to_reg) begin
        axis_mvalid_skid <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (skid_to_reg) begin
      axis_mdata_reg <= axis_mdata_skid;
      axis_mkeep_reg <= axis_mkeep_skid;
      axis_muser_reg <= axis_muser_skid;
      axis_mid_reg   <= axis_mid_skid  ;
      axis_mdest_reg <= axis_mdest_skid;
      axis_mstrb_reg <= axis_mstrb_skid;
      axis_mlast_reg <= axis_mlast_skid;
    end
    else if (s_to_reg) begin
      axis_mdata_reg <= axis_sdata;
      axis_mkeep_reg <= axis_skeep;
      axis_muser_reg <= axis_suser;
      axis_mid_reg   <= axis_sid  ;
      axis_mdest_reg <= axis_sdest;
      axis_mstrb_reg <= axis_sstrb;
      axis_mlast_reg <= axis_slast;
    end
  end

  always @(posedge clk) begin
    if (s_to_skid) begin
      axis_mdata_skid <= axis_sdata;
      axis_mkeep_skid <= axis_skeep;
      axis_muser_skid <= axis_suser;
      axis_mid_skid   <= axis_sid  ;
      axis_mdest_skid <= axis_sdest;
      axis_mstrb_skid <= axis_sstrb;
      axis_mlast_skid <= axis_slast;
    end
  end

  assign  axis_mdata       = axis_mdata_reg   ;
  assign  axis_mkeep       = axis_mkeep_reg   ;
  assign  axis_muser       = axis_muser_reg   ;
  assign  axis_mid         = axis_mid_reg     ;
  assign  axis_mdest       = axis_mdest_reg   ;
  assign  axis_mstrb       = axis_mstrb_reg   ;
  assign  axis_mlast       = axis_mlast_reg   ;
  assign  axis_mvalid      = axis_mvalid_reg  ;

endmodule
`resetall
