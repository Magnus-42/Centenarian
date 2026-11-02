`timescale 1ns/100ps
`include "cfg_map.vh"

// Language: Verilog 2001
// ============================================================================
// File Name   : tb_cfg_get.v
// Module Name : tb_cfg_get
// Author      : LiXintao
// Date        : 2026-10-28
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : cfg_get 单元验证 —— 背靠背 + 反压组合下不丢、不重、不串
//
//   背景：cfg_get 的 rd_val 直接来自 cfg_reg_bank 的当前输出（按需读、1 拍后
//         有效），没有独立寄存。若 rec_ready 在 rd_req_s1 / rd_req_s2 有效期间
//         放行，后一次读会刷新 rd_val，导致「上一条的 seq/item + 这一条的值」
//         串包，或未握手发出的应答被覆盖丢失。
//         该缺陷在 cfg_cmd_top 级 TB 上看不出来：cfg_demux 每 TLV 要 6 拍以上，
//         命令之间天然隔开，问题窗口被掩盖。必须在单元级压测。
//
//   用例：
//     K1 无反压、3 条背靠背            -> 内容/顺序/条数全对
//     K2 反压起点最早（应答尚未产生）  -> 同上（最敏感，宽松 rec_ready 在此丢包）
//     K3 反压卡在流水中间（第 6 拍）   -> 同上
//     K4 反压卡在应答已发出未握手      -> 同上
//
//   判据：应答条数 == 命令条数，且每条 seq/item/val 与对应命令一致
//         （val 由 TB 模拟的 reg_bank 按 rd_item 生成，因此能暴露串包）
// ============================================================================
module tb_cfg_get;

  localparam NCMD = 3;

  // ---------------------------------------------------------------- 时钟 / 复位
  reg clk = 1'b0;
  always #2.5 clk = ~clk;   // 200 MHz（功能仿真，频率不影响逻辑正确性）
  reg rst = 1'b1;

  integer err_total = 0;

  // ---------------------------------------------------------------- 命令源
  // 队列式 AXIS 源：q_rd 只在 always 里更新，避免与 initial 竞争
  reg [7:0] q_seq  [0:NCMD-1];
  reg [7:0] q_item [0:NCMD-1];
  integer   q_rd    = 0;
  reg       src_clr = 1'b0;
  wire      s_valid = (q_rd < NCMD);
  wire [7:0] s_seq  = q_seq [q_rd];
  wire [7:0] s_item = q_item[q_rd];

  // ---------------------------------------------------------------- DUT 连线
  wire         s_ready;
  wire         rd_req;
  reg  [7:0]   rd_len = 8'd0;
  reg  [127:0] rd_val = 128'd0;
  wire [511:0] m_data;
  wire [ 63:0] m_keep;
  wire         m_last;
  wire         m_valid;
  reg          m_ready = 1'b1;
  reg          bp_hold = 1'b0;   // 1 = 反压（m_ready 拉低），时钟同步

  always @(posedge clk) begin
    if (rst) m_ready <= 1'b1;
    else     m_ready <= ~bp_hold;
  end

  cfg_get #(
    .MAX_VALUE_BYTES (16),
    .CMD_USR_WIDTH   (96)
  ) u_dut (
    .clk             (clk     ),
    .rst             (rst     ),
    // 命令输入
    .rec_valid       (s_valid ),
    .rec_ready       (s_ready ),
    .rec_op          (8'h02  ),
    .rec_seq         (s_seq   ),
    .rec_item        (s_item  ),
    .rec_set         (4'd0    ),
    .rec_port        (4'd0    ),
    .rec_len         (8'd0    ),
    .rec_val         (128'd0  ),
    .rec_usr         (96'd0   ),
    // 读回
    .rd_req          (rd_req  ),
    .rd_item         (        ),
    .rd_set          (        ),
    .rd_port         (        ),
    .rd_len          (rd_len  ),
    .rd_val          (rd_val  ),
    // 应答输出
    .rd_axis_mdata   (m_data  ),
    .rd_axis_mkeep   (m_keep  ),
    .rd_axis_mlast   (m_last  ),
    .rd_axis_mvalid  (m_valid ),
    .rd_axis_mready  (m_ready ),
    .rd_axis_musr    (        )
  );

  // ---------------------------------------------------------------- reg_bank 行为模型
  // 读延迟 1 拍；返回值 = {120'd0, 8'hA0, 被读 item}，值随 item 变化
  // ⇒ 一旦 seq/item 与 val 不是同一条命令的，比对立刻失败
  always @(posedge clk) begin
    if (rd_req) begin
      rd_len <= 8'd4;
      rd_val <= {120'd0, 8'hA0, u_dut.rd_item};
    end
  end

  // ---------------------------------------------------------------- 命令源退队 / 清零
  always @(posedge clk) begin
    if (src_clr)             q_rd <= 0;
    else if (s_valid && s_ready) q_rd <= q_rd + 1;
  end

  // ---------------------------------------------------------------- 应答采集
  reg [7:0]  g_seq  [0:15];
  reg [7:0]  g_item [0:15];
  reg [15:0] g_val  [0:15];
  integer    rsp_cnt = 0;
  reg        cap_clr = 1'b0;

  always @(posedge clk) begin
    if (cap_clr) rsp_cnt <= 0;
    else if (m_valid && m_ready && rsp_cnt < 16) begin
      g_seq [rsp_cnt] <= m_data[15:8];
      g_item[rsp_cnt] <= m_data[31:24];
      g_val [rsp_cnt] <= m_data[63:48];
      rsp_cnt <= rsp_cnt + 1;
    end
  end

  // ---------------------------------------------------------------- 辅助任务
  task automatic do_reset;
    begin
      src_clr = 1'b1;
      cap_clr = 1'b1;
      @(posedge clk);
      @(posedge clk);
      src_clr = 1'b0;
      cap_clr = 1'b0;
      @(posedge clk);
    end
  endtask

  // 结算：条数 + 每条内容
  task automatic check(input [8*8-1:0] tag);
    integer k;
    integer bad;
    begin
      bad = 0;
      if (rsp_cnt !== NCMD) begin
        $display("  [FAIL] 应答条数 = %0d (exp %0d)", rsp_cnt, NCMD);
        bad = bad + 1;
      end
      else begin
        for (k = 0; k < NCMD; k = k + 1) begin
          if (g_seq[k] !== (8'hC0 + k[7:0]) ||
              g_item[k] !== (8'h50 + k[7:0]) ||
              g_val[k] !== (16'hA050 + k[15:0])) begin
            $display("  [FAIL] 第 %0d 条: seq=%h item=%h val=%h (exp %h/%h/%h)",
                     k, g_seq[k], g_item[k], g_val[k],
                     8'hC0 + k[7:0], 8'h50 + k[7:0], 16'hA050 + k[15:0]);
            bad = bad + 1;
          end
        end
      end
      if (bad == 0) $display("  [PASS] %0s : 3 responses OK (count/order/content)", tag);
      err_total = err_total + bad;
    end
  endtask

  // ---------------------------------------------------------------- 主激励
  integer k;
  initial begin
    for (k = 0; k < NCMD; k = k + 1) begin
      q_seq [k] = 8'hC0 + k;
      q_item[k] = 8'h50 + k;
    end

    rst = 1'b1;
    repeat (10) @(posedge clk);
    rst = 1'b0;
    repeat (3) @(posedge clk);

    // ---------------- K1 无反压 ----------------
    $display("--- K1: 无反压、3 条背靠背 ---");
    do_reset();
    repeat (120) @(posedge clk);
    check("K1-none");

    // ---------------- K2 反压起点最早 ----------------
    // 应答尚未产生、mvalid 仍为 0，是「宽松 rec_ready」唯一会丢包的窗口
    $display("--- K2: 反压起点最早（应答尚未产生，持续 6 拍）---");
    do_reset();
    bp_hold = 1'b1;
    repeat (6) @(posedge clk);
    bp_hold = 1'b0;
    repeat (120) @(posedge clk);
    check("K2-early");

    // ---------------- K3 反压卡在流水中间 ----------------
    $display("--- K3: 反压卡在流水中间（第 6 拍起，持续 6 拍）---");
    do_reset();
    repeat (5) @(posedge clk);
    bp_hold = 1'b1;
    repeat (6) @(posedge clk);
    bp_hold = 1'b0;
    repeat (120) @(posedge clk);
    check("K3-mid");

    // ---------------- K4 反压卡在应答已产生未握手 ----------------
    $display("--- K4: 反压卡在应答已产生、未握手（第 8 拍起，持续 8 拍）---");
    do_reset();
    repeat (7) @(posedge clk);
    bp_hold = 1'b1;
    repeat (8) @(posedge clk);
    bp_hold = 1'b0;
    repeat (120) @(posedge clk);
    check("K4-hang");

    // ---------------- 汇总 ----------------
    $display("================================================================");
    if (err_total == 0) $display(" *** ALL TESTS PASSED ***");
    else                $display(" *** %0d CHECK(S) FAILED ***", err_total);
    $display("================================================================");
    $finish;
  end

  initial begin
    #2_000_000;
    $display("[%0t] [FAIL] FATAL: timeout", $time);
    $display(" *** 1 CHECK(S) FAILED ***");
    $finish;
  end

endmodule
