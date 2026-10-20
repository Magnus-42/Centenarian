`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_icmpv4_top.v
// Module Name : tb_icmpv4_top
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-10-18
// ----------------------------------------------------------------------------
// Description : icmpv4_top 分流语义验证
//   echo 请求 (type=8/code=0, 非分片)   -> ipv4_icmp_tx_*      (内部应答, 不出边界)
//   其它 ICMP (type!=8 / code!=0 / 分片) -> ipv4_other_axis_m*  (= 顶层 icmp_axis_m*)
//   判定:
//     [A] other 路逐字节与输入一致(按 keep 重建), 顺序正确
//     [B] echo 路包数正确, 且应答 type 字节 == 0x00
//     [C] other 路包数/字节数正确
//     [D] 互斥: 两路包数之和 == 发送包数(同一包不得两路都有)
//     [E] usr 透传一致
//     [F] 输出无 X
//     [G] 相内超时打 [FAIL]
//   两个 phase: ① 全速(两路 ready 常高) ② 随机反压
// ============================================================================
module tb_icmpv4_top;

  localparam W  = 512;
  localparam K  = 64;
  localparam NP = 7;               // 包数
  localparam MAXB = 256;           // 单包最大字节
  localparam CYC_MAX = 200000;     // 相内超时(拍)

  localparam ECHO  = 1'b1;
  localparam OTHER = 1'b0;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg rst = 1'b1;

  // ---------------- DUT ----------------
  reg  [W-1:0]  sdata  = 0;
  reg  [K-1:0]  skeep  = 0;
  reg           slast  = 0;
  reg           svalid = 0;
  reg  [96:0]   susr   = 97'h1_2345_6788;
  wire          sready;

  wire [W-1:0]  tx_data , oth_data ;
  wire [K-1:0]  tx_keep , oth_keep ;
  wire          tx_last , tx_valid, oth_last, oth_valid;
  wire [3:0]    tx_usr  ;
  wire [96:0]   oth_usr  ;
  reg           tx_ready  = 1'b1;
  reg           oth_ready = 1'b1;

  icmpv4_top #(
    .AXIS_USER_WIDTH  (4                ),
    .ARBITER_VAL      (12               )
  ) u_dut (
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .ipv4_icmp_axis_sdata (sdata        ),// (input)
    .ipv4_icmp_axis_skeep (skeep        ),// (input)
    .ipv4_icmp_axis_slast (slast        ),// (input)
    .ipv4_icmp_axis_svalid(svalid       ),// (input)
    .ipv4_icmp_axis_susr  (susr         ),// (input)
    .ipv4_icmp_axis_sready(sready       ),// (output)
    .ipv4_other_axis_mdata (oth_data    ),// (output)
    .ipv4_other_axis_mkeep (oth_keep    ),// (output)
    .ipv4_other_axis_mlast (oth_last    ),// (output)
    .ipv4_other_axis_mvalid(oth_valid   ),// (output)
    .ipv4_other_axis_musr  (oth_usr     ),// (output)
    .ipv4_other_axis_mready(oth_ready   ),// (input)
    .ipv4_icmp_tx_mdata  (tx_data       ),// (output)
    .ipv4_icmp_tx_mkeep  (tx_keep       ),// (output)
    .ipv4_icmp_tx_mlast  (tx_last       ),// (output)
    .ipv4_icmp_tx_mvalid (tx_valid      ),// (output)
    .ipv4_icmp_tx_musr   (tx_usr        ),// (output)
    .ipv4_icmp_tx_mready (tx_ready      ),// (input)
    // 本 TB 只测内部应答, 用户发送路(默认 1 路)恒 0
    .icmp_axis_sdata     (512'd0        ),// (input)
    .icmp_axis_skeep     (64'd0         ),// (input)
    .icmp_axis_slast     (1'b0          ),// (input)
    .icmp_axis_svalid    (1'b0          ),// (input)
    .icmp_axis_susr      (4'd0          ),// (input)
    .icmp_axis_sready    (              ),// (output)
    .stat_drop_pulse     (               ),// (output)
    .stat_drop_reason    (               ) // (output)
  );

  // ---------------- 包定义 ----------------
  integer   PLEN  [0:NP-1];          // 输入字节数
  integer   ROUTE [0:NP-1];          // ECHO / OTHER
  reg [7:0] pkt   [0:NP*MAXB-1];     // 包字节(p*MAXB + j)

  function [7:0] pay;
    input integer p;
    input integer j;
    begin pay = (8'h20 + p*13 + j) & 8'hFF; end
  endfunction

  localparam [31:0] SRC_IP = 32'hC0A80164;
  localparam [31:0] DST_IP = 32'hC0A801C8;

  task automatic mkpkt;
    input integer p;
    input integer nbytes;
    input [7:0]   typ;
    input [7:0]   cod;
    input [7:0]   flags;        // 0x40=DF ; 0x60=MF
    input [7:0]   fragoff;      // byte6 低 5 位 frag offset
    integer j;
    begin
      for (j = 0; j < nbytes; j = j + 1) pkt[p*MAXB+j] = pay(p, j);
      pkt[p*MAXB+ 0] = 8'h45;                     // ver=4 / IHL=5
      pkt[p*MAXB+ 1] = 8'h00;
      pkt[p*MAXB+ 2] = nbytes[15:8];              // total_len (大端)
      pkt[p*MAXB+ 3] = nbytes[7:0];
      pkt[p*MAXB+ 4] = 8'h00;                     // id
      pkt[p*MAXB+ 5] = 8'h01;
      pkt[p*MAXB+ 6] = flags | fragoff;           // flags + frag_off[12:8]
      pkt[p*MAXB+ 7] = 8'h00;                     // frag_off[7:0]
      pkt[p*MAXB+ 8] = 8'h40;                     // ttl
      pkt[p*MAXB+ 9] = 8'h01;                     // proto = icmp
      pkt[p*MAXB+10] = 8'h00;                     // hdr cksum
      pkt[p*MAXB+11] = 8'h00;
      pkt[p*MAXB+12] = SRC_IP[31:24];
      pkt[p*MAXB+13] = SRC_IP[23:16];
      pkt[p*MAXB+14] = SRC_IP[15:8];
      pkt[p*MAXB+15] = SRC_IP[7:0];
      pkt[p*MAXB+16] = DST_IP[31:24];
      pkt[p*MAXB+17] = DST_IP[23:16];
      pkt[p*MAXB+18] = DST_IP[15:8];
      pkt[p*MAXB+19] = DST_IP[7:0];
      pkt[p*MAXB+20] = typ;
      pkt[p*MAXB+21] = cod;
      pkt[p*MAXB+22] = 8'h00;                     // icmp cksum
      pkt[p*MAXB+23] = 8'h00;
      PLEN[p] = nbytes;
      $display("  [PKT %0d] len=%0dB type=%0d code=%0d flags=%02x fragoff=%02x -> %s",
               p, nbytes, typ, cod, flags, fragoff, (ROUTE[p]==ECHO) ? "ECHO->tx" : "OTHER->边界");
    end
  endtask

  // ---------------- 发送 ----------------
  task automatic send_pkt;
    input integer p;
    integer nb, jj, ii, b0;
    begin
      nb = (PLEN[p] + 63) / 64;
      for (jj = 0; jj < nb; jj = jj + 1) begin
        b0 = jj * 64;
        @(negedge clk);
        sdata = 0; skeep = 0;
        for (ii = 0; ii < 64; ii = ii + 1) begin
          if (b0 + ii < PLEN[p]) begin
            sdata[ii*8 +: 8] = pkt[p*MAXB + b0 + ii];
            skeep[ii] = 1'b1;
          end
        end
        slast  = (jj == nb-1);
        svalid = 1'b1;
        @(posedge clk);
        while (sready !== 1'b1) @(posedge clk);   // posedge 采拍前稳态
      end
      @(negedge clk);
      svalid = 1'b0; slast = 1'b0; sdata = 0; skeep = 0;
    end
  endtask

  // ---------------- 期望(仅 other 路逐字节) ----------------
  reg [7:0] exp_b [0:NP*MAXB-1];
  integer exp_wr = 0;
  integer exp_echo_pkt = 0;
  integer exp_oth_pkt  = 0;

  // ---------------- 收集 ----------------
  reg [7:0] oth_buf [0:NP*MAXB*2-1];
  integer oth_wr = 0, oth_pkt = 0;
  integer tx_pkt = 0;
  integer xcnt = 0;
  integer usr_bad = 0;
  integer tx_type_bad = 0;
  reg     tx_first  = 1'b1;
  reg     oth_first = 1'b1;
  reg [96:0] usr_exp = 97'h1_2345_6788;
  integer kk;

  always @(posedge clk) begin
    // ---- other 路 ----
    if (oth_valid === 1'b1 && oth_ready === 1'b1) begin
      if ((^oth_data) === 1'bx || (^oth_keep) === 1'bx || (^oth_usr) === 1'bx) xcnt = xcnt + 1;
      if (oth_first) begin
        if (oth_usr !== usr_exp) usr_bad = usr_bad + 1;
        oth_first = 1'b0;
      end
      for (kk = 0; kk < 64; kk = kk + 1) begin
        if (oth_keep[kk]) begin
          oth_buf[oth_wr] = oth_data[kk*8 +: 8];
          oth_wr = oth_wr + 1;
        end
      end
      if (oth_last === 1'b1) begin
        oth_pkt   = oth_pkt + 1;
        oth_first = 1'b1;
      end
    end
    // ---- echo 路(应答) ----
    if (tx_valid === 1'b1 && tx_ready === 1'b1) begin
      if ((^tx_data) === 1'bx || (^tx_keep) === 1'bx) xcnt = xcnt + 1;
      if (tx_first) begin
        if (tx_data[167:160] !== 8'h00) tx_type_bad = tx_type_bad + 1;  // 应答 type 应为 0
        tx_first = 1'b0;
      end
      if (tx_last === 1'b1) begin
        tx_pkt   = tx_pkt + 1;
        tx_first = 1'b1;
      end
    end
  end

  // ---------------- 反压 ----------------
  reg bp_en = 1'b0;
  always @(negedge clk) begin
    if (!rst && bp_en) begin
      tx_ready  <= ($random % 3) != 0;
      oth_ready <= ($random % 3) != 0;
    end
    else begin
      tx_ready  <= 1'b1;
      oth_ready <= 1'b1;
    end
  end

  // ---------------- 主流程 ----------------
  integer err = 0, i, j, pass, cyc;
  integer echo_total;

  initial begin
    // 包表(len / type / code / flags / fragoff / 期望路由)
    ROUTE[0] = ECHO;    // 标准 echo 请求
    ROUTE[1] = OTHER;   // 目的不可达
    ROUTE[2] = OTHER;   // type=8 但 code=1
    ROUTE[3] = OTHER;   // type=8 但 MF=1(分片)
    ROUTE[4] = ECHO;    // 2 拍 echo 请求
    ROUTE[5] = OTHER;   // 时间超时
    ROUTE[6] = OTHER;   // type=8 但 frag_off!=0

    mkpkt(0,  64, 8'h08, 8'h00, 8'h40, 8'h00);
    mkpkt(1,  64, 8'h03, 8'h01, 8'h40, 8'h00);
    mkpkt(2,  64, 8'h08, 8'h01, 8'h40, 8'h00);
    mkpkt(3,  64, 8'h08, 8'h00, 8'h60, 8'h00);
    mkpkt(4, 128, 8'h08, 8'h00, 8'h40, 8'h00);
    mkpkt(5,  64, 8'h0B, 8'h00, 8'h40, 8'h00);
    mkpkt(6,  64, 8'h08, 8'h00, 8'h40, 8'h01);

    echo_total = 0;
    for (j = 0; j < NP; j = j + 1) begin
      if (ROUTE[j] == ECHO) echo_total = echo_total + 1;
      else begin
        for (i = 0; i < PLEN[j]; i = i + 1) begin
          exp_b[exp_wr] = pkt[j*MAXB + i];
          exp_wr = exp_wr + 1;
        end
        exp_oth_pkt = exp_oth_pkt + 1;
      end
    end

    repeat (4) @(posedge clk);
    rst = 1'b0;
    repeat (2) @(posedge clk);

    for (pass = 0; pass < 2; pass = pass + 1) begin
      bp_en = (pass == 1);
      $display("---- PHASE %0d (%s) ----", pass, (pass == 0) ? "全速" : "随机反压");
      for (j = 0; j < NP; j = j + 1) send_pkt(j);

      // ---- 相内超时(按包数收敛) ----
      cyc = 0;
      while ((oth_pkt < exp_oth_pkt*(pass+1) || tx_pkt < echo_total*(pass+1)) && cyc < CYC_MAX) begin
        @(posedge clk);
        cyc = cyc + 1;
      end
      if (cyc >= CYC_MAX) begin
        $display("  [G-FAIL] phase%0d 相内超时: oth_pkt=%0d/%0d tx_pkt=%0d/%0d",
                 pass, oth_pkt, exp_oth_pkt*(pass+1), tx_pkt, echo_total*(pass+1));
        err = err + 1;
      end
      repeat (20) @(posedge clk);
    end
    bp_en = 1'b0;
    repeat (40) @(posedge clk);

    // ---- 结算 ----
    if (oth_pkt != exp_oth_pkt*2) begin
      $display("  [C-FAIL] other 包数 %0d != %0d", oth_pkt, exp_oth_pkt*2); err = err + 1;
    end
    if (tx_pkt != echo_total*2) begin
      $display("  [B-FAIL] echo 包数 %0d != %0d", tx_pkt, echo_total*2); err = err + 1;
    end
    if (oth_pkt + tx_pkt != NP*2) begin
      $display("  [D-FAIL] 互斥失败: 两路合计 %0d != %0d", oth_pkt + tx_pkt, NP*2); err = err + 1;
    end
    if (tx_type_bad != 0) begin
      $display("  [B-FAIL] echo 应答 type!=0 的包数 %0d", tx_type_bad); err = err + 1;
    end
    if (oth_wr != exp_wr*2) begin
      $display("  [C-FAIL] other 字节数 %0d != %0d", oth_wr, exp_wr*2); err = err + 1;
    end
    j = (oth_wr < exp_wr*2) ? oth_wr : exp_wr*2;
    for (i = 0; i < j; i = i + 1) begin
      if (oth_buf[i] !== exp_b[i % exp_wr]) begin
        if (err < 20) $display("  [A-FAIL] other byte%0d 实际=%02x 期望=%02x", i, oth_buf[i], exp_b[i % exp_wr]);
        err = err + 1;
      end
    end
    if (usr_bad != 0) begin
      $display("  [E-FAIL] usr 透传错误 %0d 次", usr_bad); err = err + 1;
    end
    if (xcnt != 0) begin
      $display("  [F-FAIL] 输出含 X 的拍数 %0d", xcnt); err = err + 1;
    end

    $display(" 统计: other=%0d 包 / %0d B ; echo(tx)=%0d 包 ; 发送=%0d 包", oth_pkt, oth_wr, tx_pkt, NP*2);
    if (err == 0) $display(" *** ALL ICMPv4_TOP CHECKS PASSED ***");
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
    $finish;
  end

  initial begin
    #5000000;
    $display(" FATAL: global timeout");
    $finish;
  end

endmodule
`resetall
