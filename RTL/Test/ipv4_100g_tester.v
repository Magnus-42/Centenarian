`resetall
`default_nettype none
`timescale 1ns / 100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_100g_tester.v
// Module Name : ipv4_100g_tester
// Author      : LiXintao
// Date        : 2026-10-12
// Version     : v3.0
// ----------------------------------------------------------------------------
// Description : IPv4 链路极限测速与误码校验模块 (发包机 + 校验机)
// ============================================================================
module ipv4_100g_tester #(
  parameter  AXIS_WIDTH= 512,
  parameter  AXIS_USER_WIDTH= 1 ,
  parameter  PKT_LEN_BEATS= 16,                       // 纯 IPv4 包 = 16 * 64 = 1024 字节
  parameter  ONE_SEC_CYCLES= 32'd250_000_000,        // 1 秒的时钟周期数
  parameter  [AXIS_USER_WIDTH-1:0] AXIS_USER_VAL= 'd0,// TX usr; 过 by_val 仲裁须非 0(0=永不选中)
  parameter  [                  31: 0]       DST_IP_LE= 32'h0201_A8C0,        // 目的 IP(线序): 192.168.1.2
  parameter  [                  31: 0]       SRC_IP_LE= 32'h0101_A8C0// 源 IP  (线序): 192.168.1.1
) (
    // --- TX 域 (发包机) ---
  input  wire                                          clk             ,
  input  wire                                          rst             ,
  output wire          [        AXIS_WIDTH-1: 0]       axis_mdata      ,
  output wire          [      AXIS_WIDTH/8-1: 0]       axis_mkeep      ,
  output reg                                           axis_mvalid     ,
  output reg                                           axis_mlast      ,
  output wire          [   AXIS_USER_WIDTH-1: 0]       axis_musr       ,
  input  wire                                          axis_mready     ,

    // --- RX 域 (校验机) ---
  input  wire          [        AXIS_WIDTH-1: 0]       axis_sdata      ,
  input  wire          [      AXIS_WIDTH/8-1: 0]       axis_skeep      ,
  input  wire                                          axis_svalid     ,
  input  wire                                          axis_slast      ,
  input  wire          [   AXIS_USER_WIDTH-1: 0]       axis_susr       ,
  output wire                                          axis_sready     ,

  // --- 控制与状态 ---
  input  wire                                          test_enable      // 高电平启动打流
);

  // ----------------------------------------------------------------------------
  // 纯 IPv4 头常数 (20 字节 = 160bit, byte0 在最低位)
  //   byte0  = 0x45  Ver=4 / IHL=5
  //   byte1  = 0x00  TOS
  //   byte2-3= 总长(线序)   byte4-5 = ID(0)      byte6-7 = Flags/Frag(0x4000)
  //   byte8  = 0x40  TTL=64 byte9   = 0x11 UDP  byte10-11= 校验和(不校验, 置0)
  //   byte12-15 = 源 IP     byte16-19 = 目的 IP (ipv4_arp_service 即从这里取 query_ip)
  // ----------------------------------------------------------------------------
  localparam [                  15: 0]       IP_LEN= PKT_LEN_BEATS*64;
  localparam [                  15: 0]       IP_LEN_LE= {IP_LEN[7:0], IP_LEN[15:8]};
  localparam [                 159: 0]       HEADER_IPV4= {DST_IP_LE, SRC_IP_LE,
                                                          16'h0000, 8'h11, 8'h40,
                                                          16'h0040, 16'h0000,
                                                          IP_LEN_LE, 8'h00, 8'h45};
  localparam [        AXIS_WIDTH-1: 0]       HEADER_BEAT_0= {{(AXIS_WIDTH-160){1'b0}}, HEADER_IPV4};

  // ----------------------------------------------------------------------------
  // TX 发包机寄存器
  // ----------------------------------------------------------------------------
  reg                  [                  15: 0]       tx_beat_cnt        ;
  reg                  [        AXIS_WIDTH-1: 0]       w_axis_mdata       ;

  // ----------------------------------------------------------------------------
  // RX 校验机寄存器
  // ----------------------------------------------------------------------------
  reg                  [                  15: 0]       rx_beat_cnt        ;
  reg                                                  rx_lock            ;// 帧头对齐锁定标志

  // ILA 探针 (误码/吞吐统计)
(* mark_debug = "true" *)   reg                  [                  31: 0]       rx_error_cnt       ;// 误码计数器
(* mark_debug = "true" *)   reg                  [                  35: 0]       rx_bw_bytes_per_s  ;// 1 秒吞吐量 (Byte/s)
(* mark_debug = "true" *)   reg                  [                  35: 0]       rx_pkt_per_s       ;// 1 秒收包数
(* mark_debug = "true" *)   wire                                                 debug_rx_lock    =rx_lock;
(* mark_debug = "true" *)   reg                  [                  31: 0]       rx_len_err_cnt     ;// 包长异常包数(累计)

  reg                  [                  35: 0]       byte_cnt_acc,pkt_cnt_acc  ;
  reg                  [                  31: 0]       timer_1s           ;
  reg                                                  err_this_beat      ;
  wire                 [        AXIS_WIDTH-1: 0]       exp_data         =(rx_beat_cnt==16'd0)?HEADER_BEAT_0:{{(AXIS_WIDTH-16){1'b0}},rx_beat_cnt};

  // ============================================================================
  // TX 发包机逻辑 (TX Domain)
  // ============================================================================
  assign  axis_mkeep       = {(AXIS_WIDTH / 8) {1'b1}};
  assign  axis_musr        = AXIS_USER_VAL;
  assign  axis_mdata       = w_axis_mdata     ;

  // 组合逻辑：根据当前发包节拍，动态组装包头和 Payload
  always @(*) begin
    case (tx_beat_cnt)
      16'd0:   w_axis_mdata = HEADER_BEAT_0;
      default: w_axis_mdata = {{(AXIS_WIDTH-16){1'b0}}, tx_beat_cnt};// Payload = 递增拍号
    endcase
  end

  // 时序逻辑：仅控制握手信号与节拍计数器
  always @(posedge clk) begin
    if (rst) begin
      axis_mvalid <= 1'b0;
      axis_mlast  <= 1'b0;
      tx_beat_cnt <= 16'd0;
    end else if (test_enable) begin
      axis_mvalid <= 1'b1;

      if (axis_mready && axis_mvalid) begin
        if (tx_beat_cnt == PKT_LEN_BEATS - 2) begin
          axis_mlast  <= 1'b1;                                      // 下一拍是包尾
          tx_beat_cnt <= tx_beat_cnt + 1'b1;
        end else if (tx_beat_cnt == PKT_LEN_BEATS - 1) begin
          axis_mlast  <= 1'b0;                                      // 一包发送完毕，重置状态
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

  // ============================================================================
  // RX 校验与测速逻辑 (RX Domain)
  // ============================================================================
  assign  axis_sready      = 1'b1             ;// 接收机永不反压，测试极限带宽
  wire                                                 rx_handshake     =axis_svalid&&axis_sready;

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
      // 测速统计逻辑
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

      // 纯 IPv4 包头与 Payload 误码校验逻辑
      if (rx_handshake) begin
        if (!rx_lock) begin
          // 等待前序残缺帧结束，锁定下一个完整帧的起始位置
          if (axis_slast) rx_lock <= 1'b1;
        end

        // 接收端节拍计数器随 tlast 清零复位
        if (axis_slast) begin
          rx_beat_cnt <= 16'd0;
        end else begin
          rx_beat_cnt <= rx_beat_cnt + 1'b1;
        end
      end
    end
  end

  // ============================================================================
  // 包长统计
  // ============================================================================
  wire                 [                  15: 0]       rx_pkt_beats     =rx_beat_cnt+16'd1;
  wire                                                 rx_len_stat_en   =rx_handshake&&axis_slast&&rx_lock;

  always @(posedge clk) begin
    if (rst) begin
      rx_len_err_cnt <= 32'd0   ;
    end else if (rx_len_stat_en) begin
      if (rx_pkt_beats != PKT_LEN_BEATS)           rx_len_err_cnt <= rx_len_err_cnt + 1'b1;
    end
  end

endmodule
`resetall
