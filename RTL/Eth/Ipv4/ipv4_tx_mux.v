`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_tx_mux.v
// Module Name : ipv4_tx_mux
// Author      : LiXintao
// Date        : 2026-09-29
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 以太网出口复用: 四类以太帧(other / ospf / icmp / udp)仲裁复用到一路
// Note        : 优先级：other- > ospf -> icmp -> udp
// ============================================================================

module ipv4_tx_mux(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // ---- 入口 0: other(优先级最高) ----
  input  wire          [                 511: 0]       ipv4_other_axis_sdata,
  input  wire          [                  63: 0]       ipv4_other_axis_skeep,
  input  wire                                          ipv4_other_axis_slast,
  input  wire                                          ipv4_other_axis_svalid,
  output wire                                          ipv4_other_axis_sready,

  // ---- 入口 1: ospf ----
  input  wire          [                 511: 0]       ipv4_ospf_axis_sdata,
  input  wire          [                  63: 0]       ipv4_ospf_axis_skeep,
  input  wire                                          ipv4_ospf_axis_slast,
  input  wire                                          ipv4_ospf_axis_svalid,
  output wire                                          ipv4_ospf_axis_sready,

  // ---- 入口 2: icmp ----
  input  wire          [                 511: 0]       ipv4_icmp_axis_sdata,
  input  wire          [                  63: 0]       ipv4_icmp_axis_skeep,
  input  wire                                          ipv4_icmp_axis_slast,
  input  wire                                          ipv4_icmp_axis_svalid,
  output wire                                          ipv4_icmp_axis_sready,

  // ---- 入口 3: udp(优先级最低) ----
  input  wire          [                 511: 0]       ipv4_udp_axis_sdata,
  input  wire          [                  63: 0]       ipv4_udp_axis_skeep,
  input  wire                                          ipv4_udp_axis_slast,
  input  wire                                          ipv4_udp_axis_svalid,
  output wire                                          ipv4_udp_axis_sready,

  // ---- 出口 ----
  output wire          [                 511: 0]       ipv4_axis_mdata ,
  output wire          [                  63: 0]       ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  input  wire                                          ipv4_axis_mready,

  // ---- 状态 ----
  output wire          [                   1: 0]       stat_active_port,// 0=other 1=ospf 2=icmp 3=udp
  output wire                                          stat_idle        
);

  wire                 [                   3: 0]       arb_sready         ;

  axis_nto1 #(
    .NUM_PORTS        (4                ),
    .AXIS_WIDTH       (512              ),
    .AXIS_ID_WIDTH    (1                ),
    .AXIS_USER_WIDTH  (1                ),
    .ARB_TYPE         (1                ),// 1 = 严格优先(低位优先 => port0 最高)
    .UPDATE_TID       (0                ) // 不覆写 tid
  ) u_arb (
    .clk              (clk              ),
    .rst              (rst              ),
    .axis_sdata       ({ipv4_udp_axis_sdata, ipv4_icmp_axis_sdata , ipv4_ospf_axis_sdata , ipv4_other_axis_sdata }),
    .axis_skeep       ({ipv4_udp_axis_skeep, ipv4_icmp_axis_skeep , ipv4_ospf_axis_skeep , ipv4_other_axis_skeep }),
    .axis_sid         ({(4){1'b0}}      ),
    .axis_suser       ({(4){1'b0}}      ),
    .axis_svalid      ({ipv4_udp_axis_svalid, ipv4_icmp_axis_svalid, ipv4_ospf_axis_svalid, ipv4_other_axis_svalid}),
    .axis_slast       ({ipv4_udp_axis_slast, ipv4_icmp_axis_slast , ipv4_ospf_axis_slast , ipv4_other_axis_slast }),
    .axis_sready      (arb_sready       ),
    .axis_mdata       (ipv4_axis_mdata  ),
    .axis_mkeep       (ipv4_axis_mkeep  ),
    .axis_mid         (                 ),
    .axis_muser       (                 ),
    .axis_mvalid      (ipv4_axis_mvalid ),
    .axis_mlast       (ipv4_axis_mlast  ),
    .axis_mready      (ipv4_axis_mready ),
    .stat_active_port (stat_active_port ),
    .stat_idle        (stat_idle        ) 
  );

  assign  ipv4_other_axis_sready= arb_sready[0]    ;
  assign  ipv4_ospf_axis_sready= arb_sready[1]    ;
  assign  ipv4_icmp_axis_sready= arb_sready[2]    ;
  assign  ipv4_udp_axis_sready= arb_sready[3]    ;

endmodule
`resetall
