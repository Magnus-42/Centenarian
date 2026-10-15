`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv6_eth_tx.v
// Module Name : ipv6_eth_tx
// Author      : LiXintao
// Date        : 2026-10-11
// Version     : v2.0
// ----------------------------------------------------------------------------
// Description : IPv6 发送链路: 纯 IPv6 包 -> 查表(多IP配MAC) -> 插以太头(EtherType 0x86DD)
//               -> 完整以太帧
// Note        : 1. 目的 MAC 由 dest 表(目的IP->对端MAC)、源 MAC 由 src 表(本机IP->本机MAC)
//                  查得(上游统一配置, 无 NDP); 任一未命中 => lookup 级直接丢弃(不产生输出拍).
//               2. u_ipv6_mac_lookup -> u_ipv6_mac_add 两级流水.
// ============================================================================

module ipv6_eth_tx #(
  parameter  DEST_MAC_ENTRY_NUM= 8 ,    // dest(对端)表项数
  parameter  SRC_MAC_ENTRY_NUM= 8 ,     // src (本机)表项数
  parameter  AXIS_USER_WIDTH= 4 
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511:0]        ipv6_axis_sdata ,
  input  wire          [                  63:0]        ipv6_axis_skeep ,
  input  wire                                          ipv6_axis_slast ,
  input  wire                                          ipv6_axis_svalid,
  input  wire          [   AXIS_USER_WIDTH-1:0]        ipv6_axis_susr  ,
  output wire                                          ipv6_axis_sready,

  // 上游统一配置的 IP->MAC 映射表 (dest=对端表 / src=本机表)
  input  wire          [128*DEST_MAC_ENTRY_NUM-1:0]    cfg_dest_match_ipv6,
  input  wire          [48*DEST_MAC_ENTRY_NUM-1:0]     cfg_dest_match_mac,
  input  wire          [128*SRC_MAC_ENTRY_NUM-1:0]     cfg_src_match_ipv6,
  input  wire          [48*SRC_MAC_ENTRY_NUM-1:0]      cfg_src_match_mac,

  output wire          [                 511:0]        eth_axis_mdata  ,
  output wire          [                  63:0]        eth_axis_mkeep  ,
  output wire                                          eth_axis_mlast  ,
  output wire                                          eth_axis_mvalid ,
  output wire          [   AXIS_USER_WIDTH-1:0]        eth_axis_musr   ,
  input  wire                                          eth_axis_mready ,

  output wire                                          stat_drop_pulse  // 未命中丢包脉冲
);

  wire                 [                 511:0]        ipv6_lut_axis_mdata;
  wire                 [                  63:0]        ipv6_lut_axis_mkeep;
  wire                                                 ipv6_lut_axis_mlast;
  wire                                                 ipv6_lut_axis_mvalid;
  wire                                                 ipv6_lut_axis_mready;
  wire                 [   AXIS_USER_WIDTH-1:0]        ipv6_lut_axis_musr;

  wire                 [                  47:0]        dst_mac          ;
  wire                 [                  47:0]        src_mac          ;

ipv6_mac_lookup #(
    .DEST_MAC_ENTRY_NUM(DEST_MAC_ENTRY_NUM),
    .SRC_MAC_ENTRY_NUM(SRC_MAC_ENTRY_NUM),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ) 
) u_ipv6_mac_lookup (
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .cfg_dest_match_ipv6(cfg_dest_match_ipv6),// (input)
    .cfg_dest_match_mac(cfg_dest_match_mac),// (input)
    .cfg_src_match_ipv6(cfg_src_match_ipv6),// (input)
    .cfg_src_match_mac(cfg_src_match_mac),// (input)
    .ipv6_axis_sdata  (ipv6_axis_sdata  ),// (input)
    .ipv6_axis_skeep  (ipv6_axis_skeep  ),// (input)
    .ipv6_axis_slast  (ipv6_axis_slast  ),// (input)
    .ipv6_axis_svalid (ipv6_axis_svalid ),// (input)
    .ipv6_axis_susr   (ipv6_axis_susr   ),// (input)
    .ipv6_axis_sready (ipv6_axis_sready ),// (output)
    .ipv6_axis_mdata  (ipv6_lut_axis_mdata),// (output)
    .ipv6_axis_mkeep  (ipv6_lut_axis_mkeep),// (output)
    .ipv6_axis_mlast  (ipv6_lut_axis_mlast),// (output)
    .ipv6_axis_mvalid (ipv6_lut_axis_mvalid),// (output)
    .ipv6_axis_musr   (ipv6_lut_axis_musr),// (output)
    .ipv6_axis_mready (ipv6_lut_axis_mready),// (input)
    .dst_mac          (dst_mac          ),// (output)
    .src_mac          (src_mac          ),// (output)
    .stat_drop_pulse  (stat_drop_pulse  ) // (output)
);

ipv6_mac_add #(
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ) 
)u_ipv6_mac_add (
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .ipv6_axis_sdata  (ipv6_lut_axis_mdata),// (input)
    .ipv6_axis_skeep  (ipv6_lut_axis_mkeep),// (input)
    .ipv6_axis_slast  (ipv6_lut_axis_mlast),// (input)
    .ipv6_axis_svalid (ipv6_lut_axis_mvalid),// (input)
    .ipv6_axis_susr   (ipv6_lut_axis_musr),// (input)
    .ipv6_axis_sready (ipv6_lut_axis_mready),// (output)
    .dst_mac          (dst_mac          ),// (input)
    .src_mac          (src_mac          ),// (input)
    .eth_axis_mdata   (eth_axis_mdata   ),// (output)
    .eth_axis_mkeep   (eth_axis_mkeep   ),// (output)
    .eth_axis_mlast   (eth_axis_mlast   ),// (output)
    .eth_axis_mvalid  (eth_axis_mvalid  ),// (output)
    .eth_axis_musr    (eth_axis_musr    ),// (output)
    .eth_axis_mready  (eth_axis_mready  ) // (input)
);

endmodule
`resetall
