// -----------------------------------------------------------------------------
// File Name   : ipv6_header_strip.v
// Module Name : ipv6_header_strip
// Author      : Lixintao
// Created     : 2026-11-25
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 剥离40字节IPv6基本首部，输出本层负载与首部侧带。
// Note        : 上游保证IPv6报文正确；剥离40字节基本首部并裁剪最小帧填充。
//               非末拍keep全1，末拍keep低位连续；首部完整的空载荷保留一拍。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv6_header_strip #(
    localparam integer UsrWidth    = 113,
    localparam integer OutUsrWidth = 433
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
  // p2跨拍拼接并剥离40字节首部，缓存完整本层首部。
  // p3裁剪短帧的Ethernet最小帧填充，寄存载荷与首部侧带。
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
  reg  [          319:0] p2_header;
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

  // p3 输出缓存
  reg  [          511:0] p3_axis_mdata;
  reg  [           63:0] p3_axis_mkeep;
  reg  [OutUsrWidth-1:0] p3_axis_musr;
  reg                    p3_axis_mvalid;
  reg                    p3_axis_mlast;

  // 首拍与短帧裁剪
  reg                    p2_is_first_beat;
  reg  [           63:0] p2_short_keep;
  reg                    p2_is_short_frame;
  wire [           15:0] ip_payload_bytes;
  wire                   p2_has_padding;
  wire                   p3_ready;
  wire                   m_handshake_skid;

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
  assign p2_ready         = !p2_axis_mvalid || p3_ready;
  assign p1_ready         = p2_ready;
  assign axis_sready_skid = !p1_axis_svalid || p1_ready;
  assign s_handshake_skid = axis_svalid_skid && axis_sready_skid;
  assign p1_handshake     = p1_ready && p1_axis_svalid && (p1_axis_slast || axis_svalid_skid);
  assign p2_handshake     = p2_axis_mvalid && p3_ready;
  assign p3_ready         = !p3_axis_mvalid || axis_mready_skid;
  assign m_handshake_skid = p3_axis_mvalid && axis_mready_skid;

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

  // p2 剥离40字节首部
  assign p1_payload_empty = p1_is_first_beat && p1_axis_slast &&
      p1_axis_skeep[39] && !p1_axis_skeep[40];
  assign p1_tail_has_data = p1_axis_slast && (p1_axis_skeep[40] != 1'b0);
  assign p1_tail_no_data = p1_axis_slast && (p1_axis_skeep[40] == 1'b0);
  //// 数据
  always @(posedge clk) begin
    if (p1_handshake) begin
      if (!p1_axis_slast && axis_svalid_skid && axis_slast_skid && !axis_skeep_skid[40]) begin
        // 合并不超过40字节的末拍，错误标志取实际末拍。
        p2_axis_mdata <= {axis_sdata_skid[319:0], p1_axis_sdata[511:320]};
        p2_axis_mkeep <= {axis_skeep_skid[39:0], p1_axis_skeep[63:40]};
        p2_axis_mlast <= 1'b1;
        p2_axis_musr  <= axis_susr_skid;
      end else if (p1_tail_has_data || p1_payload_empty) begin  // 末拍剩余载荷或空载荷
        p2_axis_mdata <= {320'd0, p1_axis_sdata[511:320]};
        p2_axis_mkeep <= {40'd0, p1_axis_skeep[63:40]};
        p2_axis_mlast <= 1'b1;
        p2_axis_musr  <= p1_axis_susr;
      end else begin
        p2_axis_mdata <= {axis_sdata_skid[319:0], p1_axis_sdata[511:320]};
        p2_axis_mkeep <= {axis_skeep_skid[39:0], p1_axis_skeep[63:40]};
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
        p2_header <= p1_axis_sdata[319:0];
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
  always @(posedge clk) begin
    if (p1_handshake) begin
      p2_is_first_beat <= p1_is_first_beat;
    end
  end

  // 短帧裁剪字段
  assign ip_payload_bytes = {p1_axis_sdata[39:32], p1_axis_sdata[47:40]};
  //// 有效字节掩码
  always @(posedge clk) begin
    if (p1_handshake && p1_is_first_beat) begin
      p2_short_keep <= (64'd1 << ip_payload_bytes[5:0]) - 64'd1;
    end
  end
  //// 短帧标志
  always @(posedge clk) begin
    if (p1_handshake && p1_is_first_beat) begin
      p2_is_short_frame <= ip_payload_bytes <= 16'd6;
    end
  end

  // p3 裁剪Ethernet最小帧填充
  assign p2_has_padding = p2_is_short_frame && p2_axis_mlast &&
      p2_axis_mkeep[5] && !p2_axis_mkeep[6];
  //// 数据
  always @(posedge clk) begin
    if (p2_handshake) begin
      p3_axis_mdata <= p2_axis_mdata;
      if (p2_is_first_beat) begin
        p3_axis_mkeep <= p2_has_padding ? p2_short_keep : p2_axis_mkeep;
      end else begin
        p3_axis_mkeep <= p2_axis_mkeep;
      end
      p3_axis_mlast <= p2_axis_mlast;
      p3_axis_musr  <= {p2_header, p2_axis_musr};
    end
  end
  //// 有效位
  always @(posedge clk) begin
    if (rst) begin
      p3_axis_mvalid <= 1'b0;
    end else begin
      if (p2_handshake) begin
        p3_axis_mvalid <= p2_axis_mvalid;  // 去除填充后的空载荷仍保留首部侧带
      end else if (m_handshake_skid) begin
        p3_axis_mvalid <= 1'b0;
      end
    end
  end

  // 输出
  assign axis_mdata_skid  = p3_axis_mdata;
  assign axis_mkeep_skid  = p3_axis_mkeep;
  assign axis_musr_skid   = p3_axis_musr;
  assign axis_mlast_skid  = p3_axis_mlast;
  assign axis_mvalid_skid = p3_axis_mvalid;

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
