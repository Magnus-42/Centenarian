// -----------------------------------------------------------------------------
// File Name   : icmpv4_type_demux.v
// Module Name : icmpv4_type_demux
// Author      : LiXintao
// Created     : 2026-10-17
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : ICMPv4类型分流，区分回显请求与其他报文。
// Note        : 输入为ICMP载荷，usr携带ICMP及上游首部；检查分片与type/code。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module icmpv4_type_demux #(
    localparam integer UsrWidth         = 337,
    localparam integer Ipv4HeaderOffset = 113
) (
    input wire clk,
    input wire rst,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire [UsrWidth-1:0] axis_susr,
    input  wire                axis_svalid,
    input  wire                axis_slast,
    output wire                axis_sready,

    output wire [       511:0] echo_axis_mdata,
    output wire [        63:0] echo_axis_mkeep,
    output wire [UsrWidth-1:0] echo_axis_musr,
    output wire                echo_axis_mvalid,
    output wire                echo_axis_mlast,
    input  wire                echo_axis_mready,

    output wire [       511:0] other_axis_mdata,
    output wire [        63:0] other_axis_mkeep,
    output wire [UsrWidth-1:0] other_axis_musr,
    output wire                other_axis_mvalid,
    output wire                other_axis_mlast,
    input  wire                other_axis_mready
);

  // 入口skid后匹配type/code与usr中的IPv4分片字段。
  // p1缓存输入并锁定帧路由，各通道skid独立缓存输出。

  // 参数范围检查
  initial begin
    if (UsrWidth < 1) begin
      $display("错误：icmpv4_type_demux：不支持的参数配置。");
      $finish;
    end
  end

  // 接收usr中的首部字段位置
  localparam integer IcmpHeaderOffset = 273;

  // 入口skid接口
  wire [       511:0] axis_sdata_skid;
  wire [        63:0] axis_skeep_skid;
  wire                axis_slast_skid;
  wire                axis_svalid_skid;
  wire                axis_sready_skid;
  wire [UsrWidth-1:0] axis_susr_skid;
  wire                s_handshake_skid;

  // p1 输入缓存
  reg  [       511:0] p1_axis_sdata;
  reg  [        63:0] p1_axis_skeep;
  reg                 p1_axis_slast;
  reg                 p1_axis_svalid;
  reg  [UsrWidth-1:0] p1_axis_susr;

  // 首拍标志
  reg                 is_first_beat;

  // 协议匹配与帧路由
  wire [        15:0] flags_fragment;
  wire                is_unfragmented;
  wire                is_echo_request;
  wire                matches_echo;
  reg                 echo_selected_locked;

  // 流水控制
  wire                p1_ready;
  wire                p1_handshake;

  // 出口skid接口
  wire                echo_axis_mready_skid;
  wire                other_axis_mready_skid;

  // 协议匹配
  assign flags_fragment = axis_susr_skid[Ipv4HeaderOffset+48+:16];
  assign is_unfragmented = !flags_fragment[5] && (flags_fragment[4:0] == 5'd0) &&
      (flags_fragment[15:8] == 8'd0);
  assign is_echo_request = (axis_susr_skid[IcmpHeaderOffset+:16] == 16'h0008);
  assign matches_echo = is_unfragmented && is_echo_request;

  // 流水控制
  assign s_handshake_skid = axis_svalid_skid && axis_sready_skid;
  assign p1_ready = (echo_selected_locked && echo_axis_mready_skid) ||
      (!echo_selected_locked && other_axis_mready_skid);
  assign p1_handshake = p1_ready && p1_axis_svalid;
  assign axis_sready_skid = !p1_axis_svalid || p1_ready;

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

  // 帧路由锁定
  always @(posedge clk) begin
    if (rst) begin
      echo_selected_locked <= 1'b0;
    end else begin
      if (s_handshake_skid && is_first_beat) begin
        echo_selected_locked <= matches_echo;
      end
    end
  end

  // 首拍标志
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;
    end else begin
      if (s_handshake_skid) begin
        is_first_beat <= axis_slast_skid;
      end
    end
  end

  // p1 输入缓存
  //// 数据与边带
  always @(posedge clk) begin
    if (s_handshake_skid) begin
      p1_axis_sdata <= axis_sdata_skid;
      p1_axis_skeep <= axis_skeep_skid;
      p1_axis_slast <= axis_slast_skid;
      p1_axis_susr  <= axis_susr_skid;
    end
  end
  //// 有效位
  always @(posedge clk) begin
    if (rst) begin
      p1_axis_svalid <= 1'b0;
    end else begin
      if (s_handshake_skid) begin
        p1_axis_svalid <= 1'b1;
      end else if (p1_handshake) begin
        p1_axis_svalid <= 1'b0;
      end
    end
  end

  // 回显通道
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth)
  ) axis_skid_buffer_echo (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(echo_axis_mready_skid),
      .axis_sdata (p1_axis_sdata),
      .axis_skeep (p1_axis_skeep),
      .axis_susr  (p1_axis_susr),
      .axis_slast (p1_axis_slast),
      .axis_svalid(p1_axis_svalid && echo_selected_locked),
      .axis_mready(echo_axis_mready),
      .axis_mdata (echo_axis_mdata),
      .axis_mkeep (echo_axis_mkeep),
      .axis_musr  (echo_axis_musr),
      .axis_mlast (echo_axis_mlast),
      .axis_mvalid(echo_axis_mvalid)
  );

  // 其他通道
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth)
  ) axis_skid_buffer_other (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(other_axis_mready_skid),
      .axis_sdata (p1_axis_sdata),
      .axis_skeep (p1_axis_skeep),
      .axis_susr  (p1_axis_susr),
      .axis_slast (p1_axis_slast),
      .axis_svalid(p1_axis_svalid && !echo_selected_locked),
      .axis_mready(other_axis_mready),
      .axis_mdata (other_axis_mdata),
      .axis_mkeep (other_axis_mkeep),
      .axis_musr  (other_axis_musr),
      .axis_mlast (other_axis_mlast),
      .axis_mvalid(other_axis_mvalid)
  );

endmodule
`resetall
