`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_eth_tx.v
// Module Name : ipv4_eth_tx
// Author      : LiXintao
// Date        : 2026-09-18
// Version     : v2.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计
// Note        : u_ipv4_arp_service -> u_ipv4_mac_add
// ============================================================================

module ipv4_eth_tx(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511: 0]       ipv4_axis_sdata ,
  input  wire          [                  63: 0]       ipv4_axis_skeep ,
  input  wire                                          ipv4_axis_slast ,
  input  wire                                          ipv4_axis_svalid,
  output wire                                          ipv4_axis_sready,


  output wire          [                  31: 0]       query_src_ip    ,
  output wire          [                  31: 0]       query_dst_ip    ,
  output wire                                          query_valid_pulse,
  input  wire          [                  47: 0]       arp_dst_mac     ,
  input  wire          [                  47: 0]       arp_src_mac     ,
  input  wire                                          arp_miss        ,
  input  wire                                          arp_valid       ,

  output wire          [                 511: 0]       eth_axis_mdata  ,
  output wire          [                  63: 0]       eth_axis_mkeep  ,
  output wire                                          eth_axis_mlast  ,
  output wire                                          eth_axis_mvalid ,
  input  wire                                          eth_axis_mready  
);


  wire                 [                 511: 0]       ipv4_arp_axis_mdata  ;
  wire                 [                  63: 0]       ipv4_arp_axis_mkeep  ;
  wire                                                 ipv4_arp_axis_mlast  ;
  wire                                                 ipv4_arp_axis_mvalid  ;
  wire                                                 ipv4_arp_axis_mready  ;

  wire                 [                  47: 0]       dst_mac            ;
  wire                 [                  47: 0]       src_mac            ;
  
ipv4_arp_service u_ipv4_arp_service(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .ipv4_axis_sdata  (ipv4_axis_sdata  ),// (input)
    .ipv4_axis_skeep  (ipv4_axis_skeep  ),// (input)
    .ipv4_axis_slast  (ipv4_axis_slast  ),// (input)
    .ipv4_axis_svalid (ipv4_axis_svalid ),// (input)
    .ipv4_axis_sready (ipv4_axis_sready ),// (output)
    .ipv4_axis_mdata  (ipv4_arp_axis_mdata),// (output)
    .ipv4_axis_mkeep  (ipv4_arp_axis_mkeep),// (output)
    .ipv4_axis_mlast  (ipv4_arp_axis_mlast),// (output)
    .ipv4_axis_mvalid (ipv4_arp_axis_mvalid),// (output)
    .ipv4_axis_mready (ipv4_arp_axis_mready),// (input)
    .dst_mac          (dst_mac          ),// (output)
    .src_mac          (src_mac          ),// (output)
    .query_src_ip     (query_src_ip     ),// (output)
    .query_dst_ip     (query_dst_ip     ),// (output)
    .query_valid_pulse(query_valid_pulse),// (output)
    .arp_dst_mac      (arp_dst_mac      ),// (input)
    .arp_src_mac      (arp_src_mac      ),// (input)
    .arp_miss         (arp_miss         ),// (input)
    .arp_valid        (arp_valid        ) // (input)
);

ipv4_mac_add u_ipv4_mac_add(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .ipv4_axis_sdata  (ipv4_arp_axis_mdata),// (input)
    .ipv4_axis_skeep  (ipv4_arp_axis_mkeep),// (input)
    .ipv4_axis_slast  (ipv4_arp_axis_mlast),// (input)
    .ipv4_axis_svalid (ipv4_arp_axis_mvalid),// (input)
    .ipv4_axis_sready (ipv4_arp_axis_mready),// (output)
    .dst_mac          (dst_mac          ),// (input)
    .src_mac          (src_mac          ),// (input)
    .eth_axis_mdata   (eth_axis_mdata   ),// (output)
    .eth_axis_mkeep   (eth_axis_mkeep   ),// (output)
    .eth_axis_mlast   (eth_axis_mlast   ),// (output)
    .eth_axis_mvalid  (eth_axis_mvalid  ),// (output)
    .eth_axis_mready  (eth_axis_mready  ) // (input)
);

endmodule
`resetall
