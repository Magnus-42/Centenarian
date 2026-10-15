`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : tb_axis_nto1.v
// Module Name : tb_axis_nto1
// Author      : LiXintao
// Date        : 2026-09-19
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : axis_nto1 (N:1 包级 AXIS 仲裁/多路) 单元验证
//   方法: 每个源按"包"发送, 载荷 = {包号, 端口, 拍号}; 输出端按 tid(=源端口, UPDATE_TID=1)
//         分组, 与"该源已发出的逐拍序列"严格比对 (数据 + last 都要一致)
//         => 可检出: 丢拍 / 重复拍 / 幽灵帧(多余 last) / 帧边界错乱
//   用例: T1 单路; T2 两路同时(严格优先 port0); T3 输出反压; T4 长跑稳定性
// ============================================================================
module tb_axis_nto1;

  localparam P     = 2;
  localparam W     = 64;
  localparam IDW   = 1;
  localparam UW    = 1;
  localparam LEN   = 8;      // 每包拍数
  localparam GAP   = 6;      // 包间隔(严格优先下低优先路也有机会)
  localparam MAXB  = 8192;

  reg clk = 1'b0;
  always #2.5 clk = ~clk;
  reg rst = 1'b1;

  // ---------------------------------------------------------------- DUT 连线
  wire [P*W-1:0]                  s_data ;
  wire [P*W/8-1:0]                s_keep ;
  wire [P*IDW-1:0]                s_id   ;
  wire [P*UW-1:0]                 s_user ;
  wire [P-1:0]                    s_valid;
  wire [P-1:0]                    s_last ;
  wire [P-1:0]                    s_ready;
  wire [W-1:0]                    m_data ;
  wire [W/8-1:0]                  m_keep ;
  wire [IDW-1:0]                  m_id   ;
  wire [UW-1:0]                   m_user ;
  wire                            m_valid;
  wire                            m_last ;
  reg                             m_ready;
  wire [IDW-1:0]                  stat_port;
  wire                            stat_idle;

  axis_nto1 #(
    .NUM_PORTS       (P   ),
    .IDX_W           (IDW ),
    .AXIS_WIDTH      (W   ),
    .AXIS_ID_WIDTH   (IDW ),
    .AXIS_USER_WIDTH (UW  ),
    .ARB_TYPE        (1   ),   // 严格优先(低位优先)
    .UPDATE_TID      (1   )    // 输出 tid = 选中端口号(用于识别来源)
  ) u_dut (
    .clk(clk), .rst(rst),
    .axis_sdata(s_data), .axis_skeep(s_keep), .axis_sid(s_id), .axis_susr(s_user),
    .axis_svalid(s_valid), .axis_slast(s_last), .axis_sready(s_ready),
    .axis_mdata(m_data), .axis_mkeep(m_keep), .axis_mid(m_id), .axis_musr(m_user),
    .axis_mvalid(m_valid), .axis_mlast(m_last), .axis_mready(m_ready),
    .stat_active_port(stat_port), .stat_idle(stat_idle)
  );

  // ---------------------------------------------------------------- 激励源
  reg en0 = 1'b0, en1 = 1'b0;

  genvar gp;
  generate
    for (gp = 0; gp < P; gp = gp + 1) begin : gen_src
      reg [15:0] beat_cnt;
      reg [15:0] gap_cnt;
      wire       en      = (gp == 0) ? en0 : en1;
      wire       gap_on  = (gap_cnt != 16'd0);
      wire       send_en = en && !gap_on;

      always @(posedge clk) begin
        if (rst) begin
          beat_cnt <= 16'd0;
          gap_cnt  <= 16'd0;
        end else if (en) begin
          if (gap_on) begin
            gap_cnt <= gap_cnt - 1'b1;
          end else if (s_valid[gp] && s_ready[gp]) begin
            if (s_last[gp]) begin
              beat_cnt <= 16'd0;
              gap_cnt  <= GAP[15:0];
            end else begin
              beat_cnt <= beat_cnt + 1'b1;
            end
          end
        end
      end

      assign s_data [gp*W+:W]     = {48'd0, gp[15:0], beat_cnt};
      assign s_keep [gp*W/8+:W/8] = {W/8{1'b1}};
      assign s_user [gp*UW+:UW]   = gp[0];
      assign s_id   [gp*IDW+:IDW] = 1'b0;
      assign s_valid[gp]          = send_en;
      assign s_last [gp]          = send_en && (beat_cnt == LEN-1);
    end
  endgenerate

  // ---------------------------------------------------------------- 记分板
  reg [W-1:0]  exp_data [0:P-1][0:MAXB-1];
  reg          exp_last [0:P-1][0:MAXB-1];
  integer      exp_wr   [0:P-1];       // 该源被 DUT 接收的拍数(期望)
  integer      exp_rd   [0:P-1];       // 已比对的拍数
  integer      frame_out[0:P-1];       // 输出帧数
  integer      rd_err   = 0;

  integer p;
  always @(posedge clk) begin
    if (!rst) begin
      for (p = 0; p < P; p = p + 1) begin
        if (s_valid[p] && s_ready[p]) begin
          exp_data[p][exp_wr[p]] = s_data[p*W+:W];
          exp_last[p][exp_wr[p]] = s_last[p];
          exp_wr[p] = exp_wr[p] + 1;
        end
      end
    end
  end

  always @(posedge clk) begin
    if (!rst && m_valid && m_ready) begin
      if (m_last) frame_out[m_id] = frame_out[m_id] + 1;
      if (exp_rd[m_id] < exp_wr[m_id]) begin
        if (m_data !== exp_data[m_id][exp_rd[m_id]]) begin
          rd_err = rd_err + 1;
          if (rd_err <= 10)
            $display("  [MISMATCH] port%0d 第%0d拍 数据 rx=%h exp=%h",
                     m_id, exp_rd[m_id], m_data, exp_data[m_id][exp_rd[m_id]]);
        end
        if (m_last !== exp_last[m_id][exp_rd[m_id]]) begin
          rd_err = rd_err + 1;
          if (rd_err <= 10)
            $display("  [LAST-ERR] port%0d 第%0d拍 last rx=%b exp=%b data=%h",
                     m_id, exp_rd[m_id], m_last, exp_last[m_id][exp_rd[m_id]], m_data);
        end
        exp_rd[m_id] = exp_rd[m_id] + 1;
      end else begin
        rd_err = rd_err + 1;
        if (rd_err <= 10) $display("  [EXTRA] port%0d 输出多出一拍! data=%h last=%b", m_id, m_data, m_last);
      end
    end
  end

  // ---------------------------------------------------------------- 反压
  reg [7:0] rnd = 8'h5A;
  reg       bp_en = 1'b0;
  always @(posedge clk) if (!rst) rnd <= {rnd[6:0], rnd[7]^rnd[5]^rnd[4]^rnd[3]};
  wire bp_stall = bp_en && (rnd[0] ^ rnd[1]);
  always @(posedge clk) m_ready <= rst ? 1'b0 : ~bp_stall;

  // ---------------------------------------------------------------- 激励
  integer err_total;
  task automatic cyc(input integer n); integer i; begin for (i=0;i<n;i=i+1) @(posedge clk); end endtask

  // 优雅停源: 等本包最后一拍握手后再拉低 en。
  // 直接中途掐断会让 DUT 收到"半包": 包级锁定下一等 last 不到就永远排不出去,
  // 记分板会误报"少了 N 拍"(数据比对其实 0 错)。
  task automatic stop_src0; integer n; begin
    n = 0;
    while (en0 && !(s_valid[0] && s_ready[0] && s_last[0]) && n < 500) begin @(posedge clk); n = n + 1; end
    @(negedge clk); en0 = 1'b0;
  end endtask
  task automatic stop_src1; integer n; begin
    n = 0;
    while (en1 && !(s_valid[1] && s_ready[1] && s_last[1]) && n < 500) begin @(posedge clk); n = n + 1; end
    @(negedge clk); en1 = 1'b0;
  end endtask

  initial begin
    err_total = 0;
    for (p=0;p<P;p=p+1) begin exp_wr[p]=0; exp_rd[p]=0; frame_out[p]=0; end
    en0=1'b0; en1=1'b0; bp_en=1'b0;
    rst = 1'b1;
    cyc(10);
    rst = 1'b0;
    cyc(5);

    // ---------------- T1 单路 ----------------
    $display("--- T1: 单路(port0), 每包 %0d 拍, 包间隔 %0d ---", LEN, GAP);
    en0 = 1'b1;
    cyc(600);
    stop_src0;
    cyc(80);
    if (rd_err != 0 || exp_rd[0] != exp_wr[0]) begin
      $display("  [FAIL] T1 序列错误(或不完整) err=%0d 入=%0d 出=%0d", rd_err, exp_wr[0], exp_rd[0]);
      err_total = err_total + 1;
    end else $display("  [PASS] T1 逐拍一致 (入=%0d 出=%0d 帧=%0d)", exp_wr[0], exp_rd[0], frame_out[0]);
    if (frame_out[0]*LEN != exp_wr[0]) begin
      $display("  [FAIL] T1 帧数x包长 != 拍数 (%0d x %0d != %0d)", frame_out[0], LEN, exp_wr[0]);
      err_total = err_total + 1;
    end else $display("  [PASS] T1 帧数正确 (%0d 帧)", frame_out[0]);

    // ---------------- T2 两路同时(严格优先) ----------------
    $display("--- T2: 两路同时发起 (严格优先: port0 高于 port1) ---");
    en0 = 1'b1; en1 = 1'b1;
    cyc(1500);
    stop_src0; en1 = 1'b1;
    cyc(600);
    stop_src1;
    cyc(200);
    if (rd_err != 0 || exp_rd[0]!=exp_wr[0] || exp_rd[1]!=exp_wr[1]) begin
      $display("  [FAIL] T2 序列错误 err=%0d p0 入%0d/出%0d  p1 入%0d/出%0d",
               rd_err, exp_wr[0], exp_rd[0], exp_wr[1], exp_rd[1]);
      err_total = err_total + 1;
    end else $display("  [PASS] T2 逐拍一致 (p0 %0d拍/%0d帧, p1 %0d拍/%0d帧)",
                      exp_wr[0], frame_out[0], exp_wr[1], frame_out[1]);
    if (frame_out[1]==0) begin $display("  [FAIL] T2 port1 完全没有得到授权(饿死)"); err_total=err_total+1; end
    else $display("  [PASS] T2 port1 也获得了授权 (%0d 帧)", frame_out[1]);

    // ---------------- T3 输出反压 ----------------
    $display("--- T3: 输出随机反压 + 两路同时 ---");
    bp_en = 1'b1;
    en0 = 1'b1; en1 = 1'b1;
    cyc(2500);
    stop_src0; en1 = 1'b1;
    cyc(600);
    stop_src1;
    bp_en = 1'b0;
    cyc(600);
    if (rd_err != 0 || exp_rd[0]!=exp_wr[0] || exp_rd[1]!=exp_wr[1]) begin
      $display("  [FAIL] T3 序列错误 err=%0d p0 入%0d/出%0d  p1 入%0d/出%0d",
               rd_err, exp_wr[0], exp_rd[0], exp_wr[1], exp_rd[1]);
      err_total = err_total + 1;
    end else $display("  [PASS] T3 逐拍一致 (p0 %0d拍/%0d帧, p1 %0d拍/%0d帧)",
                      exp_wr[0], frame_out[0], exp_wr[1], frame_out[1]);
    $display("  [INFO] 结束时 stat_idle=%b stat_active_port=%b", stat_idle, stat_port);

    // ---------------- T4 长跑 ----------------
    $display("--- T4: 长跑 (两路同时, 长时) ---");
    en0 = 1'b1; en1 = 1'b1;
    cyc(6000);
    stop_src0; stop_src1;
    cyc(400);
    if (rd_err != 0 || exp_rd[0]!=exp_wr[0] || exp_rd[1]!=exp_wr[1]) begin
      $display("  [FAIL] T4 序列错误 err=%0d", rd_err); err_total = err_total + 1;
    end else $display("  [PASS] T4 长跑逐拍一致 (p0 %0d拍/%0d帧, p1 %0d拍/%0d帧)",
                      exp_wr[0], frame_out[0], exp_wr[1], frame_out[1]);

    $display("================================================================");
    $display(" 汇总: p0 入%0d 出%0d 帧%0d | p1 入%0d 出%0d 帧%0d | 比对错误=%0d",
             exp_wr[0], exp_rd[0], frame_out[0], exp_wr[1], exp_rd[1], frame_out[1], rd_err);
    if (err_total == 0 && rd_err == 0) $display(" *** ALL TESTS PASSED ***");
    else                               $display(" *** %0d CHECK(S) FAILED (比对错误=%0d) ***", err_total, rd_err);
    $display("================================================================");
    $finish;
  end

  initial begin #4_000_000; $display(" *** TIMEOUT ***"); $finish; end

endmodule
