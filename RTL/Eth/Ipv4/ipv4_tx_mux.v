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
// Description : IPV4出口复用: IPV4帧仲裁复用到一路
// Note        : 优先级：高位优先
// ============================================================================

module ipv4_tx_mux#(
  parameter  TYPE_NUM= 4 ,
  parameter  AXIS_USER_WIDTH= 4 ,
  parameter  IDX_W= (TYPE_NUM <= 1) ? 1 : $clog2(TYPE_NUM)
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // ---- 入口 ----
  input  wire          [      512*TYPE_NUM-1:0]        ipv4_axis_sdata ,
  input  wire          [       64*TYPE_NUM-1:0]        ipv4_axis_skeep ,
  input  wire          [          TYPE_NUM-1:0]        ipv4_axis_slast ,
  input  wire          [          TYPE_NUM-1:0]        ipv4_axis_svalid,
  input  wire          [AXIS_USER_WIDTH*TYPE_NUM-1:0]  ipv4_axis_susr  ,
  output wire          [          TYPE_NUM-1:0]        ipv4_axis_sready,

  // ---- 出口 ----
  output wire          [                 511:0]        ipv4_axis_mdata ,
  output wire          [                  63:0]        ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  output wire          [   AXIS_USER_WIDTH-1:0]        ipv4_axis_musr  ,
  input  wire                                          ipv4_axis_mready,

  // ---- 状态 ----
  output wire          [             IDX_W-1:0]        stat_active_port,
  output wire                                          stat_idle        
);

axis_nto1_by_val#(
    .NUM_PORTS        (TYPE_NUM         ),
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
    .axis_sdata       (ipv4_axis_sdata  ),// (input)
    .axis_skeep       (ipv4_axis_skeep  ),// (input)
    .axis_sid         ('d0              ),// (input)
    .axis_susr        (ipv4_axis_susr   ),// (input)
    .axis_svalid      (ipv4_axis_svalid ),// (input)
    .axis_slast       (ipv4_axis_slast  ),// (input)
    .axis_sready      (ipv4_axis_sready ),// (output)
// --- 1 路 Master 输出 ---
    .axis_mdata       (ipv4_axis_mdata  ),// (output)
    .axis_mkeep       (ipv4_axis_mkeep  ),// (output)
    .axis_mid         (                 ),// (output)
    .axis_musr        (ipv4_axis_musr   ),// (output)
    .axis_mvalid      (ipv4_axis_mvalid ),// (output)
    .axis_mlast       (ipv4_axis_mlast  ),// (output)
    .axis_mready      (ipv4_axis_mready ),// (input)
// --- 状态 / 调试 ---
    .stat_active_port (stat_active_port ),// (output)// 当前正在传输的端口号
    .stat_idle        (stat_idle        ) // (output)// 空闲状态指示
);

endmodule
`resetall
