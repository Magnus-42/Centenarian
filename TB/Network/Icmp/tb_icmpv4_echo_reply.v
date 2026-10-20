`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_icmpv4_echo_reply.v
// Module Name : tb_icmpv4_echo_reply
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-10-17
// ----------------------------------------------------------------------------
// Description : icmpv4_echo_reply 自测（回显应答黄金比对 + 丢弃防御）
//
// 模块语义(与 RTL 一致)：
//   - 输入完整 IPv4 包(demux 后的 echo 通道), usr[0] = MAC 错误标志(1=错)
//   - 应答: 交换 src/dst IP, ICMP type 8->0, ICMP 校验和 +8, TTL 继承, IPv4 校验和不变
//   - 输出 usr = ARBITER_VAL(12)
//   - 丢弃: TTL=0 / MAC 错 / 非 echo(防御) -> stat_drop_pulse + 3bit 原因
//
// 用例：
//   T1 合法 echo(2 拍)   -> 黄金应答逐字节, musr==12, 无 drop
//   T2 TTL=0             -> drop (reason[0])
//   T3 MAC 错(usr[0]=1)  -> drop (reason[1])
//   T4 type!=8(防御)     -> drop (reason[2])
//   T5 单拍 echo         -> 黄金应答(首拍即 last)
//   T6 背靠背 合法+drop 交错 -> 合法有应答, drop 无输出, 不串包
// ============================================================================
module tb_icmpv4_echo_reply;

  localparam W  = 512;
  localparam K  = 64;
  localparam UW = 4;

  reg               clk = 1'b0;
  reg               rst = 1'b1;
  always #5 clk = ~clk;

  reg  [W-1:0]      sdata ;
  reg  [K-1:0]      skeep ;
  reg               slast ;
  reg               svalid;
  wire              sready;
  reg  [96:0]       susr  = 97'd0;   // [0]=MAC 错

  wire [W-1:0]      mdata ;
  wire [K-1:0]      mkeep ;
  wire              mlast ;
  wire              mvalid;
  wire [UW-1:0]     musr  ;
  reg               mready = 1'b1;
  wire              drop_pulse;
  wire [2:0]        drop_reason;

  icmpv4_echo_reply #(.AXIS_USER_WIDTH(UW), .ARBITER_VAL(12)) u_dut (
    .clk(clk), .rst(rst),
    .ipv4_axis_sdata(sdata), .ipv4_axis_skeep(skeep), .ipv4_axis_slast(slast),
    .ipv4_axis_svalid(svalid), .ipv4_axis_susr(susr), .ipv4_axis_sready(sready),
    .ipv4_axis_mdata(mdata), .ipv4_axis_mkeep(mkeep), .ipv4_axis_mlast(mlast),
    .ipv4_axis_mvalid(mvalid), .ipv4_axis_musr(musr), .ipv4_axis_mready(mready),
    .stat_drop_pulse(drop_pulse), .stat_drop_reason(drop_reason)
  );

  // ---------------- 发送队列 ----------------
  localparam QN = 256;
  reg [W-1:0] sq_data [0:QN-1];
  reg [K-1:0] sq_keep [0:QN-1];
  reg         sq_last [0:QN-1];
  reg [96:0]  sq_usr  [0:QN-1];
  integer     sq_wr, sq_rd;

  always @(negedge clk) begin
    if (!rst && svalid === 1'b0 && sq_rd < sq_wr) begin
      sdata  <= sq_data[sq_rd];
      skeep  <= sq_keep[sq_rd];
      slast  <= sq_last[sq_rd];
      susr   <= sq_usr [sq_rd];
      svalid <= 1'b1;
      sq_rd  = sq_rd + 1;
    end
  end
  always @(posedge clk) begin
    if (rst) svalid <= 1'b0;
    else if (svalid === 1'b1 && sready === 1'b1) svalid <= 1'b0;
  end

  // ---------------- 期望队列(黄金应答) ----------------
  reg [W-1:0] eq_data [0:QN-1];
  reg [K-1:0] eq_keep [0:QN-1];
  reg         eq_last [0:QN-1];
  integer     e_wr, e_rd, got;
  integer     err, perr;

  function [15:0] fold8; input [15:0] x; reg [16:0] f; reg [16:0] g;
    begin f = {1'b0, x} + 17'h0008; g = {1'b0, f[15:0]} + {16'd0, f[16]}; fold8 = g[15:0]; end
  endfunction

  // 构造 echo 请求帧(首拍 64B 全有效 + 可选末拍), 若 legal 则同时生成黄金应答
  task automatic push_echo(input [7:0] ttl, input [7:0] itype, input [7:0] icode,
                           input err, input [7:0] tag, input integer len2, input integer legal);
    integer i, b, v, L, nb;
    reg [W-1:0] d;
    reg [K-1:0] k;
    reg [7:0]   fb [0:127];
    reg [W-1:0] gold;
    begin
      for (i = 0; i < 128; i = i + 1) fb[i] = 8'h00;
      fb[0]  = 8'h45;                // version=4, IHL=5
      fb[1]  = 8'h00;                // TOS
      fb[2]  = 8'h00; fb[3] = 8'h50; // total_len = 80 (网络序, 0x0050)
      fb[4]  = 8'h00; fb[5] = 8'h01; // id
      fb[6]  = 8'h40; fb[7] = 8'h00; // DF=1, frag=0
      fb[8]  = ttl;                  // TTL
      fb[9]  = 8'h01;                // protocol = ICMP
      fb[10] = 8'h00; fb[11] = 8'h00;// ip header checksum
      fb[12] = 8'hC0; fb[13] = 8'hA8; fb[14] = 8'h01; fb[15] = 8'h64; // src 192.168.1.100
      fb[16] = 8'hC0; fb[17] = 8'hA8; fb[18] = 8'h01; fb[19] = 8'hC8; // dst 192.168.1.200
      fb[20] = itype; fb[21] = icode;
      fb[22] = 8'h12; fb[23] = 8'h34; // icmp checksum (线序值 16'h3412)
      fb[24] = 8'h00; fb[25] = 8'h01; // identifier
      fb[26] = 8'h00; fb[27] = 8'h01; // sequence
      for (i = 0; i < 36; i = i + 1) fb[28+i] = tag + i[7:0];
      L = 64 + len2;
      for (i = 0; i < len2; i = i + 1) fb[64+i] = 8'hE0 + i[7:0];
      nb = (len2 == 0) ? 1 : 2;

      for (b = 0; b < nb; b = b + 1) begin
        d = {W{1'b0}}; k = {K{1'b0}};
        for (v = 0; v < 64; v = v + 1)
          if (64*b + v < L) begin d[v*8 +: 8] = fb[64*b + v]; k[v] = 1'b1; end
        sq_data[sq_wr] = d; sq_keep[sq_wr] = k; sq_last[sq_wr] = (b == nb-1);
        sq_usr[sq_wr] = 97'd0; sq_usr[sq_wr][0] = err;
        sq_wr = sq_wr + 1;

        if (legal) begin
          if (b == 0) begin
            // 交换 src/dst, type 8->0, checksum +8, 其余不变
            gold = {d[511:192], fold8(d[191:176]), 16'h0000, d[127:96], d[159:128], d[95:0]};
          end
          else begin
            gold = d;
          end
          eq_data[e_wr] = gold; eq_keep[e_wr] = k; eq_last[e_wr] = (b == nb-1);
          e_wr = e_wr + 1;
        end
      end
    end
  endtask

  // ---------------- 输出比对 ----------------
  always @(posedge clk) begin
    if (!rst && mvalid === 1'b1 && mready === 1'b1) begin
      got = got + 1;
      if (e_rd >= e_wr) begin
        if (perr < 8) $display("  [FAIL] beat #%0d 无期望 -> 重复/多发", got);
        perr = perr + 1; err = err + 1;
      end
      else begin
        if (mkeep !== eq_keep[e_rd]) begin
          if (perr < 8) $display("  [FAIL] beat #%0d keep: got %h exp %h", got, mkeep, eq_keep[e_rd]);
          perr = perr + 1; err = err + 1;
        end
        if (mdata !== eq_data[e_rd]) begin
          if (perr < 8) $display("  [FAIL] beat #%0d data 不符: got[159:0]=%040x exp[159:0]=%040x",
                                 got, mdata[159:0], eq_data[e_rd][159:0]);
          perr = perr + 1; err = err + 1;
        end
        if (mlast !== eq_last[e_rd]) begin
          if (perr < 8) $display("  [FAIL] beat #%0d last: got %b exp %b", got, mlast, eq_last[e_rd]);
          perr = perr + 1; err = err + 1;
        end
        if (musr !== 4'd12) begin
          if (perr < 8) $display("  [FAIL] beat #%0d musr: got %0d exp 12", got, musr);
          perr = perr + 1; err = err + 1;
        end
        e_rd = e_rd + 1;
      end
    end
  end

  // drop 累计监测
  integer drop_cnt = 0;
  reg [2:0] last_reason = 0;
  always @(posedge clk) begin
    if (!rst && drop_pulse === 1'b1) begin
      drop_cnt = drop_cnt + 1;
      last_reason = drop_reason;
    end
  end

  task automatic cyc(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
  endtask

  integer base, prev_got, prev_drop;
  initial begin
    $display("================================================================");
    $display(" tb_icmpv4_echo_reply");
    $display("================================================================");
    err=0; perr=0; sq_wr=0; sq_rd=0; e_wr=0; e_rd=0; got=0; drop_cnt=0;
    sdata=0; skeep=0; slast=0; svalid=0; mready=1'b1;
    rst=1'b1; cyc(6); rst=1'b0; cyc(2);

    // ---- T1: 合法 echo(2 拍) -> 黄金应答 ----
    $display("--- T1: legal echo request (2 beats) ---");
    prev_got = got; prev_drop = drop_cnt;
    push_echo(8'h40, 8'h08, 8'h00, 0, 8'h11, 16, 1); cyc(80);
    if (got - prev_got != 2) begin $display("  [FAIL] 应出 2 拍, 实得 %0d", got - prev_got); err = err + 1; end
    else if (drop_cnt != prev_drop) begin $display("  [FAIL] 合法包不应 drop"); err = err + 1; end
    else $display("  [PASS] 2 拍黄金应答, musr=12, 无 drop");

    // ---- T2: TTL=0 -> drop ----
    $display("--- T2: TTL=0 -> drop ---");
    prev_got = got; prev_drop = drop_cnt;
    push_echo(8'h00, 8'h08, 8'h00, 0, 8'h22, 16, 0); cyc(80);
    if (got != prev_got) begin $display("  [FAIL] TTL=0 不应有输出"); err = err + 1; end
    else if (drop_cnt - prev_drop != 1) begin $display("  [FAIL] 应 drop 1 次, 实得 %0d", drop_cnt - prev_drop); err = err + 1; end
    else if (last_reason !== 3'b001) begin $display("  [FAIL] reason 应 001(TTL=0), 实得 %b", last_reason); err = err + 1; end
    else $display("  [PASS] drop 1 次, reason[0](TTL=0)");

    // ---- T3: MAC 错(usr[0]=1) -> drop ----
    $display("--- T3: MAC error (usr[0]=1) -> drop ---");
    prev_got = got; prev_drop = drop_cnt;
    push_echo(8'h40, 8'h08, 8'h00, 1, 8'h33, 16, 0); cyc(80);
    if (got != prev_got) begin $display("  [FAIL] MAC 错不应有输出"); err = err + 1; end
    else if (drop_cnt - prev_drop != 1) begin $display("  [FAIL] 应 drop 1 次, 实得 %0d", drop_cnt - prev_drop); err = err + 1; end
    else if (last_reason !== 3'b010) begin $display("  [FAIL] reason 应 010(MAC错), 实得 %b", last_reason); err = err + 1; end
    else $display("  [PASS] drop 1 次, reason[1](MAC 错)");

    // ---- T4: type!=8 防御 -> drop ----
    $display("--- T4: type!=8 (defensive) -> drop ---");
    prev_got = got; prev_drop = drop_cnt;
    push_echo(8'h40, 8'h00, 8'h00, 0, 8'h44, 16, 0); cyc(80);
    if (got != prev_got) begin $display("  [FAIL] 非 echo 不应有输出"); err = err + 1; end
    else if (drop_cnt - prev_drop != 1) begin $display("  [FAIL] 应 drop 1 次, 实得 %0d", drop_cnt - prev_drop); err = err + 1; end
    else if (last_reason !== 3'b100) begin $display("  [FAIL] reason 应 100(非echo), 实得 %b", last_reason); err = err + 1; end
    else $display("  [PASS] drop 1 次, reason[2](非 echo)");

    // ---- T5: 单拍 echo -> 黄金应答 ----
    $display("--- T5: single-beat echo request ---");
    prev_got = got; prev_drop = drop_cnt;
    push_echo(8'h40, 8'h08, 8'h00, 0, 8'h55, 0, 1); cyc(80);
    if (got - prev_got != 1) begin $display("  [FAIL] 应出 1 拍, 实得 %0d", got - prev_got); err = err + 1; end
    else if (drop_cnt != prev_drop) begin $display("  [FAIL] 合法包不应 drop"); err = err + 1; end
    else $display("  [PASS] 1 拍黄金应答");

    // ---- T6: 背靠背 合法+drop 交错 ----
    $display("--- T6: back-to-back legal + drop interleave ---");
    prev_got = got; prev_drop = drop_cnt;
    push_echo(8'h40, 8'h08, 8'h00, 0, 8'h61, 16, 1);   // 合法
    push_echo(8'h00, 8'h08, 8'h00, 0, 8'h62, 16, 0);   // TTL=0 drop
    push_echo(8'h40, 8'h08, 8'h00, 0, 8'h63, 16, 1);   // 合法
    push_echo(8'h40, 8'h08, 8'h00, 1, 8'h64, 16, 0);   // MAC 错 drop
    cyc(160);
    if (got - prev_got != 4) begin $display("  [FAIL] 应出 4 拍(2 合法包), 实得 %0d", got - prev_got); err = err + 1; end
    else if (drop_cnt - prev_drop != 2) begin $display("  [FAIL] 应 drop 2 次, 实得 %0d", drop_cnt - prev_drop); err = err + 1; end
    else $display("  [PASS] 2 合法包各 2 拍 + 2 次 drop, 不串包");
    cyc(20);

    $display("================================================================");
    $display(" 输出拍 %0d / 期望 %0d, drop %0d 次, err=%0d", got, e_wr, drop_cnt, err);
    if (err == 0 && got == e_wr) $display(" *** ALL TESTS PASSED ***");
    else                          $display(" *** %0d CHECK(S) FAILED ***", err + ((got != e_wr) ? 1 : 0));
    $display("================================================================");
    $finish;
  end

  initial begin
    #200_000;
    $display("[%0t] [FAIL] FATAL: timeout", $time);
    $finish;
  end

endmodule
`resetall
