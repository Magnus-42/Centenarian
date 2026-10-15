`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_axis_fifo_sync.v
// Module Name : tb_axis_fifo_sync
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-09-18
// ----------------------------------------------------------------------------
// Description : axis_fifo_sync 自测平台 (包模式, PACKET_FIFO=1)
//   参数 BLK 切换配置:  BLK=0 -> distributed
//                      BLK=1 -> block + BRAM_DO_REG=2   (ipv4_tx 实际用法)
//
//   结构:
//     - 发送队列: 背靠背驱动, 每拍最多 1 拍(不会被 shell/工具吃掉参数)
//     - 期望队列: 只有"整包完成"才整体入队 -> 半包绝不允许出现在期望里
//     - 在线比对器: 每拍比对 data/keep/user/strb/id/dest/last 全字段 +
//                   出现"无期望拍"即报错(可抓多读/半包泄漏) + X 检测
//
//   用例:
//     T1 半包不可见 -> 补完可读 (2 包 x 2 拍, 全字段比对)
//     T2 读侧反压: 输出保持不丢不重
//     T3 3 包 x 3 拍背靠背 + 伪随机反压 (压流水/包计数)
//     T4 写满 -> full/sready 反压 -> 释放后按序补齐 (24 个单拍包)
//     T5 末尾残留半包不得输出 + 状态口径记录
//     T6 流中复位: 无 spurious beat, 复位后功能正常
// ============================================================================

module tb_axis_fifo_sync;

  parameter  BLK    = 0;                       // 0=distributed, 1=block+DO_REG2, 2=auto+DO_REG2
  localparam MEM    = (BLK == 2) ? "auto" : ((BLK == 1) ? "block" : "distributed");
  localparam DO_REG = (BLK == 0) ? 1 : 2;

  localparam W      = 512;
  localparam UW     = 100;
  localparam DEPTH  = 16;
  localparam QN     = 1024;                    // 队列深度

  reg               clk = 1'b0;
  reg               rst = 1'b1;
  always #5 clk = ~clk;

  reg  [W-1:0]      sdata ;
  reg  [W/8-1:0]    skeep ;
  reg               slast ;
  reg               svalid;
  wire              sready;
  reg  [UW-1:0]     suser ;
  reg  [W/8-1:0]    sstrb ;
  reg               sid   ;
  reg               sdest ;

  wire [W-1:0]      mdata ;
  wire [W/8-1:0]    mkeep ;
  wire              mvalid;
  wire              mlast ;
  reg               mready;
  wire [UW-1:0]     muser ;
  wire [W/8-1:0]    mstrb ;
  wire              mid   ;
  wire              mdest ;

  wire prog_empty, prog_full, empty, full;
  wire [$clog2(DEPTH)+1-1:0] remain_count;

  axis_fifo_sync #(
    .FIFO_DEPTH       (DEPTH  ),
    .AXIS_WIDTH       (W      ),
    .AXIS_USER_WIDTH  (UW     ),
    .PACKET_FIFO      (1      ),
    .FIFO_MEMORY_TYPE (MEM    ),
    .BRAM_DO_REG      (DO_REG )
  ) u_dut(
    .rst         (rst         ),
    .clk         (clk         ),
    .axis_sdata  (sdata       ),
    .axis_skeep  (skeep       ),
    .axis_svalid (svalid      ),
    .axis_slast  (slast       ),
    .axis_sready (sready      ),
    .axis_susr  (suser       ),
    .axis_sstrb  (sstrb       ),
    .axis_sid    (sid         ),
    .axis_sdest  (sdest       ),
    .axis_mdata  (mdata       ),
    .axis_mkeep  (mkeep       ),
    .axis_mvalid (mvalid      ),
    .axis_mlast  (mlast       ),
    .axis_mready (mready      ),
    .axis_musr  (muser       ),
    .axis_mstrb  (mstrb       ),
    .axis_mid    (mid         ),
    .axis_mdest  (mdest       ),
    .prog_empty  (prog_empty  ),
    .prog_full   (prog_full   ),
    .empty       (empty       ),
    .full        (full        ),
    .remain_count(remain_count)
  );

  // ==========================================================================
  // 记分板
  // ==========================================================================
  reg [7:0] q_tag [0:QN-1];      // 发送队列
  reg       q_lst [0:QN-1];
  integer   q_wr, q_rd;

  reg [7:0] e_tag [0:QN-1];      // 期望队列(整包才入队)
  reg       e_lst [0:QN-1];
  integer   e_wr, e_rd;

  reg [7:0] st_tag [0:QN-1];     // 正在拼的半包
  reg       st_lst [0:QN-1];
  integer   st_n;

  integer   got_cnt, err, cerr, perr;

  task automatic chk(input cond, input [8*80-1:0] msg);
    begin
      if (!cond) begin
        $display("  [FAIL] %0s", msg);
        err = err + 1;
      end
    end
  endtask

  // 压一拍照进发送队列; 若 last 则把整包刷进期望队列
  task automatic push_beat(input [7:0] t, input last);
    integer k;
    begin
      q_tag[q_wr] = t;   q_lst[q_wr] = last;   q_wr = q_wr + 1;
      st_tag[st_n] = t;  st_lst[st_n] = last;  st_n = st_n + 1;
      if (last) begin
        for (k = 0; k < st_n; k = k + 1) begin
          e_tag[e_wr] = st_tag[k];
          e_lst[e_wr] = st_lst[k];
          e_wr = e_wr + 1;
        end
        st_n = 0;
      end
    end
  endtask

  task automatic push_pkt(input [7:0] t0, input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) push_beat(t0 + k, (k == n - 1));
    end
  endtask

  // ==========================================================================
  // 发送驱动 (negedge 上换拍 -> 可背靠背; svalid 保持到被接收)
  // ==========================================================================
  always @(negedge clk) begin
    if (!rst) begin
      if (svalid === 1'b0 && q_rd < q_wr) begin
        sdata  <= {504'd0, q_tag[q_rd]};
        skeep  <= {8{q_tag[q_rd]}};
        suser  <= {25{q_tag[q_rd][3:0]}};
        sstrb  <= {8{~q_tag[q_rd]}};
        sid    <= q_tag[q_rd][0];
        sdest  <= q_tag[q_rd][1];
        slast  <= q_lst[q_rd];
        svalid <= 1'b1;
        q_rd    = q_rd + 1;
      end
    end
  end

  always @(posedge clk) begin
    if (rst) svalid <= 1'b0;
    else if (svalid === 1'b1 && sready === 1'b1) svalid <= 1'b0;
  end

  // ==========================================================================
  // 读侧在线比对器 (全字段 + 无期望拍检测 + X 检测)
  // ==========================================================================
  always @(posedge clk) begin
    if (!rst) begin
      if (mvalid === 1'b1) begin
        if ((^mdata) === 1'bx || (^mkeep) === 1'bx || (^muser) === 1'bx ||
            (^mstrb) === 1'bx || mlast === 1'bx || mid === 1'bx || mdest === 1'bx) begin
          if (perr < 8) $display("  [FAIL] X on m-side while mvalid=1 (t=%0t)", $time);
          perr = perr + 1;  cerr = cerr + 1;
        end
      end
      if (mvalid === 1'b1 && mready === 1'b1) begin
        got_cnt = got_cnt + 1;
        if (e_rd >= e_wr) begin
          if (perr < 8) $display("  [FAIL] beat #%0d 无期望(tag=%02h) -> 多读/半包泄漏 t=%0t",
                                 got_cnt, mdata[7:0], $time);
          perr = perr + 1;  cerr = cerr + 1;
        end
        else begin
          if (mdata[7:0] !== e_tag[e_rd]) begin
            if (perr < 8) $display("  [FAIL] data: got %02h exp %02h (beat#%0d)",
                                   mdata[7:0], e_tag[e_rd], got_cnt);
            perr = perr + 1;  cerr = cerr + 1;
          end
          if (mkeep !== {8{e_tag[e_rd]}}) begin
            if (perr < 8) $display("  [FAIL] keep mismatch (beat#%0d tag=%02h) got %h exp %h",
                                   got_cnt, e_tag[e_rd], mkeep, {8{e_tag[e_rd]}});
            perr = perr + 1;  cerr = cerr + 1;
          end
          if (muser !== {25{e_tag[e_rd][3:0]}}) begin
            if (perr < 8) $display("  [FAIL] user mismatch (beat#%0d tag=%02h)", got_cnt, e_tag[e_rd]);
            perr = perr + 1;  cerr = cerr + 1;
          end
          if (mstrb !== {8{~e_tag[e_rd]}}) begin
            if (perr < 8) $display("  [FAIL] strb mismatch (beat#%0d tag=%02h)", got_cnt, e_tag[e_rd]);
            perr = perr + 1;  cerr = cerr + 1;
          end
          if (mid !== e_tag[e_rd][0] || mdest !== e_tag[e_rd][1]) begin
            if (perr < 8) $display("  [FAIL] id/dest mismatch (beat#%0d tag=%02h): id=%b dest=%b",
                                   got_cnt, e_tag[e_rd], mid, mdest);
            perr = perr + 1;  cerr = cerr + 1;
          end
          if (mlast !== e_lst[e_rd]) begin
            if (perr < 8) $display("  [FAIL] last mismatch (beat#%0d tag=%02h): got %b exp %b",
                                   got_cnt, e_tag[e_rd], mlast, e_lst[e_rd]);
            perr = perr + 1;  cerr = cerr + 1;
          end
          e_rd = e_rd + 1;
        end
      end
    end
  end

  // ==========================================================================
  // 读侧反压模式: 0=恒 ready, 1=恒停, 2=伪随机
  // ==========================================================================
  reg [1:0] mr_mode;
  reg [2:0] bp_cnt;
  reg [7:0] bp_pat = 8'b1011_0010;
  always @(posedge clk) begin
    case (mr_mode)
      2'd0: mready <= 1'b1;
      2'd1: mready <= 1'b0;
      2'd2: begin bp_cnt <= bp_cnt + 1'b1; mready <= bp_pat[bp_cnt]; end
      default: mready <= 1'b1;
    endcase
  end

  task automatic set_mode(input [1:0] m);
    begin @(negedge clk); mr_mode <= m; end
  endtask

  task automatic cyc(input integer n);
    integer k;
    begin for (k = 0; k < n; k = k + 1) @(posedge clk); end
  endtask

  // ==========================================================================
  integer bef, i, base;
  initial begin
    $display("================================================================");
    $display(" tb_axis_fifo_sync  MEM=%0s  BRAM_DO_REG=%0d  PACKET_FIFO=1  DEPTH=%0d",
             MEM, DO_REG, DEPTH);
    $display("================================================================");
    err = 0; cerr = 0; perr = 0; got_cnt = 0;
    q_wr = 0; q_rd = 0; e_wr = 0; e_rd = 0; st_n = 0;
    sdata = 0; skeep = 0; slast = 0; svalid = 0; suser = 0; sstrb = 0; sid = 0; sdest = 0;
    mr_mode = 2'd0; bp_cnt = 3'd0; mready = 1'b1;
    rst = 1'b1; cyc(6); rst = 1'b0; cyc(2);

    // ---------------- T1: 半包不可见 ----------------
    $display("--- T1: partial packet invisible -> completed packet read back ---");
    bef = err + cerr;  base = got_cnt;
    push_beat(8'h11, 1'b0); cyc(8);
    chk(mvalid === 1'b0, "mvalid must be 0 while only a partial packet is in fifo");
    chk(got_cnt === base, "nothing may come out of a partial packet");
    push_beat(8'h12, 1'b1); cyc(6);
    push_pkt(8'h21, 2);     cyc(60);
    chk(got_cnt === base + 4, "expect exactly 4 beats of 2 complete packets");
    chk(e_rd === e_wr, "all 4 beats matched in order");
    if (err + cerr == bef) $display("  [PASS] T1 partial gating + full-field match");

    // ---------------- T2: 读侧反压 ----------------
    $display("--- T2: read-side backpressure: output held, no loss/dup ---");
    bef = err + cerr;  base = got_cnt;
    set_mode(2'd1); cyc(3);
    push_pkt(8'h31, 2); cyc(20);
    chk(mvalid === 1'b1, "mvalid should be 1 (complete packet available)");
    chk(mdata[7:0] === 8'h31 && mlast === 1'b0, "beat1 data/last held under backpressure");
    cyc(20);
    chk(mdata[7:0] === 8'h31 && mlast === 1'b0, "beat1 still held after 20 cycles");
    set_mode(2'd0); cyc(40);
    chk(got_cnt === base + 2, "exactly 2 beats after release");
    chk(e_rd === e_wr, "no duplicate / no loss");
    if (err + cerr == bef) $display("  [PASS] T2 backpressure hold");

    // ---------------- T3: 背靠背 + 伪随机反压 ----------------
    $display("--- T3: 3 packets x 3 beats back-to-back + pseudo-random backpressure ---");
    bef = err + cerr;  base = got_cnt;
    set_mode(2'd2); cyc(2);
    push_pkt(8'h41, 3); push_pkt(8'h51, 3); push_pkt(8'h61, 3);
    cyc(200);
    set_mode(2'd0); cyc(40);
    chk(got_cnt === base + 9, "expect exactly 9 beats");
    chk(e_rd === e_wr, "9 beats delivered in order, none lost/dup");
    if (err + cerr == bef) $display("  [PASS] T3 back-to-back + random backpressure");

    // ---------------- T4: 写满 ----------------
    $display("--- T4: fill up -> full/sready backpressure -> drain in order ---");
    bef = err + cerr;  base = got_cnt;
    set_mode(2'd1); cyc(3);
    for (i = 0; i < 24; i = i + 1) push_beat(8'h80 + i, 1'b1);
    cyc(80);
    chk(full === 1'b1, "FIFO should be full (24 single-beat packets, read side stopped)");
    chk(sready === 1'b0, "sready must be low when full");
    chk(q_rd < q_wr, "write side must be stalled by backpressure (beats still queued)");
    set_mode(2'd0); cyc(300);
    chk(got_cnt === base + 24, "all 24 beats drained after release");
    chk(e_rd === e_wr, "none lost, order kept");
    chk(empty === 1'b1, "empty=1 after drain");
    chk(remain_count === 0, "remain_count=0 after drain");
    if (err + cerr == bef) $display("  [PASS] T4 full / sready / drain");

    // ---------------- T5: 末尾残留半包 ----------------
    $display("--- T5: trailing partial packet must never come out ---");
    bef = err + cerr;  base = got_cnt;
    push_pkt(8'hA1, 2);
    push_beat(8'hB1, 1'b0); push_beat(8'hB2, 1'b0);   // 半个包, 永不完成
    cyc(80);
    chk(got_cnt === base + 2, "only the complete packet may come out");
    chk(e_rd === e_wr, "partial packet still not visible");
    chk(mvalid === 1'b0, "mvalid=0 with only a partial packet left");
    $display("  [INFO] 此时 empty=%b remain_count=%0d (RAM 残留 2 拍不可读 -> empty 口径见报告)",
             empty, remain_count);
    if (err + cerr == bef) $display("  [PASS] T5 trailing partial packet");

    // ---------------- T6: 流中复位 ----------------
    $display("--- T6: reset in the middle of a stream ---");
    bef = err + cerr;
    @(negedge clk); rst = 1'b1;
    q_wr = 0; q_rd = 0; e_wr = 0; e_rd = 0; st_n = 0; got_cnt = 0; mready = 1'b0;
    cyc(4); rst = 1'b0;
    chk(mvalid === 1'b0, "no spurious valid right after reset");
    set_mode(2'd0); cyc(20);
    chk(mvalid === 1'b0, "no spurious valid while idle after reset");
    chk(empty === 1'b1, "empty=1 after reset");
    base = got_cnt;
    push_pkt(8'hC1, 3); cyc(60);
    chk(got_cnt === base + 3, "3 beats after reset");
    chk(e_rd === e_wr, "post-reset packet correct");
    if (err + cerr == bef) $display("  [PASS] T6 mid-stream reset");

    // ---------------- 汇总 ----------------
    cyc(10);
    $display("================================================================");
    $display(" beats out=%0d  err=%0d  checker_err=%0d", got_cnt, err, cerr);
    $display(" empty=%b full=%b remain_count=%0d", empty, full, remain_count);
    if (err == 0 && cerr == 0) $display(" *** ALL TESTS PASSED ***");
    else                       $display(" *** %0d CHECK(S) FAILED ***", err + cerr);
    $display("================================================================");
    $finish;
  end

  initial begin
    #500_000;
    $display("[%0t] FATAL: timeout", $time);
    $finish;
  end

endmodule
`resetall
