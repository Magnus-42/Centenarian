`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_ipv4_arp_service.v
// Module Name : tb_ipv4_arp_service
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-10-15
// ----------------------------------------------------------------------------
// Description : ipv4_arp_service 单模块合并回归（单 top, 顺序 phase 执行）
//
//   原两个 TB 合并而来, 全部场景/激励/判定保留:
//     tb_ipv4_arp_service.v  (wrapper + hitmiss + pipeline)
//     tb_stress_bp.v         (wrapper + stress + buf_probe)
//
//   phase 顺序:
//     P1 hitmiss    命中/未命中/多拍/下游反压/arp_buf/吞吐/skid      (7 拍 ARP stub)
//     P2 pipeline   10 级流水与 10 拍查表延迟对齐/背靠背/反压归属    (9 拍行为模型)
//     P3 stress     真实 arp_engine_top + 线速连发 + 下游随机反压    (逼出缓冲分支)
//     P4 buf_probe  缓冲分支"实时/已缓冲"量化诊断                    (不计入 PASS/FAIL)
//
//   DUT 结构:
//     u_dut     ipv4_arp_service —— hitmiss + pipeline 共用一个实例
//               (ARP stub 延迟/语义用 sh_arp_delay / sh_arp_mode 切换)
//     u_stress  ipv4_eth_tx(内含 ipv4_arp_service) + arp_engine_top
//     u_probe   ipv4_arp_service —— buf_probe 单独实例(行为模型 MD=9)
//
// 编译/运行:
//   xvlog -work work -sv <RTL 排除 Backup/Top/Test> <RTL/Test> 本文件
//   xelab work.tb_ipv4_arp_service -s snap_tb_ipv4_arp_service
//   xsim snap_tb_ipv4_arp_service -runall
// ============================================================================

module tb_ipv4_arp_service;

  // ==========================================================================
  // 全局时钟 / 复位 / phase 控制
  // ==========================================================================
  reg  clk = 1'b0;
  always #2.5 clk = ~clk;

  reg  rst = 1'b1;

  reg  en_hitmiss  = 1'b0;
  reg  en_pipeline = 1'b0;
  reg  en_stress   = 1'b0;
  reg  en_probe    = 1'b0;

  integer total_err = 0;
  integer hit_err   = 0;
  integer pipe_err  = 0;
  integer bp_err    = 0;

  // ==========================================================================
  // 公共常量
  // ==========================================================================
  localparam [31:0] IP_HIT   = 32'h0500_000A;   // hitmiss: 命中的 IP(线序 10.0.0.5)
  localparam [47:0] MAC_HIT  = 48'hAABB_CCDD_0005; // hitmiss: 与 stub 公式一致
  localparam [31:0] IP_MISS  = 32'h0900_000A;   // hitmiss: 必然 miss 的 IP(10.0.0.9)
  localparam [31:0] MISS_IP  = 32'h0808_0808;   // pipeline/probe: 一律 miss 的 IP
  localparam [63:0] KEEP_PAT = 64'h0F0F_0F0F_0F0F_0F0F;
  localparam SH_SQN = 512;

  // ==========================================================================
  // 共享 DUT (hitmiss + pipeline 共用一个 ipv4_arp_service)
  // ==========================================================================
  reg  [511:0] sh_sdata;
  reg  [ 63:0] sh_skeep;
  reg          sh_slast;
  reg          sh_svalid;
  wire         sh_sready;
  wire [511:0] sh_mdata;
  wire [ 63:0] sh_mkeep;
  wire         sh_mlast;
  wire         sh_mvalid;
  reg          sh_mready;
  wire [ 47:0] sh_dst_mac;
  wire [ 47:0] sh_src_mac;
  wire [ 31:0] sh_query_dst_ip;
  wire [ 31:0] sh_query_src_ip;
  wire         sh_query_valid_pulse;
  reg  [ 47:0] sh_arp_mac;
  reg          sh_arp_miss;
  reg          sh_arp_valid;

  // ---- ARP 行为模型: 查询后 sh_arp_delay 拍返回 ----
  //      hitmiss  : sh_arp_delay = 6 (原 vld_pipe[6] = 7 拍 stub)
  //      pipeline : sh_arp_delay = 9 (原 qv_d[9]    = 第 9 拍)
  reg  [ 3:0] sh_arp_delay;
  reg         sh_arp_mode;   // 0 = hitmiss 语义 ; 1 = pipeline 语义
  reg         sh_qv  [0:9];
  reg  [31:0] sh_qip [0:9];
  integer     sh_k;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      for (sh_k = 0; sh_k <= 9; sh_k = sh_k + 1) begin
        sh_qv [sh_k] <= 1'b0;
        sh_qip[sh_k] <= 32'd0;
      end
    end
    else begin
      sh_qv [0] <= sh_query_valid_pulse;
      sh_qip[0] <= sh_query_dst_ip;
      for (sh_k = 1; sh_k <= 9; sh_k = sh_k + 1) begin
        sh_qv [sh_k] <= sh_qv [sh_k-1];
        sh_qip[sh_k] <= sh_qip[sh_k-1];
      end
    end
  end

  wire [31:0] sh_arp_ip = sh_qip[sh_arp_delay];
  always @(*) begin
    sh_arp_valid = sh_qv[sh_arp_delay];
    if (sh_arp_mode == 1'b0) begin
      // hitmiss: 线序寄存器高字节 = 人类 IP 最后一段, 1~8 命中
      sh_arp_miss = ~((sh_arp_ip[31:24] >= 8'd1) && (sh_arp_ip[31:24] <= 8'd8));
      sh_arp_mac  = ((sh_arp_ip[31:24] >= 8'd1) && (sh_arp_ip[31:24] <= 8'd8))
                    ? (48'hAABB_CCDD_0000 + sh_arp_ip[31:24]) : 48'd0;
    end
    else begin
      // pipeline/probe: 目的 IP == MISS_IP 则 miss
      sh_arp_miss = (sh_arp_ip == MISS_IP);
      sh_arp_mac  = {16'hAAAA, sh_arp_ip[15:0], 16'hBBBB};
    end
  end

  ipv4_arp_service u_dut(
    .clk               (clk                ),
    .rst               (rst                ),
    .ipv4_axis_sdata   (sh_sdata           ),
    .ipv4_axis_skeep   (sh_skeep           ),
    .ipv4_axis_slast   (sh_slast           ),
    .ipv4_axis_svalid  (sh_svalid          ),
    .ipv4_axis_susr    (4'd0               ),
    .ipv4_axis_sready  (sh_sready          ),
    .ipv4_axis_mdata   (sh_mdata           ),
    .ipv4_axis_mkeep   (sh_mkeep           ),
    .ipv4_axis_mlast   (sh_mlast           ),
    .ipv4_axis_mvalid  (sh_mvalid          ),
    .ipv4_axis_musr    (                   ),
    .ipv4_axis_mready  (sh_mready          ),
    .dst_mac           (sh_dst_mac         ),
    .src_mac           (sh_src_mac         ),
    .query_dst_ip      (sh_query_dst_ip    ),
    .query_src_ip      (sh_query_src_ip    ),
    .query_valid_pulse (sh_query_valid_pulse),
    .arp_src_mac       (48'h0              ),
    .arp_dst_mac       (sh_arp_mac         ),
    .arp_miss          (sh_arp_miss        ),
    .arp_valid         (sh_arp_valid       )
  );

  // ---- 共享 AXIS 驱动队列(满速背靠背) ----
  reg  [511:0] sh_sq_data [0:SH_SQN-1];
  reg  [ 63:0] sh_sq_keep [0:SH_SQN-1];
  reg          sh_sq_last [0:SH_SQN-1];
  integer      sh_sq_wr, sh_sq_rd;

  always @(negedge clk) begin
    if (!rst && sh_svalid === 1'b0 && sh_sq_rd < sh_sq_wr) begin
      sh_sdata  <= sh_sq_data[sh_sq_rd];
      sh_skeep  <= sh_sq_keep[sh_sq_rd];
      sh_slast  <= sh_sq_last[sh_sq_rd];
      sh_svalid <= 1'b1;
      sh_sq_rd  = sh_sq_rd + 1;
    end
  end

  always @(posedge clk) begin
    if (rst) sh_svalid <= 1'b0;
    else if (sh_svalid === 1'b1 && sh_sready === 1'b1) sh_svalid <= 1'b0;
  end

  // ---- 公共任务 ----
  task automatic sh_wait(input integer n);
    integer j;
    begin
      for (j = 0; j < n; j = j + 1) @(posedge clk);
    end
  endtask

  task automatic sh_push(input [511:0] d, input [63:0] k, input last);
    begin
      sh_sq_data[sh_sq_wr] = d;
      sh_sq_keep[sh_sq_wr] = k;
      sh_sq_last[sh_sq_wr] = last;
      sh_sq_wr = sh_sq_wr + 1;
    end
  endtask

  task automatic sh_set_mready(input v);
    begin
      @(negedge clk);
      sh_mready <= v;
    end
  endtask

  // ==========================================================================
  // PHASE 1 : hitmiss
  // ==========================================================================
  function [511:0] hit_mk_beat(input [7:0] tag, input [31:0] dip);
    begin
      hit_mk_beat = {tag, {43{8'h5A}}, dip, {16{8'hC3}}};
    end
  endfunction

  function [31:0] hit_mk_ip(input [7:0] k);
    begin hit_mk_ip = {k, 8'h00, 8'h00, 8'h0A}; end
  endfunction

  function [47:0] hit_mk_mac(input [7:0] k);
    begin hit_mk_mac = 48'hAABB_CCDD_0000 + k; end
  endfunction

  integer      hit_got_cnt;
  integer      hit_q_cnt;
  reg [511:0]  hit_got_data [0:255];
  reg [ 63:0]  hit_got_keep [0:255];
  reg          hit_got_last [0:255];
  reg [ 47:0]  hit_got_dmac [0:255];
  integer      hit_i;
  integer      hit_base;
  integer      hit_exp_cnt;
  integer      hit_base_shs;
  integer      hit_base_q;
  reg  [ 7:0]  hit_exp_tag   [0:63];
  reg          hit_exp_first [0:63];
  integer      hit_sent_cnt;
  reg  [31:0]  hit_sent_ip [0:63];
  reg  [31:0]  hit_qry_ip  [0:63];
  integer      hit_shs_cnt;
  integer      hit_buf_occ;
  integer      hit_buf_max;
  reg          hit_stress_en;
  integer      hit_scnt;
  reg          hit_dbg_en;
  integer      hit_skid_hi;
  integer      hit_st10_hi;
  integer      hit_th_cyc, hit_th_last, hit_th_gap, hit_th_max, hit_th_sum, hit_th_n, hit_th_on;

  // ---- 输出监视 ----
  always @(posedge clk) begin
    if (en_hitmiss && sh_mvalid && sh_mready) begin
      hit_got_data[hit_got_cnt] = sh_mdata;
      hit_got_keep[hit_got_cnt] = sh_mkeep;
      hit_got_last[hit_got_cnt] = sh_mlast;
      hit_got_dmac[hit_got_cnt] = sh_dst_mac;
      hit_got_cnt = hit_got_cnt + 1;
    end
  end

  // ---- 查询监视 ----
  always @(posedge clk) begin
    if (en_hitmiss && sh_query_valid_pulse) begin
      hit_qry_ip[hit_q_cnt] = sh_query_dst_ip;
      hit_q_cnt = hit_q_cnt + 1;
    end
  end

  // ---- 打印 ----
  always @(posedge clk) begin
    if (en_hitmiss && u_dut.s_handshake)
      $strobe("[%0t] IN  tag=%02h last=%b fb=%b", $time, sh_sdata[511:504],
              sh_slast, u_dut.is_first_beat);
  end
  always @(posedge clk) begin
    if (en_hitmiss && sh_query_valid_pulse)
      $strobe("[%0t] QRY ip=%08h tag=%02h", $time, sh_query_dst_ip, sh_sdata[511:504]);
  end
  always @(posedge clk) begin
    if (en_hitmiss && sh_mvalid && sh_mready)
      $strobe("[%0t] OUT tag=%02h dst=%012h last=%b", $time, sh_mdata[511:504],
              sh_dst_mac, sh_mlast);
  end

  // ---- 输入握手计数 ----
  always @(posedge clk) if (en_hitmiss && u_dut.s_handshake) hit_shs_cnt = hit_shs_cnt + 1;

  // ---- arp 结果缓存占用统计(TB 侧独立数) ----
  always @(posedge clk) begin
    if (en_hitmiss) begin
      if (u_dut.arp_buf_wr_en) hit_buf_occ = hit_buf_occ + 1;
      else if (u_dut.s7_handshake && u_dut.is_first_beat_s7 && hit_buf_occ > 0) hit_buf_occ = hit_buf_occ - 1;
      if (hit_buf_occ > hit_buf_max) hit_buf_max = hit_buf_occ;
    end
  end

  // ---- 下游反压抖动(negedge 改) ----
  always @(negedge clk) begin
    if (hit_stress_en) begin
      hit_scnt = hit_scnt + 1;
      sh_mready <= ((hit_scnt % 5) < 3);
    end
  end

  // ---- DBG 探针 ----
  always @(posedge clk) begin
    if (hit_dbg_en)
      $strobe("[%0t] DBG v=%b(s7..s1) shs=%b srdy=%b hs7=%b mv=%b mr=%b fb7=%b fb1=%b drop=%b miss=%b arpv=%b",
               $time,
               {u_dut.ipv4_axis_svalid_s7,u_dut.ipv4_axis_svalid_s6,u_dut.ipv4_axis_svalid_s5,
                u_dut.ipv4_axis_svalid_s4,u_dut.ipv4_axis_svalid_s3,u_dut.ipv4_axis_svalid_s2,
                u_dut.ipv4_axis_svalid_s1},
               u_dut.s_handshake, sh_sready, u_dut.s7_handshake,
               u_dut.ipv4_axis_mvalid_reg, sh_mready, u_dut.is_first_beat_s7,
               u_dut.is_first_beat_s1, u_dut.is_drop, u_dut.current_miss, sh_arp_valid);
  end

  // ---- skid 探针 ----
  always @(posedge clk) if (en_hitmiss && !rst && u_dut.ipv4_axis_mvalid_skid && !u_dut.ipv4_axis_mvalid_reg) hit_st10_hi = hit_st10_hi + 1;
  always @(posedge clk) if (en_hitmiss && !rst && u_dut.ipv4_axis_mvalid_skid) hit_skid_hi = hit_skid_hi + 1;

  // ---- 吞吐测量 ----
  always @(posedge clk) begin
    if (en_hitmiss) begin
      hit_th_cyc = hit_th_cyc + 1;
      if (hit_th_on && sh_mvalid && sh_mready) begin
        if (hit_th_n > 0) begin
          hit_th_gap = hit_th_cyc - hit_th_last;
          if (hit_th_gap > hit_th_max) hit_th_max = hit_th_gap;
          hit_th_sum = hit_th_sum + hit_th_gap;
        end
        hit_th_n    = hit_th_n + 1;
        hit_th_last = hit_th_cyc;
      end
    end
  end

  // ---- 发包任务 ----
  task automatic hit_send_pkt1(input [7:0] tag, input [31:0] dip);
    begin
      hit_sent_ip[hit_sent_cnt] = dip;
      hit_sent_cnt = hit_sent_cnt + 1;
      sh_push(hit_mk_beat(tag, dip), KEEP_PAT, 1'b1);
    end
  endtask

  task automatic hit_send_pkt2(input [7:0] tag0, input [7:0] tag1, input [31:0] dip);
    begin
      hit_sent_ip[hit_sent_cnt] = dip;
      hit_sent_cnt = hit_sent_cnt + 1;
      sh_push(hit_mk_beat(tag0, dip), KEEP_PAT, 1'b0);
      sh_push(hit_mk_beat(tag1, dip), KEEP_PAT, 1'b1);
    end
  endtask

  task run_hitmiss;
    begin
      en_hitmiss = 1'b1;
      sh_arp_delay = 4'd6;
      sh_arp_mode  = 1'b0;

      hit_err      = 0;
      hit_got_cnt  = 0;
      hit_q_cnt    = 0;
      hit_sent_cnt = 0;
      hit_shs_cnt  = 0;
      hit_buf_occ  = 0;
      hit_buf_max  = 0;
      hit_skid_hi  = 0;
      hit_st10_hi  = 0;
      hit_th_cyc   = 0;
      hit_th_last  = 0;
      hit_th_max   = 0;
      hit_th_sum   = 0;
      hit_th_n     = 0;
      hit_th_on    = 0;
      hit_stress_en= 1'b0;
      hit_scnt     = 0;
      hit_dbg_en   = 1'b0;
      sh_sq_wr     = 0;
      sh_sq_rd     = 0;

      sh_sdata  = 512'd0;
      sh_skeep  = 64'd0;
      sh_slast  = 1'b0;
      sh_svalid = 1'b0;
      sh_mready = 1'b1;

      $display("================================================================");
      $display(" PHASE 1 : hitmiss (7 拍 ARP stub)");
      $display("================================================================");

      rst = 1'b1;
      sh_wait(10);
      rst = 1'b0;
      sh_wait(2);

      // ---------------- TEST1: 命中, 单拍包 ----------------
      $display("--- TEST1: hit, single beat ---");
      hit_base = hit_got_cnt;
      hit_dbg_en = 1'b1;
      hit_send_pkt1(8'hA1, IP_HIT);
      sh_wait(30);
      if (hit_got_cnt != hit_base + 1) begin
        $display("  [FAIL] expect 1 beat forwarded, got %0d", hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else if (hit_got_data[hit_base] !== hit_mk_beat(8'hA1, IP_HIT)) begin
        $display("  [FAIL] data mismatch: %h", hit_got_data[hit_base]); hit_err = hit_err + 1;
      end
      else if (hit_got_keep[hit_base] !== KEEP_PAT) begin
        $display("  [FAIL] keep mismatch: %h", hit_got_keep[hit_base]); hit_err = hit_err + 1;
      end
      else if (hit_got_last[hit_base] !== 1'b1) begin
        $display("  [FAIL] last mismatch"); hit_err = hit_err + 1;
      end
      else if (hit_got_dmac[hit_base] !== MAC_HIT) begin
        $display("  [FAIL] dst_mac = %012h, expect %012h", hit_got_dmac[hit_base], MAC_HIT); hit_err = hit_err + 1;
      end
      else $display("  [PASS] 1 beat forwarded, data/keep/last ok, dst_mac=%012h", hit_got_dmac[hit_base]);
      hit_dbg_en = 1'b0;

      // ---------------- TEST2: 未命中, 单拍包应被丢弃 ----------------
      $display("--- TEST2: miss -> packet dropped ---");
      hit_base = hit_got_cnt;
      hit_send_pkt1(8'hB2, IP_MISS);
      sh_wait(40);
      if (hit_got_cnt != hit_base) begin
        $display("  [FAIL] miss packet should be dropped, got %0d beat(s)", hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else $display("  [PASS] miss packet dropped (0 beat forwarded)");

      // ---------------- TEST3: 未命中后接着命中 ----------------
      $display("--- TEST3: miss then hit ---");
      hit_base = hit_got_cnt;
      hit_send_pkt1(8'hC3, IP_MISS);
      hit_send_pkt1(8'hD4, IP_HIT );
      sh_wait(40);
      if (hit_got_cnt != hit_base + 1) begin
        $display("  [FAIL] expect 1 beat (only the hit), got %0d", hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else if (hit_got_data[hit_base] !== hit_mk_beat(8'hD4, IP_HIT)) begin
        $display("  [FAIL] wrong beat forwarded: tag=%02h", hit_got_data[hit_base][511:504]); hit_err = hit_err + 1;
      end
      else $display("  [PASS] miss dropped, following hit forwarded");

      sh_wait(20);

      // ---------------- TEST4: 多拍包(命中), 包内 dst_mac 不应被改写 ----------------
      $display("--- TEST4: hit, 2-beat packet ---");
      hit_base = hit_got_cnt;
      hit_send_pkt2(8'hE5, 8'hE6, IP_HIT);
      sh_wait(40);
      if (hit_got_cnt != hit_base + 2) begin
        $display("  [FAIL] expect 2 beats forwarded, got %0d", hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else if (hit_got_data[hit_base][511:504] !== 8'hE5 || hit_got_data[hit_base+1][511:504] !== 8'hE6) begin
        $display("  [FAIL] beat order/tag wrong: %02h %02h", hit_got_data[hit_base][511:504], hit_got_data[hit_base+1][511:504]); hit_err = hit_err + 1;
      end
      else if (hit_got_last[hit_base] !== 1'b0 || hit_got_last[hit_base+1] !== 1'b1) begin
        $display("  [FAIL] last flags wrong: %b %b", hit_got_last[hit_base], hit_got_last[hit_base+1]); hit_err = hit_err + 1;
      end
      else if (hit_got_dmac[hit_base] !== MAC_HIT) begin
        $display("  [FAIL] 首拍 dst_mac = %012h, expect %012h", hit_got_dmac[hit_base], MAC_HIT); hit_err = hit_err + 1;
      end
      else $display("  [PASS] 2 beats forwarded, keep/last ok, 首拍 dst_mac=%012h", hit_got_dmac[hit_base]);

      sh_wait(20);

      // ---------------- TEST5: 下游反压 ----------------
      $display("--- TEST5: backpressure ---");
      sh_set_mready(1'b0);
      hit_base = hit_got_cnt;
      hit_send_pkt1(8'hF7, IP_HIT);
      sh_wait(40);
      if (hit_got_cnt != hit_base) begin
        $display("  [FAIL] beat forwarded while mready=0"); hit_err = hit_err + 1;
      end
      else if (sh_mvalid !== 1'b1) begin
        $display("  [FAIL] beat should be held on m axis (mvalid=0)"); hit_err = hit_err + 1;
      end
      else $display("  [PASS] beat held while mready=0 (mvalid=1, not counted)");
      sh_set_mready(1'b1);
      sh_wait(20);
      if (hit_got_cnt != hit_base + 1) begin
        $display("  [FAIL] expect exactly 1 beat after release, got %0d", hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else if (hit_got_data[hit_base][511:504] !== 8'hF7 || hit_got_dmac[hit_base] !== MAC_HIT) begin
        $display("  [FAIL] released beat corrupted: tag=%02h mac=%012h", hit_got_data[hit_base][511:504], hit_got_dmac[hit_base]); hit_err = hit_err + 1;
      end
      else $display("  [PASS] released beat correct (tag=F7, dst=%012h), no duplication", hit_got_dmac[hit_base]);
      sh_wait(20);

      // ---------------- TEST6: 结果到达时下游阻塞 -> arp 结果缓存通路 ----------------
      $display("--- TEST6: result arrives while downstream stalled (arp_buf path) ---");
      hit_base = hit_got_cnt;
      sh_set_mready(1'b0);
      hit_send_pkt1(8'h18, IP_HIT);
      sh_wait(25);
      sh_set_mready(1'b1);
      sh_wait(25);
      if (hit_got_cnt != hit_base + 1) begin
        $display("  [FAIL] expect 1 beat via buffer path, got %0d", hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else if (hit_got_data[hit_base] !== hit_mk_beat(8'h18, IP_HIT)) begin
        $display("  [FAIL] data mismatch on buffer path: tag=%02h", hit_got_data[hit_base][511:504]); hit_err = hit_err + 1;
      end
      else if (hit_got_dmac[hit_base] !== MAC_HIT) begin
        $display("  [FAIL] buffer path dst_mac wrong: %012h", hit_got_dmac[hit_base]); hit_err = hit_err + 1;
      end
      else $display("  [PASS] beat + dst_mac correct through arp result buffer");
      sh_wait(20);

      // ---------------- TEST7: 背靠背多包 + 反压抖动 ----------------
      $display("--- TEST7: back-to-back packets + mready dithering (arp_buf stress) ---");
      hit_base = hit_got_cnt;
      hit_base_shs = hit_shs_cnt;
      hit_base_q   = hit_q_cnt;
      hit_exp_cnt = 0;
      hit_stress_en = 1'b1;
      for (hit_i = 0; hit_i < 8; hit_i = hit_i + 1) begin
        if ((hit_i % 2) == 0) begin
          hit_exp_tag[hit_exp_cnt] = 8'h20 + hit_i;  hit_exp_first[hit_exp_cnt] = 1'b1;  hit_exp_cnt = hit_exp_cnt + 1;
          hit_send_pkt1(8'h20 + hit_i, IP_HIT);
        end
        else begin
          hit_exp_tag[hit_exp_cnt] = 8'h20 + hit_i;  hit_exp_first[hit_exp_cnt] = 1'b1;  hit_exp_cnt = hit_exp_cnt + 1;
          hit_exp_tag[hit_exp_cnt] = 8'h80 + hit_i;  hit_exp_first[hit_exp_cnt] = 1'b0;  hit_exp_cnt = hit_exp_cnt + 1;
          hit_send_pkt2(8'h20 + hit_i, 8'h80 + hit_i, IP_HIT);
        end
      end
      hit_stress_en = 1'b0;
      sh_set_mready(1'b1);
      sh_wait(150);
      $display("  [INFO] sent beats=%0d, input handshakes=%0d, queries=%0d, forwarded=%0d",
               hit_exp_cnt, hit_shs_cnt-hit_base_shs, hit_q_cnt-hit_base_q, hit_got_cnt-hit_base);
      if (hit_got_cnt != hit_base + hit_exp_cnt) begin
        $display("  [FAIL] expect %0d beats, got %0d", hit_exp_cnt, hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else begin
        hit_i = 0;
        while (hit_i < hit_exp_cnt && hit_got_data[hit_base+hit_i][511:504] === hit_exp_tag[hit_i] &&
               (!hit_exp_first[hit_i] || hit_got_dmac[hit_base+hit_i] === MAC_HIT)) begin
          hit_i = hit_i + 1;
        end
        if (hit_i != hit_exp_cnt) begin
          $display("  [FAIL] beat %0d: tag=%02h(exp %02h) dst_mac=%012h(首拍期望 %012h)",
                   hit_i, hit_got_data[hit_base+hit_i][511:504], hit_exp_tag[hit_i],
                   hit_got_dmac[hit_base+hit_i], MAC_HIT);
          hit_err = hit_err + 1;
        end
        else $display("  [PASS] %0d beats in order, 每包首拍 dst_mac 均正确(dithering 下)", hit_exp_cnt);
      end
      sh_wait(20);

      // ---------------- TEST8: 8 包长反压(结果缓存接近写满) ----------------
      $display("--- TEST8: 8 packets under long backpressure (arp_buf full corner) ---");
      hit_base = hit_got_cnt;
      sh_set_mready(1'b0);
      for (hit_i = 1; hit_i <= 8; hit_i = hit_i + 1) hit_send_pkt1(8'h30 + hit_i[7:0], hit_mk_ip(hit_i[7:0]));
      sh_wait(60);
      sh_set_mready(1'b1);
      sh_wait(120);
      if (hit_got_cnt != hit_base + 8) begin
        $display("  [FAIL] expect 8 beats, got %0d", hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else begin
        hit_i = 1;
        while (hit_i <= 8 && hit_got_data[hit_base+hit_i-1][511:504] === (8'h30 + hit_i[7:0]) &&
               hit_got_dmac[hit_base+hit_i-1] === hit_mk_mac(hit_i[7:0])) begin
          hit_i = hit_i + 1;
        end
        if (hit_i != 9) begin
          $display("  [FAIL] beat %0d(pkt %0d): tag=%02h(exp %02h) dst=%012h(exp %012h)",
                   hit_i-1, hit_i, hit_got_data[hit_base+hit_i-1][511:504], 8'h30+hit_i[7:0],
                   hit_got_dmac[hit_base+hit_i-1], hit_mk_mac(hit_i[7:0]));
          hit_err = hit_err + 1;
        end
        else $display("  [PASS] 8 packets: each dst_mac matches its own IP");
      end
      sh_wait(20);
      $display("  [INFO] arp_buf 占用峰值 = %0d (TB 独立统计)", hit_buf_max);

      // ---------------- TEST9: 命中包占住输出寄存器, 未命中包卡在 s7 ----------------
      $display("--- TEST9: miss packet stalled at s7 behind a blocked hit packet ---");
      hit_base = hit_got_cnt;
      sh_set_mready(1'b0);
      hit_send_pkt1(8'h51, IP_HIT);
      hit_send_pkt1(8'h52, IP_MISS);
      sh_wait(30);
      sh_set_mready(1'b1);
      sh_wait(60);
      if (hit_got_cnt != hit_base + 1) begin
        $display("  [FAIL] expect only the hit packet, got %0d beat(s)", hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else if (hit_got_data[hit_base][511:504] !== 8'h51 || hit_got_dmac[hit_base] !== MAC_HIT) begin
        $display("  [FAIL] wrong beat out: tag=%02h dst=%012h", hit_got_data[hit_base][511:504], hit_got_dmac[hit_base]); hit_err = hit_err + 1;
      end
      else $display("  [PASS] hit forwarded, miss dropped (stalled at s7)");
      sh_wait(20);

      // ---------------- TEST10: 输出吞吐测量 ----------------
      $display("--- TEST10: throughput with mready=1, full-rate input ---");
      hit_base = hit_got_cnt;
      sh_set_mready(1'b1);
      hit_send_pkt2(8'hA1, 8'hA2, IP_HIT);
      sh_wait(20);
      hit_th_on = 1'b0; hit_th_n = 0; hit_th_max = 0; hit_th_sum = 0;
      hit_th_on = 1'b1;
      hit_send_pkt2(8'hB1, 8'hB2, IP_HIT);
      hit_send_pkt2(8'hC1, 8'hC2, IP_HIT);
      hit_send_pkt2(8'hD1, 8'hD2, IP_HIT);
      sh_wait(60);
      hit_th_on = 1'b0;
      if (hit_th_n >= 2) begin
        $display("  [INFO] 连续 %0d 拍输出: 最大间隔=%0d 拍, 平均=%0d.%0d 拍  => %.2f beat/cycle (满速=1.00)",
                 hit_th_n, hit_th_max, hit_th_sum/(hit_th_n-1), (hit_th_sum*10/(hit_th_n-1))%10,
                 (hit_th_n-1)*1.0/hit_th_sum);
      end
      if (hit_got_cnt != hit_base + 8) begin
        $display("  [FAIL] expect 8 beats (4 包 x 2 拍), got %0d", hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else $display("  [PASS] 8 beats forwarded (顺序/数量正确)");
      sh_wait(20);

      // ---------------- TEST11: 多拍 HIT 包跨越 stall ----------------
      $display("--- TEST11: multi-beat HIT packet straddling a stall ---");
      hit_base = hit_got_cnt;
      sh_set_mready(1'b1);
      hit_sent_ip[hit_sent_cnt] = IP_HIT;  hit_sent_cnt = hit_sent_cnt + 1;
      sh_push(hit_mk_beat(8'hE1, IP_HIT), KEEP_PAT, 1'b0);
      sh_push(hit_mk_beat(8'hE2, IP_HIT), KEEP_PAT, 1'b0);
      sh_push(hit_mk_beat(8'hE3, IP_HIT), KEEP_PAT, 1'b0);
      sh_push(hit_mk_beat(8'hE4, IP_HIT), KEEP_PAT, 1'b1);
      sh_set_mready(1'b0);
      sh_wait(8);
      sh_set_mready(1'b1);
      sh_wait(100);
      if (hit_got_cnt != hit_base + 4) begin
        $display("  [FAIL] expect 4 beats after stall, got %0d", hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else if (hit_got_data[hit_base  ][511:504] !== 8'hE1 || hit_got_data[hit_base+1][511:504] !== 8'hE2 ||
               hit_got_data[hit_base+2][511:504] !== 8'hE3 || hit_got_data[hit_base+3][511:504] !== 8'hE4) begin
        $display("  [FAIL] beat order/tag wrong: %02h %02h %02h %02h",
                 hit_got_data[hit_base][511:504], hit_got_data[hit_base+1][511:504],
                 hit_got_data[hit_base+2][511:504], hit_got_data[hit_base+3][511:504]); hit_err = hit_err + 1;
      end
      else if (hit_got_dmac[hit_base] !== MAC_HIT) begin
        $display("  [FAIL] 首拍 dst_mac=%012h (跨 stall 错位)", hit_got_dmac[hit_base]); hit_err = hit_err + 1;
      end
      else if (hit_got_last[hit_base+3] !== 1'b1 || hit_got_last[hit_base] !== 1'b0) begin
        $display("  [FAIL] last 标志错误(跨 stall)"); hit_err = hit_err + 1;
      end
      else $display("  [PASS] 4 beats in order across the stall, keep/last/dst ok");

      // ---------------- TEST12: 多拍 MISS 包在 stall 中 ----------------
      $display("--- TEST12: multi-beat MISS packet while stalled ---");
      hit_base = hit_got_cnt;
      sh_set_mready(1'b0);
      hit_sent_ip[hit_sent_cnt] = IP_MISS;  hit_sent_cnt = hit_sent_cnt + 1;
      sh_push(hit_mk_beat(8'hF1, IP_MISS), KEEP_PAT, 1'b0);
      sh_push(hit_mk_beat(8'hF2, IP_MISS), KEEP_PAT, 1'b0);
      sh_push(hit_mk_beat(8'hF3, IP_MISS), KEEP_PAT, 1'b1);
      sh_wait(30);
      hit_sent_ip[hit_sent_cnt] = IP_HIT;  hit_sent_cnt = hit_sent_cnt + 1;
      sh_push(hit_mk_beat(8'hF5, IP_HIT ), KEEP_PAT, 1'b0);
      sh_push(hit_mk_beat(8'hF6, IP_HIT ), KEEP_PAT, 1'b1);
      sh_wait(30);
      sh_set_mready(1'b1);
      sh_wait(100);
      if (hit_got_cnt != hit_base + 2) begin
        $display("  [FAIL] expect only 2 HIT beats (MISS must vanish), got %0d", hit_got_cnt - hit_base); hit_err = hit_err + 1;
      end
      else if (hit_got_data[hit_base][511:504] !== 8'hF5 || hit_got_data[hit_base+1][511:504] !== 8'hF6) begin
        $display("  [FAIL] wrong beats out: %02h %02h", hit_got_data[hit_base][511:504], hit_got_data[hit_base+1][511:504]);
        hit_err = hit_err + 1;
      end
      else if (hit_got_dmac[hit_base] !== MAC_HIT) begin
        $display("  [FAIL] 首拍 dst_mac 错位: %012h", hit_got_dmac[hit_base]); hit_err = hit_err + 1;
      end
      else $display("  [PASS] MISS 3 拍全丢, 紧跟的 HIT 2 拍与 dst_mac 均正确");

      // ---------------- 对账: 每包恰好一次查询 ----------------
      if (hit_q_cnt !== hit_sent_cnt) begin
        $display("  [FAIL] query count %0d != packet count %0d", hit_q_cnt, hit_sent_cnt); hit_err = hit_err + 1;
      end
      else begin
        hit_i = 0;
        while (hit_i < hit_sent_cnt && hit_qry_ip[hit_i] === hit_sent_ip[hit_i]) hit_i = hit_i + 1;
        if (hit_i != hit_sent_cnt) begin
          $display("  [FAIL] query_dst_ip[%0d]=%08h expect %08h", hit_i, hit_qry_ip[hit_i], hit_sent_ip[hit_i]); hit_err = hit_err + 1;
        end
        else $display("--- [PASS] %0d packets -> %0d queries, query_dst_ip 与每包目的 IP 一一对应", hit_sent_cnt, hit_q_cnt);
      end

      $display("================================================================");
      $display(" PHASE 1 (hitmiss) 汇总: query pulses=%0d, beats forwarded=%0d", hit_q_cnt, hit_got_cnt);
      $display(" [INFO] mvalid_skid 为 1 的周期数 = %0d", hit_skid_hi);
      $display(" [INFO] 状态 2'b10 出现周期数 = %0d", hit_st10_hi);
      if (hit_err == 0) $display(" PHASE 1 (hitmiss): *** PASSED ***");
      else              $display(" PHASE 1 (hitmiss): *** %0d CHECK(S) FAILED ***", hit_err);
      $display("================================================================");
      en_hitmiss = 1'b0;
    end
  endtask

  // ==========================================================================
  // PHASE 2 : pipeline
  // ==========================================================================
  function [511:0] pipe_mk_beat(input [31:0] pid, input [31:0] bid, input [31:0] dstip);
    begin
      pipe_mk_beat = {352'd0, dstip, 32'hC0A8_010A, 32'd0, pid, bid};
    end
  endfunction

  integer pipe_exp_n, pipe_act_n, pipe_err_n;
  reg [31:0] pipe_exp_pid [0:255];
  reg [31:0] pipe_exp_bid [0:255];
  reg        pipe_exp_lst [0:255];
  reg [47:0] pipe_exp_mac [0:255];
  reg [31:0] pipe_act_pid [0:255];
  reg [31:0] pipe_act_bid [0:255];
  reg        pipe_act_lst [0:255];
  reg [47:0] pipe_act_mac [0:255];
  integer    pipe_mon_cnt;
  reg        pipe_dbg_en;

  always @(posedge clk) begin
    if (en_pipeline && !rst && sh_mvalid && sh_mready) begin
      pipe_act_pid[pipe_mon_cnt] = sh_mdata[63:32];
      pipe_act_bid[pipe_mon_cnt] = sh_mdata[31:0];
      pipe_act_lst[pipe_mon_cnt] = sh_mlast;
      pipe_act_mac[pipe_mon_cnt] = sh_dst_mac;
      pipe_mon_cnt = pipe_mon_cnt + 1;
    end
  end

  always @(posedge clk) begin
    if (pipe_dbg_en && !rst)
      $display("t=%0t s10v=%0b s10r=%0b isf10=%0b skidv=%0b regv=%0b mrdy=%0b drop=%0b s10pid=%0d s10bid=%0d regpid=%0d regbid=%0d bufemp=%0b",
        $time,
        u_dut.ipv4_axis_svalid_s10, u_dut.s10_ready, u_dut.is_first_beat_s10,
        u_dut.ipv4_axis_mvalid_skid, u_dut.ipv4_axis_mvalid_reg, sh_mready, u_dut.is_drop,
        u_dut.ipv4_axis_sdata_s10[63:32], u_dut.ipv4_axis_sdata_s10[31:0],
        u_dut.ipv4_axis_mdata_reg[63:32], u_dut.ipv4_axis_mdata_reg[31:0],
        u_dut.arp_buf_empty);
  end

  task automatic pipe_exp_pkt(input [31:0] pid, input [31:0] dstip, input integer nbeats);
    integer b;
    begin
      if (dstip != MISS_IP) begin
        for (b = 0; b < nbeats; b = b + 1) begin
          pipe_exp_pid[pipe_exp_n] = pid;
          pipe_exp_bid[pipe_exp_n] = b;
          pipe_exp_lst[pipe_exp_n] = (b == nbeats - 1);
          pipe_exp_mac[pipe_exp_n] = (b == 0) ? {16'hAAAA, dstip[15:0], 16'hBBBB} : 48'd0;
          pipe_exp_n = pipe_exp_n + 1;
        end
      end
    end
  endtask

  task automatic pipe_send_pkt(input [31:0] pid, input [31:0] dstip, input integer nbeats);
    integer b;
    begin
      for (b = 0; b < nbeats; b = b + 1)
        sh_push(pipe_mk_beat(pid, b[31:0], dstip), 64'hFFFF_FFFF_FFFF_FFFF, (b == nbeats - 1));
      pipe_exp_pkt(pid, dstip, nbeats);
    end
  endtask

  task automatic pipe_check(input [127:0] name);
    integer i;
    begin
      sh_wait(40);
      pipe_act_n = pipe_mon_cnt;
      pipe_err_n = 0;
      if (pipe_act_n != pipe_exp_n) begin
        $display("[FAIL] %s : 拍数不符 exp=%0d act=%0d", name, pipe_exp_n, pipe_act_n);
        for (i = 0; i < pipe_act_n; i = i + 1)
          $display("        act[%0d] pid=%0d bid=%0d lst=%0b mac=%h", i, pipe_act_pid[i], pipe_act_bid[i], pipe_act_lst[i], pipe_act_mac[i]);
        for (i = 0; i < pipe_exp_n; i = i + 1)
          $display("        exp[%0d] pid=%0d bid=%0d lst=%0b mac=%h", i, pipe_exp_pid[i], pipe_exp_bid[i], pipe_exp_lst[i], pipe_exp_mac[i]);
        pipe_err_n = pipe_err_n + 1;
      end
      for (i = 0; i < ((pipe_act_n < pipe_exp_n) ? pipe_act_n : pipe_exp_n); i = i + 1) begin
        if (pipe_act_pid[i] !== pipe_exp_pid[i] || pipe_act_bid[i] !== pipe_exp_bid[i] ||
            pipe_act_lst[i] !== pipe_exp_lst[i] || pipe_act_mac[i] !== pipe_exp_mac[i]) begin
          if (pipe_err_n < 6)
            $display("[FAIL] %s : beat%0d exp(pid=%0d bid=%0d lst=%0b mac=%h) act(pid=%0d bid=%0d lst=%0b mac=%h)",
                     name, i, pipe_exp_pid[i], pipe_exp_bid[i], pipe_exp_lst[i], pipe_exp_mac[i],
                          pipe_act_pid[i], pipe_act_bid[i], pipe_act_lst[i], pipe_act_mac[i]);
          pipe_err_n = pipe_err_n + 1;
        end
      end
      if (pipe_err_n == 0)
        $display("[PASS] %s : %0d 拍全部正确", name, pipe_exp_n);
      pipe_err  = pipe_err + pipe_err_n;
      pipe_exp_n = 0; pipe_mon_cnt = 0;
    end
  endtask

  task run_pipeline;
    begin
      en_pipeline = 1'b1;
      sh_arp_delay = 4'd9;
      sh_arp_mode  = 1'b1;

      pipe_err    = 0;
      pipe_exp_n  = 0;
      pipe_mon_cnt= 0;
      pipe_err_n  = 0;
      pipe_dbg_en = 1'b0;
      sh_sq_wr    = 0;
      sh_sq_rd    = 0;

      sh_sdata  = 512'd0;
      sh_skeep  = 64'd0;
      sh_slast  = 1'b0;
      sh_svalid = 1'b0;
      sh_mready = 1'b1;

      $display("================================================================");
      $display(" PHASE 2 : pipeline (9 拍行为模型)");
      $display("================================================================");

      rst = 1'b1;
      sh_wait(10);
      rst = 1'b0;
      sh_wait(5);

      // ---- S1: 单包 3 拍, 未命中 -> 期望 0 拍
      pipe_send_pkt(1, MISS_IP, 3);
      pipe_check("S1_miss_3beat");

      // ---- S2: 单包 3 拍, 命中 -> 期望 3 拍, 首拍带 mac
      pipe_send_pkt(2, 32'hC0A8_0164, 3);
      pipe_check("S2_hit_3beat");

      // ---- S3: 单包 1 拍, 命中 -> 期望 1 拍
      pipe_send_pkt(3, 32'hC0A8_0165, 1);
      pipe_check("S3_hit_1beat");

      // ---- S4: 单包 1 拍, 未命中 -> 期望 0 拍
      pipe_send_pkt(4, MISS_IP, 1);
      pipe_check("S4_miss_1beat");

      // ---- S5: 背靠背 3 包(命中/未命中/命中), 各 3 拍
      pipe_send_pkt(5, 32'hC0A8_0170, 3);
      pipe_send_pkt(6, MISS_IP,       3);
      pipe_send_pkt(7, 32'hC0A8_0171, 3);
      pipe_check("S5_back2back_mix");

      // ---- S6: 背靠背 8 个单拍包交替 miss/hit
      pipe_send_pkt(10, MISS_IP,       1);
      pipe_send_pkt(11, 32'hC0A8_0180, 1);
      pipe_send_pkt(12, MISS_IP,       1);
      pipe_send_pkt(13, 32'hC0A8_0181, 1);
      pipe_send_pkt(14, 32'hC0A8_0182, 1);
      pipe_send_pkt(15, MISS_IP,       1);
      pipe_send_pkt(16, 32'hC0A8_0183, 1);
      pipe_send_pkt(17, MISS_IP,       1);
      pipe_check("S6_burst8_mix");

      // ---- S7: 输出反压(mready 抽低) + 混合
      sh_set_mready(1'b0);
      pipe_send_pkt(20, 32'hC0A8_0190, 4);
      pipe_send_pkt(21, MISS_IP,       4);
      pipe_send_pkt(22, 32'hC0A8_0191, 4);
      sh_wait(30);
      sh_set_mready(1'b1);
      pipe_check("S7_backpressure");

      sh_wait(20);
      $display("================================================================");
      if (pipe_err == 0) $display(" PHASE 2 (pipeline): *** PASSED ***");
      else               $display(" PHASE 2 (pipeline): *** %0d CHECK(S) FAILED ***", pipe_err);
      $display("================================================================");
      en_pipeline = 1'b0;
    end
  endtask

  // ==========================================================================
  // PHASE 3 : stress (真实 arp_engine_top + 线速连发 + 下游随机反压)
  // ==========================================================================
  localparam AXIS_WIDTH = 512;
  localparam [31:0] LOCAL_IP  = 32'h0A01_A8C0;
  localparam [31:0] GW_IP     = 32'h0101_A8C0;
  localparam [31:0] MASK24    = 32'h00FF_FFFF;
  localparam [47:0] LOCAL_MAC = 48'h0102_0304_0501;
  localparam [31:0] PEER_IP   = 32'h3201_A8C0;
  localparam [47:0] PEER_MAC  = 48'hAABB_CCDD_EE01;
  localparam [31:0] EXT_IP    = 32'h0808_0808;
  localparam [47:0] GW_MAC    = 48'hAABB_CCDD_EE02;

  reg  [AXIS_WIDTH-1:0] bp_iv_sdata;
  reg  [63:0]           bp_iv_skeep;
  reg                   bp_iv_slast, bp_iv_svalid;
  wire                  bp_iv_sready;
  wire [AXIS_WIDTH-1:0] bp_ev_mdata;
  wire [63:0]           bp_ev_mkeep;
  wire                  bp_ev_mlast, bp_ev_mvalid;
  reg                   bp_ev_mready;
  wire [31:0]           bp_q_src, bp_q_dst;
  wire                  bp_q_valid;
  wire [47:0]           bp_arp_mac;
  wire [47:0]           bp_arp_src_mac;
  wire                  bp_arp_miss, bp_arp_valid;
  wire [AXIS_WIDTH-1:0] bp_am_mdata;
  wire [63:0]           bp_am_mkeep;
  wire                  bp_am_mvalid, bp_am_mlast;
  reg                   bp_am_mready;
  reg  [AXIS_WIDTH-1:0] bp_as_sdata;
  reg  [63:0]           bp_as_skeep;
  reg                   bp_as_svalid, bp_as_slast;
  wire                  bp_as_sready;
  wire bp_stat_rx_error, bp_stat_ack_ovf, bp_stat_pend_ovf, bp_stat_no_resp;
  wire bp_stat_pend_clr, bp_stat_cache_clr, bp_stat_src_bad;

  ipv4_eth_tx u_ipv4_tx (
    .clk               (clk), .rst (rst),
    .ipv4_axis_sdata   (bp_iv_sdata), .ipv4_axis_skeep  (bp_iv_skeep),
    .ipv4_axis_slast   (bp_iv_slast), .ipv4_axis_svalid (bp_iv_svalid),
    .ipv4_axis_susr    (4'd0),
    .ipv4_axis_sready  (bp_iv_sready),
    .query_src_ip      (bp_q_src), .query_dst_ip (bp_q_dst),
    .query_valid_pulse (bp_q_valid),
    .arp_dst_mac       (bp_arp_mac), .arp_src_mac (bp_arp_src_mac), .arp_miss (bp_arp_miss), .arp_valid (bp_arp_valid),
    .eth_axis_mdata    (bp_ev_mdata), .eth_axis_mkeep  (bp_ev_mkeep),
    .eth_axis_mlast    (bp_ev_mlast), .eth_axis_mvalid (bp_ev_mvalid),
    .eth_axis_musr     (            ),
    .eth_axis_mready   (bp_ev_mready)
  );

  arp_engine_top #(
    .AXIS_WIDTH (AXIS_WIDTH), .CACHE_DEEP (8), .PENDING_DEEP (8), .LOCAL_IP_NUM (1)
  ) u_arp (
    .clk (clk), .rst (rst),
    .query_src_ip (bp_q_src), .query_dst_ip (bp_q_dst), .query_valid_pulse (bp_q_valid),
    .arp_dst_mac (bp_arp_mac), .arp_src_mac (bp_arp_src_mac), .arp_miss (bp_arp_miss), .arp_valid (bp_arp_valid),
    .arp_axis_sdata (bp_as_sdata), .arp_axis_skeep (bp_as_skeep),
    .arp_axis_svalid (bp_as_svalid), .arp_axis_slast (bp_as_slast),
    .arp_axis_susr (1'b0),
    .arp_axis_sready (bp_as_sready),
    .arp_axis_mdata (bp_am_mdata), .arp_axis_mkeep (bp_am_mkeep),
    .arp_axis_mvalid (bp_am_mvalid), .arp_axis_mlast (bp_am_mlast),
    .arp_axis_musr (),
    .arp_axis_mready (bp_am_mready),
    .cfg_local_ip (LOCAL_IP), .cfg_local_mac (LOCAL_MAC),
    .cfg_gateway_ip (GW_IP), .cfg_subnet_mask (MASK24),
    .cfg_pending_time (57'd16),
    .cfg_clear_cache (1'b0), .cfg_clear_pending (1'b0),
    .stat_rx_error (bp_stat_rx_error),
    .stat_ack_fifo_overflow_error (bp_stat_ack_ovf),
    .stat_pending_fifo_overflow_error (bp_stat_pend_ovf),
    .stat_lookup_no_resp_error (bp_stat_no_resp),
    .stat_pending_clear_finish (bp_stat_pend_clr),
    .stat_cache_clear_finish (bp_stat_cache_clr),
    .stat_query_src_not_local (bp_stat_src_bad)
  );

  // ---- 对端主机模型 ----
  reg        bp_rsp_pend;
  reg [31:0] bp_rsp_tpa, bp_rsp_spa;
  reg [47:0] bp_rsp_tha, bp_rsp_sha;

  always @(posedge clk) begin
    if (rst) bp_rsp_pend <= 1'b0;
    else if (bp_am_mvalid && bp_am_mready && bp_am_mdata[175:160] == 16'h0100 && !bp_rsp_pend) begin
      bp_rsp_spa <= bp_am_mdata[335:304];
      bp_rsp_tpa <= bp_am_mdata[255:224];
      bp_rsp_tha <= bp_am_mdata[223:176];
      bp_rsp_sha <= (bp_am_mdata[335:304] == PEER_IP) ? PEER_MAC :
                    (bp_am_mdata[335:304] == GW_IP  ) ? GW_MAC   : 48'h0202_0304_0506;
      bp_rsp_pend <= 1'b1;
    end
  end

  always @(posedge clk) begin
    if (rst) begin bp_as_svalid <= 1'b0; bp_as_slast <= 1'b0; end
    else if (bp_rsp_pend && (!bp_as_svalid || (bp_as_svalid && bp_as_sready))) begin
      bp_as_sdata  <= {176'd0, bp_rsp_tpa, bp_rsp_tha, bp_rsp_spa, bp_rsp_sha,
                       16'h0200, 8'h04, 8'h06, 16'h0008, 16'h0100, 16'h0608,
                       bp_rsp_sha, bp_rsp_tha};
      bp_as_skeep  <= 64'h0000_03FF_FFFF_FFFF;
      bp_as_slast  <= 1'b1;
      bp_as_svalid <= 1'b1;
      bp_rsp_pend  <= 1'b0;
    end
    else if (bp_as_svalid && bp_as_sready) begin bp_as_svalid <= 1'b0; bp_as_slast <= 1'b0; end
  end

  // ---- arp_buf 分支探针 ----
  integer bp_cnt_first, bp_cnt_empty, bp_cnt_buff, bp_cnt_wr, bp_max_occ, bp_occv;
  always @(posedge clk) if (en_stress && !rst) begin
    if (u_ipv4_tx.u_ipv4_arp_service.s10_handshake &&
        u_ipv4_tx.u_ipv4_arp_service.is_first_beat_s10) begin
      bp_cnt_first = bp_cnt_first + 1;
      if (u_ipv4_tx.u_ipv4_arp_service.arp_buf_empty) bp_cnt_empty = bp_cnt_empty + 1;
      else                                             bp_cnt_buff  = bp_cnt_buff  + 1;
    end
    if (u_ipv4_tx.u_ipv4_arp_service.arp_buf_wr_en) bp_cnt_wr = bp_cnt_wr + 1;
    bp_occv = (u_ipv4_tx.u_ipv4_arp_service.arp_buf_wr_ptr >= u_ipv4_tx.u_ipv4_arp_service.arp_buf_rd_ptr)
            ? (u_ipv4_tx.u_ipv4_arp_service.arp_buf_wr_ptr - u_ipv4_tx.u_ipv4_arp_service.arp_buf_rd_ptr)
            : (u_ipv4_tx.u_ipv4_arp_service.arp_buf_wr_ptr + 16
               - u_ipv4_tx.u_ipv4_arp_service.arp_buf_rd_ptr);
    if (bp_occv > bp_max_occ) bp_max_occ = bp_occv;
  end

  // ---- 输出记分板 ----
  integer bp_pkts_out;
  integer bp_cur_beats;
  reg [95:0] bp_first_tag;
  reg [47:0] bp_first_mac;
  reg        bp_scb_en;
  integer    bp_exp_pid;

  always @(posedge clk) begin
    if (rst) begin
      bp_pkts_out <= 0; bp_cur_beats <= 0; bp_exp_pid <= 0;
    end
    else if (en_stress && bp_ev_mvalid && bp_ev_mready) begin
      if (bp_cur_beats == 0) begin
        bp_first_mac <= bp_ev_mdata[47:0];
        bp_first_tag <= bp_ev_mdata[207:112];
      end
      bp_cur_beats <= bp_cur_beats + 1;
      if (bp_ev_mlast) begin
        if (bp_scb_en) begin
          bp_pkts_out <= bp_pkts_out + 1;
          if (bp_pkts_out < 3) begin
            $display("[DBG ] out#%0d mac=%h tag=%0d lowtag=%h",
                     bp_exp_pid, bp_first_mac, bp_first_tag[95:64], bp_first_tag[63:0]);
          end
          if (bp_cur_beats + 1 != 4) begin
            $display("[FAIL] pkt#%0d beats=%0d exp=4 (tag=%h mac=%h)",
                     bp_exp_pid, bp_cur_beats + 1, bp_first_tag, bp_first_mac);
            bp_err = bp_err + 1;
          end
          else if (bp_first_tag[95:64] !== bp_exp_pid) begin
            $display("[FAIL] pkt#%0d 标识位错位 exp=%0d got=%0d", bp_exp_pid, bp_exp_pid, bp_first_tag[95:64]);
            bp_err = bp_err + 1;
          end
          else if (bp_first_tag[31:0] !== 32'h0) begin
            $display("[FAIL] pkt#%0d dst IP 字段被改写 = %h", bp_exp_pid, bp_first_tag[31:0]);
            bp_err = bp_err + 1;
          end
          bp_exp_pid <= bp_exp_pid + 1;
        end
        bp_cur_beats <= 0;
      end
    end
  end

  task automatic bp_waitcyc(input integer n);
    begin repeat (n) @(posedge clk); end
  endtask

  // ---- 下游反压: LFSR 伪随机 ----
  reg [15:0] bp_lfsr_r;
  always @(posedge clk) if (en_stress && !rst) begin
    bp_lfsr_r <= {bp_lfsr_r[14:0], bp_lfsr_r[15] ^ bp_lfsr_r[13] ^ bp_lfsr_r[12] ^ bp_lfsr_r[10]};
  end
  always @(negedge clk) begin
    if (en_stress && !rst) bp_ev_mready <= bp_lfsr_r[2:0] > 3'd2;
  end

  // ---- 发包 ----
  task automatic bp_send_pkt(input [31:0] tag, input [31:0] dstip);
    integer b;
    begin
      for (b = 0; b < 3; b = b + 1) begin
        @(negedge clk);
        bp_iv_sdata  = {352'd0, dstip, LOCAL_IP, tag, 32'd0, b[31:0]};
        bp_iv_skeep  = 64'hFFFF_FFFF_FFFF_FFFF;
        bp_iv_slast  = (b == 2);
        bp_iv_svalid = 1'b1;
        @(posedge clk);
        while (!(bp_iv_svalid && bp_iv_sready)) @(posedge clk);
      end
      @(negedge clk);
      bp_iv_svalid = 1'b0;
      bp_iv_slast  = 1'b0;
    end
  endtask

  task run_stress;
    integer i;
    begin
      en_stress = 1'b1;
      bp_err = 0;
      bp_iv_sdata = 0; bp_iv_skeep = 0; bp_iv_slast = 0; bp_iv_svalid = 0;
      bp_am_mready = 1'b1;
      bp_ev_mready = 1'b1;
      bp_as_sdata = 0; bp_as_skeep = 0; bp_as_svalid = 0; bp_as_slast = 0;
      bp_rsp_pend = 1'b0;
      bp_cnt_first = 0; bp_cnt_empty = 0; bp_cnt_buff = 0; bp_cnt_wr = 0; bp_max_occ = 0; bp_occv = 0;
      bp_pkts_out = 0; bp_cur_beats = 0; bp_first_tag = 0; bp_first_mac = 0;
      bp_scb_en = 1'b0; bp_exp_pid = 0;
      bp_lfsr_r = 16'hACE1;

      $display("================================================================");
      $display(" PHASE 3 : stress (真实 arp_engine_top + 线速连发 + 下游随机反压)");
      $display("================================================================");

      rst = 1'b1;
      bp_waitcyc(20);
      rst = 1'b0;
      wait (bp_stat_cache_clr && bp_stat_pend_clr);
      bp_waitcyc(10);

      // --- 学习 PEER 与 GW ---
      bp_send_pkt(32'd1, PEER_IP);
      bp_waitcyc(60);
      bp_send_pkt(32'd2, PEER_IP);
      bp_waitcyc(60);
      bp_send_pkt(32'd3, EXT_IP);
      bp_waitcyc(60);
      bp_send_pkt(32'd4, EXT_IP);
      bp_waitcyc(60);

      // --- 排空学习期残留, 清计数 ---
      bp_ev_mready = 1'b1;
      bp_waitcyc(120);
      @(negedge clk); bp_pkts_out = 0; bp_exp_pid = 0; bp_cur_beats = 0;
      bp_cnt_first = 0; bp_cnt_empty = 0; bp_cnt_buff = 0; bp_cnt_wr = 0; bp_max_occ = 0;
      bp_scb_en = 1'b1;

      // --- 压力: 交替目的 IP, 线速连发, 下游抖动反压 ---
      for (i = 0; i < 40; i = i + 1) begin
        bp_send_pkt(i[31:0], (i[0]) ? EXT_IP : PEER_IP);
      end

      // 停止反压, 排空
      bp_ev_mready = 1'b1;
      bp_waitcyc(200);

      $display("--- 压力测试(含下游随机反压) ---");
      $display("  输出包数            = %0d  (期望 40)", bp_pkts_out);
      $display("  s10 首拍握手        = %0d", bp_cnt_first);
      $display("    走 [实时] 分支    = %0d", bp_cnt_empty);
      $display("    走 [缓冲] 分支    = %0d   <== 关键覆盖率", bp_cnt_buff);
      $display("  arp_buf_wr_en 翻转  = %0d", bp_cnt_wr);
      $display("  buf 占用峰值        = %0d", bp_max_occ);
      if (bp_pkts_out != 40) begin
        $display("[FAIL] 丢包/包数不对"); bp_err = bp_err + 1;
      end
      $display("================================================================");
      if (bp_err == 0) $display(" PHASE 3 (stress): *** STRESS PASSED ***");
      else             $display(" PHASE 3 (stress): *** %0d 项失败 ***", bp_err);
      $display("================================================================");
      en_stress = 1'b0;
    end
  endtask

  // ==========================================================================
  // PHASE 4 : buf_probe (诊断量化, 不计入 PASS/FAIL)
  // ==========================================================================
  localparam [31:0] PROBE_HIT_A = 32'h3201_A8C0;
  localparam [31:0] PROBE_HIT_B = 32'h6401_A8C0;

  reg  [511:0] probe_sdata;
  reg  [ 63:0] probe_skeep;
  reg          probe_slast;
  reg          probe_svalid;
  wire         probe_sready;
  wire [511:0] probe_mdata;
  wire [ 63:0] probe_mkeep;
  wire         probe_mlast;
  wire         probe_mvalid;
  reg          probe_mready;
  wire [ 47:0] probe_dst_mac;
  wire [ 31:0] probe_query_dst_ip;
  wire [ 31:0] probe_query_src_ip;
  wire         probe_query_valid_pulse;
  reg  [ 47:0] probe_arp_mac;
  reg          probe_arp_miss;
  reg          probe_arp_valid;

  // probe ARP 行为模型: MD = 9
  reg        probe_qv  [0:9];
  reg [31:0] probe_qip [0:9];
  integer    probe_k;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      for (probe_k = 0; probe_k <= 9; probe_k = probe_k + 1) begin
        probe_qv [probe_k] <= 1'b0;
        probe_qip[probe_k] <= 32'd0;
      end
    end
    else begin
      probe_qv [0] <= probe_query_valid_pulse;
      probe_qip[0] <= probe_query_dst_ip;
      for (probe_k = 1; probe_k <= 9; probe_k = probe_k + 1) begin
        probe_qv [probe_k] <= probe_qv [probe_k-1];
        probe_qip[probe_k] <= probe_qip[probe_k-1];
      end
    end
  end
  always @(*) begin
    probe_arp_valid = probe_qv[9];
    probe_arp_miss  = (probe_qip[9] == MISS_IP);
    probe_arp_mac   = {16'hAAAA, probe_qip[9][15:0], 16'hBBBB};
  end

  ipv4_arp_service u_probe (
    .clk              (clk              ),
    .rst              (rst              ),
    .ipv4_axis_sdata  (probe_sdata      ),
    .ipv4_axis_skeep  (probe_skeep      ),
    .ipv4_axis_slast  (probe_slast      ),
    .ipv4_axis_svalid (probe_svalid     ),
    .ipv4_axis_susr   (4'd0             ),
    .ipv4_axis_sready (probe_sready     ),
    .ipv4_axis_mdata  (probe_mdata      ),
    .ipv4_axis_mkeep  (probe_mkeep      ),
    .ipv4_axis_mlast  (probe_mlast      ),
    .ipv4_axis_mvalid (probe_mvalid     ),
    .ipv4_axis_musr   (                 ),
    .ipv4_axis_mready (probe_mready     ),
    .dst_mac          (probe_dst_mac    ),
    .src_mac          (                 ),
    .query_dst_ip     (probe_query_dst_ip),
    .query_src_ip     (probe_query_src_ip),
    .query_valid_pulse(probe_query_valid_pulse),
    .arp_src_mac      (48'h0            ),
    .arp_dst_mac      (probe_arp_mac    ),
    .arp_miss         (probe_arp_miss   ),
    .arp_valid        (probe_arp_valid  )
  );

  integer probe_cnt_s10first, probe_cnt_first_empty, probe_cnt_first_buff;
  integer probe_cnt_take_live, probe_cnt_wr, probe_max_occ, probe_occ;
  integer probe_cnt_out;

  always @(posedge clk) begin
    if (en_probe && !rst) begin
      if (u_probe.s10_handshake && u_probe.is_first_beat_s10) begin
        probe_cnt_s10first = probe_cnt_s10first + 1;
        if (u_probe.arp_buf_empty) probe_cnt_first_empty = probe_cnt_first_empty + 1;
        else                       probe_cnt_first_buff  = probe_cnt_first_buff  + 1;
      end
      if (u_probe.arp_buf_take_live) probe_cnt_take_live = probe_cnt_take_live + 1;
      if (u_probe.arp_buf_wr_en)     probe_cnt_wr        = probe_cnt_wr        + 1;
      probe_occ = (u_probe.arp_buf_wr_ptr >= u_probe.arp_buf_rd_ptr)
                ? (u_probe.arp_buf_wr_ptr - u_probe.arp_buf_rd_ptr)
                : (u_probe.arp_buf_wr_ptr + 16 - u_probe.arp_buf_rd_ptr);
      if (probe_occ > probe_max_occ) probe_max_occ = probe_occ;
    end
  end

  always @(posedge clk) begin
    if (en_probe && !rst && probe_mvalid && probe_mready) begin
      $display("OUT %0d last=%0b pid=%0h bid=%0h mac=%h", probe_cnt_out, probe_mlast, probe_mdata[63:32], probe_mdata[31:0], probe_dst_mac);
      probe_cnt_out = probe_cnt_out + 1;
    end
  end

  task automatic probe_send_pkt(input [31:0] pid, input [31:0] dstip, input integer nbeats);
    integer b;
    begin
      for (b = 0; b < nbeats; b = b + 1) begin
        @(negedge clk);
        probe_sdata  = {352'd0, dstip, 32'h0A01_A8C0, 32'd0, pid, b[31:0]};
        probe_skeep  = 64'hFFFF_FFFF_FFFF_FFFF;
        probe_slast  = (b == nbeats - 1);
        probe_svalid = 1'b1;
        @(posedge clk);
        while (!(probe_svalid && probe_sready)) @(posedge clk);
      end
      @(negedge clk);
      probe_svalid = 1'b0;
      probe_slast  = 1'b0;
    end
  endtask

  task run_probe;
    begin
      en_probe = 1'b1;
      probe_sdata = 0; probe_skeep = 0; probe_slast = 0; probe_svalid = 0;
      probe_mready = 1'b1;
      probe_cnt_s10first = 0; probe_cnt_first_empty = 0; probe_cnt_first_buff = 0;
      probe_cnt_take_live = 0; probe_cnt_wr = 0; probe_max_occ = 0; probe_occ = 0;
      probe_cnt_out = 0;

      $display("================================================================");
      $display(" PHASE 4 : buf_probe (缓冲分支量化诊断, 不计入 PASS/FAIL)");
      $display("================================================================");

      rst = 1'b1;
      bp_waitcyc(20);
      rst = 1'b0;

      probe_send_pkt(1, MISS_IP,     3);
      bp_waitcyc(4);
      probe_send_pkt(2, PROBE_HIT_A, 3);
      bp_waitcyc(4);
      probe_send_pkt(3, PROBE_HIT_B, 1);
      bp_waitcyc(4);
      probe_send_pkt(4, MISS_IP,     1);
      bp_waitcyc(4);
      probe_send_pkt(5, PROBE_HIT_A, 1);
      probe_send_pkt(6, MISS_IP,     1);
      probe_send_pkt(7, PROBE_HIT_B, 1);
      probe_send_pkt(8, PROBE_HIT_A, 1);
      bp_waitcyc(60);

      $display("==================================================");
      $display("MD = 9  (ARP 结果延迟拍数)");
      $display("  s10 首拍握手次数        cnt_s10first     = %0d", probe_cnt_s10first);
      $display("  其中走 [实时] 分支       cnt_first_empty  = %0d", probe_cnt_first_empty);
      $display("  其中走 [缓冲] 分支       cnt_first_buff   = %0d", probe_cnt_first_buff);
      $display("  arp_buf_take_live 翻转  cnt_take_live    = %0d", probe_cnt_take_live);
      $display("  arp_buf_wr_en 翻转      cnt_wr           = %0d", probe_cnt_wr);
      $display("  buf 占用峰值            max_occ          = %0d", probe_max_occ);
      $display("  输出拍数                cnt_out          = %0d", probe_cnt_out);
      $display("==================================================");
      en_probe = 1'b0;
    end
  endtask

  // ==========================================================================
  // 主流程: 顺序执行各 phase
  // ==========================================================================
  initial begin
    $display("================================================================");
    $display(" tb_ipv4_arp_service : 合并回归开始 (单模块顺序 phase)");
    $display("================================================================");
    total_err = 0;

    run_hitmiss();
    total_err = total_err + hit_err;

    run_pipeline();
    total_err = total_err + pipe_err;

    run_stress();
    total_err = total_err + bp_err;

    run_probe();

    $display("");
    $display("================================================================");
    $display(" tb_ipv4_arp_service : 合并回归结束 —— 各 phase 结果:");
    $display("   - phase hitmiss      : %s", (hit_err  == 0) ? "PASS" : "FAIL");
    $display("   - phase pipeline     : %s", (pipe_err == 0) ? "PASS" : "FAIL");
    $display("   - phase stress       : %s", (bp_err   == 0) ? "PASS" : "FAIL");
    $display("   - phase buf_probe    : 诊断(不计入 PASS/FAIL)");
    $display("   累计失败 = %0d", total_err);
    if (total_err == 0) $display(" *** ALL TESTS PASSED ***");
    else                $display(" *** %0d CHECK(S) FAILED ***", total_err);
    $display("================================================================");
    $finish;
  end

  // 全局看门狗
  initial begin
    #20_000_000;
    $display("*** GLOBAL TIMEOUT ***");
    $finish;
  end

endmodule
