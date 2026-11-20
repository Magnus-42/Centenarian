// -----------------------------------------------------------------------------
// File Name   : axis_fifo_async.v
// Module Name : axis_fifo_async
// Author      : LiXintao
// Created     : 2026-11-09
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 异步AXIS FIFO，支持包模式和非包模式。
// Note        : Depth必须为2的2次幂；arst同时复位读写两域
//               axis_s*属于wr_clk域，axis_m*属于rd_clk域
//               包模式下DeadlockRisk=1严格等待完整包，Depth需容纳最大包
//               DeadlockRisk=0允许接近满时提前交付，并持续到该包结束
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module axis_fifo_async #(
    parameter  integer Depth           = 512,
    parameter  integer DataWidth       = 512,
    parameter  integer UsrWidth        = 1,
    parameter  integer PacketFifo      = 1,
    parameter          DataMemoryType  = "block",           // distributed/block，data和keep
    parameter          UsrMemoryType   = "distributed",     // distributed/block，usr
    parameter  integer ProgEmptyThresh = Depth / 4,
    parameter  integer ProgFullThresh  = Depth / 2,
    parameter  integer DeadlockRisk    = 0,
    localparam integer KeepWidth       = DataWidth / 8,
    localparam integer CountWidth      = $clog2(Depth) + 1
) (
    input wire wr_clk,
    input wire rd_clk,
    input wire arst,

    input  wire [DataWidth-1:0] axis_sdata,
    input  wire [KeepWidth-1:0] axis_skeep,
    input  wire [ UsrWidth-1:0] axis_susr,
    input  wire                 axis_svalid,
    input  wire                 axis_slast,
    output wire                 axis_sready,

    output wire [DataWidth-1:0] axis_mdata,
    output wire [KeepWidth-1:0] axis_mkeep,
    output wire [ UsrWidth-1:0] axis_musr,
    output wire                 axis_mvalid,
    output wire                 axis_mlast,
    input  wire                 axis_mready,

    output wire                  stat_rd_prog_empty,
    output wire                  stat_wr_prog_full,
    output wire                  stat_rd_empty,
    output wire                  stat_wr_full,
    output wire [CountWidth-1:0] stat_wr_data_count,
    output wire [CountWidth-1:0] stat_rd_data_count
);

  // 写域将data与keep、usr、last分别写入异步FIFO。
  // 完整包计数经Gray码同步到读域，控制包输出与提前释放。
  // 读域预取last并对齐各路数据，满空及AXIS接口按所属时钟域生成。

  // 参数范围检查
  initial begin
    if (Depth < 2 || (Depth & (Depth - 1)) != 0 || DataWidth < 8 || DataWidth % 8 != 0 ||
        UsrWidth < 1) begin
      $display({"错误：axis_fifo_async：Depth必须为不小于2的2次幂，",
                "DataWidth必须为8的正整数倍，UsrWidth必须不小于1"});
      $finish;
    end
    if ((DataMemoryType != "distributed" && DataMemoryType != "block") ||
        (UsrMemoryType != "distributed" && UsrMemoryType != "block")) begin
      $display({"错误：axis_fifo_async：DataMemoryType和UsrMemoryType",
                "仅支持distributed或block"});
      $finish;
    end
    if ((PacketFifo != 0 && PacketFifo != 1) || (DeadlockRisk != 0 && DeadlockRisk != 1)) begin
      $display("错误：axis_fifo_async：PacketFifo和DeadlockRisk仅支持0或1");
      $finish;
    end
    if (ProgEmptyThresh < 0 || ProgEmptyThresh > Depth || ProgFullThresh < 0 ||
        ProgFullThresh > Depth) begin
      $display("错误：axis_fifo_async：阈值必须位于0到Depth范围内");
      $finish;
    end
  end

  // 内部常量
  localparam integer DataKeepWidth = DataWidth + KeepWidth;
  localparam integer PacketOffsetWidth = $clog2(Depth);
  localparam integer PacketCounterWidth = $clog2(Depth) + 2;
  localparam integer EarlyReleaseThresh = (Depth > 4) ? Depth - 4 : Depth;

  // 数据与usr FIFO接口
  wire [     DataKeepWidth-1:0] rd_data_keep_fifo;
  wire [          UsrWidth-1:0] rd_usr_fifo;
  wire                          wr_data_keep_full;
  wire                          rd_data_keep_empty;
  wire                          wr_usr_full;
  wire                          rd_usr_empty;

  // last FIFO与输出寄存
  wire                          rd_last_fifo;
  wire                          rd_last_fifo_rd_en;
  reg                           rd_last_output;
  reg                           rd_last_output_valid;
  wire                          wr_last_full;
  wire                          rd_last_empty;

  // 分域复位
  wire                          wr_arst;
  wire                          rd_arst;

  // AXIS握手
  wire                          rd_fifo_rd_en;
  wire                          wr_handshake;
  wire                          rd_handshake;

  // 包计数与读取控制
  reg  [PacketCounterWidth-1:0] wr_packet_bin;
  reg  [PacketCounterWidth-1:0] wr_packet_gray;
  reg  [PacketCounterWidth-1:0] rd_packet_bin;
  wire [PacketCounterWidth-1:0] rd_wr_packet_bin_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  reg  [PacketCounterWidth-1:0] rd_wr_packet_gray_sync_d1;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  reg  [PacketCounterWidth-1:0] rd_wr_packet_gray_sync_d2;
  reg                           rd_packet_active;
  wire [PacketCounterWidth-1:0] wr_packet_bin_plus_one;
  wire [                   1:0] rd_packet_wrap_plus_one;
  wire                          rd_wr_packet_offset_greater;
  wire                          rd_packet_same_wrap;
  wire                          rd_wr_packet_wrap_ahead;
  wire                          rd_packet_available;
  reg                           rd_early_release_active;
  wire                          rd_allow_read;

  // 异步复位同步释放
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)reg  [                   1:0] wr_rst_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)reg  [                   1:0] rd_rst_sync;

  // 生成循环
  genvar g_gray;

  // 复位
  always @(posedge wr_clk or posedge arst) begin
    if (arst) wr_rst_sync <= 2'b11;
    else wr_rst_sync <= {wr_rst_sync[0], 1'b0};
  end
  always @(posedge rd_clk or posedge arst) begin
    if (arst) rd_rst_sync <= 2'b11;
    else rd_rst_sync <= {rd_rst_sync[0], 1'b0};
  end
  assign wr_arst                = wr_rst_sync[1];
  assign rd_arst                = rd_rst_sync[1];

  // AXIS握手
  assign wr_handshake           = axis_svalid && axis_sready;
  assign rd_handshake           = axis_mvalid && axis_mready;

  // 包计数及同步
  //// 完整包计数
  assign wr_packet_bin_plus_one = wr_packet_bin + 1'b1;
  always @(posedge wr_clk or posedge wr_arst) begin
    if (wr_arst) begin
      wr_packet_bin  <= 'd0;
      wr_packet_gray <= 'd0;
    end else if (wr_handshake && axis_slast) begin
      wr_packet_bin  <= wr_packet_bin_plus_one;
      wr_packet_gray <= (wr_packet_bin_plus_one >> 1) ^ wr_packet_bin_plus_one;
    end
  end
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) begin
      rd_packet_bin <= 'd0;
    end else if (rd_handshake) begin
      rd_packet_bin <= rd_last_output ? (rd_packet_bin + 1'b1) : rd_packet_bin;
    end
  end
  //// 完整包计数同步
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) begin
      rd_wr_packet_gray_sync_d1 <= 'd0;
      rd_wr_packet_gray_sync_d2 <= 'd0;
    end else begin
      rd_wr_packet_gray_sync_d1 <= wr_packet_gray;
      rd_wr_packet_gray_sync_d2 <= rd_wr_packet_gray_sync_d1;
    end
  end
  //// 完整包计数Gray转二进制
  assign rd_wr_packet_bin_sync[PacketCounterWidth-1] =
    rd_wr_packet_gray_sync_d2[PacketCounterWidth-1];
  for (g_gray = 0; g_gray < PacketCounterWidth - 1; g_gray = g_gray + 1) begin : gen_gray_decode
    assign rd_wr_packet_bin_sync[g_gray] = ^rd_wr_packet_gray_sync_d2[PacketCounterWidth-1:g_gray];
  end

  // 包模式
  assign rd_allow_read = (PacketFifo == 0) || rd_packet_available || rd_packet_active ||
      rd_early_release_active;
  //// 包检测
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) begin
      rd_packet_active <= 1'b0;
    end else if (rd_handshake) begin
      rd_packet_active <= (PacketFifo != 0) && !rd_last_output;
    end
  end
  //// 防死锁
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) rd_early_release_active <= 1'b0;
    else begin
      rd_early_release_active <= (DeadlockRisk == 0) && (
          stat_rd_data_count >= (rd_handshake ? (EarlyReleaseThresh + 1) : EarlyReleaseThresh));
    end
  end
  //// 存在包可读
  assign rd_wr_packet_offset_greater = rd_wr_packet_bin_sync[PacketOffsetWidth-1:0] >
      rd_packet_bin[PacketOffsetWidth-1:0];
  assign rd_packet_wrap_plus_one = rd_packet_bin[PacketCounterWidth-1:PacketOffsetWidth] + 2'd1;
  assign rd_packet_same_wrap = rd_wr_packet_bin_sync[PacketCounterWidth-1:PacketOffsetWidth] ==
      rd_packet_bin[PacketCounterWidth-1:PacketOffsetWidth];
  assign rd_wr_packet_wrap_ahead = rd_wr_packet_bin_sync[PacketCounterWidth-1:PacketOffsetWidth] ==
      rd_packet_wrap_plus_one;
  assign rd_packet_available = (rd_packet_same_wrap && rd_wr_packet_offset_greater) ||
      (rd_wr_packet_wrap_ahead && !rd_wr_packet_offset_greater);

  // 底层FIFO
  assign rd_fifo_rd_en = rd_handshake;
  //// data和keep合并存储
  if (DataMemoryType == "block") begin : gen_data_block
    fifo_async_fwft #(
        .Depth          (Depth),
        .Width          (DataKeepWidth),
        .ProgEmptyThresh(ProgEmptyThresh),
        .ProgFullThresh (ProgFullThresh)
    ) fifo_async_fwft_data_keep (
        .wr_clk            (wr_clk),
        .rd_clk            (rd_clk),
        .wr_arst           (wr_arst),
        .rd_arst           (rd_arst),
        .wr_en             (wr_handshake),
        .din               ({axis_skeep, axis_sdata}),
        .rd_en             (rd_fifo_rd_en),
        .dout              (rd_data_keep_fifo),
        .full              (wr_data_keep_full),
        .empty             (rd_data_keep_empty),
        .prog_full         (stat_wr_prog_full),
        .prog_empty        (stat_rd_prog_empty),
        .stat_wr_data_count(stat_wr_data_count),
        .stat_rd_data_count(stat_rd_data_count)
    );
  end else begin : gen_data_distributed
    fifo_async #(
        .Depth          (Depth),
        .Width          (DataKeepWidth),
        .MemoryType     ("distributed"),
        .ProgEmptyThresh(ProgEmptyThresh),
        .ProgFullThresh (ProgFullThresh)
    ) fifo_async_data_keep (
        .wr_clk            (wr_clk),
        .rd_clk            (rd_clk),
        .wr_arst           (wr_arst),
        .rd_arst           (rd_arst),
        .wr_en             (wr_handshake),
        .din               ({axis_skeep, axis_sdata}),
        .rd_en             (rd_fifo_rd_en),
        .dout              (rd_data_keep_fifo),
        .full              (wr_data_keep_full),
        .empty             (rd_data_keep_empty),
        .prog_full         (stat_wr_prog_full),
        .prog_empty        (stat_rd_prog_empty),
        .stat_wr_data_count(stat_wr_data_count),
        .stat_rd_data_count(stat_rd_data_count)
    );
  end
  //// usr存储
  if (UsrMemoryType == "block") begin : gen_usr_block
    fifo_async_fwft #(
        .Depth(Depth),
        .Width(UsrWidth)
    ) fifo_async_fwft_usr (
        .wr_clk            (wr_clk),
        .rd_clk            (rd_clk),
        .wr_arst           (wr_arst),
        .rd_arst           (rd_arst),
        .wr_en             (wr_handshake),
        .din               (axis_susr),
        .rd_en             (rd_fifo_rd_en),
        .dout              (rd_usr_fifo),
        .full              (wr_usr_full),
        .empty             (rd_usr_empty),
        .prog_full         (),
        .prog_empty        (),
        .stat_wr_data_count(),
        .stat_rd_data_count()
    );
  end else begin : gen_usr_distributed
    fifo_async #(
        .Depth          (Depth),
        .Width          (UsrWidth),
        .MemoryType     ("distributed"),
        .ProgEmptyThresh(0),
        .ProgFullThresh (0)
    ) fifo_async_usr (
        .wr_clk            (wr_clk),
        .rd_clk            (rd_clk),
        .wr_arst           (wr_arst),
        .rd_arst           (rd_arst),
        .wr_en             (wr_handshake),
        .din               (axis_susr),
        .rd_en             (rd_fifo_rd_en),
        .dout              (rd_usr_fifo),
        .full              (wr_usr_full),
        .empty             (rd_usr_empty),
        .prog_full         (),
        .prog_empty        (),
        .stat_wr_data_count(),
        .stat_rd_data_count()
    );
  end
  //// last
  ////// 分布式输出寄存器化
  assign rd_last_fifo_rd_en = !rd_arst && !rd_last_empty && (!rd_last_output_valid || rd_handshake);
  always @(posedge rd_clk) begin
    if (rd_last_fifo_rd_en) rd_last_output <= rd_last_fifo;
  end
  always @(posedge rd_clk or posedge rd_arst) begin
    if (rd_arst) rd_last_output_valid <= 1'b0;
    else if (rd_last_fifo_rd_en) rd_last_output_valid <= 1'b1;
    else if (rd_handshake) rd_last_output_valid <= 1'b0;
  end
  ////// last固定使用分布式FIFO
  fifo_async #(
      .Depth          (Depth),
      .Width          (1),
      .MemoryType     ("distributed"),
      .ProgEmptyThresh(0),
      .ProgFullThresh (0)
  ) fifo_async_last (
      .wr_clk            (wr_clk),
      .rd_clk            (rd_clk),
      .wr_arst           (wr_arst),
      .rd_arst           (rd_arst),
      .wr_en             (wr_handshake),
      .din               (axis_slast),
      .rd_en             (rd_last_fifo_rd_en),
      .dout              (rd_last_fifo),
      .full              (wr_last_full),
      .empty             (rd_last_empty),
      .prog_full         (),
      .prog_empty        (),
      .stat_wr_data_count(),
      .stat_rd_data_count()
  );

  // 输出
  //// 状态信号
  assign stat_wr_full             = wr_data_keep_full || wr_usr_full || wr_last_full;
  assign stat_rd_empty            = !rd_last_output_valid || rd_data_keep_empty || rd_usr_empty;

  //// AXIS接口
  assign axis_sready              = !wr_arst && !stat_wr_full;
  assign axis_mvalid              = !rd_arst && !stat_rd_empty && rd_allow_read;
  assign {axis_mkeep, axis_mdata} = rd_data_keep_fifo;
  assign axis_musr                = rd_usr_fifo;
  assign axis_mlast               = rd_last_output;

endmodule
`resetall
