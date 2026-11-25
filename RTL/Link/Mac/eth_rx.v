// -----------------------------------------------------------------------------
// File Name   : eth_rx.v
// Module Name : eth_rx
// Author      : Lixintao
// Created     : 2026-11-25
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 以太网接收通路，剥离本层首部后按EtherType分流。
// Note        : 输入已去除FCS，输出usr为{Ethernet首部,坏帧标志}。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module eth_rx #(
    parameter  integer RxTypeCount = 4,
    localparam integer RxUsrWidth  = 113
) (
    input  wire                                  clk,
    input  wire                                  rst,
    input  wire [            RxTypeCount*16-1:0] cfg_type_dict,
    input  wire [                         511:0] axis_sdata,
    input  wire [                          63:0] axis_skeep,
    input  wire                                  axis_susr,
    input  wire                                  axis_svalid,
    input  wire                                  axis_slast,
    output wire                                  axis_sready,
    output wire [       512*(RxTypeCount+1)-1:0] axis_mdata,
    output wire [        64*(RxTypeCount+1)-1:0] axis_mkeep,
    output wire [RxUsrWidth*(RxTypeCount+1)-1:0] axis_musr,
    output wire [                 RxTypeCount:0] axis_mvalid,
    output wire [                 RxTypeCount:0] axis_mlast,
    input  wire [                 RxTypeCount:0] axis_mready
);

  // 首部剥离后的负载与侧带
  wire [         511:0] rx_data;
  wire [          63:0] rx_keep;
  wire [RxUsrWidth-1:0] rx_usr;
  wire                  rx_valid;
  wire                  rx_last;
  wire                  rx_ready;

  // 以太网首部剥离
  eth_header_strip eth_header_strip_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_svalid(axis_svalid),
      .axis_slast (axis_slast),
      .axis_sready(axis_sready),
      .axis_mdata (rx_data),
      .axis_mkeep (rx_keep),
      .axis_musr  (rx_usr),
      .axis_mvalid(rx_valid),
      .axis_mlast (rx_last),
      .axis_mready(rx_ready)
  );

  // EtherType分流，末路为未匹配通道。
  eth_type_demux #(
      .TypeCount(RxTypeCount),
      .UsrWidth (RxUsrWidth)
  ) eth_type_demux_inst (
      .clk          (clk),
      .rst          (rst),
      .cfg_type_dict(cfg_type_dict),
      .axis_sdata   (rx_data),
      .axis_skeep   (rx_keep),
      .axis_susr    (rx_usr),
      .axis_svalid  (rx_valid),
      .axis_slast   (rx_last),
      .axis_sready  (rx_ready),
      .axis_mdata   (axis_mdata),
      .axis_mkeep   (axis_mkeep),
      .axis_musr    (axis_musr),
      .axis_mvalid  (axis_mvalid),
      .axis_mlast   (axis_mlast),
      .axis_mready  (axis_mready)
  );

endmodule
`resetall
