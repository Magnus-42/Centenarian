`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_udp_ipv4_header_add.v
// Module Name : tb_udp_ipv4_header_add
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-10-18
// ----------------------------------------------------------------------------
// Description : udp_ipv4_header_add 严格整包比对（独立参考模型，按 keep 重建字节流）
//   被测契约: 输入 = UDP 数据报(8B UDP 头 + 载荷); 输出 = 20B IPv4 头 + 整个 UDP 数据报
//     IPv4 头: 0x45 / TOS=0 / total_len=UDP长度+20(网络序) / id=0 / flags=0x4000(DF)
//              / TTL(usr[11:4]) / proto=0x11 / 校验和 / src_ip(usr[75:44]) / dst_ip(usr[107:76])
//     usr 原样透传; 末拍高 20 字节含有效数据时补发一个"插入拍"
//   判定（与拍内打包方式解耦）: 输出按 keep 重建字节流, 与参考模型逐字节比
//     [A] 字节内容错   [B] 包字节数错   [C] usr 透传错   [D] 包数/多余拍错
//     [E] 输出含 X     [F] 复位恢复     [G] (INFO) keep 非低位连续
//   5 段: 长度扫描 12 种 / 背靠背交替 keep / 随机长度+随机反压 / 极深反压(走 skid) / 流中复位
// ============================================================================
module tb_udp_ipv4_header_add;

  localparam W  = 512;
  localparam K  = 64;
  localparam UW = 108;
  localparam QN = 8192;
  localparam NMAX = 400;

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  reg  [W-1:0]  sdata  = 0;
  reg  [K-1:0]  skeep  = 0;
  reg           slast  = 0;
  reg           svalid = 0;
  wire          sready ;
  reg  [UW-1:0] susr   = 0;

  wire [W-1:0]  mdata ;
  wire [K-1:0]  mkeep ;
  wire          mlast ;
  wire          mvalid;
  wire [UW-1:0] musr  ;
  reg           mready = 1'b1;

  udp_ipv4_header_add #(.AXIS_USER_WIDTH(UW)) u_dut (
    .clk(clk), .rst(rst),
    .udp_axis_sdata(sdata), .udp_axis_skeep(skeep), .udp_axis_slast(slast),
    .udp_axis_svalid(svalid), .udp_axis_susr(susr), .udp_axis_sready(sready),
    .ipv4_axis_mdata(mdata), .ipv4_axis_mkeep(mkeep), .ipv4_axis_mlast(mlast),
    .ipv4_axis_mvalid(mvalid), .ipv4_axis_musr(musr), .ipv4_axis_mready(mready)
  );

  // ---------------- 反压 ----------------
  reg [31:0] lfsr = 32'h1234_5678;
  always @(posedge clk) if (!rst) lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};

  integer mode = 0;
  integer stall = 0;
  always @(negedge clk) begin
    if (rst) begin mready <= 1'b1; stall <= 0; end
    else begin
      stall <= stall + 1;
      case (mode)
        0: mready <= 1'b1;
        1: mready <= (lfsr[2:0] != 3'b000);        // ~87%
        2: mready <= (lfsr[3:0] < 4'd8);           // ~50%
        3: mready <= ((stall % 40) < 3);           // 极深 (必走 skid)
        4: mready <= lfsr[0];                      // 50% 随机
        default: mready <= 1'b1;
      endcase
    end
  end

  // ---------------- 发送队列 ----------------
  reg [W-1:0]  q_data [0:QN-1];
  reg [K-1:0]  q_keep [0:QN-1];
  reg          q_last [0:QN-1];
  reg [UW-1:0] q_usr  [0:QN-1];
  integer      q_wr, q_rd, gap_hold;

  always @(negedge clk) begin
    if (rst) begin
      svalid <= 1'b0; gap_hold = 0;
    end
    else if (svalid === 1'b1) begin
      if (sready === 1'b1) svalid <= 1'b0;
    end
    else begin
      if (gap_hold > 0) gap_hold = gap_hold - 1;
      else if (q_rd < q_wr) begin
        sdata  <= q_data[q_rd];
        skeep  <= q_keep[q_rd];
        slast  <= q_last[q_rd];
        susr   <= q_usr[q_rd];
        svalid <= 1'b1;
        q_rd    = q_rd + 1;
      end
    end
  end

  // ---------------- 包参数 / 参考模型 ----------------
  integer p_len   [0:NMAX];   // UDP 数据报字节数
  integer p_ttl   [0:NMAX];
  integer p_sip   [0:NMAX];
  integer p_dip   [0:NMAX];
  integer p_sport [0:NMAX];
  integer p_dport [0:NMAX];
  integer p_cks   [0:NMAX];   // 参考模型算出的 IPv4 头校验和(网络序整数)

  function [7:0] dgram_byte; input integer pi; input integer j;
    integer v;
    begin
      case (j)
        0: dgram_byte = (p_sport[pi] >> 8) & 8'hFF;
        1: dgram_byte = p_sport[pi] & 8'hFF;
        2: dgram_byte = (p_dport[pi] >> 8) & 8'hFF;
        3: dgram_byte = p_dport[pi] & 8'hFF;
        4: dgram_byte = (p_len[pi] >> 8) & 8'hFF;      // UDP 长度(网络序)
        5: dgram_byte = p_len[pi] & 8'hFF;
        6: dgram_byte = 8'hA5;                          // UDP 校验和(原样透传)
        7: dgram_byte = 8'h5A;
        default: dgram_byte = (8'h30 + pi*11 + j*5) & 8'hFF;
      endcase
    end
  endfunction

  function [7:0] hdr_byte; input integer pi; input integer t;
    integer total, v;
    begin
      total = p_len[pi] + 20;
      case (t)
        0:  hdr_byte = 8'h45;
        1:  hdr_byte = 8'h00;
        2:  hdr_byte = (total >> 8) & 8'hFF;
        3:  hdr_byte = total & 8'hFF;
        4:  hdr_byte = 8'h00;
        5:  hdr_byte = 8'h00;
        6:  hdr_byte = 8'h40;                            // DF
        7:  hdr_byte = 8'h00;
        8:  hdr_byte = p_ttl[pi] & 8'hFF;
        9:  hdr_byte = 8'h11;                            // UDP
        10: hdr_byte = (p_cks[pi] >> 8) & 8'hFF;
        11: hdr_byte = p_cks[pi] & 8'hFF;
        12: hdr_byte = p_sip[pi] & 8'hFF;
        13: hdr_byte = (p_sip[pi] >> 8)  & 8'hFF;
        14: hdr_byte = (p_sip[pi] >> 16) & 8'hFF;
        15: hdr_byte = (p_sip[pi] >> 24) & 8'hFF;
        16: hdr_byte = p_dip[pi] & 8'hFF;
        17: hdr_byte = (p_dip[pi] >> 8)  & 8'hFF;
        18: hdr_byte = (p_dip[pi] >> 16) & 8'hFF;
        19: hdr_byte = (p_dip[pi] >> 24) & 8'hFF;
        default: hdr_byte = 8'h00;
      endcase
    end
  endfunction

  // 期望输出第 t 字节
  function [7:0] xp_byte; input integer pi; input integer t;
    begin
      if (t < 20) xp_byte = hdr_byte(pi, t);
      else        xp_byte = dgram_byte(pi, t - 20);
    end
  endfunction

  function integer xp_total; input integer pi;
    begin xp_total = p_len[pi] + 20; end
  endfunction

  function [UW-1:0] mk_usr; input integer pi;
    reg [UW-1:0] u;
    begin
      u = {UW{1'b0}};
      u[3:0]    = pi[3:0];
      u[11:4]   = p_ttl[pi];
      u[27:12]  = p_sport[pi];
      u[43:28]  = p_dport[pi];
      u[75:44]  = p_sip[pi];
      u[107:76] = p_dip[pi];
      mk_usr = u;
    end
  endfunction

  // 参考校验和(标准 16bit 反码和, 网络序)
  task automatic calc_cks(input integer pi);
    integer sum, j, cks;
    begin
      sum = 0;
      for (j = 0; j < 20; j = j + 2)
        if (j != 10) sum = sum + (hdr_byte(pi,j)*256 + hdr_byte(pi,j+1));
      while (sum > 16'hFFFF) sum = (sum & 16'hFFFF) + (sum >> 16);
      cks = (~sum) & 16'hFFFF;
      p_cks[pi] = cks;
    end
  endtask

  // 入队一个包(输入拍)
  task automatic push_packet(input integer pi);
    integer nin, nb, b, k;
    reg [W-1:0] d; reg [K-1:0] kp;
    begin
      nin = p_len[pi];
      calc_cks(pi);
      nb = (nin + 63) / 64;
      for (b = 0; b < nb; b = b + 1) begin
        d = {W{1'b0}}; kp = {K{1'b0}};
        for (k = 0; k < 64; k = k + 1)
          if (64*b + k < nin) begin
            d[k*8 +: 8] = dgram_byte(pi, 64*b + k);
            kp[k] = 1'b1;
          end
        q_data[q_wr] = d; q_keep[q_wr] = kp; q_last[q_wr] = (b == nb-1); q_usr[q_wr] = mk_usr(pi);
        q_wr = q_wr + 1;
      end
    end
  endtask

  // ---------------- 分数板 ----------------
  integer errA, errB, errC, errD, errF, x_cnt, infoG;
  integer n_out, n_pkt_out, n_pkt_in;
  integer opkt, obeat, gn;         // gn = 当前输出包已收字节数
  integer score_en = 1;
  // dbg: 0=关闭(默认) / 1=打印首拍恢复的逐拍明细 / 2=打印内部装载探针
  integer dbg = 0, dbg_n = 0;
  // 内部探针: 谁在给输出寄存器装载
  integer xfer_n = 0;
  always @(posedge clk) begin
    if (dbg == 2 && !rst && (u_dut.s4_to_reg || u_dut.skid_to_reg || u_dut.insert_en)) begin
      xfer_n = xfer_n + 1;
      $display("   [XFER] t=%0t #%0d s4r=%b skr=%b ins=%b | sv4=%b ins5=%b fst4=%b | s4keep[43:0]=%h remainkeep=%h",
        $time, xfer_n, u_dut.s4_to_reg, u_dut.skid_to_reg, u_dut.insert_en,
        u_dut.udp_axis_svalid_s4, u_dut.is_insert_beat_s5, u_dut.is_first_beat_s4,
        u_dut.udp_axis_skeep_s4[43:0], u_dut.keep_remain_reg);
    end
  end

  task automatic cyc(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
  endtask

  // 相内超时: 等"队列排空且包数对齐", 超限计 [D] 失败并继续(不卡死)
  task automatic wait_drain(input integer limit);
    integer k;
    begin
      k = 0;
      while ((q_rd < q_wr || n_pkt_out < n_pkt_in) && k < limit) begin cyc(10); k = k + 10; end
      if (k >= limit) begin
        errD = errD + 1;
        $display("   [D-FAIL] 相内超时: 未排空 (q_rd=%0d q_wr=%0d out=%0d in=%0d)",
                 q_rd, q_wr, n_pkt_out, n_pkt_in);
      end
    end
  endtask

  // 相内超时: 等"发送队列积压降到阈值以下"
  task automatic wait_queue_below(input integer th, input integer limit);
    integer k;
    begin
      k = 0;
      while (((q_wr - q_rd) > th) && k < limit) begin cyc(10); k = k + 10; end
      if (k >= limit) begin
        errD = errD + 1;
        $display("   [D-FAIL] 相内超时: 队列积压未下降 (%0d > %0d)", q_wr - q_rd, th);
      end
    end
  endtask

  always @(posedge clk) begin
    if (rst) begin
      opkt = 0; obeat = 0; gn = 0;
    end
    else if (mvalid === 1'b1 && mready === 1'b1) begin : OUT_BEAT
      integer k, hi;
      reg [7:0] gb;
      obeat = obeat + 1;
      n_out = n_out + 1;
      if (dbg == 1 && dbg_n < 10) begin : DBG
        integer q, nv;
        nv = 0;
        for (q = 0; q < 64; q = q + 1) if (mkeep[q]) nv = nv + 1;
        dbg_n = dbg_n + 1;
        $display("   [DBG] t=%0t 拍#%0d last=%b nkeep=%0d data0..7=%02h %02h %02h %02h %02h %02h %02h %02h usr=%h s4r=%b skr=%b ins=%b fst=%b",
                 $time, dbg_n, mlast, nv,
                 mdata[7:0], mdata[15:8], mdata[23:16], mdata[31:24],
                 mdata[39:32], mdata[47:40], mdata[55:48], mdata[63:56],
                 musr, u_dut.s4_to_reg, u_dut.skid_to_reg, u_dut.insert_en, u_dut.is_first_beat_s4);
      end

      // [E] X
      if ((^mdata) === 1'bx || (^mkeep) === 1'bx || mlast === 1'bx || (^musr) === 1'bx) begin
        x_cnt = x_cnt + 1;
        if (x_cnt <= 5) begin : XDIAG
          integer q, fx;
          fx = -1;
          for (q = 0; q < 64; q = q + 1)
            if (((^mdata[8*q +: 8]) === 1'bx) && (fx < 0)) fx = q;
          $display("   [E-FAIL] t=%0t 包%0d 第%0d拍 输出含 X: dataX=%b keepX=%b usrX=%b | mkeep=%h | 首个X字节=%0d (keep=%b)",
                   $time, opkt+1, obeat, (^mdata)===1'bx, (^mkeep)===1'bx, (^musr)===1'bx, mkeep, fx,
                   (fx>=0) ? mkeep[fx] : 1'b0);
        end
      end

      if (score_en == 1) begin
        // [G] keep 低位连续性(仅统计)
        hi = 0;
        for (k = 63; k >= 0; k = k - 1)
          if (mkeep[k]) begin hi = k + 1; k = -1; end
        begin : CONTIG
          integer c, seen0, bad;
          bad = 0; seen0 = 0;
          for (c = 0; c < 64; c = c + 1) begin
            if (!mkeep[c]) seen0 = 1;
            else if (seen0) bad = 1;
          end
          if (bad) infoG = infoG + 1;
        end

        if (opkt >= n_pkt_in) begin
          errD = errD + 1;
          if (errD <= 5) $display("   [D-FAIL] t=%0t 多出输出拍(包%0d 未推入)", $time, opkt+1);
        end
        else begin
          // [A]+[B] 按 keep 重建字节流
          for (k = 0; k < 64; k = k + 1) begin
            if (mkeep[k]) begin
              if (gn >= xp_total(opkt)) begin
                errB = errB + 1;
                if (errB <= 5) $display("   [B-FAIL] t=%0t 包%0d 有效字节超出期望(%0d) 于第%0d拍 byte%0d",
                                        $time, opkt+1, xp_total(opkt), obeat, k);
              end
              else begin
                gb = mdata[8*k +: 8];
                if (gb !== xp_byte(opkt, gn)) begin
                  errA = errA + 1;
                  if (errA <= 10) $display("   [A-FAIL] t=%0t 包%0d(%0dB) 字节#%0d got=%02h exp=%02h (拍%0d/byte%0d)",
                                           $time, opkt+1, p_len[opkt], gn, gb, xp_byte(opkt,gn), obeat, k);
                end
                gn = gn + 1;
              end
            end
          end
          // [C] usr
          if (musr !== mk_usr(opkt)) begin
            errC = errC + 1;
            if (errC <= 5) $display("   [C-FAIL] t=%0t 包%0d 第%0d拍 usr got=%h exp=%h",
                                    $time, opkt+1, obeat, musr, mk_usr(opkt));
          end
          if (mlast === 1'b1) begin
            if (gn !== xp_total(opkt)) begin
              errB = errB + 1;
              if (errB <= 8) $display("   [B-FAIL] t=%0t 包%0d(%0dB) 输出字节数 got=%0d exp=%0d",
                                      $time, opkt+1, p_len[opkt], gn, xp_total(opkt));
            end
            opkt = opkt + 1; obeat = 0; gn = 0;
            n_pkt_out = n_pkt_out + 1;
          end
        end
      end
      else if (mlast === 1'b1) begin
        obeat = 0; gn = 0;
      end
    end
  end

  // ---------------- 测试流程 ----------------
  integer i, base;
  integer lens [0:11];
  integer pkt_seen;

  task automatic set_pkt(input integer pi, input integer len, input integer ttl,
                         input integer sip, input integer dip,
                         input integer sp,  input integer dp);
    begin
      p_len[pi]=len; p_ttl[pi]=ttl; p_sip[pi]=sip; p_dip[pi]=dip;
      p_sport[pi]=sp; p_dport[pi]=dp;
    end
  endtask

  initial begin
    $display("================================================================");
    $display(" tb_udp_ipv4_header_add : 严格测试(独立参考模型, 按 keep 重建字节流)");
    $display("================================================================");
    errA=0; errB=0; errC=0; errD=0; errF=0; x_cnt=0; infoG=0;
    n_out=0; n_pkt_out=0; n_pkt_in=0;
    q_wr=0; q_rd=0; gap_hold=0;
    opkt=0; obeat=0; gn=0; score_en=1;

    rst = 1'b1; cyc(8); rst = 1'b0; cyc(4);

    // ---------------- T1: 长度扫描 ----------------
    $display("---- T1: 长度扫描 8/44/45/64/65/108/109/128/129/200/1024/1524 ----");
    lens[0]=8; lens[1]=44; lens[2]=45; lens[3]=64; lens[4]=65; lens[5]=108;
    lens[6]=109; lens[7]=128; lens[8]=129; lens[9]=200; lens[10]=1024; lens[11]=1524;
    mode = 0;
    for (i = 0; i < 12; i = i + 1) begin
      set_pkt(n_pkt_in, lens[i], 8'h40+i, 32'h6401A8C0+i, 32'hC801A8C0+i, 16'h0B0B+i, 16'h1313+i);
      push_packet(n_pkt_in);
      n_pkt_in = n_pkt_in + 1;
      wait_drain(3000);
      gap_hold = 3;
      wait_drain(3000);
      cyc(20);
    end
    $display("   T1 完成: 输出包 %0d / 输入包 %0d", n_pkt_out, n_pkt_in);

    // ---------------- T2: 背靠背短包交替 keep（关键） ----------------
    $display("---- T2: 背靠背 40 包, 交替 64B(满keep)/10B(部分keep), 零空隙 ----");
    mode = 0; gap_hold = 0;
    for (i = 0; i < 40; i = i + 1) begin
      set_pkt(n_pkt_in, ((i%2)==0) ? 64 : 10, 8'h20+i, 32'h0101A8C0, 32'h0201A8C0, 16'h1234, 16'h5678);
      push_packet(n_pkt_in);
      n_pkt_in = n_pkt_in + 1;
    end
    wait_drain(10000);
    cyc(30);
    $display("   T2 完成: 输出包 %0d / 输入包 %0d", n_pkt_out, n_pkt_in);

    // ---------------- T3: 随机长度 + 随机反压 + 随机空隙 ----------------
    $display("---- T3: 60 包随机长度(8..1600) + 随机反压 + 空隙 0~5 ----");
    mode = 2; gap_hold = 0;
    for (i = 0; i < 60; i = i + 1) begin
      set_pkt(n_pkt_in, 8 + (lfsr % 1593), 8'h30+i, 32'h6401A8C0+i*7, 32'hC801A8C0+i*13,
              16'h1000+i, 16'h2000+i);
      push_packet(n_pkt_in);
      n_pkt_in = n_pkt_in + 1;
      mode = lfsr[4:3] % 5;
      gap_hold = lfsr % 6;
      wait_queue_below(300, 5000);
    end
    wait_drain(30000);
    cyc(30);
    $display("   T3 完成: 输出包 %0d / 输入包 %0d", n_pkt_out, n_pkt_in);

    // ---------------- T4: 极深反压（必走 skid） ----------------
    $display("---- T4: 极深反压 3/40 + 25 包(20~500B) ----");
    mode = 3;
    for (i = 0; i < 25; i = i + 1) begin
      set_pkt(n_pkt_in, 20 + (lfsr % 480), 8'h50+i, 32'h0A00A8C0, 32'h0B00A8C0, 16'h3000+i, 16'h4000+i);
      push_packet(n_pkt_in);
      n_pkt_in = n_pkt_in + 1;
      gap_hold = 0;
      wait_queue_below(200, 5000);
    end
    wait_drain(40000);
    cyc(30);
    $display("   T4 完成: 输出包 %0d / 输入包 %0d", n_pkt_out, n_pkt_in);

    // ---------------- T5: 流中复位 + 恢复 ----------------
    $display("---- T5: 流中复位 + 恢复 ----");
    mode = 3; score_en = 0;
    set_pkt(n_pkt_in, 1000, 8'h60, 32'h01010101, 32'h02020202, 16'h1111, 16'h2222);
    push_packet(n_pkt_in); n_pkt_in = n_pkt_in + 1;
    cyc(150);
    rst = 1'b1; cyc(8); rst = 1'b0; cyc(6);
    mode = 0; mready = 1'b1;            // 关键: 复位后立刻放开反压, 残留拍才无处可藏
    cyc(2);
    q_wr=0; q_rd=0; gap_hold=0; opkt=0; obeat=0; gn=0;
    n_pkt_out=0; n_pkt_in=0;
    begin : CHK_CLEAN
      integer c, dirty;
      dirty = 0;
      for (c = 0; c < 20; c = c + 1) begin
        @(posedge clk);
        if (mvalid === 1'b1 && mready === 1'b1) dirty = 1;
      end
      if (dirty) begin errF = errF + 1; $display("   [F-FAIL] 复位后 20 拍内仍有输出"); end
      else $display("   复位后输出干净");
    end
    score_en = 1; mode = 0;
    for (i = 0; i < 3; i = i + 1) begin
      set_pkt(n_pkt_in, (i==0) ? 8 : (i==1) ? 64 : 300, 8'h70+i, 32'h11223344, 32'h55667788,
              16'hAABB, 16'hCCDD);
      push_packet(n_pkt_in); n_pkt_in = n_pkt_in + 1;
      gap_hold = (i==0) ? 2 : 0;
    end
    wait_drain(20000);
    cyc(30);
    if (n_pkt_out == n_pkt_in) $display("   复位后恢复出包正常 (%0d 包)", n_pkt_out);
    else begin errF = errF + 1; $display("   [F-FAIL] 复位后恢复异常: 输出 %0d / 输入 %0d", n_pkt_out, n_pkt_in); end

    // ---------------- 汇总 ----------------
    cyc(40);
    $display("");
    $display("================================================================");
    $display(" 输出拍 %0d, 输出包 %0d", n_out, n_pkt_out);
    $display(" [A] 字节内容错       = %0d", errA);
    $display(" [B] 包字节数错       = %0d", errB);
    $display(" [C] usr 透传错       = %0d", errC);
    $display(" [D] 包数/多余拍错    = %0d", errD);
    $display(" [E] 输出 X 拍数      = %0d", x_cnt);
    $display(" [F] 复位相关错       = %0d", errF);
    $display(" [G] INFO: keep 非低位连续的拍数 = %0d", infoG);
    if (errA+errB+errC+errD+x_cnt+errF == 0) $display(" *** ALL TESTS PASSED ***");
    else $display(" *** %0d CHECK(S) FAILED ***", errA+errB+errC+errD+x_cnt+errF);
    $display("================================================================");
    $finish;
  end

  initial begin
    #5_000_000;
    $display("   [FAIL] FATAL: timeout (全局看门狗 5ms 到期, 仿真未正常结束)");
    $display(" *** 1 CHECK(S) FAILED *** (超时)");
    $finish;
  end

endmodule
