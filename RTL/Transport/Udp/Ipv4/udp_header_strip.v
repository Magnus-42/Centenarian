// -----------------------------------------------------------------------------
// File Name   : udp_header_strip.v
// Module Name : udp_header_strip
// Author      : LiXintao
// Created     : 2026-10-19
// Version     : v1.0

// Description : 剥离8字节UDP头，输出应用载荷与端口、长度字段。
// Note        : 零载荷数据报不产生输出；本模块不校验校验和或按长度裁剪。
//
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_header_strip #(
    localparam integer UsrWidth = 193
) (
    input wire clk,
    input wire rst,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire                axis_slast,
    input  wire                axis_svalid,
    input  wire [UsrWidth-1:0] axis_susr,
    output wire                axis_sready,

    output wire [       511:0] axis_mdata,
    output wire [        63:0] axis_mkeep,
    output wire                axis_mlast,
    output wire                axis_mvalid,
    output wire [UsrWidth-1:0] axis_musr,
    input  wire                axis_mready,

    output wire [15:0] dst_port,
    output wire [15:0] src_port,
    output wire [15:0] udp_len
);

  // 入口skid缓存UDP报文与usr。
  // p1缓存UDP报文。
  // p2剥离8字节UDP头，跨拍拼接并保存端口和长度。
  // 出口skid同步缓存载荷、usr、端口和UDP长度。

  // 入口skid接口
  wire [       511:0] axis_sdata_skid;
  wire [        63:0] axis_skeep_skid;
  wire [UsrWidth-1:0] axis_susr_skid;
  wire                axis_slast_skid;
  wire                axis_svalid_skid;
  wire                axis_sready_skid;
  wire                s_handshake_skid;

  // 出口skid接口
  wire                axis_mready_skid;
  wire                m_handshake_skid;

  // p1 数据与边带
  reg  [       511:0] p1_axis_sdata;
  reg  [        63:0] p1_axis_skeep;
  reg                 p1_axis_slast;
  reg                 p1_axis_svalid;
  reg  [UsrWidth-1:0] p1_axis_susr;

  // p2 数据与边带
  reg  [       511:0] p2_axis_mdata;
  reg  [        63:0] p2_axis_mkeep;
  reg                 p2_axis_mlast;
  reg                 p2_axis_mvalid;
  reg  [UsrWidth-1:0] p2_axis_musr;

  // 首拍标志
  reg                 p1_is_first_beat;

  // 流水控制
  wire                p2_ready;
  wire                p1_ready;
  wire                p1_tail_has_data;
  wire                p1_tail_no_data;
  wire                p1_handshake;

  // p2 首拍字段
  reg  [        15:0] p2_dst_port;
  reg  [        15:0] p2_src_port;
  reg  [        15:0] p2_udp_len;

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
  assign p2_ready         = !p2_axis_mvalid || axis_mready_skid;
  assign p1_ready         = p2_ready;
  assign axis_sready_skid = !p1_axis_svalid || p1_ready;
  assign p1_tail_has_data = p1_axis_slast && p1_axis_skeep[8];
  assign p1_tail_no_data  = p1_axis_slast && !p1_axis_skeep[8];
  assign s_handshake_skid = axis_svalid_skid && axis_sready_skid;
  assign p1_handshake     = p1_ready && p1_axis_svalid && (p1_axis_slast || axis_svalid_skid);
  assign m_handshake_skid = axis_mready_skid && p2_axis_mvalid;

  // P1首拍标志
  always @(posedge clk) begin
    if (rst) begin
      p1_is_first_beat <= 1'b1;  // 复位后第一拍视为首拍
    end else begin
      if (p1_handshake) begin
        p1_is_first_beat <= p1_axis_slast;  // 本拍是末拍 -> 下一拍即新包首拍
      end
    end
  end

  // 首拍端口与长度
  always @(posedge clk) begin
    if (p1_handshake) begin
      if (p1_is_first_beat) begin
        p2_dst_port <= p1_axis_sdata[31:16];
        p2_src_port <= p1_axis_sdata[15:0];
        p2_udp_len  <= p1_axis_sdata[47:32];
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

  // p2 剥头与跨拍拼接
  //// 数据与边带
  always @(posedge clk) begin
    if (p1_handshake) begin
      if (!p1_axis_slast && axis_svalid_skid && axis_slast_skid && !axis_skeep_skid[8]) begin
        // 仅合并同一帧中不超过8字节的末拍。
        p2_axis_mdata <= {axis_sdata_skid[63:0], p1_axis_sdata[511:64]};
        p2_axis_mkeep <= {axis_skeep_skid[7:0], p1_axis_skeep[63:8]};
        p2_axis_mlast <= 1'b1;
        p2_axis_musr  <= p1_axis_susr;
      end else if (p1_tail_has_data) begin
        p2_axis_mdata <= {64'd0, p1_axis_sdata[511:64]};
        p2_axis_mkeep <= {8'd0, p1_axis_skeep[63:8]};
        p2_axis_mlast <= 1'b1;
        p2_axis_musr  <= p1_axis_susr;
      end else begin
        p2_axis_mdata <= {axis_sdata_skid[63:0], p1_axis_sdata[511:64]};
        p2_axis_mkeep <= {axis_skeep_skid[7:0], p1_axis_skeep[63:8]};
        p2_axis_mlast <= 1'b0;
        p2_axis_musr  <= p1_axis_susr;
      end
    end
  end

  //// 有效位
  always @(posedge clk) begin
    if (rst) begin
      p2_axis_mvalid <= 1'b0;
    end else begin
      if (p1_handshake) begin
        if (p1_tail_no_data) begin
          p2_axis_mvalid <= 1'b0;  // 末拍无载荷 => 本拍不产生输出
        end else begin
          p2_axis_mvalid <= 1'b1;
        end
      end else if (m_handshake_skid) begin
        p2_axis_mvalid <= 1'b0;
      end
    end
  end

  // 出口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth + 48)
  ) axis_skid_buffer_out (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_mready_skid),
      .axis_sdata (p2_axis_mdata),
      .axis_skeep (p2_axis_mkeep),
      .axis_susr  ({p2_udp_len, p2_dst_port, p2_src_port, p2_axis_musr}),
      .axis_slast (p2_axis_mlast),
      .axis_svalid(p2_axis_mvalid),
      .axis_mready(axis_mready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  ({udp_len, dst_port, src_port, axis_musr}),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid)
  );
endmodule
`resetall
