`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_ipv4_eth_rx.v
// Module Name : tb_ipv4_eth_rx
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-09-19
// ----------------------------------------------------------------------------
// Description : ipv4_eth_rx 自测（剥掉 14 字节以太头，输出纯 IPv4 包）
//   约定: 帧 byte k = bus[8k+7:8k]; keep 为低对齐连续掩码
//   期望模型(与实现无关):
//     输入帧 = 目的MAC(6)+源MAC(6)+EtherType(2) + 载荷(N 字节)
//     输出   = 载荷按 64 字节/拍切分, keep=该拍有效字节数(低对齐), 末拍 last=1
//     同时 dest_mac/src_mac 应与该帧一致(首拍对齐)
//   用例:
//     T1 短帧: 14+46=60B  (载荷 46B, 单拍出) —— 边界: 帧长=最小帧长
//     T2 长帧: 14+100=114B(载荷 100B, 2 拍出) —— 关键: 跨拍 carry
//     T3 边界: 14+50=64B  (载荷 50B, 恰好占满首拍, 不应多出空拍)
//     T4 长帧+反压: 不丢不重
// ============================================================================

module tb_ipv4_eth_rx;

  localparam W = 512;
  localparam K = 64;

  reg               clk = 1'b0;
  reg               rst = 1'b1;
  always #5 clk = ~clk;

  reg  [W-1:0]      eth_ipv4_axis_mdata ;
  reg  [K-1:0]      eth_ipv4_axis_mkeep ;
  reg               eth_ipv4_axis_mlast ;
  reg               eth_ipv4_axis_mvalid;
  wire              eth_ipv4_axis_mready;

  wire [W-1:0]      ipv4_axis_mdata ;
  wire [K-1:0]      ipv4_axis_mkeep ;
  wire              ipv4_axis_mlast ;
  wire              ipv4_axis_mvalid;
  reg               ipv4_axis_mready;

  wire [47:0]       dest_mac;
  wire [47:0]       src_mac ;

  // 线序写法: 线上 01 02 03 04 05 06 => 48'h060504030201
  localparam [47:0] DST_MAC = 48'h0605_0403_0201;
  localparam [47:0] SRC_MAC = 48'h0c0b_0a09_0807;

  ipv4_eth_rx u_dut (
    .clk                  (clk                  ),
    .rst                  (rst                  ),
    .eth_ipv4_axis_sdata  (eth_ipv4_axis_mdata  ),
    .eth_ipv4_axis_skeep  (eth_ipv4_axis_mkeep  ),
    .eth_ipv4_axis_slast  (eth_ipv4_axis_mlast  ),
    .eth_ipv4_axis_svalid (eth_ipv4_axis_mvalid ),
    .eth_ipv4_axis_susr   (1'b0                 ),
    .eth_ipv4_axis_sready (eth_ipv4_axis_mready ),
    .ipv4_axis_mdata      (ipv4_axis_mdata      ),
    .ipv4_axis_mkeep      (ipv4_axis_mkeep      ),
    .ipv4_axis_mlast      (ipv4_axis_mlast      ),
    .ipv4_axis_mvalid     (ipv4_axis_mvalid     ),
    .ipv4_axis_musr       (                    ),
    .ipv4_axis_mready     (ipv4_axis_mready     ),
    .dest_mac             (dest_mac             ),
    .src_mac              (src_mac              )
  );

  reg t5_trace;
  initial t5_trace = 1'b0;
  always @(posedge clk) begin
    if (t5_trace)
      $display("    [TRC] t=%0t inv=%b s1v=%b s1last=%b mval=%b do=%b outB50=%02h outB63=%02h inbusLow=%04h s1hiB50=%02h",
        $time, eth_ipv4_axis_mvalid, u_dut.eth_ipv4_axis_svalid_s1, u_dut.eth_ipv4_axis_slast_s1,
        ipv4_axis_mvalid, ipv4_axis_mready,
        ipv4_axis_mdata[407:400], ipv4_axis_mdata[511:504],
        eth_ipv4_axis_mdata[13:0], u_dut.eth_ipv4_axis_sdata_s1[407:400]);
  end

  // ---------------- 发送队列 ----------------
  localparam QN = 128;
  reg [W-1:0] sq_data [0:QN-1];
  reg [K-1:0] sq_keep [0:QN-1];
  reg         sq_last [0:QN-1];
  integer     sq_wr, sq_rd;

  always @(negedge clk) begin
    if (!rst && eth_ipv4_axis_mvalid === 1'b0 && sq_rd < sq_wr) begin
      eth_ipv4_axis_mdata  <= sq_data[sq_rd];
      eth_ipv4_axis_mkeep  <= sq_keep[sq_rd];
      eth_ipv4_axis_mlast  <= sq_last[sq_rd];
      eth_ipv4_axis_mvalid <= 1'b1;
      sq_rd = sq_rd + 1;
    end
  end
  always @(posedge clk) begin
    if (rst) eth_ipv4_axis_mvalid <= 1'b0;
    else if (eth_ipv4_axis_mvalid === 1'b1 && eth_ipv4_axis_mready === 1'b1) eth_ipv4_axis_mvalid <= 1'b0;
  end

  // ---------------- 期望队列 ----------------
  reg [W-1:0] e_data [0:QN-1];
  reg [K-1:0] e_keep [0:QN-1];
  reg         e_last [0:QN-1];
  integer     e_wr, e_rd;

  integer got_cnt, err, perr;
  reg [W-1:0] md;
  reg [K-1:0] mk;
  integer     first_exp, err_before;

  // 逐字节掩码(512bit): mask[i*8 +: 8] = 8 个 e_keep[i]  —— 之前写成 64bit 会被零扩展, 只比对低 8 字节!
  wire [W-1:0] exp_mask;
  genvar gk;
  generate for (gk = 0; gk < 64; gk = gk + 1)
    assign exp_mask[gk*8 +: 8] = {8{e_keep[e_rd][gk]}};
  endgenerate

  always @(posedge clk) begin
    if (!rst && ipv4_axis_mvalid === 1'b1 && ipv4_axis_mready === 1'b1) begin
      got_cnt = got_cnt + 1;
      md = ipv4_axis_mdata; mk = ipv4_axis_mkeep;
      if (e_rd >= e_wr) begin
        if (perr < 8) $display("  [FAIL] beat #%0d 无期望 -> 多发", got_cnt);
        perr = perr + 1; err = err + 1;
      end
      else begin
        if (mk !== e_keep[e_rd]) begin
          if (perr < 8) $display("  [FAIL] beat #%0d keep: got %h exp %h", got_cnt, mk, e_keep[e_rd]);
          perr = perr + 1; err = err + 1;
        end
        if ((md & exp_mask) !== (e_data[e_rd] & exp_mask)) begin
          if (perr < 8) $display("  [FAIL] beat #%0d data: got %h exp %h byte50..=%02h/%02h",
                                 got_cnt, md[447:384], e_data[e_rd][447:384], md[407:400], e_data[e_rd][407:400]);
          perr = perr + 1; err = err + 1;
        end
        if (ipv4_axis_mlast !== e_last[e_rd]) begin
          if (perr < 8) $display("  [FAIL] beat #%0d last: got %b exp %b", got_cnt, ipv4_axis_mlast, e_last[e_rd]);
          perr = perr + 1; err = err + 1;
        end
        if (first_exp) begin
          if (dest_mac !== DST_MAC || src_mac !== SRC_MAC) begin
            if (perr < 8) $display("  [FAIL] 首拍 MAC 错: dest=%012h src=%012h", dest_mac, src_mac);
            perr = perr + 1; err = err + 1;
          end
          first_exp = 0;
        end
        e_rd = e_rd + 1;
      end
    end
  end

  // 造帧并生成期望: 载荷 npay 字节, 内容 tag+i
  task automatic push_frame(input [7:0] tag, input integer npay);
    integer i, b, v, L, nb, ne;
    reg [W-1:0] d; reg [K-1:0] k;
    reg [7:0] fb [0:255];
    reg [7:0] pb [0:255];
    begin
      for (i = 0; i < 256; i = i + 1) begin fb[i] = 8'h00; pb[i] = 8'h00; end
      for (i = 0; i < 6; i = i + 1)  fb[i]   = DST_MAC[8*i +: 8];
      for (i = 0; i < 6; i = i + 1)  fb[6+i] = SRC_MAC[8*i +: 8];
      fb[12] = 8'h08; fb[13] = 8'h00;                       // EtherType 08 00 (IPv4, 线序)
      for (i = 0; i < npay; i = i + 1) begin
        pb[i] = tag + i[7:0];
        fb[14+i] = pb[i];
      end
      L  = 14 + npay;
      nb = (L + 63) / 64;
      // 输入拍
      for (b = 0; b < nb; b = b + 1) begin
        d = {W{1'b0}}; k = {K{1'b0}};
        for (v = 0; v < 64; v = v + 1)
          if (64*b + v < L) begin d[v*8 +: 8] = fb[64*b + v]; k[v] = 1'b1; end
        sq_data[sq_wr] = d; sq_keep[sq_wr] = k; sq_last[sq_wr] = (b == nb-1);
        sq_wr = sq_wr + 1;
      end
      // 期望输出拍 = 载荷切分
      ne = (npay + 63) / 64;
      for (b = 0; b < ne; b = b + 1) begin
        d = {W{1'b0}}; k = {K{1'b0}};
        for (v = 0; v < 64; v = v + 1)
          if (64*b + v < npay) begin d[v*8 +: 8] = pb[64*b + v]; k[v] = 1'b1; end
        e_data[e_wr] = d; e_keep[e_wr] = k; e_last[e_wr] = (b == ne-1);
        e_wr = e_wr + 1;
      end
      first_exp = 1;
    end
  endtask

  // 帧内带气泡地送一帧: 送完前 split_after 拍后停 gap_cyc 拍再送其余
  task automatic push_frame_gap(input [7:0] tag, input integer npay, input integer split_after);
    integer i, b, v, L, nb, ne;
    reg [W-1:0] d; reg [K-1:0] k;
    reg [7:0] fb [0:255];
    reg [7:0] pb [0:255];
    begin
      for (i = 0; i < 256; i = i + 1) begin fb[i] = 8'h00; pb[i] = 8'h00; end
      for (i = 0; i < 6; i = i + 1)  fb[i]   = DST_MAC[8*i +: 8];
      for (i = 0; i < 6; i = i + 1)  fb[6+i] = SRC_MAC[8*i +: 8];
      fb[12] = 8'h08; fb[13] = 8'h00;
      for (i = 0; i < npay; i = i + 1) begin pb[i] = tag + i[7:0]; fb[14+i] = pb[i]; end
      L  = 14 + npay;  nb = (L + 63) / 64;
      for (b = 0; b < nb; b = b + 1) begin
        d = {W{1'b0}}; k = {K{1'b0}};
        for (v = 0; v < 64; v = v + 1)
          if (64*b + v < L) begin d[v*8 +: 8] = fb[64*b + v]; k[v] = 1'b1; end
        sq_data[sq_wr] = d; sq_keep[sq_wr] = k; sq_last[sq_wr] = (b == nb-1);
        sq_wr = sq_wr + 1;
        if (b == split_after-1) cyc(3);        // 帧内插 3 拍气泡(队列空 => 输入 valid=0)
      end
      ne = (npay + 63) / 64;
      for (b = 0; b < ne; b = b + 1) begin
        d = {W{1'b0}}; k = {K{1'b0}};
        for (v = 0; v < 64; v = v + 1)
          if (64*b + v < npay) begin d[v*8 +: 8] = pb[64*b + v]; k[v] = 1'b1; end
        e_data[e_wr] = d; e_keep[e_wr] = k; e_last[e_wr] = (b == ne-1);
        e_wr = e_wr + 1;
      end
      first_exp = 1;
    end
  endtask

  task automatic cyc(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
  endtask

  task automatic set_mready(input v);
    begin @(negedge clk); ipv4_axis_mready <= v; end
  endtask

  integer base;
  initial begin
    $display("================================================================");
    $display(" tb_ipv4_eth_rx");
    $display("================================================================");
    err=0; err_before=0; perr=0; got_cnt=0; sq_wr=0; sq_rd=0; e_wr=0; e_rd=0; first_exp=0;
    eth_ipv4_axis_mdata=0; eth_ipv4_axis_mkeep=0; eth_ipv4_axis_mlast=0; eth_ipv4_axis_mvalid=0;
    ipv4_axis_mready=1'b1;
    rst=1'b1; cyc(6); rst=1'b0; cyc(2);

    $display("--- T1: frame 60B (payload 46B) -> 1 beat ---");
    base = got_cnt; push_frame(8'h10, 46); cyc(60);
    if (got_cnt != base + 1) begin $display("  [FAIL] expect 1 beat, got %0d", got_cnt-base); err=err+1; end
    else $display("  [PASS] 1 beat");

    $display("--- T2: frame 114B (payload 100B) -> 2 beats (跨拍 carry) ---");
    base = got_cnt; push_frame(8'h40, 100); cyc(120);
    if (got_cnt != base + 2) begin $display("  [FAIL] expect 2 beats, got %0d", got_cnt-base); err=err+1; end
    else $display("  [PASS] 2 beats");

    $display("--- T3: frame 64B (payload 50B, 恰好占满首拍) ---");
    base = got_cnt; push_frame(8'h80, 50); cyc(80);
    if (got_cnt != base + 1) begin $display("  [FAIL] expect 1 beat, got %0d", got_cnt-base); err=err+1; end
    else $display("  [PASS] 1 beat");

    $display("--- T4: 长载荷 + 反压 ---");
    base = got_cnt;
    set_mready(1'b0); cyc(3);
    push_frame(8'hC0, 100); cyc(60);
    set_mready(1'b1); cyc(120);
    if (got_cnt != base + 2) begin $display("  [FAIL] expect 2 beats, got %0d", got_cnt-base); err=err+1; end
    else $display("  [PASS] 2 beats, 不丢不重");
    cyc(20);


    // ---- T5: 同一帧内插气泡(检验隐含假设) ----
    //   本模块的跨拍 carry 取自"实时输入总线", 不是寄存器 => 若上游在帧内插气泡,
    //   carry 会取到(尚未更新的)旧数据。此用例用于量化该假设。
    $display("--- T5: 帧内插气泡 -> 跨拍 carry 是否仍对? ---");
    base = got_cnt;
    err_before = err;
    t5_trace = 1'b1;
    push_frame_gap(8'hE0, 100, 1);        // 载荷 100B(2 拍), 在第 1 拍后插 3 拍气泡
    cyc(160);
    if (err == err_before) $display("  [PASS] 帧内插气泡下 carry 仍正确(支持气泡)");
    else                  $display("  [FAIL] 帧内插气泡导致载荷字节错");
    t5_trace = 1'b0;
    cyc(20);

    // ---- T6: 短尾帧(末拍 keep[14]==0) + 帧间气泡 -> 不得死锁 ----
    //   载荷 60B => 帧 74B => 2 拍, 末拍只有 10 字节有效; 之后插 3 拍气泡再发下一帧
    $display("--- T6: 短尾帧 + 帧间气泡(不得死锁) ---");
    base = got_cnt; err_before = err;
    push_frame_gap(8'hE0, 60, 2);
    push_frame(8'h30, 46);
    cyc(200);
    if (got_cnt != base + 2) begin
      $display("  [FAIL] expect 2 beats, got %0d (可能死锁)", got_cnt-base); err=err+1;
    end
    else if (err != err_before) $display("  [FAIL] 短尾帧+帧间气泡 结果错");
    else $display("  [PASS] 2 beats, 未死锁");
    cyc(20);

    $display("================================================================");
    $display(" beats out=%0d err=%0d", got_cnt, err);
    if (err == 0) $display(" *** ALL TESTS PASSED ***");
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
    $display("================================================================");
    $finish;
  end

  initial begin
    #200_000;
    $display("[%0t] FATAL: timeout", $time);
    $finish;
  end

endmodule
`resetall
