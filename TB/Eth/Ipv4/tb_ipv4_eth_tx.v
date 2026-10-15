`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_ipv4_eth_tx.v
// Module Name : tb_ipv4_eth_tx
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-10-15
// ----------------------------------------------------------------------------
// Description : ipv4_eth_tx 合并回归（单 module, 顺序 phase）
//
//   合并自 3 个原测试台:
//     1) TB/Eth/Ipv4/tb_ipv4_eth_tx.v     —— 主功能(行为 ARP stub)
//     2) TB/Eth/Ipv4/tb_ip_dstip_check.v  —— 目的 IP 字段回归防护
//     3) TB/Eth/Arp/tb_arp_e2e.v          —— 真实 arp_engine_top 端到端
//
//   DUT 结构:
//     u_st       : ipv4_eth_tx + 行为 ARP 模型(每问必答, 第 6 拍返回)
//                  —— 服务于 P1(主功能) 与 P2(dstip 回归), 共用一个 DUT
//     u_e2e_tx   : ipv4_eth_tx (真实 arp_engine_top 联测)
//     u_e2e_arp  : arp_engine_top(真实)
//
//   Phase:
//     P1  ipv4_eth_tx 主功能  T1 短包命中 / T2 长包命中 / T3 未命中丢弃 / T4 反压
//     P2  dstip 回归防护      ARP 结论不得覆盖 IPv4 头目的 IP 字段("未复现"=通过)
//     P3  e2e 端到端          E1~E6 首次未命中/学习转发/跨网段网关/广播直发
//
//   字节序(工程约定): 字段低位 = 线上首字节; 0x0800 -> 16'h0008
// ============================================================================

module tb_ipv4_eth_tx;

  localparam W = 512;
  localparam K = 64;
  localparam QN = 512;

  // ---------------- 时钟与复位 ----------------
  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg st_rst  = 1'b1;   // 共享 DUT (P1/P2) 复位
  reg e2e_rst = 1'b1;   // e2e DUT (P3) 复位

  // ---------------- 常量 ----------------
  localparam [47:0] ST_LOCAL_MAC = 48'h0302_0100_0504;   // 共享 DUT 源 MAC(线序: 线上 04 05 00 01 02 03)
  localparam [31:0] ST_MISS_IP   = 32'h6300_000A;        // 线序: 人类 10.0.0.99 必 miss

  localparam [31:0] DST_SRC_IP   = 32'h0A01_A8C0;        // dstip_check: 192.168.1.10
  localparam [31:0] DST_REAL_DST = 32'h0808_0808;        // dstip_check: 8.8.8.8(IPv4 头真实目的 IP)

  localparam [31:0] E2E_LOCAL_IP  = 32'h0A01_A8C0;       // 192.168.1.10
  localparam [31:0] E2E_GW_IP     = 32'h0101_A8C0;       // 192.168.1.1
  localparam [31:0] E2E_MASK24    = 32'h00FF_FFFF;       // 255.255.255.0
  localparam [47:0] E2E_LOCAL_MAC = 48'h0102_0304_0501;
  localparam [31:0] E2E_PEER_IP   = 32'h3201_A8C0;       // 192.168.1.50
  localparam [47:0] E2E_PEER_MAC  = 48'hAABB_CCDD_EE01;
  localparam [31:0] E2E_EXT_IP    = 32'h0808_0808;       // 8.8.8.8
  localparam [47:0] E2E_GW_MAC    = 48'hAABB_CCDD_EE02;
  localparam [31:0] E2E_BC_IP     = 32'hFF01_A8C0;       // 192.168.1.255 本网段广播
  localparam [31:0] E2E_ALL_BC    = 32'hFFFF_FFFF;       // 255.255.255.255 全局广播

  // ==========================================================================
  // 共享 DUT: u_st (行为 ARP 模型) —— P1 主功能 + P2 dstip 回归
  // ==========================================================================
  reg  [W-1:0] st_sdata;
  reg  [K-1:0] st_skeep;
  reg          st_slast;
  reg          st_svalid;
  wire         st_sready;
  wire [31:0]  st_q_src;
  wire [31:0]  st_q_dst;
  wire         st_q_valid;
  reg  [47:0]  st_arp_mac;
  reg          st_arp_miss;
  reg          st_arp_valid;
  wire [W-1:0] st_mdata;
  wire [K-1:0] st_mkeep;
  wire         st_mlast;
  wire         st_mvalid;
  reg          st_mready;

  ipv4_eth_tx u_st (
    .clk               (clk         ),
    .rst               (st_rst      ),
    .ipv4_axis_sdata   (st_sdata    ),
    .ipv4_axis_skeep   (st_skeep    ),
    .ipv4_axis_slast   (st_slast    ),
    .ipv4_axis_svalid  (st_svalid   ),
    .ipv4_axis_susr    (4'd0        ),
    .ipv4_axis_sready  (st_sready   ),
    .query_dst_ip      (st_q_dst    ),
    .query_src_ip      (st_q_src    ),
    .query_valid_pulse (st_q_valid  ),
    .arp_dst_mac       (st_arp_mac  ),
    .arp_src_mac       (ST_LOCAL_MAC),
    .arp_miss          (st_arp_miss ),
    .arp_valid         (st_arp_valid),
    .eth_axis_mdata    (st_mdata    ),
    .eth_axis_mkeep    (st_mkeep    ),
    .eth_axis_mlast    (st_mlast    ),
    .eth_axis_mvalid   (st_mvalid   ),
    .eth_axis_musr     (            ),
    .eth_axis_mready   (st_mready   )
  );

  // ---------------- ARP 引擎模型: 每问必答, 固定第 6 拍 ----------------
  function [47:0] mac_of; input [31:0] ip; begin mac_of = {16'hA5A5, ip}; end endfunction

  reg        q1,q2,q3,q4,q5,q6;
  reg [31:0] qi1,qi2,qi3,qi4,qi5,qi6;
  always @(posedge clk or posedge st_rst) begin
    if (st_rst) begin
      q1<=1'b0;q2<=1'b0;q3<=1'b0;q4<=1'b0;q5<=1'b0;q6<=1'b0;
      qi1<=32'd0;qi2<=32'd0;qi3<=32'd0;qi4<=32'd0;qi5<=32'd0;qi6<=32'd0;
      st_arp_valid<=1'b0; st_arp_miss<=1'b0; st_arp_mac<=48'd0;
    end else begin
      q1<=st_q_valid; qi1<=st_q_dst;
      q2<=q1; qi2<=qi1;  q3<=q2; qi3<=qi2;  q4<=q3; qi4<=qi3;
      q5<=q4; qi5<=qi4;  q6<=q5; qi6<=qi5;
      st_arp_valid <= q6;
      st_arp_miss  <= (qi6 == ST_MISS_IP);
      st_arp_mac   <= (qi6 == ST_MISS_IP) ? 48'd0 : mac_of(qi6);
    end
  end

  // ---------------- 发送队列 ----------------
  reg [W-1:0] sq_data [0:QN-1];
  reg [K-1:0] sq_keep [0:QN-1];
  reg         sq_last [0:QN-1];
  integer     sq_wr, sq_rd;

  always @(negedge clk) begin
    if (!st_rst && st_svalid === 1'b0 && sq_rd < sq_wr) begin
      st_sdata  <= sq_data[sq_rd];
      st_skeep  <= sq_keep[sq_rd];
      st_slast  <= sq_last[sq_rd];
      st_svalid <= 1'b1;
      sq_rd = sq_rd + 1;
    end
  end
  always @(posedge clk) begin
    if (st_rst) st_svalid <= 1'b0;
    else if (st_svalid === 1'b1 && st_sready === 1'b1) st_svalid <= 1'b0;
  end

  // ---------------- 期望队列 + 逐字节掩码 ----------------
  reg [W-1:0] e_data [0:QN-1];
  reg [K-1:0] e_keep [0:QN-1];
  reg         e_last [0:QN-1];
  integer     e_wr, e_rd;

  wire [W-1:0] exp_mask;
  genvar gk;
  generate for (gk = 0; gk < 64; gk = gk + 1)
    assign exp_mask[gk*8 +: 8] = {8{e_keep[e_rd][gk]}};
  endgenerate

  reg [7:0]   ipb [0:255];
  integer     ipn;

  task automatic push_frame_beats(input [31:0] dip);
    integer L, Lp, nb, b, f, v;
    reg [W-1:0] d;
    reg [K-1:0] k;
    reg [47:0]  emac;
    begin
      emac = mac_of(dip);
      // 注: ipv4_eth_tx (arp_service + mac_add) 不做最小帧长补齐, 补齐由下游 eth_frame_pad60 负责。
      //     因此期望帧长 = 14 + IPv4 包长, 不取整到 60。
      L  = 14 + ipn;
      Lp = L;
      nb = (Lp + 63) / 64;
      for (b = 0; b < nb; b = b + 1) begin
        d = {W{1'b0}}; k = {K{1'b0}};
        for (f = 0; f < 64; f = f + 1) begin
          v = 64*b + f;
          if (v < Lp) begin
            k[f] = 1'b1;
            if (v < 6)                     d[f*8 +: 8] = emac[8*v +: 8];            // 目的MAC
            else if (v < 12)               d[f*8 +: 8] = ST_LOCAL_MAC[8*(v-6) +: 8]; // 源MAC
            else if (v == 12)              d[f*8 +: 8] = 8'h08;                     // EtherType 08 00
            else if (v == 13)              d[f*8 +: 8] = 8'h00;
            else                           d[f*8 +: 8] = ipb[v - 14];               // IPv4 包
          end
        end
        e_data[e_wr] = d; e_keep[e_wr] = k; e_last[e_wr] = (b == nb-1);
        e_wr = e_wr + 1;
      end
    end
  endtask

  // 压一个 IPv4 包: nbytes 字节, 目的IP = dip(线序); hit=1 时生成期望
  task automatic push_ip_pkt(input integer nbytes, input [7:0] tag, input [31:0] dip, input hit);
    integer i, nb, b;
    reg [W-1:0] d;
    reg [K-1:0] k;
    begin
      for (i = 0; i < 256; i = i + 1) ipb[i] = 8'h00;
      for (i = 0; i < nbytes; i = i + 1) ipb[i] = tag + i[7:0];
      ipb[16] = dip[ 7: 0]; ipb[17] = dip[15: 8];
      ipb[18] = dip[23:16]; ipb[19] = dip[31:24];
      ipn = nbytes;
      nb = (nbytes + 63) / 64;
      for (b = 0; b < nb; b = b + 1) begin
        d = {W{1'b0}}; k = {K{1'b0}};
        for (i = 0; i < 64; i = i + 1)
          if (64*b + i < nbytes) begin d[i*8 +: 8] = ipb[64*b + i]; k[i] = 1'b1; end
        sq_data[sq_wr] = d; sq_keep[sq_wr] = k; sq_last[sq_wr] = (b == nb-1);
        sq_wr = sq_wr + 1;
      end
      if (hit) push_frame_beats(dip);
    end
  endtask

  // 直接压一拍(供 P2 dstip_check 使用)
  task automatic st_push_beat(input [W-1:0] data, input [K-1:0] keep, input last);
    begin
      sq_data[sq_wr] = data; sq_keep[sq_wr] = keep; sq_last[sq_wr] = last;
      sq_wr = sq_wr + 1;
    end
  endtask

  // ---------------- 在线比对 (仅 P1 使能) ----------------
  integer     err, perr, got_cnt, dbg_k;
  reg [W-1:0] md;
  reg [K-1:0] mk;
  reg         st_cmp_en = 1'b0;

  always @(posedge clk) begin
    if (!st_rst && st_cmp_en && st_mvalid === 1'b1 && st_mready === 1'b1) begin
      got_cnt = got_cnt + 1;
      md = st_mdata; mk = st_mkeep;
      if (e_rd >= e_wr) begin
        if (perr < 6) $display("  [FAIL] beat #%0d 无期望 -> 多发/漏包 t=%0t", got_cnt, $time);
        perr = perr + 1; err = err + 1;
      end
      else begin
        if (mk !== e_keep[e_rd]) begin
          if (perr < 6) $display("  [FAIL] beat #%0d keep: got %h exp %h", got_cnt, mk, e_keep[e_rd]);
          perr = perr + 1; err = err + 1;
        end
        if ((md & exp_mask) !== (e_data[e_rd] & exp_mask)) begin
          if (perr < 3) begin
            $display("  [FAIL] beat #%0d data mismatch", got_cnt);
            for (dbg_k = 0; dbg_k < 64; dbg_k = dbg_k + 1)
              if (e_keep[e_rd][dbg_k] && (md[dbg_k*8 +: 8] !== e_data[e_rd][dbg_k*8 +: 8]))
                $display("      byte[%0d] got %02h exp %02h", dbg_k, md[dbg_k*8 +: 8], e_data[e_rd][dbg_k*8 +: 8]);
          end
          perr = perr + 1; err = err + 1;
        end
        if (st_mlast !== e_last[e_rd]) begin
          if (perr < 6) $display("  [FAIL] beat #%0d last: got %b exp %b", got_cnt, st_mlast, e_last[e_rd]);
          perr = perr + 1; err = err + 1;
        end
        e_rd = e_rd + 1;
      end
    end
  end

  // ---------------- dstip_check 首拍监视 (仅 P2 使能) ----------------
  reg         st_dstip_en  = 1'b0;
  reg         st_got_first = 1'b0;
  reg [31:0]  st_out_dst_field = 0;
  reg [31:0]  st_out_src_field = 0;
  reg [47:0]  st_out_dst_mac   = 0;
  reg [47:0]  st_out_src_mac   = 0;
  reg [15:0]  st_out_ethertype = 0;

  always @(posedge clk) begin
    if (!st_rst && st_dstip_en && st_mvalid && st_mready && !st_got_first) begin
      st_got_first      <= 1'b1;
      st_out_dst_field  <= st_mdata[271:240];    // 输出 byte30..33 = IPv4 头 dst_ip 字段
      st_out_src_field  <= st_mdata[239:208];    // 输出 byte26..29 = IPv4 头 src_ip 字段
      st_out_dst_mac    <= st_mdata[47:0];
      st_out_src_mac    <= st_mdata[95:48];
      st_out_ethertype  <= st_mdata[111:96];
    end
  end

  // ==========================================================================
  // e2e DUT: u_e2e_tx + u_e2e_arp (真实 arp_engine_top) —— P3 端到端
  // ==========================================================================
  reg  [W-1:0] e2e_iv_sdata = 0;
  reg  [63:0]  e2e_iv_skeep = 0;
  reg          e2e_iv_slast = 0, e2e_iv_svalid = 0;
  wire         e2e_iv_sready;
  wire [W-1:0] e2e_ev_mdata;
  wire [63:0]  e2e_ev_mkeep;
  wire         e2e_ev_mlast, e2e_ev_mvalid;
  reg          e2e_ev_mready = 1'b1;

  wire [31:0]  e2e_q_src, e2e_q_dst;
  wire         e2e_q_valid;
  wire [47:0]  e2e_arp_mac, e2e_arp_src_mac;
  wire         e2e_arp_miss, e2e_arp_valid;

  wire [W-1:0] e2e_am_mdata;
  wire [63:0]  e2e_am_mkeep;
  wire         e2e_am_mvalid, e2e_am_mlast;
  reg          e2e_am_mready = 1'b1;
  reg  [W-1:0] e2e_as_sdata = 0;
  reg  [63:0]  e2e_as_skeep = 0;
  reg          e2e_as_svalid = 0, e2e_as_slast = 0;
  wire         e2e_as_sready;

  wire e2e_stat_rx_error, e2e_stat_ack_ovf, e2e_stat_pend_ovf, e2e_stat_no_resp;
  wire e2e_stat_pend_clr, e2e_stat_cache_clr, e2e_stat_src_bad;

  ipv4_eth_tx u_e2e_tx (
    .clk               (clk          ),
    .rst               (e2e_rst      ),
    .ipv4_axis_sdata   (e2e_iv_sdata ),
    .ipv4_axis_skeep   (e2e_iv_skeep ),
    .ipv4_axis_slast   (e2e_iv_slast ),
    .ipv4_axis_svalid  (e2e_iv_svalid),
    .ipv4_axis_susr    (4'd0         ),
    .ipv4_axis_sready  (e2e_iv_sready),
    .query_src_ip      (e2e_q_src    ),
    .query_dst_ip      (e2e_q_dst    ),
    .query_valid_pulse (e2e_q_valid  ),
    .arp_dst_mac       (e2e_arp_mac  ),
    .arp_src_mac       (e2e_arp_src_mac),
    .arp_miss          (e2e_arp_miss ),
    .arp_valid         (e2e_arp_valid),
    .eth_axis_mdata    (e2e_ev_mdata ),
    .eth_axis_mkeep    (e2e_ev_mkeep ),
    .eth_axis_mlast    (e2e_ev_mlast ),
    .eth_axis_mvalid   (e2e_ev_mvalid),
    .eth_axis_musr     (             ),
    .eth_axis_mready   (e2e_ev_mready)
  );

  arp_engine_top #(
    .AXIS_WIDTH   (W),
    .CACHE_DEEP   (8),
    .PENDING_DEEP (8),
    .LOCAL_IP_NUM (1)
  ) u_e2e_arp (
    .clk                              (clk),
    .rst                              (e2e_rst),
    .query_src_ip                     (e2e_q_src),
    .query_dst_ip                     (e2e_q_dst),
    .query_valid_pulse                (e2e_q_valid),
    .arp_dst_mac                      (e2e_arp_mac),
    .arp_src_mac                      (e2e_arp_src_mac),
    .arp_miss                         (e2e_arp_miss),
    .arp_valid                        (e2e_arp_valid),
    .arp_axis_sdata                   (e2e_as_sdata),
    .arp_axis_skeep                   (e2e_as_skeep),
    .arp_axis_svalid                  (e2e_as_svalid),
    .arp_axis_slast                   (e2e_as_slast),
    .arp_axis_susr                    (1'b0),
    .arp_axis_sready                  (e2e_as_sready),
    .arp_axis_mdata                   (e2e_am_mdata),
    .arp_axis_mkeep                   (e2e_am_mkeep),
    .arp_axis_mvalid                  (e2e_am_mvalid),
    .arp_axis_mlast                   (e2e_am_mlast),
    .arp_axis_musr                    (      ),
    .arp_axis_mready                  (e2e_am_mready),
    .cfg_local_ip                     (E2E_LOCAL_IP),
    .cfg_local_mac                    (E2E_LOCAL_MAC),
    .cfg_gateway_ip                   (E2E_GW_IP),
    .cfg_subnet_mask                  (E2E_MASK24),
    .cfg_pending_time                 (57'd16),
    .cfg_clear_cache                  (1'b0),
    .cfg_clear_pending                (1'b0),
    .stat_rx_error                    (e2e_stat_rx_error),
    .stat_ack_fifo_overflow_error     (e2e_stat_ack_ovf),
    .stat_pending_fifo_overflow_error (e2e_stat_pend_ovf),
    .stat_lookup_no_resp_error        (e2e_stat_no_resp),
    .stat_pending_clear_finish        (e2e_stat_pend_clr),
    .stat_cache_clear_finish          (e2e_stat_cache_clr),
    .stat_query_src_not_local         (e2e_stat_src_bad)
  );

  // ---------------- 对端主机模型: 抓 ARP 请求 -> 自动回 ARP 应答 ----------------
  reg        e2e_rsp_pend = 1'b0;
  reg [31:0] e2e_rsp_tpa = 0, e2e_rsp_spa = 0;
  reg [47:0] e2e_rsp_tha = 0, e2e_rsp_sha = 0;

  integer    e2e_req_cnt = 0;
  reg [31:0] e2e_req_tpa = 0;
  reg [31:0] e2e_req_spa = 0;
  reg [47:0] e2e_req_sha = 0;

  always @(posedge clk) begin
    if (e2e_rst) begin
      e2e_rsp_pend <= 1'b0;
      e2e_req_cnt  <= 0;
    end
    else begin
      if (e2e_am_mvalid && e2e_am_mready && e2e_am_mdata[175:160] == 16'h0100 && !e2e_rsp_pend) begin
        e2e_req_spa  <= e2e_am_mdata[255:224];
        e2e_req_tpa  <= e2e_am_mdata[335:304];
        e2e_req_sha  <= e2e_am_mdata[223:176];
        e2e_req_cnt  <= e2e_req_cnt + 1;
        e2e_rsp_spa  <= e2e_am_mdata[335:304];
        e2e_rsp_tpa  <= e2e_am_mdata[255:224];
        e2e_rsp_tha  <= e2e_am_mdata[223:176];
        e2e_rsp_sha  <= (e2e_am_mdata[335:304] == E2E_PEER_IP) ? E2E_PEER_MAC :
                        (e2e_am_mdata[335:304] == E2E_GW_IP  ) ? E2E_GW_MAC   : 48'h0202_0304_0506;
        e2e_rsp_pend <= 1'b1;
      end
    end
  end

  always @(posedge clk) begin
    if (e2e_rst) begin
      e2e_as_svalid <= 1'b0;
      e2e_as_slast  <= 1'b0;
    end
    else begin
      if (e2e_rsp_pend && (!e2e_as_svalid || (e2e_as_svalid && e2e_as_sready))) begin
        e2e_as_sdata  <= {176'd0, e2e_rsp_tpa, e2e_rsp_tha, e2e_rsp_spa, e2e_rsp_sha,
                          16'h0200, 8'h04, 8'h06, 16'h0008, 16'h0100, 16'h0608,
                          e2e_rsp_sha, e2e_rsp_tha};
        e2e_as_skeep  <= 64'h0000_03FF_FFFF_FFFF;
        e2e_as_slast  <= 1'b1;
        e2e_as_svalid <= 1'b1;
        e2e_rsp_pend  <= 1'b0;
      end
      else if (e2e_as_svalid && e2e_as_sready) begin
        e2e_as_svalid <= 1'b0;
        e2e_as_slast  <= 1'b0;
      end
    end
  end

  // ---------------- e2e 输出监视 ----------------
  integer e2e_out_beats = 0;
  integer e2e_out_pkts  = 0;
  reg [47:0] e2e_out_mac0 = 0;
  reg        e2e_in_pkt = 1'b0;

  always @(posedge clk) begin
    if (e2e_rst) begin
      e2e_out_beats <= 0; e2e_out_pkts <= 0; e2e_in_pkt <= 1'b0;
    end
    else if (e2e_ev_mvalid && e2e_ev_mready) begin
      if (!e2e_in_pkt) begin
        e2e_out_mac0 <= e2e_ev_mdata[47:0];
        e2e_in_pkt   <= 1'b1;
      end
      e2e_out_beats <= e2e_out_beats + 1;
      if (e2e_ev_mlast) begin
        e2e_out_pkts <= e2e_out_pkts + 1;
        e2e_in_pkt   <= 1'b0;
      end
    end
  end

  // ---------------- 探针: arp_buf 分支 ----------------
  integer e2e_cnt_first       = 0;
  integer e2e_cnt_first_empty = 0;
  integer e2e_cnt_first_buff  = 0;
  integer e2e_cnt_take_live   = 0;
  integer e2e_cnt_wr          = 0;
  integer e2e_max_occ         = 0;
  integer e2e_occv            = 0;

  always @(posedge clk) begin
    if (!e2e_rst) begin
      if (u_e2e_tx.u_ipv4_arp_service.s10_handshake &&
          u_e2e_tx.u_ipv4_arp_service.is_first_beat_s10) begin
        e2e_cnt_first = e2e_cnt_first + 1;
        if (u_e2e_tx.u_ipv4_arp_service.arp_buf_empty) e2e_cnt_first_empty = e2e_cnt_first_empty + 1;
        else                                            e2e_cnt_first_buff  = e2e_cnt_first_buff  + 1;
      end
      if (u_e2e_tx.u_ipv4_arp_service.arp_buf_take_live) e2e_cnt_take_live = e2e_cnt_take_live + 1;
      if (u_e2e_tx.u_ipv4_arp_service.arp_buf_wr_en)     e2e_cnt_wr        = e2e_cnt_wr        + 1;
      e2e_occv = (u_e2e_tx.u_ipv4_arp_service.arp_buf_wr_ptr >= u_e2e_tx.u_ipv4_arp_service.arp_buf_rd_ptr)
               ? (u_e2e_tx.u_ipv4_arp_service.arp_buf_wr_ptr - u_e2e_tx.u_ipv4_arp_service.arp_buf_rd_ptr)
               : (u_e2e_tx.u_ipv4_arp_service.arp_buf_wr_ptr + 16
                  - u_e2e_tx.u_ipv4_arp_service.arp_buf_rd_ptr);
      if (e2e_occv > e2e_max_occ) e2e_max_occ = e2e_occv;
    end
  end

  // query -> arp_valid 实测延迟(拍)
  integer e2e_lat_q = -1;
  integer e2e_lat_a = -1;
  integer e2e_cyc_n = 0;
  always @(posedge clk) if (!e2e_rst) e2e_cyc_n = e2e_cyc_n + 1;
  always @(posedge clk) if (!e2e_rst && e2e_q_valid   && e2e_lat_q < 0) e2e_lat_q = e2e_cyc_n;
  always @(posedge clk) if (!e2e_rst && e2e_arp_valid && e2e_lat_a < 0) e2e_lat_a = e2e_cyc_n;

  // ---------------- 探针: 输出 IPv4 头目的 IP 字段是否被 ARP 结论覆盖 ----------------
  reg        e2e_ipchk_arm  = 1'b0;
  reg        e2e_ipchk_done = 1'b0;
  reg [31:0] e2e_ipchk_dst  = 0;

  always @(posedge clk) begin
    if (e2e_rst) begin
      e2e_ipchk_done <= 1'b0;
    end
    else if (e2e_ipchk_arm && !e2e_ipchk_done && e2e_ev_mvalid && e2e_ev_mready) begin
      e2e_ipchk_done <= 1'b1;
      e2e_ipchk_dst  <= e2e_ev_mdata[271:240];
    end
  end

  // ==========================================================================
  // 任务
  // ==========================================================================
  task automatic cyc(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
  endtask

  task automatic set_mready(input v);
    begin @(negedge clk); st_mready <= v; end
  endtask

  task automatic e2e_clr_out;
    begin
      @(negedge clk);
      e2e_out_beats = 0; e2e_out_pkts = 0; e2e_out_mac0 = 0; e2e_req_cnt = 0;
    end
  endtask

  task automatic e2e_chk_dstip;
    input [119:0] name;
    input [31:0]  exp;
    begin
      if (!e2e_ipchk_done) begin
        $display("[FAIL] %s : 未收到输出帧, 无法检查", name);
        err = err + 1;
      end
      else if (e2e_ipchk_dst !== exp) begin
        $display("[FAIL] %s : IPv4 头目的 IP 字段 exp=%h act=%h (被 ARP 结论覆盖!)",
                 name, exp, e2e_ipchk_dst);
        err = err + 1;
      end
      else begin
        $display("[PASS] %s : IPv4 头目的 IP 字段 = %h (未被改写)", name, e2e_ipchk_dst);
      end
      e2e_ipchk_arm  = 1'b0;
      e2e_ipchk_done = 1'b0;
    end
  endtask

  task automatic e2e_chk_out;
    input [119:0] name;
    input integer exp_beats;
    input [47:0]  exp_mac;
    begin
      if (e2e_out_beats != exp_beats) begin
        $display("[FAIL] %s : 输出拍数 exp=%0d act=%0d", name, exp_beats, e2e_out_beats);
        err = err + 1;
      end
      else if (exp_beats != 0 && e2e_out_mac0 !== exp_mac) begin
        $display("[FAIL] %s : 首拍目的 MAC exp=%h act=%h", name, exp_mac, e2e_out_mac0);
        err = err + 1;
      end
      else begin
        if (exp_beats == 0) $display("[PASS] %s : 整包丢弃", name);
        else                $display("[PASS] %s : %0d 拍, 目的 MAC=%h", name, exp_beats, e2e_out_mac0);
      end
    end
  endtask

  task automatic e2e_chk_req;
    input [119:0] name;
    input integer exp_cnt;
    input [31:0]  exp_tpa;
    input [31:0]  exp_spa;
    input [47:0]  exp_sha;
    begin
      if (e2e_req_cnt != exp_cnt) begin
        $display("[FAIL] %s : ARP 请求数 exp=%0d act=%0d", name, exp_cnt, e2e_req_cnt);
        err = err + 1;
      end
      else if (exp_cnt != 0 && (e2e_req_tpa !== exp_tpa || e2e_req_spa !== exp_spa || e2e_req_sha !== exp_sha)) begin
        $display("[FAIL] %s : TPA exp=%h act=%h / SPA exp=%h act=%h / SHA exp=%h act=%h",
                 name, exp_tpa, e2e_req_tpa, exp_spa, e2e_req_spa, exp_sha, e2e_req_sha);
        err = err + 1;
      end
      else begin
        if (exp_cnt == 0) $display("[PASS] %s : 未发 ARP 请求", name);
        else              $display("[PASS] %s : TPA=%h SPA=%h SHA=%h", name, e2e_req_tpa, e2e_req_spa, e2e_req_sha);
      end
    end
  endtask

  task automatic e2e_send_pkt;
    input [31:0] pid;
    input [31:0] dstip;
    input integer nbeats;
    integer b;
    begin
      for (b = 0; b < nbeats; b = b + 1) begin
        @(negedge clk);
        e2e_iv_sdata  = {352'd0, dstip, E2E_LOCAL_IP, 32'd0, pid, b};
        e2e_iv_skeep  = 64'hFFFF_FFFF_FFFF_FFFF;
        e2e_iv_slast  = (b == nbeats - 1);
        e2e_iv_svalid = 1'b1;
        @(posedge clk);
        while (!(e2e_iv_svalid && e2e_iv_sready)) @(posedge clk);
      end
      @(negedge clk);
      e2e_iv_svalid = 1'b0;
      e2e_iv_slast  = 1'b0;
    end
  endtask

  task automatic e2e_waitcyc;
    input integer n;
    begin
      repeat (n) @(posedge clk);
    end
  endtask

  // ==========================================================================
  // 激励: 顺序 phase
  // ==========================================================================
  integer base;

  initial begin
    $display("================================================================");
    $display(" tb_ipv4_eth_tx 合并回归 (P1 主功能 / P2 dstip 回归 / P3 e2e)");
    $display("================================================================");
    err=0; perr=0; got_cnt=0; sq_wr=0; sq_rd=0; e_wr=0; e_rd=0;
    st_sdata=0; st_skeep=0; st_slast=0; st_svalid=0;
    st_mready=1'b1;
    st_cmp_en=0; st_dstip_en=0; st_got_first=0;
    e2e_am_mready=1'b1; e2e_ev_mready=1'b1;
    e2e_iv_sdata=0; e2e_iv_skeep=0; e2e_iv_slast=0; e2e_iv_svalid=0;
    e2e_as_sdata=0; e2e_as_skeep=0; e2e_as_svalid=0; e2e_as_slast=0;
    st_rst=1'b1; e2e_rst=1'b1;
    cyc(6); st_rst=1'b0; cyc(2);

    // ===================== P1: 主功能 =====================
    $display("==================== P1: ipv4_eth_tx 集成自测 (行为 ARP) ====================");
    st_cmp_en=1'b1;

    $display("--- T1: short 20B IPv4 packet, HIT -> frame 34B => 60B ---");
    base = got_cnt;
    push_ip_pkt(20, 8'h10, 32'h0900_000A, 1'b1); cyc(120);
    if (got_cnt != base + 1) begin $display("  [FAIL] expect 1 beat, got %0d", got_cnt-base); err=err+1; end
    else $display("  [PASS] 1 beat(60B 帧)");
    cyc(20);

    $display("--- T2: long 80B IPv4 packet, HIT -> frame 94B => 2 beats ---");
    base = got_cnt;
    push_ip_pkt(80, 8'h40, 32'h0A00_000B, 1'b1); cyc(200);
    if (got_cnt != base + 2) begin $display("  [FAIL] expect 2 beats, got %0d", got_cnt-base); err=err+1; end
    else $display("  [PASS] 2 beats");
    cyc(20);

    $display("--- T3: MISS packet must vanish ---");
    base = got_cnt;
    push_ip_pkt(40, 8'h60, ST_MISS_IP, 1'b0); cyc(150);
    if (got_cnt != base) begin $display("  [FAIL] MISS 包不应有输出, got %0d", got_cnt-base); err=err+1; end
    else $display("  [PASS] MISS 整包丢弃");
    cyc(20);

    $display("--- T4: backpressure then another packet ---");
    base = got_cnt;
    set_mready(1'b0); cyc(3);
    push_ip_pkt(30, 8'h80, 32'h0B00_000C, 1'b1); cyc(60);
    set_mready(1'b1); cyc(60);
    push_ip_pkt(70, 8'hA0, 32'h0C00_000D, 1'b1); cyc(200);
    if (got_cnt != base + 3) begin $display("  [FAIL] expect 3 beats, got %0d", got_cnt-base); err=err+1; end
    else $display("  [PASS] 3 beats");
    cyc(20);

    st_cmp_en=1'b0;
    $display("P1 完成: err=%0d", err);
    $display("");

    // ===================== P2: dstip 回归防护 =====================
    $display("==================== P2: 目的 IP 字段回归防护 ====================");
    st_got_first = 0;
    st_dstip_en  = 1'b1;
    st_push_beat({352'd0, DST_REAL_DST, DST_SRC_IP, 96'd0}, 64'hFFFF_FFFF_FFFF_FFFF, 1'b0);
    st_push_beat({352'd0, 64'h1122_3344_5566_7788, 96'd0}, 64'hFFFF_FFFF_FFFF_FFFF, 1'b0);
    st_push_beat({352'd0, 64'h1122_3344_5566_7788, 96'd0}, 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
    cyc(80);
    st_dstip_en = 1'b0;

    $display("IPv4 头里真实目的 IP REAL_DST = %h", DST_REAL_DST);
    $display("输出以太帧: dst_mac=%h src_mac=%h ethertype=%h",
             st_out_dst_mac, st_out_src_mac, st_out_ethertype);
    $display("输出 IPv4 头 src_ip 字段      = %h  (期望 %h) %s",
             st_out_src_field, DST_SRC_IP,
             (st_out_src_field === DST_SRC_IP) ? "OK" : "*** 被改写 ***");
    $display("输出 IPv4 头 dst_ip 字段      = %h  (期望 %h) %s",
             st_out_dst_field, DST_REAL_DST,
             (st_out_dst_field === DST_REAL_DST) ? "OK" : "*** 被改写 ***");
    if (st_out_dst_field !== DST_REAL_DST) begin
      $display("[FAIL] BUG 复现: IPv4 头目的 IP 被 ARP 结论 IP 覆盖 (%h -> %h)",
               DST_REAL_DST, st_out_dst_field);
      err = err + 1;
    end
    else begin
      $display("[PASS] 未复现: 目的 IP 字段保持不变");
    end
    $display("P2 完成: err=%0d", err);
    $display("");

    // ===================== P3: e2e 端到端 =====================
    $display("==================== P3: e2e 端到端 (真实 arp_engine_top) ====================");
    e2e_rst = 1'b0;
    // 等 cache / pending 清表完成
    wait (e2e_stat_cache_clr && e2e_stat_pend_clr);
    e2e_waitcyc(10);
    $display("--- cache/pending 清表完成, 开始测试 ---");

    // E1 同网段首次查询
    e2e_clr_out();
    e2e_send_pkt(1, E2E_PEER_IP, 3);
    e2e_waitcyc(60);
    e2e_chk_out ("E1 同网段首次(应丢弃)", 0, 48'd0);
    e2e_chk_req ("E1 ARP 请求", 1, E2E_PEER_IP, E2E_LOCAL_IP, E2E_LOCAL_MAC);

    // E2 学习后再发
    e2e_waitcyc(30);
    e2e_clr_out();
    e2e_send_pkt(2, E2E_PEER_IP, 3);
    e2e_waitcyc(60);
    e2e_chk_out ("E2 同网段命中转发", 4, E2E_PEER_MAC);

    // E3 跨网段首次查询
    e2e_clr_out();
    e2e_send_pkt(3, E2E_EXT_IP, 3);
    e2e_waitcyc(60);
    e2e_chk_out ("E3 跨网段首次(应丢弃)", 0, 48'd0);
    e2e_chk_req ("E3 ARP 请求(网关)", 1, E2E_GW_IP, E2E_LOCAL_IP, E2E_LOCAL_MAC);

    // E4 学习网关后再发
    e2e_waitcyc(30);
    e2e_clr_out();
    @(negedge clk); e2e_ipchk_arm = 1'b1;
    e2e_send_pkt(4, E2E_EXT_IP, 3);
    e2e_waitcyc(60);
    e2e_chk_out ("E4 跨网段命中转发", 4, E2E_GW_MAC);
    e2e_chk_dstip("E4 IPv4 头目的 IP", E2E_EXT_IP);

    // E5 本网段广播 192.168.1.255
    e2e_clr_out();
    e2e_send_pkt(5, E2E_BC_IP, 3);
    e2e_waitcyc(60);
    e2e_chk_out ("E5 本网段广播转发", 4, 48'hFFFF_FFFF_FFFF);
    e2e_chk_req ("E5 广播不发请求", 0, 32'd0, 32'd0, 48'd0);

    // E6 全局广播 255.255.255.255
    e2e_clr_out();
    e2e_send_pkt(6, E2E_ALL_BC, 3);
    e2e_waitcyc(60);
    e2e_chk_out ("E6 全局广播转发", 4, 48'hFFFF_FFFF_FFFF);
    e2e_chk_req ("E6 全局广播不发请求", 0, 32'd0, 32'd0, 48'd0);

    e2e_waitcyc(20);
    $display("--- arp_buf 分支探针 (真实 arp_engine_top 时序) ---");
    $display("  s10 首拍握手次数         cnt_first       = %0d", e2e_cnt_first);
    $display("  其中走 [实时] 分支        cnt_first_empty = %0d", e2e_cnt_first_empty);
    $display("  其中走 [缓冲] 分支        cnt_first_buff  = %0d", e2e_cnt_first_buff);
    $display("  arp_buf_take_live 翻转   cnt_take_live   = %0d", e2e_cnt_take_live);
    $display("  arp_buf_wr_en 翻转       cnt_wr          = %0d", e2e_cnt_wr);
    $display("  buf 占用峰值             max_occ         = %0d", e2e_max_occ);
    $display("  query->arp_valid 延迟     %0d 拍", e2e_lat_a - e2e_lat_q);
    $display("--- stat 锁存(应全为 0, 否则属于误报) ---");
    $display("  stat_rx_error         = %b", e2e_stat_rx_error);
    $display("  stat_ack_fifo_ovf     = %b", e2e_stat_ack_ovf);
    $display("  stat_pending_fifo_ovf = %b", e2e_stat_pend_ovf);
    $display("  stat_lookup_no_resp   = %b   <== M3 修复后不应误报", e2e_stat_no_resp);
    $display("  stat_query_src_not_local = %b (各包 src 均为本地 IP, 应为 0)", e2e_stat_src_bad);
    $display("  cache_clr=%b pend_clr=%b", e2e_stat_cache_clr, e2e_stat_pend_clr);
    $display("P3 完成: err=%0d", err);

    // ===================== 汇总 =====================
    $display("================================================================");
    $display(" 汇总: 累计 err=%0d", err);
    if (err == 0) $display(" *** ALL TESTS PASSED ***");
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
    $display("================================================================");
    $finish;
  end

  initial begin
    #500_000;
    $display("[%0t] FATAL: timeout", $time);
    $finish;
  end

endmodule
`resetall
