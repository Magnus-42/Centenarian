// -----------------------------------------------------------------------------
// File Name   : arp_engine_top.v
// Module Name : arp_engine_top
// Author      : LiXintao
// Created     : 2026-09-14
// Version     : 2.0
// -----------------------------------------------------------------------------
// Description : ARP引擎，连接帧收发、缓存查询和待决请求控制
// Note        : 支持多组本地IP、MAC、子网和网关配置
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module arp_engine_top #(
    parameter  integer DataWidth        = 512,
    parameter  integer CacheDepth       = 512,
    parameter  integer PendingTimeWidth = 24,
    parameter  integer PendingDepth     = 512,
    parameter  integer HashWayCount     = 4,
    parameter  integer LocalIpCount     = 1,
    parameter  integer ClkFreqHz        = 400000000,
    parameter  integer ReqWidth         = 4,
    localparam integer TxUsrWidth       = ReqWidth + 112,
    localparam integer RxUsrWidth       = 113              // MAC首部与末拍错误标志
) (
    input wire clk,
    input wire rst,

    input  wire [LocalIpCount-1:0] announce_mask,
    input  wire                    announce_valid,
    output wire                    announce_ready,

    input  wire [31:0] query_src_ip,
    input  wire [31:0] query_dst_ip,
    input  wire        query_valid_pulse,
    output wire [47:0] arp_dst_mac,
    output wire [47:0] arp_src_mac,
    output wire        arp_miss,
    output wire        arp_valid,

    input  wire [  DataWidth-1:0] axis_sdata,
    input  wire [DataWidth/8-1:0] axis_skeep,
    input  wire                   axis_svalid,
    input  wire                   axis_slast,
    input  wire [ RxUsrWidth-1:0] axis_susr,
    output wire                   axis_sready,

    output wire [  DataWidth-1:0] axis_mdata,
    output wire [DataWidth/8-1:0] axis_mkeep,
    output wire                   axis_mvalid,
    output wire                   axis_mlast,
    output wire [ TxUsrWidth-1:0] axis_musr,
    input  wire                   axis_mready,

    input wire [ReqWidth-1:0] cfg_arp_priority,

    input wire [32*LocalIpCount-1:0] cfg_local_ip,
    input wire [48*LocalIpCount-1:0] cfg_local_mac,
    input wire [32*LocalIpCount-1:0] cfg_gateway_ip,
    input wire [32*LocalIpCount-1:0] cfg_subnet_mask,

    input wire [PendingTimeWidth-1:0] cfg_pending_time,   // 单位ms
    input wire                        cfg_clear_cache,    // 上游需要能缓存CacheDepth周期
    input wire                        cfg_clear_pending,  // FIFO需要能缓存PendingDepth周期
    input wire                        cfg_stat_clear,

    output wire stat_rx_error,
    output wire stat_ack_fifo_overflow_error,
    output wire stat_pending_fifo_overflow_error,
    output wire stat_pending_clear_finish,
    output wire stat_cache_clear_finish,
    output wire stat_query_src_not_local
);

  // p1匹配本地源地址，寄存子网、广播判断标志和MAC候选。
  // 本地路由配置在查询在途期间保持稳定，更新前停止查询并排空流水。
  // p2选择缓存查询IP，p3至p6完成四级缓存查询，随后寄存应答。
  // 未命中请求进入五级待决查询，许可后生成ARP请求。
  // 接收帧用于缓存学习和应答，应答、待决请求和免费ARP公告经仲裁与封装输出。

  // 参数范围检查
  initial begin
    if (DataWidth < 480 || DataWidth % 8 != 0) begin
      $display("错误：arp_engine_top：DataWidth必须不小于480且为8的整数倍");
      $finish;
    end
    if (LocalIpCount < 1 || HashWayCount < 1 || PendingTimeWidth < 1 || ReqWidth < 1) begin
      $display(
          "错误：arp_engine_top：本地地址数量、路数、时间位宽和请求位宽必须不小于1");
      $finish;
    end
    if (CacheDepth < 2 || (CacheDepth & (CacheDepth - 1)) != 0 || PendingDepth < 2 ||
        (PendingDepth & (PendingDepth - 1)) != 0) begin
      $display("错误：arp_engine_top：CacheDepth和PendingDepth必须为不小于2的2次幂");
      $finish;
    end
    if (ClkFreqHz < 1000) begin
      $display("错误：arp_engine_top：ClkFreqHz必须不小于1000");
      $finish;
    end
  end

  // 内部常量
  localparam integer CacheLookupDelay = 4;
  localparam integer PendingCtrlDelay = 5;
  localparam integer QueryDelay = 2 + CacheLookupDelay;
  localparam integer PendingSourceDelay = QueryDelay + PendingCtrlDelay;
  localparam integer FrameWidth = 224;
  localparam integer FrameFifoDepth = 32;
  localparam integer RxGroupCount = (LocalIpCount + 1) / 2;

  // 本地配置
  reg  [          32*LocalIpCount-1:0] cfg_local_ip_d1;
  reg  [          32*LocalIpCount-1:0] cfg_gateway_ip_d1;
  reg  [          32*LocalIpCount-1:0] cfg_subnet_mask_d1;
  reg  [          48*LocalIpCount-1:0] cfg_local_mac_d1;
  reg                                  cfg_clear_cache_d1;
  reg                                  cfg_stat_clear_d1;

  // 查询与路由流水
  wire                                 query_enable;
  reg                                  query_src_is_local;
  reg  [                         47:0] p1_query_src_mac;
  reg  [               QueryDelay-1:0] query_valid_shift;
  reg  [               QueryDelay-1:0] query_src_match_shift;
  reg  [           CacheLookupDelay:0] broadcast_shift;
  reg  [    32*PendingSourceDelay-1:0] query_src_ip_shift;
  (* shreg_extract = "no" *)reg  [                         47:0] p2_query_src_mac;
  reg  [48*(PendingSourceDelay-2)-1:0] query_src_mac_tail_shift;
  wire [48*(PendingSourceDelay-1)-1:0] query_src_mac_shift;
  reg  [                         31:0] p1_query_dst_ip;
  reg  [                         31:0] p2_query_ip;
  wire                                 p1_query_valid;
  wire                                 p2_query_valid;
  wire [                         31:0] p1_query_src_ip;
  reg                                  p1_is_broadcast;
  reg  [                         31:0] p1_routed_query_ip;
  wire                                 query_result_valid;
  wire                                 query_source_match;
  wire                                 query_is_broadcast;
  wire [                         47:0] query_source_mac;
  wire [             LocalIpCount-1:0] query_src_match_mask;
  reg  [             LocalIpCount-1:0] p1_query_src_match_mask;
  reg  [             LocalIpCount-1:0] p1_is_out_subnet;
  reg  [             LocalIpCount-1:0] p1_host_bits_all_ones;
  reg                                  p1_is_limited_broadcast;
  reg  [          48*LocalIpCount-1:0] p1_query_mac;

  // 接收学习与应答
  reg                                  rx_target_is_local;
  reg  [                         47:0] rx_reply_src_mac;
  wire                                 rx_frame_valid;
  wire                                 rx_frame_ready;
  wire [                         15:0] rx_oper;
  wire [                         47:0] rx_sha;
  wire [                         31:0] rx_spa;
  wire [                         31:0] rx_tpa;
  wire                                 rx_error_pulse;
  wire                                 rx_frame_take;
  wire                                 rx_is_request;
  wire                                 rx_is_reply;
  reg                                  rx_learn_valid_reg;
  reg                                  rx_reply_valid_reg;
  reg  [                         31:0] rx_learn_ip_reg;
  reg  [                         47:0] rx_learn_mac_reg;
  reg  [                        175:0] rx_reply_tail_reg;
  wire [               FrameWidth-1:0] rx_reply_data;
  wire [             LocalIpCount-1:0] rx_target_match_mask;
  reg  [             RxGroupCount-1:0] p1_rx_group_hit;
  reg  [          48*RxGroupCount-1:0] p1_rx_group_mac;

  // 待决查询结果
  wire [                         31:0] pending_source_ip;
  wire [                         47:0] pending_source_mac;
  wire                                 pending_req_valid;
  wire                                 permit_valid_pulse;
  wire                                 permit_blocked;
  wire [                         31:0] permit_dst_ip;

  // 缓存查询结果
  wire                                 lookup_valid_pulse;
  wire                                 lookup_miss;
  wire [                         31:0] lookup_ip;
  wire [                         47:0] lookup_mac;
  wire                                 lookup_result_valid;

  // ARP查询应答
  reg                                  arp_valid_reg;
  reg                                  arp_miss_reg;
  reg  [                         47:0] arp_dst_mac_reg;
  reg  [                         47:0] arp_src_mac_reg;

  // 发送帧队列
  wire                                 pending_frame_valid;
  wire [               FrameWidth-1:0] pending_frame_data;
  wire                                 ack_fifo_full;
  wire                                 ack_fifo_empty;
  wire                                 pending_fifo_full;
  wire                                 pending_fifo_empty;
  wire [               FrameWidth-1:0] ack_fifo_dout;
  wire [               FrameWidth-1:0] pending_fifo_dout;
  wire                                 ack_fifo_rd_en;
  wire                                 pending_fifo_rd_en;

  // 发送仲裁与缓存
  wire [               FrameWidth-1:0] announce_frame_data;
  wire                                 announce_frame_valid;
  wire                                 announce_frame_ready;
  wire [                          2:0] arb_req;
  wire [                          2:0] arb_onehot;
  wire                                 arb_valid;
  wire                                 arb_refresh;
  wire                                 tx_frame_ready;
  reg                                  tx_frame_valid_reg;
  reg  [               FrameWidth-1:0] tx_frame_data_reg;
  wire                                 tx_stage_ready;
  wire                                 arb_take;
  wire [               FrameWidth-1:0] arb_frame_data;
  wire [                         47:0] tx_src_mac;
  wire [                         47:0] tx_dst_mac;
  wire [                         47:0] tx_target_mac;
  wire [                         15:0] tx_oper;
  wire [                         31:0] tx_target_ip;
  wire [                         31:0] tx_source_ip;

  // 错误锁存状态
  reg                                  stat_rx_error_reg;
  reg                                  stat_ack_fifo_overflow_error_reg;
  reg                                  stat_pending_fifo_overflow_error_reg;
  reg                                  stat_query_src_not_local_reg;

  // 生成循环
  genvar g_local;
  genvar g_group;

  // 查询与路由接口
  assign query_enable = stat_cache_clear_finish && !cfg_clear_cache_d1;
  assign query_src_mac_shift = {query_src_mac_tail_shift, p2_query_src_mac};
  assign p1_query_valid = query_valid_shift[0] && query_enable;
  assign p2_query_valid = query_valid_shift[1] && query_enable;
  assign p1_query_src_ip = query_src_ip_shift[0+:32];
  assign query_result_valid = query_valid_shift[QueryDelay-1] && query_enable;
  assign query_source_match = query_src_match_shift[QueryDelay-1];
  assign query_is_broadcast = broadcast_shift[CacheLookupDelay];
  assign query_source_mac = query_src_mac_shift[48*(QueryDelay-2)+:48];
  //// 待决请求
  assign pending_source_ip = query_src_ip_shift[32*(PendingSourceDelay-1)+:32];
  assign pending_source_mac = query_src_mac_shift[48*(PendingSourceDelay-2)+:48];

  assign lookup_result_valid = stat_cache_clear_finish && lookup_valid_pulse;
  assign pending_req_valid = query_enable && lookup_valid_pulse && lookup_miss &&
      query_source_match && !query_is_broadcast;

  // 接收帧接口
  assign rx_frame_take = rx_frame_valid && rx_frame_ready;
  assign rx_is_request = rx_oper == 16'h0100;
  assign rx_is_reply = rx_oper == 16'h0200;
  assign rx_reply_data = {rx_reply_src_mac, rx_reply_tail_reg};

  // 发送帧与仲裁接口
  assign pending_frame_valid = permit_valid_pulse && !permit_blocked;
  assign pending_frame_data = {
    pending_source_mac, 48'hffff_ffff_ffff, 16'h0100, 48'd0, permit_dst_ip, pending_source_ip
  };
  assign arb_req = {announce_frame_valid, !pending_fifo_empty, !ack_fifo_empty};
  assign arb_valid = |arb_req;
  assign tx_stage_ready = !tx_frame_valid_reg || tx_frame_ready;
  assign arb_take = arb_refresh && arb_valid;
  assign ack_fifo_rd_en = arb_take && arb_onehot[0];
  assign pending_fifo_rd_en = arb_take && arb_onehot[1];
  assign announce_frame_ready = arb_take && arb_onehot[2];
  assign arb_frame_data = arb_onehot[2] ? announce_frame_data :
      (arb_onehot[1] ? pending_fifo_dout : ack_fifo_dout);

  // 本地配置与地址匹配
  //// 寄存配置
  always @(posedge clk) begin
    cfg_local_ip_d1    <= cfg_local_ip;
    cfg_local_mac_d1   <= cfg_local_mac;
    cfg_gateway_ip_d1  <= cfg_gateway_ip;
    cfg_subnet_mask_d1 <= cfg_subnet_mask;
  end
  always @(posedge clk) begin
    if (rst) begin
      cfg_clear_cache_d1 <= 1'b0;
    end else begin
      cfg_clear_cache_d1 <= cfg_clear_cache;
    end
  end
  always @(posedge clk) begin
    if (rst) begin
      cfg_stat_clear_d1 <= 1'b0;
    end else begin
      cfg_stat_clear_d1 <= cfg_stat_clear;
    end
  end
  //// P1并行寄存子网和主机位判断，P2完成路由与广播选择
  for (g_local = 0; g_local < LocalIpCount; g_local = g_local + 1) begin : gen_route
    wire is_out_subnet;
    assign is_out_subnet =
        |((query_dst_ip ^ cfg_local_ip_d1[g_local*32+:32]) & cfg_subnet_mask_d1[g_local*32+:32]);
    assign query_src_match_mask[g_local] = query_src_ip == cfg_local_ip_d1[g_local*32+:32];
    assign rx_target_match_mask[g_local] = rx_tpa == cfg_local_ip_d1[g_local*32+:32];
    always @(posedge clk) begin
      p1_query_src_match_mask[g_local] <= query_src_match_mask[g_local];
      p1_query_mac[g_local*48+:48] <= cfg_local_mac_d1[g_local*48+:48];
      p1_is_out_subnet[g_local] <= is_out_subnet;
      p1_is_limited_broadcast <= query_dst_ip == 32'hffff_ffff;
      p1_host_bits_all_ones[g_local] <=
          (query_dst_ip | cfg_subnet_mask_d1[g_local*32+:32]) == 32'hffff_ffff;
    end
  end
  for (g_group = 0; g_group < RxGroupCount; g_group = g_group + 1) begin : gen_rx_group
    if (g_group * 2 + 1 < LocalIpCount) begin : gen_pair
      always @(posedge clk) begin
        p1_rx_group_hit[g_group] <= rx_target_match_mask[g_group*2] ||
            rx_target_match_mask[g_group*2+1];
        p1_rx_group_mac[g_group*48+:48] <= rx_target_match_mask[g_group*2+1] ?
            cfg_local_mac_d1[(g_group*2+1)*48+:48] : cfg_local_mac_d1[g_group*2*48+:48];
      end
    end else begin : gen_single
      always @(posedge clk) begin
        p1_rx_group_hit[g_group]        <= rx_target_match_mask[g_group*2];
        p1_rx_group_mac[g_group*48+:48] <= cfg_local_mac_d1[g_group*2*48+:48];
      end
    end
  end
  always @(*) begin : match_local
    integer i;
    query_src_is_local = |query_src_match_mask;
    p1_query_src_mac   = 'd0;
    p1_routed_query_ip = p1_query_dst_ip;
    p1_is_broadcast    = p1_is_limited_broadcast;
    for (i = 0; i < LocalIpCount; i = i + 1) begin
      if (p1_query_src_match_mask[i]) begin
        p1_query_src_mac = p1_query_mac[i*48+:48];
        p1_routed_query_ip = p1_is_out_subnet[i] && !p1_is_limited_broadcast ?
            cfg_gateway_ip_d1[i*32+:32] : p1_query_dst_ip;
        p1_is_broadcast    = p1_is_limited_broadcast ||
            (!p1_is_out_subnet[i] && p1_host_bits_all_ones[i]);
      end
    end
  end
  //// 接收目标匹配与应答MAC选择
  always @(*) begin : match_receive
    integer i;
    rx_target_is_local = |rx_target_match_mask;
    rx_reply_src_mac   = 'd0;
    for (i = 0; i < RxGroupCount; i = i + 1) begin
      if (p1_rx_group_hit[i]) rx_reply_src_mac = p1_rx_group_mac[i*48+:48];
    end
  end

  // 查询
  //// 移位寄存
  always @(posedge clk) begin
    query_src_ip_shift <= {query_src_ip_shift[32*(PendingSourceDelay-1)-1:0], query_src_ip};
    p2_query_src_mac <= p1_query_src_mac;
    query_src_mac_tail_shift <= {
      query_src_mac_tail_shift[48*(PendingSourceDelay-3)-1:0], p2_query_src_mac
    };
    if (rst || !query_enable) begin
      query_valid_shift     <= 'd0;
      query_src_match_shift <= 'd0;
      broadcast_shift       <= 'd0;
    end else begin
      query_valid_shift     <= {query_valid_shift[QueryDelay-2:0], query_valid_pulse};
      query_src_match_shift <= {query_src_match_shift[QueryDelay-2:0], query_src_is_local};
      broadcast_shift       <= {broadcast_shift[CacheLookupDelay-1:0], p1_is_broadcast};
    end
  end
  //// p1 寄存查询和路由信息
  always @(posedge clk) begin
    p1_query_dst_ip <= query_dst_ip;
  end
  //// p2 合并子网判断和网关选择
  always @(posedge clk) begin
    if (p1_query_valid) begin
      p2_query_ip <= p1_routed_query_ip;
    end
  end
  //// 输出结果
  always @(posedge clk) begin
    if (rst || !query_enable) begin
      arp_valid_reg <= 1'b0;
      arp_miss_reg  <= 1'b0;
    end else begin
      arp_valid_reg <= query_result_valid;
      if (query_result_valid) begin
        arp_miss_reg <= !query_is_broadcast &&
            (!lookup_result_valid || !query_source_match || lookup_miss);
      end
    end
    if (query_result_valid) begin
      arp_src_mac_reg <= query_source_mac;
      arp_dst_mac_reg <= query_is_broadcast ?
          48'hffff_ffff_ffff : (lookup_result_valid ? lookup_mac : 48'd0);
    end
  end

  // 接收
  //// 寄存学习和应答信息
  always @(posedge clk) begin
    if (rst) begin
      rx_learn_valid_reg <= 1'b0;
      rx_reply_valid_reg <= 1'b0;
    end else begin
      rx_learn_valid_reg <= rx_frame_take &&
        (rx_is_request || rx_is_reply) &&
        (rx_target_is_local || (rx_tpa == rx_spa));
      rx_reply_valid_reg <= rx_frame_take && rx_target_is_local && rx_is_request;
    end
    rx_learn_ip_reg   <= rx_spa;
    rx_learn_mac_reg  <= rx_sha;
    rx_reply_tail_reg <= {rx_sha, 16'h0200, rx_sha, rx_spa, rx_tpa};
  end
  //// 帧解析
  arp_rx #(
      .DataWidth(DataWidth)
  ) arp_rx_inst (
      .clk             (clk),
      .rst             (rst),
      .frame_valid     (rx_frame_valid),
      .frame_ready     (rx_frame_ready),
      .arp_htype       (),
      .arp_ptype       (),
      .arp_hlen        (),
      .arp_plen        (),
      .arp_oper        (rx_oper),
      .arp_sha         (rx_sha),
      .arp_spa         (rx_spa),
      .arp_tha         (),
      .arp_tpa         (rx_tpa),
      .axis_sdata      (axis_sdata),
      .axis_skeep      (axis_skeep),
      .axis_susr       (axis_susr),
      .axis_svalid     (axis_svalid),
      .axis_slast      (axis_slast),
      .axis_sready     (axis_sready),
      .stat_error_pulse(rx_error_pulse)
  );
  assign rx_frame_ready = query_enable;

  // 发送
  //// 应答队列
  fifo_sync_fwft #(
      .Depth(FrameFifoDepth),
      .Width(FrameWidth)
  ) fifo_sync_fwft_ack (
      .clk  (clk),
      .rst  (rst),
      .din  (rx_reply_data),
      .wr_en(rx_reply_valid_reg),
      .rd_en(ack_fifo_rd_en),
      .dout (ack_fifo_dout),
      .full (ack_fifo_full),
      .empty(ack_fifo_empty)
  );
  //// 待决请求队列
  fifo_sync_fwft #(
      .Depth(FrameFifoDepth),
      .Width(FrameWidth)
  ) fifo_sync_fwft_pending (
      .clk  (clk),
      .rst  (rst),
      .din  (pending_frame_data),
      .wr_en(pending_frame_valid),
      .rd_en(pending_fifo_rd_en),
      .dout (pending_fifo_dout),
      .full (pending_fifo_full),
      .empty(pending_fifo_empty)
  );
  //// 免费ARP公告
  arp_announce #(
      .LocalIpCount(LocalIpCount)
  ) arp_announce_inst (
      .clk           (clk),
      .rst           (rst),
      .announce_mask (announce_mask),
      .announce_valid(announce_valid),
      .announce_ready(announce_ready),
      .cfg_local_ip  (cfg_local_ip_d1),
      .cfg_local_mac (cfg_local_mac_d1),
      .frame_data    (announce_frame_data),
      .frame_valid   (announce_frame_valid),
      .frame_ready   (announce_frame_ready)
  );
  //// 仲裁
  assign arb_refresh = tx_stage_ready && !rst;
  rr_arbiter #(
      .Width   (3),
      .LowFirst(1)
  ) rr_arbiter_inst (
      .clk    (clk),
      .rst    (rst),
      .req    (arb_req),
      .refresh(arb_refresh),
      .onehot (arb_onehot),
      .index  ()
  );
  //// 寄存完整帧，背压时保持数据和有效位
  always @(posedge clk) begin
    if (rst) tx_frame_valid_reg <= 1'b0;
    else if (tx_stage_ready) tx_frame_valid_reg <= arb_valid;
    if (arb_take) tx_frame_data_reg <= arb_frame_data;
  end
  assign {tx_src_mac, tx_dst_mac, tx_oper, tx_target_mac, tx_target_ip, tx_source_ip} =
      tx_frame_data_reg;
  //// 帧封装
  arp_eth_tx #(
      .DataWidth(DataWidth),
      .ReqWidth (ReqWidth)
  ) arp_eth_tx_inst (
      .clk             (clk),
      .rst             (rst),
      .cfg_arp_priority(cfg_arp_priority),
      .frame_valid     (tx_frame_valid_reg),
      .frame_ready     (tx_frame_ready),
      .eth_dest_mac    (tx_dst_mac),
      .eth_src_mac     (tx_src_mac),
      .eth_type        (16'h0608),
      .arp_htype       (16'h0100),
      .arp_ptype       (16'h0008),
      .arp_hlen        (8'h06),
      .arp_plen        (8'h04),
      .arp_oper        (tx_oper),
      .arp_sha         (tx_src_mac),
      .arp_spa         (tx_source_ip),
      .arp_tha         (tx_target_mac),
      .arp_tpa         (tx_target_ip),
      .axis_mdata      (axis_mdata),
      .axis_mkeep      (axis_mkeep),
      .axis_mvalid     (axis_mvalid),
      .axis_mlast      (axis_mlast),
      .axis_musr       (axis_musr),
      .axis_mready     (axis_mready)
  );

  // 缓存
  //// 四级查询和写入控制
  arp_cache_subsys #(
      .CacheDepth  (CacheDepth),
      .HashWayCount(HashWayCount)
  ) arp_cache_subsys_inst (
      .clk               (clk),
      .rst               (rst),
      .query_valid_pulse (p2_query_valid),
      .query_ip          (p2_query_ip),
      .lookup_valid_pulse(lookup_valid_pulse),
      .lookup_miss       (lookup_miss),
      .lookup_ip         (lookup_ip),
      .lookup_mac        (lookup_mac),
      .write_valid_pulse (rx_learn_valid_reg),
      .write_ip          (rx_learn_ip_reg),
      .write_mac         (rx_learn_mac_reg),
      .cfg_clear         (cfg_clear_cache_d1),
      .stat_clear_finish (stat_cache_clear_finish)
  );
  //// 五级待决控制
  arp_pending_ctrl #(
      .CacheDepth  (PendingDepth),
      .HashWayCount(HashWayCount),
      .TimeWidth   (PendingTimeWidth),
      .ClkFreqHz   (ClkFreqHz)
  ) arp_pending_ctrl_inst (
      .clk               (clk),
      .rst               (rst),
      .req_valid_pulse   (pending_req_valid),
      .req_ip            (lookup_ip),
      .permit_valid_pulse(permit_valid_pulse),
      .permit_blocked    (permit_blocked),
      .permit_ip         (permit_dst_ip),
      .cfg_pending_time  (cfg_pending_time),
      .cfg_clear         (cfg_clear_pending),
      .stat_clear_finish (stat_pending_clear_finish)
  );

  // 状态
  //// 错误锁存
  always @(posedge clk) begin
    if (rst || cfg_stat_clear_d1) begin
      stat_rx_error_reg <= 1'b0;
    end else begin
      if (rx_error_pulse) stat_rx_error_reg <= 1'b1;
    end
  end
  always @(posedge clk) begin
    if (rst || cfg_stat_clear_d1) begin
      stat_ack_fifo_overflow_error_reg <= 1'b0;
    end else begin
      if (rx_reply_valid_reg && ack_fifo_full) stat_ack_fifo_overflow_error_reg <= 1'b1;
    end
  end
  always @(posedge clk) begin
    if (rst || cfg_stat_clear_d1) begin
      stat_pending_fifo_overflow_error_reg <= 1'b0;
    end else begin
      if (pending_frame_valid && pending_fifo_full) stat_pending_fifo_overflow_error_reg <= 1'b1;
    end
  end
  always @(posedge clk) begin
    if (rst || cfg_stat_clear_d1) begin
      stat_query_src_not_local_reg <= 1'b0;
    end else begin
      if (p1_query_valid && !query_src_match_shift[0]) stat_query_src_not_local_reg <= 1'b1;
    end
  end
  //// 输出
  assign arp_valid                        = arp_valid_reg;
  assign arp_miss                         = arp_miss_reg;
  assign arp_dst_mac                      = arp_dst_mac_reg;
  assign arp_src_mac                      = arp_src_mac_reg;
  assign stat_rx_error                    = stat_rx_error_reg;
  assign stat_ack_fifo_overflow_error     = stat_ack_fifo_overflow_error_reg;
  assign stat_pending_fifo_overflow_error = stat_pending_fifo_overflow_error_reg;
  assign stat_query_src_not_local         = stat_query_src_not_local_reg;
endmodule
`resetall
