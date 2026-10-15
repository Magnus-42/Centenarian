`resetall
`default_nettype none
`timescale 1ns/100ps
// Language: Verilog 2001
// ============================================================================
// File Name   : arp_pending_lookup.v
// Module Name : arp_pending_lookup
// Author      : LiXintao
// Date        : 2026-09-15
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 8级流水，如果单拍ARP，最多同时突发8次，若数据包长度>=4（passby），则只会突发一次
// 
// ============================================================================

module arp_pending_ctrl#(
  parameter  ITEM_WIDTH= 90, // valid+ip+time=1+32+57
  parameter  CACHE_DEEP= 1024,
  parameter  CACHE_ADDR_WIDTH= CACHE_DEEP == 1? 1 : $clog2(CACHE_DEEP),
  parameter  HASH_WAY_CNT= 4 ,
  parameter  TIME_WIDTH= 57
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire                                          req_valid_pulse ,
  input  wire          [                  31: 0]       req_ip          ,

  output wire                                          permit_valid_pulse,
  output wire                                          permit_miss     ,
  output wire          [                  31: 0]       permit_ip       ,

  input  wire          [        TIME_WIDTH-1: 0]       cfg_pending_time,
  input  wire                                          cfg_clear       ,

  output wire                                          stat_clear_finish 
);

  localparam HASH_WAY_CNT_WIDTH= HASH_WAY_CNT == 1 ? 1 : $clog2(HASH_WAY_CNT);

  reg                  [        TIME_WIDTH-1: 0]       time_base_reg      ;

  reg                  [  CACHE_ADDR_WIDTH-1: 0]       lookup_addr_reg    ;
  reg                                                  lookup_re_reg      ;
  wire                 [ITEM_WIDTH*HASH_WAY_CNT-1: 0]  lookup_dout        ;

  reg                  [      HASH_WAY_CNT-1: 0]       write_we_full_reg  ;
  reg                  [      HASH_WAY_CNT-1: 0]       write_we_full_random  ;
  reg                  [  CACHE_ADDR_WIDTH-1: 0]       write_addr_reg     ;
  reg                  [        ITEM_WIDTH-1: 0]       write_din_reg      ;

  reg                                                  permit_valid_pulse_reg  ;
  reg                                                  permit_miss_reg    ;
  reg                  [                  31: 0]       permit_ip_reg      ;

  wire                 [                  31: 0]       ip_hash            ;
  reg                  [  CACHE_ADDR_WIDTH-1: 0]       ip_hash_s1,      ip_hash_s2,ip_hash_s3,ip_hash_s4,ip_hash_s5,ip_hash_s6,ip_hash_s7;
  reg                                                  req_valid_pulse_s1,req_valid_pulse_s2,req_valid_pulse_s3,req_valid_pulse_s4,req_valid_pulse_s5,req_valid_pulse_s6,req_valid_pulse_s7  ;
  reg                  [                  31: 0]       req_ip_s1,req_ip_s2,req_ip_s3,req_ip_s4,req_ip_s5,req_ip_s6,req_ip_s7  ;

  reg                                                  match_comb         ;
  reg                  [HASH_WAY_CNT_WIDTH-1: 0]       match_way_index_comb  ;
  reg                                                  empty_comb         ;
  reg                  [HASH_WAY_CNT_WIDTH-1: 0]       empty_way_index_comb  ;
  reg                  [        TIME_WIDTH-1: 0]       match_time_comb    ;
   
  reg                                                  clear_finish       ;
  reg                  [  CACHE_ADDR_WIDTH-1: 0]       clear_addr_reg     ;

  reg                                                 is_timeout         ;

  // 计算hash
  // 读取
  // 等待1
  // 等待2
  // 缓存输入，计算条件
  // 计算结果
  // 计算超时
  // 输出/写入

  // clear_addr_reg
  always @(posedge clk) begin
    if (cfg_clear || rst) begin
      clear_addr_reg <= 'd0;
    end
    else begin
      clear_addr_reg <= clear_addr_reg + 1'b1;
    end
  end

  // clear_finish
  always @(posedge clk)begin
    if (rst || cfg_clear) begin
      clear_finish <= 'd0;
    end
    else begin
      if (clear_addr_reg == {CACHE_ADDR_WIDTH{1'b1}}) begin
        clear_finish <= 1'b1;
      end
    end
  end

  // time_base_reg
  always @(posedge clk) begin
    if (rst || cfg_clear) begin
        time_base_reg <= 'd0;
    end
    else begin
        time_base_reg <= time_base_reg + 1'b1;
    end
  end

  // 流水线
  always @(posedge clk)begin
    if (rst || !clear_finish) begin
      {req_valid_pulse_s7,req_valid_pulse_s6,req_valid_pulse_s5,req_valid_pulse_s4,req_valid_pulse_s3,req_valid_pulse_s2} <= 'd0;
    end
    else begin
      if (clear_finish) begin
        {req_valid_pulse_s7,req_valid_pulse_s6,req_valid_pulse_s5,req_valid_pulse_s4,req_valid_pulse_s3,req_valid_pulse_s2} <= {req_valid_pulse_s6,req_valid_pulse_s5,req_valid_pulse_s4,req_valid_pulse_s3,req_valid_pulse_s2,req_valid_pulse_s1};
      end
    end

    if (clear_finish) begin
      {ip_hash_s7,ip_hash_s6,ip_hash_s5,ip_hash_s4,ip_hash_s3,ip_hash_s2} <= {ip_hash_s6,ip_hash_s5,ip_hash_s4,ip_hash_s3,ip_hash_s2,ip_hash_s1};
      {req_ip_s7,req_ip_s6,req_ip_s5,req_ip_s4,req_ip_s3,req_ip_s2} <= {req_ip_s6,req_ip_s5,req_ip_s4,req_ip_s3,req_ip_s2,req_ip_s1};
    end
  end

  // 第一级，对哈希结果打拍，原始输入进行缓存
  // ip_hash_s1
  always @(posedge clk)begin
    if (req_valid_pulse) begin
      ip_hash_s1 <= ip_hash[CACHE_ADDR_WIDTH-1:0];
    end
  end

  // req_valid_pulse_s1
  always @(posedge clk)begin
    if (rst) begin
      req_valid_pulse_s1 <= 'd0;
    end
    else begin
      if (req_valid_pulse && clear_finish) begin
        req_valid_pulse_s1 <= req_valid_pulse;
      end
      else begin
        req_valid_pulse_s1 <= 'd0;
      end
    end
  end

  // req_ip_s1
  always @(posedge clk)begin
    if (req_valid_pulse && clear_finish) begin
      req_ip_s1 <= req_ip;
    end
  end

  // 第二级，读取RAM中的数据 s1
  // lookup_re_reg
  always @(posedge clk)begin
    if(rst)begin
      lookup_re_reg <= 'd0;
    end
    else begin
      if (req_valid_pulse_s1) begin
        lookup_re_reg <= 1'b1;
      end
      else begin
        lookup_re_reg <= 1'b0;
      end
    end
  end

  // lookup_addr_reg
  always @(posedge clk)begin
    if(req_valid_pulse_s1)begin
      lookup_addr_reg <= ip_hash_s1;
    end
  end

  // 第三级，等待 s2
  // 第四级，等待 s3
  // 第五级，缓存输出，计算条件 s4
  // 第六级，计算结果 s5
  // 第七级，计算超时 s6
  // 第八级，输出结果 s7
  // 静态优先级编码器
  reg [ITEM_WIDTH*HASH_WAY_CNT-1: 0] lookup_dout_reg ;
  reg [HASH_WAY_CNT-1:0] is_match_one_hot;
  reg [HASH_WAY_CNT-1:0] is_empty_one_hot;
  integer                                              way_index          ;

  // lookup_dout_reg is_match_one_hot is_empty_one_hot
  always @(posedge clk)begin
    lookup_dout_reg <= lookup_dout;
    if (rst) begin
      is_empty_one_hot <= 'd0;
      is_match_one_hot <= 'd0;
    end
    else begin
      for (way_index = 0; way_index < HASH_WAY_CNT; way_index = way_index + 1) begin
        is_match_one_hot[way_index] <= lookup_dout[way_index*ITEM_WIDTH+ITEM_WIDTH-1 -: 33] ==  {1'b1,req_ip_s4};
        is_empty_one_hot[way_index] <= lookup_dout[way_index*ITEM_WIDTH+ITEM_WIDTH-1] == 1'b0;
      end
    end
  end

  
  always @(*) begin
    match_comb = 1'b0;
    match_way_index_comb = 'd0;
    match_time_comb = 'd0;
    empty_comb = 1'b0;
    empty_way_index_comb = 'd0;

    for (way_index = 0; way_index < HASH_WAY_CNT; way_index = way_index + 1) begin
      if (is_match_one_hot[way_index]) begin// valid+ip
        match_comb = 1'b1;
        match_way_index_comb = way_index;
        match_time_comb = lookup_dout_reg[way_index*ITEM_WIDTH+: TIME_WIDTH];
      end
      if (is_empty_one_hot[way_index]) begin// valid
        empty_comb = 1'b1;
        empty_way_index_comb = way_index;
      end
    end
  end

  reg match_s6,match_s7;
  reg [HASH_WAY_CNT_WIDTH-1: 0] match_way_index_s6,match_way_index_s7;
  reg [ TIME_WIDTH-1: 0]  match_time_s6,match_time_s7;
  reg empty_s6,empty_s7;
  reg [HASH_WAY_CNT_WIDTH-1: 0] empty_way_index_s6,empty_way_index_s7;

  always @(posedge clk) begin                                        
    if(rst) begin
      match_s6 <= 0;
      empty_s6 <= 0;
    end
    else begin
      if (req_valid_pulse_s5) begin
        match_s6 <= match_comb;
        match_way_index_s6 <= match_way_index_comb;
        match_time_s6 <= match_time_comb;
        empty_s6 <= empty_comb;
        empty_way_index_s6 <= empty_way_index_comb;
      end
      else begin
        match_s6 <= 0;
        empty_s6 <= 0;
      end
    end
  end

  always @(posedge clk) begin                                        
    if(rst) begin
      match_s7 <= 0;
      empty_s7 <= 0;
    end
    else begin
      match_s7 <= match_s6;
      match_way_index_s7 <= match_way_index_s6;
      match_time_s7 <= match_time_s6;
      empty_s7 <= empty_s6;
      empty_way_index_s7 <= empty_way_index_s6;
    end
  end


  // write_we_full_random
  always @(posedge clk) begin
    if (rst) begin
      write_we_full_random <= 'd1;
    end
    else begin
      write_we_full_random <= {write_we_full_random[HASH_WAY_CNT-2:0],write_we_full_random[HASH_WAY_CNT-1]};
    end
  end

  // is_timeout
  always @(posedge clk)begin
    if(rst)begin
      is_timeout <= 1'b0;
    end
    else begin
      is_timeout <= (time_base_reg - match_time_s6) >= cfg_pending_time;
    end
  end

  // write_we_full_reg
  always @(posedge clk)begin
    if(rst)begin
      write_we_full_reg <= 'd0;
    end
    else begin
      if (~clear_finish) begin
        write_we_full_reg <= {HASH_WAY_CNT{1'b1}};
      end
      else if(req_valid_pulse_s7) begin
        if(match_s7)begin
          if (is_timeout) begin
            write_we_full_reg <= 'b1 << match_way_index_s7;       // 更新
          end
          else begin
            write_we_full_reg <= 'd0;                               // 忽略
          end
        end
        else if(empty_s7) begin
          write_we_full_reg <= 'b1 << empty_way_index_s7;         // 插入
        end
        else begin
          write_we_full_reg <= write_we_full_random;                // 随机插入
        end
      end
      else begin
        write_we_full_reg <= 1'b0;
      end
    end
  end

  // write_addr_reg
  always @(posedge clk)begin
    if(req_valid_pulse_s7 && clear_finish)begin
      write_addr_reg <= ip_hash_s7;
    end
    else begin
      write_addr_reg <= clear_addr_reg;
    end
  end

  // write_din_reg
  always @(posedge clk)begin
    if(req_valid_pulse_s7 && clear_finish)begin
      write_din_reg <= {1'b1,req_ip_s7,time_base_reg};
    end
    else begin
      write_din_reg <= 'd0;
    end
  end


  // permit_valid_pulse_reg
  always @(posedge clk)begin
    if(req_valid_pulse_s7)begin
      permit_valid_pulse_reg <= 1'b1;
    end
    else begin
      permit_valid_pulse_reg <= 'd0;
    end
  end

  // permit_miss_reg
  always @(posedge clk)begin
    if(req_valid_pulse_s7)begin
      permit_miss_reg <= ~is_timeout && match_s7;
    end
  end

  // permit_ip_reg
  always @(posedge clk)begin
    if(req_valid_pulse_s7)begin
      permit_ip_reg <= req_ip_s7;
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
    .data_in          (req_ip           ),// (input)
    .state_in         (32'hFFFFFFFF     ),// (input)
    .data_out         (                 ),// (output)// 加扰后输出
    .state_out        (ip_hash          ) // (output)
  );


genvar g_way_index;
generate
  for (g_way_index = 0; g_way_index < HASH_WAY_CNT; g_way_index = g_way_index + 1) begin : gen_pending_cache_bram
    sdp_bram#(
    .DATA_WIDTH       (ITEM_WIDTH       ),
    .DEEP             (CACHE_DEEP       ),
    .DEEP_WIDTH       (CACHE_ADDR_WIDTH ),
    .DO_REG           (1                ),
    .INIT_EN          (1                ),
    .INIT_USE_FILE    (0                ),
    .BYPASS_EN        (1                ) 
    )
    u_pending_cache_bram(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
  // ============================================================================
  // A 写端口
  // ============================================================================
    .a_we             (write_we_full_reg[g_way_index]),// (input)
    .a_addr           (write_addr_reg   ),// (input)
    .a_din            (write_din_reg    ),// (input)
  // ============================================================================
  // B 读端口
  // ============================================================================
    .b_re             (lookup_re_reg    ),// (input)
    .b_addr           (lookup_addr_reg  ),// (input)
    .b_dout           (lookup_dout[g_way_index*ITEM_WIDTH +: ITEM_WIDTH]) // (output)
    );

  end
endgenerate

  assign  stat_clear_finish= clear_finish     ;

  assign  permit_valid_pulse= permit_valid_pulse_reg;
  assign  permit_miss      = permit_miss_reg      ;
  assign  permit_ip        = permit_ip_reg    ;

endmodule
`resetall
