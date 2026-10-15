`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_ipv4_mac_add.v
// Module Name : tb_ipv4_mac_add
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-09-18
// ----------------------------------------------------------------------------
// Description : ipv4_mac_add 自测平台
//   约定(与设计一致): 拍内按字段大端、字段从低位往高位排; keep[i] 对应帧第 i 字节。
//   本模块期望行为 = 在纯 IPv4 包前插入 14 字节以太头, 且不改写 IPv4 头里的目的 IP:
//     out[111:  0] = {16'h0008, cfg_local_mac, dst_mac}          (以太头, 线序)
//     out[271:240] = in[159:128]                                  (原包自己的 dst IP, 不得被改写)
//     out[511:272] = in[399:160]                                  (其余载荷上移 112bit)
//     out[239:112] = in[127:  0]
//     首拍 mkeep   = {in_keep[49:0], 14'h3FFF}
//   插入拍(末拍高 14 字节含有效数据时才有):
//     mdata = {400'd0, in_prev[511:400]}, mkeep = {50'd0, in_prev_keep[63:50]}, mlast = 1
//   测试用字节图案: 第 i 字节 = 8'h10 + i  (便于观察错位)
// ============================================================================

module tb_ipv4_mac_add;

  localparam CLK_PERIOD = 10;

  localparam [31:0] DST_IP_0 = 32'h0500_000A;   // 线序: 线上 05 00 00 0A => 10.0.0.5
  localparam [47:0] DST_MAC_0= 48'h0500DDCCBBAA;  // 线序: 线上 05 00 0A AA BB CC DD 段 => AA:BB:CC:DD:00:05
  localparam [47:0] SRC_MAC  = 48'h554433221100;  // 线序: 线上 00 11 22 33 44 55 => 00:11:22:33:44:55

  reg                       clk = 1'b0;
  reg                       rst = 1'b1;

  reg  [511:0]              ipv4_axis_sdata ;
  reg  [63:0]               ipv4_axis_skeep ;
  reg                       ipv4_axis_slast ;
  reg                       ipv4_axis_svalid;
  wire                      ipv4_axis_sready;

  // 注: dst_ip 输入口已随 S1 修复删除, 本 TB 改为"IPv4 头目的 IP 必须原样透传"
  reg  [47:0]               dst_mac ;

  wire [511:0]              eth_axis_mdata ;
  wire [63:0]               eth_axis_mkeep ;
  wire                      eth_axis_mlast ;
  wire                      eth_axis_mvalid;
  reg                       eth_axis_mready;

  always #(CLK_PERIOD/2) clk = ~clk;

  ipv4_mac_add u_dut(
    .clk              (clk              ),
    .rst              (rst              ),
    .ipv4_axis_sdata  (ipv4_axis_sdata  ),
    .ipv4_axis_skeep  (ipv4_axis_skeep  ),
    .ipv4_axis_slast  (ipv4_axis_slast  ),
    .ipv4_axis_svalid (ipv4_axis_svalid ),
    .ipv4_axis_susr   (4'd0            ),
    .ipv4_axis_sready (ipv4_axis_sready ),
    .dst_mac          (dst_mac          ),
    .src_mac          (SRC_MAC          ),
    .eth_axis_mdata   (eth_axis_mdata   ),
    .eth_axis_mkeep   (eth_axis_mkeep   ),
    .eth_axis_mlast   (eth_axis_mlast   ),
    .eth_axis_mvalid  (eth_axis_mvalid  ),
    .eth_axis_musr    (                ),
    .eth_axis_mready  (eth_axis_mready  )
  );

  // --------------------------------------------------------------------------
  // 输出监视: 记录每一次 m 侧握手
  // --------------------------------------------------------------------------
  integer      got_cnt ;
  reg [511:0]  got_data [0:15];
  reg [63:0]   got_keep [0:15];
  reg          got_last [0:15];

  always @(posedge clk) begin
    if (eth_axis_mvalid && eth_axis_mready) begin
      got_data[got_cnt] = eth_axis_mdata;
      got_keep[got_cnt] = eth_axis_mkeep;
      got_last[got_cnt] = eth_axis_mlast;
      got_cnt           = got_cnt + 1;
    end
  end

  // --------------------------------------------------------------------------
  // 激励: svalid 握手当拍自动拉低(避免重复握手)
  // --------------------------------------------------------------------------
  always @(posedge clk) begin
    if (ipv4_axis_svalid && ipv4_axis_sready) ipv4_axis_svalid <= 1'b0;
  end

  task automatic cyc(input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
  endtask

  task automatic set_mready(input v);
    begin
      @(negedge clk);
      eth_axis_mready <= v;
    end
  endtask

  // 第 i 字节 = 8'h10+i 的 512bit 图案
  function [511:0] pat_data(input [7:0] seed);
    integer i;
    begin
      pat_data = 512'd0;
      for (i = 0; i < 64; i = i + 1) begin
        pat_data[i*8 +: 8] = 8'h10 + i[7:0] + seed;   // 仅用于产生可分辨图案
      end
    end
  endfunction

  task automatic send_beat(input [511:0] d, input [63:0] k, input last);
    begin
      @(negedge clk);
      while (ipv4_axis_svalid !== 1'b0) @(negedge clk);
      ipv4_axis_sdata  <= d;
      ipv4_axis_skeep  <= k;
      ipv4_axis_slast  <= last;
      ipv4_axis_svalid <= 1'b1;
    end
  endtask

  // --------------------------------------------------------------------------
  // 主流程
  // --------------------------------------------------------------------------
  integer err, i, base;
  reg [511:0] d1, d2;
  reg [63:0]  k_full, k_short;
  reg [511:0] exp_hdr;

  initial begin
    $display("================================================================");
    $display(" tb_ipv4_mac_add start");
    $display("================================================================");
    err = 0; got_cnt = 0;
    i   = 0;

    ipv4_axis_sdata  = 512'd0;
    ipv4_axis_skeep  = 64'd0;
    ipv4_axis_slast  = 1'b0;
    ipv4_axis_svalid = 1'b0;
    eth_axis_mready  = 1'b1;
    dst_mac          = DST_MAC_0;

    k_full  = 64'hFFFF_FFFF_FFFF_FFFF;          // 64 字节全有效
    k_short = 64'h0000_0000_000F_FFFF;          // 20 字节有效
    d1      = pat_data(8'h00);

    rst = 1'b1; cyc(10); rst = 1'b0; cyc(2);

    // ---------------- TEST1: 单拍满帧(64B) -> 数据拍 + 插入拍 ----------------
    $display("--- TEST1: 1 beat full(64B) -> data beat + insert beat ---");
    base = got_cnt;
    send_beat(d1, k_full, 1'b1);
    cyc(40);
    if (got_cnt != base + 2) begin
      $display("  [FAIL] expect 2 beats out, got %0d", got_cnt - base); err = err + 1;
    end
    else begin
      // 数据拍
      if (got_data[base][111:0] !== {16'h0008, SRC_MAC, DST_MAC_0}) begin
        $display("  [FAIL] eth header wrong: %h", got_data[base][111:0]); err = err + 1;
      end
      else if (got_data[base][271:240] !== d1[159:128]) begin
        $display("  [FAIL] IPv4 头 dst IP 被改写: [271:240]=%h, 期望原值 %h",
                 got_data[base][271:240], d1[159:128]); err = err + 1;
      end
      else if (got_data[base][511:272] !== d1[399:160]) begin
        $display("  [FAIL] payload high part wrong"); err = err + 1;
      end
      else if (got_data[base][239:112] !== d1[127:0]) begin
        $display("  [FAIL] payload low part wrong"); err = err + 1;
      end
      else if (got_keep[base] !== {k_full[49:0], 14'h3FFF}) begin
        $display("  [FAIL] keep1 wrong: %h", got_keep[base]); err = err + 1;
      end
      else if (got_last[base] !== 1'b0) begin
        $display("  [FAIL] beat1 should not be last (insert beat follows)"); err = err + 1;
      end
      // 插入拍
      else if (got_data[base+1] !== {400'd0, d1[511:400]}) begin
        $display("  [FAIL] insert beat data wrong"); err = err + 1;
      end
      else if (got_keep[base+1] !== {50'd0, k_full[63:50]}) begin
        $display("  [FAIL] insert beat keep wrong: %h", got_keep[base+1]); err = err + 1;
      end
      else if (got_last[base+1] !== 1'b1) begin
        $display("  [FAIL] insert beat should be last"); err = err + 1;
      end
      else $display("  [PASS] data beat(header+shifted payload) + insert beat all correct");
    end
    cyc(20);

    // ---------------- TEST2: 单拍短帧(20B) -> 只需 1 拍, 无插入拍 ----------------
    $display("--- TEST2: 1 beat short(20B) -> single beat, no insert ---");
    base = got_cnt;
    send_beat(d1, k_short, 1'b1);
    cyc(40);
    if (got_cnt != base + 1) begin
      $display("  [FAIL] expect 1 beat out, got %0d", got_cnt - base); err = err + 1;
    end
    else if (got_data[base][111:0] !== {16'h0008, SRC_MAC, DST_MAC_0}) begin
      $display("  [FAIL] header wrong"); err = err + 1;
    end
    else if (got_keep[base] !== {30'd0, k_short[19:0], 14'h3FFF}) begin
      $display("  [FAIL] keep wrong: %h", got_keep[base]); err = err + 1;
    end
    else if (got_last[base] !== 1'b1) begin
      $display("  [FAIL] should be last"); err = err + 1;
    end
    else $display("  [PASS] short packet: single beat with correct keep/last");
    cyc(20);

    // ---------------- TEST3: 双拍满帧 -> 3 拍 ----------------
    $display("--- TEST3: 2 beats full -> 3 beats (shift carry) ---");
    base = got_cnt;
    d2 = pat_data(8'h80);
    send_beat(d1, k_full, 1'b0);
    send_beat(d2, k_full, 1'b1);
    cyc(60);
    if (got_cnt != base + 3) begin
      $display("  [FAIL] expect 3 beats out, got %0d", got_cnt - base); err = err + 1;
    end
    else if (got_data[base+1][511:112] !== d2[399:0]) begin
      $display("  [FAIL] beat2 payload wrong"); err = err + 1;
    end
    else if (got_data[base+1][111:0] !== d1[511:400]) begin
      $display("  [FAIL] beat2 carry(from beat1) wrong"); err = err + 1;
    end
    else if (got_keep[base+1] !== {k_full[49:0], k_full[63:50]}) begin
      $display("  [FAIL] beat2 keep wrong: %h", got_keep[base+1]); err = err + 1;
    end
    else if (got_data[base+2] !== {400'd0, d2[511:400]}) begin
      $display("  [FAIL] insert beat data wrong"); err = err + 1;
    end
    else $display("  [PASS] cross-beat carry + insert beat correct");
    cyc(20);

    // ---------------- TEST4: 反压时输出必须保持(尤其 mlast) ----------------
    $display("--- TEST4: hold beat under backpressure (mlast must be kept) ---");
    set_mready(1'b0);
    send_beat(d1, k_short, 1'b1);       // 短帧末拍, mlast=1, 随后被反压压住
    cyc(20);
    if (eth_axis_mvalid !== 1'b1) begin
      $display("  [FAIL] beat should be presented (mvalid=0)"); err = err + 1;
    end
    else if (eth_axis_mlast !== 1'b1) begin
      $display("  [FAIL] mlast lost while held (got %b) -> frame boundary lost", eth_axis_mlast); err = err + 1;
    end
    else $display("  [PASS] mvalid/mlast held while mready=0");
    set_mready(1'b1);
    cyc(10);
    base = got_cnt;
    cyc(20);
    if (got_cnt != base) begin
      $display("  [FAIL] extra beat after release"); err = err + 1;
    end
    else $display("  [PASS] released, no duplicate");
    cyc(20);

    // ---------------- TEST5: 背靠背混合长度包(压 flow-through 与插入拍交织) ----------------
    // P1:1 拍满(->2 拍)  P2:1 拍短(->1 拍)  P3:2 拍满(->3 拍), 共 6 拍
    $display("--- TEST5: back-to-back mixed-length packets ---");
    base = got_cnt;
    send_beat(d1, k_full , 1'b1);
    send_beat(d1, k_short, 1'b1);
    send_beat(d1, k_full , 1'b0);
    send_beat(d2, k_full , 1'b1);
    cyc(80);
    if (got_cnt != base + 6) begin
      $display("  [FAIL] expect 6 beats, got %0d", got_cnt - base); err = err + 1;
    end
    else if ({got_last[base+5],got_last[base+4],got_last[base+3],
              got_last[base+2],got_last[base+1],got_last[base]} !== 6'b100110) begin
      $display("  [FAIL] mlast pattern wrong: %b (expect 100110)",
               {got_last[base+5],got_last[base+4],got_last[base+3],
                got_last[base+2],got_last[base+1],got_last[base]}); err = err + 1;
    end
    else if (got_data[base  ][111:0] !== {16'h0008,SRC_MAC,DST_MAC_0} ||
             got_data[base+2][111:0] !== {16'h0008,SRC_MAC,DST_MAC_0} ||
             got_data[base+3][111:0] !== {16'h0008,SRC_MAC,DST_MAC_0}) begin
      $display("  [FAIL] eth header missing on a packet-start beat"); err = err + 1;
    end
    // 注: base+3 是"d1(非末拍)+d2(末拍)"这个 2 拍包的首拍, 故其 dst 字段仍应等于 d1 的原值
    else if (got_data[base  ][271:240] !== d1[159:128] ||
             got_data[base+2][271:240] !== d1[159:128] ||
             got_data[base+3][271:240] !== d1[159:128]) begin
      $display("  [FAIL] IPv4 头 dst IP 未原样透传: %h/%h/%h",
               got_data[base][271:240], got_data[base+2][271:240], got_data[base+3][271:240]);
      err = err + 1;
    end
    else if (got_keep[base+1] !== {50'd0, k_full[63:50]} ||
             got_keep[base+5] !== {50'd0, k_full[63:50]}) begin
      $display("  [FAIL] insert beat keep wrong"); err = err + 1;
    end
    else $display("  [PASS] 6 beats, mlast/header/dst IP 透传/insert all correct");
    cyc(20);

    $display("================================================================");
    $display(" beats out=%0d", got_cnt);
    if (err == 0) $display(" *** ALL TESTS PASSED ***");
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
    $display("================================================================");
    $finish;
  end

  initial begin
    $dumpfile("tb_ipv4_mac_add.vcd");
    $dumpvars(0, tb_ipv4_mac_add);
  end

  initial begin
    #200_000;
    $display("[%0t] FATAL: timeout (可能死锁)", $time);
    $finish;
  end

endmodule
`resetall
