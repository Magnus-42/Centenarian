// -----------------------------------------------------------------------------
// File Name   : udp_ipv6_rx.v
// Module Name : udp_ipv6_rx
// Author      : LiXintao
// Created     : 2026-11-22
// Version     : v1.0

// Description : 剥离固定40字节IPv6头，输出UDP报文与头字段。
// Note        : 字段保留总线字节序；版本、Next Header或首拍头长度无效时丢弃整帧。
//
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_ipv6_rx #(
    localparam integer UsrWidth = 97
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

    output wire [  7:0] next_header,
    output wire [ 15:0] payload_len,
    output wire [  7:0] hop_limit,
    output wire [127:0] src_ip,
    output wire [127:0] dst_ip
);

  // 入口skid同步缓存IPv6报文与usr。
  // p1缓存输入及首拍标志。
  // p2剥离40字节IPv6头，跨拍拼接并保存头字段。
  // 出口skid同步缓存UDP报文、usr及288位IPv6字段。

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

  // p2 首拍字段
  reg  [         7:0] p2_next_header;
  reg  [        15:0] p2_payload_len;
  reg  [         7:0] p2_hop_limit;
  reg  [       127:0] p2_src_ip;
  reg  [       127:0] p2_dst_ip;

  // 非IPv6 UDP帧丢弃状态
  reg                 drop_frame;
  wire                p1_drop;

  // 首拍标志
  reg                 is_first_beat;
  reg                 p1_is_first_beat;

  // 流水控制
  wire                p2_ready;
  wire                p1_ready;
  wire                p1_tail_has_data;
  wire                p1_tail_no_data;
  wire                p1_handshake;

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
  assign p2_ready = !p2_axis_mvalid || axis_mready_skid;
  assign p1_ready = p2_ready;
  assign axis_sready_skid = !p1_axis_svalid || p1_ready;
  assign p1_tail_has_data = p1_axis_slast && (p1_axis_skeep[40] != 1'b0);
  assign p1_tail_no_data = p1_axis_slast && (p1_axis_skeep[40] == 1'b0);
  assign p1_handshake = p1_ready && p1_axis_svalid &&
      (p1_axis_slast || axis_svalid_skid);  // 非末拍需要下一拍参与拼接
  assign p1_drop = p1_is_first_beat ?
      (p1_axis_sdata[7:4] != 4'd6 || p1_axis_sdata[55:48] != 8'd17 ||
       !(&p1_axis_skeep[47:0])) : drop_frame;

  assign s_handshake_skid = axis_sready_skid && axis_svalid_skid;
  assign m_handshake_skid = axis_mready_skid && p2_axis_mvalid;
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
      p1_axis_svalid <= 'd0;
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
      if (!p1_axis_slast && axis_svalid_skid && axis_slast_skid && !axis_skeep_skid[40]) begin
        p2_axis_mdata <= {axis_sdata_skid[319:0], p1_axis_sdata[511:320]};
        p2_axis_mkeep <= {axis_skeep_skid[39:0], p1_axis_skeep[63:40]};
        p2_axis_mlast <= 1'b1;
        p2_axis_musr  <= p1_axis_susr;
      end else if (p1_tail_has_data) begin  // 最后一拍
        p2_axis_mdata <= {340'd0, p1_axis_sdata[511:320]};
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
        if (p1_drop || p1_tail_no_data) begin
          p2_axis_mvalid <= 1'b0;  // 丢弃无效帧或已被拼接的空尾拍
        end else begin
          p2_axis_mvalid <= 1'b1;
        end
      end else if (m_handshake_skid) begin
        p2_axis_mvalid <= 1'b0;
      end
    end
  end
  //// IPv6字段
  always @(posedge clk) begin
    if (p1_handshake) begin
      if (p1_is_first_beat) begin  // 首拍保存IPv6字段
        p2_next_header <= p1_axis_sdata[55:48];
        p2_payload_len <= p1_axis_sdata[47:32];
        p2_hop_limit <= p1_axis_sdata[63:56];
        p2_src_ip <= p1_axis_sdata[191:64];
        p2_dst_ip <= p1_axis_sdata[319:192];
      end
    end
  end

  // 首拍判定结果保持到同一帧的末拍。
  always @(posedge clk) begin
    if (rst) drop_frame <= 1'b0;
    else if (p1_handshake && p1_is_first_beat) drop_frame <= p1_drop;
  end
  // 输入首拍标志
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

  // 出口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth + 288)
  ) axis_skid_buffer_out (
      .clk(clk),
      .rst(rst),
      .axis_sready(axis_mready_skid),
      .axis_sdata(p2_axis_mdata),
      .axis_skeep(p2_axis_mkeep),
      .axis_susr({
        p2_dst_ip, p2_src_ip, p2_hop_limit, p2_payload_len, p2_next_header, p2_axis_musr
      }),
      .axis_slast(p2_axis_mlast),
      .axis_svalid(p2_axis_mvalid),
      .axis_mready(axis_mready),
      .axis_mdata(axis_mdata),
      .axis_mkeep(axis_mkeep),
      .axis_musr({dst_ip, src_ip, hop_limit, payload_len, next_header, axis_musr}),
      .axis_mlast(axis_mlast),
      .axis_mvalid(axis_mvalid)
  );
endmodule
`resetall
