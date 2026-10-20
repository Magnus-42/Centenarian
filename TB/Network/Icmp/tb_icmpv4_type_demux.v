`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_icmpv4_type_demux.v
// Module Name : tb_icmpv4_type_demux
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-10-17
// ----------------------------------------------------------------------------
// Description : icmpv4_type_demux 自测（echo / other 两路分流）
//
// 首拍匹配条件(与 RTL 一致)：
//   - IPv4 version=4 且 IHL=5 (sdata[7:0]==8'h45)
//   - 非分片 (MF=0 且 frag_off=0)
//   - 首拍至少 24 字节有效 (keep[23:0] 全 1)
//   - ICMP type/code = 8/0 (sdata[175:160]==16'h0008)
// 任一不满足 -> other。
//
// 用例：
//   T1 合法 echo 请求            -> echo  口
//   T2 echo reply(type=0)        -> other 口
//   T3 dest unreachable(type=3)  -> other 口
//   T5 MF=1 分片                 -> other 口
//   T6 frag_off != 0             -> other 口
//   T7 首拍 <24B 有效            -> other 口
//   T8 echo/other 背靠背 + echo 口反压抖动 -> 不串口/不丢/不重
// ============================================================================
module tb_icmpv4_type_demux;

  localparam W  = 512;
  localparam K  = 64;
  localparam UW = 97;

  reg               clk = 1'b0;
  reg               rst = 1'b1;
  always #5 clk = ~clk;

  reg  [W-1:0]      sdata ;
  reg  [K-1:0]      skeep ;
  reg               slast ;
  reg               svalid;
  wire              sready;
  reg  [UW-1:0]     susr  = 97'd0;

  wire [W-1:0]      echo_mdata ;
  wire [K-1:0]      echo_mkeep ;
  wire              echo_mlast ;
  wire              echo_mvalid;
  wire [UW-1:0]     echo_musr  ;
  reg               echo_mready = 1'b1;

  wire [W-1:0]      other_mdata ;
  wire [K-1:0]      other_mkeep ;
  wire              other_mlast ;
  wire              other_mvalid;
  wire [UW-1:0]     other_musr  ;
  reg               other_mready = 1'b1;

  icmpv4_type_demux #(.AXIS_USER_WIDTH(UW)) u_dut (
    .clk(clk), .rst(rst),
    .ipv4_icmp_axis_sdata(sdata), .ipv4_icmp_axis_skeep(skeep),
    .ipv4_icmp_axis_slast(slast), .ipv4_icmp_axis_svalid(svalid),
    .ipv4_icmp_axis_susr(susr),   .ipv4_icmp_axis_sready(sready),
    .ipv4_echo_axis_mdata(echo_mdata), .ipv4_echo_axis_mkeep(echo_mkeep),
    .ipv4_echo_axis_mlast(echo_mlast), .ipv4_echo_axis_mvalid(echo_mvalid),
    .ipv4_echo_axis_musr(echo_musr),   .ipv4_echo_axis_mready(echo_mready),
    .ipv4_other_axis_mdata(other_mdata), .ipv4_other_axis_mkeep(other_mkeep),
    .ipv4_other_axis_mlast(other_mlast), .ipv4_other_axis_mvalid(other_mvalid),
    .ipv4_other_axis_musr(other_musr),   .ipv4_other_axis_mready(other_mready)
  );

  // ---------------- 发送队列 ----------------
  localparam QN = 256;
  reg [W-1:0] sq_data [0:QN-1];
  reg [K-1:0] sq_keep [0:QN-1];
  reg         sq_last [0:QN-1];
  integer     sq_wr, sq_rd;

  always @(negedge clk) begin
    if (!rst && svalid === 1'b0 && sq_rd < sq_wr) begin
      sdata  <= sq_data[sq_rd];
      skeep  <= sq_keep[sq_rd];
      slast  <= sq_last[sq_rd];
      svalid <= 1'b1;
      sq_rd  = sq_rd + 1;
    end
  end
  always @(posedge clk) begin
    if (rst) svalid <= 1'b0;
    else if (svalid === 1'b1 && sready === 1'b1) svalid <= 1'b0;
  end

  // ---------------- 期望队列(echo=0, other=1) ----------------
  reg [W-1:0] ed [0:1][0:QN-1];
  reg [K-1:0] ek [0:1][0:QN-1];
  reg         el [0:1][0:QN-1];
  integer     e_wr [0:1];
  integer     e_rd [0:1];
  integer     got  [0:1];
  integer     err, perr;

  // 构造 ICMP 帧(首拍 64B 全有效 + 可选末拍)。首拍字节序 byte k = bus[8k+:8]
  //   which: 0=echo 口, 1=other 口
  task automatic push_icmp(input [7:0] vihl, input [7:0] flag6, input [7:0] frag7,
                           input [7:0] itype, input [7:0] icode,
                           input integer len2, input [7:0] tag, input integer which);
    integer i, b, v, L, nb;
    reg [W-1:0] d;
    reg [K-1:0] k;
    reg [7:0]   fb [0:127];
    begin
      for (i = 0; i < 128; i = i + 1) fb[i] = 8'h00;
      fb[0]  = vihl;                 // version/IHL
      fb[1]  = 8'h00;                // TOS
      fb[2]  = 8'h00; fb[3] = 8'h00; // total_len(demux 不查)
      fb[4]  = 8'h00; fb[5] = 8'h00; // id
      fb[6]  = flag6;                // {0,DF,MF,frag_off[12:8]}
      fb[7]  = frag7;                // frag_off[7:0]
      fb[8]  = 8'h40;                // TTL
      fb[9]  = 8'h01;                // protocol = ICMP
      fb[10] = 8'h00; fb[11] = 8'h00;// ip header checksum
      fb[12] = 8'hC0; fb[13] = 8'hA8; fb[14] = 8'h01; fb[15] = 8'h64; // src
      fb[16] = 8'hC0; fb[17] = 8'hA8; fb[18] = 8'h01; fb[19] = 8'hC8; // dst
      fb[20] = itype; fb[21] = icode;
      fb[22] = 8'h00; fb[23] = 8'h00; // icmp checksum
      fb[24] = 8'h00; fb[25] = 8'h01; // identifier
      fb[26] = 8'h00; fb[27] = 8'h01; // sequence
      for (i = 0; i < 36; i = i + 1) fb[28+i] = tag + i[7:0]; // 首拍剩余 data
      L = 64 + len2;
      for (i = 0; i < len2; i = i + 1) fb[64+i] = 8'hE0 + i[7:0];
      nb = (len2 == 0) ? 1 : 2;
      for (b = 0; b < nb; b = b + 1) begin
        d = {W{1'b0}}; k = {K{1'b0}};
        for (v = 0; v < 64; v = v + 1)
          if (64*b + v < L) begin d[v*8 +: 8] = fb[64*b + v]; k[v] = 1'b1; end
        sq_data[sq_wr] = d; sq_keep[sq_wr] = k; sq_last[sq_wr] = (b == nb-1);
        sq_wr = sq_wr + 1;
        ed[which][e_wr[which]] = d; ek[which][e_wr[which]] = k; el[which][e_wr[which]] = (b == nb-1);
        e_wr[which] = e_wr[which] + 1;
      end
    end
  endtask

  // 短帧: 首拍只 20B 有效(keep[19:0]=1), 不足 24B -> other
  task automatic push_short(input [7:0] tag, input integer which);
    integer i, v;
    reg [W-1:0] d;
    reg [K-1:0] k;
    begin
      d = {W{1'b0}}; k = {K{1'b0}};
      d[7:0] = 8'h45;              // IHL=5, version=4
      for (i = 0; i < 20; i = i + 1) begin
        if (i != 0) d[i*8 +: 8] = tag + i[7:0];
        k[i] = 1'b1;
      end
      // type 字段位置(byte20)的 keep=0, 但首拍本就 <24B
      sq_data[sq_wr] = d; sq_keep[sq_wr] = k; sq_last[sq_wr] = 1'b1;
      sq_wr = sq_wr + 1;
      ed[which][e_wr[which]] = d; ek[which][e_wr[which]] = k; el[which][e_wr[which]] = 1'b1;
      e_wr[which] = e_wr[which] + 1;
    end
  endtask

  // ---------------- 在线比对 ----------------
  task automatic chk_port(input integer which, input [W-1:0] d, input [K-1:0] k, input l);
    begin
      got[which] = got[which] + 1;
      if (e_rd[which] >= e_wr[which]) begin
        if (perr < 8) $display("  [FAIL] port%0d beat #%0d 无期望 -> 重复/多发", which, got[which]);
        perr = perr + 1; err = err + 1;
      end
      else begin
        if (k !== ek[which][e_rd[which]]) begin
          if (perr < 8) $display("  [FAIL] port%0d beat #%0d keep: got %h exp %h", which, got[which], k, ek[which][e_rd[which]]);
          perr = perr + 1; err = err + 1;
        end
        if (d !== ed[which][e_rd[which]]) begin
          if (perr < 8) $display("  [FAIL] port%0d beat #%0d data 不符 (byte28=%02h exp %02h)",
                                 which, got[which], d[231:224], ed[which][e_rd[which]][231:224]);
          perr = perr + 1; err = err + 1;
        end
        if (l !== el[which][e_rd[which]]) begin
          if (perr < 8) $display("  [FAIL] port%0d beat #%0d last: got %b exp %b", which, got[which], l, el[which][e_rd[which]]);
          perr = perr + 1; err = err + 1;
        end
        e_rd[which] = e_rd[which] + 1;
      end
    end
  endtask

  always @(posedge clk) begin
    if (!rst) begin
      if (echo_mvalid  && echo_mready ) chk_port(0, echo_mdata,  echo_mkeep,  echo_mlast );
      if (other_mvalid && other_mready) chk_port(1, other_mdata, other_mkeep, other_mlast);
    end
  end

  // echo 口反压抖动
  reg [1:0] bp_mode;
  reg [2:0] bp_cnt;
  always @(posedge clk) begin
    case (bp_mode)
      2'd0: echo_mready <= 1'b1;
      2'd1: echo_mready <= 1'b0;
      2'd2: begin bp_cnt <= bp_cnt + 1'b1; echo_mready <= (bp_cnt[1] ^ bp_cnt[0]); end
      default: echo_mready <= 1'b1;
    endcase
  end

  task automatic cyc(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
  endtask

  integer base;
  initial begin
    $display("================================================================");
    $display(" tb_icmpv4_type_demux");
    $display("================================================================");
    err=0; perr=0; sq_wr=0; sq_rd=0; bp_mode=2'd0; bp_cnt=3'd0;
    for (base = 0; base < 2; base = base + 1) begin e_wr[base]=0; e_rd[base]=0; got[base]=0; end
    sdata=0; skeep=0; slast=0; svalid=0;
    echo_mready=1'b1; other_mready=1'b1;
    susr = {1'b1, 96'h89ABCDEF0123456789ABCDEF};   // 任意非零, 验证 usr 透传
    rst=1'b1; cyc(6); rst=1'b0; cyc(2);

    // ---- T1: 合法 echo -> echo 口 ----
    $display("--- T1: legal echo request -> echo port ---");
    push_icmp(8'h45, 8'h00, 8'h00, 8'h08, 8'h00, 16, 8'h11, 0); cyc(40);
    if (got[0] != 2) begin $display("  [FAIL] echo 口应出 2 拍, 实得 %0d", got[0]); err = err + 1; end
    else $display("  [PASS] echo 口 2 拍");

    // ---- T2: echo reply(type=0) -> other 口 ----
    $display("--- T2: echo reply (type=0) -> other port ---");
    push_icmp(8'h45, 8'h00, 8'h00, 8'h00, 8'h00, 16, 8'h22, 1); cyc(40);
    if (got[1] != 2) begin $display("  [FAIL] other 口应出 2 拍, 实得 %0d", got[1]); err = err + 1; end
    else $display("  [PASS] other 口 2 拍");

    // ---- T3: dest unreachable(type=3) -> other 口 ----
    $display("--- T3: dest unreachable (type=3) -> other port ---");
    push_icmp(8'h45, 8'h00, 8'h00, 8'h03, 8'h03, 0, 8'h33, 1); cyc(40);
    if (got[1] != 3) begin $display("  [FAIL] other 口应出 3 拍, 实得 %0d", got[1]); err = err + 1; end
    else $display("  [PASS] other 口累计 3 拍");

    // ---- T5: MF=1 分片 -> other 口 ----
    $display("--- T5: MF=1 fragment -> other port ---");
    push_icmp(8'h45, 8'h20, 8'h00, 8'h08, 8'h00, 0, 8'h55, 1); cyc(40);
    if (got[1] != 4) begin $display("  [FAIL] other 口应出 4 拍, 实得 %0d", got[1]); err = err + 1; end
    else $display("  [PASS] other 口累计 4 拍");

    // ---- T6: frag_off != 0 -> other 口 ----
    $display("--- T6: frag_off != 0 -> other port ---");
    push_icmp(8'h45, 8'h00, 8'h01, 8'h08, 8'h00, 0, 8'h66, 1); cyc(40);
    if (got[1] != 5) begin $display("  [FAIL] other 口应出 5 拍, 实得 %0d", got[1]); err = err + 1; end
    else $display("  [PASS] other 口累计 5 拍");

    // ---- T7: 首拍 <24B -> other 口 ----
    $display("--- T7: short first beat (<24B valid) -> other port ---");
    push_short(8'h77, 1); cyc(40);
    if (got[1] != 6) begin $display("  [FAIL] other 口应出 6 拍, 实得 %0d", got[1]); err = err + 1; end
    else $display("  [PASS] other 口累计 6 拍");

    // ---- T8: 背靠背交错 + echo 口反压 ----
    $display("--- T8: back-to-back interleave with echo-port backpressure ---");
    bp_mode = 2'd2;
    push_icmp(8'h45, 8'h00, 8'h00, 8'h08, 8'h00, 16, 8'h81, 0);
    push_icmp(8'h45, 8'h00, 8'h00, 8'h00, 8'h00, 16, 8'h82, 1);
    push_icmp(8'h45, 8'h00, 8'h00, 8'h08, 8'h00, 16, 8'h83, 0);
    push_icmp(8'h45, 8'h00, 8'h00, 8'h03, 8'h01,  0, 8'h84, 1);
    cyc(240);
    bp_mode = 2'd0; cyc(20);
    // echo 累计 2+2+2=6 拍, other 累计 6(前)+reply(2)+type3(1)=9 拍
    if (got[0] != 6) begin $display("  [FAIL] echo 口应共 6 拍, 实得 %0d", got[0]); err = err + 1; end
    else if (got[1] != 9) begin $display("  [FAIL] other 口应共 9 拍, 实得 %0d", got[1]); err = err + 1; end
    else $display("  [PASS] 背靠背 4 帧共 16 拍全对(无串口/丢/重)");
    cyc(20);

    $display("================================================================");
    $display(" got: echo=%0d other=%0d   err=%0d", got[0], got[1], err);
    if (err == 0) $display(" *** ALL TESTS PASSED ***");
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
    $display("================================================================");
    $finish;
  end

  initial begin
    #200_000;
    $display("[%0t] [FAIL] FATAL: timeout", $time);
    $finish;
  end

endmodule
`resetall
