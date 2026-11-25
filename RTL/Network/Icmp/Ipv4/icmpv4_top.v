// -----------------------------------------------------------------------------
// File Name   : icmpv4_top.v
// Module Name : icmpv4_top
// Author      : LiXintao
// Created     : 2026-10-17
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : ICMPv4收发顶层，连接ICMP头剥离、类型分流、回显应答与发送仲裁。
// Note        : TX输入为ICMP载荷，输出为ICMP报文与IPv4首部侧带。
//               RX输入为ICMP报文，分流输出ICMP载荷，首部字段逐层放入usr。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module icmpv4_top #(
    parameter  integer ReqWidth       = 4,
    localparam integer TxUsrWidth     = ReqWidth + 224,
    localparam integer IpTxUsrWidth   = ReqWidth + 160,
    localparam integer RxUsrWidth     = 337,
    localparam integer Ipv4RxUsrWidth = 273,
    parameter  integer TxChannelCount = 1
) (
    input wire clk,
    input wire rst,

    input wire [ReqWidth-1:0] cfg_arbiter_value,
    input wire                cfg_clear_error,

    input  wire [             511:0] rx_axis_sdata,
    input  wire [              63:0] rx_axis_skeep,
    input  wire [Ipv4RxUsrWidth-1:0] rx_axis_susr,
    input  wire                      rx_axis_svalid,
    input  wire                      rx_axis_slast,
    output wire                      rx_axis_sready,

    output wire [         511:0] other_axis_mdata,
    output wire [          63:0] other_axis_mkeep,
    output wire [RxUsrWidth-1:0] other_axis_musr,
    output wire                  other_axis_mvalid,
    output wire                  other_axis_mlast,
    input  wire                  other_axis_mready,

    input  wire [       512*TxChannelCount-1:0] tx_axis_sdata,
    input  wire [        64*TxChannelCount-1:0] tx_axis_skeep,
    input  wire [TxUsrWidth*TxChannelCount-1:0] tx_axis_susr,
    input  wire [           TxChannelCount-1:0] tx_axis_svalid,
    input  wire [           TxChannelCount-1:0] tx_axis_slast,
    output wire [           TxChannelCount-1:0] tx_axis_sready,

    output wire [           511:0] tx_axis_mdata,
    output wire [            63:0] tx_axis_mkeep,
    output wire [IpTxUsrWidth-1:0] tx_axis_musr,
    output wire                    tx_axis_mvalid,
    output wire                    tx_axis_mlast,
    input  wire                    tx_axis_mready,

    output wire stat_ttl_error
);

  // 接收通路先剥离ICMP头并打包头字段，再区分回显请求和其他ICMP报文。
  // 应答与用户发送载荷按帧仲裁，计算校验和并添加ICMP基本首部。

  // 参数范围检查
  initial begin
    if (ReqWidth < 1 || RxUsrWidth < 1 || TxChannelCount < 1) begin
      $display("错误：icmpv4_top：不支持的参数配置。");
      $finish;
    end
  end

  // ICMP剥头后的载荷与侧带
  wire [                            511:0] rx_icmp_data;
  wire [                             63:0] rx_icmp_keep;
  wire [                   RxUsrWidth-1:0] rx_icmp_usr;
  wire                                     rx_icmp_valid;
  wire                                     rx_icmp_last;
  wire                                     rx_icmp_ready;

  // 接收通路
  wire [                            511:0] echo_rx_data;
  wire [                             63:0] echo_rx_keep;
  wire                                     echo_rx_last;
  wire                                     echo_rx_valid;
  wire [                   RxUsrWidth-1:0] echo_rx_usr;
  wire                                     echo_rx_ready;

  // 回显应答通路
  wire [                            511:0] echo_tx_data;
  wire [                             63:0] echo_tx_keep;
  wire                                     echo_tx_last;
  wire                                     echo_tx_valid;
  wire [                   TxUsrWidth-1:0] echo_tx_usr;
  wire                                     echo_tx_ready;

  // 发送仲裁输出
  wire [                            511:0] tx_mux_data;
  wire [                             63:0] tx_mux_keep;
  wire [                   TxUsrWidth-1:0] tx_mux_usr;
  wire                                     tx_mux_valid;
  wire                                     tx_mux_last;
  wire                                     tx_mux_ready;

  // 发送仲裁接口
  wire [       512*(TxChannelCount+1)-1:0] mux_data;
  wire [        64*(TxChannelCount+1)-1:0] mux_keep;
  wire [           (TxChannelCount+1)-1:0] mux_last;
  wire [           (TxChannelCount+1)-1:0] mux_valid;
  wire [TxUsrWidth*(TxChannelCount+1)-1:0] mux_usr;
  wire [           (TxChannelCount+1)-1:0] mux_ready;

  // 接收通路
  //// ICMP基本首部剥离
  icmpv4_header_strip icmpv4_header_strip_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (rx_axis_sdata),
      .axis_skeep (rx_axis_skeep),
      .axis_susr  (rx_axis_susr),
      .axis_svalid(rx_axis_svalid),
      .axis_slast (rx_axis_slast),
      .axis_sready(rx_axis_sready),
      .axis_mdata (rx_icmp_data),
      .axis_mkeep (rx_icmp_keep),
      .axis_musr  (rx_icmp_usr),
      .axis_mvalid(rx_icmp_valid),
      .axis_mlast (rx_icmp_last),
      .axis_mready(rx_icmp_ready)
  );
  //// ICMP类型分流
  icmpv4_type_demux icmpv4_type_demux_inst (
      .clk              (clk),
      .rst              (rst),
      .axis_sdata       (rx_icmp_data),
      .axis_skeep       (rx_icmp_keep),
      .axis_susr        (rx_icmp_usr),
      .axis_svalid      (rx_icmp_valid),
      .axis_slast       (rx_icmp_last),
      .axis_sready      (rx_icmp_ready),
      .echo_axis_mdata  (echo_rx_data),
      .echo_axis_mkeep  (echo_rx_keep),
      .echo_axis_musr   (echo_rx_usr),
      .echo_axis_mvalid (echo_rx_valid),
      .echo_axis_mlast  (echo_rx_last),
      .echo_axis_mready (echo_rx_ready),
      .other_axis_mdata (other_axis_mdata),
      .other_axis_mkeep (other_axis_mkeep),
      .other_axis_musr  (other_axis_musr),
      .other_axis_mvalid(other_axis_mvalid),
      .other_axis_mlast (other_axis_mlast),
      .other_axis_mready(other_axis_mready)
  );

  // 回显应答
  icmpv4_echo_reply #(
      .ReqWidth(ReqWidth)
  ) icmpv4_echo_reply_inst (
      .clk              (clk),
      .rst              (rst),
      .cfg_arbiter_value(cfg_arbiter_value),
      .cfg_clear_error  (cfg_clear_error),
      .axis_sdata       (echo_rx_data),
      .axis_skeep       (echo_rx_keep),
      .axis_susr        (echo_rx_usr),
      .axis_svalid      (echo_rx_valid),
      .axis_slast       (echo_rx_last),
      .axis_sready      (echo_rx_ready),
      .axis_mdata       (echo_tx_data),
      .axis_mkeep       (echo_tx_keep),
      .axis_musr        (echo_tx_usr),
      .axis_mvalid      (echo_tx_valid),
      .axis_mlast       (echo_tx_last),
      .axis_mready      (echo_tx_ready),
      .stat_ttl_error   (stat_ttl_error)
  );

  // 发送仲裁
  assign mux_data       = {tx_axis_sdata, echo_tx_data};
  assign mux_keep       = {tx_axis_skeep, echo_tx_keep};
  assign mux_last       = {tx_axis_slast, echo_tx_last};
  assign mux_valid      = {tx_axis_svalid, echo_tx_valid};
  assign mux_usr        = {tx_axis_susr, echo_tx_usr};

  assign echo_tx_ready  = mux_ready[0];
  assign tx_axis_sready = mux_ready[TxChannelCount:1];

  icmpv4_tx_mux #(
      .PortCount(TxChannelCount + 1),
      .ReqWidth (ReqWidth)
  ) icmpv4_tx_mux_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (mux_data),
      .axis_skeep (mux_keep),
      .axis_susr  (mux_usr),
      .axis_svalid(mux_valid),
      .axis_slast (mux_last),
      .axis_sready(mux_ready),
      .axis_mdata (tx_mux_data),
      .axis_mkeep (tx_mux_keep),
      .axis_musr  (tx_mux_usr),
      .axis_mvalid(tx_mux_valid),
      .axis_mlast (tx_mux_last),
      .axis_mready(tx_mux_ready)
  );

  // ICMP发送。
  icmpv4_tx #(
      .ReqWidth(ReqWidth)
  ) icmpv4_tx_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (tx_mux_data),
      .axis_skeep (tx_mux_keep),
      .axis_susr  (tx_mux_usr),
      .axis_svalid(tx_mux_valid),
      .axis_slast (tx_mux_last),
      .axis_sready(tx_mux_ready),
      .axis_mdata (tx_axis_mdata),
      .axis_mkeep (tx_axis_mkeep),
      .axis_musr  (tx_axis_musr),
      .axis_mvalid(tx_axis_mvalid),
      .axis_mlast (tx_axis_mlast),
      .axis_mready(tx_axis_mready)
  );

endmodule
`resetall
