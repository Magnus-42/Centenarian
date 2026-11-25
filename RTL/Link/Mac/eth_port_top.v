// -----------------------------------------------------------------------------
// File Name   : eth_port_top.v
// Module Name : eth_port_top
// Author      : LiXintao
// Created     : 2026-10-11
// Version     : 4.0
// -----------------------------------------------------------------------------
// Description : 100G以太网端口封装，连接CMAC、跨时钟FIFO和帧分流复用模块
// Note        : RX经SLR、CDC FIFO后剥头分流；TX经加头、仲裁、补齐、CDC FIFO和SLR后发送。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module eth_port_top #(
    parameter  integer CmacSelect          = 0,                 // 0 = cmac_a_if, 1 = cmac_b_if
    parameter  integer RxTypeCount         = 4,
    parameter  integer TxChannelCount      = 4,
    parameter  integer TxReqWidth          = 4,
    localparam integer TxUsrWidth          = TxReqWidth + 112,
    localparam integer RxUsrWidth          = 113,
    parameter  integer CdcFifoDepth        = 512,
    parameter  integer LedHalfPeriodCycles = 50_000_000
) (
    input wire init_clk,
    input wire arst,

    output wire gt_txusrclk,
    output wire gt_rxusrclk,
    output wire gt_tx_arst,
    output wire gt_rx_arst,

    output wire [3:0] gt_txp_out,
    output wire [3:0] gt_txn_out,
    input  wire [3:0] gt_rxp_in,
    input  wire [3:0] gt_rxn_in,
    input  wire       gt_ref_clk_p,
    input  wire       gt_ref_clk_n,
    output wire       qsfp_reset_n,
    output wire       qsfp_low_power_mode,
    output wire       qsfp_select_n,
    input  wire       qsfp_present_n,
    output wire       qsfp_led,

    output wire stat_link_up,  // gt_rxusrclk域链路状态，跨域使用前需同步

    input wire clk,
    input wire rst,
    input wire tx_fifo_arst, // TX跨时钟FIFO的全局异步复位

    input wire [RxTypeCount*16-1:0] cfg_type_dict,

    output wire [       512*(RxTypeCount+1)-1:0] axis_mdata,
    output wire [        64*(RxTypeCount+1)-1:0] axis_mkeep,
    output wire [                 RxTypeCount:0] axis_mlast,
    output wire [                 RxTypeCount:0] axis_mvalid,
    output wire [RxUsrWidth*(RxTypeCount+1)-1:0] axis_musr,
    input  wire [                 RxTypeCount:0] axis_mready,

    input  wire [       512*TxChannelCount-1:0] axis_sdata,
    input  wire [        64*TxChannelCount-1:0] axis_skeep,
    input  wire [           TxChannelCount-1:0] axis_slast,
    input  wire [           TxChannelCount-1:0] axis_svalid,
    input  wire [TxUsrWidth*TxChannelCount-1:0] axis_susr,
    output wire [           TxChannelCount-1:0] axis_sready
);

  // CMAC选择连接对应的GT、用户时钟与QSFP信号。
  // 接收通路依次经过SLR跨区、异步FIFO和以太网类型分流。
  // 发送通路依次经过帧仲裁、短帧补齐、异步FIFO和SLR跨区。

  // 参数范围检查
  initial begin
    if (CmacSelect != 0 && CmacSelect != 1) begin
      $display("错误：eth_port_top：CmacSelect仅支持0或1");
      $finish;
    end
    if (RxTypeCount < 1 || TxChannelCount < 1 || TxUsrWidth < 1) begin
      $display({"错误：eth_port_top：RxTypeCount、TxChannelCount、",
                "TxUsrWidth必须不小于1"});
      $finish;
    end
    if (CdcFifoDepth < 2 || (CdcFifoDepth & (CdcFifoDepth - 1)) != 0) begin
      $display("错误：eth_port_top：CdcFifoDepth必须为不小于2的2次幂");
      $finish;
    end
    if (LedHalfPeriodCycles < 0) begin
      $display("错误：eth_port_top：LedHalfPeriodCycles必须不小于0");
      $finish;
    end
  end

  // CMAC接收接口
  wire [511:0] gt_rx_cmac_data;
  wire [ 63:0] gt_rx_cmac_keep;
  wire         gt_rx_cmac_last;
  wire         gt_rx_cmac_valid;
  wire         gt_rx_cmac_usr;

  // CMAC发送接口
  wire [511:0] gt_tx_cmac_data;
  wire [ 63:0] gt_tx_cmac_keep;
  wire         gt_tx_cmac_last;
  wire         gt_tx_cmac_valid;
  wire         gt_tx_cmac_usr;
  wire         gt_tx_cmac_ready;

  // 接收SLR接口
  wire [511:0] gt_rx_slr_data;
  wire [ 63:0] gt_rx_slr_keep;
  wire         gt_rx_slr_usr;
  wire         gt_rx_slr_last;
  wire         gt_rx_slr_valid;
  wire         gt_rx_slr_ready;

  // 发送FIFO读接口
  wire [511:0] gt_tx_fifo_data;
  wire [ 63:0] gt_tx_fifo_keep;
  wire         gt_tx_fifo_last;
  wire         gt_tx_fifo_valid;
  wire         gt_tx_fifo_ready;

  // 逻辑域接收接口
  wire [511:0] rx_fifo_data;
  wire [ 63:0] rx_fifo_keep;
  wire         rx_fifo_last;
  wire         rx_fifo_valid;
  wire         rx_fifo_usr;
  wire         rx_fifo_ready;

  // 短帧补齐接口
  wire [511:0] pad_data;
  wire [ 63:0] pad_keep;
  wire         pad_last;
  wire         pad_valid;
  wire         pad_ready;

  // CMAC选择
  if (CmacSelect == 0) begin : gen_cmac_a
    cmac_a_if #(
        .LedHalfPeriodCycles(LedHalfPeriodCycles)
    ) cmac_a_if_inst (
        .init_clk           (init_clk),
        .arst               (arst),
        .gt_txp_out         (gt_txp_out),
        .gt_txn_out         (gt_txn_out),
        .gt_rxp_in          (gt_rxp_in),
        .gt_rxn_in          (gt_rxn_in),
        .gt_ref_clk_p       (gt_ref_clk_p),
        .gt_ref_clk_n       (gt_ref_clk_n),
        .gt_txusrclk        (gt_txusrclk),
        .gt_rxusrclk        (gt_rxusrclk),
        .axis_mvalid        (gt_rx_cmac_valid),
        .axis_mdata         (gt_rx_cmac_data),
        .axis_mlast         (gt_rx_cmac_last),
        .axis_mkeep         (gt_rx_cmac_keep),
        .axis_musr          (gt_rx_cmac_usr),
        .axis_svalid        (gt_tx_cmac_valid),
        .axis_sdata         (gt_tx_cmac_data),
        .axis_slast         (gt_tx_cmac_last),
        .axis_skeep         (gt_tx_cmac_keep),
        .axis_susr          (gt_tx_cmac_usr),
        .axis_sready        (gt_tx_cmac_ready),
        .gt_tx_arst         (gt_tx_arst),
        .gt_rx_arst         (gt_rx_arst),
        .qsfp_reset_n       (qsfp_reset_n),
        .qsfp_low_power_mode(qsfp_low_power_mode),
        .qsfp_select_n      (qsfp_select_n),
        .qsfp_present_n     (qsfp_present_n),
        .qsfp_led           (qsfp_led),
        .stat_link_up       (stat_link_up)
    );
  end else begin : gen_cmac_b
    cmac_b_if #(
        .LedHalfPeriodCycles(LedHalfPeriodCycles / 2)
    ) cmac_b_if_inst (
        .init_clk           (init_clk),
        .arst               (arst),
        .gt_txp_out         (gt_txp_out),
        .gt_txn_out         (gt_txn_out),
        .gt_rxp_in          (gt_rxp_in),
        .gt_rxn_in          (gt_rxn_in),
        .gt_ref_clk_p       (gt_ref_clk_p),
        .gt_ref_clk_n       (gt_ref_clk_n),
        .gt_txusrclk        (gt_txusrclk),
        .gt_rxusrclk        (gt_rxusrclk),
        .axis_mvalid        (gt_rx_cmac_valid),
        .axis_mdata         (gt_rx_cmac_data),
        .axis_mlast         (gt_rx_cmac_last),
        .axis_mkeep         (gt_rx_cmac_keep),
        .axis_musr          (gt_rx_cmac_usr),
        .axis_svalid        (gt_tx_cmac_valid),
        .axis_sdata         (gt_tx_cmac_data),
        .axis_slast         (gt_tx_cmac_last),
        .axis_skeep         (gt_tx_cmac_keep),
        .axis_susr          (gt_tx_cmac_usr),
        .axis_sready        (gt_tx_cmac_ready),
        .gt_tx_arst         (gt_tx_arst),
        .gt_rx_arst         (gt_rx_arst),
        .qsfp_reset_n       (qsfp_reset_n),
        .qsfp_low_power_mode(qsfp_low_power_mode),
        .qsfp_select_n      (qsfp_select_n),
        .qsfp_present_n     (qsfp_present_n),
        .qsfp_led           (qsfp_led),
        .stat_link_up       (stat_link_up)
    );
  end

  // 接收通路
  // CMAC接收不支持背压，后级需及时排空缓存。
  //// gt_rxusrclk域SLR跨区
  axis_slr_crossing axis_slr_crossing_rx (
      .aclk         (gt_rxusrclk),
      .aresetn      (~gt_rx_arst),
      .s_axis_tvalid(gt_rx_cmac_valid),
      .s_axis_tready(),
      .s_axis_tdata (gt_rx_cmac_data),
      .s_axis_tkeep (gt_rx_cmac_keep),
      .s_axis_tlast (gt_rx_cmac_last),
      .s_axis_tuser (gt_rx_cmac_usr),
      .m_axis_tvalid(gt_rx_slr_valid),
      .m_axis_tready(gt_rx_slr_ready),
      .m_axis_tdata (gt_rx_slr_data),
      .m_axis_tkeep (gt_rx_slr_keep),
      .m_axis_tlast (gt_rx_slr_last),
      .m_axis_tuser (gt_rx_slr_usr)
  );
  //// 异步FIFO
  axis_fifo_async #(
      .Depth          (CdcFifoDepth),
      .DataWidth      (512),
      .UsrWidth       (1),
      .PacketFifo     (0),
      .DataMemoryType ("block"),
      .UsrMemoryType  ("distributed"),
      .ProgEmptyThresh(0),
      .ProgFullThresh (0),
      .DeadlockRisk   (0)
  ) axis_fifo_async_rx (
      .wr_clk            (gt_rxusrclk),
      .rd_clk            (clk),
      .arst              (gt_rx_arst),
      .axis_sdata        (gt_rx_slr_data),
      .axis_skeep        (gt_rx_slr_keep),
      .axis_susr         (gt_rx_slr_usr),
      .axis_svalid       (gt_rx_slr_valid),
      .axis_slast        (gt_rx_slr_last),
      .axis_sready       (gt_rx_slr_ready),
      .axis_mdata        (rx_fifo_data),
      .axis_mkeep        (rx_fifo_keep),
      .axis_musr         (rx_fifo_usr),
      .axis_mvalid       (rx_fifo_valid),
      .axis_mlast        (rx_fifo_last),
      .axis_mready       (rx_fifo_ready),
      .stat_rd_prog_empty(),
      .stat_wr_prog_full (),
      .stat_rd_empty     (),
      .stat_wr_full      (),
      .stat_wr_data_count(),
      .stat_rd_data_count()
  );
  //// 逻辑域类型分流
  eth_rx #(
      .RxTypeCount(RxTypeCount)
  ) eth_rx_inst (
      .clk          (clk),
      .rst          (rst),
      .cfg_type_dict(cfg_type_dict),
      .axis_sdata   (rx_fifo_data),
      .axis_skeep   (rx_fifo_keep),
      .axis_slast   (rx_fifo_last),
      .axis_svalid  (rx_fifo_valid),
      .axis_susr    (rx_fifo_usr),
      .axis_sready  (rx_fifo_ready),
      .axis_mdata   (axis_mdata),
      .axis_mkeep   (axis_mkeep),
      .axis_mlast   (axis_mlast),
      .axis_mvalid  (axis_mvalid),
      .axis_musr    (axis_musr),
      .axis_mready  (axis_mready)
  );

  // 发送通路
  //// 加MAC头。
  eth_tx #(
      .TxChannelCount(TxChannelCount),
      .TxReqWidth    (TxReqWidth)
  ) eth_tx_inst (
      .clk        (clk),
      .rst        (rst),
      .axis_sdata (axis_sdata),
      .axis_skeep (axis_skeep),
      .axis_susr  (axis_susr),
      .axis_svalid(axis_svalid),
      .axis_slast (axis_slast),
      .axis_sready(axis_sready),
      .axis_mdata (pad_data),
      .axis_mkeep (pad_keep),
      .axis_mvalid(pad_valid),
      .axis_mlast (pad_last),
      .axis_mready(pad_ready)
  );
  //// 异步FIFO
  axis_fifo_async #(
      .Depth          (CdcFifoDepth),
      .DataWidth      (512),
      .UsrWidth       (1),
      .PacketFifo     (0),
      .DataMemoryType ("block"),
      .UsrMemoryType  ("distributed"),
      .ProgEmptyThresh(0),
      .ProgFullThresh (0),
      .DeadlockRisk   (0)
  ) axis_fifo_async_tx (
      .wr_clk            (clk),
      .rd_clk            (gt_txusrclk),
      .arst              (tx_fifo_arst),
      .axis_sdata        (pad_data),
      .axis_skeep        (pad_keep),
      .axis_susr         (1'b0),
      .axis_svalid       (pad_valid),
      .axis_slast        (pad_last),
      .axis_sready       (pad_ready),
      .axis_mdata        (gt_tx_fifo_data),
      .axis_mkeep        (gt_tx_fifo_keep),
      .axis_musr         (),
      .axis_mvalid       (gt_tx_fifo_valid),
      .axis_mlast        (gt_tx_fifo_last),
      .axis_mready       (gt_tx_fifo_ready),
      .stat_rd_prog_empty(),
      .stat_wr_prog_full (),
      .stat_rd_empty     (),
      .stat_wr_full      (),
      .stat_wr_data_count(),
      .stat_rd_data_count()
  );
  //// gt_txusrclk域SLR跨区
  axis_slr_crossing axis_slr_crossing_tx (
      .aclk         (gt_txusrclk),
      .aresetn      (~gt_tx_arst),
      .s_axis_tvalid(gt_tx_fifo_valid),
      .s_axis_tready(gt_tx_fifo_ready),
      .s_axis_tdata (gt_tx_fifo_data),
      .s_axis_tkeep (gt_tx_fifo_keep),
      .s_axis_tlast (gt_tx_fifo_last),
      .s_axis_tuser (1'b0),
      .m_axis_tvalid(gt_tx_cmac_valid),
      .m_axis_tready(gt_tx_cmac_ready),
      .m_axis_tdata (gt_tx_cmac_data),
      .m_axis_tkeep (gt_tx_cmac_keep),
      .m_axis_tlast (gt_tx_cmac_last),
      .m_axis_tuser (gt_tx_cmac_usr)
  );

endmodule
`resetall
