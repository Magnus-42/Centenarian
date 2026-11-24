// -----------------------------------------------------------------------------
// File Name   : ipv4_header_add.v
// Module Name : ipv4_header_add
// Author      : LiXintao
// Created     : 2026-10-8
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 添加固定20字节IPv4头，并计算首部校验和。
// Note        : usr低ReqWidth位为请求，其上160位为原始IPv4首部。
//               校验字段由模块重新计算，出口usr仅保留请求。
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

  // 入口skid
  // p1 缓存本层负载与完整IPv4头元数据，校验字段按0求和。
  // p2 加法树：10个16位字 -> 5个p2_pair_sum -> 3个p2_partial_sum寄存值。
  // p3 合并部分和：p3_partial_sum -> p3_header_sum，得到20位首部总和。
  // p4 两次回卷进位：p3_fold1_add -> p3_fold2_add，取反后寄存到p4_checksum。
  // p5 出口skid寄存插入IPv4头后的数据与usr；末拍高20字节有效时另发尾拍。
  // p1至p4共享pipeline_ce，数据、字段及valid同步停顿；p5由skid握手独立推进。

  // IPv4首部校验和原理（RFC 791、RFC 1071）
  // 只对20字节IPv4首部求和，不包含本层负载；计算时首部校验和字段置0。
  // 将10个16位字相加，高16位进位回加到低16位，再将结果逐位取反。
  // 本实现先用加法树保留完整进位，再做两次折叠，等价于16位反码加法。

  // 参数范围检查
  initial begin
    if (ReqWidth < 1) begin
      $display("错误：ipv4_header_add：ReqWidth必须不小于1。");
      $finish;
    end
  end

  // 内部常量
  localparam integer PipelineDepth = 4;
  localparam integer ShiftDepth = PipelineDepth - 1;
  localparam integer Ipv4HeaderBits = 160;

  // 入口skid接口
  wire [               511:0] axis_sdata_skid;
  wire [                63:0] axis_skeep_skid;
  wire [        UsrWidth-1:0] axis_susr_skid;
  wire                        axis_slast_skid;
  wire                        axis_svalid_skid;
  wire                        axis_sready_skid;

  // 共享推进的载荷延迟，末级保持显式FF。
  reg  [               511:0] data_shift       [0:ShiftDepth-1];
  reg  [                63:0] keep_shift       [0:ShiftDepth-1];
  reg  [        UsrWidth-1:0] usr_shift        [0:ShiftDepth-1];
  reg  [      ShiftDepth-1:0] last_shift;
  reg  [   PipelineDepth-1:0] valid_shift;
  (* shreg_extract = "no" *)reg  [               511:0] p4_axis_sdata;
  (* shreg_extract = "no" *)reg  [                63:0] p4_axis_skeep;
  (* shreg_extract = "no" *)reg  [        UsrWidth-1:0] p4_axis_susr;
  (* shreg_extract = "no" *)reg                         p4_axis_slast;
  wire                        p4_axis_svalid;
  wire                        pipeline_ce;
  wire [               159:0] p1_ipv4_header;
  wire                        p4_needs_tail;

  // IPv4校验和计算
  wire [                16:0] p2_pair_sum      [           0:4];
  reg  [                17:0] p2_partial_sum   [           0:2];
  wire [                18:0] p3_partial_sum   [           0:1];
  reg  [                19:0] p3_header_sum;
  wire [                16:0] p3_fold1_add;
  wire [                16:0] p3_fold2_add;
  reg  [                15:0] p4_checksum;

  // 首拍标志
  reg                         p4_is_first_beat;

  // 跨拍缓存
  reg  [  Ipv4HeaderBits-1:0] data_held;
  reg  [Ipv4HeaderBits/8-1:0] keep_held;
  reg  [        UsrWidth-1:0] usr_held;

  // 尾拍补发控制
  reg                         tail_pending;

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
  wire                        p4_ready;
  wire                        p4_handshake;

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

  // 组成校验字段为0的IPv4首部，重新计算首部校验和。
  assign p1_ipv4_header = {usr_shift[0][ReqWidth+96+:64], 16'd0, usr_shift[0][ReqWidth+:80]};

  // 流水控制
  assign output_can_take = axis_mready_skid;
  assign insert_en = tail_pending && output_can_take;
  assign pipeline_ce = !tail_pending && (!p4_axis_svalid || output_can_take);
  assign axis_sready_skid = pipeline_ce;
  assign p4_ready = !tail_pending && output_can_take;
  assign p4_handshake = p4_ready && p4_axis_svalid;
  assign p4_needs_tail = p4_axis_slast && (|p4_axis_skeep[63-:20]);

  // p2 加法树：相邻16位字相加，10个字归并为5个17位部分和。
  assign p2_pair_sum[0] = p1_ipv4_header[15:0] + p1_ipv4_header[31:16];
  assign p2_pair_sum[1] = p1_ipv4_header[47:32] + p1_ipv4_header[63:48];
  assign p2_pair_sum[2] = p1_ipv4_header[79:64] + p1_ipv4_header[95:80];
  assign p2_pair_sum[3] = p1_ipv4_header[111:96] + p1_ipv4_header[127:112];
  assign p2_pair_sum[4] = p1_ipv4_header[143:128] + p1_ipv4_header[159:144];
  //// 两两合并并寄存为3项，未配对的第5项直接延迟。
  always @(posedge clk) begin
    if (pipeline_ce) begin
      p2_partial_sum[0] <= p2_pair_sum[0] + p2_pair_sum[1];
      p2_partial_sum[1] <= p2_pair_sum[2] + p2_pair_sum[3];
      p2_partial_sum[2] <= p2_pair_sum[4];
    end
  end

  // p3 加法树：3个部分和合并，寄存完整20位首部总和。
  assign p3_partial_sum[0] = p2_partial_sum[0] + p2_partial_sum[1];
  assign p3_partial_sum[1] = p2_partial_sum[2];
  //// 合并两项并寄存，仍保留未折叠的进位。
  always @(posedge clk) begin
    if (pipeline_ce) begin
      p3_header_sum <= p3_partial_sum[0] + p3_partial_sum[1];
    end
  end

  // p4 折叠进位并取反：组合计算仍以p3寄存值为输入，结果写入p4_checksum。
  //// 首次将20位总和的高4位回加，第二次将新产生的第16位进位回加。
  assign p3_fold1_add = p3_header_sum[15:0] + p3_header_sum[19:16];
  assign p3_fold2_add = {1'b0, p3_fold1_add[15:0]} + {16'd0, p3_fold1_add[16]};
  //// 折叠后取低16位逐位取反，得到首部校验和。
  always @(posedge clk) begin
    if (pipeline_ce) begin
      p4_checksum <= ~p3_fold2_add[15:0];
    end
  end

  // 补尾先于后续数据发送，补尾期间计算流水保持。
  always @(posedge clk) begin
    if (rst) tail_pending <= 1'b0;
    else if (p4_handshake) tail_pending <= p4_needs_tail;
    else if (insert_en) tail_pending <= 1'b0;
  end

  // 输出首拍标志
  always @(posedge clk) begin
    if (rst) begin
      p4_is_first_beat <= 1'b1;
    end else begin
      if (p4_handshake) begin
        p4_is_first_beat <= p4_axis_slast;
      end
    end
  end

  // 跨拍保持
  always @(posedge clk) begin
    if (p4_handshake) begin
      data_held <= p4_axis_sdata[511-:Ipv4HeaderBits];
    end
  end
  always @(posedge clk) begin
    if (p4_handshake) begin
      keep_held <= p4_axis_skeep[63-:Ipv4HeaderBits/8];
    end
  end
  always @(posedge clk) begin
    if (p4_handshake) begin
      usr_held <= p4_axis_susr;
    end
  end

  // 载荷与有效位同步推进，无效输入移入气泡。
  assign p4_axis_svalid = valid_shift[3];
  always @(posedge clk) begin : shift_payload
    integer stage_index;
    if (pipeline_ce) begin
      data_shift[0] <= axis_sdata_skid;
      keep_shift[0] <= axis_skeep_skid;
      usr_shift[0] <= axis_susr_skid;
      last_shift <= {last_shift[ShiftDepth-2:0], axis_slast_skid};
      for (stage_index = 1; stage_index < ShiftDepth; stage_index = stage_index + 1) begin
        data_shift[stage_index] <= data_shift[stage_index-1];
        keep_shift[stage_index] <= keep_shift[stage_index-1];
        usr_shift[stage_index]  <= usr_shift[stage_index-1];
      end
      p4_axis_sdata <= data_shift[ShiftDepth-1];
      p4_axis_skeep <= keep_shift[ShiftDepth-1];
      p4_axis_susr  <= usr_shift[ShiftDepth-1];
      p4_axis_slast <= last_shift[ShiftDepth-1];
    end
  end
  always @(posedge clk) begin
    if (rst) valid_shift <= 'd0;
    else if (pipeline_ce) valid_shift <= {valid_shift[PipelineDepth-2:0], axis_svalid_skid};
  end

  // p5 输出拼接与出口skid
  //// 首拍插入20字节IPv4头，后续拍拼接跨拍缓存；必需的尾拍优先发送。
  assign axis_mdata_skid = tail_pending ? {{352{1'b0}}, data_held} :
      (p4_is_first_beat ? {p4_axis_sdata[511-Ipv4HeaderBits:0], p4_axis_susr[ReqWidth+96+:64],
                           p4_checksum, p4_axis_susr[ReqWidth+:80]} :
       {p4_axis_sdata[511-Ipv4HeaderBits:0], data_held});
  assign axis_mkeep_skid = tail_pending ? {{44{1'b0}}, keep_held} :
      (p4_is_first_beat ? {p4_axis_skeep[63-Ipv4HeaderBits/8:0], {20{1'b1}}} :
       {p4_axis_skeep[63-Ipv4HeaderBits/8:0], keep_held});
  assign axis_musr_skid = tail_pending ? usr_held : p4_axis_susr;
  assign axis_mlast_skid = tail_pending || (!p4_needs_tail && p4_axis_slast);
  assign axis_mvalid_skid = tail_pending || p4_axis_svalid;
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
