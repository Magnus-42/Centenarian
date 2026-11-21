// -----------------------------------------------------------------------------
// File Name   : subsys_100g_tester.v
// Module Name : subsys_100g_tester
// Author      : LiXintao
// Created     : 2026-10-09
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 单通道发包、逐拍校验和测速，用于eth_stack_top用户通道。
// Note        : 每路独立实例化；首拍低320位为HDR_BYTES，其余位补0，后续拍为递增拍号。
//               HDR_BYTES低字节先发送，最长40字节；IPv4/以太网短头自动高位补0。
//               收发按全keep整拍计数；接收恒不反压，首次收到末拍后开始校验。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module subsys_100g_tester #(
    parameter AXIS_WIDTH = 512,
    parameter PKT_LEN_BEATS = 16,
    parameter ONE_SEC_CYCLES = 32'd400_000_000,
    parameter [319:0] HDR_BYTES = 320'd0
) (
    input wire clk,
    input wire rst,
    input wire test_enable, // 撤销后完成当前包，再停止启动新包

    // 发送至协议栈
    output wire [  AXIS_WIDTH-1:0] axis_mdata,
    output wire [AXIS_WIDTH/8-1:0] axis_mkeep,
    output wire                    axis_mvalid,
    output wire                    axis_mlast,
    input  wire                    axis_mready,

    // 接收协议栈输出
    input  wire [  AXIS_WIDTH-1:0] axis_sdata,
    input  wire [AXIS_WIDTH/8-1:0] axis_skeep,
    input  wire                    axis_svalid,
    input  wire                    axis_slast,
    output wire                    axis_sready,

    input wire [15:0] cfg_gap_cycles  // 单位为clk周期
);

  // 末拍握手装载包间隔，计数归零后允许发送。
  // 使能撤销只阻止下一包，当前包继续到末拍握手。

  // 内部常量
  localparam [AXIS_WIDTH-1:0] HDR_BEAT = {{(AXIS_WIDTH - 320) {1'b0}}, HDR_BYTES};

  // 包间隔配置
  reg  [            15:0] cfg_gap_cycles_d1;
  reg                     cfg_gap_zero_d1;

  // 发送拍号与包间隔
  reg  [            15:0] tx_beat_cnt;
  wire [            15:0] tx_beat_next;
  reg  [            15:0] gap_remaining;
  wire [            15:0] gap_remaining_next;
  wire                    gap_next_is_zero;

  // 接收计数与校验
  reg  [            15:0] rx_beat_cnt;
  reg                     rx_lock;
  reg                     err_this_beat;
  wire [  AXIS_WIDTH-1:0] exp_data;

  // 测速累计
  reg  [            35:0] byte_cnt_acc;
  reg  [            35:0] pkt_cnt_acc;
  reg  [            31:0] timer_1s;

  // 调试状态
  (* mark_debug = "true" *)reg  [            31:0] rx_error_cnt;  // 错误拍累计数
  (* mark_debug = "true" *)reg  [            35:0] rx_bw_bytes_per_s;  // 窗口接收字节数
  (* mark_debug = "true" *)reg  [            35:0] rx_pkt_per_s;  // 窗口接收包数
  (* mark_debug = "true" *)reg  [            31:0] rx_len_err_cnt;  // 包长异常累计数
  (* mark_debug = "true" *)wire                    debug_rx_lock;

  // 包长检查
  wire [            15:0] rx_pkt_beats;
  wire                    rx_len_stat_en;

  // 握手
  wire                    s_handshake;
  wire                    m_handshake;
  wire                    reg_ready;

  // 发送出口寄存
  reg  [  AXIS_WIDTH-1:0] axis_mdata_reg;
  reg  [AXIS_WIDTH/8-1:0] axis_mkeep_reg;
  reg                     axis_mvalid_reg;
  reg                     axis_mlast_reg;

  // 出口装载与握手
  assign reg_ready   = !axis_mvalid_reg || axis_mready;
  assign m_handshake = axis_mvalid && axis_mready;

  // 包间隔配置
  always @(posedge clk) begin
    cfg_gap_cycles_d1 <= cfg_gap_cycles;
    cfg_gap_zero_d1   <= cfg_gap_cycles == 16'd0;
  end

  // 包间隔
  assign gap_remaining_next = (m_handshake && axis_mlast_reg) ?
      cfg_gap_cycles_d1 : ((gap_remaining != 16'd0) ? gap_remaining - 16'd1 : 16'd0);
  assign gap_next_is_zero = (m_handshake && axis_mlast_reg) ?
      cfg_gap_zero_d1 : (gap_remaining <= 16'd1);
  always @(posedge clk) begin
    if (rst) gap_remaining <= cfg_gap_cycles;
    else gap_remaining <= gap_remaining_next;
  end

  // 发送拍计数
  assign tx_beat_next = m_handshake ? (axis_mlast_reg ? 16'd0 : tx_beat_cnt + 16'd1) : tx_beat_cnt;
  always @(posedge clk) begin
    if (rst) begin
      tx_beat_cnt <= 16'd0;
    end else begin
      if (m_handshake) tx_beat_cnt <= tx_beat_next;
    end
  end

  // 发送出口寄存
  //// 数据与keep：出口为空或当前拍被消费时装载，背压时保持。
  always @(posedge clk) begin
    if (reg_ready) begin
      if (tx_beat_next == 'd0) axis_mdata_reg <= HDR_BEAT;
      else axis_mdata_reg <= {{(AXIS_WIDTH - 16) {1'b0}}, tx_beat_next};
      axis_mkeep_reg <= {(AXIS_WIDTH / 8) {1'b1}};
      axis_mlast_reg <= tx_beat_next == (PKT_LEN_BEATS - 1);
    end
  end
  //// 有效位：间隔结束后启动，撤销使能时等当前末拍握手。
  always @(posedge clk) begin
    if (rst) begin
      axis_mvalid_reg <= 'd0;
    end else begin
      if (test_enable) begin
        if (gap_next_is_zero) axis_mvalid_reg <= 1'b1;
        else if (m_handshake) axis_mvalid_reg <= 1'b0;
      end else begin
        if (m_handshake && axis_mlast) begin
          axis_mvalid_reg <= 1'b0;
        end
      end
    end
  end

  // 发送输出
  assign axis_mvalid = axis_mvalid_reg;
  assign axis_mlast = axis_mlast_reg;
  assign axis_mkeep = axis_mkeep_reg;
  assign axis_mdata = axis_mdata_reg;

  // 接收拍计数与校验启用
  assign axis_sready = 1'b1;
  assign s_handshake = axis_svalid && axis_sready;
  assign debug_rx_lock = rx_lock;
  assign exp_data = (rx_beat_cnt == 16'd0) ? HDR_BEAT : {{(AXIS_WIDTH - 16) {1'b0}}, rx_beat_cnt};
  //// 接收拍计数
  always @(posedge clk) begin
    if (rst) rx_beat_cnt <= 16'd0;
    else begin
      if (s_handshake) begin
        if (axis_slast) rx_beat_cnt <= 16'd0;
        else rx_beat_cnt <= rx_beat_cnt + 1'b1;
      end
    end
  end
  //// 首次收到末拍后启用校验。
  always @(posedge clk) begin
    if (rst) rx_lock <= 1'b0;
    else if (s_handshake && !rx_lock && axis_slast) rx_lock <= 1'b1;
  end

  // 错误拍检测与累计
  //// 检测结果寄存一拍。
  always @(posedge clk) begin
    if (rst) begin
      err_this_beat <= 1'b0;
    end else begin
      err_this_beat <= s_handshake && rx_lock &&
        ((axis_sdata != exp_data) || (axis_skeep != {(AXIS_WIDTH / 8) {1'b1}}));
    end
  end
  //// 累计上一拍的检测结果。
  always @(posedge clk) begin
    if (rst) rx_error_cnt <= 32'd0;
    else if (err_this_beat) rx_error_cnt <= rx_error_cnt + 1'b1;
  end

  // 窗口测速
  //// 窗口计时
  always @(posedge clk) begin
    if (rst) timer_1s <= 32'd0;
    else begin
      if (timer_1s == ONE_SEC_CYCLES - 1) timer_1s <= 32'd0;
      else timer_1s <= timer_1s + 1'b1;
    end
  end
  //// 字节累计与窗口结果，结算包含本拍握手。
  always @(posedge clk) begin
    if (rst) begin
      byte_cnt_acc      <= 36'd0;
      rx_bw_bytes_per_s <= 36'd0;
    end else if (timer_1s == ONE_SEC_CYCLES - 1) begin
      byte_cnt_acc      <= 36'd0;
      rx_bw_bytes_per_s <= byte_cnt_acc + (s_handshake ? AXIS_WIDTH / 8 : 36'd0);
    end else if (s_handshake) begin
      byte_cnt_acc <= byte_cnt_acc + AXIS_WIDTH / 8;
    end
  end
  //// 包数累计与窗口结果，结算包含本拍末拍。
  always @(posedge clk) begin
    if (rst) begin
      pkt_cnt_acc  <= 36'd0;
      rx_pkt_per_s <= 36'd0;
    end else if (timer_1s == ONE_SEC_CYCLES - 1) begin
      pkt_cnt_acc  <= 36'd0;
      rx_pkt_per_s <= pkt_cnt_acc + ((s_handshake && axis_slast) ? 36'd1 : 36'd0);
    end else if (s_handshake && axis_slast) begin
      pkt_cnt_acc <= pkt_cnt_acc + 1'b1;
    end
  end

  // 包长检查
  assign rx_pkt_beats   = rx_beat_cnt + 16'd1;
  assign rx_len_stat_en = s_handshake && axis_slast && rx_lock;

  always @(posedge clk) begin
    if (rst) begin
      rx_len_err_cnt <= 32'd0;
    end else if (rx_len_stat_en) begin
      if (rx_pkt_beats != PKT_LEN_BEATS) rx_len_err_cnt <= rx_len_err_cnt + 1'b1;
    end
  end

  // ILA观测
  ila_tester u_ila_tester (
      .clk(clk),  // 业务时钟

      .probe0(rx_error_cnt),       // 错误拍累计数
      .probe1(rx_bw_bytes_per_s),  // 窗口字节数
      .probe2(rx_pkt_per_s),       // 窗口包数
      .probe3(rx_len_err_cnt),     // 包长异常累计数
      .probe4(debug_rx_lock)       // 接收校验已启用
  );

endmodule
`resetall
