`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : subsys_100g_tester.v
// Module Name : subsys_100g_tester
// Author      : LiXintao
// Date        : 2026-10-09
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 通用单通道测试机（发包 + 逐拍校验 + 测速），用于 eth_subsys_top 的用户通道
// NOTE        :
//   1. 挂在任意"单路 AXIS 通道"上：MAC other / IPv4 icmp/ospf/other 各一路；
//      UDP 通道的多路输出由顶层静态选一路接入（每路一个实例）。
//   2. 包结构 = 第 0 拍 [HDR_BYTES 置于低 160 位, 余位填 0]，后续拍为递增拍号；
//      校验端用同一公式恢复期望值（HDR_BYTES 低字节 = 线上第一字节）。
//   3. 接收端恒不反压（测极限带宽）；rx_lock 做帧头对齐（跳过残缺帧）。
// ============================================================================
module subsys_100g_tester #(
  parameter  AXIS_WIDTH     = 512,
  parameter  PKT_LEN_BEATS  = 16,                       // 每包包长(拍)，64B 对齐
  parameter  ONE_SEC_CYCLES = 32'd400_000_000,          // 1 秒的时钟周期数
  parameter  [   159: 0]       HDR_BYTES   = 160'd0     // 第 0 拍包头(低字节=线上第一字节, 高位填0)
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,
  input  wire                                          test_enable     ,// 高电平启动打流

  // --- 发 : -> DUT ---
  output wire          [        AXIS_WIDTH-1: 0]       axis_mdata      ,
  output wire          [      AXIS_WIDTH/8-1: 0]       axis_mkeep      ,
  output reg                                           axis_mvalid     ,
  output reg                                           axis_mlast      ,
  input  wire                                          axis_mready     ,

  // --- 收 : <- DUT ---
  input  wire          [        AXIS_WIDTH-1: 0]       axis_sdata      ,
  input  wire          [      AXIS_WIDTH/8-1: 0]       axis_skeep      ,
  input  wire                                          axis_svalid     ,
  input  wire                                          axis_slast      ,
  output wire                                          axis_sready
);

  localparam [AXIS_WIDTH-1:0] HDR_BEAT = {{(AXIS_WIDTH-160){1'b0}}, HDR_BYTES};

  // ----------------------------------------------------------------------------
  // TX 发包机
  // ----------------------------------------------------------------------------
  reg                  [                  15: 0]       tx_beat_cnt        ;
  reg                  [        AXIS_WIDTH-1: 0]       w_axis_mdata       ;

  assign  axis_mkeep       = {(AXIS_WIDTH / 8) {1'b1}};
  assign  axis_mdata       = w_axis_mdata     ;

  always @(*) begin
    case (tx_beat_cnt)
      16'd0:   w_axis_mdata = HDR_BEAT;                                    // 包头拍
      default: w_axis_mdata = {{(AXIS_WIDTH-16){1'b0}}, tx_beat_cnt};      // Payload = 递增拍号
    endcase
  end

  always @(posedge clk) begin
    if (rst) begin
      axis_mvalid <= 1'b0;
      axis_mlast  <= 1'b0;
      tx_beat_cnt <= 16'd0;
    end else if (test_enable) begin
      axis_mvalid <= 1'b1;

      if (axis_mready && axis_mvalid) begin
        if (tx_beat_cnt == PKT_LEN_BEATS - 2) begin
          axis_mlast  <= 1'b1;                                            // 下一拍是包尾
          tx_beat_cnt <= tx_beat_cnt + 1'b1;
        end else if (tx_beat_cnt == PKT_LEN_BEATS - 1) begin
          axis_mlast  <= 1'b0;                                            // 一包发送完毕，重置状态
          tx_beat_cnt <= 16'd0;
        end else begin
          axis_mlast  <= 1'b0;
          tx_beat_cnt <= tx_beat_cnt + 1'b1;
        end
      end
    end else begin
      if (axis_mvalid) begin
        if (axis_mready) begin
          if (tx_beat_cnt == PKT_LEN_BEATS - 2) begin
            axis_mlast  <= 1'b1;
            tx_beat_cnt <= tx_beat_cnt + 1'b1;
          end else if (tx_beat_cnt == PKT_LEN_BEATS - 1) begin
            axis_mvalid <= 1'b0;
            axis_mlast  <= 1'b0;
            tx_beat_cnt <= 16'd0;
          end else begin
            tx_beat_cnt <= tx_beat_cnt + 1'b1;
          end
        end
      end else begin
        axis_mvalid <= 1'b0;
        axis_mlast  <= 1'b0;
        tx_beat_cnt <= 16'd0;
      end
    end
  end

  // ----------------------------------------------------------------------------
  // RX 校验与测速
  // ----------------------------------------------------------------------------
  reg                  [                  15: 0]       rx_beat_cnt        ;
  reg                                                  rx_lock            ;// 帧头对齐锁定

(* mark_debug = "true" *)   reg  [31:0]  rx_error_cnt       ;// 误码计数器
(* mark_debug = "true" *)   reg  [35:0]  rx_bw_bytes_per_s  ;// 1 秒吞吐量 (Byte/s)
(* mark_debug = "true" *)   reg  [35:0]  rx_pkt_per_s       ;// 1 秒收包数
(* mark_debug = "true" *)   reg  [31:0]  rx_len_err_cnt     ;// 包长异常包数(累计)
(* mark_debug = "true" *)   wire         debug_rx_lock      = rx_lock;

  reg                  [                  35: 0]       byte_cnt_acc       ;
  reg                  [                  35: 0]       pkt_cnt_acc        ;
  reg                  [                  31: 0]       timer_1s           ;
  reg                                                  err_this_beat      ;
  wire                 [        AXIS_WIDTH-1: 0]       exp_data           =
      (rx_beat_cnt == 16'd0) ? HDR_BEAT : {{(AXIS_WIDTH-16){1'b0}}, rx_beat_cnt};

  assign  axis_sready      = 1'b1             ;// 接收机永不反压，测试极限带宽
  wire                                                 rx_handshake     = axis_svalid && axis_sready;

  always @(posedge clk) begin
    if (rst) begin
      rx_beat_cnt       <= 16'd0;
      rx_lock           <= 1'b0;
      err_this_beat     <= 1'b0;
      rx_error_cnt      <= 32'd0;
      timer_1s          <= 32'd0;
      byte_cnt_acc      <= 36'd0;
      pkt_cnt_acc       <= 36'd0;
      rx_bw_bytes_per_s <= 36'd0;
      rx_pkt_per_s      <= 36'd0;
    end else begin
      // 测速统计
      if (timer_1s == ONE_SEC_CYCLES - 1) begin
        timer_1s          <= 32'd0;
        rx_bw_bytes_per_s <= byte_cnt_acc;
        rx_pkt_per_s      <= pkt_cnt_acc;
        byte_cnt_acc      <= 36'd0;
        pkt_cnt_acc       <= 36'd0;
      end else begin
        timer_1s <= timer_1s + 1'b1;
        if (rx_handshake) begin
          byte_cnt_acc <= byte_cnt_acc + 64;
          if (axis_slast) pkt_cnt_acc <= pkt_cnt_acc + 1'b1;
        end
      end

      err_this_beat <= rx_handshake && rx_lock && (axis_sdata != exp_data);
      if (err_this_beat) rx_error_cnt <= rx_error_cnt + 1'b1;

      // 包头与 Payload 误码校验
      if (rx_handshake) begin
        if (!rx_lock) begin
          if (axis_slast) rx_lock <= 1'b1;                                // 等前序残缺帧结束再锁定
        end

        if (axis_slast) begin
          rx_beat_cnt <= 16'd0;
        end else begin
          rx_beat_cnt <= rx_beat_cnt + 1'b1;
        end
      end
    end
  end

  // ----------------------------------------------------------------------------
  // 包长统计
  // ----------------------------------------------------------------------------
  wire                 [                  15: 0]       rx_pkt_beats     = rx_beat_cnt + 16'd1;
  wire                                                 rx_len_stat_en   = rx_handshake && axis_slast && rx_lock;

  always @(posedge clk) begin
    if (rst) begin
      rx_len_err_cnt <= 32'd0;
    end else if (rx_len_stat_en) begin
      if (rx_pkt_beats != PKT_LEN_BEATS) rx_len_err_cnt <= rx_len_err_cnt + 1'b1;
    end
  end

endmodule
`resetall
