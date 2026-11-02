`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : icmpv4_top.v
// Module Name : icmpv4_top
// Author      : LiXintao
// Date        : 2026-10-17
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : ICMPv4 链路顶层: 分流 + 应答
//
//   ipv4_icmp_axis_s* (来自 ipv4_top ch1, 完整 IPv4 包)
//        -> icmpv4_type_demux
//             |-- echo 请求 -> icmpv4_echo_reply -> ipv4_icmp_tx_*
//             |-- 其它 ICMP -> ipv4_other_axis_m*
// ============================================================================

module icmpv4_top#(
  parameter  AXIS_USER_WIDTH= 4 , // TX 侧仲裁值位宽(usr 宽度)
  parameter  AXIS_RX_USER_WIDTH= 97, // RX 侧 usr 每通道位宽(来自 IPv4 层)
  parameter  TX_TYPE_NUM    = 1  // 用户 ICMP 发送路数(>=1；0 由上层折算为 1 路占位)
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [    AXIS_USER_WIDTH-1:0]       arbiter_val     ,

  input  wire          [                 511:0]        ipv4_icmp_axis_sdata,
  input  wire          [                  63:0]        ipv4_icmp_axis_skeep,
  input  wire                                          ipv4_icmp_axis_slast,
  input  wire                                          ipv4_icmp_axis_svalid,
  input  wire          [AXIS_RX_USER_WIDTH-1:0]        ipv4_icmp_axis_susr ,
  output wire                                          ipv4_icmp_axis_sready,

  output wire          [                 511:0]        ipv4_other_axis_mdata ,
  output wire          [                  63:0]        ipv4_other_axis_mkeep ,
  output wire                                          ipv4_other_axis_mlast ,
  output wire                                          ipv4_other_axis_mvalid,
  output wire          [AXIS_RX_USER_WIDTH-1:0]        ipv4_other_axis_musr  ,
  input  wire                                          ipv4_other_axis_mready,

  output wire          [                 511:0]        ipv4_icmp_tx_mdata,
  output wire          [                  63:0]        ipv4_icmp_tx_mkeep,
  output wire                                          ipv4_icmp_tx_mlast,
  output wire                                          ipv4_icmp_tx_mvalid,
  output wire          [   AXIS_USER_WIDTH-1:0]        ipv4_icmp_tx_musr ,
  input  wire                                          ipv4_icmp_tx_mready,

  // ---- TX 入口: 用户 ICMP 发送 N 路(完整 IPv4 包, usr=优先级) ----
  input  wire          [      512*TX_TYPE_NUM-1:0]     icmp_axis_sdata ,
  input  wire          [       64*TX_TYPE_NUM-1:0]     icmp_axis_skeep ,
  input  wire          [          TX_TYPE_NUM-1:0]     icmp_axis_slast ,
  input  wire          [          TX_TYPE_NUM-1:0]     icmp_axis_svalid,
  input  wire          [AXIS_USER_WIDTH*TX_TYPE_NUM-1:0] icmp_axis_susr,
  output wire          [          TX_TYPE_NUM-1:0]     icmp_axis_sready,

  output wire                                          stat_drop_pulse ,
  output wire          [                   2:0]        stat_drop_reason
);

  // --------------------------------------------------------------------------
  // 1) 分流: echo / other
  // --------------------------------------------------------------------------
  wire                 [                 511:0]        demux_echo_data  ;
  wire                 [                  63:0]        demux_echo_keep  ;
  wire                                                 demux_echo_last  ;
  wire                                                 demux_echo_valid ;
  wire                 [AXIS_RX_USER_WIDTH-1:0]        demux_echo_usr   ;
  wire                                                 demux_echo_ready ;

  icmpv4_type_demux#(
    .AXIS_USER_WIDTH  (AXIS_RX_USER_WIDTH)
  ) u_icmpv4_type_demux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .ipv4_icmp_axis_sdata (ipv4_icmp_axis_sdata ),// (input)
    .ipv4_icmp_axis_skeep (ipv4_icmp_axis_skeep ),// (input)
    .ipv4_icmp_axis_slast (ipv4_icmp_axis_slast ),// (input)
    .ipv4_icmp_axis_svalid(ipv4_icmp_axis_svalid),// (input)
    .ipv4_icmp_axis_susr  (ipv4_icmp_axis_susr  ),// (input)
    .ipv4_icmp_axis_sready(ipv4_icmp_axis_sready),// (output)
    .ipv4_echo_axis_mdata (demux_echo_data     ),// (output)
    .ipv4_echo_axis_mkeep (demux_echo_keep     ),// (output)
    .ipv4_echo_axis_mlast (demux_echo_last     ),// (output)
    .ipv4_echo_axis_mvalid(demux_echo_valid    ),// (output)
    .ipv4_echo_axis_musr  (demux_echo_usr      ),// (output)
    .ipv4_echo_axis_mready(demux_echo_ready    ),// (input)
    .ipv4_other_axis_mdata (ipv4_other_axis_mdata ),// (output)
    .ipv4_other_axis_mkeep (ipv4_other_axis_mkeep ),// (output)
    .ipv4_other_axis_mlast (ipv4_other_axis_mlast ),// (output)
    .ipv4_other_axis_mvalid(ipv4_other_axis_mvalid),// (output)
    .ipv4_other_axis_musr  (ipv4_other_axis_musr  ),// (output)
    .ipv4_other_axis_mready(ipv4_other_axis_mready) // (input)
  );

  // --------------------------------------------------------------------------
  // 2) 应答
  // --------------------------------------------------------------------------
  icmpv4_echo_reply#(
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .AXIS_RX_USER_WIDTH(AXIS_RX_USER_WIDTH)
  ) u_icmpv4_echo_reply(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .arbiter_val      (arbiter_val      ),// (input)
    .ipv4_axis_sdata  (demux_echo_data  ),// (input)
    .ipv4_axis_skeep  (demux_echo_keep  ),// (input)
    .ipv4_axis_slast  (demux_echo_last  ),// (input)
    .ipv4_axis_svalid (demux_echo_valid ),// (input)
    .ipv4_axis_susr   (demux_echo_usr   ),// (input)
    .ipv4_axis_sready (demux_echo_ready ),// (output)
    .ipv4_axis_mdata  (echo_tx_data     ),// (output)
    .ipv4_axis_mkeep  (echo_tx_keep     ),// (output)
    .ipv4_axis_mlast  (echo_tx_last     ),// (output)
    .ipv4_axis_mvalid (echo_tx_valid    ),// (output)
    .ipv4_axis_musr   (echo_tx_usr      ),// (output)
    .ipv4_axis_mready (echo_tx_ready    ),// (input)
    .stat_drop_pulse  (stat_drop_pulse ),
    .stat_drop_reason (stat_drop_reason)
  );

  // --------------------------------------------------------------------------
  // 3) 发送汇聚: 内部 echo 应答(档0) + 用户 N 路(档1..N) -> 1 路
  // --------------------------------------------------------------------------
  wire                 [      512*(TX_TYPE_NUM+1)-1:0] tx_mux_sdata ;
  wire                 [       64*(TX_TYPE_NUM+1)-1:0] tx_mux_skeep ;
  wire                 [          (TX_TYPE_NUM+1)-1:0] tx_mux_slast ;
  wire                 [          (TX_TYPE_NUM+1)-1:0] tx_mux_svalid;
  wire                 [AXIS_USER_WIDTH*(TX_TYPE_NUM+1)-1:0] tx_mux_susr;
  wire                 [          (TX_TYPE_NUM+1)-1:0] tx_mux_sready;

  wire                 [                 511:0]        echo_tx_data  ;
  wire                 [                  63:0]        echo_tx_keep  ;
  wire                                                 echo_tx_last  ;
  wire                                                 echo_tx_valid ;
  wire                 [   AXIS_USER_WIDTH-1:0]        echo_tx_usr   ;
  wire                                                 echo_tx_ready ;

  assign  tx_mux_sdata  = {icmp_axis_sdata , echo_tx_data };
  assign  tx_mux_skeep  = {icmp_axis_skeep , echo_tx_keep };
  assign  tx_mux_slast  = {icmp_axis_slast , echo_tx_last };
  assign  tx_mux_svalid = {icmp_axis_svalid, echo_tx_valid};
  assign  tx_mux_susr   = {icmp_axis_susr  , arbiter_val};

  assign  echo_tx_ready = tx_mux_sready[0];
  assign  icmp_axis_sready = tx_mux_sready[TX_TYPE_NUM:1];

  icmpv4_tx_mux#(
    .PORT_NUM         (TX_TYPE_NUM + 1  ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .ARBITER_VAL_WIDTH(AXIS_USER_WIDTH  )
  ) u_icmpv4_tx_mux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .icmp_axis_sdata  (tx_mux_sdata     ),// (input)
    .icmp_axis_skeep  (tx_mux_skeep     ),// (input)
    .icmp_axis_slast  (tx_mux_slast     ),// (input)
    .icmp_axis_svalid (tx_mux_svalid    ),// (input)
    .icmp_axis_susr   (tx_mux_susr      ),// (input)
    .icmp_axis_sready (tx_mux_sready    ),// (output)
    .icmp_axis_mdata  (ipv4_icmp_tx_mdata ),// (output)
    .icmp_axis_mkeep  (ipv4_icmp_tx_mkeep ),// (output)
    .icmp_axis_mlast  (ipv4_icmp_tx_mlast ),// (output)
    .icmp_axis_mvalid (ipv4_icmp_tx_mvalid),// (output)
    .icmp_axis_musr   (ipv4_icmp_tx_musr  ),// (output)
    .icmp_axis_mready (ipv4_icmp_tx_mready),// (input)
    .stat_active_port (                 ),// (output)
    .stat_idle        (                 ) // (output)
  );

endmodule
`resetall
