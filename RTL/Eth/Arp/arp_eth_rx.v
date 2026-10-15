`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : arp_eth_rx.v
// Module Name : arp_eth_rx
// Author      : LiXintao
// Date        : 2026-09-14
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 
// 
// ============================================================================

module arp_eth_rx#(
  parameter  AXIS_WIDTH= 512
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // arp frame input
  output wire                                          arp_frame_valid ,
  input  wire                                          arp_frame_ready ,
  output wire          [                  47: 0]       eth_dest_mac    ,
  output wire          [                  47: 0]       eth_src_mac     ,
  output wire          [                  15: 0]       eth_type        ,
  output wire          [                  15: 0]       arp_htype       ,
  output wire          [                  15: 0]       arp_ptype       ,
  output wire          [                   7: 0]       arp_hlen        ,
  output wire          [                   7: 0]       arp_plen        ,
  output wire          [                  15: 0]       arp_oper        ,
  output wire          [                  47: 0]       arp_sha         ,// sender hardware address
  output wire          [                  31: 0]       arp_spa         ,// sender protocol address
  output wire          [                  47: 0]       arp_tha         ,// target hardware address
  output wire          [                  31: 0]       arp_tpa         ,// target protocol address

  // eth_arp axis out
  input  wire          [        AXIS_WIDTH-1: 0]       arp_axis_sdata  ,
  input  wire          [      AXIS_WIDTH/8-1: 0]       arp_axis_skeep  ,
  input  wire                                          arp_axis_svalid ,
  input  wire                                          arp_axis_slast  ,
  output wire                                          arp_axis_sready ,

  output wire                                          stat_error       // 帧解析失败，不是标准的ARP ETH帧

);

  reg                                                  arp_frame_valid_reg  ;
  reg                  [                  47: 0]       eth_dest_mac_reg   ;
  reg                  [                  47: 0]       eth_src_mac_reg    ;
  reg                  [                  15: 0]       eth_type_reg       ;
  reg                  [                  15: 0]       arp_htype_reg      ;
  reg                  [                  15: 0]       arp_ptype_reg      ;
  reg                  [                   7: 0]       arp_hlen_reg       ;
  reg                  [                   7: 0]       arp_plen_reg       ;
  reg                  [                  15: 0]       arp_oper_reg       ;
  reg                  [                  47: 0]       arp_sha_reg        ;
  reg                  [                  31: 0]       arp_spa_reg        ;
  reg                  [                  47: 0]       arp_tha_reg        ;
  reg                  [                  31: 0]       arp_tpa_reg        ;
  reg                                                  stat_error_reg     ;

  wire                                                 s_handshake        ;
  wire                                                 arp_frame_handshake  ;

  assign  s_handshake      = arp_axis_sready & arp_axis_svalid;
  assign  arp_frame_handshake= arp_frame_valid & arp_frame_ready;
  assign  arp_axis_sready  = !arp_frame_valid || arp_frame_ready;

always @(posedge clk) begin
  if (rst) begin
    arp_frame_valid_reg <= 'd0;
    stat_error_reg <= 'd0;
  end
  else begin
    stat_error_reg <= 1'd0;
    if (s_handshake) begin
      if (arp_axis_slast && (arp_axis_skeep & 64'h0000_03FF_FFFF_FFFF) == 64'h0000_03FF_FFFF_FFFF) begin
        arp_frame_valid_reg <= 1'b1;
        {arp_tpa_reg,arp_tha_reg,arp_spa_reg,arp_sha_reg,arp_oper_reg,arp_plen_reg,arp_hlen_reg,arp_ptype_reg,arp_htype_reg,eth_type_reg,eth_src_mac_reg,eth_dest_mac_reg} <= arp_axis_sdata[335:0];
      end
      else begin
        stat_error_reg <= 1'd1;
      end
    end
    else if (arp_frame_handshake) begin
      arp_frame_valid_reg <= 1'b0;
    end
  end
end

  assign  stat_error       = stat_error_reg   ;
  assign  arp_frame_valid  = arp_frame_valid_reg;
  assign  eth_dest_mac     = eth_dest_mac_reg ;
  assign  eth_src_mac      = eth_src_mac_reg  ;
  assign  eth_type         = eth_type_reg     ;
  assign  arp_htype        = arp_htype_reg    ;
  assign  arp_ptype        = arp_ptype_reg    ;
  assign  arp_hlen         = arp_hlen_reg     ;
  assign  arp_plen         = arp_plen_reg     ;
  assign  arp_oper         = arp_oper_reg     ;
  assign  arp_sha          = arp_sha_reg      ;
  assign  arp_spa          = arp_spa_reg      ;
  assign  arp_tha          = arp_tha_reg      ;
  assign  arp_tpa          = arp_tpa_reg      ;

endmodule
`resetall