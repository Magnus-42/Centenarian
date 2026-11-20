// -----------------------------------------------------------------------------
// File Name   : skid_buffer.v
// Module Name : skid_buffer
// Author      : LiXintao
// Created     : 2026-09-20
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : skid缓冲，阻断下游ready的组合传递。
// Note        : 上游ready由skid有效位产生，最小传输延迟为1拍。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module skid_buffer #(
    parameter integer DataWidth = 1
) (
    input wire clk,
    input wire rst,

    output wire                 sready,
    input  wire [DataWidth-1:0] sdata,
    input  wire                 svalid,

    input  wire                 mready,
    output wire [DataWidth-1:0] mdata,
    output wire                 mvalid
);

  // p1寄存输出，skid在下游阻塞时暂存一拍。

  // 参数范围检查
  initial begin
    if (DataWidth < 1) begin
      $display("错误：skid_buffer：不支持的参数配置。");
      $finish;
    end
  end

  // p1 输出缓存
  reg  [DataWidth-1:0] p1_mdata;
  reg                  p1_mvalid;
  wire                 p1_can_take;

  // skid暂存
  reg  [DataWidth-1:0] mdata_skid;
  reg                  mvalid_skid;
  wire                 s_to_skid;

  // 握手与转移控制
  wire                 s_handshake;
  wire                 m_handshake;
  wire                 skid_to_p1;
  wire                 s_to_p1;

  // 握手与转移控制
  assign s_handshake = svalid && sready;
  assign m_handshake = mready && mvalid;
  assign sready      = !mvalid_skid;

  assign p1_can_take = !p1_mvalid || m_handshake;
  assign skid_to_p1  = mvalid_skid && p1_can_take;
  assign s_to_p1     = s_handshake && p1_can_take;
  assign s_to_skid   = s_handshake && !p1_can_take;

  // 有效位
  always @(posedge clk) begin
    if (rst) begin
      p1_mvalid   <= 'd0;
      mvalid_skid <= 'd0;
    end else begin
      if (s_to_p1 || skid_to_p1) p1_mvalid <= 1'b1;
      else if (m_handshake) p1_mvalid <= 1'b0;

      if (s_to_skid) mvalid_skid <= 1'b1;
      else if (skid_to_p1) mvalid_skid <= 1'b0;
    end
  end

  // 数据位
  always @(posedge clk) begin
    if (skid_to_p1) p1_mdata <= mdata_skid;
    else if (p1_can_take) p1_mdata <= sdata;
  end
  always @(posedge clk) begin
    if (sready && !p1_can_take) mdata_skid <= sdata;
  end

  // 输出
  assign mdata  = p1_mdata;
  assign mvalid = p1_mvalid;

endmodule
`resetall
