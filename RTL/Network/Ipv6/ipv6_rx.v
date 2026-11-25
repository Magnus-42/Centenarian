// -----------------------------------------------------------------------------
// File Name   : ipv6_rx.v
// Module Name : ipv6_rx
// Author      : Codex
// Created     : 2026-11-25
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : IPv6接收链，剥离IP首部并按协议字典分流。
// Note        : 输入data为IPv6报文，输出data为本层负载，首部追加到usr高位。
//               输出共TypeCount+1路，末路为默认通道。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv6_rx #(
    parameter  integer TypeCount          = 3,
    localparam integer EffectiveTypeCount = (TypeCount > 0) ? TypeCount : 1,
    localparam integer MacUsrWidth        = 113,
    localparam integer UsrWidth           = 433
) (
    input wire clk,
    input wire rst,

    input wire [EffectiveTypeCount*8-1:0] cfg_type_dict,

    input  wire [          511:0] axis_sdata,
    input  wire [           63:0] axis_skeep,
    input  wire [MacUsrWidth-1:0] axis_susr,
    input  wire                   axis_svalid,
    input  wire                   axis_slast,
    output wire                   axis_sready,

    output wire [     512*(TypeCount+1)-1:0] axis_mdata,
    output wire [      64*(TypeCount+1)-1:0] axis_mkeep,
    output wire [UsrWidth*(TypeCount+1)-1:0] axis_musr,
    output wire [               TypeCount:0] axis_mvalid,
    output wire [               TypeCount:0] axis_mlast,
    input  wire [               TypeCount:0] axis_mready
);

  // 剥离固定IP首部，再从usr匹配协议字段并按帧分流。

  // 参数范围检查
  initial begin
    if (TypeCount < 0) begin
      $display("错误：ipv6_rx：TypeCount必须不小于0。");
      $finish;
    end
  end

  // 接收载荷接口
  wire [       511:0] payload_data;
  wire [        63:0] payload_keep;
  wire [UsrWidth-1:0] payload_usr;
  wire                payload_last;
  wire                payload_valid;
  wire                payload_ready;

  // 接收通路
  //// IP首部剥离
  ipv6_header_strip ipv6_header_strip_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_slast (axis_slast),
      .axis_svalid(axis_svalid),
      .axis_susr  (axis_susr),
      .axis_sready(axis_sready),
      .axis_mdata (payload_data),
      .axis_mkeep (payload_keep),
      .axis_mlast (payload_last),
      .axis_mvalid(payload_valid),
      .axis_mready(payload_ready),
      .axis_musr  (payload_usr)
  );
  //// 协议分流
  ipv6_proto_demux #(
      .TypeCount(TypeCount)
  ) ipv6_proto_demux_inst (
      .clk          (clk),
      .rst          (rst),
      .cfg_type_dict(cfg_type_dict),
      .axis_sdata   (payload_data),
      .axis_skeep   (payload_keep),
      .axis_slast   (payload_last),
      .axis_svalid  (payload_valid),
      .axis_susr    (payload_usr),
      .axis_sready  (payload_ready),
      .axis_mdata   (axis_mdata),
      .axis_mkeep   (axis_mkeep),
      .axis_mlast   (axis_mlast),
      .axis_mvalid  (axis_mvalid),
      .axis_musr    (axis_musr),
      .axis_mready  (axis_mready)
  );

endmodule
`resetall
