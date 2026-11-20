// -----------------------------------------------------------------------------
// File Name   : arp_pending_ctrl.v
// Module Name : arp_pending_ctrl
// Author      : LiXintao
// Created     : 2026-09-15
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : ARP待决请求控制，利用IP和时间戳抑制超时前的重复请求
// Note        : 5级流水线，每拍接收请求；连续同IP请求存在在途更新不可见窗口
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module arp_pending_ctrl #(
    parameter integer TimeWidth = 24,  // 毫秒时间戳，约4.66小时回绕
    localparam integer ItemWidth = 33 + TimeWidth,  // valid+ip+time
    parameter integer CacheDepth = 1024,
    localparam integer CacheAddrWidth = CacheDepth == 1 ? 1 : $clog2(CacheDepth),
    parameter integer HashWayCount = 4,
    parameter integer ClkFreqHz = 400000000
) (
    input wire clk,
    input wire rst,

    input wire        req_valid_pulse,
    input wire [31:0] req_ip,

    output wire permit_valid_pulse,
    output wire permit_blocked,
    output wire [31:0] permit_ip,

    input wire [TimeWidth-1:0] cfg_pending_time,
    input wire                 cfg_clear,

    output wire stat_clear_finish
);

  // p1发出读请求，p2/p3对齐待决表返回。
  // p4寄存匹配和超时结果，p5输出许可并按需写回。
  // 毫秒时基维护时间戳，清表期间屏蔽请求。

  // 参数范围检查
  initial begin
    if (CacheDepth < 2 || (CacheDepth & (CacheDepth - 1)) != 0 || HashWayCount < 1 ||
        TimeWidth < 1 || ClkFreqHz < 1000) begin
      $display(
          "错误：arp_pending_ctrl：深度须为不小于2的2次幂，路数和时间位宽须大于0");
      $display("错误：arp_pending_ctrl：ClkFreqHz须不小于1000");
      $finish;
    end
  end

  // 内部常量
  localparam integer CyclesPerMs  = ClkFreqHz / 1000;
  localparam integer MsCountWidth = CyclesPerMs <= 1 ? 1 : $clog2(CyclesPerMs);
  localparam integer RequestDelay = 4;

  // 待决配置
  reg  [                  TimeWidth-1:0] cfg_pending_time_d1;
  reg                                    cfg_clear_d1;

  // 请求流水
  reg  [               RequestDelay-1:0] req_valid_shift;
  reg  [            32*RequestDelay-1:0] req_ip_shift;
  reg  [CacheAddrWidth*RequestDelay-1:0] req_addr_shift;
  wire [                           31:0] ip_hash;

  // p4 比较结果
  reg                                    p4_has_match;
  reg                                    p4_has_empty_way;
  reg                                    p4_match_expired;
  reg  [               HashWayCount-1:0] p4_matched_way_onehot;
  reg  [               HashWayCount-1:0] p4_empty_way_onehot;

  // p5 写回接口
  reg  [               HashWayCount-1:0] p5_write_we;
  reg  [             CacheAddrWidth-1:0] p5_write_addr;
  reg  [                  ItemWidth-1:0] p5_write_din;

  // p5 许可结果
  reg                                    p5_permit_valid_pulse;
  reg                                    p5_permit_blocked;
  reg  [                           31:0] p5_permit_ip;

  // 毫秒时基
  reg  [               MsCountWidth-1:0] ms_cycle_count;
  wire                                   ms_tick;
  reg  [                  TimeWidth-1:0] timestamp_ms;

  // 清表扫描
  reg                                    clear_finish;
  reg  [             CacheAddrWidth-1:0] clear_addr;

  // 匹配与替换选择
  wire [     ItemWidth*HashWayCount-1:0] lookup_dout;
  reg  [               HashWayCount-1:0] replace_way_onehot;
  reg                                    has_match;
  reg                                    has_empty_way;
  reg                                    matched_entry_expired;
  wire [               HashWayCount-1:0] expired_way_mask;
  wire [               HashWayCount-1:0] matched_way_mask;
  wire [               HashWayCount-1:0] empty_way_mask;
  wire [               HashWayCount-1:0] matched_way_onehot;
  wire [               HashWayCount-1:0] empty_way_onehot;

  // 生成循环
  genvar g_timeout_way;
  genvar g_select;
  genvar g_way_index;

  // 毫秒计数终值
  assign ms_tick = ms_cycle_count == CyclesPerMs - 1;

  // 请求流水与配置
  //// 请求载荷与有效位延迟
  always @(posedge clk) begin
    req_ip_shift <= {req_ip_shift[32*(RequestDelay-1)-1:0], req_ip};
    req_addr_shift <= {
      req_addr_shift[CacheAddrWidth*(RequestDelay-1)-1:0], ip_hash[CacheAddrWidth-1:0]
    };
    if (rst || cfg_clear_d1 || !clear_finish) begin
      req_valid_shift <= 'd0;
    end else begin
      req_valid_shift <= {req_valid_shift[RequestDelay-2:0], req_valid_pulse};
    end
  end
  //// 寄存配置
  always @(posedge clk) begin
    cfg_pending_time_d1 <= cfg_pending_time;
  end
  always @(posedge clk) begin
    cfg_clear_d1 <= cfg_clear;
  end
  //// 毫秒时基
  always @(posedge clk) begin
    if (rst || cfg_clear_d1 || ms_tick) begin
      ms_cycle_count <= 'd0;
    end else begin
      ms_cycle_count <= ms_cycle_count + 1'b1;
    end
  end
  always @(posedge clk) begin
    if (rst || cfg_clear_d1) begin
      timestamp_ms <= 'd0;
    end else if (ms_tick) begin
      timestamp_ms <= timestamp_ms + 1'b1;
    end
  end

  // 读取
  //// 计算哈希
  crc32_d32 crc32_d32_inst (
      .crc     (32'hFFFFFFFF),
      .data    (req_ip),
      .crc_next(ip_hash)
  );

  // 比较
  //// 计算匹配
  for (
      g_timeout_way = 0; g_timeout_way < HashWayCount; g_timeout_way = g_timeout_way + 1
  ) begin : gen_timeout
    wire [TimeWidth-1:0] elapsed_ms;
    assign elapsed_ms = timestamp_ms - lookup_dout[g_timeout_way*ItemWidth+:TimeWidth];
    assign expired_way_mask[g_timeout_way] = elapsed_ms >= cfg_pending_time_d1;
  end
  for (g_select = 0; g_select < HashWayCount; g_select = g_select + 1) begin : gen_select
    assign matched_way_mask[g_select] = lookup_dout[g_select*ItemWidth+ItemWidth-1-:33] ==
        {1'b1, req_ip_shift[32*(RequestDelay-2)+:32]};
    assign empty_way_mask[g_select] = !lookup_dout[g_select*ItemWidth+ItemWidth-1];
    if (g_select == HashWayCount - 1) begin : gen_last
      assign matched_way_onehot[g_select] = matched_way_mask[g_select];
      assign empty_way_onehot[g_select]   = empty_way_mask[g_select];
    end else begin : gen_priority
      assign matched_way_onehot[g_select] = matched_way_mask[g_select] &&
          !(|matched_way_mask[HashWayCount-1:g_select+1]);
      assign empty_way_onehot[g_select] = empty_way_mask[g_select] &&
          !(|empty_way_mask[HashWayCount-1:g_select+1]);
    end
  end
  always @(*) begin
    has_match             = |matched_way_mask;
    has_empty_way         = |empty_way_mask;
    matched_entry_expired = |(matched_way_onehot & expired_way_mask);
  end
  //// 寄存比较结果
  always @(posedge clk) begin
    p4_has_match          <= has_match;
    p4_has_empty_way      <= has_empty_way;
    p4_match_expired      <= matched_entry_expired;
    p4_matched_way_onehot <= matched_way_onehot;
    p4_empty_way_onehot   <= empty_way_onehot;
  end

  // 写入
  //// 清除计算
  always @(posedge clk) begin
    if (rst || cfg_clear_d1) begin
      clear_addr <= 'd0;
    end else begin
      clear_addr <= clear_addr + 1'b1;
    end
  end
  always @(posedge clk) begin
    if (rst || cfg_clear_d1) begin
      clear_finish <= 1'b0;
    end else begin
      if (clear_addr == {CacheAddrWidth{1'b1}}) clear_finish <= 1'b1;
    end
  end
  //// 写回
  ////// 替换候选每拍轮转
  always @(posedge clk) begin
    if (rst) replace_way_onehot <= {{(HashWayCount - 1) {1'b0}}, 1'b1};
    else
      replace_way_onehot <= (replace_way_onehot << 1) | (replace_way_onehot >> (HashWayCount - 1));
  end
  ////// 写入地址使能数据
  always @(posedge clk) begin
    if (rst) begin
      p5_write_we <= 'd0;
    end else begin
      if (!clear_finish) p5_write_we <= {HashWayCount{1'b1}};
      else if (cfg_clear_d1 || !req_valid_shift[RequestDelay-1]) p5_write_we <= 'd0;
      else if (p4_has_match) begin
        if (p4_match_expired) p5_write_we <= p4_matched_way_onehot;
        else p5_write_we <= 'd0;
      end else if (p4_has_empty_way) p5_write_we <= p4_empty_way_onehot;
      else p5_write_we <= replace_way_onehot;
    end
  end
  always @(posedge clk) begin
    if (req_valid_shift[RequestDelay-1] && clear_finish && !cfg_clear_d1 && !rst) begin
      p5_write_addr <= req_addr_shift[CacheAddrWidth*(RequestDelay-1)+:CacheAddrWidth];
      p5_write_din  <= {1'b1, req_ip_shift[32*(RequestDelay-1)+:32], timestamp_ms};
    end else begin
      p5_write_addr <= clear_addr;
      p5_write_din  <= 'd0;
    end
  end

  // 输出
  always @(posedge clk) begin
    if (rst) begin
      p5_permit_blocked <= 1'b0;
    end else begin
      if (req_valid_shift[RequestDelay-1] && clear_finish && !cfg_clear_d1) begin
        p5_permit_blocked <= p4_has_match && !p4_match_expired;
      end
    end
  end
  always @(posedge clk) begin
    if (rst) begin
      p5_permit_valid_pulse <= 1'b0;
    end else begin
      p5_permit_valid_pulse <= req_valid_shift[RequestDelay-1] && clear_finish && !cfg_clear_d1;
    end
  end
  always @(posedge clk) begin
    if (req_valid_shift[RequestDelay-1] && clear_finish && !cfg_clear_d1 && !rst) begin
      p5_permit_ip <= req_ip_shift[32*(RequestDelay-1)+:32];
    end
  end

  for (g_way_index = 0; g_way_index < HashWayCount; g_way_index = g_way_index + 1) begin : gen_way
    (* dont_touch = "true" *) reg p1_lookup_re;
    (* dont_touch = "true" *) reg [CacheAddrWidth-1:0] p1_lookup_addr;
    always @(posedge clk) begin
      if (rst || cfg_clear_d1 || !clear_finish) p1_lookup_re <= 1'b0;
      else p1_lookup_re <= req_valid_pulse;
      if (req_valid_pulse) p1_lookup_addr <= ip_hash[CacheAddrWidth-1:0];
    end
    sdp_bram #(
        .DataWidth  (ItemWidth),
        .Depth      (CacheDepth),
        .DoReg      (1),
        .InitEn     (1),
        .InitUseFile(0),
        .BypassEn   (1)
    ) sdp_bram_inst (
        .clk(clk),
        .rst(rst),

        .a_we  (p5_write_we[g_way_index]),
        .a_addr(p5_write_addr),
        .a_din (p5_write_din),

        .b_re  (p1_lookup_re),
        .b_addr(p1_lookup_addr),
        .b_dout(lookup_dout[g_way_index*ItemWidth+:ItemWidth])
    );

  end

  assign stat_clear_finish  = clear_finish;

  assign permit_valid_pulse = p5_permit_valid_pulse;
  assign permit_blocked     = p5_permit_blocked;
  assign permit_ip          = p5_permit_ip;

endmodule
`resetall
