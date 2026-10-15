`timescale 1ns/100ps

// POR 逻辑的独立单元验证: 与 ipv4_test_top.v 里插入的 POR 块逐行一致
module tb_por;

  localparam POR_CNT_W = 16;

  reg                        clk      = 1'b0;
  reg                        gt_rst   = 1'b0;
  reg  [POR_CNT_W-1:0]       por_cnt  = {POR_CNT_W{1'b0}};
  reg                        por_done = 1'b0;
  wire                       por_rst  = (por_done !== 1'b1);

  always #1.25 clk = ~clk;                       // 400MHz, 周期 2.5ns

  always @(posedge clk) begin
    if (gt_rst) begin
      por_cnt  <= {POR_CNT_W{1'b0}};
      por_done <= 1'b0;
    end else if (por_done !== 1'b1) begin
      por_cnt <= por_cnt + 1'b1;
      if (por_cnt == {POR_CNT_W{1'b1}}) por_done <= 1'b1;
    end
  end

  integer cyc;
  integer err;

  initial begin
    err = 0;

    // 1) 上电即刻为 1 (不能是 X, 也不能是 0)
    if (por_rst === 1'b1) $display("[PASS] power-up: por_rst=1");
    else begin $display("[FAIL] power-up: por_rst=%b (expect 1)", por_rst); err = err + 1; end

    // 2) 计满后释放
    cyc = 0;
    while (por_rst === 1'b1 && cyc < 200000) begin @(posedge clk); cyc = cyc + 1; end
    if (cyc >= 65536 && cyc <= 65538) $display("[PASS] released after %0d cycles (expect ~65536)", cyc);
    else begin $display("[FAIL] released after %0d cycles (expect ~65536)", cyc); err = err + 1; end
    if (por_rst === 1'b0) $display("[PASS] por_rst=0 after release");
    else begin $display("[FAIL] por_rst=%b after release", por_rst); err = err + 1; end

    // 3) 释放后不再自己拉高 (无自锁)
    repeat (1000) @(posedge clk);
    if (por_rst === 1'b0) $display("[PASS] stays 0, no self-lock");
    else begin $display("[FAIL] por_rst went back to %b (self-lock!)", por_rst); err = err + 1; end

    // 4) GT/CMAC 复位可重新武装
    gt_rst = 1'b1;
    repeat (4) @(posedge clk);
    gt_rst = 1'b0;
    if (por_rst === 1'b1) $display("[PASS] re-armed by gt_rst");
    else begin $display("[FAIL] not re-armed, por_rst=%b", por_rst); err = err + 1; end

    cyc = 0;
    while (por_rst === 1'b1 && cyc < 200000) begin @(posedge clk); cyc = cyc + 1; end
    if (cyc >= 65536 && cyc <= 65538) $display("[PASS] released again after %0d cycles", cyc);
    else begin $display("[FAIL] released again after %0d", cyc); err = err + 1; end

    $display("--------------------------------");
    if (err == 0) $display(" *** POR ALL PASSED ***");
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
    $finish;
  end

  initial begin
    #1000000;
    $display("FATAL: timeout");
    $finish;
  end

endmodule
