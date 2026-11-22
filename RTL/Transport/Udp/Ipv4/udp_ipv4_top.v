// -----------------------------------------------------------------------------
// File Name   : udp_ipv4_top.v
// Module Name : udp_ipv4_top
// Author      : LiXintao
// Created     : 2026-10-8
// Version     : v1.0

// Description : UDP over IPv4收发顶层。
//
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_ipv4_top #(
    parameter integer RxPortCount = 3,
    parameter integer TxChannelCount = 4,
    parameter integer TxReqWidth = 4,
    localparam integer EffectiveRxPortCount = (RxPortCount > 0) ? RxPortCount : 1,
    localparam integer TxUsrWidth = TxReqWidth + 104,
    localparam integer RxUsrWidth = 241,
    localparam integer Ipv4RxUsrWidth = 97,
    localparam integer Ipv4HeaderUsrWidth = 96
) (
    input wire clk,
    input wire rst,

    input wire [EffectiveRxPortCount*32-1:0] cfg_dst_port_range,

    // rx
    input  wire [             511:0] rx_axis_sdata,
    input  wire [              63:0] rx_axis_skeep,
    input  wire                      rx_axis_slast,
    input  wire                      rx_axis_svalid,
    input  wire [Ipv4RxUsrWidth-1:0] rx_axis_susr,
    output wire                      rx_axis_sready,

    output wire [       512*(RxPortCount+1)-1:0] rx_axis_mdata,
    output wire [        64*(RxPortCount+1)-1:0] rx_axis_mkeep,
    output wire [                 RxPortCount:0] rx_axis_mlast,
    output wire [                 RxPortCount:0] rx_axis_mvalid,
    output wire [RxUsrWidth*(RxPortCount+1)-1:0] rx_axis_musr,
    input  wire [                 RxPortCount:0] rx_axis_mready,

    // tx
    input  wire [       512*TxChannelCount-1:0] tx_axis_sdata,
    input  wire [        64*TxChannelCount-1:0] tx_axis_skeep,
    input  wire [           TxChannelCount-1:0] tx_axis_slast,
    input  wire [           TxChannelCount-1:0] tx_axis_svalid,
    input  wire [TxUsrWidth*TxChannelCount-1:0] tx_axis_susr,
    output wire [           TxChannelCount-1:0] tx_axis_sready,

    output wire [         511:0] tx_axis_mdata,
    output wire [          63:0] tx_axis_mkeep,
    output wire                  tx_axis_mlast,
    output wire                  tx_axis_mvalid,
    output wire [TxReqWidth-1:0] tx_axis_musr,
    input  wire                  tx_axis_mready,

    output wire stat_is_df

);

  // 接收依次剥离IPv4和UDP头，按目的端口分流。
  // 发送依次仲裁、计算长度和校验和，并插入UDP和IPv4头。

  // 参数范围检查
  initial begin
    if (RxPortCount < 0 || TxChannelCount < 1 || TxReqWidth < 1) begin
      $display("错误：udp_ipv4_top：不支持的参数配置。");
      $finish;
    end
  end

  // 接收UDP报文接口
  wire [                                511:0] rx_udp_data;
  wire [                                 63:0] rx_udp_keep;
  wire                                         rx_udp_last;
  wire                                         rx_udp_valid;
  wire                                         rx_udp_ready;
  wire [Ipv4RxUsrWidth+Ipv4HeaderUsrWidth-1:0] rx_udp_usr;

  // 接收载荷接口
  wire [                                511:0] rx_payload_data;
  wire [                                 63:0] rx_payload_keep;
  wire                                         rx_payload_last;
  wire                                         rx_payload_valid;
  wire [                       RxUsrWidth-1:0] rx_payload_usr;
  wire                                         rx_payload_ready;

  // 解析字段
  wire [                                  7:0] protocol;
  wire [                                 15:0] total_len;
  wire [                                  7:0] ttl;
  wire [                                 31:0] src_ip;
  wire [                                 31:0] dst_ip;
  wire [                                 15:0] dst_port;
  wire [                                 15:0] src_port;

  wire [                                 15:0] udp_len;

  // 发送仲裁接口
  wire [                                511:0] tx_mux_data;
  wire [                                 63:0] tx_mux_keep;
  wire                                         tx_mux_last;
  wire                                         tx_mux_valid;
  wire [                       TxUsrWidth-1:0] tx_mux_usr;
  wire                                         tx_mux_ready;

  // 接收通路
  //// IPv4头剥离
  udp_ipv4_rx udp_ipv4_rx_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (rx_axis_sdata),
      .axis_skeep (rx_axis_skeep),
      .axis_slast (rx_axis_slast),
      .axis_svalid(rx_axis_svalid),
      .axis_susr  (rx_axis_susr),
      .axis_sready(rx_axis_sready),
      .axis_mdata (rx_udp_data),
      .axis_mkeep (rx_udp_keep),
      .axis_mlast (rx_udp_last),
      .axis_mvalid(rx_udp_valid),
      .axis_musr  (rx_udp_usr[Ipv4RxUsrWidth-1:0]),
      .axis_mready(rx_udp_ready),
      .protocol   (protocol),
      .total_len  (total_len),
      .ttl        (ttl),
      .src_ip     (src_ip),
      .dst_ip     (dst_ip),
      .stat_is_df (stat_is_df)                       // 禁止分片
  );
  assign rx_udp_usr[Ipv4RxUsrWidth+:Ipv4HeaderUsrWidth] = {
    dst_ip, src_ip, ttl, total_len, protocol
  };
  //// UDP头剥离
  udp_ipv4_header_strip udp_ipv4_header_strip_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (rx_udp_data),
      .axis_skeep (rx_udp_keep),
      .axis_slast (rx_udp_last),
      .axis_svalid(rx_udp_valid),
      .axis_susr  (rx_udp_usr),
      .axis_sready(rx_udp_ready),
      .axis_mdata (rx_payload_data),
      .axis_mkeep (rx_payload_keep),
      .axis_mlast (rx_payload_last),
      .axis_mvalid(rx_payload_valid),
      .axis_musr  (rx_payload_usr[Ipv4RxUsrWidth+Ipv4HeaderUsrWidth-1:0]),
      .axis_mready(rx_payload_ready),
      .dst_port   (dst_port),
      .src_port   (src_port),
      .udp_len    (udp_len)
  );
  assign rx_payload_usr[RxUsrWidth-1:Ipv4RxUsrWidth+Ipv4HeaderUsrWidth] = {
    udp_len, src_port, dst_port
  };
  //// 目的端口分流
  udp_ipv4_port_demux #(
      .PortCount(RxPortCount)
  ) udp_ipv4_port_demux_inst (
      .clk               (clk),
      .rst               (rst),
      .cfg_dst_port_range(cfg_dst_port_range),
      .axis_sdata        (rx_payload_data),
      .axis_skeep        (rx_payload_keep),
      .axis_slast        (rx_payload_last),
      .axis_svalid       (rx_payload_valid),
      .axis_susr         (rx_payload_usr),
      .axis_sready       (rx_payload_ready),
      .axis_mdata        (rx_axis_mdata),
      .axis_mkeep        (rx_axis_mkeep),
      .axis_mlast        (rx_axis_mlast),
      .axis_mvalid       (rx_axis_mvalid),
      .axis_musr         (rx_axis_musr),
      .axis_mready       (rx_axis_mready)
  );

  // 发送通路
  //// 数值优先级仲裁
  udp_ipv4_tx_mux #(
      .TxChannelCount(TxChannelCount),
      .ReqWidth      (TxReqWidth)
  ) udp_ipv4_tx_mux_inst (
      .clk        (clk),
      .rst        (rst),
      // 入口
      .axis_sdata (tx_axis_sdata),
      .axis_skeep (tx_axis_skeep),
      .axis_slast (tx_axis_slast),
      .axis_svalid(tx_axis_svalid),
      .axis_susr  (tx_axis_susr),
      .axis_sready(tx_axis_sready),
      // 出口
      .axis_mdata (tx_mux_data),
      .axis_mkeep (tx_mux_keep),
      .axis_mlast (tx_mux_last),
      .axis_mvalid(tx_mux_valid),
      .axis_musr  (tx_mux_usr),
      .axis_mready(tx_mux_ready)
  );
  //// UDP与IPv4封装
  udp_ipv4_tx #(
      .ReqWidth(TxReqWidth)
  ) udp_ipv4_tx_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (tx_mux_data),
      .axis_skeep (tx_mux_keep),
      .axis_slast (tx_mux_last),
      .axis_svalid(tx_mux_valid),
      .axis_susr  (tx_mux_usr),
      .axis_sready(tx_mux_ready),
      .axis_mdata (tx_axis_mdata),
      .axis_mkeep (tx_axis_mkeep),
      .axis_mlast (tx_axis_mlast),
      .axis_mvalid(tx_axis_mvalid),
      .axis_musr  (tx_axis_musr),
      .axis_mready(tx_axis_mready)
  );

endmodule
`resetall
