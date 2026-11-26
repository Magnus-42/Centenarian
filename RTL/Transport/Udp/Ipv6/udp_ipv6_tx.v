// -----------------------------------------------------------------------------
// File Name   : udp_ipv6_tx.v
// Module Name : udp_ipv6_tx
// Author      : LiXintao
// Created     : 2026-11-22
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : UDP发送链，按包仲裁后共享长度、校验与首部封装通路。
// Note        : 输入data为UDP载荷，usr为{UDP首部,IPv6首部,请求}。
//               输出data为完整UDP报文，usr提供IPv6基本头与请求值。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_ipv6_tx #(
    parameter  integer TxChannelCount = 1,
    parameter  integer ReqWidth       = 4,
    localparam integer UsrWidth       = ReqWidth + 384
) (
    input wire clk,
    input wire rst,

    input  wire [     512*TxChannelCount-1:0] axis_sdata,
    input  wire [      64*TxChannelCount-1:0] axis_skeep,
    input  wire [         TxChannelCount-1:0] axis_slast,
    input  wire [         TxChannelCount-1:0] axis_svalid,
    input  wire [UsrWidth*TxChannelCount-1:0] axis_susr,
    output wire [         TxChannelCount-1:0] axis_sready,

    output wire [           511:0] axis_mdata,
    output wire [            63:0] axis_mkeep,
    output wire                    axis_mlast,
    output wire                    axis_mvalid,
    output wire [ReqWidth+320-1:0] axis_musr,
    input  wire                    axis_mready
);

  // 整包缓存载荷并计算UDP长度与校验和。
  // 插入UDP头；出口usr提供IPv6头元数据，由网络层加头。

  // 参数范围检查
  initial begin
    if (TxChannelCount < 1 || ReqWidth < 1) begin
      $display("错误：udp_ipv6_tx：不支持的参数配置。");
      $finish;
    end
  end

  // 发送仲裁接口
  wire [       511:0] mux_data;
  wire [        63:0] mux_keep;
  wire [UsrWidth-1:0] mux_usr;
  wire                mux_valid;
  wire                mux_last;
  wire                mux_ready;

  // 长度与校验和接口
  wire [       511:0] checksum_data;
  wire [        63:0] checksum_keep;
  wire                checksum_last;
  wire                checksum_valid;
  wire [UsrWidth-1:0] checksum_usr;
  wire                checksum_ready;

  // 数值优先级仲裁
  udp_ipv6_tx_mux #(
      .TxChannelCount(TxChannelCount),
      .ReqWidth      (ReqWidth)
  ) udp_ipv6_tx_mux_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_svalid(axis_svalid),
      .axis_slast (axis_slast),
      .axis_sready(axis_sready),
      .axis_mdata (mux_data),
      .axis_mkeep (mux_keep),
      .axis_musr  (mux_usr),
      .axis_mvalid(mux_valid),
      .axis_mlast (mux_last),
      .axis_mready(mux_ready)
  );

  // 长度与校验和
  udp_ipv6_len_checksum #(
      .ReqWidth(ReqWidth)
  ) udp_ipv6_len_checksum_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (mux_data),
      .axis_skeep (mux_keep),
      .axis_slast (mux_last),
      .axis_svalid(mux_valid),
      .axis_susr  (mux_usr),
      .axis_sready(mux_ready),
      .axis_mdata (checksum_data),
      .axis_mkeep (checksum_keep),
      .axis_mlast (checksum_last),
      .axis_mvalid(checksum_valid),
      .axis_musr  (checksum_usr),
      .axis_mready(checksum_ready)
  );

  // UDP头插入
  udp_ipv6_header_add #(
      .ReqWidth(ReqWidth)
  ) udp_ipv6_header_add_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (checksum_data),
      .axis_skeep (checksum_keep),
      .axis_slast (checksum_last),
      .axis_svalid(checksum_valid),
      .axis_susr  (checksum_usr),
      .axis_sready(checksum_ready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid),
      .axis_musr  (axis_musr),
      .axis_mready(axis_mready)
  );

endmodule
`resetall
