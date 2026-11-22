// -----------------------------------------------------------------------------
// File Name   : udp_ipv6_tx.v
// Module Name : udp_ipv6_tx
// Author      : LiXintao
// Created     : 2026-11-22
// Version     : v1.0

// Description : UDP发送链，计算长度和校验和并插入UDP及IPv6头。
//
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_ipv6_tx #(
    parameter  integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth + 296
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
    output wire [ReqWidth-1:0] axis_musr,
    input  wire                axis_mready
);

  // 整包缓存载荷并计算UDP长度与校验和。
  // 依次插入UDP头和IPv6头，出口保留请求字段。

  // 参数范围检查
  initial begin
    if (ReqWidth < 1) begin
      $display("错误：udp_ipv6_tx：不支持的参数配置。");
      $finish;
    end
  end

  // 长度与校验和接口
  wire [       511:0] checksum_data;
  wire [        63:0] checksum_keep;
  wire                checksum_last;
  wire                checksum_valid;
  wire [UsrWidth-1:0] checksum_usr;
  wire                checksum_ready;
  wire [        15:0] pkt_udp_len;
  wire [        15:0] pkt_udp_checksum;

  // UDP封装接口
  wire [       511:0] udp_header_data;
  wire [        63:0] udp_header_keep;
  wire                udp_header_last;
  wire                udp_header_valid;
  wire [UsrWidth-1:0] udp_header_usr;
  wire                udp_header_ready;

  // IPv6封装接口
  wire [       511:0] ipv6_header_data;
  wire [        63:0] ipv6_header_keep;
  wire                ipv6_header_last;
  wire                ipv6_header_valid;
  wire [UsrWidth-1:0] ipv6_header_usr;
  wire                ipv6_header_ready;

  // 长度与校验和
  udp_ipv6_len_checksum #(
      .ReqWidth(ReqWidth)
  ) udp_ipv6_len_checksum_inst (
      .clk          (clk),
      .rst          (rst),
      .axis_sdata   (axis_sdata),
      .axis_skeep   (axis_skeep),
      .axis_slast   (axis_slast),
      .axis_svalid  (axis_svalid),
      .axis_susr    (axis_susr),
      .axis_sready  (axis_sready),
      .axis_mdata   (checksum_data),
      .axis_mkeep   (checksum_keep),
      .axis_mlast   (checksum_last),
      .axis_mvalid  (checksum_valid),
      .axis_musr    (checksum_usr),
      .axis_mready  (checksum_ready),
      .total_len    (pkt_udp_len),
      .head_checksum(pkt_udp_checksum)
  );

  // UDP头插入
  udp_ipv6_udp_header_add #(
      .ReqWidth(ReqWidth)
  ) udp_ipv6_udp_header_add_inst (
      .clk              (clk),
      .rst              (rst),
      .axis_sdata       (checksum_data),
      .axis_skeep       (checksum_keep),
      .axis_slast       (checksum_last),
      .axis_svalid      (checksum_valid),
      .axis_susr        (checksum_usr),
      .axis_sready      (checksum_ready),
      .pkt_total_len    (pkt_udp_len),
      .pkt_head_checksum(pkt_udp_checksum),
      .axis_mdata       (udp_header_data),
      .axis_mkeep       (udp_header_keep),
      .axis_mlast       (udp_header_last),
      .axis_mvalid      (udp_header_valid),
      .axis_musr        (udp_header_usr),
      .axis_mready      (udp_header_ready)
  );

  // IPv6头插入
  udp_ipv6_header_add #(
      .ReqWidth(ReqWidth)
  ) udp_ipv6_header_add_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (udp_header_data),
      .axis_skeep (udp_header_keep),
      .axis_slast (udp_header_last),
      .axis_svalid(udp_header_valid),
      .axis_susr  (udp_header_usr),
      .axis_sready(udp_header_ready),
      .axis_mdata (ipv6_header_data),
      .axis_mkeep (ipv6_header_keep),
      .axis_mlast (ipv6_header_last),
      .axis_mvalid(ipv6_header_valid),
      .axis_musr  (ipv6_header_usr),
      .axis_mready(ipv6_header_ready)
  );

  // 输出：IPv6头已插入，仅保留低ReqWidth位请求字段。
  assign axis_mdata        = ipv6_header_data;
  assign axis_mkeep        = ipv6_header_keep;
  assign axis_mlast        = ipv6_header_last;
  assign axis_mvalid       = ipv6_header_valid;
  assign axis_musr         = ipv6_header_usr[ReqWidth-1:0];
  assign ipv6_header_ready = axis_mready;
endmodule
`resetall
