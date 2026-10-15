`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : arp_engine_top.v
// Module Name : arp_engine_top
// Author      : LiXintao
// Date        : 2026-09-14
// Version     : 2.0
// ----------------------------------------------------------------------------
// Description : 支持流水线query_dst_ip,流水线深度为10，会在请求后的第10拍获得结果
//               支持多IP、MAC、子网和网关设计
// 
// ============================================================================

module arp_engine_top#(
  parameter  AXIS_WIDTH= 512,
  parameter  CACHE_ITEM_WIDTH= 81, // valid+mac+ip(81bit)
  parameter  CACHE_DEEP= 1024,
  parameter  CACHE_ADDR_WIDTH= CACHE_DEEP == 1? 1 : $clog2(CACHE_DEEP),
  parameter  PENDING_ITEM_WIDTH= 90,
  parameter  PENDING_DEEP= 1024,
  parameter  PENDING_ADDR_WIDTH= PENDING_DEEP == 1? 1 : $clog2(PENDING_DEEP),
  parameter  PENDING_TIME_WIDTH= 57, // 57位，10年以上
  parameter  HASH_WAY_CNT= 4,
  parameter  LOCAL_IP_NUM = 1,
  parameter  AXIS_TX_USR_WID = 4,
  parameter  ARP_PRIORITY = 15
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // eth_arp_query
  input  wire          [                  31: 0]       query_src_ip    ,
  input  wire          [                  31: 0]       query_dst_ip    ,
  input  wire                                          query_valid_pulse,
  output wire          [                  47: 0]       arp_dst_mac     ,
  output wire          [                  47: 0]       arp_src_mac     ,
  output wire                                          arp_miss        ,
  output wire                                          arp_valid       ,

  // eth_arp axis in
  input  wire          [        AXIS_WIDTH-1: 0]       arp_axis_sdata  ,
  input  wire          [      AXIS_WIDTH/8-1: 0]       arp_axis_skeep  ,
  input  wire                                          arp_axis_svalid ,
  input  wire                                          arp_axis_slast  ,
  input  wire                                          arp_axis_susr   ,
  output wire                                          arp_axis_sready ,

  // eth_arp axis out
  output wire          [        AXIS_WIDTH-1: 0]       arp_axis_mdata  ,
  output wire          [      AXIS_WIDTH/8-1: 0]       arp_axis_mkeep  ,
  output wire                                          arp_axis_mvalid ,
  output wire                                          arp_axis_mlast  ,
  output wire          [   AXIS_TX_USR_WID-1: 0]       arp_axis_musr   ,
  input  wire                                          arp_axis_mready ,

  // cfg
  input  wire          [   32*LOCAL_IP_NUM-1: 0]       cfg_local_ip    ,
  input  wire          [   48*LOCAL_IP_NUM-1: 0]       cfg_local_mac   ,
  input  wire          [   32*LOCAL_IP_NUM-1: 0]       cfg_gateway_ip  ,
  input  wire          [   32*LOCAL_IP_NUM-1: 0]       cfg_subnet_mask ,

  input  wire          [PENDING_TIME_WIDTH-1: 0]       cfg_pending_time,
  input  wire                                          cfg_clear_cache ,// 上游需要能缓存CACHE_DEEP周期
  input  wire                                          cfg_clear_pending,// FIFO需要能缓存PENDING_DEEP周期

  // stat
  output wire                                          stat_rx_error   ,// 收到非标准 ARP 帧(锁存, rst 清零)
  output wire                                          stat_ack_fifo_overflow_error,// ack FIFO 满时写被丢弃(锁存)
  output wire                                          stat_pending_fifo_overflow_error,// pending FIFO 满时写被丢弃(锁存)
  output wire                                          stat_lookup_no_resp_error,// 查询周期已到但没有查表结果(锁存)
  output wire                                          stat_pending_clear_finish, // pending 表清零完成
  output wire                                          stat_cache_clear_finish,
  output wire                                          stat_query_src_not_local
);
  wire                                                 arp_rx_frame_valid  ;
  wire                                                 arp_rx_frame_ready  ;
  wire                 [                  47: 0]       eth_rx_dest_mac    ;
  wire                 [                  47: 0]       eth_rx_src_mac     ;
  wire                 [                  15: 0]       eth_rx_type        ;
  wire                 [                  15: 0]       arp_rx_htype       ;
  wire                 [                  15: 0]       arp_rx_ptype       ;
  wire                 [                   7: 0]       arp_rx_hlen        ;
  wire                 [                   7: 0]       arp_rx_plen        ;
  wire                 [                  15: 0]       arp_rx_oper        ;
  wire                 [                  47: 0]       arp_rx_sha         ;
  wire                 [                  31: 0]       arp_rx_spa         ;
  wire                 [                  47: 0]       arp_rx_tha         ;
  wire                 [                  31: 0]       arp_rx_tpa         ;
  wire                                                 arp_rx_error_pulse  ;// arp_eth_rx 解析失败脉冲(非标准 ARP 帧)

  wire                                                 arp_tx_frame_valid  ;
  wire                                                 arp_tx_frame_ready  ;
  wire                 [                  47: 0]       eth_tx_dest_mac    ;
  wire                 [                  47: 0]       eth_tx_src_mac     ;
  wire                 [                  15: 0]       eth_tx_type        ;
  wire                 [                  15: 0]       arp_tx_htype       ;
  wire                 [                  15: 0]       arp_tx_ptype       ;
  wire                 [                   7: 0]       arp_tx_hlen        ;
  wire                 [                   7: 0]       arp_tx_plen        ;
  wire                 [                  15: 0]       arp_tx_oper        ;
  wire                 [                  47: 0]       arp_tx_sha         ;
  wire                 [                  31: 0]       arp_tx_spa         ;
  wire                 [                  47: 0]       arp_tx_tha         ;
  wire                 [                  31: 0]       arp_tx_tpa         ;

  wire                                                 lookup_valid_pulse  ;
  wire                                                 lookup_miss        ;
  wire                 [                  31: 0]       lookup_ip          ;
  wire                 [                  47: 0]       lookup_mac         ;

  wire                                                 write_valid_pulse  ;
  wire                 [                  31: 0]       write_ip           ;
  wire                 [                  47: 0]       write_mac          ;

  wire                                                 permit_valid_pulse  ;
  wire                                                 permit_miss        ;
  wire                 [                  31: 0]       permit_dst_ip      ;

  wire                                                 cache_clear_finish  ;
  wire                                                 pending_clear_finish  ;

  reg                                                  write_valid_pulse_reg  ;
  reg                  [                  31: 0]       write_ip_reg       ;
  reg                  [                  47: 0]       write_mac_reg      ;

  reg                  [                  47: 0]       arp_dst_mac_reg    ;
  reg                  [                  47: 0]       arp_src_mac_reg    ;
  reg                                                  arp_miss_reg       ;
  reg                                                  arp_valid_reg      ;

  // s3判断是不是同一子网 s2 -> s5(arp_top) s6输出
  // stat: 各类错误的 sticky 记录(发生即锁存, rst 清零)
  reg                                                  stat_rx_error_reg  ;
  reg                                                  stat_ack_fifo_overflow_error_reg  ;
  reg                                                  stat_pending_fifo_overflow_error_reg  ;
  reg                                                  stat_lookup_no_resp_error_reg  ;
  reg                                                  stat_query_src_not_local_reg;

  // 查询流水线
  reg                                                  query_valid_pulse_s1,query_valid_pulse_s2,query_valid_pulse_s3,query_valid_pulse_s4;
  reg                                                  query_valid_pulse_s5,query_valid_pulse_s6,query_valid_pulse_s7,query_valid_pulse_s8,query_valid_pulse_s9;
  reg                  [                  31: 0]       query_dst_ip_s1,query_dst_ip_s2,query_dst_ip_s3  ;
  reg                                                  match_query_s1,match_query_s2,match_query_s3,match_query_s4;
  reg                                                  match_query_s5,match_query_s6,match_query_s7;
  reg                                                  match_query_s8,match_query_s9;
  reg                  [                  31: 0]       match_query_src_s1,match_query_src_s2,match_query_src_s3,match_query_src_s4;
  reg                  [                  31: 0]       match_query_src_s5,match_query_src_s6,match_query_src_s7,match_query_src_s8;
  reg                  [                  31: 0]       match_query_src_s9,match_query_src_s10,match_query_src_s11,match_query_src_s12;
  reg                  [                  31: 0]       match_query_src_s13,match_query_src_s14,match_query_src_s15,match_query_src_s16,match_query_src_s17;
  reg                  [                  47: 0]       match_query_src_mac_s1,match_query_src_mac_s2,match_query_src_mac_s3,match_query_src_mac_s4;
  reg                  [                  47: 0]       match_query_src_mac_s5,match_query_src_mac_s6,match_query_src_mac_s7,match_query_src_mac_s8;
  reg                  [                  47: 0]       match_query_src_mac_s9,match_query_src_mac_s10,match_query_src_mac_s11,match_query_src_mac_s12;
  reg                  [                  47: 0]       match_query_src_mac_s13,match_query_src_mac_s14,match_query_src_mac_s15,match_query_src_mac_s16,match_query_src_mac_s17;
  reg                                                  is_broadcast_addr_s3,is_broadcast_addr_s4,is_broadcast_addr_s5,is_broadcast_addr_s6,is_broadcast_addr_s7,is_broadcast_addr_s8,is_broadcast_addr_s9  ;

  // pending
  reg [31:0] match_gateway_ip_s1, match_gateway_ip_s2;
  reg [31:0] match_subnet_s1, match_subnet_s2;
  
  reg                                                  is_out_subnet_s2;
  wire                                                 is_limited_bc_s2 = (query_dst_ip_s2 == 32'hFFFF_FFFF); // 受限广播
  wire                                                 cache_query_valid_pulse=query_valid_pulse_s3;
  wire                 [                  31: 0]       cache_query_ip   =query_dst_ip_s3;
  wire                                                 pending_req_valid_pulse=lookup_valid_pulse&&lookup_miss&&match_query_s9&&!is_broadcast_addr_s9;
  wire                 [                  31: 0]       pending_req_ip   =lookup_ip;

  // req
  reg is_arp_req_reg;
  reg is_arp_ack_reg;
  reg [47:0] arp_rx_sha_reg;
  reg [31:0] arp_rx_spa_reg;

  // 写侧
  reg match_src_ip_comb;
  reg [47:0] match_local_mac_comb;
  reg [31:0] match_local_ip_comb;

  reg match_src_ip_reg;
  reg [47:0] match_local_mac_reg;
  reg [31:0] match_local_ip_reg;

  // pengding侧
  reg match_query_comb;
  reg [31:0] match_query_src_comb;
  reg [47:0] match_query_src_mac_comb;
  reg [31:0] match_gateway_ip_comb;
  reg [31:0] match_subnet_comb;

  always @(*) begin : match_src
    integer local_ip_index;
    match_src_ip_comb = 1'b0;
    match_local_ip_comb = 'd0;
    match_local_mac_comb = 'd0;
    for (local_ip_index = 0; local_ip_index<LOCAL_IP_NUM; local_ip_index=local_ip_index+1'b1) begin
      if (arp_rx_tpa == cfg_local_ip[local_ip_index*32 +:32]) begin
        match_src_ip_comb = 1'b1;
        match_local_ip_comb = arp_rx_tpa;
        match_local_mac_comb = cfg_local_mac[local_ip_index*48+:48];
      end
    end
  end

  always @(*) begin : match_query
    integer local_ip_index;
    match_query_comb = 1'b0;
    match_query_src_comb = 'd0;
    match_query_src_mac_comb = 'd0;
    match_gateway_ip_comb = 'd0;
    match_subnet_comb = 'd0;
    for (local_ip_index = 0; local_ip_index<LOCAL_IP_NUM; local_ip_index=local_ip_index+1'b1) begin
      if (query_src_ip == cfg_local_ip[local_ip_index*32 +:32]) begin
        match_query_comb = 1'b1;
        match_query_src_comb = query_src_ip;
        match_query_src_mac_comb = cfg_local_mac[local_ip_index*48+:48];
        match_gateway_ip_comb = cfg_gateway_ip[local_ip_index*32+:32];
        match_subnet_comb = cfg_subnet_mask[local_ip_index*32+:32];
      end
    end
  end

  // match_src_ip_reg
  always @(posedge clk) begin
    if (rst) begin
      match_src_ip_reg <= 'd0;
    end
    else begin
      match_src_ip_reg <= match_src_ip_comb;
    end
  end

  // match_local_ip_reg
  always @(posedge clk) begin
    match_local_ip_reg <= match_local_ip_comb;
  end

  // match_local_mac_reg
  always @(posedge clk) begin
    match_local_mac_reg <= match_local_mac_comb;
  end

  // match_gateway_ip_s1
  always @(posedge clk) begin
    match_gateway_ip_s1 <= match_gateway_ip_comb;
    match_gateway_ip_s2 <= match_gateway_ip_s1;
  end

  // match_subnet_s1
  always @(posedge clk) begin
    match_subnet_s1 <= match_subnet_comb;
    match_subnet_s2 <= match_subnet_s1;
  end

  // ============================================================================
  // 查询流水线
  //   T0   : query_valid_pulse 输入
  //   s3   : 判断是否跨网段(跨网段则替换成网关 IP) / 是否为本网段广播地址, 同时向 arp_top 发起查询
  //   s2~s6: arp_top(arp_lookup + sdp_bram) 共 5 级流水
  //   reg   : 与 lookup_valid_pulse 对齐, 输出 arp_dst_mac / arp_src_mac_reg / arp_miss / arp_valid
  // ============================================================================
  // is_out_subnet_s2
  always @(posedge clk) begin
    is_out_subnet_s2 <= ((query_dst_ip_s1^match_gateway_ip_s1)&match_subnet_s1)!=0; // 没src ip匹配到，则默认同网段
  end

  // query_valid_pulse_s1 ~ s6
  always @(posedge clk) begin
    if (rst) begin
      query_valid_pulse_s1 <= 'd0;
      query_valid_pulse_s2 <= 'd0;
      query_valid_pulse_s3 <= 'd0;
      query_valid_pulse_s4 <= 'd0;
      query_valid_pulse_s5 <= 'd0;
      query_valid_pulse_s6 <= 'd0;
      query_valid_pulse_s7 <= 'd0;
      query_valid_pulse_s8 <= 'd0;
      query_valid_pulse_s9 <= 'd0;
    end
    else begin
      query_valid_pulse_s1 <= query_valid_pulse    ;
      query_valid_pulse_s2 <= query_valid_pulse_s1 ;
      query_valid_pulse_s3 <= query_valid_pulse_s2 ;
      query_valid_pulse_s4 <= query_valid_pulse_s3 ;
      query_valid_pulse_s5 <= query_valid_pulse_s4 ;
      query_valid_pulse_s6 <= query_valid_pulse_s5 ;
      query_valid_pulse_s7 <= query_valid_pulse_s6 ;
      query_valid_pulse_s8 <= query_valid_pulse_s7 ;
      query_valid_pulse_s9 <= query_valid_pulse_s8 ;
    end
  end

  // is_broadcast_addr_s1 ~ s6
  always @(posedge clk) begin
    if (rst) begin
      is_broadcast_addr_s3 <= 'd0;
      is_broadcast_addr_s4 <= 'd0;
      is_broadcast_addr_s5 <= 'd0;
      is_broadcast_addr_s6 <= 'd0;
      is_broadcast_addr_s7 <= 'd0;
      is_broadcast_addr_s8 <= 'd0;
      is_broadcast_addr_s9 <= 'd0;
    end
    else begin
      is_broadcast_addr_s3 <=((~(query_dst_ip_s2|match_subnet_s2)==0)&&!is_out_subnet_s2) || is_limited_bc_s2; // 没src ip匹配到，(dst == 32'hFFFFFFFF)则会认为广播
      is_broadcast_addr_s4 <= is_broadcast_addr_s3;
      is_broadcast_addr_s5 <= is_broadcast_addr_s4;
      is_broadcast_addr_s6 <= is_broadcast_addr_s5;
      is_broadcast_addr_s7 <= is_broadcast_addr_s6;
      is_broadcast_addr_s8 <= is_broadcast_addr_s7;
      is_broadcast_addr_s9 <= is_broadcast_addr_s8;
    end
  end

  // query_dst_ip_s1 ~ s6
  always @(posedge clk) begin
    query_dst_ip_s1 <= query_dst_ip;
    query_dst_ip_s2 <= query_dst_ip_s1;
    if (query_valid_pulse_s2 && is_out_subnet_s2 && !is_limited_bc_s2) begin                 // 跨网段 -> 查询网关的 MAC
      query_dst_ip_s3 <= match_gateway_ip_s2;
    end
    else if (query_valid_pulse_s2) begin
      query_dst_ip_s3 <= query_dst_ip_s2;
    end
  end

  // match_query_s1 ~ s6
  always @(posedge clk) begin
    if (rst) begin
      match_query_s1 <= 'd0;
      match_query_s2 <= 'd0;
      match_query_s3 <= 'd0;
      match_query_s4 <= 'd0;
      match_query_s5 <= 'd0;
      match_query_s6 <= 'd0;
      match_query_s7 <= 'd0;
      match_query_s8 <= 'd0;
      match_query_s9 <= 'd0;
    end
    else begin
      match_query_s1 <= match_query_comb;
      match_query_s2 <= match_query_s1 ;
      match_query_s3 <= match_query_s2 ;
      match_query_s4 <= match_query_s3 ;
      match_query_s5 <= match_query_s4 ;
      match_query_s6 <= match_query_s5 ;
      match_query_s7 <= match_query_s6 ;
      match_query_s8 <= match_query_s7 ;
      match_query_s9 <= match_query_s8 ;
    end
  end

  // match_query_src_s1 ~ s15
  always @(posedge clk) begin
    match_query_src_s1 <= match_query_src_comb;
    match_query_src_s2 <= match_query_src_s1;
    match_query_src_s3 <= match_query_src_s2;
    match_query_src_s4 <= match_query_src_s3;
    match_query_src_s5 <= match_query_src_s4;
    match_query_src_s6 <= match_query_src_s5;
    match_query_src_s7 <= match_query_src_s6;
    match_query_src_s8 <=  match_query_src_s7 ;
    match_query_src_s9 <=  match_query_src_s8 ;
    match_query_src_s10 <= match_query_src_s9 ;
    match_query_src_s11 <= match_query_src_s10;
    match_query_src_s12 <= match_query_src_s11;
    match_query_src_s13 <= match_query_src_s12;
    match_query_src_s14 <= match_query_src_s13;
    match_query_src_s15 <= match_query_src_s14;
    match_query_src_s16 <= match_query_src_s15;
    match_query_src_s17 <= match_query_src_s16;
  end

  // match_query_src_mac_s1 ~ s15
  always @(posedge clk) begin
    match_query_src_mac_s1 <=  match_query_src_mac_comb;
    match_query_src_mac_s2 <=  match_query_src_mac_s1;
    match_query_src_mac_s3 <=  match_query_src_mac_s2;
    match_query_src_mac_s4 <=  match_query_src_mac_s3;
    match_query_src_mac_s5 <=  match_query_src_mac_s4;
    match_query_src_mac_s6 <=  match_query_src_mac_s5;
    match_query_src_mac_s7 <=  match_query_src_mac_s6;
    match_query_src_mac_s8 <=  match_query_src_mac_s7 ;
    match_query_src_mac_s9 <=  match_query_src_mac_s8 ;
    match_query_src_mac_s10 <= match_query_src_mac_s9 ;
    match_query_src_mac_s11 <= match_query_src_mac_s10;
    match_query_src_mac_s12 <= match_query_src_mac_s11;
    match_query_src_mac_s13 <= match_query_src_mac_s12;
    match_query_src_mac_s14 <= match_query_src_mac_s13;
    match_query_src_mac_s15 <= match_query_src_mac_s14;
    match_query_src_mac_s16 <= match_query_src_mac_s15;
    match_query_src_mac_s17 <= match_query_src_mac_s16;
  end

  wire                                                 arp_res_ok     ;
  assign  arp_res_ok = cache_clear_finish && lookup_valid_pulse;

  // arp_valid_reg
  always @(posedge clk) begin
    if (rst) begin
      arp_valid_reg <= 'd0;
    end
    else begin
      if (query_valid_pulse_s9) begin
        arp_valid_reg <= 1'b1; // 有结论(命中/未命中/未就绪)
      end
      else begin
        arp_valid_reg <= 'd0;
      end
    end
  end

  // arp_dst_mac_reg
  always @(posedge clk) begin
    if (query_valid_pulse_s9 && is_broadcast_addr_s9) begin
      arp_dst_mac_reg <= 48'hffffffffffff;
    end
    else if (query_valid_pulse_s9) begin
      arp_dst_mac_reg <= arp_res_ok ? lookup_mac : 48'd0;
    end
  end

  // arp_src_mac_reg
  always @(posedge clk) begin
    if (query_valid_pulse_s9) begin
      arp_src_mac_reg <= match_query_src_mac_s9;
    end
  end

  // arp_miss_reg
  always @(posedge clk) begin
    if (rst) begin
      arp_miss_reg <= 'd0;
    end
    else begin
      if (query_valid_pulse_s9 && is_broadcast_addr_s9) begin
        arp_miss_reg <= 1'b0;
      end
      else if (query_valid_pulse_s9) begin
        arp_miss_reg <= arp_res_ok ? (match_query_s9 ? lookup_miss : 1'b1) : 1'b1;
      end
    end
  end

  assign  arp_valid        = arp_valid_reg    ;
  assign  arp_dst_mac      = arp_dst_mac_reg      ;
  assign  arp_src_mac      = arp_src_mac_reg      ;
  assign  arp_miss         = arp_miss_reg     ;

  wire                                                 arp_rx_frame_handshake=arp_rx_frame_valid&&arp_rx_frame_ready  ;
  wire                                                 is_arp_ack       =arp_rx_frame_handshake&&arp_rx_oper==16'h0200;// 只学习自己的
  wire                                                 is_arp_req       =arp_rx_frame_handshake&&arp_rx_oper==16'h0100;// 只学习自己的


  // Pending -> eth
  wire                                                 eth_pending_frame_valid=!permit_miss&&permit_valid_pulse;
  wire                 [                  47: 0]       eth_pending_src_mac =match_query_src_mac_s17;
  wire                 [                  47: 0]       eth_pending_dest_mac=48'hffffffffffff  ;
  wire                 [                  15: 0]       eth_pending_oper =16'h0100;
  wire                 [                  47: 0]       eth_pending_tha  =48'h0;
  wire                 [                  31: 0]       eth_pending_tpa  =permit_dst_ip;
  wire                 [                  31: 0]       eth_pending_spa  =match_query_src_s17;


  wire                 [                   1: 0]       arp_rr_dout_onehot  ;
  wire                                                 arp_rr_dout_valid   ;

  // ack -> eth
  wire                                                 eth_ack_frame_valid=is_arp_req_reg && match_src_ip_reg;
  wire                 [                  47: 0]       eth_ack_src_mac =match_local_mac_reg;      
  wire                 [                  47: 0]       eth_ack_dest_mac=arp_rx_sha_reg  ;
  wire                 [                  15: 0]       eth_ack_oper     =16'h0200;
  wire                 [                  47: 0]       eth_ack_tha      =arp_rx_sha_reg;
  wire                 [                  31: 0]       eth_ack_tpa      =arp_rx_spa_reg;
  wire                 [                  31: 0]       eth_ack_spa      =match_local_ip_reg;

  wire                                                 arp_ack_fifo_full  ;
  wire                                                 arp_ack_fifo_empty  ;
  wire                 [                 223: 0]       arp_ack_fifo_dout  ;
  wire                                                 overflow_arp_ack_fifo_error=arp_ack_fifo_full&&eth_ack_frame_valid  ;

  wire                                                 arp_pending_fifo_full  ;
  wire                                                 arp_pending_fifo_empty  ;
  wire                 [                 223: 0]       arp_pending_fifo_dout  ;
  wire                                                 overflow_arp_pending_fifo_error=arp_pending_fifo_full&&eth_pending_frame_valid  ;

  wire                 [                 223: 0]       tx_frame_data_comb=arp_rr_dout_onehot[1]?arp_pending_fifo_dout:arp_ack_fifo_dout;
  reg                  [                 223: 0]       tx_frame_data_reg  ;
  reg                                                  tx_frame_data_valid  ;
  wire                                                 arp_rr_grant_valid=arp_rr_dout_onehot[1]?!arp_pending_fifo_empty : !arp_ack_fifo_empty;

  wire                                                 tx_frame_data_ready=arp_tx_frame_ready  ;
  wire                                                 tx_frame_data_handshake=tx_frame_data_ready&&tx_frame_data_valid;
  wire                                                 arp_rr_take      =(!tx_frame_data_valid|| arp_tx_frame_ready) && (arp_rr_dout_valid && arp_rr_grant_valid);
  wire                                                 arp_rr_ack       =arp_rr_take|| !(arp_rr_dout_valid && arp_rr_grant_valid);
  wire                                                 arp_ack_fifo_rd_en=arp_rr_take&&arp_rr_dout_onehot[0];
  wire                                                 arp_pending_fifo_rd_en=arp_rr_take&&arp_rr_dout_onehot[1];

  // is_arp_req_reg is_arp_ack_reg
  always @(posedge clk) begin
    if (rst) begin
      is_arp_req_reg <= 'd0;
      is_arp_ack_reg <='d0;
    end
    else begin
      if (is_arp_req) begin
        is_arp_req_reg <= 1'b1;
      end else begin
        is_arp_req_reg <= 1'b0;
      end

      if (is_arp_ack) begin
        is_arp_ack_reg <= 1'b1;
      end else begin
        is_arp_ack_reg <= 1'b0;
      end
    end
  end

  // arp_rx_sha_reg arp_rx_spa_reg
  always @(posedge clk) begin
    if (is_arp_req || is_arp_ack)begin
      arp_rx_sha_reg <= arp_rx_sha;
      arp_rx_spa_reg <= arp_rx_spa;
    end
  end

  // tx_frame_data_valid
  always @(posedge clk) begin
    if (rst) begin
      tx_frame_data_valid <= 'd0;
    end
    else begin
      if (arp_rr_take) begin
        tx_frame_data_valid <= 1'b1;
      end
      else if(tx_frame_data_handshake) begin
        tx_frame_data_valid <= 1'b0;
      end
    end
  end

  // tx_frame_data_reg
  always @(posedge clk) begin
    if (arp_rr_take) begin
      tx_frame_data_reg <= tx_frame_data_comb;
    end
  end

  // write_valid_pulse_reg
  always @(posedge clk) begin
    if (rst) begin
      write_valid_pulse_reg <= 'd0;
    end
    else begin
      if ((is_arp_ack_reg || is_arp_req_reg) && match_src_ip_reg) begin
        write_valid_pulse_reg <= 'd1;
      end
      else begin
        write_valid_pulse_reg <= 'd0;
      end
    end
  end

  // write_ip_reg write_mac_reg
  always @(posedge clk) begin
    if ((is_arp_ack_reg || is_arp_req_reg) && match_src_ip_reg) begin
      write_ip_reg     <= arp_rx_spa_reg;
      write_mac_reg    <= arp_rx_sha_reg;
    end
    else begin
      write_ip_reg     <= 'd0;
      write_mac_reg    <= 'd0;
    end
  end

  // ============================================================================
  // stat 锁存: 一旦发生即置 1, 直到 rst 清零(便于上板定位偶发错误)
  // ============================================================================
  // stat_lookup_no_resp_error
  always @(posedge clk) begin
    if (rst) begin
      stat_lookup_no_resp_error_reg <= 1'b0;
    end
    else begin
      if (query_valid_pulse_s9 && !arp_res_ok) begin
        stat_lookup_no_resp_error_reg <= 1'b1;
      end
    end
  end

  // stat_rx_error: 收到非标准 ARP 帧(长度/keep 不合规)
  always @(posedge clk) begin
    if (rst) begin
      stat_rx_error_reg <= 1'b0;
    end
    else begin
      if (arp_rx_error_pulse) begin
        stat_rx_error_reg <= 1'b1;
      end
    end
  end

  // stat_ack_fifo_overflow_error: ack FIFO 满, 应答帧被丢弃
  always @(posedge clk) begin
    if (rst) begin
      stat_ack_fifo_overflow_error_reg <= 1'b0;
    end
    else begin
      if (overflow_arp_ack_fifo_error) begin
        stat_ack_fifo_overflow_error_reg <= 1'b1;
      end
    end
  end

  // stat_pending_fifo_overflow_error: pending FIFO 满, 请求帧被丢弃
  always @(posedge clk) begin
    if (rst) begin
      stat_pending_fifo_overflow_error_reg <= 1'b0;
    end
    else begin
      if (overflow_arp_pending_fifo_error) begin
        stat_pending_fifo_overflow_error_reg <= 1'b1;
      end
    end
  end

  // stat_query_src_not_local_reg
  always @(posedge clk) begin
    if (rst) begin
      stat_query_src_not_local_reg <= 1'b0;
    end
    else begin
      if (!match_query_s1 && query_valid_pulse_s1) begin
        stat_query_src_not_local_reg <= 1'b1;
      end
    end
  end

  assign  stat_rx_error    = stat_rx_error_reg;
  assign  stat_ack_fifo_overflow_error= stat_ack_fifo_overflow_error_reg;
  assign  stat_pending_fifo_overflow_error= stat_pending_fifo_overflow_error_reg;
  assign  stat_lookup_no_resp_error= stat_lookup_no_resp_error_reg;
  assign  stat_query_src_not_local = stat_query_src_not_local_reg;

fifo_sync#(
    // 控制数据路径，最高优先级。（手动ARP[最高优先级] ARP_ACK QUERY_ARP1，至少缓存3拍)
    // 假设一直QUERY，则剩下的拍数都是作为突发，可缓冲手动ARP和ARP_ACK两种类型
    .FIFO_DEPTH       (32               ),
    .DATA_WIDTH       (224              ),
    .FIFO_MEMORY_TYPE ("auto"           ),
    .BRAM_DO_REG      (2                ) 
)
 u_arp_pending_fifo_sync(
    // ============================================================================
    // 时钟与复位
    // ============================================================================
    .rst              (rst              ),// (input)
    .clk              (clk              ),// (input)
    // ============================================================================
    // FIFO 数据接口
    // ============================================================================
    .din              ({eth_pending_src_mac,eth_pending_dest_mac,eth_pending_oper,eth_pending_tha,eth_pending_tpa,eth_pending_spa}),// (input)
    .wr_en            (eth_pending_frame_valid),// (input)
    .rd_en            (arp_pending_fifo_rd_en),// (input)
    .dout             (arp_pending_fifo_dout),// (output)
    .full             (arp_pending_fifo_full),// (output)
    .empty            (arp_pending_fifo_empty),// (output)
    .prog_full        (                 ),// (output)
    .prog_empty       (                 ),// (output)
    .remain_count     (                 ) // (output)
);

fifo_sync#(
    // 同理
    .FIFO_DEPTH       (32               ),
    .DATA_WIDTH       (224              ),
    .FIFO_MEMORY_TYPE ("distributed"    ) 
)
 u_arp_ack_fifo_sync(
    // ============================================================================
    // 时钟与复位
    // ============================================================================
    .rst              (rst              ),// (input)
    .clk              (clk              ),// (input)
    // ============================================================================
    // FIFO 数据接口
    // ============================================================================
    .din              ({eth_ack_src_mac,eth_ack_dest_mac,eth_ack_oper,eth_ack_tha,eth_ack_tpa,eth_ack_spa}),// (input)
    .wr_en            (eth_ack_frame_valid),// (input)
    .rd_en            (arp_ack_fifo_rd_en),// (input)
    .dout             (arp_ack_fifo_dout),// (output)
    .full             (arp_ack_fifo_full),// (output)
    .empty            (arp_ack_fifo_empty),// (output)
    .prog_full        (                 ),// (output)
    .prog_empty       (                 ),// (output)
    .remain_count     (                 ) // (output)
);

arbiter#(
    .ARB_TYPE         (0                ),
    .ARB_SOUT_REG     (1                ),
    .ARB_BLOCK        (1                ),
    .ARB_BLOCK_BY_ACK (1                ),
    .WIDTH            (2                ),
    .LOW_FIRST        (1                ) 
)
 u_arp_out_arbiter(
    .rst              (rst              ),// (input)
    .clk              (clk              ),// (input)
    .din              ({~arp_pending_fifo_empty,~arp_ack_fifo_empty}),// (input)
    .index            (                 ),// (output)
    .dout_onehot      (arp_rr_dout_onehot),// (output)
    .valid            (arp_rr_dout_valid ),// (output)
    .ack              (arp_rr_ack       ) // (input)
);

arp_eth_tx#(
    .AXIS_WIDTH       (AXIS_WIDTH       ) ,
    .AXIS_TX_USR_WID  (AXIS_TX_USR_WID  ) ,
    .ARP_PRIORITY     (ARP_PRIORITY     )
)
 u_arp_eth_tx(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    // arp frame input
    .arp_frame_valid  (arp_tx_frame_valid),// (input)
    .arp_frame_ready  (arp_tx_frame_ready),// (output)
    .eth_dest_mac     (eth_tx_dest_mac  ),// (input)
    .eth_src_mac      (eth_tx_src_mac   ),// (input)
    .eth_type         (eth_tx_type      ),// (input)
    .arp_htype        (arp_tx_htype     ),// (input)
    .arp_ptype        (arp_tx_ptype     ),// (input)
    .arp_hlen         (arp_tx_hlen      ),// (input)
    .arp_plen         (arp_tx_plen      ),// (input)
    .arp_oper         (arp_tx_oper      ),// (input)
    .arp_sha          (arp_tx_sha       ),// (input)// sender hardware address
    .arp_spa          (arp_tx_spa       ),// (input)// sender protocol address
    .arp_tha          (arp_tx_tha       ),// (input)// target hardware address
    .arp_tpa          (arp_tx_tpa       ),// (input)// target protocol address
    // eth_arp axis out
    .arp_axis_mdata   (arp_axis_mdata   ),// (output)
    .arp_axis_mkeep   (arp_axis_mkeep   ),// (output)
    .arp_axis_mvalid  (arp_axis_mvalid  ),// (output)
    .arp_axis_mlast   (arp_axis_mlast   ),// (output)
    .arp_axis_musr    (arp_axis_musr    ),// (output)
    .arp_axis_mready  (arp_axis_mready  ) // (input)
);

arp_eth_rx#(
    .AXIS_WIDTH       (AXIS_WIDTH       ) 
)
 u_arp_eth_rx(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    // arp frame input
    .arp_frame_valid  (arp_rx_frame_valid),// (output)
    .arp_frame_ready  (arp_rx_frame_ready),// (input)
    .eth_dest_mac     (eth_rx_dest_mac  ),// (output)
    .eth_src_mac      (eth_rx_src_mac   ),// (output)
    .eth_type         (eth_rx_type      ),// (output)
    .arp_htype        (arp_rx_htype     ),// (output)
    .arp_ptype        (arp_rx_ptype     ),// (output)
    .arp_hlen         (arp_rx_hlen      ),// (output)
    .arp_plen         (arp_rx_plen      ),// (output)
    .arp_oper         (arp_rx_oper      ),// (output)
    .arp_sha          (arp_rx_sha       ),// (output)// sender hardware address
    .arp_spa          (arp_rx_spa       ),// (output)// sender protocol address
    .arp_tha          (arp_rx_tha       ),// (output)// target hardware address
    .arp_tpa          (arp_rx_tpa       ),// (output)// target protocol address
    // eth_arp axis out
    .arp_axis_sdata   (arp_axis_sdata   ),// (input)
    .arp_axis_skeep   (arp_axis_skeep   ),// (input)
    .arp_axis_susr    (arp_axis_susr    ),// (input)
    .arp_axis_svalid  (arp_axis_svalid  ),// (input)
    .arp_axis_slast   (arp_axis_slast   ),// (input)
    .arp_axis_sready  (arp_axis_sready  ),// (output)
    // stat
    .stat_error       (arp_rx_error_pulse) // (output)// 帧解析失败，不是标准的ARP ETH帧
);
  assign  arp_rx_frame_ready= cache_clear_finish;

  assign  arp_tx_frame_valid= tx_frame_data_valid;
  assign  {eth_tx_src_mac,eth_tx_dest_mac,arp_tx_oper,arp_tx_tha,arp_tx_tpa,arp_tx_spa}= tx_frame_data_reg;

  assign  eth_tx_type      = 16'h0608         ;
  assign  arp_tx_htype     = 16'h0100            ;
  assign  arp_tx_ptype     = 16'h0008         ;
  assign  arp_tx_hlen      = 8'h06             ;
  assign  arp_tx_plen      = 8'h04             ;
  assign  arp_tx_sha       = eth_tx_src_mac    ;

arp_cache_top#(
    .ITEM_WIDTH       (CACHE_ITEM_WIDTH ),
    .CACHE_DEEP       (CACHE_DEEP       ),
    .CACHE_ADDR_WIDTH (CACHE_ADDR_WIDTH ),
    .HASH_WAY_CNT     (HASH_WAY_CNT     ) 
)
 u_arp_cache_top(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
// query
    .query_valid_pulse(cache_query_valid_pulse),// (input)
    .query_ip         (cache_query_ip),// (input)
// output
    .lookup_valid_pulse(lookup_valid_pulse),// (output)
    .lookup_miss      (lookup_miss      ),// (output)
    .lookup_ip        (lookup_ip        ),// (output)
    .lookup_mac       (lookup_mac       ),// (output)
    .write_valid_pulse(write_valid_pulse),// (input)
    .write_ip         (write_ip         ),// (input)
    .write_mac        (write_mac        ),// (input)
// cfg
    .cfg_clear        (cfg_clear_cache  ),// (input)
    .stat_clear_finish(cache_clear_finish) 
);

  assign  write_valid_pulse= write_valid_pulse_reg;
  assign  write_ip         = write_ip_reg     ;
  assign  write_mac        = write_mac_reg    ;

  assign stat_cache_clear_finish = cache_clear_finish;
  assign stat_pending_clear_finish = pending_clear_finish;

arp_pending_ctrl#(
    .ITEM_WIDTH       (PENDING_ITEM_WIDTH),
    .CACHE_DEEP       (PENDING_DEEP     ),
    .CACHE_ADDR_WIDTH (PENDING_ADDR_WIDTH),
    .HASH_WAY_CNT     (HASH_WAY_CNT     ),
    .TIME_WIDTH       (PENDING_TIME_WIDTH) 
)
 u_arp_pending_ctrl(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .req_valid_pulse  (pending_req_valid_pulse),// (input)
    .req_ip           (pending_req_ip   ),// (input)
    .permit_valid_pulse(permit_valid_pulse),// (output)
    .permit_miss      (permit_miss      ),// (output)
    .permit_ip        (permit_dst_ip     ),// (output)
    .cfg_pending_time (cfg_pending_time ),// (input)
    .cfg_clear        (cfg_clear_pending),// (input)
    .stat_clear_finish(pending_clear_finish) // (output)
);

endmodule
`resetall
