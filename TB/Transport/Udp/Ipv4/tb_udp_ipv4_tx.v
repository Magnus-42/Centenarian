`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_udp_ipv4_tx.v
// Module Name : tb_udp_ipv4_tx
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-10-17
// ----------------------------------------------------------------------------
// Description : udp_ipv4_tx 链路黄金整包比对(存整包 + 插 UDP 头 + 插 IPv4 头)
//               参考模型独立从网络字节序重算 UDP/IPv4 校验和与头字段,
//               逐字节(按 keep 掩码)比对, 可抓字节序/校验和/补拍三类错误。
// ============================================================================
module tb_udp_ipv4_tx;

  localparam W  = 512;
  localparam K  = 64;
  localparam UW = 108;
  localparam NPKT = 6;

  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst = 1'b1;

  // ---- 每包网络序参数 ----
  localparam [31:0] SRC_IP = 32'hC0A80164;   // 192.168.1.100
  localparam [31:0] DST_IP = 32'hC0A801C8;   // 192.168.1.200
  localparam [15:0] SPORT  = 16'h0B0B;
  localparam [15:0] DPORT  = 16'h1313;
  localparam [7:0]  TTL    = 8'h40;
  localparam [3:0]  PRIO   = 4'd8;

  function [31:0] sw32; input [31:0] x; begin sw32 = {x[7:0],x[15:8],x[23:16],x[31:24]}; end endfunction
  function [15:0] sw16; input [15:0] x; begin sw16 = {x[7:0],x[15:8]}; end endfunction

  reg  [W-1:0]  sdata  = 0;
  reg  [K-1:0]  skeep  = 0;
  reg           slast  = 0;
  reg           svalid = 0;
  reg  [UW-1:0] susr   = {sw32(DST_IP), sw32(SRC_IP), sw16(DPORT), sw16(SPORT), TTL, PRIO};
  wire          sready;

  wire [W-1:0]  mdata;
  wire [K-1:0]  mkeep;
  wire          mlast;
  wire          mvalid;
  wire [3:0]    musr;
  reg           mready = 1'b1;

  udp_ipv4_tx #(.AXIS_USER_WIDTH(UW), .ARBITER_VAL_WIDTH(4)) u_dut (
    .clk(clk), .rst(rst),
    .udp_axis_sdata(sdata), .udp_axis_skeep(skeep), .udp_axis_slast(slast),
    .udp_axis_svalid(svalid), .udp_axis_susr(susr), .udp_axis_sready(sready),
    .ipv4_axis_mdata(mdata), .ipv4_axis_mkeep(mkeep), .ipv4_axis_mlast(mlast),
    .ipv4_axis_mvalid(mvalid), .ipv4_axis_musr(musr), .ipv4_axis_mready(mready)
  );

  // ---------------- 参考模型 ----------------
  integer LEN [0:NPKT-1];

  function [7:0] pay; input integer p; input integer j;
    begin pay = (8'h30 + p*7 + j) & 8'hFF; end
  endfunction

  localparam MAXBYTES = 256;
  reg [7:0] exp_b [0:NPKT*MAXBYTES-1];
  integer   exp_total = 0;

  task automatic build_exp(input integer p);
    integer plen, ulen, i;
    reg [31:0] s; reg [16:0] f; reg [15:0] csum;
    reg [15:0] ucksum, icksum, ul;
    begin
      plen = LEN[p];
      ulen = 8 + plen;
      // UDP 校验和(网络序)
      s = SRC_IP[31:16] + SRC_IP[15:0] + DST_IP[31:16] + DST_IP[15:0];
      s = s + 16'h0011 + ulen[15:0] + SPORT + DPORT + ulen[15:0];
      i = 0;
      while (i + 1 < plen) begin
        s = s + {pay(p,i), pay(p,i+1)}; i = i + 2;
      end
      if (i < plen) s = s + {pay(p,i), 8'h00};
      f = s[15:0] + s[31:16]; f = {1'b0,f[15:0]} + {16'd0,f[16]};
      csum = {1'b0,f[15:0]} + {16'd0,f[16]};
      ucksum = ~csum[15:0];
      if (ucksum == 16'h0000) ucksum = 16'hFFFF;
      // IPv4 头校验和(网络序)
      ul = 20 + ulen;
      s = 16'h4500 + ul + 16'h0000 + 16'h4000 + {TTL,8'h11} + SRC_IP[31:16] + SRC_IP[15:0] + DST_IP[31:16] + DST_IP[15:0];
      f = s[15:0] + s[31:16]; f = {1'b0,f[15:0]} + {16'd0,f[16]};
      csum = {1'b0,f[15:0]} + {16'd0,f[16]};
      icksum = ~csum[15:0];

      exp_b[exp_total+ 0] = 8'h45; exp_b[exp_total+ 1] = 8'h00;
      exp_b[exp_total+ 2] = ul[15:8]; exp_b[exp_total+ 3] = ul[7:0];
      exp_b[exp_total+ 4] = 8'h00; exp_b[exp_total+ 5] = 8'h00;
      exp_b[exp_total+ 6] = 8'h40; exp_b[exp_total+ 7] = 8'h00;
      exp_b[exp_total+ 8] = TTL; exp_b[exp_total+ 9] = 8'h11;
      exp_b[exp_total+10] = icksum[15:8]; exp_b[exp_total+11] = icksum[7:0];
      exp_b[exp_total+12] = SRC_IP[31:24]; exp_b[exp_total+13] = SRC_IP[23:16];
      exp_b[exp_total+14] = SRC_IP[15:8];  exp_b[exp_total+15] = SRC_IP[7:0];
      exp_b[exp_total+16] = DST_IP[31:24]; exp_b[exp_total+17] = DST_IP[23:16];
      exp_b[exp_total+18] = DST_IP[15:8];  exp_b[exp_total+19] = DST_IP[7:0];
      exp_b[exp_total+20] = SPORT[15:8]; exp_b[exp_total+21] = SPORT[7:0];
      exp_b[exp_total+22] = DPORT[15:8]; exp_b[exp_total+23] = DPORT[7:0];
      exp_b[exp_total+24] = ulen[15:8];  exp_b[exp_total+25] = ulen[7:0];
      exp_b[exp_total+26] = ucksum[15:8]; exp_b[exp_total+27] = ucksum[7:0];
      for (i = 0; i < plen; i = i + 1) exp_b[exp_total+28+i] = pay(p,i);
      exp_total = exp_total + 28 + plen;
    end
  endtask

  // ---------------- 发送(顺序, 每拍握手) ----------------
  task automatic send_pkt(input integer p);
    integer plen, nb, b0, jj, ii;
    begin
      plen = LEN[p]; nb = (plen + 63) / 64; if (nb == 0) nb = 1;
      for (jj = 0; jj < nb; jj = jj + 1) begin
        b0 = jj * 64;
        @(negedge clk);
        sdata = 0; skeep = 0;
        for (ii = 0; ii < 64; ii = ii + 1) begin
          if (b0 + ii < plen) begin sdata[ii*8 +: 8] = pay(p, b0+ii); skeep[ii] = 1'b1; end
        end
        slast  = (jj == nb-1);
        svalid = 1'b1;
        @(posedge clk);
        while (sready !== 1'b1) @(posedge clk);
      end
      svalid = 1'b0;
    end
  endtask

  // ---------------- 输出收集 ----------------
  reg [W-1:0] out_buf [0:NPKT*MAXBYTES-1];
  integer out_wr = 0, pkt_seen = 0, xcnt = 0;
  integer kk;
  always @(posedge clk) begin
    if (mvalid && mready) begin
      if ((^mdata)===1'bx || (^mkeep)===1'bx) xcnt = xcnt + 1;
      for (kk = 0; kk < 64; kk = kk + 1) begin
        if (mkeep[kk]) begin
          out_buf[out_wr] = mdata[kk*8 +: 8];
          out_wr = out_wr + 1;
        end
      end
      if (mlast) pkt_seen = pkt_seen + 1;
    end
  end

  integer err = 0, i, j;

  initial begin
    LEN[0] = 1;  LEN[1] = 55; LEN[2] = 56;
    LEN[3] = 57; LEN[4] = 44; LEN[5] = 128;

    for (j = 0; j < NPKT; j = j + 1) build_exp(j);

    repeat (4) @(posedge clk);
    rst = 1'b0;

    for (j = 0; j < NPKT; j = j + 1) send_pkt(j);
    repeat (20) @(posedge clk);

    while (pkt_seen < NPKT) begin
      @(posedge clk);
      if ($time > 2000000) begin
        $display("  [FAIL] timeout: pkt_seen=%0d/%0d", pkt_seen, NPKT);
        err = err + 1;
        $finish;
      end
    end

    if (out_wr != exp_total) begin
      $display("  [FAIL] 输出字节 %0d != 期望 %0d", out_wr, exp_total);
      err = err + 1;
    end
    j = (out_wr < exp_total) ? out_wr : exp_total;
    for (i = 0; i < j; i = i + 1) begin
      if (out_buf[i] !== exp_b[i]) begin
        if (err < 20) $display("  [FAIL] byte%0d 实际=%02x 期望=%02x", i, out_buf[i], exp_b[i]);
        err = err + 1;
      end
    end
    if (xcnt > 0) err = err + 1;

    if (err == 0) $display(" *** ALL CHAIN CHECKS PASSED *** (%0d bytes, %0d pkts)", exp_total, NPKT);
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
    $finish;
  end

  initial begin
    #3000000;
    $display(" FATAL: timeout");
    $finish;
  end

endmodule
`resetall
