`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : icmpv4_tx_mux.v
// Module Name : icmpv4_tx_mux
// Author      : LiXintao
// Date        : 2026-10-19
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : ICMPv4 发送汇聚: N 路(用户 ICMP + 内部 echo 应答)仲裁复用到 1 路
// Note        : 1. 各路按 usr 低 ARBITER_VAL_WIDTH 位作仲裁值(0=禁用/无请求)
//               2. 包级锁定, 同值轮询; 与 udp_ipv4_tx_mux / ipv4_tx_mux 同构
// ============================================================================

module icmpv4_tx_mux#(
  parameter  PORT_NUM= 2 ,
  parameter  AXIS_USER_WIDTH= 4 ,
  parameter  ARBITER_VAL_WIDTH= 4 ,
  localparam IDX_WIDTH= (PORT_NUM <= 1) ? 1 : $clog2(PORT_NUM)
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // ---- 入口: N 路 ----
  input  wire          [      512*PORT_NUM-1:0]        icmp_axis_sdata ,
  input  wire          [       64*PORT_NUM-1:0]        icmp_axis_skeep ,
  input  wire          [          PORT_NUM-1:0]        icmp_axis_slast ,
  input  wire          [          PORT_NUM-1:0]        icmp_axis_svalid,
  input  wire          [AXIS_USER_WIDTH*PORT_NUM-1:0]  icmp_axis_susr  ,
  output wire          [          PORT_NUM-1:0]        icmp_axis_sready,

  // ---- 出口: 1 路 -> IPv4 TX 的 icmp 档 ----
  output wire          [                 511:0]        icmp_axis_mdata ,
  output wire          [                  63:0]        icmp_axis_mkeep ,
  output wire                                          icmp_axis_mlast ,
  output wire                                          icmp_axis_mvalid,
  output wire          [   AXIS_USER_WIDTH-1:0]        icmp_axis_musr  ,
  input  wire                                          icmp_axis_mready,

  // ---- 状态 ----
  output wire          [             IDX_WIDTH-1:0]    stat_active_port,
  output wire                                          stat_idle
);

  axis_n_to_1_by_val#(
    .NUM_PORTS        (PORT_NUM         ),
    .AXIS_WIDTH       (512              ),
    .AXIS_ID_WIDTH    (1                ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .ARBITER_VAL_WIDTH(ARBITER_VAL_WIDTH),
    .LOW_FIRST        (0                ),
    .UPDATE_TID       (0                )
  )
  u_axis_n_to_1_by_val(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    // --- N 路 Slave 输入 (Packed Array) ---
    .axis_sdata       (icmp_axis_sdata  ),// (input)
    .axis_skeep       (icmp_axis_skeep  ),// (input)
    .axis_sid         ('d0              ),// (input)
    .axis_susr        (icmp_axis_susr   ),// (input)
    .axis_svalid      (icmp_axis_svalid ),// (input)
    .axis_slast       (icmp_axis_slast  ),// (input)
    .axis_sready      (icmp_axis_sready ),// (output)
    // --- 1 路 Master 输出 ---
    .axis_mdata       (icmp_axis_mdata  ),// (output)
    .axis_mkeep       (icmp_axis_mkeep  ),// (output)
    .axis_mid         (                 ),// (output)
    .axis_musr        (icmp_axis_musr   ),// (output)
    .axis_mvalid      (icmp_axis_mvalid ),// (output)
    .axis_mlast       (icmp_axis_mlast  ),// (output)
    .axis_mready      (icmp_axis_mready ),// (input)
    // --- 状态 / 调试 ---
    .stat_active_port (stat_active_port ),// (output)
    .stat_idle        (stat_idle        ) // (output)
  );

endmodule
`resetall
