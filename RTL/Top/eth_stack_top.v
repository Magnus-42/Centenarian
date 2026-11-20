// -----------------------------------------------------------------------------
// File Name   : eth_stack_top.v
// Module Name : eth_stack_top
// Author      : Codex
// Created     : 2026-11-19
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 连接A/B两路固定以太网协议栈与板级接口。
// Note        : 每口用户通道按本口宽度引出，GT复位请求在本层汇总。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module eth_stack_top #(
    parameter integer ReqWidth = 4,
    localparam integer UdpTxUsrWidth = 104 + ReqWidth
) (
    // 公共时钟与复位
    input  wire init_clk,
    input  wire clk,
    input  wire rst,
    input  wire clk_locked,
    output wire qsfp_gt_rst,

    // A口板级和业务接口
    //// GT接口
    output wire [3:0] a_gt_txp_out,
    output wire [3:0] a_gt_txn_out,
    input  wire [3:0] a_gt_rxp_in,
    input  wire [3:0] a_gt_rxn_in,
    input  wire       a_gt_ref_clk_p,
    input  wire       a_gt_ref_clk_n,
    //// QSFP控制
    output wire       a_qsfp_reset_n,
    output wire       a_qsfp_low_power_mode,
    output wire       a_qsfp_select_n,
    input  wire       a_qsfp_present_n,
    output wire       a_qsfp_led,

    //// MAC接收
    output wire [1535:0] a_mac_axis_mdata,
    output wire [ 191:0] a_mac_axis_mkeep,
    output wire [   2:0] a_mac_axis_mvalid,
    output wire [   2:0] a_mac_axis_mlast,
    input  wire [   2:0] a_mac_axis_mready,

    //// MAC发送
    input  wire [        1023:0] a_mac_axis_sdata,
    input  wire [         127:0] a_mac_axis_skeep,
    input  wire [2*ReqWidth-1:0] a_mac_axis_susr,
    input  wire [           1:0] a_mac_axis_svalid,
    input  wire [           1:0] a_mac_axis_slast,
    output wire [           1:0] a_mac_axis_sready,

    //// IPv4接收
    output wire [2047:0] a_ipv4_axis_mdata,
    output wire [ 255:0] a_ipv4_axis_mkeep,
    output wire [ 387:0] a_ipv4_axis_musr,
    output wire [   3:0] a_ipv4_axis_mvalid,
    output wire [   3:0] a_ipv4_axis_mlast,
    input  wire [   3:0] a_ipv4_axis_mready,

    //// IPv4发送
    input  wire [        2047:0] a_ipv4_axis_sdata,
    input  wire [         255:0] a_ipv4_axis_skeep,
    input  wire [4*ReqWidth-1:0] a_ipv4_axis_susr,
    input  wire [           3:0] a_ipv4_axis_svalid,
    input  wire [           3:0] a_ipv4_axis_slast,
    output wire [           3:0] a_ipv4_axis_sready,

    //// ICMP接收
    output wire [511:0] a_icmp_axis_mdata,
    output wire [ 63:0] a_icmp_axis_mkeep,
    output wire [ 96:0] a_icmp_axis_musr,
    output wire         a_icmp_axis_mvalid,
    output wire         a_icmp_axis_mlast,
    input  wire         a_icmp_axis_mready,

    //// IPv6接收
    output wire [2047:0] a_ipv6_axis_mdata,
    output wire [ 255:0] a_ipv6_axis_mkeep,
    output wire [ 387:0] a_ipv6_axis_musr,
    output wire [   3:0] a_ipv6_axis_mvalid,
    output wire [   3:0] a_ipv6_axis_mlast,
    input  wire [   3:0] a_ipv6_axis_mready,

    //// IPv6发送
    input  wire [        1535:0] a_ipv6_axis_sdata,
    input  wire [         191:0] a_ipv6_axis_skeep,
    input  wire [3*ReqWidth-1:0] a_ipv6_axis_susr,
    input  wire [           2:0] a_ipv6_axis_svalid,
    input  wire [           2:0] a_ipv6_axis_slast,
    output wire [           2:0] a_ipv6_axis_sready,

    //// UDP接收
    output wire [2047:0] a_udp_ipv4_axis_mdata,
    output wire [ 255:0] a_udp_ipv4_axis_mkeep,
    output wire [ 963:0] a_udp_ipv4_axis_musr,
    output wire [   3:0] a_udp_ipv4_axis_mvalid,
    output wire [   3:0] a_udp_ipv4_axis_mlast,
    input  wire [   3:0] a_udp_ipv4_axis_mready,

    //// UDP发送
    input  wire [             4095:0] a_udp_ipv4_axis_sdata,
    input  wire [              511:0] a_udp_ipv4_axis_skeep,
    input  wire [8*UdpTxUsrWidth-1:0] a_udp_ipv4_axis_susr,
    input  wire [                7:0] a_udp_ipv4_axis_svalid,
    input  wire [                7:0] a_udp_ipv4_axis_slast,
    output wire [                7:0] a_udp_ipv4_axis_sready,

    // B口板级和业务接口
    //// GT接口
    output wire [3:0] b_gt_txp_out,
    output wire [3:0] b_gt_txn_out,
    input  wire [3:0] b_gt_rxp_in,
    input  wire [3:0] b_gt_rxn_in,
    input  wire       b_gt_ref_clk_p,
    input  wire       b_gt_ref_clk_n,
    //// QSFP控制
    output wire       b_qsfp_reset_n,
    output wire       b_qsfp_low_power_mode,
    output wire       b_qsfp_select_n,
    input  wire       b_qsfp_present_n,
    output wire       b_qsfp_led,

    //// MAC接收
    output wire [1023:0] b_mac_axis_mdata,
    output wire [ 127:0] b_mac_axis_mkeep,
    output wire [   1:0] b_mac_axis_mvalid,
    output wire [   1:0] b_mac_axis_mlast,
    input  wire [   1:0] b_mac_axis_mready,

    //// MAC发送
    input  wire [        1535:0] b_mac_axis_sdata,
    input  wire [         191:0] b_mac_axis_skeep,
    input  wire [3*ReqWidth-1:0] b_mac_axis_susr,
    input  wire [           2:0] b_mac_axis_svalid,
    input  wire [           2:0] b_mac_axis_slast,
    output wire [           2:0] b_mac_axis_sready,

    //// IPv4接收
    output wire [2047:0] b_ipv4_axis_mdata,
    output wire [ 255:0] b_ipv4_axis_mkeep,
    output wire [ 387:0] b_ipv4_axis_musr,
    output wire [   3:0] b_ipv4_axis_mvalid,
    output wire [   3:0] b_ipv4_axis_mlast,
    input  wire [   3:0] b_ipv4_axis_mready,

    //// IPv4发送
    input  wire [        2047:0] b_ipv4_axis_sdata,
    input  wire [         255:0] b_ipv4_axis_skeep,
    input  wire [4*ReqWidth-1:0] b_ipv4_axis_susr,
    input  wire [           3:0] b_ipv4_axis_svalid,
    input  wire [           3:0] b_ipv4_axis_slast,
    output wire [           3:0] b_ipv4_axis_sready,

    //// ICMP接收
    output wire [511:0] b_icmp_axis_mdata,
    output wire [ 63:0] b_icmp_axis_mkeep,
    output wire [ 96:0] b_icmp_axis_musr,
    output wire         b_icmp_axis_mvalid,
    output wire         b_icmp_axis_mlast,
    input  wire         b_icmp_axis_mready,

    //// IPv6接收
    output wire [2047:0] b_ipv6_axis_mdata,
    output wire [ 255:0] b_ipv6_axis_mkeep,
    output wire [ 387:0] b_ipv6_axis_musr,
    output wire [   3:0] b_ipv6_axis_mvalid,
    output wire [   3:0] b_ipv6_axis_mlast,
    input  wire [   3:0] b_ipv6_axis_mready,

    //// IPv6发送
    input  wire [        1535:0] b_ipv6_axis_sdata,
    input  wire [         191:0] b_ipv6_axis_skeep,
    input  wire [3*ReqWidth-1:0] b_ipv6_axis_susr,
    input  wire [           2:0] b_ipv6_axis_svalid,
    input  wire [           2:0] b_ipv6_axis_slast,
    output wire [           2:0] b_ipv6_axis_sready,

    //// UDP接收
    output wire [2047:0] b_udp_ipv4_axis_mdata,
    output wire [ 255:0] b_udp_ipv4_axis_mkeep,
    output wire [ 963:0] b_udp_ipv4_axis_musr,
    output wire [   3:0] b_udp_ipv4_axis_mvalid,
    output wire [   3:0] b_udp_ipv4_axis_mlast,
    input  wire [   3:0] b_udp_ipv4_axis_mready,

    //// UDP发送
    input  wire [             2047:0] b_udp_ipv4_axis_sdata,
    input  wire [              255:0] b_udp_ipv4_axis_skeep,
    input  wire [4*UdpTxUsrWidth-1:0] b_udp_ipv4_axis_susr,
    input  wire [                3:0] b_udp_ipv4_axis_svalid,
    input  wire [                3:0] b_udp_ipv4_axis_slast,
    output wire [                3:0] b_udp_ipv4_axis_sready
);

  // 分别连接A/B口协议栈与板级、用户业务接口。
  // 汇总两口GT复位信号。

  // 各口GT复位
  wire a_qsfp_gt_rst;
  wire b_qsfp_gt_rst;

  // GT复位汇总
  assign qsfp_gt_rst = a_qsfp_gt_rst || b_qsfp_gt_rst;

  // A口协议栈
  eth_stack_port_a #(
      .ReqWidth(ReqWidth)
  ) eth_stack_port_a_inst (
      .init_clk  (init_clk),
      .clk       (clk),
      .rst       (rst),
      .clk_locked(clk_locked),

      .gt_txp_out  (a_gt_txp_out),
      .gt_txn_out  (a_gt_txn_out),
      .gt_rxp_in   (a_gt_rxp_in),
      .gt_rxn_in   (a_gt_rxn_in),
      .gt_ref_clk_p(a_gt_ref_clk_p),
      .gt_ref_clk_n(a_gt_ref_clk_n),

      .qsfp_reset_n       (a_qsfp_reset_n),
      .qsfp_low_power_mode(a_qsfp_low_power_mode),
      .qsfp_select_n      (a_qsfp_select_n),
      .qsfp_present_n     (a_qsfp_present_n),
      .qsfp_led           (a_qsfp_led),

      .qsfp_gt_rst(a_qsfp_gt_rst),

      .mac_axis_mdata (a_mac_axis_mdata),
      .mac_axis_mkeep (a_mac_axis_mkeep),
      .mac_axis_mvalid(a_mac_axis_mvalid),
      .mac_axis_mlast (a_mac_axis_mlast),
      .mac_axis_mready(a_mac_axis_mready),

      .mac_axis_sdata (a_mac_axis_sdata),
      .mac_axis_skeep (a_mac_axis_skeep),
      .mac_axis_susr  (a_mac_axis_susr),
      .mac_axis_svalid(a_mac_axis_svalid),
      .mac_axis_slast (a_mac_axis_slast),
      .mac_axis_sready(a_mac_axis_sready),

      .ipv4_axis_mdata (a_ipv4_axis_mdata),
      .ipv4_axis_mkeep (a_ipv4_axis_mkeep),
      .ipv4_axis_musr  (a_ipv4_axis_musr),
      .ipv4_axis_mvalid(a_ipv4_axis_mvalid),
      .ipv4_axis_mlast (a_ipv4_axis_mlast),
      .ipv4_axis_mready(a_ipv4_axis_mready),

      .ipv4_axis_sdata (a_ipv4_axis_sdata),
      .ipv4_axis_skeep (a_ipv4_axis_skeep),
      .ipv4_axis_susr  (a_ipv4_axis_susr),
      .ipv4_axis_svalid(a_ipv4_axis_svalid),
      .ipv4_axis_slast (a_ipv4_axis_slast),
      .ipv4_axis_sready(a_ipv4_axis_sready),

      .icmp_axis_mdata (a_icmp_axis_mdata),
      .icmp_axis_mkeep (a_icmp_axis_mkeep),
      .icmp_axis_musr  (a_icmp_axis_musr),
      .icmp_axis_mvalid(a_icmp_axis_mvalid),
      .icmp_axis_mlast (a_icmp_axis_mlast),
      .icmp_axis_mready(a_icmp_axis_mready),

      .ipv6_axis_mdata (a_ipv6_axis_mdata),
      .ipv6_axis_mkeep (a_ipv6_axis_mkeep),
      .ipv6_axis_musr  (a_ipv6_axis_musr),
      .ipv6_axis_mvalid(a_ipv6_axis_mvalid),
      .ipv6_axis_mlast (a_ipv6_axis_mlast),
      .ipv6_axis_mready(a_ipv6_axis_mready),

      .ipv6_axis_sdata (a_ipv6_axis_sdata),
      .ipv6_axis_skeep (a_ipv6_axis_skeep),
      .ipv6_axis_susr  (a_ipv6_axis_susr),
      .ipv6_axis_svalid(a_ipv6_axis_svalid),
      .ipv6_axis_slast (a_ipv6_axis_slast),
      .ipv6_axis_sready(a_ipv6_axis_sready),

      .udp_ipv4_axis_mdata (a_udp_ipv4_axis_mdata),
      .udp_ipv4_axis_mkeep (a_udp_ipv4_axis_mkeep),
      .udp_ipv4_axis_musr  (a_udp_ipv4_axis_musr),
      .udp_ipv4_axis_mvalid(a_udp_ipv4_axis_mvalid),
      .udp_ipv4_axis_mlast (a_udp_ipv4_axis_mlast),
      .udp_ipv4_axis_mready(a_udp_ipv4_axis_mready),

      .udp_ipv4_axis_sdata (a_udp_ipv4_axis_sdata),
      .udp_ipv4_axis_skeep (a_udp_ipv4_axis_skeep),
      .udp_ipv4_axis_susr  (a_udp_ipv4_axis_susr),
      .udp_ipv4_axis_svalid(a_udp_ipv4_axis_svalid),
      .udp_ipv4_axis_slast (a_udp_ipv4_axis_slast),
      .udp_ipv4_axis_sready(a_udp_ipv4_axis_sready)
  );

  // B口协议栈
  eth_stack_port_b #(
      .ReqWidth(ReqWidth)
  ) eth_stack_port_b_inst (
      .init_clk  (init_clk),
      .clk       (clk),
      .rst       (rst),
      .clk_locked(clk_locked),

      .gt_txp_out  (b_gt_txp_out),
      .gt_txn_out  (b_gt_txn_out),
      .gt_rxp_in   (b_gt_rxp_in),
      .gt_rxn_in   (b_gt_rxn_in),
      .gt_ref_clk_p(b_gt_ref_clk_p),
      .gt_ref_clk_n(b_gt_ref_clk_n),

      .qsfp_reset_n       (b_qsfp_reset_n),
      .qsfp_low_power_mode(b_qsfp_low_power_mode),
      .qsfp_select_n      (b_qsfp_select_n),
      .qsfp_present_n     (b_qsfp_present_n),
      .qsfp_led           (b_qsfp_led),

      .qsfp_gt_rst(b_qsfp_gt_rst),

      .mac_axis_mdata (b_mac_axis_mdata),
      .mac_axis_mkeep (b_mac_axis_mkeep),
      .mac_axis_mvalid(b_mac_axis_mvalid),
      .mac_axis_mlast (b_mac_axis_mlast),
      .mac_axis_mready(b_mac_axis_mready),

      .mac_axis_sdata (b_mac_axis_sdata),
      .mac_axis_skeep (b_mac_axis_skeep),
      .mac_axis_susr  (b_mac_axis_susr),
      .mac_axis_svalid(b_mac_axis_svalid),
      .mac_axis_slast (b_mac_axis_slast),
      .mac_axis_sready(b_mac_axis_sready),

      .ipv4_axis_mdata (b_ipv4_axis_mdata),
      .ipv4_axis_mkeep (b_ipv4_axis_mkeep),
      .ipv4_axis_musr  (b_ipv4_axis_musr),
      .ipv4_axis_mvalid(b_ipv4_axis_mvalid),
      .ipv4_axis_mlast (b_ipv4_axis_mlast),
      .ipv4_axis_mready(b_ipv4_axis_mready),

      .ipv4_axis_sdata (b_ipv4_axis_sdata),
      .ipv4_axis_skeep (b_ipv4_axis_skeep),
      .ipv4_axis_susr  (b_ipv4_axis_susr),
      .ipv4_axis_svalid(b_ipv4_axis_svalid),
      .ipv4_axis_slast (b_ipv4_axis_slast),
      .ipv4_axis_sready(b_ipv4_axis_sready),

      .icmp_axis_mdata (b_icmp_axis_mdata),
      .icmp_axis_mkeep (b_icmp_axis_mkeep),
      .icmp_axis_musr  (b_icmp_axis_musr),
      .icmp_axis_mvalid(b_icmp_axis_mvalid),
      .icmp_axis_mlast (b_icmp_axis_mlast),
      .icmp_axis_mready(b_icmp_axis_mready),

      .ipv6_axis_mdata (b_ipv6_axis_mdata),
      .ipv6_axis_mkeep (b_ipv6_axis_mkeep),
      .ipv6_axis_musr  (b_ipv6_axis_musr),
      .ipv6_axis_mvalid(b_ipv6_axis_mvalid),
      .ipv6_axis_mlast (b_ipv6_axis_mlast),
      .ipv6_axis_mready(b_ipv6_axis_mready),

      .ipv6_axis_sdata (b_ipv6_axis_sdata),
      .ipv6_axis_skeep (b_ipv6_axis_skeep),
      .ipv6_axis_susr  (b_ipv6_axis_susr),
      .ipv6_axis_svalid(b_ipv6_axis_svalid),
      .ipv6_axis_slast (b_ipv6_axis_slast),
      .ipv6_axis_sready(b_ipv6_axis_sready),

      .udp_ipv4_axis_mdata (b_udp_ipv4_axis_mdata),
      .udp_ipv4_axis_mkeep (b_udp_ipv4_axis_mkeep),
      .udp_ipv4_axis_musr  (b_udp_ipv4_axis_musr),
      .udp_ipv4_axis_mvalid(b_udp_ipv4_axis_mvalid),
      .udp_ipv4_axis_mlast (b_udp_ipv4_axis_mlast),
      .udp_ipv4_axis_mready(b_udp_ipv4_axis_mready),

      .udp_ipv4_axis_sdata (b_udp_ipv4_axis_sdata),
      .udp_ipv4_axis_skeep (b_udp_ipv4_axis_skeep),
      .udp_ipv4_axis_susr  (b_udp_ipv4_axis_susr),
      .udp_ipv4_axis_svalid(b_udp_ipv4_axis_svalid),
      .udp_ipv4_axis_slast (b_udp_ipv4_axis_slast),
      .udp_ipv4_axis_sready(b_udp_ipv4_axis_sready)
  );

endmodule
`resetall
