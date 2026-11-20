// -----------------------------------------------------------------------------
// File Name   : ipv6_eth_header_add.v
// Module Name : ipv6_eth_header_add
// Author      : LiXintao
// Created     : 2026-09-18
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : IPv6发送封装，插入14字节以太网头。
// Note        : 末拍高14字节含有效载荷时，增加一个尾拍。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv6_eth_header_add #(
    parameter  integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth
) (
    input wire clk,
    input wire rst,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire [UsrWidth-1:0] axis_susr,
    input  wire                axis_svalid,
    input  wire                axis_slast,
    output wire                axis_sready,

    input wire [47:0] dst_mac,
    input wire [47:0] src_mac,

    output wire [       511:0] axis_mdata,
    output wire [        63:0] axis_mkeep,
    output wire [UsrWidth-1:0] axis_musr,
    output wire                axis_mvalid,
    output wire                axis_mlast,
    input  wire                axis_mready
);

  // 入口skid同步缓存输入数据与MAC地址。
  // p1缓存数据与MAC地址，记录末拍是否需要补发尾拍。
  // p2插入以太网头并拼接跨拍数据，必要时补发尾拍。
  // 出口skid缓存输出。

  // 参数范围检查
  initial begin
    if (ReqWidth < 1) begin
      $display("错误：ipv6_eth_header_add：ReqWidth必须不小于1。");
      $finish;
    end
  end

  // 内部常量
  localparam integer EthHeaderBits = 112;

  // 入口skid接口
  wire [              511:0] axis_sdata_skid;
  wire [               63:0] axis_skeep_skid;
  wire [       UsrWidth-1:0] axis_susr_skid;
  wire                       axis_slast_skid;
  wire                       axis_svalid_skid;
  wire                       axis_sready_skid;
  wire                       s_handshake_skid;

  // p1 输入缓存
  reg  [              511:0] p1_axis_sdata;
  reg  [               63:0] p1_axis_skeep;
  reg                        p1_axis_slast;
  reg                        p1_axis_svalid;
  reg  [       UsrWidth-1:0] p1_axis_susr;
  reg  [               47:0] p1_dst_mac;
  reg  [               47:0] p1_src_mac;

  // 跨拍缓存
  reg  [  EthHeaderBits-1:0] data_held;
  reg  [EthHeaderBits/8-1:0] keep_held;
  reg  [       UsrWidth-1:0] usr_held;

  // p2 输出缓存
  reg  [              511:0] p2_axis_mdata;
  reg  [               63:0] p2_axis_mkeep;
  reg                        p2_axis_mlast;
  reg                        p2_axis_mvalid;
  reg  [       UsrWidth-1:0] p2_axis_musr;

  // 首拍标志
  reg                        is_first_beat;

  // 尾拍补发控制
  reg                        tail_pending;
  reg                        p2_tail_pending;

  // 流水控制
  wire                       p2_can_take;
  wire                       tail_to_p2;
  wire                       p1_ready;
  wire                       m_handshake_skid;
  wire                       p1_handshake;

  // 出口skid接口
  wire [               47:0] src_mac_skid;
  wire [               47:0] dst_mac_skid;
  wire [              511:0] axis_mdata_skid;
  wire [               63:0] axis_mkeep_skid;
  wire [       UsrWidth-1:0] axis_musr_skid;
  wire                       axis_mlast_skid;
  wire                       axis_mvalid_skid;
  wire                       axis_mready_skid;

  // 入口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth + 96)
  ) axis_skid_buffer_in (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_sready),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  ({src_mac, dst_mac, axis_susr}),
      .axis_slast (axis_slast),
      .axis_svalid(axis_svalid),
      .axis_mready(axis_sready_skid),
      .axis_mdata (axis_sdata_skid),
      .axis_mkeep (axis_skeep_skid),
      .axis_musr  ({src_mac_skid, dst_mac_skid, axis_susr_skid}),
      .axis_mlast (axis_slast_skid),
      .axis_mvalid(axis_svalid_skid)
  );

  // 流水控制
  assign p2_can_take      = !p2_axis_mvalid || axis_mready_skid;
  assign tail_to_p2       = p2_tail_pending && p2_can_take;
  assign p1_ready         = (!p2_axis_mvalid || axis_mready_skid) && !p2_tail_pending;
  assign m_handshake_skid = p2_axis_mvalid && axis_mready_skid;
  assign s_handshake_skid = axis_sready_skid && axis_svalid_skid;
  assign p1_handshake     = p1_ready && p1_axis_svalid;
  assign axis_sready_skid = (!p1_axis_svalid || p1_ready) && !tail_pending;

  // 首拍标志
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;
    end else begin
      if (p1_handshake) begin
        is_first_beat <= p1_axis_slast;
      end
    end
  end

  // p1 输入缓存
  //// 数据与MAC地址
  always @(posedge clk) begin
    if (s_handshake_skid) begin
      p1_axis_sdata <= axis_sdata_skid;
      p1_axis_skeep <= axis_skeep_skid;
      p1_axis_slast <= axis_slast_skid;
      p1_axis_susr  <= axis_susr_skid;
      p1_dst_mac    <= dst_mac_skid;
      p1_src_mac    <= src_mac_skid;
    end
  end
  //// 有效位
  always @(posedge clk) begin
    if (rst) p1_axis_svalid <= 1'b0;
    else if (s_handshake_skid) p1_axis_svalid <= 1'b1;
    else if (p1_handshake) p1_axis_svalid <= 1'b0;
  end
  //// 尾拍补发控制
  always @(posedge clk) begin
    if (rst) begin
      tail_pending <= 'd0;
    end else begin
      if (s_handshake_skid) begin
        tail_pending <= axis_slast_skid ?
            axis_skeep_skid[63-:(EthHeaderBits/8)] != {(EthHeaderBits / 8) {1'b0}} : 'd0;
      end else if (p1_handshake) begin
        tail_pending <= 'd0;
      end
    end
  end

  // p2 插入以太网头与补发尾拍
  //// p2 待补发标志
  always @(posedge clk) begin
    if (rst) begin
      p2_tail_pending <= 'd0;
    end else begin
      if (p1_handshake) begin
        p2_tail_pending <= tail_pending;
      end else if (tail_to_p2) begin
        p2_tail_pending <= 'd0;
      end
    end
  end
  //// 跨拍缓存
  always @(posedge clk) begin
    if (p1_handshake) begin
      data_held <= p1_axis_sdata[511-:EthHeaderBits];
      keep_held <= p1_axis_skeep[63-:(EthHeaderBits/8)];
      usr_held  <= p1_axis_susr;
    end
  end
  //// 数据
  always @(posedge clk) begin
    if (tail_to_p2) begin
      p2_axis_mdata <= {{(512 - EthHeaderBits) {1'b0}}, data_held};
      p2_axis_musr  <= usr_held;
      p2_axis_mkeep <= {{(64 - EthHeaderBits / 8) {1'b0}}, keep_held};
      p2_axis_mlast <= 1'b1;
    end else if (p1_handshake) begin
      if (is_first_beat) begin
        p2_axis_mdata <= {p1_axis_sdata[511-EthHeaderBits:0], 16'hDD86, p1_src_mac, p1_dst_mac};
        p2_axis_mkeep <= {p1_axis_skeep[63-EthHeaderBits/8:0], 14'b1111_1111_1111_11};
      end else begin
        p2_axis_mdata <= {p1_axis_sdata[511-EthHeaderBits:0], data_held};
        p2_axis_mkeep <= {p1_axis_skeep[63-EthHeaderBits/8:0], keep_held};
      end
      p2_axis_mlast <= !tail_pending && p1_axis_slast;
      p2_axis_musr  <= p1_axis_susr;
    end else if (m_handshake_skid) begin
      p2_axis_mlast <= 1'b0;
    end
  end
  //// 有效位
  always @(posedge clk) begin
    if (rst) begin
      p2_axis_mvalid <= 'd0;
    end else begin
      if (p1_handshake || p2_tail_pending) begin
        p2_axis_mvalid <= 1'b1;
      end else if (m_handshake_skid) begin
        p2_axis_mvalid <= 1'b0;
      end
    end
  end

  // 输出
  assign axis_mdata_skid  = p2_axis_mdata;
  assign axis_mkeep_skid  = p2_axis_mkeep;
  assign axis_mlast_skid  = p2_axis_mlast;
  assign axis_mvalid_skid = p2_axis_mvalid;
  assign axis_musr_skid   = p2_axis_musr;

  // 出口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth)
  ) axis_skid_buffer_out (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_mready_skid),
      .axis_sdata (axis_mdata_skid),
      .axis_skeep (axis_mkeep_skid),
      .axis_susr  (axis_musr_skid),
      .axis_slast (axis_mlast_skid),
      .axis_svalid(axis_mvalid_skid),
      .axis_mready(axis_mready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (axis_musr),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid)
  );

endmodule
`resetall
