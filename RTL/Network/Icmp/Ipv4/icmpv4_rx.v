// -----------------------------------------------------------------------------
// File Name   : icmpv4_rx.v
// Module Name : icmpv4_rx
// Author      : Lixintao
// Created     : 2026-11-24
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : ICMPv4接收链，剥离基本首部并区分回显请求与其他报文。
// Note        : 输入data为ICMP报文，输出data为本层负载，首部追加到usr高位。
//               仅匹配cfg_local_ip表中任一地址的Echo Request进入回显通道。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module icmpv4_rx #(
    parameter  integer LocalIpCount   = 1,
    localparam integer RxUsrWidth     = 337,
    localparam integer Ipv4RxUsrWidth = 273
) (
    input wire clk,
    input wire rst,

    input wire [32*LocalIpCount-1:0] cfg_local_ip,

    input  wire [             511:0] axis_sdata,
    input  wire [              63:0] axis_skeep,
    input  wire [Ipv4RxUsrWidth-1:0] axis_susr,
    input  wire                      axis_svalid,
    input  wire                      axis_slast,
    output wire                      axis_sready,

    output wire [         511:0] other_axis_mdata,
    output wire [          63:0] other_axis_mkeep,
    output wire [RxUsrWidth-1:0] other_axis_musr,
    output wire                  other_axis_mvalid,
    output wire                  other_axis_mlast,
    input  wire                  other_axis_mready,

    output wire [         511:0] echo_axis_mdata,
    output wire [          63:0] echo_axis_mkeep,
    output wire [RxUsrWidth-1:0] echo_axis_musr,
    output wire                  echo_axis_mvalid,
    output wire                  echo_axis_mlast,
    input  wire                  echo_axis_mready
);

  // ICMP剥头后的载荷与侧带
  wire [         511:0] rx_icmp_data;
  wire [          63:0] rx_icmp_keep;
  wire [RxUsrWidth-1:0] rx_icmp_usr;
  wire                  rx_icmp_valid;
  wire                  rx_icmp_last;
  wire                  rx_icmp_ready;

  // 接收通路
  //// ICMP基本首部剥离
  icmpv4_header_strip icmpv4_header_strip_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_svalid(axis_svalid),
      .axis_slast (axis_slast),
      .axis_sready(axis_sready),
      .axis_mdata (rx_icmp_data),
      .axis_mkeep (rx_icmp_keep),
      .axis_musr  (rx_icmp_usr),
      .axis_mvalid(rx_icmp_valid),
      .axis_mlast (rx_icmp_last),
      .axis_mready(rx_icmp_ready)
  );
  //// ICMP类型分流
  icmpv4_type_demux #(
      .LocalIpCount(LocalIpCount)
  ) icmpv4_type_demux_inst (
      .clk              (clk),
      .rst              (rst),
      .cfg_local_ip     (cfg_local_ip),
      .axis_sdata       (rx_icmp_data),
      .axis_skeep       (rx_icmp_keep),
      .axis_susr        (rx_icmp_usr),
      .axis_svalid      (rx_icmp_valid),
      .axis_slast       (rx_icmp_last),
      .axis_sready      (rx_icmp_ready),
      .echo_axis_mdata  (echo_axis_mdata),
      .echo_axis_mkeep  (echo_axis_mkeep),
      .echo_axis_musr   (echo_axis_musr),
      .echo_axis_mvalid (echo_axis_mvalid),
      .echo_axis_mlast  (echo_axis_mlast),
      .echo_axis_mready (echo_axis_mready),
      .other_axis_mdata (other_axis_mdata),
      .other_axis_mkeep (other_axis_mkeep),
      .other_axis_musr  (other_axis_musr),
      .other_axis_mvalid(other_axis_mvalid),
      .other_axis_mlast (other_axis_mlast),
      .other_axis_mready(other_axis_mready)
  );

endmodule
`resetall
