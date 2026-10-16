`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// tb_fifo_sync
// 目的: 验证 fifo_sync(BRAM_DO_REG=2, block RAM) 在"稀疏单脉冲读"下的行为
//   契约: 一次 rd_en 使能应能取出一个条目并在固定延迟内出现在 dout 上
//   覆盖:
//     T1~T4 多次稀疏单脉冲读 (含"读走最后一条使 FIFO 变空")
//     T5    空读(rd_en 时 FIFO 空)后紧跟写入 -> dout 是否被陈旧值污染
//     T6    连续读(rd_en 拉高) -> 顺序与值
// ============================================================================
module tb_fifo_sync;

  localparam DW    = 32;
  localparam DEPTH = 512;
  localparam RCW   = 10;   // $clog2(512)+1

  reg  clk = 1'b0;
  reg  rst = 1'b1;
  always #5 clk = ~clk;

  reg  [DW-1:0] din     = 0;
  reg           wr_en   = 0;
  reg           rd_en   = 0;
  wire [DW-1:0] dout    ;
  wire          full    ;
  wire          empty   ;
  wire          prog_full ;
  wire          prog_empty;
  wire [RCW-1:0] remain_count;

  fifo_sync #(
    .FIFO_DEPTH       (DEPTH ),
    .DATA_WIDTH       (DW    ),
    .FIFO_MEMORY_TYPE ("auto"),
    .BRAM_DO_REG      (2     )
  ) dut (
    .rst          (rst         ),
    .clk          (clk         ),
    .din          (din         ),
    .wr_en        (wr_en       ),
    .rd_en        (rd_en       ),
    .dout         (dout        ),
    .full         (full        ),
    .empty        (empty       ),
    .prog_full    (prog_full   ),
    .prog_empty   (prog_empty  ),
    .remain_count (remain_count)
  );

  integer errs, pulse_cnt;

  // 每次 rd_en 脉冲的边沿计数, 便于报告延迟
  always @(posedge clk) if (!rst && rd_en === 1'b1) pulse_cnt = pulse_cnt + 1;

  // ---------------- 基本动作 ----------------
  task automatic cyc(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
  endtask

  task automatic wr(input [DW-1:0] d);
    begin
      @(negedge clk);
      din = d; wr_en = 1'b1;
      @(negedge clk);
      wr_en = 1'b0;
    end
  endtask

  // 单拍读脉冲
  task automatic rd_pulse();
    begin
      @(negedge clk);
      rd_en = 1'b1;
      @(negedge clk);
      rd_en = 1'b0;
    end
  endtask

  // 读脉冲后 6 拍内检查 dout 是否等于 exp, 并报告出现的拍数
  reg [7:0] tagbuf [0:7];
  task automatic chk(input [DW-1:0] exp, input integer tag);
    integer k; reg found;
    begin
      found = 1'b0;
      for (k = 1; k <= 6; k = k + 1) begin
        @(posedge clk); #2;
        if (!found && (dout === exp)) begin
          found = 1'b1;
          $display("   [ OK ] T%0d: dout=%08h 在 rd_en 后第 %0d 拍出现", tag, dout, k);
        end
      end
      if (!found) begin
        errs = errs + 1;
        $display("   [FAIL] T%0d: 6 拍内 dout 未出现 %08h (当前 %08h, empty=%b)",
                 tag, exp, dout, empty);
      end
    end
  endtask

  // 不给脉冲, 只观察 dout 是否变化 (用于污染检查)
  task automatic chk_hold(input [DW-1:0] exp, input integer tag);
    integer k;
    begin
      for (k = 1; k <= 4; k = k + 1) begin
        @(posedge clk); #2;
        if (dout !== exp) begin
          errs = errs + 1;
          $display("   [FAIL] T%0d: 无读脉冲但 dout 变成 %08h (期望保持 %08h)", tag, dout, exp);
          disable chk_hold;
        end
      end
      $display("   [ OK ] T%0d: 无读脉冲期间 dout 保持 %08h", tag, exp);
    end
  endtask

  // ---------------- 主流程 ----------------
  initial begin
    $display("================================================================");
    $display(" tb_fifo_sync : 稀疏单脉冲读行为 (DEPTH=%0d, W=%0d, BRAM_DO_REG=2)", DEPTH, DW);
    $display("================================================================");
    errs = 0; pulse_cnt = 0;
    rst = 1'b1; cyc(6); rst = 1'b0; cyc(2);

    // ---- T0: 精确测量 rd_en -> dout 的延迟 (逐拍打印) ----
    $display("---- T0: 读出延迟精确测量 (单拍 rd_en) ----");
    wr(32'h9000_0001); wr(32'h9000_0002);
    $display("   写入 2 条: empty=%b remain_count=%0d", empty, remain_count);
    @(negedge clk); rd_en = 1'b1;                       // 沿 A: 拉高
    @(negedge clk); rd_en = 1'b0;                       // 沿 B: 拉低 (中间含 1 个上升沿 = rd_en 被采样的沿)
    begin : TRACE
      integer k;
      for (k = 0; k < 5; k = k + 1) begin
        @(posedge clk); #2;
        $display("     rd_en 采样沿之后第 %0d 个上升沿: dout=%08h empty=%b remain=%0d", k+1, dout, empty, remain_count);
      end
    end
    rst = 1'b1; cyc(4); rst = 1'b0; cyc(2);             // 复位, 让后续用例从空 FIFO 开始
    $display("   复位后 empty=%b remain_count=%0d", empty, remain_count);

    // ---- T1~T4: 写 4 条, 逐个单脉冲读; 第 4 次读会使 FIFO 变空 ----
    $display("---- T1~T4: 稀疏单脉冲读 4 条 (第 4 次读后 FIFO 变空) ----");
    wr(32'hA000_0001); wr(32'hA000_0002); wr(32'hA000_0003); wr(32'hA000_0004);
    $display("   写入后 empty=%b remain_count=%0d", empty, remain_count);

    rd_pulse(); chk(32'hA000_0001, 1); cyc(3);
    rd_pulse(); chk(32'hA000_0002, 2); cyc(3);
    rd_pulse(); chk(32'hA000_0003, 3); cyc(3);
    $display("   读第 4 条前: empty=%b remain_count=%0d", empty, remain_count);
    rd_pulse(); chk(32'hA000_0004, 4); cyc(3);
    $display("   读第 4 条后: empty=%b remain_count=%0d", empty, remain_count);

    // ---- T5: 空读 (rd_en 时 FIFO 空) 后紧跟写入, 检查 dout 是否被污染 ----
    $display("---- T5: 空读后紧跟写入 (检查陈旧值污染) ----");
    $display("   空读前: empty=%b dout=%08h", empty, dout);
    @(negedge clk); rd_en = 1'b1;
    @(negedge clk); rd_en = 1'b0;                       // 空读: 无条目
    wr(32'hB000_0005);                                  // 紧接着写入一条(不读)
    chk_hold(32'hA000_0004, 5);                         // dout 应仍为上一次读出的值
    cyc(3);

    // ---- T6: 连续读 (rd_en 拉高) 应把剩余条目按顺序流出 ----
    $display("---- T6: 连续读 (rd_en 拉高直至空) ----");
    wr(32'hC000_0006); wr(32'hC000_0007);
    @(negedge clk); rd_en = 1'b1;
    begin : CONT
      integer k;
      for (k = 0; k < 8; k = k + 1) begin
        @(posedge clk); #2;
        $display("     连续读第 %0d 拍: empty=%b remain_count=%0d dout=%08h", k+1, empty, remain_count, dout);
      end
    end
    @(negedge clk); rd_en = 1'b0;
    if (!(dout === 32'hC000_0007 || dout === 32'hB000_0005))
      $display("   [WARN] T6 结束时 dout=%08h (期望在 B5/C6/C7 之内)", dout);

    $display("================================================================");
    $display(" 结果: 失败 %0d 项", errs);
    if (errs == 0) $display(" *** ALL TESTS PASSED ***");
    else           $display(" *** %0d CHECK(S) FAILED ***", errs);
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
