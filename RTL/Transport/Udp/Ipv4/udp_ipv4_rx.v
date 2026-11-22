// -----------------------------------------------------------------------------
// File Name   : udp_ipv4_rx.v
// Module Name : udp_ipv4_rx
// Author      : LiXintao
// Created     : 2026-10-8
// Version     : v1.0

// Description : 剥离固定20字节IPv4头，输出UDP报文与头字段。
// Note        : 输入须为已筛选的无选项IPv4报文；字段保留总线字节序。
//               stat_is_df为最近已解析首拍的DF位，仅在解析后有效。
//
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_ipv4_rx #(
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

    output wire [ 7:0] protocol,
    output wire [15:0] total_len,
    output wire [ 7:0] ttl,
    output wire [31:0] src_ip,
    output wire [31:0] dst_ip,

    output wire stat_is_df  // 禁止分片
);

  // 入口skid同步缓存IPv4报文与usr。
  // p1缓存输入及首拍标志。
  // p2剥离20字节IPv4头，跨拍拼接并保存头字段。
  // 出口skid同步缓存UDP报文、usr及96位IPv4字段。

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
  reg  [         7:0] p2_protocol;
  reg  [        15:0] p2_total_len;
  reg  [         7:0] p2_ttl;
  reg  [        31:0] p2_src_ip;
  reg  [        31:0] p2_dst_ip;

  // DF状态
  reg                 is_df_reg;

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
  assign p1_tail_has_data = p1_axis_slast && (p1_axis_skeep[20] != 1'b0);
  assign p1_tail_no_data = p1_axis_slast && (p1_axis_skeep[20] == 1'b0);
  assign p1_handshake = p1_ready && p1_axis_svalid &&
      (p1_tail_has_data || axis_svalid_skid);  // 非末拍需要下一拍参与拼接

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
      if (!p1_axis_slast && axis_svalid_skid && axis_slast_skid && !axis_skeep_skid[20]) begin
        p2_axis_mdata <= {axis_sdata_skid[159:0], p1_axis_sdata[511:160]};
        p2_axis_mkeep <= {axis_skeep_skid[19:0], p1_axis_skeep[63:20]};
        p2_axis_mlast <= 1'b1;
        p2_axis_musr  <= p1_axis_susr;
      end else if (p1_tail_has_data) begin  // 最后一拍
        p2_axis_mdata <= {160'd0, p1_axis_sdata[511:160]};
        p2_axis_mkeep <= {20'd0, p1_axis_skeep[63:20]};
        p2_axis_mlast <= 1'b1;
        p2_axis_musr  <= p1_axis_susr;
      end else begin
        p2_axis_mdata <= {axis_sdata_skid[159:0], p1_axis_sdata[511:160]};
        p2_axis_mkeep <= {axis_skeep_skid[19:0], p1_axis_skeep[63:20]};
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
  //// IPv4字段
  always @(posedge clk) begin
    if (p1_handshake) begin
      if (p1_is_first_beat) begin  // 首拍保存IPv4字段
        p2_protocol <= p1_axis_sdata[79:72];
        p2_total_len <= p1_axis_sdata[31:16];
        p2_ttl <= p1_axis_sdata[71:64];
        p2_src_ip <= p1_axis_sdata[127:96];
        p2_dst_ip <= p1_axis_sdata[159:128];
      end
    end
  end

  // DF位
  always @(posedge clk) begin
    if (p1_handshake) begin
      if (p1_is_first_beat) begin  // 首拍保存IPv4字段
        is_df_reg <= p1_axis_sdata[54];
      end
    end
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
      .UsrWidth (UsrWidth + 96)
  ) axis_skid_buffer_out (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_mready_skid),
      .axis_sdata (p2_axis_mdata),
      .axis_skeep (p2_axis_mkeep),
      .axis_susr  ({p2_dst_ip, p2_src_ip, p2_ttl, p2_total_len, p2_protocol, p2_axis_musr}),
      .axis_slast (p2_axis_mlast),
      .axis_svalid(p2_axis_mvalid),
      .axis_mready(axis_mready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  ({dst_ip, src_ip, ttl, total_len, protocol, axis_musr}),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid)
  );

  // 最近已解析首拍的DF状态，保持原解析阶段更新语义。
  assign stat_is_df = is_df_reg;
endmodule
`resetall
