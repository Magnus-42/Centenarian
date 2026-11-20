// -----------------------------------------------------------------------------
// File Name   : axis_fifo_sync.v
// Module Name : axis_fifo_sync
// Author      : LiXintao
// Created     : 2026-11-09
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 同步AXIS FIFO，支持包模式和非包模式。
// Note        : 含block配置时Depth必须不小于5；全分布式配置Depth必须不小于2
//               包模式下DeadlockRisk=1严格等待完整包，Depth需容纳最大包
//               DeadlockRisk=0允许接近满时提前交付，并持续到该包结束
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module axis_fifo_sync #(
    parameter integer Depth = 32,
    parameter integer DataWidth = 64,
    parameter integer UsrWidth = 100,
    parameter integer PacketFifo = 1,
    parameter DataMemoryType = "distributed",  // distributed/block，data和keep
    parameter UsrMemoryType = "distributed",  // distributed/block，usr
    parameter integer ProgEmptyThresh = Depth / 4,
    parameter integer ProgFullThresh = Depth / 2,
    parameter integer DeadlockRisk = 0,
    localparam integer KeepWidth = DataWidth / 8,
    localparam integer CountWidth = $clog2(Depth) + 1
) (
    input wire clk,
    input wire rst,

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

    output wire                  stat_prog_empty,
    output wire                  stat_prog_full,
    output wire                  stat_empty,
    output wire                  stat_full,
    output wire [CountWidth-1:0] stat_data_count
);

  // data与keep、usr、last分别存储，使用同一AXIS握手保持对齐。
  // last预取到输出寄存器，包计数控制完整包与提前释放。

  // 参数范围检查
  initial begin
    if (Depth < 2 || DataWidth < 8 || DataWidth % 8 != 0 || UsrWidth < 1) begin
      $display({"错误：axis_fifo_sync：Depth必须不小于2，",
                "DataWidth必须为8的正整数倍，UsrWidth必须不小于1"});
      $finish;
    end
    if ((DataMemoryType != "distributed" && DataMemoryType != "block") ||
        (UsrMemoryType != "distributed" && UsrMemoryType != "block")) begin
      $display({"错误：axis_fifo_sync：DataMemoryType和UsrMemoryType",
                "仅支持distributed或block"});
      $finish;
    end
    if ((DataMemoryType == "block" || UsrMemoryType == "block") && Depth < 5) begin
      $display("错误：axis_fifo_sync：使用block存储时Depth必须不小于5");
      $finish;
    end
    if ((PacketFifo != 0 && PacketFifo != 1) || (DeadlockRisk != 0 && DeadlockRisk != 1)) begin
      $display("错误：axis_fifo_sync：PacketFifo和DeadlockRisk仅支持0或1");
      $finish;
    end
    if (ProgEmptyThresh < 0 || ProgEmptyThresh > Depth || ProgFullThresh < 0 ||
        ProgFullThresh > Depth) begin
      $display("错误：axis_fifo_sync：阈值必须位于0到Depth范围内");
      $finish;
    end
  end

  // 内部常量
  localparam integer DataKeepWidth = DataWidth + KeepWidth;
  localparam integer EarlyReleaseThresh = (Depth > 4) ? Depth - 4 : Depth;

  // 数据与usr FIFO接口
  wire [DataKeepWidth-1:0] data_keep_fifo;
  wire [     UsrWidth-1:0] usr_fifo;
  wire                     data_keep_full;
  wire                     data_keep_empty;
  wire                     usr_full;
  wire                     usr_empty;

  // last FIFO与输出寄存
  wire                     last_fifo;
  wire                     last_fifo_rd_en;
  reg                      last_output;
  reg                      last_output_valid;
  wire                     last_full;
  wire                     last_empty;

  // AXIS握手
  wire                     fifo_rd_en;
  wire                     s_handshake;
  wire                     m_handshake;

  // 占用与阈值状态
  reg  [   CountWidth-1:0] data_count;
  reg                      prog_full_reg;
  reg                      prog_empty_reg;

  // 包计数与读取控制
  reg  [   CountWidth-1:0] packet_count;
  reg                      packet_active;
  wire                     s_packet_end;
  wire                     m_packet_end;
  reg                      early_release_active;
  reg                      complete_packet_empty;
  wire                     allow_read;

  // AXIS握手
  assign s_handshake = axis_svalid && axis_sready;
  assign m_handshake = axis_mvalid && axis_mready;

  // 占用计数
  always @(posedge clk) begin
    if (rst) begin
      data_count     <= 'd0;
      prog_full_reg  <= {CountWidth{1'b0}} >= ProgFullThresh;
      prog_empty_reg <= {CountWidth{1'b0}} <= ProgEmptyThresh;
    end else begin
      case ({
        s_handshake, m_handshake
      })
        2'b10: begin
          data_count     <= data_count + 1'b1;
          prog_full_reg  <= prog_full_reg || (data_count == (ProgFullThresh - 1));
          prog_empty_reg <= data_count < ProgEmptyThresh;
        end
        2'b01: begin
          data_count     <= data_count - 1'b1;
          prog_full_reg  <= data_count > ProgFullThresh;
          prog_empty_reg <= prog_empty_reg || (data_count == (ProgEmptyThresh + 1));
        end
        default: begin
          data_count     <= data_count;
          prog_full_reg  <= prog_full_reg;
          prog_empty_reg <= prog_empty_reg;
        end
      endcase
    end
  end

  // 包模式
  assign allow_read =
      (PacketFifo == 0) || !complete_packet_empty || packet_active || early_release_active;
  //// 包计数器
  assign s_packet_end = s_handshake && axis_slast;
  assign m_packet_end = m_handshake && last_output;
  always @(posedge clk) begin
    if (rst) begin
      packet_count <= 'd0;
    end else begin
      case ({
        s_packet_end, m_packet_end
      })
        2'b10: begin
          packet_count <= packet_count + 1'b1;
        end
        2'b01: begin
          packet_count <= packet_count - 1'b1;
        end
        default: begin
          packet_count <= packet_count;
        end
      endcase
    end
  end
  //// 防死锁
  always @(posedge clk) begin
    if (rst) early_release_active <= 1'b0;
    else if (DeadlockRisk != 0) early_release_active <= 1'b0;
    else begin
      case ({
        s_handshake, m_handshake
      })
        2'b10: begin
          early_release_active <= data_count >= (EarlyReleaseThresh - 1);
        end
        2'b01: begin
          early_release_active <= data_count > EarlyReleaseThresh;
        end
        default: begin
          early_release_active <= early_release_active;
        end
      endcase
    end
  end
  //// 完整包空标志
  always @(posedge clk) begin
    if (rst) complete_packet_empty <= 1'b1;
    else begin
      case ({
        s_packet_end, m_packet_end
      })
        2'b10: begin
          complete_packet_empty <= packet_count == {CountWidth{1'b1}};
        end
        2'b01: begin
          complete_packet_empty <= packet_count == 1;
        end
        default: begin
          complete_packet_empty <= complete_packet_empty;
        end
      endcase
    end
  end
  //// 包检测
  always @(posedge clk) begin
    if (rst) begin
      packet_active <= 1'b0;
    end else if (fifo_rd_en) begin
      packet_active <= (PacketFifo != 0) && !last_output;
    end
  end

  // 底层FIFO
  assign fifo_rd_en = m_handshake;
  //// data和keep合并存储
  if (DataMemoryType == "block") begin : gen_data_block
    fifo_sync_fwft #(
        .Depth(Depth),
        .Width(DataKeepWidth)
    ) fifo_sync_fwft_data_keep (
        .clk  (clk),
        .rst  (rst),
        .wr_en(s_handshake),
        .din  ({axis_skeep, axis_sdata}),
        .rd_en(fifo_rd_en),
        .dout (data_keep_fifo),
        .full (data_keep_full),
        .empty(data_keep_empty)
    );
  end else begin : gen_data_distributed
    fifo_sync #(
        .Depth          (Depth),
        .Width          (DataKeepWidth),
        .MemoryType     ("distributed"),
        .ProgEmptyThresh(0),
        .ProgFullThresh (0)
    ) fifo_sync_data_keep (
        .clk            (clk),
        .rst            (rst),
        .wr_en          (s_handshake),
        .din            ({axis_skeep, axis_sdata}),
        .rd_en          (fifo_rd_en),
        .dout           (data_keep_fifo),
        .full           (data_keep_full),
        .empty          (data_keep_empty),
        .prog_full      (),
        .prog_empty     (),
        .stat_data_count()
    );
  end
  //// usr存储
  if (UsrMemoryType == "block") begin : gen_usr_block
    fifo_sync_fwft #(
        .Depth(Depth),
        .Width(UsrWidth)
    ) fifo_sync_fwft_usr (
        .clk  (clk),
        .rst  (rst),
        .wr_en(s_handshake),
        .din  (axis_susr),
        .rd_en(fifo_rd_en),
        .dout (usr_fifo),
        .full (usr_full),
        .empty(usr_empty)
    );
  end else begin : gen_usr_distributed
    fifo_sync #(
        .Depth          (Depth),
        .Width          (UsrWidth),
        .MemoryType     ("distributed"),
        .ProgEmptyThresh(0),
        .ProgFullThresh (0)
    ) fifo_sync_usr (
        .clk            (clk),
        .rst            (rst),
        .wr_en          (s_handshake),
        .din            (axis_susr),
        .rd_en          (fifo_rd_en),
        .dout           (usr_fifo),
        .full           (usr_full),
        .empty          (usr_empty),
        .prog_full      (),
        .prog_empty     (),
        .stat_data_count()
    );
  end
  //// last
  ////// last输出寄存器
  assign last_fifo_rd_en = !rst && !last_empty && (!last_output_valid || m_handshake);
  always @(posedge clk) begin
    if (last_fifo_rd_en) last_output <= last_fifo;
  end
  always @(posedge clk) begin
    if (rst) last_output_valid <= 1'b0;
    else if (last_fifo_rd_en) last_output_valid <= 1'b1;
    else if (m_handshake) last_output_valid <= 1'b0;
  end
  ////// last固定使用分布式FIFO
  fifo_sync #(
      .Depth          (Depth),
      .Width          (1),
      .MemoryType     ("distributed"),
      .ProgEmptyThresh(0),
      .ProgFullThresh (0)
  ) fifo_sync_last (
      .clk            (clk),
      .rst            (rst),
      .wr_en          (s_handshake),
      .din            (axis_slast),
      .rd_en          (last_fifo_rd_en),
      .dout           (last_fifo),
      .full           (last_full),
      .empty          (last_empty),
      .prog_full      (),
      .prog_empty     (),
      .stat_data_count()
  );

  // 输出
  //// 状态信号
  assign stat_data_count          = data_count;
  assign stat_full                = data_keep_full || usr_full || last_full;
  assign stat_empty               = !last_output_valid || data_keep_empty || usr_empty;
  assign stat_prog_empty          = prog_empty_reg;
  assign stat_prog_full           = prog_full_reg;

  //// AXIS接口
  assign axis_mvalid              = !rst && !stat_empty && allow_read;
  assign axis_sready              = !rst && !stat_full;
  assign {axis_mkeep, axis_mdata} = data_keep_fifo;
  assign axis_musr                = usr_fifo;
  assign axis_mlast               = last_output;

endmodule
`resetall
