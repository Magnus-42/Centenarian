// ============================================================================
// TB : tb_axis_fifo_async   —— 单模块合并版
// ----------------------------------------------------------------------------
// axis_fifo_async 合并回归，整个测试台只有一个 module tb_axis_fifo_async。
//
// 原 3 个独立子测试合并为 3 个"顺序 phase"，各自独立 DUT + 时钟 + 信号前缀：
//   phase basic         基础功能（包模式 / 背靠背 / 反压 / 排空）     前缀 b_*
//   phase wraparound    指针回绕 + 慢读压力（写 100MHz / 读 38MHz）  前缀 w_*
//   phase random        随机包长 / 随机间隔 + 异步复位压力 + 超长包死锁演示 前缀 r_*
//
// 每个 phase 打印 PASS/FAIL；末尾统一汇总累计 err：
//   *** ALL TESTS PASSED ***   或   *** N CHECK(S) FAILED ***
//
// 编译/运行:
//   xvlog -work work -sv <RTL 排除 Backup/Top/Test> <RTL/Test> 本文件
//   xelab work.tb_axis_fifo_async -s snap_tb_axis_fifo_async
//   xsim snap_tb_axis_fifo_async -R
// ============================================================================

`timescale 1ns/100ps

module tb_axis_fifo_async;

  // ============================================================================
  // 全局编排与错误累计
  // ============================================================================
  integer total_err = 0;
  integer b_err     = 0;
  integer w_err     = 0;

  reg start_basic = 0;
  reg start_wrap  = 0;
  reg start_rand  = 0;
  reg done_basic  = 0;
  reg done_wrap   = 0;
  reg done_rand   = 0;

  // ============================================================================
  // Phase 1 : basic —— 包模式基础功能
  // ============================================================================
  localparam B_FIFO_DEPTH          = 32;
  localparam B_AXIS_WIDTH          = 64;
  localparam B_AXIS_USER_WIDTH     = 1;
  localparam B_AXIS_ID_WIDTH       = 1;
  localparam B_AXIS_DEST_WIDTH     = 1;
  localparam B_REMAIN_COUNT_WIDTH  = 6; // $clog2(32) + 1 = 6

  reg  b_srst;
  reg  b_sclk;
  reg  b_mclk;

  reg  [        B_AXIS_WIDTH-1:0] b_axis_sdata;
  reg  [      B_AXIS_WIDTH/8-1:0] b_axis_skeep;
  reg                             b_axis_svalid;
  reg                             b_axis_slast;
  wire                            b_axis_sready;
  reg  [   B_AXIS_USER_WIDTH-1:0] b_axis_susr;
  reg  [      B_AXIS_WIDTH/8-1:0] b_axis_sstrb;
  reg  [     B_AXIS_ID_WIDTH-1:0] b_axis_sid;
  reg  [   B_AXIS_DEST_WIDTH-1:0] b_axis_sdest;

  wire [        B_AXIS_WIDTH-1:0] b_axis_mdata;
  wire [      B_AXIS_WIDTH/8-1:0] b_axis_mkeep;
  wire                            b_axis_mvalid;
  wire                            b_axis_mlast;
  reg                             b_axis_mready;
  wire [   B_AXIS_USER_WIDTH-1:0] b_axis_musr;
  wire [      B_AXIS_WIDTH/8-1:0] b_axis_mstrb;
  wire [     B_AXIS_ID_WIDTH-1:0] b_axis_mid;
  wire [   B_AXIS_DEST_WIDTH-1:0] b_axis_mdest;

  wire                            b_prog_almost_empty;
  wire                            b_prog_almost_full;
  wire                            b_almost_empty;
  wire                            b_almost_full;
  wire [B_REMAIN_COUNT_WIDTH-1:0] b_wr_almost_remain_count;
  wire [B_REMAIN_COUNT_WIDTH-1:0] b_rd_almost_remain_count;

  initial begin b_sclk = 0; forever #5.0 b_sclk = ~b_sclk; end // 100MHz 写时钟
  initial begin b_mclk = 0; forever #3.3 b_mclk = ~b_mclk; end // ~151MHz 读时钟

  axis_fifo_async #(
    .FIFO_DEPTH       (B_FIFO_DEPTH),
    .AXIS_WIDTH       (B_AXIS_WIDTH),
    .AXIS_USER_WIDTH  (B_AXIS_USER_WIDTH),
    .AXIS_ID_WIDTH    (B_AXIS_ID_WIDTH),
    .AXIS_DEST_WIDTH  (B_AXIS_DEST_WIDTH),
    .PACKET_FIFO      (1),              // 测试关键: 开启整包模式
    .FIFO_MEMORY_TYPE ("block"),        // 测试关键: BRAM类型
    .BRAM_DO_REG      (2),              // 测试关键: 2级输出流水线
    .PROG_EMPTY_THRESH(B_FIFO_DEPTH/4),
    .PROG_FULL_THRESH (B_FIFO_DEPTH/2),
    .REMAIN_COUNT_WIDTH(B_REMAIN_COUNT_WIDTH)
  ) u_dut_basic (
    .srst                  (b_srst),
    .sclk                  (b_sclk),
    .mclk                  (b_mclk),
    .axis_sdata            (b_axis_sdata),
    .axis_skeep            (b_axis_skeep),
    .axis_svalid           (b_axis_svalid),
    .axis_slast            (b_axis_slast),
    .axis_sready           (b_axis_sready),
    .axis_susr            (b_axis_susr),
    .axis_sstrb            (b_axis_sstrb),
    .axis_sid              (b_axis_sid),
    .axis_sdest            (b_axis_sdest),
    .axis_mdata            (b_axis_mdata),
    .axis_mkeep            (b_axis_mkeep),
    .axis_mvalid           (b_axis_mvalid),
    .axis_mlast            (b_axis_mlast),
    .axis_mready           (b_axis_mready),
    .axis_musr            (b_axis_musr),
    .axis_mstrb            (b_axis_mstrb),
    .axis_mid              (b_axis_mid),
    .axis_mdest            (b_axis_mdest),
    .prog_almost_empty     (b_prog_almost_empty),
    .prog_almost_full      (b_prog_almost_full),
    .almost_empty          (b_almost_empty),
    .almost_full           (b_almost_full),
    .wr_almost_remain_count(b_wr_almost_remain_count),
    .rd_almost_remain_count(b_rd_almost_remain_count)
  );

  task b_send_packet;
    input integer length;
    input [7:0]   start_val;
    integer i;
    begin
      @(posedge b_sclk);
      for (i = 0; i < length; i = i + 1) begin
        b_axis_svalid <= 1'b1;
        b_axis_sdata  <= { {(B_AXIS_WIDTH-8){1'b0}}, start_val + i[7:0] };
        b_axis_skeep  <= {(B_AXIS_WIDTH/8){1'b1}};
        b_axis_sstrb  <= {(B_AXIS_WIDTH/8){1'b1}};
        b_axis_slast  <= (i == length - 1) ? 1'b1 : 1'b0;
        @(posedge b_sclk);
        while (!(b_axis_svalid && b_axis_sready)) begin
          @(posedge b_sclk);
        end
      end
      b_axis_svalid <= 1'b0;
      b_axis_slast  <= 1'b0;
    end
  endtask

  initial begin
    b_srst         = 1'b1;
    b_axis_svalid  = 1'b0;
    b_axis_sdata   = {B_AXIS_WIDTH{1'b0}};
    b_axis_skeep   = {(B_AXIS_WIDTH/8){1'b0}};
    b_axis_slast   = 1'b0;
    b_axis_susr   = {B_AXIS_USER_WIDTH{1'b0}};
    b_axis_sstrb   = {(B_AXIS_WIDTH/8){1'b0}};
    b_axis_sid     = {B_AXIS_ID_WIDTH{1'b0}};
    b_axis_sdest   = {B_AXIS_DEST_WIDTH{1'b0}};
    b_axis_mready  = 1'b0;
    b_err          = 0;
    wait (start_basic);

    #30;
    b_srst = 1'b0;
    #100;

    // ------------------------------------------------------------------
    // Case 1: 写入完整数据包并读出 (基础功能测试)
    // ------------------------------------------------------------------
    $display("[%0t] --- Case 1: Basic Write/Read ---", $time);
    b_send_packet(4, 8'hA0);

    #100;

    b_axis_mready = 1'b1;
    wait (b_axis_mvalid && b_axis_mlast);
    @(posedge b_mclk);
    b_axis_mready = 1'b0;

    #50;

    // ------------------------------------------------------------------
    // Case 2: 包模式(PACKET_FIFO=1) 防泄漏测试
    // ------------------------------------------------------------------
    $display("[%0t] --- Case 2: Packet Mode Leakage Test ---", $time);

    @(posedge b_sclk);
    b_axis_svalid <= 1'b1;
    b_axis_sdata  <= {{(B_AXIS_WIDTH-32){1'b0}}, 32'hDEADBEEF};
    b_axis_slast  <= 1'b0;

    @(posedge b_sclk);
    while (!(b_axis_svalid && b_axis_sready)) begin
      @(posedge b_sclk);
    end
    b_axis_svalid <= 1'b0;

    b_axis_mready = 1'b1;
    repeat (20) @(posedge b_mclk);
    if (b_axis_mvalid) begin
      $display("[%0t] [FAIL] Leakage Detected! mvalid asserted for incomplete packet.", $time);
      b_err = b_err + 1;
    end else begin
      $display("[%0t] [PASS] No leakage. Data is held in FIFO.", $time);
    end
    b_axis_mready = 1'b0;

    #20;
    b_send_packet(1, 8'hFF);

    #100;
    b_axis_mready = 1'b1;
    wait (b_axis_mvalid && b_axis_mlast);
    @(posedge b_mclk);
    b_axis_mready = 1'b0;

    #50;

    // ------------------------------------------------------------------
    // Case 3: 背靠背连续流与反压测试 (Fork-Join 并发)
    // ------------------------------------------------------------------
    $display("[%0t] --- Case 3: Back-to-Back & Backpressure ---", $time);
    fork
      begin
        b_send_packet(10, 8'h10);
        b_send_packet(8,  8'h20);
        b_send_packet(15, 8'h30);
      end
      begin
        #150;
        repeat (30) begin
          @(posedge b_mclk);
          b_axis_mready <= $random & 1'b1;
        end
        b_axis_mready <= 1'b1;
      end
    join

    wait (b_almost_empty == 1'b1);
    repeat (10) @(posedge b_mclk);
    b_axis_mready = 1'b0;

    $display("[%0t] --- Simulation Finished (basic) ---", $time);
    if (b_err == 0) $display("[%0t] [PHASE basic] PASS", $time);
    else            $display("[%0t] [PHASE basic] FAIL (err=%0d)", $time, b_err);
    done_basic = 1;
  end

  // ============================================================================
  // Phase 2 : wraparound —— 指针回绕 + 慢读压力
  // ============================================================================
  localparam W_FIFO_DEPTH = 32;
  localparam W_AW         = 32;
  localparam W_RCW        = 6;   // $clog2(32)+1
  localparam W_PLEN       = 3;   // 每个包的拍数
  localparam W_NPKT       = 21;  // NPKT*PLEN = 63 = 2*FIFO_DEPTH-1 (关键!)
  localparam W_MEMTYPE    = "block";
  localparam W_PKT        = 1;
  localparam W_DOREG      = 2;
  localparam W_PDW        = $clog2(W_FIFO_DEPTH); // 指针低位宽
  localparam W_PTR_MOD    = 2 * W_FIFO_DEPTH;     // 指针回绕模值

  reg                  w_srst;
  reg                  w_sclk;
  reg                  w_mclk;

  reg  [        W_AW-1:0] w_sdata;
  reg  [    W_AW/8 - 1:0] w_skeep;
  reg  [    W_AW/8 - 1:0] w_sstrb;
  reg                  w_svalid;
  reg                  w_slast;
  reg                  w_suser;
  reg                  w_sid;
  reg                  w_sdest;
  wire                 w_sready;

  wire [        W_AW-1:0] w_mdata;
  wire [    W_AW/8 - 1:0] w_mkeep;
  wire [    W_AW/8 - 1:0] w_mstrb;
  wire                 w_mvalid;
  wire                 w_mlast;
  wire                 w_musr;
  wire                 w_mid;
  wire                 w_mdest;
  reg                  w_mready;

  wire                 w_pae;
  wire                 w_paf;
  wire                 w_aempty;
  wire                 w_afull;
  wire [     W_RCW - 1:0] w_wrcnt;
  wire [     W_RCW - 1:0] w_rdcnt;

  initial begin w_sclk = 1'b0; forever #5.0  w_sclk = ~w_sclk; end // 写 100MHz
  initial begin w_mclk = 1'b0; forever #13.0 w_mclk = ~w_mclk; end // 读 ~38MHz

  axis_fifo_async #(
    .FIFO_DEPTH       (W_FIFO_DEPTH),
    .AXIS_WIDTH       (W_AW),
    .AXIS_USER_WIDTH  (1),
    .AXIS_ID_WIDTH    (1),
    .AXIS_DEST_WIDTH  (1),
    .PACKET_FIFO      (W_PKT),
    .FIFO_MEMORY_TYPE (W_MEMTYPE),
    .BRAM_DO_REG      (W_DOREG),
    .PROG_EMPTY_THRESH(W_FIFO_DEPTH / 4),
    .PROG_FULL_THRESH (W_FIFO_DEPTH / 2),
    .REMAIN_COUNT_WIDTH(W_RCW)
  ) u_dut_wrap (
    .srst                  (w_srst),
    .sclk                  (w_sclk),
    .mclk                  (w_mclk),
    .axis_sdata            (w_sdata),
    .axis_skeep            (w_skeep),
    .axis_svalid           (w_svalid),
    .axis_slast            (w_slast),
    .axis_sready           (w_sready),
    .axis_susr            (w_suser),
    .axis_sstrb            (w_sstrb),
    .axis_sid              (w_sid),
    .axis_sdest            (w_sdest),
    .axis_mdata            (w_mdata),
    .axis_mkeep            (w_mkeep),
    .axis_mvalid           (w_mvalid),
    .axis_mlast            (w_mlast),
    .axis_mready           (w_mready),
    .axis_musr            (w_musr),
    .axis_mstrb            (w_mstrb),
    .axis_mid              (w_mid),
    .axis_mdest            (w_mdest),
    .prog_almost_empty     (w_pae),
    .prog_almost_full      (w_paf),
    .almost_empty          (w_aempty),
    .almost_full           (w_afull),
    .wr_almost_remain_count(w_wrcnt),
    .rd_almost_remain_count(w_rdcnt)
  );

  // 发送队列 (背靠背满速, 不因 TB 打拍掩盖 DUT 吞吐问题)
  reg     [7:0] w_q_tag  [0:4095];
  reg           w_q_last [0:4095];
  integer       w_q_wr;
  integer       w_q_rd;
  integer       w_tag_next;

  task automatic w_push_beat(input [7:0] t, input l);
    begin
      w_q_tag[w_q_wr]  = t;
      w_q_last[w_q_wr] = l;
      w_q_wr           = w_q_wr + 1;
    end
  endtask

  task automatic w_push_pkt(input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) begin
        w_push_beat(w_tag_next[7:0], (i == n - 1));
        w_tag_next = w_tag_next + 1;
      end
    end
  endtask

  always @(negedge w_sclk) begin
    if (w_srst) begin
      w_svalid <= 1'b0;
    end else if (w_svalid === 1'b0 && w_q_rd < w_q_wr) begin
      w_sdata  <= {4{w_q_tag[w_q_rd]}};
      w_skeep  <= w_q_tag[w_q_rd][3:0];
      w_sstrb  <= ~w_q_tag[w_q_rd][3:0];
      w_suser  <= w_q_tag[w_q_rd][0];
      w_sid    <= w_q_tag[w_q_rd][1];
      w_sdest  <= w_q_tag[w_q_rd][2];
      w_slast  <= w_q_last[w_q_rd];
      w_svalid <= 1'b1;
      w_q_rd   <= w_q_rd + 1;
    end
  end

  integer w_sent;
  always @(posedge w_sclk) begin
    if (w_srst) begin
      w_svalid <= 1'b0;
      w_sent   <= 0;
    end else if (w_svalid && w_sready) begin
      w_svalid <= 1'b0;
      w_sent   <= w_sent + 1;
    end
  end

  // 接收端: 逐字段回算比对 + 计数
  reg     [7:0] w_exp_tag;
  integer       w_recv;
  integer       w_pkt_recv;

  always @(posedge w_mclk) begin
    if (!w_srst && w_mvalid && w_mready) begin
      if (w_mdata !== {4{w_exp_tag}}) begin
        $display("[%0t] [FAIL] data  beat#%0d exp=%h got=%h", $time, w_recv, {4{w_exp_tag}}, w_mdata);
        w_err <= w_err + 1;
      end
      if (w_mkeep !== w_exp_tag[3:0]) begin
        $display("[%0t] [FAIL] keep  beat#%0d exp=%h got=%h", $time, w_recv, w_exp_tag[3:0], w_mkeep);
        w_err <= w_err + 1;
      end
      if (w_mstrb !== ~w_exp_tag[3:0]) begin
        $display("[%0t] [FAIL] strb  beat#%0d exp=%h got=%h", $time, w_recv, ~w_exp_tag[3:0], w_mstrb);
        w_err <= w_err + 1;
      end
      if (w_musr !== w_exp_tag[0]) begin
        $display("[%0t] [FAIL] user  beat#%0d exp=%b got=%b", $time, w_recv, w_exp_tag[0], w_musr);
        w_err <= w_err + 1;
      end
      if (w_mid !== w_exp_tag[1]) begin
        $display("[%0t] [FAIL] id    beat#%0d exp=%b got=%b", $time, w_recv, w_exp_tag[1], w_mid);
        w_err <= w_err + 1;
      end
      if (w_mdest !== w_exp_tag[2]) begin
        $display("[%0t] [FAIL] dest  beat#%0d exp=%b got=%b", $time, w_recv, w_exp_tag[2], w_mdest);
        w_err <= w_err + 1;
      end
      if (w_mlast) w_pkt_recv <= w_pkt_recv + 1;
      w_exp_tag <= w_exp_tag + 1;
      w_recv    <= w_recv + 1;
    end
  end

  reg [1:0] w_mr_mode;
  always @(negedge w_mclk) begin
    case (w_mr_mode)
      2'd0:     w_mready <= 1'b1;
      2'd1:     w_mready <= 1'b0;
      default:  w_mready <= $random & 1'b1;
    endcase
  end

  // 占用深度探针
  integer       w_occ_max;
  integer       w_occ_mod;
  reg  [W_PDW:0] w_wv6;
  reg  [W_PDW:0] w_rsv6;
  wire [31:0]   w_sub32 = w_wv6 - w_rsv6;

  always @(posedge w_sclk) begin
    w_wv6  <= u_dut_wrap.wr_ptr_bin;
    w_rsv6 <= u_dut_wrap.rd_ptr_bin_sync;
  end

  always @(*) begin
    w_occ_mod = (w_wv6 >= w_rsv6) ? (w_wv6 - w_rsv6) : (w_wv6 + W_PTR_MOD - w_rsv6);
  end

  always @(posedge w_sclk) begin
    if (!w_srst && w_occ_mod > w_occ_max) w_occ_max <= w_occ_mod;
  end

  task automatic w_cyc_s(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) @(posedge w_sclk); end
  endtask

  task automatic w_drain_to(input integer n);
    integer tmo;
    begin
      tmo = 0;
      while (w_recv < n && tmo < 20000) begin
        @(negedge w_mclk);
        tmo = tmo + 1;
      end
      if (w_recv < n) begin
        $display("[%0t] [FAIL] drain timeout: expect %0d beats, got %0d (deadlock?)", $time, n, w_recv);
        w_err <= w_err + 1;
      end
    end
  endtask

  integer w_k;
  integer w_expect_pkts;
  initial begin
    w_srst     = 1'b1;
    w_svalid   = 1'b0;
    w_slast    = 1'b0;
    w_sdata    = {W_AW{1'b0}};
    w_skeep    = {(W_AW/8){1'b0}};
    w_sstrb    = {(W_AW/8){1'b0}};
    w_suser    = 1'b0;
    w_sid      = 1'b0;
    w_sdest    = 1'b0;
    w_mready   = 1'b0;
    w_mr_mode  = 2'd0;
    w_q_wr     = 0;
    w_q_rd     = 0;
    w_tag_next = 0;
    w_exp_tag  = 0;
    w_recv     = 0;
    w_pkt_recv = 0;
    w_sent     = 0;
    w_err      = 0;
    w_occ_max  = 0;
    wait (start_wrap);

    #200;
    w_srst = 1'b0;
    #200;

    // ------------------------------------------------------------------
    // Case A: 写指针回绕边界
    // ------------------------------------------------------------------
    $display("================================================================");
    $display("[%0t] --- Case A: write-pointer wrap boundary ---", $time);
    $display("        FIFO_DEPTH=%0d PTR_MOD=%0d  (NPKT*PLEN=%0d = PTR_MOD-1)",
             W_FIFO_DEPTH, W_PTR_MOD, W_NPKT * W_PLEN);
    w_mr_mode = 2'd0;

    for (w_k = 0; w_k < W_NPKT; w_k = w_k + 1) begin
      w_push_pkt(W_PLEN);
      w_drain_to(w_sent);
      w_drain_to((w_k + 1) * W_PLEN);
    end
    w_cyc_s(8);

    $display("        after %0d beats drained: wr_ptr=%0d rd_ptr_sync=%0d occ=%0d",
             W_NPKT * W_PLEN, w_wv6, w_rsv6, w_occ_mod);

    w_push_beat(w_tag_next[7:0], 1'b0);
    w_tag_next = w_tag_next + 1;
    w_cyc_s(8);

    $display("        after wrap   : wr_ptr=%0d rd_ptr_sync=%0d occ_mod=%0d sub32=%0d",
             w_wv6, w_rsv6, w_occ_mod, w_sub32);
    $display("        sready=%0b  (occ=%0d, 期望 sready=1)", w_sready, w_occ_mod);

    if (w_sready !== 1'b1) begin
      $display("[%0t] [FAIL] DEADLOCK: sready stuck low after write-pointer wrap", $time);
      $display("        wr_ptr_bin=%0d rd_ptr_bin_sync=%0d => (wr-rd)@32bit=%0d >= FIFO_DEPTH-1=%0d",
               w_wv6, w_rsv6, w_sub32, W_FIFO_DEPTH - 1);
      w_err = w_err + 1;
    end else begin
      $display("[%0t] [PASS] no false-full after wrap (sready=1)", $time);
    end

    w_push_beat(w_tag_next[7:0], 1'b1);
    w_tag_next = w_tag_next + 1;
    w_cyc_s(8);
    w_drain_to(W_NPKT * W_PLEN + 2);
    if (w_recv !== W_NPKT * W_PLEN + 2) begin
      $display("[%0t] [FAIL] cannot recover after wrap: recv=%0d exp=%0d", $time, w_recv, W_NPKT * W_PLEN + 2);
      w_err = w_err + 1;
    end else begin
      $display("[%0t] [PASS] recovered, recv=%0d", $time, w_recv);
    end

    // ------------------------------------------------------------------
    // Case B: 填满测试 (读慢于写 + 随机反压)
    // ------------------------------------------------------------------
    $display("----------------------------------------------------------------");
    $display("[%0t] --- Case B: fill up with random backpressure ---", $time);
    w_occ_max  = 0;
    w_expect_pkts = w_pkt_recv + 20;
    for (w_k = 0; w_k < 20; w_k = w_k + 1) w_push_pkt(8);

    w_mr_mode = 2'd2;
    w_cyc_s(200);
    w_mr_mode = 2'd0;
    w_drain_to(W_NPKT * W_PLEN + 2 + 160);

    $display("        MAX_OCC=%0d / FIFO_DEPTH=%0d", w_occ_max, W_FIFO_DEPTH);
    if (w_occ_max < W_FIFO_DEPTH - 2) begin
      $display("[%0t] [FAIL] FIFO never filled (MAX_OCC=%0d) -> this run does not cover full logic",
               $time, w_occ_max);
      w_err = w_err + 1;
    end else begin
      $display("[%0t] [PASS] FIFO filled to %0d", $time, w_occ_max);
    end

    if (w_recv !== W_NPKT * W_PLEN + 2 + 160) begin
      $display("[%0t] [FAIL] beat count: recv=%0d exp=%0d", $time, w_recv, W_NPKT * W_PLEN + 162);
      w_err = w_err + 1;
    end
    if (w_pkt_recv !== w_expect_pkts) begin
      $display("[%0t] [FAIL] packet count: got %0d exp %0d", $time, w_pkt_recv, w_expect_pkts);
      w_err = w_err + 1;
    end

    // 汇总
    $display("================================================================");
    if (w_err == 0) $display(" [PHASE wraparound] *** ALL CHECKS PASSED *** (recv=%0d pkts=%0d MAX_OCC=%0d)",
                              w_recv, w_pkt_recv, w_occ_max);
    else            $display(" [PHASE wraparound] *** %0d CHECK(S) FAILED ***", w_err);
    done_wrap = 1;
  end

  // ============================================================================
  // Phase 3 : random —— 随机包长/间隔 + 异步复位压力 + 超长包死锁演示
  // ============================================================================
  localparam R_FIFO_DEPTH         = 64;
  localparam R_AXIS_WIDTH         = 64;
  localparam R_AXIS_USER_WIDTH    = 1;
  localparam R_AXIS_ID_WIDTH      = 1;
  localparam R_AXIS_DEST_WIDTH    = 1;
  localparam R_REMAIN_COUNT_WIDTH = 6;

  reg  r_srst;
  reg  r_sclk;
  reg  r_mclk;

  reg  [        R_AXIS_WIDTH-1:0] r_axis_sdata;
  reg  [      R_AXIS_WIDTH/8-1:0] r_axis_skeep;
  reg                             r_axis_svalid;
  reg                             r_axis_slast;
  wire                            r_axis_sready;
  reg  [   R_AXIS_USER_WIDTH-1:0] r_axis_susr;
  reg  [      R_AXIS_WIDTH/8-1:0] r_axis_sstrb;
  reg  [     R_AXIS_ID_WIDTH-1:0] r_axis_sid;
  reg  [   R_AXIS_DEST_WIDTH-1:0] r_axis_sdest;

  wire [        R_AXIS_WIDTH-1:0] r_axis_mdata;
  wire [      R_AXIS_WIDTH/8-1:0] r_axis_mkeep;
  wire                            r_axis_mvalid;
  wire                            r_axis_mlast;
  wire [   R_AXIS_USER_WIDTH-1:0] r_axis_musr;
  wire [      R_AXIS_WIDTH/8-1:0] r_axis_mstrb;
  wire [     R_AXIS_ID_WIDTH-1:0] r_axis_mid;
  wire [   R_AXIS_DEST_WIDTH-1:0] r_axis_mdest;
  reg                             r_axis_mready;

  wire                            r_prog_almost_empty;
  wire                            r_prog_almost_full;
  wire                            r_almost_empty;
  wire                            r_almost_full;
  wire [R_REMAIN_COUNT_WIDTH-1:0] r_wr_almost_remain_count;
  wire [R_REMAIN_COUNT_WIDTH-1:0] r_rd_almost_remain_count;

  initial begin r_sclk = 1'b0; forever #5.0 r_sclk = ~r_sclk; end // 100MHz 写时钟
  initial begin r_mclk = 1'b0; forever #3.3 r_mclk = ~r_mclk; end // ~151.5MHz 读时钟

  axis_fifo_async #(
    .FIFO_DEPTH       (R_FIFO_DEPTH),
    .AXIS_WIDTH       (R_AXIS_WIDTH),
    .AXIS_USER_WIDTH  (R_AXIS_USER_WIDTH),
    .AXIS_ID_WIDTH    (R_AXIS_ID_WIDTH),
    .AXIS_DEST_WIDTH  (R_AXIS_DEST_WIDTH),
    .PACKET_FIFO      (1),
    .FIFO_MEMORY_TYPE ("block"),
    .BRAM_DO_REG      (2),
    .PROG_EMPTY_THRESH(R_FIFO_DEPTH/4),
    .PROG_FULL_THRESH (R_FIFO_DEPTH/2),
    .REMAIN_COUNT_WIDTH(R_REMAIN_COUNT_WIDTH)
  ) u_dut_rand (
    .srst                  (r_srst),
    .sclk                  (r_sclk),
    .mclk                  (r_mclk),
    .axis_sdata            (r_axis_sdata),
    .axis_skeep            (r_axis_skeep),
    .axis_svalid           (r_axis_svalid),
    .axis_slast            (r_axis_slast),
    .axis_sready           (r_axis_sready),
    .axis_susr            (r_axis_susr),
    .axis_sstrb            (r_axis_sstrb),
    .axis_sid              (r_axis_sid),
    .axis_sdest            (r_axis_sdest),
    .axis_mdata            (r_axis_mdata),
    .axis_mkeep            (r_axis_mkeep),
    .axis_mvalid           (r_axis_mvalid),
    .axis_mlast            (r_axis_mlast),
    .axis_mready           (r_axis_mready),
    .axis_musr            (r_axis_musr),
    .axis_mstrb            (r_axis_mstrb),
    .axis_mid              (r_axis_mid),
    .axis_mdest            (r_axis_mdest),
    .prog_almost_empty     (r_prog_almost_empty),
    .prog_almost_full      (r_prog_almost_full),
    .almost_empty          (r_almost_empty),
    .almost_full           (r_almost_full),
    .wr_almost_remain_count(r_wr_almost_remain_count),
    .rd_almost_remain_count(r_rd_almost_remain_count)
  );

  // 参考模型 (scoreboard)
  integer r_q_wr, r_q_rd;
  integer r_wr_pkts, r_rd_pkts;
  integer r_err_score, r_err_proto;
  reg  [        R_AXIS_WIDTH-1:0] r_seq;
  reg  [        R_AXIS_WIDTH-1:0] r_q_data [0:65535];
  reg  [      R_AXIS_WIDTH/8-1:0] r_q_keep [0:65535];
  reg  [   R_AXIS_USER_WIDTH-1:0] r_q_user [0:65535];
  reg                             r_q_last [0:65535];

  always @(posedge r_sclk) begin
    if (!r_srst && r_axis_svalid && r_axis_sready) begin
      r_q_data[r_q_wr] <= r_axis_sdata;
      r_q_keep[r_q_wr] <= r_axis_skeep;
      r_q_user[r_q_wr] <= r_axis_susr;
      r_q_last[r_q_wr] <= r_axis_slast;
      r_q_wr <= r_q_wr + 1;
      if (r_axis_slast) r_wr_pkts <= r_wr_pkts + 1;
    end
  end

  always @(posedge r_mclk) begin
    if (!r_srst && r_axis_mvalid && r_axis_mready) begin
      if (r_q_rd == r_q_wr) begin
        r_err_score = r_err_score + 1;
        $display("[%0t] SCOREBOARD ERROR: read while model empty", $time);
      end else begin
        if (r_axis_mdata !== r_q_data[r_q_rd]) begin
          r_err_score = r_err_score + 1;
          $display("[%0t] SCOREBOARD ERROR beat %0d data: got %h expected %h", $time, r_q_rd, r_axis_mdata, r_q_data[r_q_rd]);
        end
        if (r_axis_mkeep !== r_q_keep[r_q_rd]) begin
          r_err_score = r_err_score + 1;
          $display("[%0t] SCOREBOARD ERROR beat %0d keep: got %h expected %h", $time, r_q_rd, r_axis_mkeep, r_q_keep[r_q_rd]);
        end
        if (r_axis_musr !== r_q_user[r_q_rd]) begin
          r_err_score = r_err_score + 1;
          $display("[%0t] SCOREBOARD ERROR beat %0d user: got %b expected %b", $time, r_q_rd, r_axis_musr, r_q_user[r_q_rd]);
        end
        if (r_axis_mlast !== r_q_last[r_q_rd]) begin
          r_err_score = r_err_score + 1;
          $display("[%0t] SCOREBOARD ERROR beat %0d last: got %b expected %b", $time, r_q_rd, r_axis_mlast, r_q_last[r_q_rd]);
        end
        r_q_rd <= r_q_rd + 1;
        if (r_axis_mlast) r_rd_pkts <= r_rd_pkts + 1;
      end
    end
  end

  // AXI-Stream 协议检查
  reg                             r_hold_v;
  reg  [        R_AXIS_WIDTH-1:0] r_hold_data;
  reg  [      R_AXIS_WIDTH/8-1:0] r_hold_keep;
  reg                             r_hold_last;
  reg  [   R_AXIS_USER_WIDTH-1:0] r_hold_user;

  always @(posedge r_mclk) begin
    if (r_srst) begin
      r_hold_v <= 1'b0;
    end else begin
      if (r_hold_v) begin
        if (!r_axis_mvalid) begin
          r_err_proto = r_err_proto + 1;
          $display("[%0t] PROTOCOL ERROR: mvalid deasserted before handshake", $time);
        end else if (r_axis_mdata !== r_hold_data || r_axis_mkeep !== r_hold_keep ||
                     r_axis_mlast !== r_hold_last || r_axis_musr !== r_hold_user) begin
          r_err_proto = r_err_proto + 1;
          $display("[%0t] PROTOCOL ERROR: stalled beat payload changed", $time);
        end
      end
      if (r_axis_mvalid && !r_axis_mready) begin
        r_hold_v    <= 1'b1;
        r_hold_data <= r_axis_mdata;
        r_hold_keep <= r_axis_mkeep;
        r_hold_last <= r_axis_mlast;
        r_hold_user <= r_axis_musr;
      end else begin
        r_hold_v <= 1'b0;
      end
    end
  end

  // 读端 mready 驱动: rd_mode 0=强制低 1=随机(70%高) 2=强制高(排空)
  reg [1:0] r_rd_mode;
  integer   r_r;
  always @(posedge r_mclk) begin
    r_r = $random;
    if (r_r < 0) r_r = -r_r;
    case (r_rd_mode)
      2'd0: r_axis_mready <= 1'b0;
      2'd1: r_axis_mready <= ((r_r % 10) < 7);
      2'd2: r_axis_mready <= 1'b1;
    endcase
  end

  task r_send_rand_packet;
    integer len, i, r;
    begin
      r = $random; if (r < 0) r = -r;
      len = 1 + (r % 20);
      for (i = 0; i < len; i = i + 1) begin
        @(posedge r_sclk);
        r_axis_sdata  <= r_seq;
        r_axis_skeep  <= {(R_AXIS_WIDTH/8){1'b1}};
        r_axis_susr  <= $random;
        r_axis_slast  <= (i == len - 1);
        r_axis_svalid <= 1'b1;
        if (i == len - 1) begin
          r = $random; if (r < 0) r = -r;
          r_axis_skeep <= r;
        end
        r_seq <= r_seq + 1;
        @(posedge r_sclk);
        while (!(r_axis_svalid && r_axis_sready)) @(posedge r_sclk);
        r = $random; if (r < 0) r = -r;
        if ((r % 5) == 0) begin
          r_axis_svalid <= 1'b0;
          repeat (1 + (r % 4)) @(posedge r_sclk);
        end
      end
      r_axis_svalid <= 1'b0;
      r_axis_slast  <= 1'b0;
    end
  endtask

  task r_send_partial_no_last;
    input integer len;
    integer i;
    begin
      for (i = 0; i < len; i = i + 1) begin
        @(posedge r_sclk);
        r_axis_sdata  <= r_seq;
        r_axis_skeep  <= {(R_AXIS_WIDTH/8){1'b1}};
        r_axis_susr  <= $random;
        r_axis_slast  <= 1'b0;
        r_axis_svalid <= 1'b1;
        r_seq <= r_seq + 1;
        @(posedge r_sclk);
        while (!(r_axis_svalid && r_axis_sready)) @(posedge r_sclk);
      end
      r_axis_svalid <= 1'b0;
    end
  endtask

  integer r_i;
  initial begin
    for (r_i = 0; r_i < 65536; r_i = r_i + 1) begin
      r_q_data[r_i] = 'd0;
      r_q_keep[r_i] = 'd0;
      r_q_user[r_i] = 'd0;
      r_q_last[r_i] = 'd0;
    end
    r_hold_v    = 'd0;
    r_hold_data = 'd0;
    r_hold_keep = 'd0;
    r_hold_last = 'd0;
    r_hold_user = 'd0;
    r_r         = 'd0;
  end

  integer r_p = 'd0, r_rand = 'd0;
  integer r_ov_rd_pkts_before = 0;
  initial begin
    r_srst        = 1'b1;
    r_rd_mode     = 2'd0;
    r_q_wr = 0; r_q_rd = 0; r_wr_pkts = 0; r_rd_pkts = 0;
    r_err_score = 0; r_err_proto = 0;
    r_seq = {R_AXIS_WIDTH{1'b0}};
    r_axis_svalid = 1'b0; r_axis_sdata = {R_AXIS_WIDTH{1'b0}};
    r_axis_skeep = {(R_AXIS_WIDTH/8){1'b0}}; r_axis_slast = 1'b0;
    r_axis_susr = {R_AXIS_USER_WIDTH{1'b0}};
    r_axis_sstrb = {(R_AXIS_WIDTH/8){1'b0}};
    r_axis_sid = {R_AXIS_ID_WIDTH{1'b0}};
    r_axis_sdest = {R_AXIS_DEST_WIDTH{1'b0}};
    wait (start_rand);

    #100;
    r_srst = 1'b0;
    #50;

    // ------------------------------------------------------------------
    // Phase 1: 压力测试 300 包
    // ------------------------------------------------------------------
    $display("[%0t] === Phase 1: stress (300 pkts, random len/gap/backpressure) ===", $time);
    r_rd_mode = 2'd1;
    for (r_p = 0; r_p < 300; r_p = r_p + 1) begin
      r_send_rand_packet;
      r_rand = $random; if (r_rand < 0) r_rand = -r_rand;
      if ((r_rand % 3) == 0) repeat (1 + (r_rand % 5)) @(posedge r_sclk);
    end
    r_rd_mode = 2'd2;
    wait (r_q_rd == r_q_wr);
    repeat (30) @(posedge r_mclk);
    if (r_axis_mvalid !== 1'b0) begin
      r_err_score = r_err_score + 1;
      $display("[%0t] ERROR: mvalid still high after drain", $time);
    end
    if (r_rd_pkts != 300) begin
      r_err_score = r_err_score + 1;
      $display("[%0t] ERROR: P1 packet count: wrote 300, read %0d", $time, r_rd_pkts);
    end
    $display("[%0t] Phase 1 done: beats=%0d pkts=%0d err_score=%0d err_proto=%0d", $time, r_q_rd, r_rd_pkts, r_err_score, r_err_proto);
    r_rd_mode = 2'd0;

    // ------------------------------------------------------------------
    // Phase 2: 流量中异步复位
    // ------------------------------------------------------------------
    $display("[%0t] === Phase 2: async reset during traffic ===", $time);
    r_rd_mode = 2'd1;
    for (r_p = 0; r_p < 10; r_p = r_p + 1) r_send_rand_packet;
    #347;
    r_srst = 1'b1;
    #53;
    r_q_wr = 0; r_q_rd = 0; r_wr_pkts = 0; r_rd_pkts = 0;
    #47;
    r_srst = 1'b0;
    r_rd_mode = 2'd0;
    repeat (30) @(posedge r_mclk);
    if (r_axis_mvalid !== 1'b0) begin
      r_err_score = r_err_score + 1;
      $display("[%0t] ERROR: mvalid high after reset", $time);
    end
    if (r_axis_sready !== 1'b1) begin
      r_err_score = r_err_score + 1;
      $display("[%0t] ERROR: sready low after reset", $time);
    end
    $display("[%0t] Phase 2 done: post-reset state clean", $time);

    // ------------------------------------------------------------------
    // Phase 3: 复位后恢复压测 150 包
    // ------------------------------------------------------------------
    $display("[%0t] === Phase 3: stress after reset (150 pkts) ===", $time);
    r_rd_mode = 2'd1;
    for (r_p = 0; r_p < 150; r_p = r_p + 1) begin
      r_send_rand_packet;
      r_rand = $random; if (r_rand < 0) r_rand = -r_rand;
      if ((r_rand % 3) == 0) repeat (1 + (r_rand % 4)) @(posedge r_sclk);
    end
    r_rd_mode = 2'd2;
    wait (r_q_rd == r_q_wr);
    repeat (30) @(posedge r_mclk);
    if (r_axis_mvalid !== 1'b0) begin
      r_err_score = r_err_score + 1;
      $display("[%0t] ERROR: mvalid high after drain P3", $time);
    end
    if (r_rd_pkts != 150) begin
      r_err_score = r_err_score + 1;
      $display("[%0t] ERROR: P3 packet count: wrote 150, read %0d", $time, r_rd_pkts);
    end
    $display("[%0t] Phase 3 done: beats=%0d pkts=%0d", $time, r_q_rd, r_rd_pkts);
    r_rd_mode = 2'd0;

    // ------------------------------------------------------------------
    // Phase 4: 超长包(未收尾, 无 tlast)死锁行为演示
    // ------------------------------------------------------------------
    $display("[%0t] === Phase 4: oversized packet (FIFO_DEPTH+8 beats > depth %0d) ===", $time, R_FIFO_DEPTH);
    r_rd_mode = 2'd0;
    repeat (10) @(posedge r_mclk);
    r_ov_rd_pkts_before = r_rd_pkts;
    fork : r_ov_blk
      begin : r_ov_wr
        r_send_partial_no_last(R_FIFO_DEPTH + 8);
      end
      begin : r_ov_watch
        repeat (400) @(posedge r_sclk);
        disable r_ov_blk;
      end
    join
    r_axis_svalid = 1'b0;
    repeat (10) @(posedge r_sclk);
    $display("[%0t] Oversize (read frozen): sready=%b mvalid=%b wr_remain=%0d wr_beats=%0d rd_beats=%0d",
             $time, r_axis_sready, r_axis_mvalid, r_wr_almost_remain_count, r_q_wr, r_q_rd);
    r_rd_mode = 2'd2;
    repeat (300) @(posedge r_mclk);
    $display("[%0t] Oversize (read released): sready=%b mvalid=%b wr_remain=%0d wr_beats=%0d rd_beats=%0d rd_pkts=%0d",
             $time, r_axis_sready, r_axis_mvalid, r_wr_almost_remain_count, r_q_wr, r_q_rd, r_rd_pkts);
    if (r_rd_pkts == r_ov_rd_pkts_before) begin
      $display("[%0t] NOTE: 未收尾的超长包永远不会被交付 (rd_pkts=%0d 未增加) - PACKET_FIFO=1 的已知限制", $time, r_rd_pkts);
    end else begin
      r_err_score = r_err_score + 1;
      $display("[%0t] UNEXPECTED: 未收尾的超长包被当成完整包交付了 (rd_pkts %0d -> %0d)", $time, r_ov_rd_pkts_before, r_rd_pkts);
    end
    r_srst = 1'b1; #53;
    r_q_wr = 0; r_q_rd = 0; r_wr_pkts = 0; r_rd_pkts = 0;
    #47; r_srst = 1'b0;
    repeat (30) @(posedge r_mclk);
    if (r_axis_mvalid !== 1'b0 || r_axis_sready !== 1'b1) begin
      r_err_score = r_err_score + 1;
      $display("[%0t] ERROR: no recovery after oversize reset", $time);
    end

    // 汇总
    if (r_err_score == 0 && r_err_proto == 0)
      $display("[%0t] [PHASE random] ============ ALL CHECKS PASSED ============", $time);
    else
      $display("[%0t] [PHASE random] ============ FAILED: err_score=%0d err_proto=%0d ============", $time, r_err_score, r_err_proto);
    done_rand = 1;
  end

  // ============================================================================
  // 编排: 顺序执行 3 个 phase, 末尾统一汇总
  // ============================================================================
  initial begin
    start_basic = 0;
    start_wrap  = 0;
    start_rand  = 0;
    #100;

    start_basic = 1;
    wait (done_basic === 1'b1);
    $display("[ORCH] basic phase finished, b_err=%0d", b_err);

    start_wrap = 1;
    wait (done_wrap === 1'b1);
    $display("[ORCH] wraparound phase finished, w_err=%0d", w_err);

    start_rand = 1;
    wait (done_rand === 1'b1);
    $display("[ORCH] random phase finished, err_score=%0d err_proto=%0d", r_err_score, r_err_proto);

    total_err = b_err + w_err + r_err_score + r_err_proto;

    $display("");
    $display("================================================================");
    $display(" tb_axis_fifo_async : 合并回归结束 —— 各 phase 结果:");
    $display("   - phase basic      : %s (err=%0d)", (b_err == 0) ? "PASS" : "FAIL", b_err);
    $display("   - phase wraparound : %s (err=%0d)", (w_err == 0) ? "PASS" : "FAIL", w_err);
    $display("   - phase random     : %s (err=%0d)", ((r_err_score + r_err_proto) == 0) ? "PASS" : "FAIL", r_err_score + r_err_proto);
    $display("================================================================");
    if (total_err == 0) begin
      $display("*** ALL TESTS PASSED ***");
    end else begin
      $display("*** %0d CHECK(S) FAILED ***", total_err);
    end
    $finish;
  end

  // 全局看门狗
  initial begin
    #20_000_000;
    $display("*** GLOBAL TIMEOUT ***");
    $finish;
  end

endmodule
