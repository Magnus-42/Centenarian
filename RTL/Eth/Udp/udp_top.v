`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_top.v
// Module Name : udp_top
// Author      : LiXintao
// Date        : 2026-10-8
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : udp 链路顶层
//
// ============================================================================

module udp_top#(
  parameter  PORT_NUM= 3 ,
  parameter  [       PORT_NUM*32-1:0]        DST_PORT_RANGE= {32'h00080002,32'h00010001,32'h00000000} // 端口禁止重叠
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // rx
  input  wire          [                 511:0]        ipv4_udp_axis_sdata,
  input  wire          [                  63:0]        ipv4_udp_axis_skeep,
  input  wire                                          ipv4_udp_axis_slast,
  input  wire                                          ipv4_udp_axis_svalid,
  input  wire          [                  95:0]        ipv4_udp_axis_susr,
  output wire                                          ipv4_udp_axis_sready,

  output wire          [  512*(PORT_NUM+1)-1:0]        udp_axis_mdata  ,
  output wire          [   64*(PORT_NUM+1)-1:0]        udp_axis_mkeep  ,
  output wire          [            PORT_NUM:0]        udp_axis_mlast  ,
  output wire          [            PORT_NUM:0]        udp_axis_mvalid ,
  output wire          [  192*(PORT_NUM+1)-1:0]        udp_axis_musr   ,
  input  wire          [            PORT_NUM:0]        udp_axis_mready ,

  // tx
  input  wire          [                 511:0]        udp_axis_sdata  ,
  input  wire          [                  63:0]        udp_axis_skeep  ,
  input  wire                                          udp_axis_slast  ,
  input  wire                                          udp_axis_svalid ,
  output wire                                          udp_axis_sready ,

  input  wire          [                  15:0]        cfg_total_len   ,
  input  wire          [                   7:0]        cfg_ttl         ,
  input  wire          [                  15:0]        cfg_head_checksum,
  input  wire          [                  31:0]        cfg_src_ip      ,
  input  wire          [                  31:0]        cfg_dest_ip     ,

  output wire          [                 511:0]        ipv4_axis_mdata ,
  output wire          [                  63:0]        ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  input  wire                                          ipv4_axis_mready,

  output wire                                          stat_is_df       

);

  wire                 [                 511:0]        udp_ipv4_rx_axis_mdata;
  wire                 [                  63:0]        udp_ipv4_rx_axis_mkeep;
  wire                                                 udp_ipv4_rx_axis_mlast;
  wire                                                 udp_ipv4_rx_axis_mvalid;
  wire                 [                 191:0]        udp_ipv4_rx_axis_musr;
  wire                                                 udp_ipv4_rx_axis_mready;

  wire                 [                   7:0]        protocol         ;
  wire                 [                  15:0]        total_len        ;
  wire                 [                   7:0]        ttl              ;
  wire                 [                  31:0]        src_ip           ;
  wire                 [                  31:0]        dest_ip          ;

  udp_ipv4_rx u_udp_ipv4_rx(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .ipv4_axis_sdata  (ipv4_udp_axis_sdata),// (input)
    .ipv4_axis_skeep  (ipv4_udp_axis_skeep),// (input)
    .ipv4_axis_slast  (ipv4_udp_axis_slast),// (input)
    .ipv4_axis_svalid (ipv4_udp_axis_svalid),// (input)
    .ipv4_axis_susr   (ipv4_udp_axis_susr),// (input)
    .ipv4_axis_sready (ipv4_udp_axis_sready),// (output)
    .udp_axis_mdata   (udp_ipv4_rx_axis_mdata),// (output)
    .udp_axis_mkeep   (udp_ipv4_rx_axis_mkeep),// (output)
    .udp_axis_mlast   (udp_ipv4_rx_axis_mlast),// (output)
    .udp_axis_mvalid  (udp_ipv4_rx_axis_mvalid),// (output)
    .udp_axis_musr    (udp_ipv4_rx_axis_musr[95:0]),// (output)
    .udp_axis_mready  (udp_ipv4_rx_axis_mready),// (input)
    .protocol         (protocol         ),// (output)
    .total_len        (total_len        ),// (output)
    .ttl              (ttl              ),// (output)
    .src_ip           (src_ip           ),// (output)
    .dest_ip          (dest_ip          ),// (output)
    .stat_is_df       (stat_is_df       ) // (output)// 禁止分片
  );

  assign  udp_ipv4_rx_axis_musr[191:96]= {dest_ip,src_ip,ttl,total_len,protocol};


  udp_type_demux#(
    .PORT_NUM         (PORT_NUM         ),
    .DST_PORT_RANGE   (DST_PORT_RANGE   ) 
  )
  u_udp_type_demux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .udp_axis_sdata   (udp_ipv4_rx_axis_mdata),// (input)
    .udp_axis_skeep   (udp_ipv4_rx_axis_mkeep),// (input)
    .udp_axis_slast   (udp_ipv4_rx_axis_mlast),// (input)
    .udp_axis_svalid  (udp_ipv4_rx_axis_mvalid),// (input)
    .udp_axis_susr    (udp_ipv4_rx_axis_musr),// (input)
    .udp_axis_sready  (udp_ipv4_rx_axis_mready),// (output)
    .udp_axis_mdata   (udp_axis_mdata   ),// (output)
    .udp_axis_mkeep   (udp_axis_mkeep   ),// (output)
    .udp_axis_mlast   (udp_axis_mlast   ),// (output)
    .udp_axis_mvalid  (udp_axis_mvalid  ),// (output)
    .udp_axis_musr    (udp_axis_musr    ),// (output)
    .udp_axis_mready  (udp_axis_mready  ) // (input)
  );

  udp_ipv4_tx u_udp_ipv4_tx(
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
    .ipv4_axis_mdata  (ipv4_axis_mdata  ),// (output)
    .ipv4_axis_mkeep  (ipv4_axis_mkeep  ),// (output)
    .ipv4_axis_mlast  (ipv4_axis_mlast  ),// (output)
    .ipv4_axis_mvalid (ipv4_axis_mvalid ),// (output)
    .ipv4_axis_mready (ipv4_axis_mready ) // (input)
  );

endmodule