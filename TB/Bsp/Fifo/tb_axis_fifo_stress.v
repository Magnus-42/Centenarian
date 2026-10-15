`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_axis_fifo_stress.v
// Module Name : tb_axis_fifo_stress
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-09-14
// ----------------------------------------------------------------------------
// Description : axis_fifo_async 压力测试台 (比 tb_axis_fifo_async 覆盖更强)
//   1. 随机包长(1..20)/随机包间隔/随机拍间隔(valid gap) + 随机 mready 反压
//   2. 参考模型逐拍比对 data/keep/user/last (scoreboard)
//   3. AXI-Stream 协议检查: valid 悬挂未握手期间 payload 必须保持稳定
//   4. 流量中异步复位 + 复位后恢复压测
//   5. 超长包(>FIFO_DEPTH)死锁演示 (PACKET_FIFO=1 的已知设计限制)
// ============================================================================
module tb_axis_fifo_stress;
  parameter FIFO_DEPTH         = 64;
  parameter AXIS_WIDTH         = 64;
  parameter AXIS_USER_WIDTH    = 1;
  parameter AXIS_ID_WIDTH      = 1;
  parameter AXIS_DEST_WIDTH    = 1;
  parameter REMAIN_COUNT_WIDTH = 6;

  reg  srst;
  reg  sclk = 1'b0;
  reg  mclk = 1'b0;
  always #5.0 sclk = ~sclk; // 100MHz 写时钟
  always #3.3 mclk = ~mclk; // ~151.5MHz 读时钟 (异步)

  // DUT slave 侧 (TB 驱动)
  reg  [        AXIS_WIDTH-1: 0]       axis_sdata;
  reg  [      AXIS_WIDTH/8-1: 0]       axis_skeep;
  reg                                  axis_svalid;
  reg                                  axis_slast;
  wire                                 axis_sready;
  reg  [   AXIS_USER_WIDTH-1: 0]       axis_suser;
  reg  [      AXIS_WIDTH/8-1: 0]       axis_sstrb;
  reg  [     AXIS_ID_WIDTH-1: 0]       axis_sid;
  reg  [   AXIS_DEST_WIDTH-1: 0]       axis_sdest;

  // DUT master 侧
  wire [        AXIS_WIDTH-1: 0]       axis_mdata;
  wire [      AXIS_WIDTH/8-1: 0]       axis_mkeep;
  wire                                 axis_mvalid;
  wire                                 axis_mlast;
  wire [   AXIS_USER_WIDTH-1: 0]       axis_muser;
  wire [      AXIS_WIDTH/8-1: 0]       axis_mstrb;
  wire [     AXIS_ID_WIDTH-1: 0]       axis_mid;
  wire [   AXIS_DEST_WIDTH-1: 0]       axis_mdest;
  reg                                  axis_mready;

  wire                                 prog_almost_empty;
  wire                                 prog_almost_full;
  wire                                 almost_empty;
  wire                                 almost_full;
  wire [REMAIN_COUNT_WIDTH-1: 0]       wr_almost_remain_count;
  wire [REMAIN_COUNT_WIDTH-1: 0]       rd_almost_remain_count;

  axis_fifo_async #(
    .FIFO_DEPTH       (FIFO_DEPTH       ),
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .AXIS_ID_WIDTH    (AXIS_ID_WIDTH    ),
    .AXIS_DEST_WIDTH  (AXIS_DEST_WIDTH  ),
    .PACKET_FIFO      (1                ),
    .FIFO_MEMORY_TYPE ("block"          ),
    .BRAM_DO_REG      (2                ),
    .PROG_EMPTY_THRESH(FIFO_DEPTH/4     ),
    .PROG_FULL_THRESH (FIFO_DEPTH/2     ),
    .REMAIN_COUNT_WIDTH(REMAIN_COUNT_WIDTH)
  ) dut (
    .srst                  (srst                  ),
    .sclk                  (sclk                  ),
    .mclk                  (mclk                  ),
    .axis_sdata            (axis_sdata            ),
    .axis_skeep            (axis_skeep            ),
    .axis_svalid           (axis_svalid           ),
    .axis_slast            (axis_slast            ),
    .axis_sready           (axis_sready           ),
    .axis_suser            (axis_suser            ),
    .axis_sstrb           (axis_sstrb            ),
    .axis_sid              (axis_sid              ),
    .axis_sdest            (axis_sdest            ),
    .axis_mdata            (axis_mdata            ),
    .axis_mkeep            (axis_mkeep            ),
    .axis_mvalid           (axis_mvalid           ),
    .axis_mlast            (axis_mlast            ),
    .axis_mready           (axis_mready           ),
    .axis_muser            (axis_muser            ),
    .axis_mstrb            (axis_mstrb            ),
    .axis_mid              (axis_mid              ),
    .axis_mdest            (axis_mdest            ),
    .prog_almost_empty     (prog_almost_empty     ),
    .prog_almost_full      (prog_almost_full      ),
    .almost_empty          (almost_empty          ),
    .almost_full           (almost_full           ),
    .wr_almost_remain_count(wr_almost_remain_count),
    .rd_almost_remain_count(rd_almost_remain_count)
  );

  // ============================================================================
  // 参考模型 (scoreboard)
  // ============================================================================
  integer q_wr, q_rd;                       // 模型节拍指针
  integer wr_pkts, rd_pkts;                 // 模型包计数
  integer err_score, err_proto;             // 错误计数 (各自单一 always 块内更新)
  reg  [        AXIS_WIDTH-1: 0]       seq; // 全局唯一数据序列
  reg  [        AXIS_WIDTH-1: 0]       q_data [0:65535];
  reg  [      AXIS_WIDTH/8-1: 0]       q_keep [0:65535];
  reg  [   AXIS_USER_WIDTH-1: 0]       q_user [0:65535];
  reg                                  q_last [0:65535];

  // 写侧镜像: 每次 sclk 域握手, 记录写入的节拍
  always @(posedge sclk) begin
    if (!srst && axis_svalid && axis_sready) begin
      q_data[q_wr] <= axis_sdata;
      q_keep[q_wr] <= axis_skeep;
      q_user[q_wr] <= axis_suser;
      q_last[q_wr] <= axis_slast;
      q_wr <= q_wr + 1;
      if (axis_slast) wr_pkts <= wr_pkts + 1;
    end
  end

  // 读侧记分板: 每次 mclk 域握手, 逐项比对
  always @(posedge mclk) begin
    if (!srst && axis_mvalid && axis_mready) begin
      if (q_rd == q_wr) begin
        err_score = err_score + 1;
        $display("[%0t] SCOREBOARD ERROR: read while model empty", $time);
      end else begin
        if (axis_mdata !== q_data[q_rd]) begin
          err_score = err_score + 1;
          $display("[%0t] SCOREBOARD ERROR beat %0d data: got %h expected %h", $time, q_rd, axis_mdata, q_data[q_rd]);
        end
        if (axis_mkeep !== q_keep[q_rd]) begin
          err_score = err_score + 1;
          $display("[%0t] SCOREBOARD ERROR beat %0d keep: got %h expected %h", $time, q_rd, axis_mkeep, q_keep[q_rd]);
        end
        if (axis_muser !== q_user[q_rd]) begin
          err_score = err_score + 1;
          $display("[%0t] SCOREBOARD ERROR beat %0d user: got %b expected %b", $time, q_rd, axis_muser, q_user[q_rd]);
        end
        if (axis_mlast !== q_last[q_rd]) begin
          err_score = err_score + 1;
          $display("[%0t] SCOREBOARD ERROR beat %0d last: got %b expected %b", $time, q_rd, axis_mlast, q_last[q_rd]);
        end
        q_rd <= q_rd + 1;
        if (axis_mlast) rd_pkts <= rd_pkts + 1;
      end
    end
  end

  // ============================================================================
  // AXI-Stream 协议检查: valid 悬挂(未握手)期间 payload 不得变化, valid 不得撤回
  // ============================================================================
  reg                                  hold_v;
  reg  [        AXIS_WIDTH-1: 0]       hold_data;
  reg  [      AXIS_WIDTH/8-1: 0]       hold_keep;
  reg                                  hold_last;
  reg  [   AXIS_USER_WIDTH-1: 0]       hold_user;

  always @(posedge mclk) begin
    if (srst) begin
      hold_v <= 1'b0;
    end else begin
      if (hold_v) begin
        if (!axis_mvalid) begin
          err_proto = err_proto + 1;
          $display("[%0t] PROTOCOL ERROR: mvalid deasserted before handshake", $time);
        end else if (axis_mdata !== hold_data || axis_mkeep !== hold_keep ||
                     axis_mlast !== hold_last || axis_muser !== hold_user) begin
          err_proto = err_proto + 1;
          $display("[%0t] PROTOCOL ERROR: stalled beat payload changed", $time);
        end
      end
      if (axis_mvalid && !axis_mready) begin
        hold_v    <= 1'b1;
        hold_data <= axis_mdata;
        hold_keep <= axis_mkeep;
        hold_last <= axis_mlast;
        hold_user <= axis_muser;
      end else begin
        hold_v <= 1'b0;
      end
    end
  end

  // ============================================================================
  // 读端 mready 驱动: rd_mode 0=强制低 1=随机(70%高) 2=强制高(排空)
  // ============================================================================
  reg [1:0] rd_mode;
  integer   r_r;
  always @(posedge mclk) begin
    r_r = $random;
    if (r_r < 0) r_r = -r_r;
    case (rd_mode)
      2'd0: axis_mready <= 1'b0;
      2'd1: axis_mready <= ((r_r % 10) < 7);
      2'd2: axis_mready <= 1'b1;
    endcase
  end

  // ============================================================================
  // 写端 task
  // ============================================================================
  task send_rand_packet;
    integer len, i, r;
    begin
      r = $random; if (r < 0) r = -r;
      len = 1 + (r % 20);
      for (i = 0; i < len; i = i + 1) begin
        @(posedge sclk);
        axis_sdata  <= seq;
        axis_skeep  <= {(AXIS_WIDTH/8){1'b1}};
        axis_suser  <= $random;
        axis_slast  <= (i == len - 1);
        axis_svalid <= 1'b1;
        if (i == len - 1) begin
          r = $random; if (r < 0) r = -r;
          axis_skeep <= r;   // 末拍随机 keep (可能非全1)
        end
        seq <= seq + 1;
        @(posedge sclk);
        while (!(axis_svalid && axis_sready)) @(posedge sclk);
        // 随机拍间隔 (包内 valid gap, 测包模式防泄漏)
        r = $random; if (r < 0) r = -r;
        if ((r % 5) == 0) begin
          axis_svalid <= 1'b0;
          repeat (1 + (r % 4)) @(posedge sclk);
        end
      end
      axis_svalid <= 1'b0;
      axis_slast  <= 1'b0;
    end
  endtask

  // 不发 last 的定长写 (用于超长包死锁演示)
  task send_partial_no_last;
    input integer len;
    integer i;
    begin
      for (i = 0; i < len; i = i + 1) begin
        @(posedge sclk);
        axis_sdata  <= seq;
        axis_skeep  <= {(AXIS_WIDTH/8){1'b1}};
        axis_suser  <= $random;
        axis_slast  <= 1'b0;
        axis_svalid <= 1'b1;
        seq <= seq + 1;
        @(posedge sclk);
        while (!(axis_svalid && axis_sready)) @(posedge sclk);
      end
      axis_svalid <= 1'b0;
    end
  endtask

  integer i;
  initial begin
    for (i = 0; i<65536; i=i+1) begin
      q_data[i] = 'd0;
      q_keep[i] = 'd0;
      q_user[i] = 'd0;
      q_last[i] = 'd0;
    end
    hold_v = 'd0;
    hold_data = 'd0;
    hold_keep = 'd0;
    hold_last = 'd0;
    hold_user = 'd0;
    r_r = 'd0;
  end

  // ============================================================================
  // 主测试序列
  // ============================================================================
  integer p = 'd0, r = 'd0;
  initial begin
    srst = 1'b1;
    rd_mode = 2'd0;
    q_wr = 0; q_rd = 0; wr_pkts = 0; rd_pkts = 0;
    err_score = 0; err_proto = 0;
    seq = {AXIS_WIDTH{1'b0}};
    axis_svalid = 1'b0; axis_sdata = {AXIS_WIDTH{1'b0}};
    axis_skeep = {(AXIS_WIDTH/8){1'b0}}; axis_slast = 1'b0;
    axis_suser = {AXIS_USER_WIDTH{1'b0}};
    axis_sstrb = {(AXIS_WIDTH/8){1'b0}};
    axis_sid = {AXIS_ID_WIDTH{1'b0}};
    axis_sdest = {AXIS_DEST_WIDTH{1'b0}};

    #100;
    srst = 1'b0;
    #50;

    // ------------------------------------------------------------------
    // Phase 1: 压力测试 300 包
    // ------------------------------------------------------------------
    $display("[%0t] === Phase 1: stress (300 pkts, random len/gap/backpressure) ===", $time);
    rd_mode = 2'd1;
    for (p = 0; p < 300; p = p + 1) begin
      send_rand_packet;
      r = $random; if (r < 0) r = -r;
      if ((r % 3) == 0) repeat (1 + (r % 5)) @(posedge sclk);
    end
    rd_mode = 2'd2;
    wait (q_rd == q_wr);
    repeat (30) @(posedge mclk);
    if (axis_mvalid !== 1'b0) begin
      err_score = err_score + 1;
      $display("[%0t] ERROR: mvalid still high after drain", $time);
    end
    if (rd_pkts != 300) begin
      err_score = err_score + 1;
      $display("[%0t] ERROR: P1 packet count: wrote 300, read %0d", $time, rd_pkts);
    end
    $display("[%0t] Phase 1 done: beats=%0d pkts=%0d err_score=%0d err_proto=%0d", $time, q_rd, rd_pkts, err_score, err_proto);
    rd_mode = 2'd0;

    // ------------------------------------------------------------------
    // Phase 2: 流量中异步复位 (模拟链路翻转)
    // ------------------------------------------------------------------
    $display("[%0t] === Phase 2: async reset during traffic ===", $time);
    rd_mode = 2'd1;
    for (p = 0; p < 10; p = p + 1) send_rand_packet;
    #347;                          // 读端消化一部分后复位
    srst = 1'b1;                   // 非时钟沿时刻异步置位
    #53;
    q_wr = 0; q_rd = 0; wr_pkts = 0; rd_pkts = 0;   // 模型与 DUT 一同清空
    #47;
    srst = 1'b0;
    rd_mode = 2'd0;
    repeat (30) @(posedge mclk);
    if (axis_mvalid !== 1'b0) begin
      err_score = err_score + 1;
      $display("[%0t] ERROR: mvalid high after reset", $time);
    end
    if (axis_sready !== 1'b1) begin
      err_score = err_score + 1;
      $display("[%0t] ERROR: sready low after reset", $time);
    end
    $display("[%0t] Phase 2 done: post-reset state clean", $time);

    // ------------------------------------------------------------------
    // Phase 3: 复位后恢复压测 150 包
    // ------------------------------------------------------------------
    $display("[%0t] === Phase 3: stress after reset (150 pkts) ===", $time);
    rd_mode = 2'd1;
    for (p = 0; p < 150; p = p + 1) begin
      send_rand_packet;
      r = $random; if (r < 0) r = -r;
      if ((r % 3) == 0) repeat (1 + (r % 4)) @(posedge sclk);
    end
    rd_mode = 2'd2;
    wait (q_rd == q_wr);
    repeat (30) @(posedge mclk);
    if (axis_mvalid !== 1'b0) begin
      err_score = err_score + 1;
      $display("[%0t] ERROR: mvalid high after drain P3", $time);
    end
    if (rd_pkts != 150) begin
      err_score = err_score + 1;
      $display("[%0t] ERROR: P3 packet count: wrote 150, read %0d", $time, rd_pkts);
    end
    $display("[%0t] Phase 3 done: beats=%0d pkts=%0d", $time, q_rd, rd_pkts);
    rd_mode = 2'd0;

    // ------------------------------------------------------------------
    // Phase 4: 超长包死锁演示 (40 拍 > 深度 32, PACKET_FIFO=1 已知限制)
    // ------------------------------------------------------------------
    $display("[%0t] === Phase 4: oversized packet (40 beats > depth 32) ===", $time);
    fork : ov_blk
      begin : ov_wr
        send_partial_no_last(40);
      end
      begin : ov_watch
        repeat (400) @(posedge sclk);
        disable ov_blk;
      end
    join
    axis_svalid = 1'b0;
    #20;
    $display("[%0t] Oversize result: sready=%b mvalid=%b wr_remain=%0d", $time, axis_sready, axis_mvalid, wr_almost_remain_count);
    if (axis_sready == 1'b0 && axis_mvalid == 1'b0) begin
      $display("[%0t] NOTE: deadlock confirmed - PACKET_FIFO=1 cannot pass packets longer than FIFO_DEPTH (design limitation, not a bug for current use)", $time);
    end else begin
      err_score = err_score + 1;
      $display("[%0t] UNEXPECTED: oversized packet did not stall as predicted", $time);
    end
    // 复位恢复
    srst = 1'b1; #53;
    q_wr = 0; q_rd = 0; wr_pkts = 0; rd_pkts = 0;
    #47; srst = 1'b0;
    repeat (30) @(posedge mclk);
    if (axis_mvalid !== 1'b0 || axis_sready !== 1'b1) begin
      err_score = err_score + 1;
      $display("[%0t] ERROR: no recovery after oversize reset", $time);
    end

    // ------------------------------------------------------------------
    // 总结
    // ------------------------------------------------------------------
    if (err_score == 0 && err_proto == 0)
      $display("[%0t] ============ ALL CHECKS PASSED ============", $time);
    else
      $display("[%0t] ============ FAILED: err_score=%0d err_proto=%0d ============", $time, err_score, err_proto);
    $finish;
  end

  // 全局看门狗
  initial begin
    #3_000_000;
    $display("[%0t] FATAL: global watchdog timeout", $time);
    $finish;
  end

endmodule
