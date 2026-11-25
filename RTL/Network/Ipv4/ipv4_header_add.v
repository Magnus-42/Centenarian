// -----------------------------------------------------------------------------
// File Name   : ipv4_header_add.v
// Module Name : ipv4_header_add
// Author      : LiXintao
// Created     : 2026-10-8
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 根据usr提供的20字节头添加IPv4首部。
// Note        : usr低ReqWidth位为请求，其上160位为原始IPv4首部。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module ipv4_header_add #(
    parameter  integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth + 160
) (
    input wire clk,
    input wire rst,

    input  wire [       511:0] axis_sdata,
    input  wire [        63:0] axis_skeep,
    input  wire                axis_slast,
    input  wire                axis_svalid,
    input  wire [UsrWidth-1:0] axis_susr,
    output wire                axis_sready,

    output wire [       511:0] axis_mdata,
    output wire [        63:0] axis_mkeep,
    output wire                axis_mlast,
    output wire                axis_mvalid,
    output wire [ReqWidth-1:0] axis_musr,
    input  wire                axis_mready
);

  // 入口skid同步缓存本层负载与IPv4头元数据。
  // p1缓存报文并拼接IPv4首部，必要时补发高20字节尾拍。
  // 出口skid保持完整数据和usr。

  // 参数范围检查
  initial begin
    if (ReqWidth < 1) begin
      $display("错误：ipv4_header_add：ReqWidth必须不小于1。");
      $finish;
    end
  end

  // 内部常量
  localparam integer Ipv4HeaderBits = 160;

  // 入口skid接口
  wire [               511:0] axis_sdata_skid;
  wire [                63:0] axis_skeep_skid;
  wire [        UsrWidth-1:0] axis_susr_skid;
  wire                        axis_slast_skid;
  wire                        axis_svalid_skid;
  wire                        axis_sready_skid;
  wire                        s_handshake_skid;

  // p1 数据与边带
  reg  [               511:0] p1_axis_sdata;
  reg  [                63:0] p1_axis_skeep;
  reg                         p1_axis_slast;
  reg                         p1_axis_svalid;
  reg  [        UsrWidth-1:0] p1_axis_susr;

  // p1 IPv4首部
  reg  [  Ipv4HeaderBits-1:0] p1_ipv4_header;
  // 首拍标志
  reg                         is_first_beat;

  // 跨拍缓存
  reg  [  Ipv4HeaderBits-1:0] data_held;
  reg  [Ipv4HeaderBits/8-1:0] keep_held;
  reg  [        UsrWidth-1:0] usr_held;

  // 尾拍补发控制
  reg                         p1_is_insert_beat;
  reg                         p2_is_insert_beat;

  // 出口skid接口
  wire                        axis_mready_skid;
  wire [               511:0] axis_mdata_skid;
  wire [                63:0] axis_mkeep_skid;
  wire [        UsrWidth-1:0] axis_musr_skid;
  wire                        axis_mlast_skid;
  wire                        axis_mvalid_skid;

  // 流水控制
  wire                        output_can_take;
  wire                        insert_en;
  wire                        p1_ready;
  wire                        p1_handshake;

  // 入口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth)
  ) axis_skid_buffer_in (
      .clk        (clk),
      .rst        (rst),
      .axis_sready(axis_sready),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_slast (axis_slast),
      .axis_svalid(axis_svalid),
      .axis_mready(axis_sready_skid),
      .axis_mdata (axis_sdata_skid),
      .axis_mkeep (axis_skeep_skid),
      .axis_musr  (axis_susr_skid),
      .axis_mlast (axis_slast_skid),
      .axis_mvalid(axis_svalid_skid)
  );

  // 流水控制
  assign output_can_take  = axis_mready_skid;
  assign insert_en        = p2_is_insert_beat && output_can_take;
  assign p1_ready         = output_can_take && !p2_is_insert_beat;
  assign s_handshake_skid = axis_sready_skid && axis_svalid_skid;
  assign p1_handshake     = p1_ready && p1_axis_svalid;
  assign axis_sready_skid = (!p1_axis_svalid || p1_ready) && !p1_is_insert_beat;
  // p1 输入缓存
  //// 数据与IPv4首部
  always @(posedge clk) begin
    if (s_handshake_skid) begin
      p1_axis_sdata  <= axis_sdata_skid;
      p1_axis_skeep  <= axis_skeep_skid;
      p1_axis_slast  <= axis_slast_skid;
      p1_axis_susr   <= axis_susr_skid;
      p1_ipv4_header <= axis_susr_skid[ReqWidth+:160];
    end
  end
  //// 有效信号
  always @(posedge clk) begin
    if (rst) p1_axis_svalid <= 1'b0;
    else if (s_handshake_skid) p1_axis_svalid <= 1'b1;
    else if (p1_handshake) p1_axis_svalid <= 1'b0;
  end

  // 补尾需求
  //// p1
  always @(posedge clk) begin
    if (rst) begin
      p1_is_insert_beat <= 'd0;
    end else begin
      if (s_handshake_skid) begin
        p1_is_insert_beat <= axis_slast_skid && (|axis_skeep_skid[63-:Ipv4HeaderBits/8]);
      end else if (p1_handshake) begin
        p1_is_insert_beat <= 'd0;
      end
    end
  end
  //// p2
  always @(posedge clk) begin
    if (rst) begin
      p2_is_insert_beat <= 'd0;
    end else begin
      if (p1_handshake) begin
        p2_is_insert_beat <= p1_is_insert_beat;
      end else if (insert_en) begin
        p2_is_insert_beat <= 'd0;
      end
    end
  end

  // 输入首拍标志
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;  // 复位后第一拍视为首拍
    end else begin
      if (p1_handshake) begin
        is_first_beat <=
            p1_axis_slast;  // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
      end
    end
  end

  // 跨拍保持
  //// data
  always @(posedge clk) begin
    if (p1_handshake) begin
      data_held <= p1_axis_sdata[511-:Ipv4HeaderBits];
    end
  end
  //// keep
  always @(posedge clk) begin
    if (p1_handshake) begin
      keep_held <= p1_axis_skeep[63-:Ipv4HeaderBits/8];
    end
  end
  //// usr
  always @(posedge clk) begin
    if (p1_handshake) begin
      usr_held <= p1_axis_susr;
    end
  end

  // 输出拼接
  assign axis_mdata_skid = p2_is_insert_beat ? {352'd0, data_held}
    : (is_first_beat
        ? {p1_axis_sdata[511-Ipv4HeaderBits:0], p1_ipv4_header}
        : {p1_axis_sdata[511-Ipv4HeaderBits:0], data_held});
  assign axis_mkeep_skid = p2_is_insert_beat ?
      {44'd0, keep_held} : (is_first_beat ? {p1_axis_skeep[63-Ipv4HeaderBits/8:0], {20{1'b1}}} :
                                 {p1_axis_skeep[63-Ipv4HeaderBits/8:0], keep_held});
  assign axis_musr_skid = p2_is_insert_beat ? usr_held : p1_axis_susr;
  assign axis_mlast_skid = p2_is_insert_beat || (!p1_is_insert_beat && p1_axis_slast);
  assign axis_mvalid_skid = p2_is_insert_beat || p1_axis_svalid;
  // 出口skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (ReqWidth)
  ) axis_skid_buffer_out (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (axis_mdata_skid),
      .axis_skeep (axis_mkeep_skid),
      .axis_susr  (axis_musr_skid[ReqWidth-1:0]),
      .axis_slast (axis_mlast_skid),
      .axis_svalid(axis_mvalid_skid),
      .axis_sready(axis_mready_skid),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_musr  (axis_musr),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid),
      .axis_mready(axis_mready)
  );
endmodule
`resetall
