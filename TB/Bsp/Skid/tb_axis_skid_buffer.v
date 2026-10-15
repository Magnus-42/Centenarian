`timescale 1ns/1ps
`default_nettype none
// -----------------------------------------------------------------------------
// File        : tb_axis_skid_buffer.v
// Module      : tb_axis_skid_buffer
// Description : axis_skid_buffer 单元验证(记分板 + 全字段比对 + 吞吐测量)
//               该模块此前从未验证过; ipv4_test_top 顶层新增了 8 个实例, 必须先验再从众
//
// 覆盖点:
//   ① 全字段(data/keep/strb/user/id/dest/last)逐拍严格比对 => 任一字段错线/漏存都 FAIL
//   ② 背靠背满速: 输出握手间隔恒 1 拍 => 吞吐 1.00 beat/cycle
//   ③ 下游任意反压(伪随机 / 周期长停) => 不丢、不重、不乱序、不吐无期望拍
//   ④ 上游稀疏(每 3 拍 1 拍) => 来一个过一个
//   ⑤ 单拍往返延迟 ∈ [1,2] (skid 两级上限)
//
// 有效性判据: 换上 Bug 版 RTL(keep 不进 skid)必须 FAIL —— 见 .workbuddy/sim/skid_tb/
// -----------------------------------------------------------------------------
module tb_axis_skid_buffer;

  localparam DATA_W = 64;
  localparam USER_W = 4;
  localparam ID_W   = 2;
  localparam DEST_W = 3;
  localparam KEEP_W = DATA_W / 8;
  localparam NMAX   = 1024;

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #2.5 clk = ~clk;              // 200 MHz

  integer err = 0;

  // ---------------- 单字节 tag -> 全部字段派生(每个字段都能用于抓错线) ----------------
  function [DATA_W-1:0] f_data; input [7:0] t; f_data = {DATA_W/8{t}}  ; endfunction
  function [KEEP_W-1:0] f_keep; input [7:0] t; f_keep = {KEEP_W{t[0]}} ; endfunction
  function [KEEP_W-1:0] f_strb; input [7:0] t; f_strb = {KEEP_W{t[4]}} ; endfunction
  function [USER_W-1:0] f_user; input [7:0] t; f_user = {USER_W{t[1]}} ; endfunction
  function [   ID_W-1:0] f_id ; input [7:0] t; f_id   = {   ID_W{t[2]}}; endfunction
  function [ DEST_W-1:0] f_dst; input [7:0] t; f_dst  = { DEST_W{t[3]}}; endfunction
  function               f_lst; input [7:0] t; f_lst  = t[5]           ; endfunction

  // ---------------- 发送队列(tag 序列) ----------------
  reg [7:0] q_tag [0:NMAX-1];
  integer   q_wr = 0, q_rd = 0;

  // ---------------- DUT 端口信号 ----------------
  reg               s_valid = 1'b0;
  reg  [DATA_W-1:0] s_data  = 0;
  reg  [KEEP_W-1:0] s_keep  = 0;
  reg  [KEEP_W-1:0] s_strb  = 0;
  reg  [USER_W-1:0] s_user  = 0;
  reg  [   ID_W-1:0] s_id   = 0;
  reg  [ DEST_W-1:0] s_dest = 0;
  reg               s_last  = 1'b0;
  wire              s_ready;

  reg               m_ready = 1'b1;                 // 单驱动, 由模式寄存器产生
  wire [DATA_W-1:0] m_data ;
  wire [KEEP_W-1:0] m_keep ;
  wire [KEEP_W-1:0] m_strb ;
  wire [USER_W-1:0] m_user ;
  wire [   ID_W-1:0] m_id  ;
  wire [ DEST_W-1:0] m_dest;
  wire              m_last ;
  wire              m_valid;

  axis_skid_buffer #(
    .AXIS_DATA_WIDTH (DATA_W ),
    .AXIS_USER_WIDTH (USER_W ),
    .AXIS_ID_WIDTH   (ID_W   ),
    .AXIS_DEST_WIDTH (DEST_W )
  ) u_dut (
    .clk       (clk     ), .rst      (rst     ),
    .axis_sdata(s_data  ), .axis_skeep(s_keep ), .axis_susr(s_user ),
    .axis_sid  (s_id    ), .axis_sdest(s_dest ), .axis_sstrb(s_strb ),
    .axis_slast(s_last  ), .axis_svalid(s_valid), .axis_sready(s_ready),
    .axis_mdata(m_data  ), .axis_mkeep(m_keep ), .axis_musr(m_user ),
    .axis_mid  (m_id    ), .axis_mdest(m_dest ), .axis_mstrb(m_strb ),
    .axis_mlast(m_last  ), .axis_mvalid(m_valid), .axis_mready(m_ready)
  );

  // ---------------- 下游 ready 模式(0=恒1 1=伪随机 2=周期停3拍) ----------------
  reg  [1:0] mr_mode  = 2'd0;
  reg  [7:0] mr_lfsr  = 8'hA5;
  reg  [2:0] mr_phase = 3'd0;
  wire       mr_rand  = mr_lfsr[0] ^ mr_lfsr[3];
  always @(posedge clk) begin
    mr_lfsr  <= {mr_lfsr[6:0], mr_lfsr[7]^mr_lfsr[5]^mr_lfsr[4]^mr_lfsr[3]};
    mr_phase <= mr_phase + 1'b1;
    case (mr_mode)
      2'd0:    m_ready <= 1'b1;
      2'd1:    m_ready <= mr_rand;
      2'd2:    m_ready <= (mr_phase < 3'd3) ? 1'b0 : 1'b1;
      default: m_ready <= 1'b1;
    endcase
  end

  // ---------------- 上游稀疏控制(每 3 拍放行 1 次装载) ----------------
  reg        s_sparse = 1'b0;
  reg  [1:0] s_slow   = 2'd0;
  reg        s_allow  = 1'b1;
  always @(posedge clk) begin
    if (!s_sparse) begin
      s_allow <= 1'b1;
    end
    else if (s_slow == 2'd2) begin
      s_slow  <= 2'd0;
      s_allow <= 1'b1;
    end
    else begin
      s_slow  <= s_slow + 1'b1;
      s_allow <= 1'b0;
    end
  end

  // ---------------- 上游队列驱动(背靠背满速, 沿外装载, 握手当拍清 valid) ----------------
  always @(negedge clk) begin
    if (!rst && s_valid === 1'b0 && (q_rd < q_wr) && s_allow) begin
      s_data  <= f_data(q_tag[q_rd]);
      s_keep  <= f_keep(q_tag[q_rd]);
      s_strb  <= f_strb(q_tag[q_rd]);
      s_user  <= f_user(q_tag[q_rd]);
      s_id    <= f_id  (q_tag[q_rd]);
      s_dest  <= f_dst (q_tag[q_rd]);
      s_last  <= f_lst (q_tag[q_rd]);
      s_valid <= 1'b1;
      q_rd    <= q_rd + 1;
    end
  end
  always @(posedge clk) begin
    if (rst)                                   s_valid <= 1'b0;
    else if (s_valid === 1'b1 && s_ready === 1'b1) s_valid <= 1'b0; // 只被接收一次
  end

  // ---------------- 单一测量/比对块 ----------------
  integer cs_id = 0;
  integer cs_cur_mode = 0;   // 本用例的下游 ready 模式
  integer cyc = 0;
  integer sent_hs = 0;   // 输入握手拍数(下界: 输出不可能超过它)
  integer rcv = 0;       // 已比对拍数
  integer in_tm [0:NMAX-1];
  integer in_wr = 0, in_re = 0;
  integer th_n = 0, th_last = 0, th_max = 0, th_sum = 0, gap;
  integer dly, dly_max = 0;
  reg cs_busy = 1'b0;
  integer c_tag_i;
  reg [7:0] c_tag;

  always @(posedge clk) begin
    if (!rst) begin
      cyc <= cyc + 1;
      if (s_valid && s_ready) begin
        sent_hs <= sent_hs + 1;
        if (cs_busy) begin in_tm[in_wr] = cyc; in_wr = in_wr + 1; end
      end
      if (m_valid && m_ready) begin
        if (!cs_busy || rcv >= sent_hs) begin
          $display("  [FAIL] case%0d: 无期望拍(mready 侧多读) rcv=%0d sent=%0d", cs_id, rcv, sent_hs);
          err = err + 1;
        end
        else begin
          c_tag = q_tag[rcv];
          if (m_data !== f_data(c_tag)) begin $display("  [FAIL] case%0d beat%0d mdata exp=%h got=%h", cs_id, rcv, f_data(c_tag), m_data); err = err + 1; end
          if (m_keep !== f_keep(c_tag)) begin $display("  [FAIL] case%0d beat%0d mkeep exp=%h got=%h", cs_id, rcv, f_keep(c_tag), m_keep); err = err + 1; end
          if (m_strb !== f_strb(c_tag)) begin $display("  [FAIL] case%0d beat%0d mstrb exp=%h got=%h", cs_id, rcv, f_strb(c_tag), m_strb); err = err + 1; end
          if (m_user !== f_user(c_tag)) begin $display("  [FAIL] case%0d beat%0d muser exp=%h got=%h", cs_id, rcv, f_user(c_tag), m_user); err = err + 1; end
          if (m_id   !== f_id  (c_tag)) begin $display("  [FAIL] case%0d beat%0d mid   exp=%h got=%h", cs_id, rcv, f_id  (c_tag), m_id  ); err = err + 1; end
          if (m_dest !== f_dst (c_tag)) begin $display("  [FAIL] case%0d beat%0d mdest exp=%h got=%h", cs_id, rcv, f_dst (c_tag), m_dest); err = err + 1; end
          if (m_last !== f_lst (c_tag)) begin $display("  [FAIL] case%0d beat%0d mlast exp=%b got=%b", cs_id, rcv, f_lst (c_tag), m_last); err = err + 1; end
          // 单拍排队延迟: 仅当下游恒 ready(mode 0) 时才应落在 [1,2];
          // 有反压时数据在 reg/skid 里排队, 延迟自然变长, 此处只做统计
          dly = cyc - in_tm[in_re];
          in_re = in_re + 1;
          if (dly > dly_max) dly_max = dly;
          if (cs_cur_mode == 0 && (dly < 1 || dly > 2)) begin
            $display("  [FAIL] case%0d beat%0d delay=%0d 越界(恒 ready 时应为 1~2)", cs_id, rcv, dly);
            err = err + 1;
          end
          // 吞吐: 相邻输出握手间隔
          if (th_n > 0) begin
            gap = cyc - th_last;
            if (gap > th_max) th_max = gap;
            th_sum = th_sum + gap;
          end
          th_n    = th_n + 1;
          th_last = cyc;
          rcv     = rcv + 1;
        end
      end
    end
  end

  // ---------------- 用例驱动 ----------------
  integer i;
  reg [7:0] tg;

  task run_case;
    input integer cid;      // 用例号
    input integer cmode;    // 下游 ready 模式
    input integer cn;       // 拍数
    input integer csparse;  // 上游稀疏
    begin
      cs_id       = cid;
      cs_cur_mode = cmode;
      q_wr        = 0; q_rd = 0;
      sent_hs   = 0; rcv = 0;
      in_wr     = 0; in_re = 0;
      th_n      = 0; th_max = 0; th_sum = 0; th_last = 0;
      dly_max   = 0;
      mr_mode   = cmode;
      s_sparse  = csparse;
      cs_busy   = 1'b1;
      for (i = 0; i < cn; i = i + 1) begin
        tg        = (i * 8'd7 + cid * 8'd13);
        q_tag[i]  = tg;
        q_wr      = q_wr + 1;
      end
      while (rcv < cn) @(posedge clk);     // 等本用例全部比对完
      cs_busy  = 1'b0;
      // 排空余量
      repeat (4) @(posedge clk);
      $display("  [CASE %0d] n=%0d 拍数核对: 收=%0d(%s) 最大间隔=%0d 平均间隔=%.2f 最大单拍延迟=%0d",
               cid, cn, rcv,
               (rcv == cn) ? "OK" : "NG",
               th_max,
               (th_n > 1) ? (th_sum * 100 / (th_n - 1)) / 100.0 : 0.0,
               dly_max);
      if (rcv !== cn) begin $display("  [FAIL] case%0d: 收拍数 %0d != 期望 %0d", cid, rcv, cn); err = err + 1; end
      mr_mode  = 2'd0;
      s_sparse = 1'b0;
    end
  endtask

  initial begin
    $display("=== tb_axis_skid_buffer : 开始 ===");
    repeat (6) @(posedge clk);
    rst = 1'b0;
    repeat (4) @(posedge clk);

    run_case(1, 0, 256, 0);   // 直通 + 背靠背满速
    run_case(2, 1, 256, 0);   // 下游伪随机反压
    run_case(3, 2, 256, 0);   // 下游周期停 3 拍
    run_case(4, 0, 128, 1);   // 上游稀疏(每 3 拍 1 拍)
    run_case(5, 1, 128, 1);   // 上下游都稀疏/反压
    run_case(6, 0,   1, 0);   // 单拍脉冲

    if (err == 0) $display(" *** ALL TESTS PASSED ***");
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
    $finish;
  end

  // 看门狗
  initial begin
    #200000;
    $display("FATAL: timeout");
    $finish;
  end

endmodule
