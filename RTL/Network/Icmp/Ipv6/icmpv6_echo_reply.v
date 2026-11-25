// -----------------------------------------------------------------------------
// File Name   : icmpv6_echo_reply.v
// Module Name : icmpv6_echo_reply
// Author      : LiXintao
// Created     : 2026-11-25
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : ICMPv6回显应答，透传Echo载荷并生成应答首部侧带。
// Note        : 输入为单播Echo Request；IPv6字段从usr提取，交换源/目的地址，应答Hop Limit为64。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module icmpv6_echo_reply #(
    parameter  integer ReqWidth         = 4,
    localparam integer TxUsrWidth       = ReqWidth + 384,
    localparam integer RxUsrWidth       = 497,
    localparam integer Ipv6HeaderOffset = 113
) (
    input wire clk,
    input wire rst,

    input wire [ReqWidth-1:0] cfg_arbiter_value,

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
    input  wire                  axis_mready
);

  // 入口skid缓存输入。
  // p1缓存输入并保存首部字段。
  // p2改写应答首部、IPv6地址与发送Hop Limit。
  // 出口skid缓存data和usr。

  // 参数范围检查
  initial begin
    if (ReqWidth < 1 || RxUsrWidth < 1) begin
      $display("错误：icmpv6_echo_reply：不支持的参数配置。");
      $finish;
    end
  end

  // 应答配置
  reg [ReqWidth-1:0] cfg_arbiter_value_d1;

  // 接收usr中的首部字段位置
  localparam integer IcmpHeaderOffset = 433;

  // 入口skid接口
  wire [         511:0] axis_sdata_skid;
  wire [          63:0] axis_skeep_skid;
  wire [RxUsrWidth-1:0] axis_susr_skid;
  wire                  axis_slast_skid;
  wire                  axis_svalid_skid;
  wire                  axis_sready_skid;
  wire                  s_handshake_skid;

  // p1 输入缓存
  reg  [         511:0] p1_axis_sdata;
  reg  [          63:0] p1_axis_skeep;
  reg                   p1_axis_slast;
  reg                   p1_axis_svalid;
  reg  [         319:0] p1_ipv6_header;
  reg  [          63:0] p1_icmp_header;

  // p2 输出缓存
  reg  [         511:0] p2_axis_sdata;
  reg  [          63:0] p2_axis_skeep;
  reg                   p2_axis_slast;
  reg                   p2_axis_svalid;
  reg  [TxUsrWidth-1:0] p2_axis_susr;

  // 首拍标志
  reg                   is_first_beat;
  reg                   p1_is_first_beat;

  // 流水控制
  wire                  p2_ready;
  wire                  p1_ready;
  wire                  p1_handshake;
  wire                  p2_handshake;

  // 流水控制
  assign p1_ready         = !p2_axis_svalid || p2_ready;
  assign axis_sready_skid = p1_ready || !p1_axis_svalid;
  assign s_handshake_skid = axis_sready_skid && axis_svalid_skid;
  assign p1_handshake     = p1_ready && p1_axis_svalid;
  assign p2_handshake     = p2_ready && p2_axis_svalid;

  // 配置寄存
  always @(posedge clk) begin
    if (rst) begin
      cfg_arbiter_value_d1 <= 'd0;
    end else begin
      cfg_arbiter_value_d1 <= cfg_arbiter_value;
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
      .axis_musr  (axis_susr_skid),
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
  //// IPv6首部侧带
  always @(posedge clk) begin
    if (s_handshake_skid) begin
      p1_ipv6_header <= axis_susr_skid[Ipv6HeaderOffset+:320];
    end
  end
  //// ICMP首部侧带
  always @(posedge clk) begin
    if (s_handshake_skid) p1_icmp_header <= axis_susr_skid[IcmpHeaderOffset+:64];
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

  // p2 应答组装
  //// 有效位
  always @(posedge clk) begin
    if (rst) begin
      p2_axis_svalid <= 'd0;
    end else begin
      if (p1_handshake) begin
        p2_axis_svalid <= 1'b1;
      end else if (p2_handshake) begin
        p2_axis_svalid <= 1'b0;
      end
    end
  end
  //// 数据与边带
  always @(posedge clk) begin
    if (p1_handshake) begin
      if (p1_is_first_beat) begin
        p2_axis_sdata <= p1_axis_sdata;
        p2_axis_susr <= {
          p1_icmp_header[63:32],
          16'd0,
          8'd0,
          8'h81,
          p1_ipv6_header[191:64],
          p1_ipv6_header[319:192],
          8'd64,
          p1_ipv6_header[55:0],
          cfg_arbiter_value_d1
        };
      end else begin
        p2_axis_sdata <= p1_axis_sdata;
      end
      p2_axis_skeep <= p1_axis_skeep;
      p2_axis_slast <= p1_axis_slast;
    end
  end

  // 出口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (TxUsrWidth)
  ) axis_skid_buffer_out (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(p2_ready),
      .axis_sdata (p2_axis_sdata),
      .axis_skeep (p2_axis_skeep),
      .axis_susr  (p2_axis_susr),
      .axis_slast (p2_axis_slast),
      .axis_svalid(p2_axis_svalid),
      .axis_mready(axis_mready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (axis_musr),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid)
  );

endmodule
`resetall
