// -----------------------------------------------------------------------------
// File Name   : ipv4_eth_rx.v
// Module Name : ipv4_eth_rx
// Author      : LiXintao
// Created     : 2026-09-19
// Version     : v2.0
// -----------------------------------------------------------------------------
// Description : IPv4接收解封装，剥离以太网头并裁剪最小帧填充。
// Note        : 上游须已去除FCS，keep从低字节连续有效，短帧裁剪依赖IPv4长度字段。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv4_eth_rx (
    input wire clk,
    input wire rst,

    input  wire [511:0] axis_sdata,
    input  wire [ 63:0] axis_skeep,
    input  wire         axis_susr,
    input  wire         axis_svalid,
    input  wire         axis_slast,
    output wire         axis_sready,

    output wire [511:0] axis_mdata,
    output wire [ 63:0] axis_mkeep,
    output wire         axis_musr,
    output wire         axis_mvalid,
    output wire         axis_mlast,
    input  wire         axis_mready,

    output wire [47:0] dst_mac,
    output wire [47:0] src_mac
);

  // 入口skid缓存完整输入。
  // p1缓存输入数据，保留待拼接拍。
  // p2跨拍拼接并剥离14字节以太网头，提取MAC地址与IPv4长度。
  // p3裁剪短帧的最小帧填充，寄存输出数据与MAC地址。
  // 出口skid同步缓存数据、错误标志和MAC地址。

  // 入口skid接口
  wire [511:0] axis_sdata_skid;
  wire [ 63:0] axis_skeep_skid;
  wire         axis_susr_skid;
  wire         axis_slast_skid;
  wire         axis_svalid_skid;
  wire         axis_sready_skid;
  wire         s_handshake_skid;

  // p1 输入缓存
  reg  [511:0] p1_axis_sdata;
  reg  [ 63:0] p1_axis_skeep;
  reg          p1_axis_slast;
  reg          p1_axis_svalid;
  reg          p1_axis_susr;

  // p2 输出缓存
  reg  [511:0] p2_axis_mdata;
  reg  [ 63:0] p2_axis_mkeep;
  reg          p2_axis_mlast;
  reg          p2_axis_mvalid;
  reg          p2_axis_musr;
  reg  [ 47:0] p2_dst_mac;
  reg  [ 47:0] p2_src_mac;

  // p3 输出缓存
  reg  [511:0] p3_axis_mdata;
  reg  [ 63:0] p3_axis_mkeep;
  reg          p3_axis_mlast;
  reg          p3_axis_mvalid;
  reg          p3_axis_musr;
  reg  [ 47:0] p3_dst_mac;
  reg  [ 47:0] p3_src_mac;

  // 首拍标志
  reg          is_first_beat;
  reg          p1_is_first_beat;
  reg          p2_is_first_beat;

  // 短帧裁剪
  reg  [ 63:0] p2_short_keep;
  reg          p2_is_short_frame;
  wire [ 15:0] ipv4_total_bytes;
  wire         p2_has_padding;

  // 流水控制
  wire         p3_ready;
  wire         p2_ready;
  wire         p1_ready;
  wire         p1_tail_has_data;
  wire         p1_tail_no_data;
  wire         p1_handshake;
  wire         p2_handshake;
  wire         m_handshake_skid;

  // 出口skid接口
  wire [511:0] axis_mdata_skid;
  wire [ 63:0] axis_mkeep_skid;
  wire         axis_musr_skid;
  wire         axis_mlast_skid;
  wire         axis_mvalid_skid;
  wire         axis_mready_skid;
  wire [ 47:0] src_mac_skid;
  wire [ 47:0] dst_mac_skid;

  // 入口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (1)
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
  assign p3_ready         = !p3_axis_mvalid || axis_mready_skid;
  assign p2_ready         = !p2_axis_mvalid || p3_ready;
  assign p1_ready         = !p2_axis_mvalid || p2_ready;
  assign axis_sready_skid = !p1_axis_svalid || p1_ready;
  assign s_handshake_skid = axis_sready_skid && axis_svalid_skid;
  assign p1_handshake     = p1_ready && p1_axis_svalid && (p1_tail_has_data || axis_svalid_skid);
  assign p2_handshake     = p2_axis_mvalid && p2_ready;
  assign m_handshake_skid = p3_axis_mvalid && axis_mready_skid;

  // p1 输入缓存
  //// 数据
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

  // p2 剥离14字节以太网头
  assign p1_tail_has_data = p1_axis_slast && (p1_axis_skeep[14] != 1'b0);
  assign p1_tail_no_data  = p1_axis_slast && (p1_axis_skeep[14] == 1'b0);
  assign ipv4_total_bytes = {p1_axis_sdata[135:128], p1_axis_sdata[143:136]};
  //// 数据
  always @(posedge clk) begin
    if (p1_handshake) begin
      // 合并不超过14字节的末拍
      if (axis_svalid_skid && axis_slast_skid && axis_skeep_skid[14] == 1'b0) begin
        p2_axis_mdata <= {axis_sdata_skid[111:0], p1_axis_sdata[511:112]};
        p2_axis_mkeep <= {axis_skeep_skid[13:0], p1_axis_skeep[63:14]};
        p2_axis_mlast <= 1'b1;
        p2_axis_musr  <= p1_axis_susr;
      end else if (p1_tail_has_data) begin  // 输出缓存末拍的剩余载荷
        p2_axis_mdata <= {112'd0, p1_axis_sdata[511:112]};
        p2_axis_mkeep <= {14'd0, p1_axis_skeep[63:14]};
        p2_axis_mlast <= 1'b1;
        p2_axis_musr  <= p1_axis_susr;
      end else begin
        p2_axis_mdata <= {axis_sdata_skid[111:0], p1_axis_sdata[511:112]};
        p2_axis_mkeep <= {axis_skeep_skid[13:0], p1_axis_skeep[63:14]};
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
          p2_axis_mvalid <= 1'b0;  // 尾拍载荷已在前一次拼接中输出
        end else begin
          p2_axis_mvalid <= 1'b1;
        end
      end else if (p2_handshake) begin
        p2_axis_mvalid <= 1'b0;
      end
    end
  end
  //// MAC地址
  always @(posedge clk) begin
    if (p1_handshake) begin
      if (p1_is_first_beat) begin
        p2_dst_mac <= p1_axis_sdata[47:0];
        p2_src_mac <= p1_axis_sdata[95:48];
      end
    end
  end
  //// 短帧有效字节掩码
  always @(posedge clk) begin
    if (p1_handshake && p1_is_first_beat) begin
      p2_is_short_frame <= ipv4_total_bytes <= 16'd46;
      p2_short_keep     <= (64'd1 << ipv4_total_bytes) - 64'd1;
    end
  end

  // p3 裁剪最小帧填充
  assign p2_has_padding = p2_is_short_frame && p2_axis_mlast && p2_axis_mkeep[45] &&
      !p2_axis_mkeep[46];
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
      p3_axis_musr  <= p2_axis_musr;
    end
  end
  //// 有效位
  always @(posedge clk) begin
    if (rst) begin
      p3_axis_mvalid <= 1'b0;
    end else begin
      if (p2_handshake) begin
        p3_axis_mvalid <= p2_axis_mvalid;
      end else if (m_handshake_skid) begin
        p3_axis_mvalid <= 1'b0;
      end
    end
  end
  //// MAC地址
  always @(posedge clk) begin
    if (p2_handshake) begin
      if (p2_is_first_beat) begin
        p3_dst_mac <= p2_dst_mac;
        p3_src_mac <= p2_src_mac;
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

  // 输出
  assign dst_mac_skid     = p3_dst_mac;
  assign src_mac_skid     = p3_src_mac;
  assign axis_mdata_skid  = p3_axis_mdata;
  assign axis_mkeep_skid  = p3_axis_mkeep;
  assign axis_mlast_skid  = p3_axis_mlast;
  assign axis_mvalid_skid = p3_axis_mvalid;
  assign axis_musr_skid   = p3_axis_musr;

  // 出口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (97)
  ) axis_skid_buffer_out (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_mready_skid),
      .axis_sdata (axis_mdata_skid),
      .axis_skeep (axis_mkeep_skid),
      .axis_susr  ({src_mac_skid, dst_mac_skid, axis_musr_skid}),
      .axis_slast (axis_mlast_skid),
      .axis_svalid(axis_mvalid_skid),
      .axis_mready(axis_mready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  ({src_mac, dst_mac, axis_musr}),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid)
  );

endmodule
`resetall
