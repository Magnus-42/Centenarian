// -----------------------------------------------------------------------------
// File Name   : axis_skid_buffer.v
// Module Name : axis_skid_buffer
// Author      : LiXintao
// Created     : 2026-09-20
// Version     : 1.1
// -----------------------------------------------------------------------------
// Description : AXIS skid缓冲，阻断下游ready的组合传递。
// Note        : 上游ready由skid有效位产生，最小传输延迟为1拍。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module axis_skid_buffer #(
    parameter  integer DataWidth = 8,
    parameter  integer UsrWidth  = 1,
    localparam integer KeepWidth = DataWidth / 8
) (
    input wire clk,
    input wire rst,

    output wire                 axis_sready,
    input  wire [DataWidth-1:0] axis_sdata,
    input  wire [KeepWidth-1:0] axis_skeep,
    input  wire [ UsrWidth-1:0] axis_susr,
    input  wire                 axis_slast,
    input  wire                 axis_svalid,

    input  wire                 axis_mready,
    output wire [DataWidth-1:0] axis_mdata,
    output wire [KeepWidth-1:0] axis_mkeep,
    output wire [ UsrWidth-1:0] axis_musr,
    output wire                 axis_mlast,
    output wire                 axis_mvalid
);

  // p1寄存AXIS输出，skid在下游阻塞时暂存一拍。

  // 参数范围检查
  initial begin
    if (DataWidth < 8 || DataWidth % 8 != 0 || UsrWidth < 1) begin
      $display("错误：axis_skid_buffer：不支持的参数配置。");
      $finish;
    end
  end

  // p1 输出缓存
  reg  [DataWidth-1:0] p1_axis_mdata;
  reg  [KeepWidth-1:0] p1_axis_mkeep;
  reg  [ UsrWidth-1:0] p1_axis_musr;
  reg                  p1_axis_mlast;
  reg                  p1_axis_mvalid;
  wire                 p1_can_take;

  // skid暂存
  reg  [DataWidth-1:0] axis_mdata_skid;
  reg  [KeepWidth-1:0] axis_mkeep_skid;
  reg  [ UsrWidth-1:0] axis_musr_skid;
  reg                  axis_mlast_skid;
  reg                  axis_mvalid_skid;
  wire                 s_to_skid;

  // 握手与转移控制
  wire                 s_handshake;
  wire                 m_handshake;
  wire                 skid_to_p1;
  wire                 s_to_p1;

  // 握手与转移控制
  assign s_handshake = axis_svalid && axis_sready;
  assign m_handshake = axis_mready && axis_mvalid;
  assign axis_sready = !axis_mvalid_skid;

  assign p1_can_take = !p1_axis_mvalid || m_handshake;
  assign skid_to_p1  = axis_mvalid_skid && p1_can_take;
  assign s_to_p1     = s_handshake && p1_can_take;
  assign s_to_skid   = s_handshake && !p1_can_take;

  // 有效位与usr
  always @(posedge clk) begin
    if (rst) begin
      p1_axis_musr     <= 'd0;
      p1_axis_mvalid   <= 'd0;
      axis_musr_skid   <= 'd0;
      axis_mvalid_skid <= 'd0;
    end else begin
      p1_axis_musr <= p1_can_take ? (axis_mvalid_skid ? axis_musr_skid : axis_susr) : p1_axis_musr;
      p1_axis_mvalid <= (s_to_p1 || skid_to_p1) ? 1'b1 : (m_handshake ? 1'b0 : p1_axis_mvalid);
      axis_musr_skid <= (axis_sready && !p1_can_take) ? axis_susr : axis_musr_skid;
      axis_mvalid_skid <= s_to_skid ? 1'b1 : (skid_to_p1 ? 1'b0 : axis_mvalid_skid);
    end
  end

  // 数据、keep与last
  always @(posedge clk) begin
    p1_axis_mdata <=
       p1_can_take ? (axis_mvalid_skid ? axis_mdata_skid : axis_sdata) : p1_axis_mdata;
    p1_axis_mkeep <=
       p1_can_take ? (axis_mvalid_skid ? axis_mkeep_skid : axis_skeep) : p1_axis_mkeep;
    p1_axis_mlast <=
       p1_can_take ? (axis_mvalid_skid ? axis_mlast_skid : axis_slast) : p1_axis_mlast;

    axis_mdata_skid <= (axis_sready && !p1_can_take) ? axis_sdata : axis_mdata_skid;
    axis_mkeep_skid <= (axis_sready && !p1_can_take) ? axis_skeep : axis_mkeep_skid;
    axis_mlast_skid <= (axis_sready && !p1_can_take) ? axis_slast : axis_mlast_skid;
  end

  // 输出
  assign axis_mdata  = p1_axis_mdata;
  assign axis_mkeep  = p1_axis_mkeep;
  assign axis_musr   = p1_axis_musr;
  assign axis_mlast  = p1_axis_mlast;
  assign axis_mvalid = p1_axis_mvalid;
endmodule
`resetall
