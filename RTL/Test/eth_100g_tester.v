`resetall
`default_nettype none
`timescale 1ns / 100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : eth_100g_tester.v
// Module Name : eth_100g_tester
// Author      : LiXintao
// Date        : 2026-09-13
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 100G 以太网极限测速与误码校验模块 (发包机 + 校验机)
//               发包机构建含 Ethernet II + IPv4 头的标准包极限打流;
//               校验机逐拍比对帧头与 Payload, 统计误码与吞吐
// ============================================================================
module eth_100g_tester #(
  parameter  AXIS_WIDTH= 512,
  parameter  AXIS_USER_WIDTH= 1 ,
  parameter  PKT_LEN_BEATS= 16,   // 16 * 64 = 1024 字节/包
  parameter  ONE_SEC_CYCLES= 32'd250_000_000
) (
    // --- TX 域 (发包机) ---
  input  wire                                          clk             ,
  input  wire                                          rst             ,
  output wire          [        AXIS_WIDTH-1: 0]       axis_mdata      ,
  output wire          [      AXIS_WIDTH/8-1: 0]       axis_mkeep      ,
  output reg                                           axis_mvalid     ,
  output reg                                           axis_mlast      ,
  output wire          [   AXIS_USER_WIDTH-1: 0]       axis_muser      ,
  input  wire                                          axis_mready     ,

    // --- RX 域 (校验机) ---
  input  wire          [        AXIS_WIDTH-1: 0]       axis_sdata      ,
  input  wire          [      AXIS_WIDTH/8-1: 0]       axis_skeep      ,
  input  wire                                          axis_svalid     ,
  input  wire                                          axis_slast      ,
  input  wire          [   AXIS_USER_WIDTH-1: 0]       axis_suser      ,
  output wire                                          axis_sready     ,

    // --- 控制与状态 ---
  input  wire                                          test_enable      // 高电平启动打流
);

  // ----------------------------------------------------------------------------
  // 参数
  // ----------------------------------------------------------------------------
  // --- IPv4 协议栈帧头常数 (AXI-Stream 64-bit 小端序) ---
  localparam [                  15: 0]       IPV4_PKT_LEN= PKT_LEN_BEATS*64 - 14;
  // DST MAC (6B) + SRC MAC + Type(0x0800)
  localparam [                 111: 0]       HEADER_MAC= {16'h0008,48'h0200_0000_0002,48'h0100_0000_0002};
  // IP Ver/IHL(0x45) + IP TOS(0x00) + IP Len(0x03F2) + IP ID(0x0000) + Flags(0x4000) + TTL(0x40) + Prot(0xFF) + IP Checksum(0x0000) + SRC IP(192.168.1.2) + DST IP(192.168.1.1)
  localparam [                  15: 0]       IPV4_PKT_LEN_LE= {IPV4_PKT_LEN[7:0],IPV4_PKT_LEN[15:8]};
  localparam [                 159: 0]       HEADER_IPV4= {128'h0101_A8C0_0201_A8C0_0000_FF40_0040_0000,IPV4_PKT_LEN_LE,16'h0045};
  localparam [        AXIS_WIDTH-1: 0]       HEADER_BEAT_0= {240'h0,HEADER_IPV4,HEADER_MAC}; // 补充240bit
 
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

  reg                  [                  35: 0]       byte_cnt_acc,pkt_cnt_acc  ;
  reg                  [                  31: 0]       timer_1s           ;
  reg                                                  err_this_beat      ;
  wire                 [        AXIS_WIDTH-1: 0]       exp_data         =(rx_beat_cnt==16'd0)?HEADER_BEAT_0:{496'd0, rx_beat_cnt};

  // ============================================================================
  // 1. TX 发包机逻辑 (TX Domain)
  // ============================================================================
  assign  axis_mkeep       = {(AXIS_WIDTH / 8) {1'b1}};
  assign  axis_muser       = {AXIS_USER_WIDTH{1'b0}};
  assign  axis_mdata       = w_axis_mdata     ;// 组合逻辑直连数据线，确保时序严格对齐

  // 组合逻辑：根据当前发包节拍，动态组装包头和 Payload
  always @(*) begin
    case (tx_beat_cnt)
      16'd0:   w_axis_mdata = HEADER_BEAT_0;
      default: w_axis_mdata = {496'd0, tx_beat_cnt};                // Payload 为简单的递增节拍数
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
      axis_mvalid <= 1'b0;
      axis_mlast  <= 1'b0;
      tx_beat_cnt <= 16'd0;
    end
  end

  // ============================================================================
  // 2. RX 校验与测速逻辑 (RX Domain)
  // ============================================================================
  assign  axis_sready      = 1'b1             ;// 接收机永不反压，测试极限带宽

  always @(posedge clk) begin
    if (rst) begin
      rx_beat_cnt       <= 16'd0;
      rx_lock           <= 1'b0;
      err_this_beat <= 1'b0;
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
        if (axis_svalid && axis_sready) begin
          byte_cnt_acc <= byte_cnt_acc + 64;
          if (axis_slast) pkt_cnt_acc <= pkt_cnt_acc + 1'b1;
        end
      end

      err_this_beat <= axis_svalid && axis_sready && rx_lock && (axis_sdata != exp_data);
      if (err_this_beat) rx_error_cnt <= rx_error_cnt + 1'b1;

      // 严格的 IPv4 帧头与 Payload 误码校验逻辑
      if (axis_svalid && axis_sready) begin
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

endmodule
`resetall
