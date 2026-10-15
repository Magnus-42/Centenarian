`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : arp_lookup.v
// Module Name : arp_lookup
// Author      : LiXintao
// Date        : 2026-09-16
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 
// 
// ============================================================================

module arp_lookup#(
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

  output wire          [      HASH_WAY_CNT-1: 0]       lookup_re       ,
  output wire          [CACHE_ADDR_WIDTH*HASH_WAY_CNT-1: 0]lookup_addr     ,
  input  wire          [ITEM_WIDTH*HASH_WAY_CNT-1: 0]  lookup_dout     ,

  input  wire                                          cfg_enable       
);

  localparam HASH_WAY_CNT_WIDTH= HASH_WAY_CNT == 1 ? 1 : $clog2(HASH_WAY_CNT);
// 第一级，对哈希结果打拍，原始输入进行缓存
// 第二级，读取RAM中的数据 s1
// 第三级，等待 s2
// 第四级，等待 s3
// 第五级，缓存输入，即使算条件 s4
// 第六级，输出结果 s5
  wire                 [                  31: 0]       ip_hash            ;
  reg                  [  CACHE_ADDR_WIDTH-1: 0]       ip_hash_s1,      ip_hash_s2,ip_hash_s3,ip_hash_s4,ip_hash_s5;
  reg                                                  query_valid_s1,  query_valid_s2,query_valid_s3,query_valid_s4,query_valid_s5;
  reg                  [                  31: 0]       query_ip_s1,     query_ip_s2,query_ip_s3,query_ip_s4,query_ip_s5;

  reg                                                  lookup_re_reg      ;
  reg                  [  CACHE_ADDR_WIDTH-1: 0]       lookup_addr_reg    ;

  reg                                                  lookup_valid_pulse_reg  ;
  reg                                                  lookup_miss_reg    ;
  reg                  [                  31: 0]       lookup_ip_reg      ;
  reg                  [                  47: 0]       lookup_mac_reg     ;

  reg                                                  match_comb         ;
  reg                  [HASH_WAY_CNT_WIDTH-1: 0]       match_way_index_comb  ;
  reg                  [                  47: 0]       match_mac_comb     ;

  // 流水线
  always @(posedge clk)begin
    if (rst || !cfg_enable) begin
      {query_valid_s5,query_valid_s4,query_valid_s3,query_valid_s2} <= 'd0;
    end
    else begin
      if (cfg_enable) begin
        {query_valid_s5,query_valid_s4,query_valid_s3,query_valid_s2}  <= {query_valid_s4,query_valid_s3,query_valid_s2,query_valid_s1};
      end
    end

    if (cfg_enable) begin
      {ip_hash_s5,ip_hash_s4,ip_hash_s3,ip_hash_s2}              <= {ip_hash_s4,ip_hash_s3,ip_hash_s2,ip_hash_s1};
      {query_ip_s5,query_ip_s4,query_ip_s3,query_ip_s2}           <= {query_ip_s4,query_ip_s3,query_ip_s2,query_ip_s1};
    end
  end

  // 第一级，对哈希结果打拍，原始输入进行缓存
  // ip_hash_s1
  always @(posedge clk)begin
    if (query_valid_pulse) begin
      ip_hash_s1 <= ip_hash[CACHE_ADDR_WIDTH-1:0];
    end
  end

  // query_valid_s1
  always @(posedge clk)begin
    if (rst) begin
      query_valid_s1 <= 'd0;
    end
    else begin
      if (query_valid_pulse && cfg_enable) begin
        query_valid_s1 <= query_valid_pulse;
      end
      else begin
        query_valid_s1 <= 'd0;
      end
    end
  end

  // query_ip_s1
  always @(posedge clk)begin
    if (query_valid_pulse && cfg_enable) begin
      query_ip_s1 <= query_ip;
    end
  end

  // 第二级，读取RAM中的数据 s1
  // lookup_re_reg
  always @(posedge clk)begin
    if(rst)begin
      lookup_re_reg <= 'd0;
    end
    else begin
      if (query_valid_s1) begin
        lookup_re_reg <= 1'b1;
      end
      else begin
        lookup_re_reg <= 1'b0;
      end
    end
  end

  // lookup_addr_reg
  always @(posedge clk)begin
    if(query_valid_s1)begin
      lookup_addr_reg <= ip_hash_s1;
    end
  end

  // 第三级，等待 s2
  // 第四级，等待 s3
  // 第五级，缓存输入，即使算条件 s4
  // 第六级，输出结果 s5

  // 静态优先级编码器
  integer                                              way_index          ;
  reg                  [ITEM_WIDTH*HASH_WAY_CNT-1: 0]  lookup_dout_reg    ;
  reg                  [      HASH_WAY_CNT-1: 0]       is_macth_onehot    ;

  always @(posedge clk)begin
    lookup_dout_reg <= lookup_dout;
    if (rst) begin
      is_macth_onehot <= 'd0;
    end
    else begin
      for (way_index = 0; way_index < HASH_WAY_CNT; way_index = way_index + 1) begin
        if (query_valid_s4) begin
          is_macth_onehot[way_index] <= lookup_dout[way_index*ITEM_WIDTH + ITEM_WIDTH-1 -:33] == {1'b1,query_ip_s4};
        end
      end
    end
  end

  always @(*) begin
    match_comb = 1'b0;
    match_way_index_comb = 'd0;
    match_mac_comb = 'd0;

    for (way_index = 0; way_index < HASH_WAY_CNT; way_index = way_index + 1) begin
      if (is_macth_onehot[way_index]) begin                         // valid+ip
        match_comb = 1'b1;
        match_way_index_comb = way_index;
        match_mac_comb = lookup_dout_reg[way_index*ITEM_WIDTH +: 48];
      end
    end
  end

  // lookup_valid_pulse_reg
  always @(posedge clk)begin
    if(rst)begin
      lookup_valid_pulse_reg <= 'd0;
    end
    else begin
      if (query_valid_s5 && cfg_enable) begin
        lookup_valid_pulse_reg <= 1'b1;
      end
      else begin
        lookup_valid_pulse_reg <= 1'b0;
      end
    end
  end

  // lookup_miss_reg
  always @(posedge clk)begin
    if (rst) begin
      lookup_miss_reg <= 'd0;
    end
    else begin
      if (query_valid_s5 && cfg_enable) begin
        lookup_miss_reg <= ~match_comb;
      end
      else begin
        lookup_miss_reg <= 'd0;
      end
    end
  end

  // lookup_ip_reg
  always @(posedge clk)begin
    if (query_valid_s5) begin
      lookup_ip_reg <= query_ip_s5;
    end
  end

  // lookup_mac_reg
  always @(posedge clk)begin
    if (query_valid_s5) begin
      lookup_mac_reg <= match_mac_comb;
    end
  end

  lfsr#(
    .LFSR_WIDTH       (32               ),
    .LFSR_POLY        (32'h4c11db7      ),
    .LFSR_CONFIG      ("GALOIS"         ),
    .REVERSE          (1                ),
    .DATA_WIDTH       (32               ),
    .STYLE            ("AUTO"           ) 
  )
  u_lfsr(
    .data_in          (query_ip         ),// (input)
    .state_in         (32'hFFFFFFFF     ),// (input)
    .data_out         (                 ),// (output)// 加扰后输出
    .state_out        (ip_hash          ) // (output)
  );

  assign  lookup_valid_pulse= lookup_valid_pulse_reg;
  assign  lookup_miss      = lookup_miss_reg  ;
  assign  lookup_ip        = lookup_ip_reg    ;
  assign  lookup_mac       = lookup_mac_reg   ;
  assign  lookup_re        = {HASH_WAY_CNT{lookup_re_reg}};
  assign  lookup_addr      = {HASH_WAY_CNT{lookup_addr_reg}};

endmodule
`resetall