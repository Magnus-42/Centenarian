// -----------------------------------------------------------------------------
// File Name   : axis_skid_buffer.v
// Module Name : axis_skid_buffer
// Author      : LiXintao
// Created     : 2026-09-20
// Version     : 1.1
// -----------------------------------------------------------------------------
// Description : AXIS skid缓冲，阻断下游ready的组合传递。
// Note        : 上游ready由skid有效位产生，最小传输延迟为1拍。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module axis_skid_buffer #(
    parameter  integer DataWidth        = 8,
    parameter  integer UsrWidth         = 1,
    parameter  integer SelectGroupWidth = 128,
    localparam integer KeepWidth        = DataWidth / 8
) (
    input wire clk,
    input wire rst,

    output wire                 axis_sready,
    input  wire [DataWidth-1:0] axis_sdata,
    input  wire [KeepWidth-1:0] axis_skeep,
    input  wire [ UsrWidth-1:0] axis_susr,
    input  wire                 axis_slast,
    input  wire                 axis_svalid,

    input  wire                 axis_mready,
    output wire [DataWidth-1:0] axis_mdata,
    output wire [KeepWidth-1:0] axis_mkeep,
    output wire [ UsrWidth-1:0] axis_musr,
    output wire                 axis_mlast,
    output wire                 axis_mvalid
);

  // p1寄存AXIS输出，skid在下游阻塞时暂存一拍。

  // 参数范围检查
  initial begin
    if (DataWidth < 8 || DataWidth % 8 != 0 || UsrWidth < 1 ||
        SelectGroupWidth < 8 || SelectGroupWidth % 8 != 0) begin
      $display("错误：axis_skid_buffer：不支持的参数配置。");
      $finish;
    end
  end

  // 分组常量
  localparam integer SelectPayloadWidth = DataWidth > UsrWidth ? DataWidth : UsrWidth;
  localparam integer SelectGroupCount =
      SelectGroupWidth >= 8 ? (SelectPayloadWidth - 1) / SelectGroupWidth + 1 : 1;

  // p1 输出缓存
  reg  [       DataWidth-1:0] p1_axis_mdata;
  reg  [       KeepWidth-1:0] p1_axis_mkeep;
  reg  [        UsrWidth-1:0] p1_axis_musr;
  reg                         p1_axis_mlast;
  reg                         p1_axis_mvalid;
  wire                        p1_can_take;

  // skid暂存
  reg  [       DataWidth-1:0] axis_mdata_skid;
  reg  [       KeepWidth-1:0] axis_mkeep_skid;
  reg  [        UsrWidth-1:0] axis_musr_skid;
  reg                         axis_mlast_skid;
  wire                        axis_mvalid_skid;
  wire                        s_to_skid;

  // 握手与转移控制
  wire                        s_handshake;
  wire                        m_handshake;
  wire                        skid_to_p1;
  wire                        s_to_p1;
  wire                        skid_valid_next;
  wire [SelectGroupCount-1:0] skid_valid_group;

  // 生成循环
  genvar g_group;

  // 握手与转移控制
  assign axis_mvalid_skid = skid_valid_group[0];
  assign s_handshake      = axis_svalid && axis_sready;
  assign m_handshake      = axis_mready && axis_mvalid;
  assign axis_sready      = !axis_mvalid_skid;

  assign p1_can_take      = !p1_axis_mvalid || m_handshake;
  assign skid_to_p1       = axis_mvalid_skid && p1_can_take;
  assign s_to_p1          = s_handshake && p1_can_take;
  assign s_to_skid        = s_handshake && !p1_can_take;
  assign skid_valid_next  = s_to_skid ? 1'b1 : (skid_to_p1 ? 1'b0 : axis_mvalid_skid);

  // 输出有效位
  always @(posedge clk) begin
    if (rst) begin
      p1_axis_mvalid <= 'd0;
    end else begin
      p1_axis_mvalid <= (s_to_p1 || skid_to_p1) ? 1'b1 : (m_handshake ? 1'b0 : p1_axis_mvalid);
    end
  end

  // 分组占用状态与载荷
  for (g_group = 0; g_group < SelectGroupCount; g_group = g_group + 1) begin : gen_select_group
    localparam integer KeepLsb = (g_group * KeepWidth + SelectGroupCount - 1) / SelectGroupCount;
    localparam integer KeepEnd =
        ((g_group + 1) * KeepWidth + SelectGroupCount - 1) / SelectGroupCount;
    localparam integer KeepBits = KeepEnd - KeepLsb;
    localparam integer DataLsb = KeepLsb * 8;
    localparam integer DataBits = KeepBits * 8;
    localparam integer UsrLsb = (g_group * UsrWidth + SelectGroupCount - 1) / SelectGroupCount;
    localparam integer UsrEnd =
        ((g_group + 1) * UsrWidth + SelectGroupCount - 1) / SelectGroupCount;
    localparam integer UsrBits = UsrEnd - UsrLsb;
    wire capture_skid;

    assign capture_skid = !skid_valid_group[g_group] && !p1_can_take;
    //// 复制axis_mvalid_skid寄存器
    if (SelectGroupCount == 1) begin : gen_shared
      reg axis_mvalid_skid_group;
      always @(posedge clk) begin
        if (rst) axis_mvalid_skid_group <= 1'b0;
        else axis_mvalid_skid_group <= skid_valid_next;
      end
      assign skid_valid_group[g_group] = axis_mvalid_skid_group;
    end else begin : gen_replica
      (* dont_touch = "true" *) reg axis_mvalid_skid_group;
      always @(posedge clk) begin
        if (rst) axis_mvalid_skid_group <= 1'b0;
        else axis_mvalid_skid_group <= skid_valid_next;
      end
      assign skid_valid_group[g_group] = axis_mvalid_skid_group;
    end
    //// data、keep、usr选取
    if (DataBits > 0) begin : gen_data
      always @(posedge clk) begin
        if (p1_can_take) begin
          p1_axis_mdata[DataLsb+:DataBits] <= skid_valid_group[g_group] ?
              axis_mdata_skid[DataLsb+:DataBits] : axis_sdata[DataLsb+:DataBits];
          p1_axis_mkeep[KeepLsb+:KeepBits] <= skid_valid_group[g_group] ?
              axis_mkeep_skid[KeepLsb+:KeepBits] : axis_skeep[KeepLsb+:KeepBits];
        end
        if (capture_skid) begin
          axis_mdata_skid[DataLsb+:DataBits] <= axis_sdata[DataLsb+:DataBits];
          axis_mkeep_skid[KeepLsb+:KeepBits] <= axis_skeep[KeepLsb+:KeepBits];
        end
      end
    end
    if (UsrBits > 0) begin : gen_usr
      always @(posedge clk) begin
        if (p1_can_take) begin
          p1_axis_musr[UsrLsb+:UsrBits] <= skid_valid_group[g_group] ?
              axis_musr_skid[UsrLsb+:UsrBits] : axis_susr[UsrLsb+:UsrBits];
        end
        if (capture_skid) begin
          axis_musr_skid[UsrLsb+:UsrBits] <= axis_susr[UsrLsb+:UsrBits];
        end
      end
    end
  end
  //// last使用第0组状态
  always @(posedge clk) begin
    p1_axis_mlast <=
       p1_can_take ? (axis_mvalid_skid ? axis_mlast_skid : axis_slast) : p1_axis_mlast;

    axis_mlast_skid <= (axis_sready && !p1_can_take) ? axis_slast : axis_mlast_skid;
  end

  // 输出
  assign axis_mdata  = p1_axis_mdata;
  assign axis_mkeep  = p1_axis_mkeep;
  assign axis_musr   = p1_axis_musr;
  assign axis_mlast  = p1_axis_mlast;
  assign axis_mvalid = p1_axis_mvalid;
endmodule
`resetall
