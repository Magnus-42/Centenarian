`resetall
`timescale 1ns/100ps
`include "cfg_map.vh"

// File Name   : tb_cfg_cmd_rx.v
// Description : cfg_cmd_rx 单元台 —— 三个相位，合并自原 tb_cfg_cmd_rx_b2b / _len / _soak
//
//   相位 1（b2b）：帧 A 恰好 64 字节（帧尾落在 beat 最后一个字节），紧接着发帧 B 无气泡
//       状态机从 A 的 S_LEN / S_VAL_LOOP 直接跳 S_OP，完全不经 S_IDLE。
//       能同时抓住两类错误：① usr_reg 只在 S_IDLE 锁存 -> 帧 B 沿用帧 A 侧带
//                          ② usr_reg 在帧起点那拍就锁存 -> 帧 A 末条被帧 B 侧带污染
//       正确做法：帧起点装载的下一拍再锁存（frame_start_d）
//       判据：A 的 8 条记录 usr 全为 AAAA...，B 的 1 条记录 usr 为 BBBB...
//
//   相位 2（len）：S_LEN 用「keep + slast」判帧尾，不能用 beat 边界（s_handshake）代替
//       场景 1：5 字节 GET 帧，帧在 beat 中间结束           期望 1 条记录
//       场景 2：80 字节 2 拍帧，第 8 根 TLV 的 LEN 字节正好落在 byte63 且 LEN=16
//               （VAL 延续到第 2 拍）                        期望 8 条记录
//       误用 s_handshake 判尾：场景 1 会吐出大量全 0 幻影记录；场景 2 会丢第 8 条
//
//   相位 3（soak）：随机压力。每帧随机 1~8 条 TLV；LEN 取 {0,4,16}；帧长因此随机，
//       可能是 64 的整数倍；帧间随机 0~3 拍气泡。5 轮 × 40 帧，轮间复位。
//
//   相位 4（byteorder）：VALUE 字节序的权威判定（原 tb_cfg_byteorder.v）
//       地址类 VALUE 走网络序（线上首字节 = 寄存器最低字节，不反转），
//       数值类走小端。这决定了上位机写进设备的 IP 会不会是反的。
//
//   四相位共用同一 DUT、打包/送拍辅助与记录捕获，合并动机见 TB/README.md
//   「一个文件 = 一个测试台，多配置用顺序 phase」。
module tb_cfg_cmd_rx;

  localparam W      = 512;
  localparam K      = 64;
  localparam MAXTLV = 8;
  localparam NFRAME = 40;      // 相位 3：每轮帧数
  localparam NITER  = 5;       // 相位 3：轮数（每轮之间复位清 FIFO）

  // fifo_din = {usr, val, len, set, port, item, seq, op}
  localparam USR_LSB = 168;

  reg clk = 1'b0;
  always #2.5 clk = ~clk;
  reg rst = 1'b1;

  reg  [W-1:0] sdata  = {W{1'b0}};
  reg  [K-1:0] skeep  = {K{1'b0}};
  reg          slast  = 1'b0;
  reg          svalid = 1'b0;
  wire         sready;
  reg  [95:0]  susr   = 96'd0;

  cfg_cmd_rx #(.AXIS_WIDTH(512), .MAX_VALUE_BYTES(16), .CMD_USR_WIDTH(96)) u_dut (
    .clk            (clk            ),
    .rst            (rst            ),
    .axis_sdata     (sdata          ),
    .axis_skeep     (skeep          ),
    .axis_slast     (slast          ),
    .axis_svalid    (svalid         ),
    .axis_sready    (sready         ),
    .axis_susr      (susr           ),
    .is_beat1_drop  (1'b0           ),
    .frame_rd_en    (1'b0           ),
    .frame_empty    (               ),
    .rec_op         (               ),
    .rec_seq        (               ),
    .rec_item       (               ),
    .rec_set        (               ),
    .rec_port       (               ),
    .rec_len        (               ),
    .rec_val        (               ),
    .rec_usr        (               )
  );

  // ---------------- 统一记录捕获（三相位共用） ----------------
  localparam NCAP = 2048;
  reg [ 7:0] r_op  [0:NCAP-1];
  reg [ 7:0] r_seq [0:NCAP-1];
  reg [ 7:0] r_item[0:NCAP-1];
  reg [ 3:0] r_set [0:NCAP-1];
  reg [ 3:0] r_port[0:NCAP-1];
  reg [ 7:0] r_len [0:NCAP-1];
  reg [95:0] r_usr [0:NCAP-1];
  integer    nrec   = 0;
  reg        cap_clr = 1'b0;
  always @(posedge clk) begin
    if (cap_clr) begin
      nrec <= 0;
    end
    else if (!rst && u_dut.fifo_wr_en && nrec < NCAP-1) begin
      r_op  [nrec] <= u_dut.fifo_din[ 0 +: 8];
      r_seq [nrec] <= u_dut.fifo_din[ 8 +: 8];
      r_item[nrec] <= u_dut.fifo_din[16 +: 8];
      r_port[nrec] <= u_dut.fifo_din[24 +: 4];
      r_set [nrec] <= u_dut.fifo_din[28 +: 4];
      r_len [nrec] <= u_dut.fifo_din[32 +: 8];
      r_usr [nrec] <= u_dut.fifo_din[USR_LSB +: 96];
      nrec         <= nrec + 1;
    end
  end

  // ---------------- 帧缓冲与辅助任务 ----------------
  reg [7:0] fb [0:511];
  integer   frm_len;
  integer   i, err = 0, chk = 0;
  reg [8*28-1:0] phase_name = "init";

  // 把 fb[off .. off+len-1] 打包进 W 位总线低位
  function [W-1:0] pack;
    input integer off;
    input integer len;
    integer v;
    begin
      pack = {W{1'b0}};
      for (v = 0; v < 64; v = v + 1)
        if (v < len) pack[v*8 +: 8] = fb[off + v];
    end
  endfunction

  function [K-1:0] mk_keep;
    input integer len;
    integer v;
    begin
      mk_keep = {K{1'b0}};
      for (v = 0; v < 64; v = v + 1) if (v < len) mk_keep[v] = 1'b1;
    end
  endfunction

  // 送一拍；返回时握手已完成，调用方可以立刻换下一拍（保持 valid 高，无气泡）
  task automatic beat;
    input [W-1:0] d;
    input [K-1:0] k;
    input         l;
    input [95:0]  u;
    begin
      // 必须用非阻塞：调用返回后紧接着换下一拍数据，若用阻塞赋值会与 DUT
      // 在同一个 posedge 的采样竞争（实测会让 DUT 采到下一帧的数据）
      sdata <= d; skeep <= k; slast <= l; susr <= u; svalid <= 1'b1;
      @(posedge clk);
      while (!(svalid && sready)) @(posedge clk);
    end
  endtask

  task automatic clr_cap;
    begin
      cap_clr = 1'b1; @(posedge clk); cap_clr = 1'b0; @(posedge clk);
    end
  endtask

  task automatic do_reset;
    begin
      svalid <= 1'b0; slast <= 1'b0;
      rst = 1'b1; repeat (8) @(posedge clk);
      rst = 1'b0; repeat (4) @(posedge clk);
    end
  endtask

  task automatic dump_head;
    input integer n;
    integer j;
    begin
      $display("   >>> 本相位写入 %0d 条记录（打印前 %0d 条）:", nrec, (nrec < n) ? nrec : n);
      for (j = 0; j < nrec && j < n; j = j + 1)
        $display("       rec%0d op=%h seq=%h item=%h len=%0d usr=%h",
                 j, r_op[j], r_seq[j], r_item[j], r_len[j], r_usr[j]);
    end
  endtask

  // ===========================================================================
  // 相位 1：帧级侧带（usr）在背靠背边界上的锁存时机
  // ===========================================================================
  localparam [95:0] USR_A = 96'hAAAA_0000_0000_0000_0000_0001;
  localparam [95:0] USR_B = 96'hBBBB_0000_0000_0000_0000_0002;

  task automatic phase_b2b;
    begin
      phase_name = "P1-b2b";
      $display("================================================================");
      $display(" P1 b2b : 64B 帧A + 5B 帧B 背靠背（无气泡）");
      $display("   期望：A 的 8 条记录 usr=AAAA...，B 的 1 条记录 usr=BBBB...");
      $display("   注意：A 恰好 64B => B 不经 S_IDLE，直接进 S_OP");
      $display("================================================================");
      do_reset;
      clr_cap;

      // 帧 A：64 字节 = 21(SET LEN16) + 9(SET LEN4) + 9(SET LEN4) + 5*5(GET LEN0)
      for (i = 0; i < 512; i = i + 1) fb[i] = 8'h00;
      fb[ 0]=8'h02; fb[ 1]=8'hC1; fb[ 2]=8'h04; fb[ 3]=8'h00; fb[ 4]=8'd16;
      fb[21]=8'h02; fb[22]=8'hC2; fb[23]=8'h03; fb[24]=8'h00; fb[25]=8'd4;
      fb[30]=8'h02; fb[31]=8'hC3; fb[32]=8'h03; fb[33]=8'h00; fb[34]=8'd4;
      fb[39]=8'h02; fb[40]=8'hC4; fb[41]=8'h51; fb[42]=8'h00; fb[43]=8'd0;
      fb[44]=8'h02; fb[45]=8'hC5; fb[46]=8'h51; fb[47]=8'h00; fb[48]=8'd0;
      fb[49]=8'h02; fb[50]=8'hC6; fb[51]=8'h51; fb[52]=8'h00; fb[53]=8'd0;
      fb[54]=8'h02; fb[55]=8'hC7; fb[56]=8'h51; fb[57]=8'h00; fb[58]=8'd0;
      fb[59]=8'h02; fb[60]=8'hC8; fb[61]=8'h51; fb[62]=8'h00; fb[63]=8'd0;
      $display("  帧A 长度 = 64 字节（8 条 TLV）");
      beat(pack(0, 64), {K{1'b1}}, 1'b1, USR_A);      // 帧A：整拍 64 字节，slast=1

      // 帧 B：5 字节，1 条 GET
      for (i = 0; i < 512; i = i + 1) fb[i] = 8'h00;
      fb[0]=8'h02; fb[1]=8'hD1; fb[2]=8'h51; fb[3]=8'h00; fb[4]=8'd0;
      $display("  帧B 长度 = 5 字节（1 条 TLV）");
      beat(pack(0, 5), mk_keep(5), 1'b1, USR_B);      // 帧B：紧接上一拍，无气泡

      @(negedge clk);
      svalid = 1'b0;
      repeat (40) @(posedge clk);

      $display("--------------------------------------------------------------");
      $display(" 共写入 %0d 条记录（期望 9）", nrec);
      for (i = 0; i < nrec; i = i + 1)
        $display("   rec%0d seq=%h usr=%h", i, r_seq[i], r_usr[i]);

      chk = chk + 1;
      if (nrec !== 9) begin
        $display("  [FAIL] 记录条数 %0d (exp 9)", nrec); err = err + 1;
      end
      else begin
        for (i = 0; i < 8; i = i + 1) begin
          chk = chk + 1;
          if (r_usr[i] !== USR_A) begin
            $display("  [FAIL] 帧A rec%0d usr=%h (exp A)", i, r_usr[i]); err = err + 1;
          end
        end
        chk = chk + 1;
        if (r_usr[8] !== USR_B) begin
          $display("  [FAIL] 帧B rec8 usr=%h (exp B) <= 沿用帧A侧带，未在帧起点重锁存", r_usr[8]);
          err = err + 1;
        end
        if (err == 0) $display("  [PASS] 帧B 记录了 B 的侧带");
      end
    end
  endtask

  // ===========================================================================
  // 相位 2：S_LEN 帧尾判定（keep + slast，不是 beat 边界）
  // ===========================================================================
  task automatic phase_len;
    integer base;
    begin
      phase_name = "P2-len";
      $display("================================================================");
      $display(" P2 len : S_LEN 帧尾判定");
      $display("================================================================");

      // ---------- 场景 1：5 字节 GET 帧，帧在 beat 中间结束 ----------
      do_reset;
      clr_cap;
      base = nrec;
      $display("--- 场景1：5 字节 GET 帧  keep=0x1F slast=1（期望 1 条记录 seq=E1）---");
      for (i = 0; i < 512; i = i + 1) fb[i] = 8'h00;
      fb[0] = 8'h02; fb[1] = 8'hE1; fb[2] = 8'h51; fb[3] = 8'h00; fb[4] = 8'd0;
      beat(pack(0, 5), mk_keep(5), 1'b1, 96'h1234_5678_9ABC_DEF0_0000_0001);
      @(negedge clk); svalid <= 1'b0;
      repeat (160) @(posedge clk);
      dump_head(20);
      chk = chk + 1;
      if ((nrec-base) !== 1) begin
        $display("   [FAIL] 记录条数 = %0d（正确应为 1）", nrec-base); err = err + 1;
      end
      else $display("   [PASS] 记录条数 = 1");

      // ---------- 场景 2：80B 2 拍帧，第 8 根 TLV 的 LEN 落在 byte63 ----------
      //  TLV1 SET 0x04 LEN16 @0  (21B : 0..20)
      //  TLV2 SET 0x03 LEN4  @21 (9B  : 21..29)
      //  TLV3 SET 0x03 LEN4  @30 (9B  : 30..38)
      //  TLV4..7 GET 0x51 LEN0 @39/44/49/54 (各 5B)
      //  TLV8 SET 0x04 LEN16 @59 (21B : 59..79) => OP59 SEQ60 ITEM61 TAG62 LEN63, VAL64..79
      $display("--- 场景2：80 字节 2 拍帧，TLV8 的 LEN 字节在 byte63（LEN=16，VAL 到第 2 拍）---");
      $display("           期望 8 条记录 seq=C1..C8，其中 C8 len=16");
      do_reset;
      clr_cap;
      base = nrec;
      for (i = 0; i < 512; i = i + 1) fb[i] = 8'h00;
      fb[ 0]=8'h02; fb[ 1]=8'hC1; fb[ 2]=8'h04; fb[ 3]=8'h00; fb[ 4]=8'd16;
      fb[21]=8'h02; fb[22]=8'hC2; fb[23]=8'h03; fb[24]=8'h00; fb[25]=8'd4;
      fb[30]=8'h02; fb[31]=8'hC3; fb[32]=8'h03; fb[33]=8'h00; fb[34]=8'd4;
      fb[39]=8'h02; fb[40]=8'hC4; fb[41]=8'h51; fb[42]=8'h00; fb[43]=8'd0;
      fb[44]=8'h02; fb[45]=8'hC5; fb[46]=8'h51; fb[47]=8'h00; fb[48]=8'd0;
      fb[49]=8'h02; fb[50]=8'hC6; fb[51]=8'h51; fb[52]=8'h00; fb[53]=8'd0;
      fb[54]=8'h02; fb[55]=8'hC7; fb[56]=8'h51; fb[57]=8'h00; fb[58]=8'd0;
      fb[59]=8'h02; fb[60]=8'hC8; fb[61]=8'h04; fb[62]=8'h00; fb[63]=8'd16;
      for (i = 64; i < 80; i = i + 1) fb[i] = 8'hA5;      // VAL 16B

      beat(pack(0, 64),  {K{1'b1}}   , 1'b0, 96'h1234_5678_9ABC_DEF0_0000_0001);  // 第 1 拍：64 字节
      beat(pack(64, 16), mk_keep(16) , 1'b1, 96'h1234_5678_9ABC_DEF0_0000_0001);  // 第 2 拍：16 字节
      @(negedge clk); svalid <= 1'b0;
      repeat (200) @(posedge clk);
      dump_head(20);
      chk = chk + 1;
      if ((nrec-base) !== 8) begin
        $display("   [FAIL] 记录条数 = %0d（正确应为 8）", nrec-base); err = err + 1;
      end
      else begin
        chk = chk + 1;
        if (r_seq[nrec-1] !== 8'hC8 || r_len[nrec-1] !== 8'd16) begin
          $display("   [FAIL] 末条记录 seq=%h len=%0d（应 C8/16，说明 TLV8 被吞）",
                   r_seq[nrec-1], r_len[nrec-1]); err = err + 1;
        end
        else $display("   [PASS] 记录条数 = 8，末条 C8 len=16");
      end
    end
  endtask

  // ===========================================================================
  // 相位 3：随机压力（随机 TLV 组合 / 随机帧长 / 随机气泡）
  // ===========================================================================
  reg [7:0] e_seq [0:511];
  reg [7:0] e_itm [0:511];
  reg [7:0] e_len [0:511];
  integer   nexp = 0;
  reg [7:0] tx_seq = 8'd1;
  integer   seed = 1;

  task automatic build_frame;
    integer n, k, v, len, itm;
    begin
      n = 1 + ({$random(seed)} % MAXTLV);        // 1..MAXTLV 条
      frm_len = 0;
      for (k = 0; k < n; k = k + 1) begin
        v = {$random(seed)} % 3;
        if      (v == 0) begin len = 0;  itm = 8'h51; end   // GET VERSION
        else if (v == 1) begin len = 4;  itm = 8'h03; end   // SET/GET mask
        else             begin len = 16; itm = 8'h04; end   // SET/GET IPv6 SRC

        fb[frm_len] = 8'h02;         frm_len = frm_len + 1;  // OP
        fb[frm_len] = tx_seq;        frm_len = frm_len + 1;  // SEQ
        fb[frm_len] = itm;           frm_len = frm_len + 1;  // TAG 低字节 = ITEM
        fb[frm_len] = 8'h00;         frm_len = frm_len + 1;  // TAG 高字节 = {set,port}
        fb[frm_len] = len;           frm_len = frm_len + 1;  // LEN
        for (v = 0; v < len; v = v + 1) begin
          fb[frm_len] = 8'h80 + v;   frm_len = frm_len + 1;  // VAL
        end

        e_seq[nexp] = tx_seq;
        e_itm[nexp] = itm;
        e_len[nexp] = len;
        nexp    = nexp + 1;
        tx_seq  = tx_seq + 1;
      end
    end
  endtask

  // 逐拍送出当前帧；帧内保持 valid 不断，帧尾后按 gap 撤 valid
  task automatic drive_frame;
    integer b, nb, v;
    reg [W-1:0] d;
    reg [K-1:0] kk;
    begin
      nb = (frm_len + 63) / 64;
      for (b = 0; b < nb; b = b + 1) begin
        d = {W{1'b0}}; kk = {K{1'b0}};
        for (v = 0; v < 64; v = v + 1)
          if ((b*64 + v) < frm_len) begin
            d[v*8 +: 8] = fb[b*64 + v];
            kk[v]       = 1'b1;
          end
        sdata <= d; skeep <= kk; slast <= (b == nb-1); svalid <= 1'b1;
        @(posedge clk);
        while (!(svalid && sready)) @(posedge clk);
      end
      svalid <= 1'b0;
      slast  <= 1'b0;
    end
  endtask

  task automatic phase_soak;
    integer it, nf, gap, j, bad;
    begin
      phase_name = "P3-soak";
      $display("================================================================");
      $display(" P3 soak : 随机 TLV 组合 / 随机帧长 / 随机气泡（%0d 轮 × %0d 帧）",
               NITER, NFRAME);
      $display("================================================================");

      for (it = 0; it < NITER; it = it + 1) begin
        do_reset;
        clr_cap;
        nexp = 0;
        susr <= 96'h0000_0001_0002_0003_0004_0005;

        for (nf = 0; nf < NFRAME; nf = nf + 1) begin
          build_frame;
          drive_frame;
          gap = {$random(seed)} % 4;              // 0~3 拍气泡
          repeat (gap) @(posedge clk);
        end

        repeat (600) @(posedge clk);

        bad = 0;
        if (nrec !== nexp) begin
          $display("  [FAIL] iter%0d 记录条数 %0d (exp %0d)", it, nrec, nexp);
          bad = bad + 1;
        end
        else begin
          for (j = 0; j < nrec; j = j + 1) begin
            chk = chk + 1;
            if (r_seq[j] !== e_seq[j] || r_item[j] !== e_itm[j] || r_len[j] !== e_len[j]) begin
              if (bad < 5)
                $display("  [FAIL] iter%0d rec%0d seq=%h item=%h len=%0d (exp %h/%h/%0d)",
                         it, j, r_seq[j], r_item[j], r_len[j], e_seq[j], e_itm[j], e_len[j]);
              bad = bad + 1;
            end
          end
        end
        err = err + bad;
        $display("  iter%0d : %0d 帧 / %0d 条记录 -> %s", it, NFRAME, nrec,
                 (bad == 0) ? "OK" : "FAIL");
      end
    end
  endtask

  // ===========================================================================
  // 相位 4：VALUE 字节序判定（地址类＝网络序，数值类＝小端）
  //   判据链：cfg_cmd_rx 把线上第 k 字节放进 val_reg[k*8 +: 8]，
  //   所以寄存器值 == VALUE 字节按小端解释的整数；而 cfg_map.vh 的默认值
  //   CFG_DEF_IPV4_IP_P0 = 32'h0901_A8C0 对应的正是 192.168.1.9 的网络序字节
  //   C0 A8 01 09 => 线上字节原样进低位，即「地址类不反转」。
  // ===========================================================================
  reg  [31:0] bo_local_ip = 32'h0901_A8C0;   // CFG_DEF_IPV4_IP_P0
  reg  [31:0] bo_gw_ip    = 32'h0101_A8C0;   // CFG_DEF_IPV4_GW_P0

  // 影子寄存器：模拟 cfg_reg_bank 的写入（命令通道收满一帧的那拍 val_reg 已完整）
  always @(posedge clk) begin
    if (u_dut.fifo_wr_en && (u_dut.item_reg == `CFG_RW_IPV4_LOCAL_IP))
      bo_local_ip <= u_dut.val_reg[31:0];
    if (u_dut.fifo_wr_en && (u_dut.item_reg == `CFG_RW_IPV4_GATEWAY))
      bo_gw_ip    <= u_dut.val_reg[31:0];
  end

  // 一条 9 字节 SET 帧：OP SEQ ITEM TAG LEN + 4B VALUE
  task automatic send_set4;
    input [7:0] seq;
    input [7:0] item;
    input [7:0] b0;
    input [7:0] b1;
    input [7:0] b2;
    input [7:0] b3;
    integer k;
    begin
      for (k = 0; k < 512; k = k + 1) fb[k] = 8'h00;
      fb[0] = 8'h01; fb[1] = seq;  fb[2] = item; fb[3] = 8'h00; fb[4] = 8'd4;
      fb[5] = b0;    fb[6] = b1;   fb[7] = b2;   fb[8] = b3;
      beat(pack(0, 9), mk_keep(9), 1'b1, 96'h0);
      repeat (60) @(posedge clk);          // 等 cmd_rx 收完并写 FIFO
    end
  endtask

  task automatic phase_byteorder;
    begin
      phase_name = "P4-byteorder";
      $display("================================================================");
      $display(" P4 byteorder : VALUE 字节序（地址类网络序 / 数值类小端）");
      $display("================================================================");
      do_reset;
      clr_cap;

      // ---- 用例 1：192.168.1.9，网络序字节 C0 A8 01 09 ----
      $display("\n[1] 写 IPV4_LOCAL_IP = 192.168.1.9（网络序字节 C0 A8 01 09）");
      send_set4(8'h42, `CFG_RW_IPV4_LOCAL_IP, 8'hC0, 8'hA8, 8'h01, 8'h09);
      $display("  写入后 ipv4_local_ip = 32'h%08h", bo_local_ip);
      chk = chk + 1;
      if (bo_local_ip === 32'h0901_A8C0) $display("  [PASS] 网络序字节 C0 A8 01 09 -> 寄存器值 = 32'h0901A8C0（等于 cfg_map 默认值）");
      else begin $display("  [FAIL] 期望 32'h0901A8C0，实得 32'h%08h", bo_local_ip); err = err + 1; end
      chk = chk + 1;
      if (bo_local_ip !== 32'hC0A80109) $display("  [PASS] 寄存器值不是 32'hC0A80109（确认未发生字节反转）");
      else begin $display("  [FAIL] 出现字节反转（32'hC0A80109）"); err = err + 1; end

      // ---- 用例 2：10.20.30.40 ----
      $display("\n[2] 写 IPV4_LOCAL_IP = 10.20.30.40（网络序字节 0A 14 1E 28）");
      send_set4(8'h43, `CFG_RW_IPV4_LOCAL_IP, 8'h0A, 8'h14, 8'h1E, 8'h28);
      $display("  写入后 ipv4_local_ip = 32'h%08h", bo_local_ip);
      chk = chk + 1;
      if (bo_local_ip === 32'h281E140A) $display("  [PASS] 网络序字节 0A 14 1E 28 -> 寄存器值 = 32'h281E140A（线序进低位）");
      else begin $display("  [FAIL] 期望 32'h281E140A，实得 32'h%08h", bo_local_ip); err = err + 1; end

      // ---- 用例 3：网关 ----
      $display("\n[3] 写 IPV4_GATEWAY = 192.168.1.254（网络序字节 C0 A8 01 FE）");
      send_set4(8'h44, `CFG_RW_IPV4_GATEWAY, 8'hC0, 8'hA8, 8'h01, 8'hFE);
      $display("  写入后 ipv4_gateway_ip = 32'h%08h", bo_gw_ip);
      chk = chk + 1;
      if (bo_gw_ip === 32'hFE01_A8C0) $display("  [PASS] 网关同样按网络序字节进寄存器低位");
      else begin $display("  [FAIL] 期望 32'hFE01A8C0，实得 32'h%08h", bo_gw_ip); err = err + 1; end

      // ---- 用例 4：反向验证「反转」是错的 ----
      $display("\n[4] 反向验证：若上位机用「反转」字节 09 01 A8 C0 会写错");
      send_set4(8'h45, `CFG_RW_IPV4_LOCAL_IP, 8'h09, 8'h01, 8'hA8, 8'hC0);
      $display("  写入后 ipv4_local_ip = 32'h%08h", bo_local_ip);
      chk = chk + 1;
      if (bo_local_ip === 32'hC0A80109) $display("  [PASS] 反转字节 09 01 A8 C0 -> 寄存器值 = 32'hC0A80109（与 cfg_map 默认值不符，故反转是错的）");
      else begin $display("  [FAIL] 期望 32'hC0A80109，实得 32'h%08h", bo_local_ip); err = err + 1; end
    end
  endtask

  // ===========================================================================
  // 主流程
  // ===========================================================================
  initial begin
    $display("================================================================");
    $display(" tb_cfg_cmd_rx : 背靠背侧带 / S_LEN 帧尾 / 随机压力 / 字节序（四相位）");
    $display("================================================================");

    phase_b2b;
    phase_len;
    phase_soak;
    phase_byteorder;

    $display("================================================================");
    $display(" 合计检查点：%0d，错误 %0d", chk, err);
    if (err == 0) $display(" *** CFG_CMD_RX ALL PHASES PASSED ***");
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
    $display("================================================================");
    $finish;
  end

  // 全局看门狗：卡死时打 [FAIL]，并指出卡在哪个相位
  initial begin
    #40_000_000;
    $display("[FAIL] timeout in phase %0s", phase_name);
    $finish;
  end

endmodule
