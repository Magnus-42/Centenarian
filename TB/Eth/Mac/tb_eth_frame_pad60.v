`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_eth_frame_pad60.v
// Module Name : tb_eth_frame_pad60
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-09-19
// ----------------------------------------------------------------------------
// Description : eth_frame_pad60 自测平台(原 ipv4_pad60)
//   期望模型(与设计意图一致):
//     - 补长只可能发生在"整帧落在首拍"的情况(512bit=64B/拍) =>
//       首拍 且 keep[59]==0 时, 把 keep 补到 60 字节(64'h0fff_ffff_ffff_ffff)
//     - 数据: 每一拍都按"本拍 keep"做字节屏蔽(keep=0 的字节输出 0x00)
//       => 补位字节天然是 0
//     - last 原样透传
//   用例:
//     T1 长帧(2 拍, keep 全 1) -> 数据/keep/last 原样通过
//     T2 短帧(34B, 单拍)       -> keep 变 60B, 34~59 字节为 0, last=1
//     T3 恰好 60B 帧           -> keep 保持 60B 不变(不额外补)
//     T4 反压                  -> 不丢不重
// ============================================================================

module tb_eth_frame_pad60;

  localparam W = 512;
  localparam K = 64;

  reg               clk = 1'b0;
  reg               rst = 1'b1;
  always #5 clk = ~clk;

  reg  [W-1:0]      sdata ;
  reg  [K-1:0]      skeep ;
  reg               slast ;
  reg               svalid;
  wire              sready;

  wire [W-1:0]      mdata ;
  wire [K-1:0]      mkeep ;
  wire              mlast ;
  wire              mvalid;
  reg               mready;

  eth_frame_pad60 u_dut (
    .clk              (clk   ),
    .rst              (rst   ),
    .eth_axis_sdata  (sdata ),
    .eth_axis_skeep  (skeep ),
    .eth_axis_slast  (slast ),
    .eth_axis_svalid (svalid),
    .eth_axis_sready (sready),
    .eth_axis_mdata  (mdata ),
    .eth_axis_mkeep  (mkeep ),
    .eth_axis_mlast  (mlast ),
    .eth_axis_mvalid (mvalid),
    .eth_axis_mready (mready)
  );

  // ---------------- 发送队列 ----------------
  localparam QN = 64;
  reg [W-1:0] sq_data [0:QN-1];
  reg [K-1:0] sq_keep [0:QN-1];
  reg         sq_last [0:QN-1];
  integer     sq_wr, sq_rd;

  always @(negedge clk) begin
    if (!rst && svalid === 1'b0 && sq_rd < sq_wr) begin
      sdata  <= sq_data[sq_rd];
      skeep  <= sq_keep[sq_rd];
      slast  <= sq_last[sq_rd];
      svalid <= 1'b1;
      sq_rd   = sq_rd + 1;
    end
  end
  always @(posedge clk) begin
    if (rst) svalid <= 1'b0;
    else if (svalid === 1'b1 && sready === 1'b1) svalid <= 1'b0;
  end

  // ---------------- 期望模型 ----------------
  function [W-1:0] f_mask;
    input [W-1:0] d;
    input [K-1:0] k;
    integer i;
    begin
      for (i = 0; i < 64; i = i + 1)
        f_mask[i*8 +: 8] = k[i] ? d[i*8 +: 8] : 8'h00;
    end
  endfunction

  localparam [K-1:0] K60 = 64'h0fff_ffff_ffff_ffff;   // 低 60 字节有效

  reg [W-1:0] e_data [0:QN-1];
  reg [K-1:0] e_keep [0:QN-1];
  reg         e_last [0:QN-1];
  integer     e_wr, e_rd;

  task automatic push_pkt(input integer nbeats, input [7:0] tag0, input integer nbytes_last);
    integer i;
    begin
      for (i = 0; i < nbeats; i = i + 1) begin
        sq_data[sq_wr] = {448'd0, tag0 + i[7:0], 56'd0};   // 每拍低字节放不同 tag
        if (i == nbeats - 1) sq_keep[sq_wr] = (nbytes_last >= 64) ? {64{1'b1}}
                                                                  : ((64'h1 << nbytes_last) - 1);
        else                 sq_keep[sq_wr] = {64{1'b1}};
        sq_last[sq_wr] = (i == nbeats - 1);
        sq_wr = sq_wr + 1;

        // 期望
        e_data[e_wr] = f_mask(sq_data[sq_wr-1], sq_keep[sq_wr-1]);
        e_keep[e_wr] = ((i == 0) && (sq_keep[sq_wr-1][59] == 1'b0)) ? K60 : sq_keep[sq_wr-1];
        e_last[e_wr] = sq_last[sq_wr-1];
        e_wr = e_wr + 1;
      end
    end
  endtask

  // ---------------- 在线比对 ----------------
  integer got_cnt, err, perr;
  always @(posedge clk) begin
    if (!rst && mvalid === 1'b1 && mready === 1'b1) begin
      got_cnt = got_cnt + 1;
      if (e_rd >= e_wr) begin
        if (perr < 6) $display("  [FAIL] beat #%0d 无期望 -> 多发 t=%0t", got_cnt, $time);
        perr = perr + 1; err = err + 1;
      end
      else begin
        if (mdata !== e_data[e_rd]) begin
          if (perr < 6) $display("  [FAIL] beat #%0d data: got %h exp %h", got_cnt, mdata[63:0], e_data[e_rd][63:0]);
          perr = perr + 1; err = err + 1;
        end
        if (mkeep !== e_keep[e_rd]) begin
          if (perr < 6) $display("  [FAIL] beat #%0d keep: got %h exp %h", got_cnt, mkeep, e_keep[e_rd]);
          perr = perr + 1; err = err + 1;
        end
        if (mlast !== e_last[e_rd]) begin
          if (perr < 6) $display("  [FAIL] beat #%0d last: got %b exp %b", got_cnt, mlast, e_last[e_rd]);
          perr = perr + 1; err = err + 1;
        end
        e_rd = e_rd + 1;
      end
    end
  end

  task automatic cyc(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
  endtask

  task automatic set_mready(input v);
    begin @(negedge clk); mready <= v; end
  endtask

  integer base;
  initial begin
    $display("================================================================");
    $display(" tb_eth_frame_pad60");
    $display("================================================================");
    err = 0; perr = 0; got_cnt = 0; sq_wr = 0; sq_rd = 0; e_wr = 0; e_rd = 0;
    sdata = 0; skeep = 0; slast = 0; svalid = 0; mready = 1'b1;
    rst = 1'b1; cyc(6); rst = 1'b0; cyc(2);

    // ---- T1: 长帧 2 拍 (keep 全 1, 不需要补) ----
    $display("--- T1: long frame, 2 beats, keep all-1 (no pad needed) ---");
    base = got_cnt;
    push_pkt(2, 8'h10, 64); cyc(40);
    if (got_cnt != base + 2) begin
      $display("  [FAIL] expect 2 beats, got %0d", got_cnt - base); err = err + 1;
    end
    else $display("  [PASS] 2 beats passed through");
    cyc(10);

    // ---- T2: 短帧 34 字节(单拍) -> 必须补到 60 字节 ----
    $display("--- T2: short frame 34 bytes (single beat) -> pad to 60 ---");
    base = got_cnt;
    push_pkt(1, 8'h20, 34); cyc(40);
    if (got_cnt != base + 1) begin
      $display("  [FAIL] expect 1 beat, got %0d", got_cnt - base); err = err + 1;
    end
    else $display("  [PASS] 1 beat out");
    cyc(10);

    // ---- T3: 恰好 60 字节帧 -> keep 不应被改 ----
    $display("--- T3: exactly 60 bytes -> keep must stay ---");
    base = got_cnt;
    push_pkt(1, 8'h30, 60); cyc(40);
    if (got_cnt != base + 1) begin
      $display("  [FAIL] expect 1 beat, got %0d", got_cnt - base); err = err + 1;
    end
    else $display("  [PASS] 1 beat out");
    cyc(10);

    // ---- T4: 反压 ----
    $display("--- T4: backpressure ---");
    base = got_cnt;
    set_mready(1'b0); cyc(3);
    push_pkt(2, 8'h40, 34); cyc(20);
    set_mready(1'b1); cyc(60);
    if (got_cnt != base + 2) begin
      $display("  [FAIL] expect 2 beats after release, got %0d", got_cnt - base); err = err + 1;
    end
    else $display("  [PASS] 2 beats, no loss/dup");
    cyc(10);

    $display("================================================================");
    $display(" beats out=%0d err=%0d", got_cnt, err);
    if (err == 0) $display(" *** ALL TESTS PASSED ***");
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
    $display("================================================================");
    $finish;
  end

  initial begin
    #100_000;
    $display("[%0t] FATAL: timeout", $time);
    $finish;
  end

endmodule
`resetall
