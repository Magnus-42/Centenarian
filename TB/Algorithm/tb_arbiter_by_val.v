`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_arbiter_by_val.v
// Module Name : tb_arbiter_by_val
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-10-19
// ----------------------------------------------------------------------------
// Description : arbiter_by_val 参数扫描验证（PIPELINE = 0 / 1 / 2）
//   同一份 TB 用 `PIPE0 / `PIPE2 选择流水档，默认 PIPELINE=1。
//   四路源常驻请求（prio 可编程），四个阶段:
//     Ph0 全等值   -> 轮询：每 N 次授权更替必须覆盖 N 个端口 + 各口份额 >= 1/8
//     Ph1 p0 最高  -> 严格优先：本阶段授权只能是 p0
//     Ph2 p0 最低  -> 严格优先：p0 一次都不能被授权
//     Ph3 恢复等值 -> 轮询与公平份额重新成立
//   逐拍不变量:
//     I1 grant_onehot 只能是 0 或独热；输出无 X
//     I2 grant_valid 时被授权口必须属于当前最高值集合，且 grant_val == max
//     I3 (PIPE>=1) 未 ack 期间授权不变（包级锁定）
//   授权事件定义：PIPE>=1 用 ack（包结束），PIPE=0 用 grant 更替（无包概念）
// Note        : 优先级切换后 4 拍 settle 窗口内不做 I2
// ============================================================================
module tb_arbiter_by_val;

  localparam N = 4;
  localparam W = 4;

`ifdef PIPE0
  localparam PIPE = 0;
`elsif PIPE2
  localparam PIPE = 2;
`else
  localparam PIPE = 1;
`endif

  reg           clk = 1'b0;
  always #2.5 clk = ~clk;
  reg           rst = 1'b1;

  reg  [N*W-1:0] req_val;
  wire [  N-1:0] grant_onehot;
  wire [  W-1:0] grant_val;
  reg            grant_ack;
  wire           grant_valid;

  arbiter_by_val #(
    .N        (N   ),
    .WIDTH    (W   ),
    .PIPELINE (PIPE),
    .LOW_FIRST(0   )
  ) u_dut (
    .clk          (clk         ),
    .rst          (rst         ),
    .req_val      (req_val     ),
    .grant_onehot (grant_onehot),
    .grant_val    (grant_val   ),
    .grant_ack    (grant_ack   ),
    .grant_valid  (grant_valid )
  );

  // ---------------------------------------------------------------- 状态
  integer     cyc;
  integer     i;
  reg [W-1:0] prio [0:N-1];
  integer     settle_until;
  integer     maxv;
  reg [N-1:0] eq_mask;

  reg [1:0]   hold;
  reg         prev_valid, ack_d;
  reg [N-1:0] prev_oh;

  integer     errors;
  integer     n_pkt  [0:N-1];
  integer     ph_port[0:N-1];
  integer     ph_cnt;
  reg [N-1:0] win_mask;
  integer     win_cnt;
  integer     ph_now;

  // 授权事件：PIPE>=1 看 ack（一次 = 一个包）；PIPE=0 看授权更替（每拍都可能换）
  wire grant_evt = (PIPE >= 1) ? (grant_valid && grant_ack)
                               : (grant_valid && (grant_onehot !== prev_oh));

  task eval_phase;
    input integer ph;
    begin
      if (ph_cnt > 16) begin
        if (ph == 0 || ph == 3) begin
          if ((ph_port[0]*8 < ph_cnt) || (ph_port[1]*8 < ph_cnt) ||
              (ph_port[2]*8 < ph_cnt) || (ph_port[3]*8 < ph_cnt)) begin
            errors = errors + 1;
            $display("[FAIL] Ph%0d unfair share: %0d/%0d/%0d/%0d of %0d",
                     ph, ph_port[0], ph_port[1], ph_port[2], ph_port[3], ph_cnt);
          end
        end
        if (ph == 1 && (ph_port[0] != ph_cnt)) begin
          errors = errors + 1;
          $display("[FAIL] Ph1 expect all p0, got %0d/%0d/%0d/%0d",
                   ph_port[0], ph_port[1], ph_port[2], ph_port[3]);
        end
        if (ph == 2 && (ph_port[0] != 0)) begin
          errors = errors + 1;
          $display("[FAIL] Ph2 p0 got %0d grants (expect 0)", ph_port[0]);
        end
      end
      for (i = 0; i < N; i = i + 1) ph_port[i] = 0;
      ph_cnt = 0;
    end
  endtask

  always @(posedge clk) begin
    if (rst) begin
      cyc          = 0;
      errors       = 0;
      hold         <= 2'd1;
      grant_ack    <= 1'b0;
      prev_oh      <= {N{1'b0}};
      prev_valid   <= 1'b0;
      ack_d        <= 1'b0;
      req_val      <= {N*W{1'b0}};
      win_mask     <= {N{1'b0}};
      win_cnt      = 0;
      ph_cnt       = 0;
      ph_now       = 0;
      settle_until = 8;
      for (i = 0; i < N; i = i + 1) begin
        prio[i]    <= 4'd8;
        n_pkt[i]    = 0;
        ph_port[i]  = 0;
      end
    end else begin
      cyc = cyc + 1;

      // ---- 相位切换（先评估上一相）----
      if (cyc == 1020) begin
        eval_phase(0);
        for (i = 0; i < N; i = i + 1) prio[i] <= 4'd8;
        prio[0] <= 4'd15;
        ph_now = 1; settle_until = cyc + 4;
        win_mask = {N{1'b0}}; win_cnt = 0;
      end
      if (cyc == 2020) begin
        eval_phase(1);
        for (i = 0; i < N; i = i + 1) prio[i] <= 4'd8;
        prio[0] <= 4'd4;
        ph_now = 2; settle_until = cyc + 4;
        win_mask = {N{1'b0}}; win_cnt = 0;
      end
      if (cyc == 3020) begin
        eval_phase(2);
        for (i = 0; i < N; i = i + 1) prio[i] <= 4'd8;
        ph_now = 3; settle_until = cyc + 4;
        win_mask = {N{1'b0}}; win_cnt = 0;
      end
      if (cyc == 3300) begin
        eval_phase(3);                 // 先结算 Ph3 的公平份额
        ph_now = 4; settle_until = cyc + 4;   // Ph4：周期性全空闲，只查结构不变量
      end

      // ---- ack 模型：每包保持 2 拍 ----
      if (!grant_valid) begin
        hold      <= 2'd1;
        grant_ack <= 1'b0;
      end else if (hold != 2'd0) begin
        hold      <= hold - 2'd1;
        grant_ack <= 1'b0;
      end else begin
        grant_ack <= 1'b1;
        hold      <= 2'd1;
      end

      // ---- Ph3 尾部插入全空闲窗口：any_sel=0 与寄存级对齐的边界 ----
      if (ph_now == 4) begin
        for (i = 0; i < N; i = i + 1)
          prio[i] <= ((cyc % 40) < 16) ? 4'd0 : 4'd8;
      end

      // ---- req_val 打一拍跟随 prio ----
      for (i = 0; i < N; i = i + 1)
        req_val[i*W +: W] <= prio[i];

      // ---- I1 ----
      if ((^{grant_onehot, grant_valid, grant_ack}) === 1'bx) begin
        errors = errors + 1;
        $display("[FAIL] %0t X on outputs", $time);
      end
      if (grant_valid && grant_onehot == {N{1'b0}}) begin
        errors = errors + 1;
        $display("[FAIL] %0t grant_valid=1 but grant_onehot=0", $time);
      end
      if (grant_onehot != {N{1'b0}} &&
          (grant_onehot & (grant_onehot - 1'b1)) != {N{1'b0}}) begin
        errors = errors + 1;
        $display("[FAIL] %0t grant_onehot not onehot: %b", $time, grant_onehot);
      end

      // ---- I2 ----
      maxv = 0;
      for (i = 0; i < N; i = i + 1)
        if (prio[i] > maxv[W-1:0]) maxv = prio[i];
      for (i = 0; i < N; i = i + 1)
        eq_mask[i] = (prio[i] == maxv[W-1:0]);

      if (grant_valid && (cyc > settle_until) && (ph_now != 4)) begin
        if ((grant_onehot & ~eq_mask) != {N{1'b0}}) begin
          errors = errors + 1;
          $display("[FAIL] %0t granted %b outside max-set %b (prio %0d/%0d/%0d/%0d)",
                   $time, grant_onehot, eq_mask, prio[0], prio[1], prio[2], prio[3]);
        end
        if (grant_val !== maxv[W-1:0]) begin
          errors = errors + 1;
          $display("[FAIL] %0t grant_val=%0d expect %0d", $time, grant_val, maxv);
        end
      end

      // ---- I3 ----
      if (PIPE >= 1 && prev_valid && grant_valid && !grant_ack && !ack_d && (cyc > settle_until) && (ph_now != 4)) begin
        if (grant_onehot !== prev_oh) begin
          errors = errors + 1;
          $display("[FAIL] %0t grant changed without ack: %b -> %b", $time, prev_oh, grant_onehot);
        end
      end

      // ---- 授权事件计数 + 轮询窗口 ----
      if (grant_evt && (cyc > settle_until) && (ph_now != 4)) begin   // 切相后的 settle 期不计入统计
        for (i = 0; i < N; i = i + 1)
          if (grant_onehot[i]) begin
            n_pkt[i]   = n_pkt[i] + 1;
            ph_port[i] = ph_port[i] + 1;
          end
        ph_cnt = ph_cnt + 1;

        if ((ph_now == 0 || ph_now == 3) && (cyc > settle_until)) begin
          win_mask = win_mask | grant_onehot;
          win_cnt  = win_cnt + 1;
          if (win_cnt == N) begin
            if (win_mask != {N{1'b1}}) begin
              errors = errors + 1;
              $display("[FAIL] %0t RR window missed ports: %b", $time, win_mask);
            end
            win_mask = {N{1'b0}};
            win_cnt  = 0;
          end
        end
      end

      prev_oh    <= grant_onehot;
      prev_valid <= grant_valid;
      ack_d      <= grant_ack;

      if (cyc == 4020) begin
        $display("------------------------------------------------------------");
        $display("PIPELINE=%0d   grants: p0=%0d p1=%0d p2=%0d p3=%0d",
                 PIPE, n_pkt[0], n_pkt[1], n_pkt[2], n_pkt[3]);
        if (errors == 0) $display("RESULT: PASS   (PIPELINE=%0d)", PIPE);
        else             $display("RESULT: FAIL   (PIPELINE=%0d, %0d errors)", PIPE, errors);
        $finish;
      end
    end
  end

  initial begin
    rst = 1'b1;
    repeat (5) @(posedge clk);
    @(negedge clk) rst = 1'b0;
  end

  initial begin
    #400000;
    $display("[FAIL] GLOBAL TIMEOUT (PIPELINE=%0d)", PIPE);
    $finish;
  end

endmodule
`default_nettype wire
