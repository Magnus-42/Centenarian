`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_tx_mux.v
// Module Name : udp_tx_mux
// Author      : LiXintao
// Date        : 2026-10-12
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : UDP出口复用: IPV4帧仲裁复用到一路
// Note        : 优先级：高位优先
// ============================================================================

module udp_tx_mux#(
  parameter  PORT_NUM= 4 ,
  parameter  AXIS_USER_WIDTH= 4 ,
  parameter  IDX_W= (PORT_NUM <= 1) ? 1 : $clog2(PORT_NUM)
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // ---- 入口 ----
  input  wire          [      512*PORT_NUM-1:0]        udp_axis_sdata  ,
  input  wire          [       64*PORT_NUM-1:0]        udp_axis_skeep  ,
  input  wire          [          PORT_NUM-1:0]        udp_axis_slast  ,
  input  wire          [          PORT_NUM-1:0]        udp_axis_svalid ,
  input  wire          [AXIS_USER_WIDTH*PORT_NUM-1:0]  udp_axis_susr   ,
  output wire          [          PORT_NUM-1:0]        udp_axis_sready ,

  // ---- 出口 ----
  output wire          [                 511:0]        udp_axis_mdata  ,
  output wire          [                  63:0]        udp_axis_mkeep  ,
  output wire                                          udp_axis_mlast  ,
  output wire                                          udp_axis_mvalid ,
  output wire          [   AXIS_USER_WIDTH-1:0]        udp_axis_musr   ,
  input  wire                                          udp_axis_mready ,

  // ---- 状态 ----
  output wire          [             IDX_W-1:0]        stat_active_port,// 0=other 1=ospf 2=icmp 3=udp
  output wire                                          stat_idle        
);


  axis_nto1_by_val#(
    .NUM_PORTS        (PORT_NUM         ),
    .AXIS_WIDTH       (512              ),
    .AXIS_ID_WIDTH    (1                ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .ARBITER_VAL_WIDTH(AXIS_USER_WIDTH  ),
    .LOW_FIRST        (0                ),
    .UPDATE_TID       (0                ) 
  )
  u_axis_nto1_by_val(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    // --- N 路 Slave 输入 (Packed Array) ---
    // 数据通道
    .axis_sdata       (udp_axis_sdata   ),// (input)
    .axis_skeep       (udp_axis_skeep   ),// (input)
    .axis_sid         ('d0              ),// (input)
    .axis_susr        (udp_axis_susr    ),// (input)
    .axis_svalid      (udp_axis_svalid  ),// (input)
    .axis_slast       (udp_axis_slast   ),// (input)
    .axis_sready      (udp_axis_sready  ),// (output)
  // --- 1 路 Master 输出 ---
    .axis_mdata       (udp_axis_mdata   ),// (output)
    .axis_mkeep       (udp_axis_mkeep   ),// (output)
    .axis_mid         (                 ),// (output)
    .axis_musr        (udp_axis_musr    ),// (output)
    .axis_mvalid      (udp_axis_mvalid  ),// (output)
    .axis_mlast       (udp_axis_mlast   ),// (output)
    .axis_mready      (udp_axis_mready  ),// (input)
  // --- 状态 / 调试 ---
    .stat_active_port (stat_active_port ),// (output)// 当前正在传输的端口号
    .stat_idle        (stat_idle        ) // (output)// 空闲状态指示
  );

endmodule
`resetall
