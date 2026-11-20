// -----------------------------------------------------------------------------
// File Name   : icmpv4_echo_reply.v
// Module Name : icmpv4_echo_reply
// Author      : LiXintao
// Created     : 2026-10-10
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : ICMPv4回显应答，改写首拍头部并保留后续载荷。
// Note        : 上游保证IHL=5、首拍头部完整且非分片；仅检查首拍TTL，有在途帧时优先级须稳定。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module icmpv4_echo_reply #(
    parameter  integer ReqWidth   = 4,
    localparam integer TxUsrWidth = ReqWidth,
    localparam integer RxUsrWidth = 97
) (
    input wire clk,
    input wire rst,

    input wire [TxUsrWidth-1:0] cfg_arbiter_value,
    input wire cfg_clear_error,

    input  wire [         511:0] axis_sdata,
    input  wire [          63:0] axis_skeep,
    input  wire [RxUsrWidth-1:0] axis_susr,
    input  wire                  axis_svalid,
    input  wire                  axis_slast,
    output wire                  axis_sready,

    output wire [         511:0] axis_mdata,
    output wire [          63:0] axis_mkeep,
    output wire [TxUsrWidth-1:0] axis_musr,
    output wire                  axis_mvalid,
    output wire                  axis_mlast,
    input  wire                  axis_mready,

    output wire stat_ttl_error
);

  // 入口skid缓存输入。
  // p1检查首拍TTL并更新ICMP校验和。
  // p2交换IP、改写type/code并过滤丢弃帧，出口skid缓存应答。

  // 参数范围检查
  initial begin
    if (TxUsrWidth < 1 || RxUsrWidth < 1) begin
      $display("错误：icmpv4_echo_reply：不支持的参数配置。");
      $finish;
    end
  end

  // 应答配置
  reg  [TxUsrWidth-1:0] cfg_arbiter_value_d1;
  reg                   cfg_clear_error_d1;

  // 入口skid接口
  wire [         511:0] axis_sdata_skid;
  wire [          63:0] axis_skeep_skid;
  wire                  axis_slast_skid;
  wire                  axis_svalid_skid;
  wire                  axis_sready_skid;
  wire                  s_handshake_skid;

  // p1 输入缓存
  reg  [         511:0] p1_axis_sdata;
  reg  [          63:0] p1_axis_skeep;
  reg                   p1_axis_slast;
  reg                   p1_axis_svalid;
  reg                   p1_is_ttl_live;
  reg  [          31:0] p1_dst_ip;
  reg  [          31:0] p1_src_ip;
  reg  [          15:0] p1_checksum;

  // p2 输出缓存
  reg  [         511:0] p2_axis_sdata;
  reg  [          63:0] p2_axis_skeep;
  reg                   p2_axis_slast;
  reg                   p2_axis_svalid;

  // 首拍标志
  reg                   is_first_beat;
  reg                   p1_is_first_beat;

  // 流水控制
  wire                  p2_ready;
  wire                  p1_ready;
  wire                  p1_handshake;
  wire                  p2_handshake;

  // 首拍预处理与丢弃状态
  reg                   drop_frame_locked;
  wire                  is_ttl_live;
  reg                   ttl_error;
  wire [          31:0] dst_ip;
  wire [          31:0] src_ip;
  wire [          16:0] checksum_sum;

  // 流水控制
  assign p1_ready         = !p2_axis_svalid || p2_ready;
  assign axis_sready_skid = p1_ready || !p1_axis_svalid;
  assign s_handshake_skid = axis_sready_skid && axis_svalid_skid;
  assign p1_handshake     = p1_ready && p1_axis_svalid;
  assign p2_handshake     = p2_ready && p2_axis_svalid;

  // 首拍预处理
  assign is_ttl_live      = axis_sdata_skid[71:64] != 8'h00;
  assign dst_ip           = axis_sdata_skid[159:128];
  assign src_ip           = axis_sdata_skid[127:96];
  assign checksum_sum     = {1'b0, axis_sdata_skid[191:176]} + 17'h0008;

  // 配置寄存
  always @(posedge clk) begin
    if (rst) begin
      cfg_arbiter_value_d1 <= 'd0;
    end else begin
      cfg_arbiter_value_d1 <= cfg_arbiter_value;
    end
  end
  always @(posedge clk) begin
    if (rst) begin
      cfg_clear_error_d1 <= 1'b0;
    end else begin
      cfg_clear_error_d1 <= cfg_clear_error;
    end
  end

  // 入口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (RxUsrWidth)
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
      .axis_musr  (),
      .axis_mlast (axis_slast_skid),
      .axis_mvalid(axis_svalid_skid)
  );

  // p1 输入缓存与首拍预处理
  //// 有效位
  always @(posedge clk) begin
    if (rst) begin
      p1_axis_svalid <= 'd0;
    end else begin
      if (s_handshake_skid) begin
        p1_axis_svalid <= 1'b1;
      end else if (p1_handshake) begin
        p1_axis_svalid <= 1'b0;
      end
    end
  end
  //// 数据与边带
  always @(posedge clk) begin
    if (s_handshake_skid) begin
      p1_axis_sdata <= axis_sdata_skid;
      p1_axis_skeep <= axis_skeep_skid;
      p1_axis_slast <= axis_slast_skid;
    end
  end
  //// TTL检查
  always @(posedge clk) begin
    if (rst) begin
      p1_is_ttl_live <= 'd0;
    end else begin
      if (s_handshake_skid) begin
        p1_is_ttl_live <= is_ttl_live;
      end
    end
  end
  //// 源与目的IP
  always @(posedge clk) begin
    if (s_handshake_skid) begin
      p1_dst_ip <= dst_ip;
      p1_src_ip <= src_ip;
    end
  end
  //// 校验和
  // 首拍将type/code改为0，并以增量方式更新ICMP校验和。
  always @(posedge clk) begin
    if (s_handshake_skid) begin
      p1_checksum <= {15'd0, checksum_sum[16]} + checksum_sum[15:0];
    end
  end
  //// 首拍标志
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat    <= 1'b1;
      p1_is_first_beat <= 1'b0;
    end else begin
      if (s_handshake_skid) begin
        // 本包末拍握手后，下一次传输为新包首拍。
        is_first_beat    <= axis_slast_skid;
        p1_is_first_beat <= is_first_beat;
      end
    end
  end

  // p2 应答组装与丢弃
  //// 丢包状态
  always @(posedge clk) begin
    if (rst) begin
      drop_frame_locked <= 'd0;
    end else begin
      if (p1_handshake && p1_is_first_beat) begin
        drop_frame_locked <= !p1_is_ttl_live;
      end
    end
  end
  //// 有效位
  always @(posedge clk) begin
    if (rst) begin
      p2_axis_svalid <= 'd0;
    end else begin
      if (p1_handshake) begin
        if (p1_is_first_beat) begin
          p2_axis_svalid <= p1_is_ttl_live;
        end else begin
          p2_axis_svalid <= !drop_frame_locked;
        end
      end else if (p2_handshake) begin
        p2_axis_svalid <= 1'b0;
      end
    end
  end
  //// 数据与边带
  always @(posedge clk) begin
    if (p1_handshake) begin
      if (p1_is_first_beat) begin
        p2_axis_sdata <= {
          p1_axis_sdata[511:192], p1_checksum, 16'h0000, p1_src_ip, p1_dst_ip, p1_axis_sdata[95:0]
        };
      end else begin
        p2_axis_sdata <= p1_axis_sdata;
      end
      p2_axis_skeep <= p1_axis_skeep;
      p2_axis_slast <= p1_axis_slast;
    end
  end

  // 输出优先级
  assign axis_musr = cfg_arbiter_value_d1;

  // 出口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (1)
  ) axis_skid_buffer_out (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(p2_ready),
      .axis_sdata (p2_axis_sdata),
      .axis_skeep (p2_axis_skeep),
      .axis_susr  (1'b0),
      .axis_slast (p2_axis_slast),
      .axis_svalid(p2_axis_svalid),
      .axis_mready(axis_mready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid)
  );

  // TTL错误锁存，新错误优先于配置清除
  always @(posedge clk) begin
    if (rst) begin
      ttl_error <= 1'b0;
    end else if (p1_handshake && p1_is_first_beat && !p1_is_ttl_live) begin
      ttl_error <= 1'b1;
    end else if (cfg_clear_error_d1) begin
      ttl_error <= 1'b0;
    end
  end
  assign stat_ttl_error = ttl_error;

endmodule
`resetall
