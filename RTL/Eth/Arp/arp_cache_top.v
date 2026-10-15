`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : arp_cache_top.v
// Module Name : arp_cache_top
// Author      : LiXintao
// Date        : 2026-09-14
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 
// 
// ============================================================================

module arp_cache_top#(
  parameter  ITEM_WIDTH= 81, // valid+mac+ip(81bit)
  parameter  CACHE_DEEP= 1024,
  parameter  CACHE_ADDR_WIDTH= CACHE_DEEP == 1? 1 : $clog2(CACHE_DEEP),
  parameter  HASH_WAY_CNT= 4 
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // query
  input  wire                                          query_valid_pulse,
  input  wire          [                  31: 0]       query_ip        ,

  // output
  output wire                                          lookup_valid_pulse,
  output wire                                          lookup_miss     ,
  output wire          [                  31: 0]       lookup_ip       ,
  output wire          [                  47: 0]       lookup_mac      ,

  input  wire                                          write_valid_pulse,
  input  wire          [                  31: 0]       write_ip        ,
  input  wire          [                  47: 0]       write_mac       ,

  // cfg
  input  wire                                          cfg_clear       ,

  output wire                                          stat_clear_finish 
);

  wire                 [      HASH_WAY_CNT-1: 0]       lookup_re          ;
  wire                 [CACHE_ADDR_WIDTH*HASH_WAY_CNT-1: 0]lookup_addr        ;
  wire                 [ITEM_WIDTH*HASH_WAY_CNT-1: 0]  lookup_dout        ;

  wire                 [      HASH_WAY_CNT-1: 0]       write_we           ;
  wire                 [CACHE_ADDR_WIDTH*HASH_WAY_CNT-1: 0]write_addr         ;
  wire                 [ITEM_WIDTH*HASH_WAY_CNT-1: 0]  write_din          ;
  wire                                                 clear_finish       ;

arp_cache#(
    .ITEM_WIDTH       (ITEM_WIDTH       ),
    .CACHE_DEEP       (CACHE_DEEP       ),
    .CACHE_ADDR_WIDTH (CACHE_ADDR_WIDTH ),
    .HASH_WAY_CNT     (HASH_WAY_CNT     ) 
)
 u_arp_cache(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .write_we         (write_we         ),// (input)
    .write_addr       (write_addr       ),// (input)
    .write_din        (write_din        ),// (input)
    .lookup_re        (lookup_re        ),// (input)
    .lookup_addr      (lookup_addr      ),// (input)
    .lookup_dout      (lookup_dout      ) // (output)
);

arp_write#(
    .ITEM_WIDTH       (ITEM_WIDTH       ),
    .CACHE_DEEP       (CACHE_DEEP       ),
    .CACHE_ADDR_WIDTH (CACHE_ADDR_WIDTH ),
    .HASH_WAY_CNT     (HASH_WAY_CNT     ) 
)
 u_arp_write(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .write_valid_pulse(write_valid_pulse),// (input)
    .write_ip         (write_ip         ),// (input)
    .write_mac        (write_mac        ),// (input)
    .write_we         (write_we         ),// (output)
    .write_addr       (write_addr       ),// (output)
    .write_din        (write_din        ),// (output)

    .cfg_clear        (cfg_clear        ),// (input)
    .stat_clear_finish(clear_finish     ) 
);


arp_lookup#(
    .ITEM_WIDTH       (ITEM_WIDTH       ),
    .CACHE_DEEP       (CACHE_DEEP       ),
    .CACHE_ADDR_WIDTH (CACHE_ADDR_WIDTH ),
    .HASH_WAY_CNT     (HASH_WAY_CNT     ) 
)
 u_arp_lookup(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
// query
    .query_valid_pulse(query_valid_pulse),// (input)
    .query_ip         (query_ip         ),// (input)
// output
    .lookup_valid_pulse(lookup_valid_pulse),// (output)
    .lookup_miss      (lookup_miss      ),// (output)
    .lookup_ip        (lookup_ip        ),// (output)
    .lookup_mac       (lookup_mac       ),// (output)
    .lookup_re        (lookup_re        ),// (output)
    .lookup_addr      (lookup_addr      ),// (output)
    .lookup_dout      (lookup_dout      ),// (input)
    .cfg_enable       (clear_finish  && (~cfg_clear)) // (input)
);

  assign  stat_clear_finish= clear_finish     ;

endmodule
`resetall
