// -----------------------------------------------------------------------------
// File Name   : arp_rx.v
// Module Name : arp_rx
// Author      : LiXintao
// Created     : 2026-09-14
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 从ARP负载提取ARP字段
// Note        : 接收单拍ARP报文，检查last、坏帧标志及字段对应的keep有效位
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module arp_rx #(
    parameter  integer DataWidth = 512,
    localparam integer UsrWidth  = 113   // MAC首部及末拍错误标志
) (
    input wire clk,
    input wire rst,

    // ARP帧字段接口
    output wire        frame_valid,
    input  wire        frame_ready,
    output wire [15:0] arp_htype,
    output wire [15:0] arp_ptype,
    output wire [ 7:0] arp_hlen,
    output wire [ 7:0] arp_plen,
    output wire [15:0] arp_oper,
    output wire [47:0] arp_sha,      // 发送方MAC地址
    output wire [31:0] arp_spa,      // 发送方IP地址
    output wire [47:0] arp_tha,      // 目标MAC地址
    output wire [31:0] arp_tpa,      // 目标IP地址

    // ARP AXIS接收接口
    input  wire [  DataWidth-1:0] axis_sdata,
    input  wire [DataWidth/8-1:0] axis_skeep,
    input  wire                   axis_svalid,
    input  wire                   axis_slast,
    input  wire [   UsrWidth-1:0] axis_susr,
    output wire                   axis_sready,

    output wire stat_error_pulse

);

  // 入口skid缓存输入，p1检查单拍帧的last、usr与头部keep。
  // 合法帧寄存ARP字段，非法帧输出错误脉冲。

  // 参数范围检查
  initial begin
    if (DataWidth < 224 || DataWidth % 8 != 0) begin
      $display("错误：arp_rx：DataWidth必须不小于224且为8的整数倍");
      $finish;
    end
  end

  // 内部常量
  localparam integer HeaderBytes = 28;
  localparam integer HeaderWidth = HeaderBytes * 8;

  // 入口skid接口
  wire [  DataWidth-1:0] axis_sdata_skid;
  wire [DataWidth/8-1:0] axis_skeep_skid;
  wire [   UsrWidth-1:0] axis_susr_skid;
  wire                   axis_slast_skid;
  wire                   axis_svalid_skid;
  wire                   axis_sready_skid;
  wire                   s_handshake_skid;

  // 接收握手
  wire                   frame_handshake;

  // p1 字段与接收状态
  reg                    p1_frame_valid;
  reg  [           15:0] p1_arp_htype;
  reg  [           15:0] p1_arp_ptype;
  reg  [            7:0] p1_arp_hlen;
  reg  [            7:0] p1_arp_plen;
  reg  [           15:0] p1_arp_oper;
  reg  [           47:0] p1_arp_sha;
  reg  [           31:0] p1_arp_spa;
  reg  [           47:0] p1_arp_tha;
  reg  [           31:0] p1_arp_tpa;
  reg                    p1_error_pulse;

  // 入口skid
  axis_skid_buffer #(
      .DataWidth(DataWidth),
      .UsrWidth (UsrWidth)
  ) axis_skid_buffer_inst (
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

  // 接收握手
  assign s_handshake_skid = axis_sready_skid && axis_svalid_skid;
  assign frame_handshake  = frame_valid && frame_ready;
  assign axis_sready_skid = !frame_valid || frame_ready;

  // 单级字段缓存，非法输入不产生有效结果
  always @(posedge clk) begin
    if (rst) begin
      p1_frame_valid <= 'd0;
      p1_error_pulse <= 'd0;
    end else begin
      p1_error_pulse <= 1'b0;
      if (s_handshake_skid) begin
        if (axis_slast_skid && (!axis_susr_skid[0]) &&
            (axis_skeep_skid[HeaderBytes-1:0] == {HeaderBytes{1'b1}})) begin
          p1_frame_valid <= 1'b1;
          {p1_arp_tpa, p1_arp_tha, p1_arp_spa, p1_arp_sha, p1_arp_oper, p1_arp_plen, p1_arp_hlen,
           p1_arp_ptype, p1_arp_htype} <=
              axis_sdata_skid[HeaderWidth-1:0];
        end else begin
          p1_frame_valid <= 1'b0;
          p1_error_pulse <= 1'b1;
        end
      end else if (frame_handshake) begin
        p1_frame_valid <= 1'b0;
      end
    end
  end

  // 字段与接收状态输出
  assign stat_error_pulse = p1_error_pulse;
  assign frame_valid      = p1_frame_valid;
  assign arp_htype        = p1_arp_htype;
  assign arp_ptype        = p1_arp_ptype;
  assign arp_hlen         = p1_arp_hlen;
  assign arp_plen         = p1_arp_plen;
  assign arp_oper         = p1_arp_oper;
  assign arp_sha          = p1_arp_sha;
  assign arp_spa          = p1_arp_spa;
  assign arp_tha          = p1_arp_tha;
  assign arp_tpa          = p1_arp_tpa;

endmodule
`resetall
