`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : arp_write.v
// Module Name : arp_write
// Author      : LiXintao
// Date        : 2026-09-16
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持流水线 
// Note        : 写表在第 s5+1 拍落地，但影子表的读在第 s1+1 拍发起，若出现两拍哈希碰撞的
//               临近IP，则后一拍会覆盖前一拍IP，低概率事件，重新请求ARP后可以解决。
// 
// ============================================================================

module arp_write#(
  parameter  ITEM_WIDTH= 81, // valid+mac+ip(81bit)
  parameter  CACHE_DEEP= 1024,
  parameter  CACHE_ADDR_WIDTH= CACHE_DEEP == 1? 1 : $clog2(CACHE_DEEP),
  parameter  HASH_WAY_CNT= 4 
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire                                          write_valid_pulse,
  input  wire          [                  31: 0]       write_ip        ,
  input  wire          [                  47: 0]       write_mac       ,

  output wire          [      HASH_WAY_CNT-1: 0]       write_we        ,
  output wire          [CACHE_ADDR_WIDTH*HASH_WAY_CNT-1: 0]write_addr      ,
  output wire          [ITEM_WIDTH*HASH_WAY_CNT-1: 0]  write_din       ,

  input  wire                                          cfg_clear       ,

  output wire                                          stat_clear_finish 
);
  localparam HASH_WAY_CNT_WIDTH= HASH_WAY_CNT == 1 ? 1 : $clog2(HASH_WAY_CNT);

  wire                 [                  31: 0]       ip_hash            ;
  reg                  [  CACHE_ADDR_WIDTH-1: 0]       ip_hash_s1,      ip_hash_s2,ip_hash_s3,ip_hash_s4,ip_hash_s5;
  reg                                                  write_valid_pulse_s1,write_valid_pulse_s2,write_valid_pulse_s3,write_valid_pulse_s4,write_valid_pulse_s5  ;
  reg                  [                  31: 0]       write_ip_s1,     write_ip_s2,write_ip_s3,write_ip_s4,write_ip_s5;
  reg                  [                  47: 0]       write_mac_s1,    write_mac_s2,write_mac_s3,write_mac_s4,write_mac_s5;

  reg                  [      HASH_WAY_CNT-1: 0]       write_we_full_reg  ;
  reg                  [      HASH_WAY_CNT-1: 0]       write_we_full_reg_random  ;
  reg                  [  CACHE_ADDR_WIDTH-1: 0]       write_addr_reg     ;
  reg                  [        ITEM_WIDTH-1: 0]       write_din_reg      ;
  reg                                                  read_re_reg        ;
  reg                  [  CACHE_ADDR_WIDTH-1: 0]       read_addr_reg      ;
  wire                 [   33*HASH_WAY_CNT-1: 0]       read_dout          ;
  reg                  [                  32: 0]       write_shadow_din_reg  ;

  reg                                                  match_comb         ;
  reg                  [HASH_WAY_CNT_WIDTH-1: 0]       match_way_index_comb  ;
  reg                                                  empty_comb         ;
  reg                  [HASH_WAY_CNT_WIDTH-1: 0]       empty_way_index_comb  ;

  reg                                                  clear_finish       ;
  reg                  [  CACHE_ADDR_WIDTH-1: 0]       clear_addr_reg     ;

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

  // 流水线
  always @(posedge clk)begin
    if (rst || !clear_finish) begin
      {write_valid_pulse_s5,write_valid_pulse_s4,write_valid_pulse_s3,write_valid_pulse_s2} <= 'd0;
    end
    else begin
      if (clear_finish) begin
        {write_valid_pulse_s5,write_valid_pulse_s4,write_valid_pulse_s3,write_valid_pulse_s2} <= {write_valid_pulse_s4,write_valid_pulse_s3,write_valid_pulse_s2,write_valid_pulse_s1};
      end
    end

    if (clear_finish) begin
      {ip_hash_s5,ip_hash_s4,ip_hash_s3,ip_hash_s2} <= {ip_hash_s4,ip_hash_s3,ip_hash_s2,ip_hash_s1};
      {write_ip_s5,write_ip_s4,write_ip_s3,write_ip_s2} <= {write_ip_s4,write_ip_s3,write_ip_s2,write_ip_s1};
      {write_mac_s5,write_mac_s4,write_mac_s3,write_mac_s2} <= {write_mac_s4,write_mac_s3,write_mac_s2,write_mac_s1};
    end
  end

  // 第一级，对哈希结果打拍，原始输入进行缓存
  // ip_hash_s1
  always @(posedge clk)begin
    if (write_valid_pulse) begin
      ip_hash_s1 <= ip_hash[CACHE_ADDR_WIDTH-1:0];
    end
  end
  
  // write_valid_pulse_s1
  always @(posedge clk)begin
    if (rst) begin
      write_valid_pulse_s1 <= 'd0;
    end
    else begin
      if (write_valid_pulse && clear_finish) begin
        write_valid_pulse_s1 <= write_valid_pulse;
      end
      else begin
        write_valid_pulse_s1 <= 'd0;
      end
    end
  end

  // write_ip_s1 write_mac_s1
  always @(posedge clk)begin
    if (write_valid_pulse && clear_finish) begin
      write_ip_s1 <= write_ip;
      write_mac_s1 <= write_mac;
    end
  end

  // 第二级，读取影子RAM中的数据 s1
  // read_re_reg
  always @(posedge clk)begin
    if(rst)begin
      read_re_reg <= 'd0;
    end
    else begin
      if (write_valid_pulse_s1) begin
        read_re_reg <= 1'b1;
      end
      else begin
        read_re_reg <= 1'b0;
      end
    end
  end

  // read_addr_reg
  always @(posedge clk)begin
    if(write_valid_pulse_s1)begin
      read_addr_reg <= ip_hash_s1;
    end
  end

  // 第三级，等待 s2
  // 第四级，等待 s3
  // 第五级，计算判断 s4 
  // 第六级，匹配、分配空位，更新/插入 s5

  // 静态优先级编码器
  integer                                              way_index          ;

  reg [ HASH_WAY_CNT-1: 0]  is_match_onehot;
  reg [ HASH_WAY_CNT-1: 0]  is_empty_onehot;

  always @(posedge clk)begin
    if(rst)begin
      is_match_onehot <= 'd0;
      is_empty_onehot <= 'd0;
    end
    else begin
      for (way_index = 0; way_index < HASH_WAY_CNT; way_index = way_index + 1) begin
        is_match_onehot[way_index] <= read_dout[way_index*33 +: 33] == {1'b1,write_ip_s4};
        is_empty_onehot[way_index] <= read_dout[way_index*33+33-1] == 1'b0;
      end
    end
  end


  always @(*) begin
    match_comb = 1'b0;
    match_way_index_comb = 'd0;
    empty_comb = 1'b0;
    empty_way_index_comb = 'd0;

    for (way_index = 0; way_index < HASH_WAY_CNT; way_index = way_index + 1) begin
      if (is_match_onehot[way_index]) begin// valid+ip
        match_comb = 1'b1;
        match_way_index_comb = way_index;
      end
      if (is_empty_onehot[way_index]) begin               // // valid
        empty_comb = 1'b1;
        empty_way_index_comb = way_index;
      end
    end
  end

  // write_we_full_reg_random
  always @(posedge clk) begin
    if (rst) begin
      write_we_full_reg_random <= 'd1;
    end
    else begin
      write_we_full_reg_random <= {write_we_full_reg_random[HASH_WAY_CNT-2:0],write_we_full_reg_random[HASH_WAY_CNT-1]};
    end
  end

  // write_we_full_reg
  always @(posedge clk)begin
    if(rst)begin
      write_we_full_reg <= 'd0;
    end
    else begin
      if (write_valid_pulse_s5 && clear_finish) begin
        if (match_comb) begin
          write_we_full_reg <= 'b1 << match_way_index_comb;         // 更新
        end
        else if (empty_comb) begin
          write_we_full_reg <= 'b1 << empty_way_index_comb;         // 插入
        end
        else begin
          write_we_full_reg <= write_we_full_reg_random;            // 随机插入
        end
      end
      else if (clear_finish) begin
        write_we_full_reg <= 'd0;
      end
      else begin
        write_we_full_reg <= {HASH_WAY_CNT{1'b1}};
      end
    end
  end

  // write_addr_reg
  always @(posedge clk)begin
    if(write_valid_pulse_s5 && clear_finish)begin
      write_addr_reg <= ip_hash_s5;
    end
    else begin
      write_addr_reg <= clear_addr_reg;
    end
  end

  // write_din_reg
  always @(posedge clk)begin
    if(write_valid_pulse_s5 && clear_finish)begin
      write_din_reg <= {1'b1,write_ip_s5,write_mac_s5};
    end
    else begin
      write_din_reg <= 'd0;
    end
  end

  // write_shadow_din_reg
  always @(posedge clk)begin
    if(write_valid_pulse_s5 && clear_finish)begin
      write_shadow_din_reg <= {1'b1,write_ip_s5};
    end
    else begin
      write_shadow_din_reg <= 'd0;
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
    .data_in          (write_ip         ),// (input)
    .state_in         (32'hFFFFFFFF     ),// (input)
    .data_out         (                 ),// (output)// 加扰后输出
    .state_out        (ip_hash          ) // (output)
  );

genvar g_way_index;
generate
  for (g_way_index = 0; g_way_index < HASH_WAY_CNT; g_way_index = g_way_index + 1) begin : gen_shadow_bram
    sdp_bram#(
    .DATA_WIDTH       (33               ),// valid+ip
    .DEEP             (CACHE_DEEP       ),
    .DO_REG           (1                ),
    .INIT_EN          (1                ),
    .INIT_USE_FILE    (0                ),
    .BYPASS_EN        (1                ) 
    ) u_sdp_bram(
    // --- 存储参数 ---
    // --- 输出与初始化参数 ---
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    // ============================================================================
    // A 写端口
    // ============================================================================
    .a_we             (write_we_full_reg[g_way_index]),// (input)
    .a_addr           (write_addr_reg   ),// (input)
    .a_din            (write_shadow_din_reg),// (input)
    // ============================================================================
    // B 读端口
    // ============================================================================
    .b_re             (read_re_reg      ),// (input)
    .b_addr           (read_addr_reg    ),// (input)
    .b_dout           (read_dout[g_way_index*33 +: 33]) // (output)
    );
  end
endgenerate

  assign  write_we         = write_we_full_reg;
  assign  write_addr       = {HASH_WAY_CNT{write_addr_reg}};
  assign  write_din        = {HASH_WAY_CNT{write_din_reg}};
  assign  stat_clear_finish= clear_finish     ;
endmodule
`resetall
