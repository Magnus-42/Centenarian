`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_icmpv4_top.sv
// Module Name : tb_icmpv4_top
// ----------------------------------------------------------------------------
// Description : 验证ICMPv4接收分流，以及业务发送与内部回显应答共用IPv4出口。
//   判定:
//     [A] other 路逐字节与输入一致(按 keep 重建), 顺序正确
//     [B] echo 应答逐字节核对地址交换、类型、校验和与载荷，检查 keep/last/优先级
//     [C] other 路包数/字节数正确
//     [D] 互斥: 两路包数之和 == 发送包数(同一包不得两路都有)
//     [E] usr 透传一致
//     [F] 输出无 X
//     [G] 相内超时打 [FAIL]
//     [H] 业务发送保留原始数据、优先级、keep和last，并与回显应答互不干扰
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
  localparam [3:0] EchoPriority = 4'd12;
  localparam [3:0] UserPriority = 4'd5;
  // 72字节IPv4包，携带有效校验和的ICMPv4 Echo Reply。
  localparam [511:0] UserFirstBeat =
      512'h38b8_0000_c801_a8c0_6401_a8c0_38b6_0140_0040_0000_4800_0045;
  localparam [511:0] UserLastBeat = 512'h1234_5678_90ab_cdef;

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

  reg  [511:0] user_data  = 512'd0;
  reg  [ 63:0] user_keep  = 64'd0;
  reg          user_last  = 1'b0;
  reg          user_valid = 1'b0;
  wire         user_ready;

  icmpv4_top u_dut (
    .clk(clk),
    .rst(rst),
    .cfg_arbiter_value(EchoPriority),
    .cfg_clear_error(1'b0),
    .rx_axis_sdata(sdata),
    .rx_axis_skeep(skeep),
    .rx_axis_slast(slast),
    .rx_axis_svalid(svalid),
    .rx_axis_susr(susr),
    .rx_axis_sready(sready),
    .other_axis_mdata(oth_data),
    .other_axis_mkeep(oth_keep),
    .other_axis_mlast(oth_last),
    .other_axis_mvalid(oth_valid),
    .other_axis_musr(oth_usr),
    .other_axis_mready(oth_ready),
    .tx_axis_sdata(user_data),
    .tx_axis_skeep(user_keep),
    .tx_axis_slast(user_last),
    .tx_axis_svalid(user_valid),
    .tx_axis_susr(UserPriority),
    .tx_axis_sready(user_ready),
    .tx_axis_mdata(tx_data),
    .tx_axis_mkeep(tx_keep),
    .tx_axis_mlast(tx_last),
    .tx_axis_mvalid(tx_valid),
    .tx_axis_musr(tx_usr),
    .tx_axis_mready(tx_ready),
    .stat_ttl_error()
  );

  reg tx_stalled = 0, oth_stalled = 0;
  reg [580:0] tx_held;
  reg [673:0] oth_held;
  always @(posedge clk) begin
    if (rst) begin tx_stalled = 0; oth_stalled = 0; end
    else begin
      if (tx_stalled && (tx_valid !== 1'b1 || {tx_data,tx_keep,tx_usr,tx_last} !== tx_held))
        $fatal(1, "ICMP TX changed under backpressure");
      if (oth_stalled && (oth_valid !== 1'b1 || {oth_data,oth_keep,oth_usr,oth_last} !== oth_held))
        $fatal(1, "ICMP other changed under backpressure");
      tx_stalled = tx_valid && !tx_ready; oth_stalled = oth_valid && !oth_ready;
      tx_held = {tx_data,tx_keep,tx_usr,tx_last}; oth_held = {oth_data,oth_keep,oth_usr,oth_last};
    end
  end

  // ---------------- 包定义 ----------------
  integer   PLEN  [0:NP-1];          // 输入字节数
  integer   ROUTE [0:NP-1];          // ECHO / OTHER
  reg [7:0] pkt   [0:NP*MAXB-1];
  reg [7:0] echo_expected[0:NP*MAXB-1];     // 包字节(p*MAXB + j)

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
      begin : checksum_reference
        integer unsigned sum;
        reg [15:0] checksum;
        sum = 0;
        for (integer k = 20; k < nbytes; k += 2)
          sum += {pkt[p*MAXB+k], (k+1<nbytes) ? pkt[p*MAXB+k+1] : 8'd0};
        while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
        checksum = ~sum[15:0];
        pkt[p*MAXB+22] = checksum[15:8]; pkt[p*MAXB+23] = checksum[7:0];
        sum = 0;
        for (integer k = 0; k < 20; k += 2) sum += {pkt[p*MAXB+k],pkt[p*MAXB+k+1]};
        while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
        checksum = ~sum[15:0];
        pkt[p*MAXB+10] = checksum[15:8]; pkt[p*MAXB+11] = checksum[7:0];
        for (integer k = 0; k < nbytes; k++) echo_expected[p*MAXB+k] = pkt[p*MAXB+k];
        for (integer k = 0; k < 4; k++) begin
          echo_expected[p*MAXB+12+k] = pkt[p*MAXB+16+k];
          echo_expected[p*MAXB+16+k] = pkt[p*MAXB+12+k];
        end
        echo_expected[p*MAXB+20] = 0; echo_expected[p*MAXB+21] = 0;
        echo_expected[p*MAXB+22] = 0; echo_expected[p*MAXB+23] = 0;
        sum = 0;
        for (integer k = 20; k < nbytes; k += 2)
          sum += {echo_expected[p*MAXB+k],(k+1<nbytes) ? echo_expected[p*MAXB+k+1] : 8'd0};
        while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
        checksum = ~sum[15:0];
        echo_expected[p*MAXB+22] = checksum[15:8]; echo_expected[p*MAXB+23] = checksum[7:0];
      end
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

  task automatic send_user_pkt;
    integer beat;
    begin
      for (beat = 0; beat < 2; beat = beat + 1) begin
        @(negedge clk);
        user_data  = (beat == 0) ? UserFirstBeat : UserLastBeat;
        user_keep  = (beat == 0) ? 64'hffff_ffff_ffff_ffff : 64'hff;
        user_last  = (beat == 1);
        user_valid = 1'b1;
        @(posedge clk);
        while (user_ready !== 1'b1) @(posedge clk);
      end
      @(negedge clk);
      user_valid = 1'b0;
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
  integer user_tx_pkt = 0;
  integer user_tx_bad = 0;
  integer xcnt = 0;
  integer usr_bad = 0;
  reg     tx_first  = 1'b1;
  reg [3:0] tx_packet_priority;
  reg     oth_first = 1'b1;
  reg [96:0] usr_exp = 97'h1_2345_6788;
  integer kk;
  integer echo_offset = 0, echo_index;

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
    // ---- IPv4发送出口 ----
    if (tx_valid === 1'b1 && tx_ready === 1'b1) begin
      if ((^tx_data) === 1'bx || (^tx_keep) === 1'bx || (^tx_usr) === 1'bx) xcnt = xcnt + 1;
      if (tx_first) tx_packet_priority = tx_usr;
      else if (tx_usr !== tx_packet_priority) user_tx_bad = user_tx_bad + 1;

      if (tx_packet_priority == UserPriority) begin
        if (tx_data !== (tx_first ? UserFirstBeat : UserLastBeat) ||
            tx_keep !== (tx_first ? 64'hffff_ffff_ffff_ffff : 64'hff) ||
            tx_last !== !tx_first) user_tx_bad = user_tx_bad + 1;
        if (tx_last) user_tx_pkt = user_tx_pkt + 1;
      end else begin
        echo_index = (tx_pkt % 2 == 0) ? 0 : 4;
        if (tx_usr !== EchoPriority) $fatal(1, "ICMP echo priority mismatch");
        for (integer lane = 0; lane < 64; lane++) begin
          if (tx_keep[lane] !== (echo_offset + lane < PLEN[echo_index]))
            $fatal(1, "ICMP echo keep mismatch");
          if (tx_keep[lane] && tx_data[lane*8+:8] !== echo_expected[echo_index*MAXB+echo_offset+lane])
            $fatal(1, "ICMP echo byte/checksum mismatch, packet=%0d byte=%0d", tx_pkt, echo_offset+lane);
        end
        if (tx_last !== (echo_offset + 64 >= PLEN[echo_index])) $fatal(1, "ICMP echo last mismatch");
        echo_offset += 64;
        if (tx_last) begin tx_pkt++; echo_offset = 0; end
      end
      tx_first = tx_last;
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

    repeat (4) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(posedge clk);

    for (pass = 0; pass < 2; pass = pass + 1) begin
      bp_en = (pass == 1);
      $display("---- PHASE %0d (%s) ----", pass, (pass == 0) ? "全速" : "随机反压");
      fork
        send_user_pkt();
        begin
          for (j = 0; j < NP; j = j + 1) send_pkt(j);
        end
      join

      // ---- 相内超时(按包数收敛) ----
      cyc = 0;
      while ((oth_pkt < exp_oth_pkt*(pass+1) || tx_pkt < echo_total*(pass+1) ||
              user_tx_pkt < pass+1) && cyc < CYC_MAX) begin
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
    if (user_tx_pkt != 2 || user_tx_bad != 0) begin
      $display("  [H-FAIL] 业务发送: 包数=%0d/2, 错误=%0d", user_tx_pkt, user_tx_bad);
      err = err + 1;
    end

    $display(" 统计: other=%0d 包 / %0d B, echo(tx)=%0d 包, user(tx)=%0d 包",
             oth_pkt, oth_wr, tx_pkt, user_tx_pkt);
    if (err == 0) $display("PASS: tb_icmpv4_top");
    else          $fatal(1, " *** %0d CHECK(S) FAILED ***", err);
    $finish;
  end

  initial begin
    #5000000;
    $fatal(1, " FATAL: global timeout");
  end

endmodule
`resetall
