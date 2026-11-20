// -----------------------------------------------------------------------------
// File Name   : ipv4_arp_service.v
// Module Name : ipv4_arp_service
// Author      : LiXintao
// Created     : 2026-09-18
// Version     : v2.0
// -----------------------------------------------------------------------------
// Description : IPv4发送ARP查询服务，缓存查询结果并过滤未命中的帧。
// Note        : 查询应答固定七拍、有序且每请求恰一次；MAC边带仅首拍有效。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv4_arp_service #(
    parameter  integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth
) (
    input wire clk,
    input wire rst,

    input wire cfg_stat_clear,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire [UsrWidth-1:0] axis_susr,
    input  wire                axis_svalid,
    input  wire                axis_slast,
    output wire                axis_sready,

    output wire [       511:0] axis_mdata,
    output wire [        63:0] axis_mkeep,
    output wire [UsrWidth-1:0] axis_musr,
    output wire                axis_mvalid,
    output wire                axis_mlast,
    input  wire                axis_mready,

    output wire [47:0] dst_mac,  // 仅首拍有效
    output wire [47:0] src_mac,  // 仅首拍有效

    output wire [31:0] query_dst_ip,
    output wire [31:0] query_src_ip,
    output wire        query_valid_pulse,
    input  wire [47:0] arp_dst_mac,
    input  wire [47:0] arp_src_mac,
    input  wire        arp_miss,
    input  wire        arp_valid,

    output wire stat_tx_drop
);

  // 入口skid后的首拍发起ARP查询。
  // p1至p7通过共享使能移位，暂存数据与边带。
  // ARP应答由d1、FIFO及FIFO输出寄存缓存，p8对齐结果并过滤未命中帧。
  // 出口skid同步缓存数据与MAC边带。

  // 参数范围检查
  initial begin
    if (ReqWidth < 1) begin
      $display("错误：ipv4_arp_service：ReqWidth必须不小于1。");
      $finish;
    end
  end

  // 内部常量
  localparam integer BufDepth = 8;
  localparam integer PipelineDepth = 8;
  localparam integer ShiftDepth = PipelineDepth - 1;

  // 入口skid接口
  wire [         511:0] axis_sdata_skid;
  wire [          63:0] axis_skeep_skid;
  wire [  UsrWidth-1:0] axis_susr_skid;
  wire                  axis_slast_skid;
  wire                  axis_svalid_skid;
  wire                  axis_sready_skid;

  // 输入首拍与握手
  reg                   is_first_beat;
  wire                  s_handshake_skid;

  // p1至p7 暂存
  reg  [         511:0] data_shift          [0:ShiftDepth-1];
  reg  [          63:0] keep_shift          [0:ShiftDepth-1];
  reg  [  UsrWidth-1:0] usr_shift           [0:ShiftDepth-1];
  reg  [ShiftDepth-1:0] last_shift;
  reg  [ShiftDepth-1:0] first_shift;
  reg  [ShiftDepth-1:0] valid_shift;

  // p8 数据与控制
  (* shreg_extract = "no" *)reg  [         511:0] p8_axis_sdata;
  (* shreg_extract = "no" *)reg  [          63:0] p8_axis_skeep;
  (* shreg_extract = "no" *)reg  [  UsrWidth-1:0] p8_axis_susr;
  (* shreg_extract = "no" *)reg                   p8_axis_slast;
  (* shreg_extract = "no" *)reg                   p8_axis_svalid;
  (* shreg_extract = "no" *)reg                   p8_is_first_beat;
  wire [          47:0] p8_dst_mac;
  wire [          47:0] p8_src_mac;
  wire                  p8_axis_svalid_skid;
  wire                  p8_ready;
  wire                  p8_handshake;
  wire                  axis_mready_skid;

  // ARP应答寄存
  reg                   arp_valid_d1;
  reg                   arp_miss_d1;
  reg  [          47:0] arp_dst_mac_d1;
  reg  [          47:0] arp_src_mac_d1;
  wire                  arp_d1_take;
  wire                  arp_d1_can_take;
  wire                  arp_d1_load;

  // ARP应答FIFO与输出寄存
  wire                  arp_buf_rd_en;
  wire                  arp_buf_wr_en;
  wire [          96:0] arp_buf_dout;
  wire                  arp_buf_empty;
  reg                   arp_buf_valid;
  reg                   arp_buf_miss;
  reg  [          47:0] arp_buf_dst_mac;
  reg  [          47:0] arp_buf_src_mac;
  wire                  arp_buf_take;
  wire                  arp_buf_can_take;

  // 应答选择与帧过滤
  wire                  current_miss;
  wire [          47:0] current_dst_mac;
  wire [          47:0] current_src_mac;
  wire                  is_drop;
  reg                   is_drop_other_beat;

  // 状态清除配置
  reg                   cfg_stat_clear_d1;

  // 丢包锁存状态
  reg                   drop_seen;

  // 状态清除配置寄存
  always @(posedge clk) begin
    if (rst) begin
      cfg_stat_clear_d1 <= 1'b0;
    end else begin
      cfg_stat_clear_d1 <= cfg_stat_clear;
    end
  end

  // 入口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth)
  ) axis_skid_buffer_in (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_sready),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_slast (axis_slast),
      .axis_svalid(axis_svalid),
      .axis_mready(axis_sready_skid),
      .axis_mdata (axis_sdata_skid),
      .axis_mkeep (axis_skeep_skid),
      .axis_musr  (axis_susr_skid),
      .axis_mlast (axis_slast_skid),
      .axis_mvalid(axis_svalid_skid)
  );

  // 流水控制
  assign p8_ready          = axis_mready_skid;
  assign p8_handshake      = p8_ready && p8_axis_svalid;
  assign axis_sready_skid  = !p8_axis_svalid || p8_ready;
  assign s_handshake_skid  = axis_svalid_skid && axis_sready_skid;

  // 首拍查询
  assign query_src_ip      = axis_sdata_skid[127:96];
  assign query_dst_ip      = axis_sdata_skid[159:128];
  assign query_valid_pulse = s_handshake_skid && is_first_beat;

  // 输入首拍标志
  always @(posedge clk) begin
    if (rst) is_first_beat <= 1'b1;
    else if (s_handshake_skid) is_first_beat <= axis_slast_skid;
  end

  // p1至p7 暂存
  //// 数据与边带
  always @(posedge clk) begin : shift_payload
    integer stage_index;
    if (axis_sready_skid) begin
      data_shift[0] <= axis_sdata_skid;
      keep_shift[0] <= axis_skeep_skid;
      usr_shift[0]  <= axis_susr_skid;
      for (stage_index = 1; stage_index < ShiftDepth; stage_index = stage_index + 1) begin
        data_shift[stage_index] <= data_shift[stage_index-1];
        keep_shift[stage_index] <= keep_shift[stage_index-1];
        usr_shift[stage_index]  <= usr_shift[stage_index-1];
      end
      last_shift  <= {last_shift[ShiftDepth-2:0], axis_slast_skid};
      first_shift <= {first_shift[ShiftDepth-2:0], is_first_beat};
    end
  end
  //// 有效位
  always @(posedge clk) begin
    if (rst) begin
      valid_shift <= 'd0;
    end else begin
      if (axis_sready_skid) begin
        valid_shift <= {valid_shift[ShiftDepth-2:0], axis_svalid_skid};
      end
    end
  end
  // p8 暂存
  //// 数据与边带
  always @(posedge clk) begin
    if (axis_sready_skid) begin
      p8_axis_sdata    <= data_shift[ShiftDepth-1];
      p8_axis_skeep    <= keep_shift[ShiftDepth-1];
      p8_axis_susr     <= usr_shift[ShiftDepth-1];
      p8_axis_slast    <= last_shift[ShiftDepth-1];
      p8_is_first_beat <= first_shift[ShiftDepth-1];
    end
  end
  //// 有效位
  always @(posedge clk) begin
    if (rst) begin
      p8_axis_svalid <= 1'b0;
    end else if (axis_sready_skid) begin
      p8_axis_svalid <= valid_shift[ShiftDepth-1];
    end
  end

  // p8 应答选择与帧过滤
  //// 应答选择
  assign current_miss        = arp_valid_d1 ? arp_miss_d1 : arp_buf_miss;
  assign current_dst_mac     = arp_valid_d1 ? arp_dst_mac_d1 : arp_buf_dst_mac;
  assign current_src_mac     = arp_valid_d1 ? arp_src_mac_d1 : arp_buf_src_mac;
  //// MAC地址
  assign p8_dst_mac          = p8_is_first_beat ? current_dst_mac : 48'd0;
  assign p8_src_mac          = p8_is_first_beat ? current_src_mac : 48'd0;
  //// 帧过滤
  assign is_drop             = p8_is_first_beat ? current_miss : is_drop_other_beat;
  assign p8_axis_svalid_skid = p8_axis_svalid && !is_drop;
  always @(posedge clk) begin
    if (rst) begin
      is_drop_other_beat <= 1'b0;
    end else if (p8_handshake) begin
      if (p8_axis_slast) is_drop_other_beat <= 1'b0;
      else if (p8_is_first_beat) is_drop_other_beat <= current_miss;
    end
  end

  // 丢包锁存状态
  assign stat_tx_drop = drop_seen;
  always @(posedge clk) begin
    if (rst || cfg_stat_clear_d1) begin
      drop_seen <= 1'b0;
    end else if (p8_handshake && p8_is_first_beat && current_miss) begin
      drop_seen <= 1'b1;
    end
  end

  // ARP应答缓存
  //// 释放与接收条件
  assign arp_d1_take = p8_handshake && p8_axis_slast && arp_valid_d1;
  assign arp_buf_take = p8_handshake && p8_axis_slast && !arp_valid_d1 && arp_buf_valid;
  assign arp_d1_can_take = !arp_valid_d1 || arp_d1_take;
  assign arp_buf_can_take = !arp_buf_valid || arp_buf_take;
  //// 应答路由
  assign arp_d1_load = arp_valid && arp_buf_empty && arp_d1_can_take &&
      arp_buf_can_take;  // arp_buf_can_take:需要保证buf中的数据被消费
  assign arp_buf_wr_en = arp_valid && !arp_d1_load;
  assign arp_buf_rd_en = !arp_buf_empty && arp_buf_can_take;
  //// FIFO
  // 待消费请求最多8项，另有d1和FIFO输出寄存器。
  fifo_sync #(
      .Depth          (BufDepth),
      .Width          (97),
      .MemoryType     ("distributed"),
      .ProgEmptyThresh(0),
      .ProgFullThresh (0)
  ) fifo_sync_arp_buf (
      .clk            (clk),
      .rst            (rst),
      .wr_en          (arp_buf_wr_en),
      .din            ({arp_miss, arp_src_mac, arp_dst_mac}),
      .rd_en          (arp_buf_rd_en),
      .dout           (arp_buf_dout),
      .full           (),
      .empty          (arp_buf_empty),
      .prog_full      (),
      .prog_empty     (),
      .stat_data_count()
  );
  //// FIFO输出寄存
  always @(posedge clk) begin
    if (rst) begin
      arp_buf_valid <= 'd0;
    end else begin
      if (arp_buf_rd_en) begin
        arp_buf_valid <= 1'b1;
      end else if (arp_buf_take) begin
        arp_buf_valid <= 1'b0;
      end
    end
  end
  always @(posedge clk) begin
    if (arp_buf_rd_en) begin
      {arp_buf_miss, arp_buf_src_mac, arp_buf_dst_mac} <= arp_buf_dout;
    end
  end
  //// 应答寄存
  always @(posedge clk) begin
    if (rst) begin
      arp_valid_d1 <= 'd0;
    end else begin
      if (arp_d1_load) begin
        arp_valid_d1 <= 1'b1;
      end else if (arp_d1_take) begin
        arp_valid_d1 <= 1'b0;
      end
    end
  end
  always @(posedge clk) begin
    if (arp_d1_load) begin
      arp_miss_d1    <= arp_miss;
      arp_src_mac_d1 <= arp_src_mac;
      arp_dst_mac_d1 <= arp_dst_mac;
    end
  end

  // 出口skid，MAC与usr同步缓存
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth + 96)
  ) axis_skid_buffer_out (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_mready_skid),
      .axis_sdata (p8_axis_sdata),
      .axis_skeep (p8_axis_skeep),
      .axis_susr  ({p8_src_mac, p8_dst_mac, p8_axis_susr}),
      .axis_slast (p8_axis_slast),
      .axis_svalid(p8_axis_svalid_skid),
      .axis_mready(axis_mready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  ({src_mac, dst_mac, axis_musr}),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid)
  );

endmodule
`resetall
