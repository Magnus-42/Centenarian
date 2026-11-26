// -----------------------------------------------------------------------------
// File Name   : udp_ipv6_rx.v
// Module Name : udp_ipv6_rx
// Author      : Lixintao
// Created     : 2026-11-26
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : UDP/IPv6接收链，剥离UDP首部并按目的端口分流。
// Note        : 输入data为UDP报文，输出为UDP载荷，首部追加到usr高位。
//               匹配通道按编号排列，末路为other；RxPortCount允许为0。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_ipv6_rx #(
    parameter  integer RxPortCount          = 3,
    localparam integer EffectiveRxPortCount = (RxPortCount > 0) ? RxPortCount : 1,
    localparam integer RxUsrWidth           = 497,
    localparam integer Ipv6RxUsrWidth       = 433
) (
    input wire clk,
    input wire rst,

    input wire [EffectiveRxPortCount*32-1:0] cfg_dst_port_range,

    input  wire [             511:0] axis_sdata,
    input  wire [              63:0] axis_skeep,
    input  wire                      axis_slast,
    input  wire                      axis_svalid,
    input  wire [Ipv6RxUsrWidth-1:0] axis_susr,
    output wire                      axis_sready,

    output wire [       512*(RxPortCount+1)-1:0] axis_mdata,
    output wire [        64*(RxPortCount+1)-1:0] axis_mkeep,
    output wire [                 RxPortCount:0] axis_mlast,
    output wire [                 RxPortCount:0] axis_mvalid,
    output wire [RxUsrWidth*(RxPortCount+1)-1:0] axis_musr,
    input  wire [                 RxPortCount:0] axis_mready
);

  // 参数范围检查
  initial begin
    if (RxPortCount < 0) begin
      $display("错误：udp_ipv6_rx：RxPortCount必须不小于0。");
      $finish;
    end
  end

  // 接收载荷接口
  wire [         511:0] rx_payload_data;
  wire [          63:0] rx_payload_keep;
  wire                  rx_payload_last;
  wire                  rx_payload_valid;
  wire [RxUsrWidth-1:0] rx_payload_usr;
  wire                  rx_payload_ready;

  // UDP首部剥离
  udp_ipv6_header_strip udp_ipv6_header_strip_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_svalid(axis_svalid),
      .axis_slast (axis_slast),
      .axis_sready(axis_sready),
      .axis_mdata (rx_payload_data),
      .axis_mkeep (rx_payload_keep),
      .axis_musr  (rx_payload_usr),
      .axis_mvalid(rx_payload_valid),
      .axis_mlast (rx_payload_last),
      .axis_mready(rx_payload_ready)
  );

  // 目的端口分流
  udp_ipv6_port_demux #(
      .PortCount(RxPortCount)
  ) udp_ipv6_port_demux_inst (
      .clk               (clk),
      .rst               (rst),
      .cfg_dst_port_range(cfg_dst_port_range),
      .axis_sdata        (rx_payload_data),
      .axis_skeep        (rx_payload_keep),
      .axis_slast        (rx_payload_last),
      .axis_svalid       (rx_payload_valid),
      .axis_susr         (rx_payload_usr),
      .axis_sready       (rx_payload_ready),
      .axis_mdata        (axis_mdata),
      .axis_mkeep        (axis_mkeep),
      .axis_mlast        (axis_mlast),
      .axis_mvalid       (axis_mvalid),
      .axis_musr         (axis_musr),
      .axis_mready       (axis_mready)
  );

endmodule
`resetall
