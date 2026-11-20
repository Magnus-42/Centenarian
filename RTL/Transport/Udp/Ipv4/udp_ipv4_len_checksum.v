// -----------------------------------------------------------------------------
// File Name   : udp_ipv4_len_checksum.v
// Module Name : udp_ipv4_len_checksum
// Author      : LiXintao
// Created     : 2026-10-16
// Version     : v1.0

// Description : UDP长度和校验和计算，整包缓存后输出。
// Note        : 严格整包缓存仅支持不超过512拍的应用载荷，非末拍keep全1、末拍keep低位连续。
//               1. total_len / head_checksum 与首拍对齐,并在本包内保持恒定
//               2. total_len / head_checksum 小端序
//               3. 源/目的 IP、源/目的端口取自 axis_susr, 每包独立;
//                  usr 必须包内恒定
//               usr低ReqWidth位为请求，其上为TTL、源端口、目的端口、源IP和目的IP。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module udp_ipv4_len_checksum #(
    parameter  integer ReqWidth = 4,
    localparam integer UsrWidth = ReqWidth + 104
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
    output wire [UsrWidth-1:0] axis_musr,
    input  wire                axis_mready,

    output wire [15:0] total_len,     // UDP长度(=8+载荷)
    output wire [15:0] head_checksum  // UDP校验和(含伪首部)
);

  // 写入
  // 入口skid缓存数据与usr。
  // p1 计算data掩码，相加stg0~stg1，计算src_ip_sum、dst_ip_sum、port_sum。
  // p2 相加stg2~stg3，计算ip_sum、type_port_sum。
  // p3 相加stg4~stg5，累计udp_len，计算type_ip_port_sum。
  // p4 累计payload_sum，末拍计算head_sum。
  // p5 末拍计算total_sum。
  // p6 折叠进位并取反。
  // p7 零值映射，得到checksum。
  // p7直接写入载荷FIFO，末拍同步提交长度和校验和。
  // 数据流写入axis_fifo_sync_payload、 udp长度和校验和写入fifo_sync_result
  // 读出：结果FIFO输出寄存，首拍取用并保持，读侧skid同步输出载荷与结果。

  // UDP校验和原理（RFC 768、RFC 1071）
  // 参与计算的内容为IPv4伪首部、8字节UDP头及应用载荷，UDP校验和字段按0计算。
  // 伪首部只参与求和，不发送：源IP、目的IP、零字节、协议号17及UDP长度。
  // UDP长度L=8+应用载荷字节数；L在伪首部与UDP头各出现一次，因此总和加入两份L。
  // 对上述内容按16位字求反码和：保留进位累加，最后将高16位回加到低16位并取反。
  // 奇数个载荷字节时，仅在计算中为最后一个字补零，不改变输出keep及实际UDP长度。
  // 若取反结果为16'h0000，发送16'hffff；线上全0表示未启用UDP校验和。

  // 参数范围检查
  initial begin
    if (ReqWidth < 1) begin
      $display("错误：udp_ipv4_len_checksum：ReqWidth必须不小于1。");
      $finish;
    end
  end

  // 内部常量
  localparam integer PipelineDepth = 7;
  localparam integer ShiftDepth = PipelineDepth - 1;
  localparam integer UsrSrcPortLsb = ReqWidth + 8;
  localparam integer UsrDstPortLsb = ReqWidth + 24;
  localparam integer UsrSrcIpLsb = ReqWidth + 40;
  localparam integer UsrDstIpLsb = ReqWidth + 72;

  // 入口skid接口
  wire    [            511:0] axis_sdata_skid;
  wire    [             63:0] axis_skeep_skid;
  wire    [     UsrWidth-1:0] axis_susr_skid;
  wire                        axis_slast_skid;
  wire                        axis_svalid_skid;
  wire                        axis_sready_skid;
  wire                        s_handshake_skid;

  // 共享推进的载荷延迟，末级保持显式FF。
  reg     [            511:0] data_shift           [0:ShiftDepth-1];
  reg     [             63:0] keep_shift           [0:ShiftDepth-1];
  reg     [     UsrWidth-1:0] usr_shift            [0:ShiftDepth-1];
  reg     [   ShiftDepth-1:0] last_shift;
  reg     [PipelineDepth-1:0] valid_shift;
  (* shreg_extract = "no" *)reg     [            511:0] p7_axis_sdata;
  (* shreg_extract = "no" *)reg     [             63:0] p7_axis_skeep;
  (* shreg_extract = "no" *)reg     [     UsrWidth-1:0] p7_axis_susr;
  (* shreg_extract = "no" *)reg                         p7_axis_slast;
  wire                        p7_axis_svalid;
  wire                        pipeline_ce;
  wire                        p1_axis_svalid;
  wire                        p2_axis_svalid;
  wire                        p3_axis_svalid;
  wire                        p4_axis_svalid;
  wire                        p5_axis_svalid;
  wire                        p6_axis_svalid;
  wire    [             63:0] p2_axis_skeep;
  wire                        p1_axis_slast;
  wire                        p2_axis_slast;
  wire                        p3_axis_slast;
  wire                        p4_axis_slast;
  wire                        p5_axis_slast;
  wire                        p6_axis_slast;

  // 载荷FIFO写接口
  wire                        fifo_axis_sready;
  wire                        fifo_write_handshake;

  // 流水控制
  wire                        p1_handshake;
  wire                        p2_handshake;
  wire                        p3_handshake;
  wire                        p4_handshake;
  wire                        p5_handshake;
  wire                        p6_handshake;

  // p2字节数
  reg     [              6:0] p2_byte_count;

  // p3累计UDP长度，p4至p7延迟对齐最终校验和。
  reg     [             15:0] p3_udp_len;
  reg     [             15:0] p4_udp_len;
  reg     [             15:0] p5_udp_len;
  reg     [             15:0] p6_udp_len;
  reg     [             15:0] p7_udp_len;

  // 首拍标志
  reg     [              2:0] first_shift;
  wire                        p1_is_first_beat;
  wire                        p2_is_first_beat;
  wire                        p3_is_first_beat;
  reg                         is_first_beat;

  // 伪首部与UDP头加法树
  reg     [             31:0] p1_src_ip_sum;
  reg     [             31:0] p1_dst_ip_sum;
  reg     [             31:0] p1_port_sum;
  reg     [             31:0] p2_type_port_sum;
  reg     [             31:0] p2_ip_sum;
  reg     [             31:0] p3_type_ip_port_sum;
  reg     [             31:0] p4_head_sum;

  // UDP载荷加法树与校验和
  wire    [             15:0] stg0_masked_raw      [          0:31];
  reg     [             16:0] p1_stg1              [          0:15];
  wire    [             17:0] p2_stg2_add          [           0:7];
  reg     [             18:0] p2_stg3              [           0:3];
  wire    [             19:0] p3_stg4_add          [           0:1];
  reg     [             20:0] p3_stg5;
  reg     [             31:0] p4_payload_sum;
  reg     [             31:0] p5_total_sum;
  wire    [             16:0] fold1;
  wire    [             15:0] fold2;
  reg     [             15:0] p6_checksum_fold;
  reg     [             15:0] p7_checksum;

  // 读侧首拍选取逐帧结果，其余拍保持同一份长度与校验和。
  reg                         is_first_fifo_beat;
  reg     [             31:0] result_held;
  wire    [             31:0] selected_result;

  // 结果FIFO输出寄存
  reg     [             31:0] result_head;
  reg                         result_head_valid;
  wire                        result_head_can_take;
  wire                        result_head_take;

  // 出口skid接口
  wire                        axis_mready_skid;
  wire                        axis_mvalid_skid;

  // 载荷FIFO读接口
  wire    [            511:0] fifo_axis_mdata;
  wire    [             63:0] fifo_axis_mkeep;
  wire                        fifo_axis_mvalid;
  wire                        fifo_axis_mlast;
  wire                        fifo_axis_mready;
  wire    [     UsrWidth-1:0] fifo_axis_musr;
  wire                        fifo_read_handshake;

  // 结果FIFO接口
  wire    [             31:0] result_fifo_din;
  wire                        result_fifo_rd_en;
  wire                        result_fifo_wr_en;
  wire    [             31:0] result_fifo_dout;
  wire                        result_fifo_empty;

  // 循环变量
  integer                     keep_index;
  genvar g_i;

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
  assign pipeline_ce          = !p7_axis_svalid || fifo_axis_sready;
  assign axis_sready_skid     = pipeline_ce;
  assign s_handshake_skid     = axis_svalid_skid && axis_sready_skid;
  assign p1_handshake         = p1_axis_svalid && pipeline_ce;
  assign p2_handshake         = p2_axis_svalid && pipeline_ce;
  assign p3_handshake         = p3_axis_svalid && pipeline_ce;
  assign p4_handshake         = p4_axis_svalid && pipeline_ce;
  assign p5_handshake         = p5_axis_svalid && pipeline_ce;
  assign p6_handshake         = p6_axis_svalid && pipeline_ce;
  assign fifo_write_handshake = p7_axis_svalid && fifo_axis_sready;

  // 载荷与逐帧结果的配对控制
  //// 末拍提交结果
  assign result_fifo_din      = {p7_udp_len[7:0], p7_udp_len[15:8], p7_checksum};
  assign result_fifo_wr_en    = p7_axis_slast && fifo_write_handshake;
  //// 结果预取
  assign result_head_take     = is_first_fifo_beat && fifo_read_handshake;
  assign result_head_can_take = !result_head_valid || result_head_take;
  assign result_fifo_rd_en    = !result_fifo_empty && result_head_can_take;
  //// 载荷FIFO与出口skid同步握手。
  assign fifo_read_handshake  = fifo_axis_mready && fifo_axis_mvalid;
  assign fifo_axis_mready     = axis_mready_skid && (!is_first_fifo_beat || result_head_valid);
  assign axis_mvalid_skid     = fifo_axis_mvalid && (!is_first_fifo_beat || result_head_valid);

  // 统计字节数
  //// p2 字节数
  always @* begin
    p2_byte_count = 7'd0;
    for (keep_index = 0; keep_index < 64; keep_index = keep_index + 1) begin
      if (p2_axis_skeep[keep_index]) begin
        p2_byte_count = keep_index[6:0] + 7'd1;
      end
    end
  end
  //// p3 累计p3_udp_len，含UDP头
  always @(posedge clk) begin
    if (p2_handshake && p2_is_first_beat) begin
      p3_udp_len <= 16'd8 + p2_byte_count;
    end else if (p2_handshake) begin
      p3_udp_len <= p3_udp_len + p2_byte_count;
    end
  end

  // 伪首部与UDP头加法树
  //// p1 源IP部分和。
  always @(posedge clk) begin
    if (s_handshake_skid && is_first_beat) begin
      p1_src_ip_sum <= axis_susr_skid[UsrSrcIpLsb+16+:16] + axis_susr_skid[UsrSrcIpLsb+:16];
    end
  end
  //// p1 目的IP部分和。
  always @(posedge clk) begin
    if (s_handshake_skid && is_first_beat) begin
      p1_dst_ip_sum <= axis_susr_skid[UsrDstIpLsb+16+:16] + axis_susr_skid[UsrDstIpLsb+:16];
    end
  end
  //// p1 源/目的端口部分和。
  always @(posedge clk) begin
    if (s_handshake_skid && is_first_beat) begin
      p1_port_sum <= {1'b0, axis_susr_skid[UsrSrcPortLsb+:16]} +
          {1'b0, axis_susr_skid[UsrDstPortLsb+:16]};
    end
  end
  //// p2 合并源/目的IP部分和。
  always @(posedge clk) begin
    if (p1_handshake && p1_is_first_beat) begin
      p2_ip_sum <= p1_dst_ip_sum + p1_src_ip_sum;
    end
  end
  //// p2 合并端口与协议号。
  ////// 零字节与协议号17按总线序排列为16'h1100。
  always @(posedge clk) begin
    if (p1_handshake && p1_is_first_beat) begin
      p2_type_port_sum <= p1_port_sum + 16'h1100;
    end
  end
  //// p3 合并IP、端口与协议号。
  always @(posedge clk) begin
    if (p2_handshake && p2_is_first_beat) begin
      p3_type_ip_port_sum <= p2_type_port_sum + p2_ip_sum;
    end
  end
  //// p4 末拍加入两份UDP长度，得到head_sum。
  ////// 伪首部和UDP头各含一份长度，数值转总线序后乘2。
  always @(posedge clk) begin
    if (p3_handshake && p3_axis_slast) begin
      p4_head_sum <= p3_type_ip_port_sum + {p3_udp_len[7:0], p3_udp_len[15:8], 1'b0};
    end
  end

  // UDP载荷加法树与校验和
  //// p1 计算data掩码，相加stg0~stg1。
  ////// 无效字节补0，奇数尾字高字节补0。
  for (g_i = 0; g_i < 32; g_i = g_i + 1) begin : gen_mask
    assign stg0_masked_raw[g_i] = (axis_skeep_skid[g_i*2+:2] == 2'b11) ? axis_sdata_skid[g_i*16+:16]
        : ((axis_skeep_skid[g_i*2+:2] == 2'b01) ? {8'h00, axis_sdata_skid[g_i*16+:8]} : 16'd0);
  end
  for (g_i = 0; g_i < 16; g_i = g_i + 1) begin : gen_stg1
    always @(posedge clk) begin
      if (s_handshake_skid) begin
        p1_stg1[g_i] <= stg0_masked_raw[g_i*2] + stg0_masked_raw[g_i*2+1];
      end
    end
  end
  //// p2 相加stg2~stg3。
  for (g_i = 0; g_i < 8; g_i = g_i + 1) begin : gen_stg2
    assign p2_stg2_add[g_i] = p1_stg1[g_i*2] + p1_stg1[g_i*2+1];
  end
  for (g_i = 0; g_i < 4; g_i = g_i + 1) begin : gen_stg3
    always @(posedge clk) begin
      if (p1_handshake) begin
        p2_stg3[g_i] <= p2_stg2_add[g_i*2] + p2_stg2_add[g_i*2+1];
      end
    end
  end
  //// p3 相加stg4~stg5。
  for (g_i = 0; g_i < 2; g_i = g_i + 1) begin : gen_stg4
    assign p3_stg4_add[g_i] = p2_stg3[g_i*2] + p2_stg3[g_i*2+1];
  end
  always @(posedge clk) begin
    if (p2_handshake) begin
      p3_stg5 <= p3_stg4_add[0] + p3_stg4_add[1];
    end
  end
  //// p4 累计payload_sum。
  always @(posedge clk) begin
    if (p3_handshake && p3_is_first_beat) begin
      p4_payload_sum <= p3_stg5;
    end else if (p3_handshake) begin
      p4_payload_sum <= p4_payload_sum + p3_stg5;
    end
  end
  //// p5 合并两路和，得到total_sum。
  always @(posedge clk) begin
    if (p4_handshake && p4_axis_slast) begin
      p5_total_sum <= p4_head_sum + p4_payload_sum;
    end
  end
  //// p6 折叠进位并取反。
  assign fold1 = p5_total_sum[15:0] + p5_total_sum[31:16];
  assign fold2 = fold1[15:0] + fold1[16];
  always @(posedge clk) begin
    if (p5_handshake && p5_axis_slast) begin
      p6_checksum_fold <= ~fold2;
    end
  end
  //// p7 生成checksum，零值映射为全1。
  always @(posedge clk) begin
    if (p6_handshake && p6_axis_slast) begin
      p7_checksum <= (p6_checksum_fold == 16'h0000) ? 16'hFFFF : p6_checksum_fold;
    end
  end

  // 输入首拍标志
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;
    end else begin
      if (s_handshake_skid) begin
        is_first_beat <= axis_slast_skid;
      end
    end
  end

  // 载荷与有效位同步推进，无效输入移入气泡。
  assign p2_axis_skeep    = keep_shift[1];
  assign p1_axis_slast    = last_shift[0];
  assign p2_axis_slast    = last_shift[1];
  assign p3_axis_slast    = last_shift[2];
  assign p4_axis_slast    = last_shift[3];
  assign p5_axis_slast    = last_shift[4];
  assign p6_axis_slast    = last_shift[5];
  assign p1_is_first_beat = first_shift[0];
  assign p2_is_first_beat = first_shift[1];
  assign p3_is_first_beat = first_shift[2];
  assign p1_axis_svalid   = valid_shift[0];
  assign p2_axis_svalid   = valid_shift[1];
  assign p3_axis_svalid   = valid_shift[2];
  assign p4_axis_svalid   = valid_shift[3];
  assign p5_axis_svalid   = valid_shift[4];
  assign p6_axis_svalid   = valid_shift[5];
  assign p7_axis_svalid   = valid_shift[6];

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
      p7_axis_sdata <= data_shift[ShiftDepth-1];
      p7_axis_skeep <= keep_shift[ShiftDepth-1];
      p7_axis_susr  <= usr_shift[ShiftDepth-1];
      p7_axis_slast <= last_shift[ShiftDepth-1];
    end
  end
  always @(posedge clk) begin
    if (rst) valid_shift <= 'd0;
    else if (pipeline_ce) valid_shift <= {valid_shift[PipelineDepth-2:0], axis_svalid_skid};
  end

  // 首拍标志延迟到p3参与累计控制，p3_udp_len延迟到p7与最终校验和对齐。
  always @(posedge clk) begin
    if (pipeline_ce) begin
      first_shift <= {first_shift[1:0], is_first_beat};
      p4_udp_len  <= p3_udp_len;
      p5_udp_len  <= p4_udp_len;
      p6_udp_len  <= p5_udp_len;
      p7_udp_len  <= p6_udp_len;
    end
  end

  // 整包载荷FIFO与逐帧结果FIFO：实际写入载荷末拍时，同时保存对应长度与校验和。
  axis_fifo_sync #(
      .Depth         (512),
      .DataWidth     (512),
      .UsrWidth      (UsrWidth),
      .PacketFifo    (1),
      .DataMemoryType("block"),
      .DeadlockRisk  (1),
      .UsrMemoryType ("block")
  ) axis_fifo_sync_payload (
      .clk            (clk),
      .rst            (rst),
      .axis_sdata     (p7_axis_sdata),
      .axis_skeep     (p7_axis_skeep),
      .axis_svalid    (p7_axis_svalid),
      .axis_slast     (p7_axis_slast),
      .axis_sready    (fifo_axis_sready),
      .axis_susr      (p7_axis_susr),
      .axis_mdata     (fifo_axis_mdata),
      .axis_mkeep     (fifo_axis_mkeep),
      .axis_mvalid    (fifo_axis_mvalid),
      .axis_mlast     (fifo_axis_mlast),
      .axis_mready    (fifo_axis_mready),
      .axis_musr      (fifo_axis_musr),
      .stat_prog_empty(),
      .stat_prog_full (),
      .stat_empty     (),
      .stat_full      (),
      .stat_data_count()
  );
  fifo_sync #(
      .Depth     (512),
      .Width     (32),
      .MemoryType("distributed")
  ) fifo_sync_result (
      .clk            (clk),
      .rst            (rst),
      .din            (result_fifo_din),
      .wr_en          (result_fifo_wr_en),
      .rd_en          (result_fifo_rd_en),
      .dout           (result_fifo_dout),
      .full           (),
      .empty          (result_fifo_empty),
      .prog_full      (),
      .prog_empty     (),
      .stat_data_count()
  );

  // 分布式FIFO输出寄存
  always @(posedge clk) begin
    if (result_fifo_rd_en) result_head <= result_fifo_dout;
  end
  always @(posedge clk) begin
    if (rst) result_head_valid <= 1'b0;
    else if (result_fifo_rd_en) result_head_valid <= 1'b1;
    else if (result_head_take) result_head_valid <= 1'b0;
  end
  assign selected_result = is_first_fifo_beat ? result_head : result_held;
  always @(posedge clk) begin
    if (rst) begin
      is_first_fifo_beat <= 1'b1;
      result_held <= 'd0;
    end else if (fifo_read_handshake) begin
      is_first_fifo_beat <= fifo_axis_mlast;
      if (is_first_fifo_beat) result_held <= result_head;
    end
  end

  // 读侧skid
  axis_skid_buffer #(
      .DataWidth(512),
      .UsrWidth (UsrWidth + 32)
  ) axis_skid_buffer_out (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (fifo_axis_mdata),
      .axis_skeep (fifo_axis_mkeep),
      .axis_slast (fifo_axis_mlast),
      .axis_svalid(axis_mvalid_skid),
      .axis_susr  ({selected_result, fifo_axis_musr}),
      .axis_sready(axis_mready_skid),
      .axis_mdata (axis_mdata),
      .axis_mkeep (axis_mkeep),
      .axis_mlast (axis_mlast),
      .axis_mvalid(axis_mvalid),
      .axis_mready(axis_mready),
      .axis_musr  ({total_len, head_checksum, axis_musr})
  );
endmodule
`resetall
