// -----------------------------------------------------------------------------
// File Name   : eth_tx.v
// Module Name : eth_tx
// Author      : Lixintao
// Created     : 2026-11-24
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 以太网发送通路，逐路加头、按帧仲裁并补齐短帧。
// Note        :
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module eth_tx #(
    parameter  integer TxChannelCount = 4,
    parameter  integer TxReqWidth     = 4,
    localparam integer TxUsrWidth     = TxReqWidth + 112
) (
    input wire clk,
    input wire rst,

    input  wire [       512*TxChannelCount-1:0] axis_sdata,
    input  wire [        64*TxChannelCount-1:0] axis_skeep,
    input  wire [TxUsrWidth*TxChannelCount-1:0] axis_susr,
    input  wire [           TxChannelCount-1:0] axis_slast,
    input  wire [           TxChannelCount-1:0] axis_svalid,
    output wire [           TxChannelCount-1:0] axis_sready,

    output wire [511:0] axis_mdata,
    output wire [ 63:0] axis_mkeep,
    output wire         axis_mlast,
    output wire         axis_mvalid,
    input  wire         axis_mready
);

  // 参数范围检查
  initial begin
    if (TxChannelCount < 1 || TxReqWidth < 1) begin
      $display("错误：eth_tx：通道数量和请求位宽必须大于0。");
      $finish;
    end
  end

  // 逐路加头后的完整以太网帧
  wire [       512*TxChannelCount-1:0] header_data;
  wire [        64*TxChannelCount-1:0] header_keep;
  wire [TxReqWidth*TxChannelCount-1:0] header_usr;
  wire [           TxChannelCount-1:0] header_last;
  wire [           TxChannelCount-1:0] header_valid;
  wire [           TxChannelCount-1:0] header_ready;

  // 仲裁输出
  wire [                        511:0] mux_data;
  wire [                         63:0] mux_keep;
  wire                                 mux_last;
  wire                                 mux_valid;
  wire                                 mux_ready;

  genvar tx_index;

  // 以太网加头
  for (tx_index = 0; tx_index < TxChannelCount; tx_index = tx_index + 1) begin : gen_tx_header
    eth_header_add #(
        .ReqWidth(TxReqWidth)
    ) eth_header_add_inst (
        .clk        (clk),
        .rst        (rst),
        .axis_sdata (axis_sdata[tx_index*512+:512]),
        .axis_skeep (axis_skeep[tx_index*64+:64]),
        .axis_susr  (axis_susr[tx_index*TxUsrWidth+:TxUsrWidth]),
        .axis_slast (axis_slast[tx_index]),
        .axis_svalid(axis_svalid[tx_index]),
        .axis_sready(axis_sready[tx_index]),
        .axis_mdata (header_data[tx_index*512+:512]),
        .axis_mkeep (header_keep[tx_index*64+:64]),
        .axis_musr  (header_usr[tx_index*TxReqWidth+:TxReqWidth]),
        .axis_mlast (header_last[tx_index]),
        .axis_mvalid(header_valid[tx_index]),
        .axis_mready(header_ready[tx_index])
    );
  end

  // 完整帧仲裁，usr仅含请求优先级。
  eth_tx_mux #(
      .ChannelCount(TxChannelCount),
      .TxReqWidth  (TxReqWidth)
  ) eth_tx_mux_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (header_data),
      .axis_skeep (header_keep),
      .axis_susr  (header_usr),
      .axis_slast (header_last),
      .axis_svalid(header_valid),
      .axis_sready(header_ready),
      .axis_mdata (mux_data),
      .axis_mkeep (mux_keep),
      .axis_musr  (),
      .axis_mlast (mux_last),
      .axis_mvalid(mux_valid),
      .axis_mready(mux_ready)
  );

  // 短帧补齐到60字节，FCS继续由CMAC生成。
  eth_frame_pad60 eth_frame_pad60_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (mux_data),
      .axis_skeep (mux_keep),
      .axis_slast (mux_last),
      .axis_svalid(mux_valid),
      .axis_sready(mux_ready),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid),
      .axis_mready(axis_mready)
  );
endmodule
`resetall
