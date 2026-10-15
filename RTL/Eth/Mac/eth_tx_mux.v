`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : eth_tx_mux.v
// Module Name : eth_tx_mux
// Author      : LiXintao
// Date        : 2026-09-24
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 以太网出口复用: 三类以太帧(other / arp / ipv4)仲裁复用到一路
// Note        : 优先级：other- > arp -> ipv4
// ============================================================================

module eth_tx_mux#(
  parameter AXIS_WIDTH      = 512,
  parameter AXIS_ID_WIDTH   = 1  ,
  parameter AXIS_USER_WIDTH = 1
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // ---- 入口 0: other(优先级最高) ----
  input  wire          [        AXIS_WIDTH-1: 0]       other_axis_sdata ,
  input  wire          [      AXIS_WIDTH/8-1: 0]       other_axis_skeep ,
  input  wire                                          other_axis_slast ,
  input  wire                                          other_axis_svalid,
  output wire                                          other_axis_sready,

  // ---- 入口 1: arp ----
  input  wire          [        AXIS_WIDTH-1: 0]       arp_axis_sdata ,
  input  wire          [      AXIS_WIDTH/8-1: 0]       arp_axis_skeep ,
  input  wire                                          arp_axis_slast ,
  input  wire                                          arp_axis_svalid,
  output wire                                          arp_axis_sready,

  // ---- 入口 2: ipv4(优先级最低) ----
  input  wire          [        AXIS_WIDTH-1: 0]       ipv4_axis_sdata ,
  input  wire          [      AXIS_WIDTH/8-1: 0]       ipv4_axis_skeep ,
  input  wire                                          ipv4_axis_slast ,
  input  wire                                          ipv4_axis_svalid,
  output wire                                          ipv4_axis_sready,

  // ---- 出口 ----
  output wire          [        AXIS_WIDTH-1: 0]       eth_axis_mdata  ,
  output wire          [      AXIS_WIDTH/8-1: 0]       eth_axis_mkeep  ,
  output wire                                          eth_axis_mlast  ,
  output wire                                          eth_axis_mvalid ,
  output wire          [   AXIS_USER_WIDTH-1: 0]       eth_axis_muser  ,
  input  wire                                          eth_axis_mready ,

  // ---- 状态 ----
  output wire          [                   1: 0]       stat_active_port ,// 0=other 1=arp 2=ipv4
  output wire                                          stat_idle
);

  wire                 [               3-1: 0]       arb_sready       ;

  axis_nto1 #(
    .NUM_PORTS       (3                ),
    .IDX_W           (2                ),
    .AXIS_WIDTH      (AXIS_WIDTH       ),
    .AXIS_ID_WIDTH   (AXIS_ID_WIDTH    ),
    .AXIS_USER_WIDTH (AXIS_USER_WIDTH  ),
    .ARB_TYPE        (1                ),// 1 = 严格优先(低位优先 => port0 最高)
    .UPDATE_TID      (0                ) // 不覆写 tid
  ) u_arb (
    .clk              (clk              ),
    .rst              (rst              ),
    //  打包顺序: {ipv4, arp, other} => port0=other(最高) port1=arp port2=ipv4
    .axis_sdata       ({ipv4_axis_sdata , arp_axis_sdata , other_axis_sdata }),
    .axis_skeep       ({ipv4_axis_skeep , arp_axis_skeep , other_axis_skeep }),
    .axis_sid         ({(3*AXIS_ID_WIDTH){1'b0}}),
    .axis_suser       ({(3*AXIS_USER_WIDTH){1'b0}}),
    .axis_svalid      ({ipv4_axis_svalid, arp_axis_svalid, other_axis_svalid}),
    .axis_slast       ({ipv4_axis_slast , arp_axis_slast , other_axis_slast }),
    .axis_sready      (arb_sready       ),
    .axis_mdata       (eth_axis_mdata   ),
    .axis_mkeep       (eth_axis_mkeep   ),
    .axis_mid         (                 ),
    .axis_muser       (eth_axis_muser   ),
    .axis_mvalid      (eth_axis_mvalid  ),
    .axis_mlast       (eth_axis_mlast   ),
    .axis_mready      (eth_axis_mready  ),
    .stat_active_port (stat_active_port ),
    .stat_idle        (stat_idle        )
  );

  assign other_axis_sready = arb_sready[0];
  assign arp_axis_sready   = arb_sready[1];
  assign ipv4_axis_sready  = arb_sready[2];

endmodule
`resetall
