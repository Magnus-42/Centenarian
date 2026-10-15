`resetall
`default_nettype none
`timescale 1ns/100ps
// ============================================================================
// File Name   : arp_cache.v
// Module Name : arp_cache
// Author      : LiXintao
// Date        : 2026-09-16
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 
// 
// ============================================================================

module arp_cache#(
  parameter  ITEM_WIDTH= 81,
  parameter  CACHE_DEEP= 1024,
  parameter  CACHE_ADDR_WIDTH= CACHE_DEEP == 1? 1 : $clog2(CACHE_DEEP),
  parameter  HASH_WAY_CNT= 4
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [      HASH_WAY_CNT-1: 0]            write_we          ,
  input  wire          [CACHE_ADDR_WIDTH*HASH_WAY_CNT-1: 0] write_addr        ,
  input  wire          [ITEM_WIDTH*HASH_WAY_CNT-1: 0]       write_din         ,

  input  wire          [      HASH_WAY_CNT-1: 0]            lookup_re       ,
  input  wire          [CACHE_ADDR_WIDTH*HASH_WAY_CNT-1: 0] lookup_addr     ,
  output wire          [ITEM_WIDTH*HASH_WAY_CNT-1: 0]       lookup_dout
);
genvar g_way_index;
generate
  for (g_way_index = 0; g_way_index < HASH_WAY_CNT; g_way_index = g_way_index + 1) begin : gen_arp_cache_bram
    sdp_bram#(
      .DATA_WIDTH       (ITEM_WIDTH               ),// valid+ip
      .DEEP             (CACHE_DEEP       ),
      .DO_REG           (1                ),
      .INIT_EN          (1                ),
      .INIT_USE_FILE    (0                ),
      .BYPASS_EN        (1                ) 
      )
      u_arp_cache_bram(
      // --- 存储参数 ---
      // --- 输出与初始化参数 ---
      .clk              (clk              ),// (input)
      .rst              (rst              ),// (input)
      // ============================================================================
      // A 写端口
      // ============================================================================
      .a_we             (write_we  [g_way_index]),// (input)
      .a_addr           (write_addr[g_way_index*CACHE_ADDR_WIDTH +: CACHE_ADDR_WIDTH]),// (input)
      .a_din            (write_din [g_way_index*ITEM_WIDTH +: ITEM_WIDTH]),// (input)
      // ============================================================================
      // B 读端口
      // ============================================================================
      .b_re             (lookup_re  [g_way_index]),// (input)
      .b_addr           (lookup_addr[g_way_index*CACHE_ADDR_WIDTH +: CACHE_ADDR_WIDTH]),// (input)
      .b_dout           (lookup_dout[g_way_index*ITEM_WIDTH +: ITEM_WIDTH]) // (output)
    );
  end
endgenerate
                                              
                                                                   
endmodule
`resetall
