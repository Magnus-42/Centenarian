`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_ipv4_tx.v
// Module Name : udp_ipv4_tx
// Author      : LiXintao
// Date        : 2026-10-8
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计
// 
// ============================================================================

module udp_ipv4_tx(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511: 0]       udp_axis_sdata  ,
  input  wire          [                  63: 0]       udp_axis_skeep  ,
  input  wire                                          udp_axis_slast  ,
  input  wire                                          udp_axis_svalid ,
  output wire                                          udp_axis_sready ,

  input  wire          [                  15: 0]       cfg_total_len   ,
  input  wire          [                   7: 0]       cfg_ttl         ,
  input  wire          [                  15: 0]       cfg_head_checksum,
  input  wire          [                  31: 0]       cfg_src_ip      ,
  input  wire          [                  31: 0]       cfg_dest_ip     ,

  output wire          [                 511: 0]       ipv4_axis_mdata ,
  output wire          [                  63: 0]       ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  input  wire                                          ipv4_axis_mready 
);


udp_ipv4_header_add u_udp_ipv4_header_add(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .udp_axis_sdata   (udp_axis_sdata   ),// (input)
    .udp_axis_skeep   (udp_axis_skeep   ),// (input)
    .udp_axis_slast   (udp_axis_slast   ),// (input)
    .udp_axis_svalid  (udp_axis_svalid  ),// (input)
    .udp_axis_sready  (udp_axis_sready  ),// (output)
    .cfg_total_len    (cfg_total_len    ),// (input)
    .cfg_ttl          (cfg_ttl          ),// (input)
    .cfg_head_checksum(cfg_head_checksum),// (input)
    .cfg_src_ip       (cfg_src_ip       ),// (input)
    .cfg_dest_ip      (cfg_dest_ip      ),// (input)
    .ipv4_axis_mdata  (udpv4_hd_add_axis_mdata ),// (output)
    .ipv4_axis_mkeep  (udpv4_hd_add_axis_mkeep ),// (output)
    .ipv4_axis_mlast  (udpv4_hd_add_axis_mlast ),// (output)
    .ipv4_axis_mvalid (udpv4_hd_add_axis_mvalid),// (output)
    .ipv4_axis_mready (udpv4_hd_add_axis_mready) // (input)
);



  wire                                                 udpv4_hd_add_axis_mready  ;
  wire                 [                 511: 0]       udpv4_hd_add_axis_mdata  ;
  wire                 [                  63: 0]       udpv4_hd_add_axis_mkeep  ;
  wire                                                 udpv4_hd_add_axis_mlast  ;
  wire                                                 udpv4_hd_add_axis_mvalid  ;

axis_skid_buffer#(
    .AXIS_DATA_WIDTH  (512              ),
    .AXIS_USER_WIDTH  (1                ),
    .AXIS_ID_WIDTH    (1                ),
    .AXIS_DEST_WIDTH  (1                ) 
)
 u_axis_skid_buffer(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .axis_sready      (udpv4_hd_add_axis_mready),// (output)
    .axis_sdata       (udpv4_hd_add_axis_mdata),// (input)
    .axis_skeep       (udpv4_hd_add_axis_mkeep),// (input)
    .axis_suser       ('d0              ),// (input)
    .axis_sid         ('d0              ),// (input)
    .axis_sdest       ('d0              ),// (input)
    .axis_sstrb       ('d0              ),// (input)
    .axis_slast       (udpv4_hd_add_axis_mlast),// (input)
    .axis_svalid      (udpv4_hd_add_axis_mvalid),// (input)
    .axis_mready      (ipv4_axis_mready ),// (input)
    .axis_mdata       (ipv4_axis_mdata  ),// (output)
    .axis_mkeep       (ipv4_axis_mkeep  ),// (output)
    .axis_muser       (                 ),// (output)
    .axis_mid         (                 ),// (output)
    .axis_mdest       (                 ),// (output)
    .axis_mstrb       (                 ),// (output)
    .axis_mlast       (ipv4_axis_mlast  ),// (output)
    .axis_mvalid      (ipv4_axis_mvalid ) // (output)
);

endmodule
`resetall
