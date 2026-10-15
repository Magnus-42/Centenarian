`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_eth_type_demux.v
// Module Name : tb_eth_type_demux
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-09-19
// ----------------------------------------------------------------------------
// Description : eth_type_demux 自测（按工程既有字节序约定构造帧）
//   约定(与 eth_100g_tester 一致): 帧 byte k = bus[8k+7:8k]; 16bit 字段常量按
//   "低位=线上首字节"写 => ethertype 0x0800 应写 16'h0008, 0x0806 写 16'h0608
//   帧构造: byte0..5=目的MAC, 6..11=源MAC, 12..13=ethertype, 14..=载荷
//   用例:
//     T1 IPv4 帧  -> 必须从 ipv4 口出
//     T2 ARP  帧  -> 必须从 arp  口出
//     T3 未知类型 -> 必须从 other 口出
//     T4 IPv4/ARP 背靠背 + ipv4 口反压抖动 -> 不得重复/丢失/串口
//   (三个 m 口各自独立 mready; 每个口一个期望队列 + 在线比对)
// ============================================================================

module tb_eth_type_demux;

  localparam W = 512;
  localparam K = 64;

  reg               clk = 1'b0;
  reg               rst = 1'b1;
  always #5 clk = ~clk;

  reg  [W-1:0]      eth_axis_sdata ;
  reg  [K-1:0]      eth_axis_skeep ;
  reg               eth_axis_slast ;
  reg               eth_axis_svalid;
  wire              eth_axis_sready;

  // ---- demux 输出(packed 矢量, 3 路: 0=ipv4 1=arp 2=other) ----
  wire [W*3-1:0]    dem_mdata ;
  wire [K*3-1:0]    dem_mkeep ;
  wire [2:0]        dem_mlast ;
  wire [2:0]        dem_mvalid;
  wire [2:0]        dem_musr  ;
  wire [2:0]        dem_mready;

  // 三路视图(沿用原端口名, 后续比对逻辑零改动)
  wire [W-1:0]      ipv4_axis_mdata  = dem_mdata[0*W +: W];
  wire [K-1:0]      ipv4_axis_mkeep  = dem_mkeep[0*K +: K];
  wire              ipv4_axis_mlast  = dem_mlast[0];
  wire              ipv4_axis_mvalid = dem_mvalid[0];

  wire [W-1:0]      arp_axis_mdata   = dem_mdata[1*W +: W];
  wire [K-1:0]      arp_axis_mkeep   = dem_mkeep[1*K +: K];
  wire              arp_axis_mlast   = dem_mlast[1];
  wire              arp_axis_mvalid  = dem_mvalid[1];

  wire [W-1:0]      other_axis_mdata  = dem_mdata[2*W +: W];
  wire [K-1:0]      other_axis_mkeep  = dem_mkeep[2*K +: K];
  wire              other_axis_mlast  = dem_mlast[2];
  wire              other_axis_mvalid = dem_mvalid[2];

  // ---- 三路 ready 视图(TB 驱动 -> 打包给 demux 的 mready) ----
  reg               ipv4_axis_mready  = 1'b1;
  wire              arp_axis_mready   = 1'b1;   // arp 口恒 ready
  wire              other_axis_mready = 1'b1;   // other 口恒 ready
  assign dem_mready = {other_axis_mready, arp_axis_mready, ipv4_axis_mready};

  eth_type_demux #(
    // 档序(线上字节 LSB=slot0): slot0=0x0800(ipv4) slot1=0x0806(arp), slot2=other 兜底
    .TYPE_NUM        (2                  ),
    .TYPE_DICT       ({16'h0608,16'h0008})
  ) u_dut (
    .clk              (clk              ),
    .rst              (rst              ),
    .eth_axis_sdata   (eth_axis_sdata   ),
    .eth_axis_skeep   (eth_axis_skeep   ),
    .eth_axis_slast   (eth_axis_slast   ),
    .eth_axis_svalid  (eth_axis_svalid  ),
    .eth_axis_susr    (1'b0             ),
    .eth_axis_sready  (eth_axis_sready  ),
    .eth_axis_mdata   (dem_mdata        ),
    .eth_axis_mkeep   (dem_mkeep        ),
    .eth_axis_mlast   (dem_mlast        ),
    .eth_axis_mvalid  (dem_mvalid       ),
    .eth_axis_musr    (dem_musr         ),
    .eth_axis_mready  (dem_mready       )
  );

  // ---------------- 发送队列 ----------------
  localparam QN = 128;
  reg [W-1:0] sq_data [0:QN-1];
  reg [K-1:0] sq_keep [0:QN-1];
  reg         sq_last [0:QN-1];
  integer     sq_wr, sq_rd;

  always @(negedge clk) begin
    if (!rst && eth_axis_svalid === 1'b0 && sq_rd < sq_wr) begin
      eth_axis_sdata  <= sq_data[sq_rd];
      eth_axis_skeep  <= sq_keep[sq_rd];
      eth_axis_slast  <= sq_last[sq_rd];
      eth_axis_svalid <= 1'b1;
      sq_rd = sq_rd + 1;
    end
  end
  always @(posedge clk) begin
    if (rst) eth_axis_svalid <= 1'b0;
    else if (eth_axis_svalid === 1'b1 && eth_axis_sready === 1'b1) eth_axis_svalid <= 1'b0;
  end

  // ---------------- 每口一个期望队列 ----------------
  reg [W-1:0] ed [0:2][0:QN-1];
  reg [K-1:0] ek [0:2][0:QN-1];
  reg         el [0:2][0:QN-1];
  integer     e_wr [0:2];
  integer     e_rd [0:2];
  integer     got   [0:2];
  integer     err, perr;

  localparam [47:0] DST_MAC = 48'h0605_0403_0201;   // 线上 01 02 03 04 05 06
  localparam [47:0] SRC_MAC = 48'h0c0b_0a09_0807;   // 线上 07 08 09 0a 0b 0c
  localparam [15:0] ETYPE_IPV4 = 16'h0008;          // 线上 08 00  (线序写法)
  localparam [15:0] ETYPE_ARP  = 16'h0608;          // 线上 08 06
  localparam [15:0] ETYPE_OTHR = 16'h3412;          // 线上 12 34

  // 造一个 2 拍帧: 首拍 64 字节全有效, 次拍 len2 字节; tag 放载荷里
  task automatic push_frame(input [15:0] etype, input [7:0] tag, input integer len2, input integer which);
    integer i, b, v;
    reg [W-1:0] d;
    reg [K-1:0] k;
    reg [7:0]   fb [0:127];
    integer     L;
    begin
      for (i = 0; i < 128; i = i + 1) fb[i] = 8'h00;
      for (i = 0; i < 6; i = i + 1)  fb[i]   = DST_MAC[8*i +: 8];
      for (i = 0; i < 6; i = i + 1)  fb[6+i] = SRC_MAC[8*i +: 8];
      fb[12] = etype[7:0];  fb[13] = etype[15:8];
      for (i = 0; i < 50; i = i + 1) fb[14+i] = tag + i[7:0];
      L = 64 + len2;
      for (i = 0; i < len2; i = i + 1) fb[64+i] = 8'hE0 + i[7:0];

      for (b = 0; b < 2; b = b + 1) begin
        d = {W{1'b0}}; k = {K{1'b0}};
        for (v = 0; v < 64; v = v + 1)
          if (64*b + v < L) begin d[v*8 +: 8] = fb[64*b + v]; k[v] = 1'b1; end
        sq_data[sq_wr] = d; sq_keep[sq_wr] = k; sq_last[sq_wr] = (b == 1);
        sq_wr = sq_wr + 1;
        ed[which][e_wr[which]] = d; ek[which][e_wr[which]] = k; el[which][e_wr[which]] = (b == 1);
        e_wr[which] = e_wr[which] + 1;
      end
    end
  endtask

  // ---------------- 在线比对(三个口分别比) ----------------
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
          if (perr < 8) $display("  [FAIL] port%0d beat #%0d data 不符 (tag=%02h exp %02h)",
                                 which, got[which], d[119:112], ed[which][e_rd[which]][119:112]);
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
      if (ipv4_axis_mvalid  && ipv4_axis_mready ) $display("    [OUT] t=%0t port0 tag=%02h keep=%h last=%b exp_rd=%0d exp_wr=%0d", $time, ipv4_axis_mdata[119:112], ipv4_axis_mkeep, ipv4_axis_mlast, e_rd[0], e_wr[0]);
      if (arp_axis_mvalid   && arp_axis_mready  ) $display("    [OUT] t=%0t port1 tag=%02h keep=%h last=%b exp_rd=%0d exp_wr=%0d", $time, arp_axis_mdata[119:112], arp_axis_mkeep, arp_axis_mlast, e_rd[1], e_wr[1]);
      if (other_axis_mvalid && other_axis_mready) $display("    [OUT] t=%0t port2 tag=%02h keep=%h last=%b exp_rd=%0d exp_wr=%0d", $time, other_axis_mdata[119:112], other_axis_mkeep, other_axis_mlast, e_rd[2], e_wr[2]);
      if (ipv4_axis_mvalid  && ipv4_axis_mready ) chk_port(0, ipv4_axis_mdata,  ipv4_axis_mkeep,  ipv4_axis_mlast );
      if (arp_axis_mvalid   && arp_axis_mready  ) chk_port(1, arp_axis_mdata,   arp_axis_mkeep,   arp_axis_mlast  );
      if (other_axis_mvalid && other_axis_mready) chk_port(2, other_axis_mdata, other_axis_mkeep, other_axis_mlast);
    end
  end

  // ipv4 口反压抖动(negedge 改)
  reg [1:0] bp_mode;      // 0=恒 ready 1=恒停 2=图案
  reg [2:0] bp_cnt;
  always @(posedge clk) begin
    case (bp_mode)
      2'd0: ipv4_axis_mready <= 1'b1;
      2'd1: ipv4_axis_mready <= 1'b0;
      2'd2: begin bp_cnt <= bp_cnt + 1'b1; ipv4_axis_mready <= (bp_cnt[1] ^ bp_cnt[0]); end
      default: ipv4_axis_mready <= 1'b1;
    endcase
  end

  task automatic cyc(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
  endtask

  integer base;
  initial begin
    $display("================================================================");
    $display(" tb_eth_type_demux");
    $display("================================================================");
    err=0; perr=0; sq_wr=0; sq_rd=0; bp_mode=2'd0; bp_cnt=3'd0;
    for (base = 0; base < 3; base = base + 1) begin e_wr[base]=0; e_rd[base]=0; got[base]=0; end
    eth_axis_sdata=0; eth_axis_skeep=0; eth_axis_slast=0; eth_axis_svalid=0;
    ipv4_axis_mready=1'b1;
    rst=1'b1; cyc(6); rst=1'b0; cyc(2);

    // ---- T1: IPv4 帧 -> ipv4 口 ----
    $display("--- T1: IPv4 frame -> ipv4 port ---");
    push_frame(ETYPE_IPV4, 8'h11, 16, 0); cyc(40);
    if (got[0] != 2) begin $display("  [FAIL] ipv4 口应出 2 拍, 实得 %0d", got[0]); err = err + 1; end
    else $display("  [PASS] ipv4 口 2 拍");
    cyc(10);

    // ---- T2: ARP 帧 -> arp 口 ----
    $display("--- T2: ARP frame -> arp port ---");
    push_frame(ETYPE_ARP, 8'h22, 24, 1); cyc(40);
    if (got[1] != 2) begin $display("  [FAIL] arp 口应出 2 拍, 实得 %0d", got[1]); err = err + 1; end
    else $display("  [PASS] arp 口 2 拍");
    cyc(10);

    // ---- T3: 未知类型 -> other 口 ----
    $display("--- T3: unknown ethertype -> other port ---");
    push_frame(ETYPE_OTHR, 8'h33, 8, 2); cyc(40);
    if (got[2] != 2) begin $display("  [FAIL] other 口应出 2 拍, 实得 %0d", got[2]); err = err + 1; end
    else $display("  [PASS] other 口 2 拍");
    cyc(10);

    // ---- T4: IPv4/ARP 背靠背 + ipv4 口反压抖动(压类型对齐) ----
    $display("--- T4: back-to-back IPv4/ARP with ipv4-port backpressure ---");
    bp_mode = 2'd2;
    push_frame(ETYPE_IPV4, 8'h41, 16, 0);
    push_frame(ETYPE_ARP , 8'h42, 16, 1);
    push_frame(ETYPE_IPV4, 8'h43, 16, 0);
    cyc(200);
    bp_mode = 2'd0; cyc(20);
    if (got[0] != 6) begin $display("  [FAIL] ipv4 口应共 6 拍, 实得 %0d", got[0]); err = err + 1; end
    else if (got[1] != 4) begin $display("  [FAIL] arp 口应共 4 拍, 实得 %0d", got[1]); err = err + 1; end
    else $display("  [PASS] 6 帧共 12 拍全对(无重复/无丢失/无串口)");
    cyc(20);

    $display("================================================================");
    $display(" got: ipv4=%0d arp=%0d other=%0d   err=%0d", got[0], got[1], got[2], err);
    if (err == 0) $display(" *** ALL TESTS PASSED ***");
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
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
