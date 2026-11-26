// -----------------------------------------------------------------------------
// File Name   : icmpv4_header_strip.v
// Module Name : icmpv4_header_strip
// Author      : Lixintao
// Created     : 2026-11-25
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 剥离8字节ICMP基本首部，输出本层负载与首部侧带。
// Note        : 上游保证ICMP报文正确，仅剥离8字节基本首部。
//               非末拍keep全1，末拍keep低位连续；首部完整的空载荷保留一拍。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module icmpv4_header_strip #(
    localparam integer UsrWidth    = 273,
    localparam integer OutUsrWidth = 337
) (
    input wire clk,
    input wire rst,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire [UsrWidth-1:0] axis_susr,
    input  wire                axis_svalid,
    input  wire                axis_slast,
    output wire                axis_sready,

    output wire [          511:0] axis_mdata,
    output wire [           63:0] axis_mkeep,
    output wire [OutUsrWidth-1:0] axis_musr,
    output wire                   axis_mvalid,
    output wire                   axis_mlast,
    input  wire                   axis_mready
);

  // 入口skid缓存完整输入。
  // p1缓存输入数据，保留待拼接拍。
  // p2跨拍拼接并剥离8字节首部，缓存完整本层首部。
  // 出口skid同步缓存载荷与首部侧带。

  // 入口skid接口
  wire [          511:0] axis_sdata_skid;
  wire [           63:0] axis_skeep_skid;
  wire [   UsrWidth-1:0] axis_susr_skid;
  wire                   axis_svalid_skid;
  wire                   axis_slast_skid;
  wire                   axis_sready_skid;
  wire                   s_handshake_skid;

  // p1 输入缓存
  reg  [          511:0] p1_axis_sdata;
  reg  [           63:0] p1_axis_skeep;
  reg  [   UsrWidth-1:0] p1_axis_susr;
  reg                    p1_axis_svalid;
  reg                    p1_axis_slast;

  // p2 输出缓存
  reg  [          511:0] p2_axis_mdata;
  reg  [           63:0] p2_axis_mkeep;
  reg  [   UsrWidth-1:0] p2_axis_musr;
  reg  [           63:0] p2_header;
  reg                    p2_axis_mvalid;
  reg                    p2_axis_mlast;

  // 首拍标志
  reg                    is_first_beat;
  reg                    p1_is_first_beat;

  // 流水控制
  wire                   p1_ready;
  wire                   p1_handshake;
  wire                   p2_ready;
  wire                   p2_handshake;
  wire                   p1_payload_empty;
  wire                   p1_tail_has_data;
  wire                   p1_tail_no_data;

  // 出口skid接口
  wire                   axis_mready_skid;
  wire [          511:0] axis_mdata_skid;
  wire [           63:0] axis_mkeep_skid;
  wire [OutUsrWidth-1:0] axis_musr_skid;
  wire                   axis_mvalid_skid;
  wire                   axis_mlast_skid;

  // 入口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth)
  ) axis_skid_buffer_in (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_svalid(axis_svalid),
      .axis_slast (axis_slast),
      .axis_sready(axis_sready),
      .axis_mdata (axis_sdata_skid),
      .axis_mkeep (axis_skeep_skid),
      .axis_musr  (axis_susr_skid),
      .axis_mvalid(axis_svalid_skid),
      .axis_mlast (axis_slast_skid),
      .axis_mready(axis_sready_skid)
  );

  // 流水控制
  assign p2_ready         = !p2_axis_mvalid || axis_mready_skid;
  assign p1_ready         = p2_ready;
  assign axis_sready_skid = !p1_axis_svalid || p1_ready;
  assign s_handshake_skid = axis_svalid_skid && axis_sready_skid;
  assign p1_handshake     = p1_ready && p1_axis_svalid && (p1_axis_slast || axis_svalid_skid);
  assign p2_handshake     = p2_axis_mvalid && axis_mready_skid;

  // p1 输入缓存
  //// 数据
  always @(posedge clk) begin
    if (s_handshake_skid) begin
      p1_axis_sdata <= axis_sdata_skid;
      p1_axis_skeep <= axis_skeep_skid;
      p1_axis_susr  <= axis_susr_skid;
      p1_axis_slast <= axis_slast_skid;
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

  // p2 剥离8字节首部
  assign p1_payload_empty = p1_is_first_beat && p1_axis_slast &&
      p1_axis_skeep[7] && !p1_axis_skeep[8];
  assign p1_tail_has_data = p1_axis_slast && (p1_axis_skeep[8] != 1'b0);
  assign p1_tail_no_data = p1_axis_slast && (p1_axis_skeep[8] == 1'b0);
  //// 数据
  always @(posedge clk) begin
    if (p1_handshake) begin
      if (!p1_axis_slast && axis_svalid_skid && axis_slast_skid && !axis_skeep_skid[8]) begin
        // 合并不超过8字节的末拍，错误标志取实际末拍。
        p2_axis_mdata <= {axis_sdata_skid[63:0], p1_axis_sdata[511:64]};
        p2_axis_mkeep <= {axis_skeep_skid[7:0], p1_axis_skeep[63:8]};
        p2_axis_mlast <= 1'b1;
        p2_axis_musr  <= axis_susr_skid;
      end else if (p1_tail_has_data || p1_payload_empty) begin  // 末拍剩余载荷或空载荷
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
          p2_axis_mvalid <= p1_payload_empty;  // 完整首部的空载荷仍提交一次
        end else begin
          p2_axis_mvalid <= 1'b1;
        end
      end else if (p2_handshake) begin
        p2_axis_mvalid <= 1'b0;
      end
    end
  end
  //// 首部字段
  always @(posedge clk) begin
    if (p1_handshake) begin
      if (p1_is_first_beat) begin
        p2_header <= p1_axis_sdata[63:0];
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
  always @(posedge clk) begin
    if (s_handshake_skid) begin
      p1_is_first_beat <= is_first_beat;
    end
  end

  // 输出
  assign axis_mdata_skid  = p2_axis_mdata;
  assign axis_mkeep_skid  = p2_axis_mkeep;
  assign axis_musr_skid   = {p2_header, p2_axis_musr};
  assign axis_mlast_skid  = p2_axis_mlast;
  assign axis_mvalid_skid = p2_axis_mvalid;

  // 出口skid同步缓存负载与首部侧带。
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (OutUsrWidth)
  ) axis_skid_buffer_out (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (axis_mdata_skid),
      .axis_skeep (axis_mkeep_skid),
      .axis_susr  (axis_musr_skid),
      .axis_svalid(axis_mvalid_skid),
      .axis_slast (axis_mlast_skid),
      .axis_sready(axis_mready_skid),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (axis_musr),
      .axis_mvalid(axis_mvalid),
      .axis_mlast (axis_mlast),
      .axis_mready(axis_mready)
  );

endmodule
`resetall
