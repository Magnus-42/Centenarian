`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_udp_ipv4_len_checksum.v
// Module Name : tb_udp_ipv4_len_checksum
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-10-17
// ----------------------------------------------------------------------------
// Description : udp_ipv4_len_checksum 极限压力测试
//
// 判定 11 类（buffer FIFO 已随 RTL 简化删除，原 [L] 项取消）：
//   [A] 首拍侧带      : 每个输出包第 1 拍 (total_len,head_checksum) == 参考值
//   [B] 包内侧带恒定  : 同一包内任意一拍必须 == 本包首拍值  (结构性检查)
//   [C] 载荷/keep      : 逐字节 + keep 比对(含末拍部分 keep)
//   [D] 拍数/last/包数 : 每包拍数 = ceil(字节/64); 包数不丢不重不多
//   [E] usr 透传       : udp_axis_musr == 输入 usr
//   [F] 复位恢复       : 3 次中途复位，每次复位后输出干净且随后仍正常
//   [G] X 检查         : 任何输出拍(mvalid&&mready)上 data/keep/last/usr/侧带 不得含 X
//   [H] 写侧守法       : sready=0 期间 sdata/skeep/slast 不得变化 (不撑爆 axis_fifo_sync 的前提)
//   [I] 包FIFO 水位    : remain_count 不得超过 512 (未撑爆)
//   [J] FIFO 配平      : 结束时 chelen FIFO 剩余深度必须为 0 (每包 1 写 1 读)
//   [K] chelen FIFO 守法: 侧带 FIFO 满时不得再写(否则静默丢侧带 -> 后续包永久错位)
//
// 流量分段：
//   P1 随机 torture  : 200 包, 包长随机(1..32704B, 20% 巨帧 511 拍), 每包随机切反压图案, 随机包间空隙 0~12
//   P2 字节风暴      : 128 个 1 字节包背靠背(零空隙) + 极深反压  ← 短包首拍对齐的最恶劣场景
//   P3 巨帧链        : 8 × 32704B 背靠背 + bursty 反压            ← 同拍读写/近满逃逸场景
//   P4 边界交替      : 1/64/65/32704 循环 + 零空隙               ← 1 拍包与 511 拍包交错
//   P5 复位 x3       : 流量中途复位, 每次复位后验证干净 + 恢复出包
// ============================================================================
module tb_udp_ipv4_len_checksum;

  localparam W  = 512;
  localparam K  = 64;
  localparam UW = 108;

  localparam NMAX = 1400;        // 最大包数(各段之和 < NMAX)
  localparam QN   = 16384;       // 发送队列深度(拍)

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  reg  [W-1:0]  sdata  = 0;
  reg  [K-1:0]  skeep  = 0;
  reg           slast  = 0;
  reg           svalid = 0;
  wire          sready ;
  reg  [UW-1:0] susr   = 108'd0;

  wire [W-1:0]  mdata ;
  wire [K-1:0]  mkeep ;
  wire          mlast ;
  wire          mvalid;
  wire [UW-1:0] musr  ;
  reg           mready = 1'b1;

  wire [15:0]   total_len     ;
  wire [15:0]   head_checksum ;

  udp_ipv4_len_checksum #(.AXIS_USER_WIDTH(UW)) u_dut (
    .clk(clk), .rst(rst),
    .udp_axis_sdata(sdata), .udp_axis_skeep(skeep), .udp_axis_slast(slast),
    .udp_axis_svalid(svalid), .udp_axis_susr(susr), .udp_axis_sready(sready),
    .udp_axis_mdata(mdata), .udp_axis_mkeep(mkeep), .udp_axis_mlast(mlast),
    .udp_axis_mvalid(mvalid), .udp_axis_musr(musr), .udp_axis_mready(mready),
    .total_len(total_len), .head_checksum(head_checksum)
  );

  // ---------------- 随机数与反压图案 ----------------
  reg [31:0] lfsr  = 32'hACE1_1234;
  reg [31:0] rlfsr = 32'h5A5A_0F0F;
  always @(posedge clk) if (!rst) begin
    lfsr  <= {lfsr[30:0],  lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    rlfsr <= {rlfsr[30:0], rlfsr[31]^rlfsr[6]^rlfsr[4]^rlfsr[2]};
  end

  integer mode  = 0;
  integer stall = 0;
  reg     bp_freeze = 1'b0;     // 强制输出冻结(mready=0) —— 用于把两个 FIFO 逼到满
  always @(negedge clk) begin
    if (rst) begin
      mready <= 1'b1; stall <= 0;
    end
    else if (bp_freeze) begin
      mready <= 1'b0;
    end
    else begin
      stall <= stall + 1;
      case (mode)
        0: mready <= 1'b1;                              // 无反压
        1: mready <= (lfsr[2:0] != 3'b000);             // ~87%
        2: mready <= (lfsr[3:0] < 4'd8);                // ~50%
        3: mready <= ((stall % 40) < 3);                // 极深 3/40 (必走 skid)
        4: mready <= ((stall % 200) < 150);             // bursty: 150 收 / 50 停
        5: mready <= ((stall % 64) < 8);                // extreme: 8/64
        6: mready <= lfsr[0];                           // 50% 随机
        default: mready <= ((stall % 100) < 60);        // 长停长放
      endcase
    end
  end

  // ---------------- 发送驱动（严格遵守 sready） ----------------
  reg [W-1:0] sq_data [0:QN-1];
  reg [K-1:0] sq_keep [0:QN-1];
  reg         sq_last [0:QN-1];
  integer     sq_wr, sq_rd, gap_hold;

  always @(negedge clk) begin
    if (rst) begin
      svalid   <= 1'b0;
      gap_hold  = 0;
    end
    else if (svalid === 1'b1) begin
      if (sready === 1'b1) svalid <= 1'b0;              // 被接收 -> 下一拍装载
    end
    else begin
      if (gap_hold > 0) begin
        gap_hold = gap_hold - 1;
      end
      else if (sq_rd < sq_wr) begin
        sdata  <= sq_data[sq_rd];
        skeep  <= sq_keep[sq_rd];
        slast  <= sq_last[sq_rd];
        svalid <= 1'b1;
        sq_rd   = sq_rd + 1;
      end
    end
  end

  // [H] 写侧守法断言: svalid=1 且 sready=0 期间激励不得变化
  reg [W-1:0] sdata_q;  reg [K-1:0] skeep_q;  reg slast_q;  reg svalid_q;  reg srdy_q;
  integer viol_cnt = 0;
  always @(posedge clk) begin
    if (!rst) begin
      if (svalid_q === 1'b1 && srdy_q === 1'b0 &&
          (sdata !== sdata_q || skeep !== skeep_q || slast !== slast_q))
        viol_cnt = viol_cnt + 1;
    end
    sdata_q <= sdata;  skeep_q <= skeep;  slast_q <= slast;  svalid_q <= svalid;  srdy_q <= sready;
  end

  // ---------------- FIFO 水位 / 配平监测 ----------------
  integer pkt_max_remain = 0, chl_max_remain = 0;
  integer pkt_full_cnt = 0, pkt_wr_when_full = 0;
  integer chl_full_cnt = 0, chl_wr_drop = 0;     // 侧带 512 深 FIFO 满 / 满时仍写(=静默丢数据)
  always @(posedge clk) if (!rst) begin
    if (u_dut.u_udp_fifo_sync.remain_count      > pkt_max_remain) pkt_max_remain = u_dut.u_udp_fifo_sync.remain_count;
    if (u_dut.u_chelen_fifo_sync.remain_count   > chl_max_remain) chl_max_remain = u_dut.u_chelen_fifo_sync.remain_count;
    if (u_dut.u_udp_fifo_sync.full === 1'b1) pkt_full_cnt = pkt_full_cnt + 1;
    if (u_dut.rea_handshake === 1'b1 && u_dut.u_udp_fifo_sync.full === 1'b1) pkt_wr_when_full = pkt_wr_when_full + 1;
    if (u_dut.u_chelen_fifo_sync.full === 1'b1) chl_full_cnt = chl_full_cnt + 1;
    if ((u_dut.fifo_axis_slast_reg && u_dut.rea_handshake) && u_dut.u_chelen_fifo_sync.full === 1'b1)
      chl_wr_drop = chl_wr_drop + 1;
  end

  // ---------------- 参考模型（独立从零重算） ----------------
  function [15:0] sw16; input [15:0] x; begin sw16 = {x[7:0], x[15:8]}; end endfunction

  // 第 pi 包第 t 字节(网络序字节值)
  function [7:0] pbyte; input integer pi; input integer t;
    begin pbyte = (8'h5A + pi*13 + t*7) & 8'hFF; end
  endfunction

  integer e_len   [0:NMAX];
  integer e_cks   [0:NMAX];
  integer e_bytes [0:NMAX];
  integer len_list[0:NMAX];

  task automatic expect_of(input integer pi);
    integer j, w, ps, sum_net, csum, ul;
    begin
      ps = 0;
      for (j = 0; j < e_bytes[pi]; j = j + 2) begin
        w = pbyte(pi,j) * 256;
        if (j+1 < e_bytes[pi]) w = w + pbyte(pi,j+1);
        ps = ps + w;
      end
      ul = 8 + e_bytes[pi];
      sum_net = 16'hC0A8 + 16'h0164 + 16'hC0A8 + 16'h01C8 + 16'h0011 +
                16'h0B0B + 16'h1313 + ul + ul + ps;
      while (sum_net > 16'hFFFF) sum_net = (sum_net & 16'hFFFF) + (sum_net >> 16);
      csum = (~sum_net) & 16'hFFFF;
      if (csum == 16'h0000) csum = 16'hFFFF;
      e_len[pi] = sw16(ul[15:0]);
      e_cks[pi] = sw16(csum[15:0]);
    end
  endtask

  // ---------------- 分数板 ----------------
  integer errA, errB, errC, errD, errE, errF, errG;
  integer n_out = 0, n_chk = 0, npush = 0;
  integer opkt = 0, obeat = 0;
  reg [15:0] ob_len, ob_cks;
  integer    score_en = 1;

  integer mvalid_x_cnt = 0;
  integer k, got_b, exp_b;
  always @(posedge clk) if (!rst && mvalid === 1'bx) mvalid_x_cnt = mvalid_x_cnt + 1;

  always @(posedge clk) begin
    if (rst) begin
      opkt = 0; obeat = 0;
    end
    else if (mvalid === 1'b1 && mready === 1'b1) begin
      obeat = obeat + 1;
      n_out = n_out + 1;

      // [G] X 检查
      if ((^mdata) === 1'bx || (^mkeep) === 1'bx || mlast === 1'bx ||
          (^musr) === 1'bx || (^total_len) === 1'bx || (^head_checksum) === 1'bx) begin
        errG = errG + 1;
        if (errG <= 6)
          $display("   [G-FAIL] t=%0t 包%0d 第%0d拍 输出含 X: data(^=%b) keep(^=%b) last=%b usr(^=%b) len(^=%b) cks(^=%b)",
                   $time, opkt+1, obeat, ^mdata, ^mkeep, mlast, ^musr, ^total_len, ^head_checksum);
      end

      // [E] usr 透传
      if (musr !== susr) begin
        errE = errE + 1;
        if (errE <= 3) $display("   [E-FAIL] t=%0t 包%0d 第%0d拍 musr=%0h 期望 %0h", $time, opkt+1, obeat, musr, susr);
      end

      if (opkt < npush && score_en == 1) begin
        // [A] 首拍侧带
        if (obeat == 1) begin
          n_chk = n_chk + 1;
          ob_len = total_len; ob_cks = head_checksum;
          if (total_len !== e_len[opkt] || head_checksum !== e_cks[opkt]) begin
            errA = errA + 1;
            if (errA <= 8)
              $display("   [A-FAIL] t=%0t 包%0d(%0d字节,%0d拍) 首拍侧带 got(%04h,%04h) exp(%04h,%04h)",
                       $time, opkt+1, e_bytes[opkt], (e_bytes[opkt]+63)/64, total_len, head_checksum, e_len[opkt], e_cks[opkt]);
          end
        end
        // [B] 包内侧带恒定
        else if (total_len !== ob_len || head_checksum !== ob_cks) begin
          errB = errB + 1;
          if (errB <= 8)
            $display("   [B-FAIL] t=%0t 包%0d 第%0d拍 侧带被改写 got(%04h,%04h) 本包首拍值(%04h,%04h)",
                     $time, opkt+1, obeat, total_len, head_checksum, ob_len, ob_cks);
        end

        // [C] 载荷/keep
        if (obeat <= ((e_bytes[opkt] + 63) / 64)) begin
          for (k = 0; k < 64; k = k + 1) begin
            got_b = mdata[8*k +: 8];
            exp_b = ((obeat-1)*64 + k < e_bytes[opkt]) ? pbyte(opkt,(obeat-1)*64 + k) : 8'h00;
            if (mkeep[k] !== ((obeat-1)*64 + k < e_bytes[opkt])) begin
              errC = errC + 1;
              if (errC <= 4) $display("   [C-FAIL] t=%0t 包%0d 第%0d拍 byte%0d keep=%b 期望 %b",
                                      $time, opkt+1, obeat, k, mkeep[k], ((obeat-1)*64+k) < e_bytes[opkt]);
            end
            else if (mkeep[k] && (got_b !== exp_b)) begin
              errC = errC + 1;
              if (errC <= 4) $display("   [C-FAIL] t=%0t 包%0d 第%0d拍 byte%0d got %02h exp %02h",
                                      $time, opkt+1, obeat, (obeat-1)*64+k, got_b, exp_b);
            end
          end
        end
        else begin
          errC = errC + 1;
          if (errC <= 4) $display("   [C-FAIL] t=%0t 包%0d 多出发拍(last=%b, 期望%0d拍)",
                                  $time, opkt+1, mlast, (e_bytes[opkt]+63)/64);
        end

        // [D] 拍数 / last
        if (obeat == ((e_bytes[opkt] + 63) / 64)) begin
          if (mlast !== 1'b1) begin
            errD = errD + 1;
            if (errD <= 4) $display("   [D-FAIL] t=%0t 包%0d 末拍(%0d) last=0", $time, opkt+1, obeat);
          end
        end
        else if (mlast === 1'b1 && obeat < ((e_bytes[opkt]+63)/64)) begin
          errD = errD + 1;
          if (errD <= 4) $display("   [D-FAIL] t=%0t 包%0d 第%0d拍提前 last=1(期望%0d拍)",
                                  $time, opkt+1, obeat, (e_bytes[opkt]+63)/64);
        end
      end
      else if (score_en == 1) begin
        errD = errD + 1;
        if (errD <= 4) $display("   [D-FAIL] t=%0t 多出输出包(第 %0d 个, 已推 %0d)", $time, opkt+1, npush);
      end

      if (mlast === 1'b1) begin
        if (score_en == 1) opkt = opkt + 1;
        obeat = 0;
      end
    end
  end

  task automatic cyc(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
  endtask

  // 入队一包(使用 e_bytes[pi] 作为长度)
  task automatic push_packet(input integer pi);
    integer b, v, nb; reg [W-1:0] d; reg [K-1:0] k;
    begin
      nb = (e_bytes[pi] + 63) / 64;
      for (b = 0; b < nb; b = b + 1) begin
        d = {W{1'b0}}; k = {K{1'b0}};
        for (v = 0; v < 64; v = v + 1)
          if (64*b + v < e_bytes[pi]) begin
            d[v*8 +: 8] = pbyte(pi, 64*b + v);
            k[v] = 1'b1;
          end
        sq_data[sq_wr] = d; sq_keep[sq_wr] = k; sq_last[sq_wr] = (b == nb-1);
        sq_wr = sq_wr + 1;
      end
    end
  endtask

  // 准备一段: 从 len_list[0..cnt-1] 生成参考值并建包
  task automatic prepare(input integer cnt);
    integer q;
    begin
      for (q = 0; q < cnt; q = q + 1) begin
        e_bytes[npush+q] = len_list[q];
        expect_of(npush+q);
      end
    end
  endtask

  integer i, q, base;
  integer NP_TOTAL;
  initial begin
    $display("================================================================");
    $display(" tb_udp_ipv4_len_checksum : 极限压力测试 (随机长流 + 字节风暴 + 巨帧链 + 边界 + 复位)");
    $display("================================================================");

    sq_wr = 0; sq_rd = 0; gap_hold = 0;
    npush = 0; n_out = 0; n_chk = 0;
    // usr 位段 (108bit): [3:0]prio [11:4]ttl [27:12]sport [43:28]dport [75:44]src_ip [107:76]dst_ip
    susr[3:0]    = 4'd8;          // priority (必须非 0)
    susr[11:4]   = 8'h40;         // ttl (len_checksum 不使用)
    susr[27:12]  = 16'h0B0B;      // src_port
    susr[43:28]  = 16'h1313;      // dst_port
    susr[75:44]  = 32'h6401A8C0;  // src_ip  (线上 192.168.1.100)
    susr[107:76] = 32'hC801A8C0;  // dst_ip  (线上 192.168.1.200)
    errA=0; errB=0; errC=0; errD=0; errE=0; errF=0; errG=0;
    opkt = 0; obeat = 0;

    rst = 1'b1; cyc(10); rst = 1'b0; cyc(6);

    // ---------------- P1: 随机 torture (200 包) ----------------
    $display("---- P1: 随机 torture (200 包, 包长随机, 每包随机切反压, 空隙 0~12) ----");
    base = npush;
    for (i = 0; i < 200; i = i + 1) begin
      case (rlfsr % 10)
        0,1,2,3: len_list[i] = 1   + (rlfsr % 130);      // 1..130B   (1~3 拍)
        4,5,6  : len_list[i] = 200 + (rlfsr % 1400);     // 200..1599B(4~25 拍)
        7      : len_list[i] = 4096 + (rlfsr % 12289);   // 4K..16K
        default: len_list[i] = 32704 - (rlfsr % 64);     // 32641..32704B (511 拍, 贴上限)
      endcase
    end
    prepare(200);
    for (i = 0; i < 200; i = i + 1) begin
      push_packet(base + i);
      npush = npush + 1;
      mode     = rlfsr % 8;                              // 每包随机换反压图案
      gap_hold = rlfsr % 13;                             // 包间空隙 0~12 拍
      while (sq_wr - sq_rd > 700) cyc(10);               // 限制队列, 避免 TB 侧失控
    end
    while (sq_rd < sq_wr || opkt < npush) cyc(20);
    cyc(60);
    $display("   P1 完成: 输出包 %0d / 已推 %0d", opkt, npush);

    // ---------------- P2: 字节风暴 (128 个 1B 包, 零空隙, 极深反压) ----------------
    $display("---- P2: 字节风暴 (128 x 1B 背靠背 + extreme 反压 8/64) ----");
    base = npush;
    for (i = 0; i < 128; i = i + 1) len_list[i] = 1;
    prepare(128);
    gap_hold = 0;
    for (i = 0; i < 128; i = i + 1) begin
      push_packet(base + i);
      npush = npush + 1;
      mode = 5;
    end
    while (sq_rd < sq_wr || opkt < npush) cyc(20);
    cyc(60);
    $display("   P2 完成: 输出包 %0d / 已推 %0d", opkt, npush);

    // ---------------- P3: 巨帧链 (8 x 32704B 背靠背 + bursty) ----------------
    $display("---- P3: 巨帧链 (8 x 32704B=511拍 背靠背 + bursty 150/200) ----");
    base = npush;
    for (i = 0; i < 8; i = i + 1) len_list[i] = 32704;
    prepare(8);
    gap_hold = 0;
    for (i = 0; i < 8; i = i + 1) begin
      push_packet(base + i);
      npush = npush + 1;
      mode = 4;
    end
    while (sq_rd < sq_wr || opkt < npush) cyc(20);
    cyc(60);
    $display("   P3 完成: 输出包 %0d / 已推 %0d", opkt, npush);

    // ---------------- P4: 边界交替 (1/64/65/32704 循环, 零空隙) ----------------
    $display("---- P4: 边界交替 (1B/64B/65B/32704B 循环 x6 + 零空隙, 长停长放) ----");
    base = npush;
    for (i = 0; i < 24; i = i + 1) begin
      case (i % 4)
        0: len_list[i] = 1;
        1: len_list[i] = 64;
        2: len_list[i] = 65;
        default: len_list[i] = 32704;
      endcase
    end
    prepare(24);
    gap_hold = 0;
    for (i = 0; i < 24; i = i + 1) begin
      push_packet(base + i);
      npush = npush + 1;
      mode = 7;
    end
    while (sq_rd < sq_wr || opkt < npush) cyc(20);
    cyc(60);
    $display("   P4 完成: 输出包 %0d / 已推 %0d", opkt, npush);

    NP_TOTAL = npush;

    // ---------------- P6: 深度边界 (512 x 1B 背靠背 + 输出长冻结) ----------------
    // 目的: 把 包FIFO(512) 与 侧带 chelen FIFO(512) 同时逼到满 ——
    //       若 chelen 深度不足, fifo_sync 的 `wr_en && !fifo_full` 会静默丢写 => 侧带错包。
    $display("---- P6: 深度边界 (512 x 1B 背靠背 + 输出冻结 2500 拍) ----");
    base = npush;
    for (i = 0; i < 512; i = i + 1) len_list[i] = 1;
    prepare(512);
    gap_hold = 0;
    bp_freeze = 1'b1;                              // 输出全停
    for (i = 0; i < 512; i = i + 1) begin
      push_packet(base + i);
      npush = npush + 1;
    end
    cyc(2500);                                     // 两个 FIFO 被填满, 输入端被 sready 顶住
    bp_freeze = 1'b0; mode = 3;
    while (sq_rd < sq_wr || opkt < npush) cyc(20);
    cyc(80);
    NP_TOTAL = npush;
    $display("   P6 完成: 输出包 %0d / 已推 %0d (chelen 最高水位 %0d)", opkt, npush, chl_max_remain);

    // ---------------- P5: 中途复位 x3 ----------------
    $display("---- P5: 中途复位 x3 (每次复位后输出须干净 + 恢复出包) ----");
    for (q = 0; q < 3; q = q + 1) begin
      mode = 3;                                     // 极深反压, 让流水线里留满数据
      score_en = 0;                                 // 复位前流量不打分
      sq_wr = 0; sq_rd = 0; gap_hold = 0;
      base = npush;
      len_list[0] = 4096 + q*1000; len_list[1] = 1500;       // 两个长包
      for (i = 0; i < 2; i = i + 1) begin
        e_bytes[npush+i] = len_list[i]; expect_of(npush+i);
        push_packet(npush+i);
      end
      cyc(400 + q*200);                             // 只推进一部分
      rst = 1'b1; cyc(10); rst = 1'b0; cyc(6);
      sq_wr = 0; sq_rd = 0; gap_hold = 0;           // 清空发送队列

      // 复位后 30 拍内不得有任何输出
      begin : CHK_CLEAN
        integer c; integer dirty;
        dirty = 0;
        for (c = 0; c < 30; c = c + 1) begin
          @(posedge clk);
          if (mvalid === 1'b1 && mready === 1'b1) dirty = 1;
        end
        if (dirty) begin
          errF = errF + 1;
          $display("   [F-FAIL] 第%0d 次复位后 30 拍内仍有输出(mvalid&&mready)", q+1);
        end
      end

      // 恢复: 打 3 包(1B/56B/300B)验证仍正常
      opkt = 0; obeat = 0; score_en = 1; npush = 0;
      mode = (q==0) ? 0 : (q==1) ? 3 : 6;
      base = 0;
      len_list[0] = 1; len_list[1] = 56; len_list[2] = 300;
      for (i = 0; i < 3; i = i + 1) begin
        e_bytes[i] = len_list[i]; expect_of(i);
      end
      for (i = 0; i < 3; i = i + 1) begin push_packet(i); npush = npush + 1; gap_hold = (i==0) ? 2 : 0; end
      while (sq_rd < sq_wr || opkt < npush) cyc(20);
      cyc(60);
      if (opkt == npush)
        $display("   第%0d 次复位后恢复出包正常 (%0d 包)", q+1, opkt);
      else begin
        errF = errF + 1;
        $display("   [F-FAIL] 第%0d 次复位后恢复异常: 输出 %0d 包 / 期望 %0d", q+1, opkt, npush);
      end
      // 复位后本轮的打分与主计数无关, 只把 opkt 归零避免干扰后续
      opkt = 0; obeat = 0; npush = 0; score_en = 1;
    end

    // ---------------- 汇总 ----------------
    cyc(100);
    $display("");
    $display("================================================================");
    $display(" 分数板: 主段输出包 %0d (期望 %0d), 首拍侧带检查 %0d 次", NP_TOTAL, NP_TOTAL, n_chk);
    $display(" [A] 首拍侧带错       = %0d", errA);
    $display(" [B] 包内侧带被改写   = %0d", errB);
    $display(" [C] 载荷/keep 错     = %0d", errC);
    $display(" [D] 拍数/last/包数错 = %0d", errD);
    $display(" [E] usr 透传错       = %0d", errE);
    $display(" [F] 复位相关错       = %0d", errF);
    $display(" [G] 输出含 X 拍数    = %0d  (另: mvalid=1'bx 计 %0d 次)", errG, mvalid_x_cnt);
    $display(" [H] 写侧违规次数     = %0d  %s", viol_cnt, (viol_cnt==0) ? "(严格遵守 sready OK)" : "(违反反压!)");
    $display(" [I] 包FIFO(512) 最高水位 = %0d 拍, full 命中 %0d 拍, full 时仍发写 %0d 次  %s",
             pkt_max_remain, pkt_full_cnt, pkt_wr_when_full,
             (pkt_max_remain <= 512) ? "(未撑爆 OK)" : "(撑爆!)");
    $display("     侧带 chelen 512 深 FIFO 最高水位 = %0d 拍 (满命中 %0d 拍)", chl_max_remain, chl_full_cnt);
    $display(" [K] chelen FIFO 满时仍写(静默丢侧带) = %0d 次  %s", chl_wr_drop,
             (chl_wr_drop==0) ? "(无丢写 OK)" : "(侧带深度不足!)");
    $display(" [J] 结束时 chelen FIFO 剩余 = %0d  %s",
             u_dut.u_chelen_fifo_sync.remain_count,
             (u_dut.u_chelen_fifo_sync.remain_count == 0) ? "(配平 OK)" : "(不配平!)");
    if (errA+errB+errC+errD+errE+errF+errG == 0 && viol_cnt == 0 && pkt_max_remain <= 512 && chl_wr_drop == 0)
      $display(" *** ALL TORTURE CHECKS PASSED ***");
    else
      $display(" *** %0d CHECK(S) FAILED ***", errA+errB+errC+errD+errE+errF+errG+((viol_cnt>0)?1:0)+((chl_wr_drop>0)?1:0));
    $display("================================================================");
    $finish;
  end

  initial begin
    #20_000_000;
    $display("[%0t] [FAIL] FATAL: timeout", $time);
    $finish;
  end

endmodule
`resetall
