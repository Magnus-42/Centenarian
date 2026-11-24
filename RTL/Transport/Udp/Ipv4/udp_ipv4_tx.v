// -----------------------------------------------------------------------------
// File Name   : udp_ipv4_tx.v
// Module Name : udp_ipv4_tx
// Author      : LiXintao
// Created     : 2026-10-18
// Version     : v2.1
// -----------------------------------------------------------------------------
// Description : UDP发送链，计算长度与校验和，添加UDP头并提供IPv4头元数据。
// Note        : 输入data为UDP载荷，usr提供IPv4首部。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_ipv4_tx #(
    parameter  integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth + 104
) (
    input wire clk,
    input wire rst,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire                axis_slast,
    input  wire                axis_svalid,
    input  wire [UsrWidth-1:0] axis_susr,
    output wire                axis_sready,

    output wire [           511:0] axis_mdata,
    output wire [            63:0] axis_mkeep,
    output wire                    axis_mlast,
    output wire                    axis_mvalid,
    output wire [ReqWidth+160-1:0] axis_musr,
    input  wire                    axis_mready
);

  // 整包缓存载荷并计算UDP长度与校验和。
  // 插入UDP头；出口usr提供IPv4头元数据。

  // 参数范围检查
  initial begin
    if (ReqWidth < 1) begin
      $display("错误：udp_ipv4_tx：不支持的参数配置。");
      $finish;
    end
  end

  // 长度与校验和接口
  wire [511:0] checksum_data;
  wire [63:0] checksum_keep;
  wire checksum_last;
  wire checksum_valid;
  wire [UsrWidth-1:0] checksum_usr;
  wire checksum_ready;
  wire [15:0] pkt_udp_len;
  wire [15:0] pkt_udp_checksum;

  // 长度与校验和
  udp_ipv4_len_checksum #(
      .ReqWidth(ReqWidth)
  ) udp_ipv4_len_checksum_inst (
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
  udp_ipv4_header_add #(
      .ReqWidth(ReqWidth)
  ) udp_ipv4_header_add_inst (
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
      .axis_mdata       (axis_mdata),
      .axis_mkeep       (axis_mkeep),
      .axis_mlast       (axis_mlast),
      .axis_mvalid      (axis_mvalid),
      .axis_musr        (axis_musr),
      .axis_mready      (axis_mready)
  );

endmodule
`resetall
