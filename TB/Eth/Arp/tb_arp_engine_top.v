`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_arp_engine_top.v
// Module Name : tb_arp_engine_top
// ----------------------------------------------------------------------------
// Description : arp_engine_top 合并回归测试台(单 module)
//   将原 5 个测试台合并为顺序执行的 phase, 每个 phase 保留其全部场景/激励/判定:
//     Phase 1 (single)  <- tb_arp_eth_top.v    主功能: 清表/学习应答/命中未命中/
//                          pending去重/错误注入/广播/跨网段/反压/ack溢出/pending清零
//     Phase 2 (same)    <- tb_arp_multi_ip.v    一口多 IP(LOCAL_IP_NUM=2) 同子网双IP
//     Phase 3 (cross)   <- tb_arp_multi_ip.v    一口多 IP 跨子网双IP(边界/流水线)
//     Phase 4 (learn)   <- tb_arp_learn_policy.v 学习策略(只学问到本机的发送方)
//     Phase 5 (shared)  <- tb_arp_shared_table.v 多 IP 共享 ARP/pending 表(两实例)
//     Phase 6 (probe)   <- tb_arp_p3_probe.v    诊断探针(打印内部信号, 不判定)
//
//   DUT 实例:
//     u_dut_single : LOCAL_IP_NUM=1, 10.0.0.2/24   gw 10.0.0.1
//     u_dut_same   : LOCAL_IP_NUM=2, 192.168.1.10/.20 同子网, gw 192.168.1.1
//     u_dut_cross  : LOCAL_IP_NUM=2, 192.168.1.10 + 10.0.0.10 跨子网(probe 复用)
//     u_dut_learn  : LOCAL_IP_NUM=1, 192.168.1.10/24
//     u_dut_sha    : LOCAL_IP_NUM=2, 同二层域
//     u_dut_shb    : LOCAL_IP_NUM=2, 不同二层域
// ============================================================================

module tb_arp_engine_top;

  // --------------------------------------------------------------------------
  // 参数
  // --------------------------------------------------------------------------
  localparam AXIS_WIDTH         = 512;
  localparam CACHE_ITEM_WIDTH   = 81;
  localparam CACHE_DEEP         = 8;
  localparam PENDING_ITEM_WIDTH = 90;
  localparam PENDING_DEEP       = 8;
  localparam PENDING_TIME_WIDTH = 57;
  localparam HASH_WAY_CNT       = 4;

  // --------------------------------------------------------------------------
  // 字节序: 工程约定"字段低位 = 线上首字节"(小端序)。
  // Phase1 的常量按人类记法写, 进入帧域前统一用 le*() 做字节交换。
  // --------------------------------------------------------------------------
  function [15:0] le16; input [15:0] x; begin le16 = {x[ 7:0],x[15: 8]}; end endfunction
  function [31:0] le32; input [31:0] x; begin le32 = {x[ 7:0],x[15: 8],x[23:16],x[31:24]}; end endfunction
  function [47:0] le48; input [47:0] x; begin le48 = {x[ 7:0],x[15: 8],x[23:16],x[31:24],x[39:32],x[47:40]}; end endfunction

  // --------------------------------------------------------------------------
  // 全局时钟 / 复位 (所有 DUT 共用, phase 顺序执行)
  // --------------------------------------------------------------------------
  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  integer cyc_i;
  task automatic cyc(input integer n);
    begin
      for (cyc_i = 0; cyc_i < n; cyc_i = cyc_i + 1) @(posedge clk);
    end
  endtask

  // --------------------------------------------------------------------------
  // 全局 err 汇总
  // --------------------------------------------------------------------------
  integer single_err = 0;
  integer same_err   = 0;
  integer cross_err  = 0;
  integer learn_err  = 0;
  integer sh_err     = 0;

  // ==========================================================================
  // Phase 1 (single) 信号: tb_arp_eth_top
  // ==========================================================================
  localparam [31:0] L_IP    = 32'h0A00_0002;  // 10.0.0.2
  localparam [31:0] GATEWAY = 32'h0A00_0001;  // 10.0.0.1
  localparam [31:0] MASK    = 32'hFFFF_FF00;
  localparam [47:0] L_MAC   = 48'h0011_2233_4455;
  localparam [47:0] HOST_MAC= 48'hAABB_CCDD_0001;
  localparam [31:0] HOST_IP = 32'h0A00_0005;
  localparam [63:0] KEEP_OK = 64'h0FFF_FFFF_FFFF_FFFF;
  localparam [63:0] KEEP_BAD= 64'h0000_0000_FFFF_FFFF;

  reg  [31:0] single_query_dst_ip;
  reg  [31:0] single_query_src_ip;
  reg         single_query_valid_pulse;
  wire [47:0] single_arp_mac;
  wire [47:0] single_arp_src_mac_w;
  wire        single_arp_miss;
  wire        single_arp_valid;

  reg  [AXIS_WIDTH-1:0] single_arp_axis_sdata;
  reg  [AXIS_WIDTH/8-1:0] single_arp_axis_skeep;
  reg         single_arp_axis_svalid;
  reg         single_arp_axis_slast;
  wire        single_arp_axis_sready;
  wire [AXIS_WIDTH-1:0] single_arp_axis_mdata;
  wire [AXIS_WIDTH/8-1:0] single_arp_axis_mkeep;
  wire        single_arp_axis_mvalid;
  wire        single_arp_axis_mlast;
  reg         single_arp_axis_mready;

  reg  [31:0] single_cfg_local_ip;
  reg  [47:0] single_cfg_local_mac;
  reg  [31:0] single_cfg_gateway_ip;
  reg  [31:0] single_cfg_subnet_mask;
  reg  [PENDING_TIME_WIDTH-1:0] single_cfg_pending_time;
  reg         single_cfg_clear_cache;
  reg         single_cfg_clear_pending;

  wire        single_stat_rx_error;
  wire        single_stat_ack_fifo_overflow_error;
  wire        single_stat_pending_fifo_overflow_error;
  wire        single_stat_lookup_no_resp_error;
  wire        single_pending_clear_finish;
  wire        single_cache_clear_finish_w;

  // 发送帧监视
  integer single_cnt_tx_frame;
  integer single_cnt_tx_req;
  integer single_cnt_tx_rep;
  reg  [31:0] single_last_req_tpa;
  reg  [47:0] single_last_req_dest_mac;
  reg  [31:0] single_last_rep_tpa;

  // 查询响应捕获
  reg        single_resp_seen;
  reg [47:0] single_resp_mac;
  reg        single_resp_miss;

  reg single_dbg_en = 1'b0;

  arp_engine_top #(
    .AXIS_WIDTH        (AXIS_WIDTH        ),
    .CACHE_ITEM_WIDTH  (CACHE_ITEM_WIDTH  ),
    .CACHE_DEEP        (CACHE_DEEP        ),
    .PENDING_ITEM_WIDTH(PENDING_ITEM_WIDTH),
    .PENDING_DEEP      (PENDING_DEEP      ),
    .PENDING_TIME_WIDTH(PENDING_TIME_WIDTH),
    .HASH_WAY_CNT      (HASH_WAY_CNT      ),
    .LOCAL_IP_NUM      (1                 )
  ) u_dut_single(
    .clk               (clk               ),
    .rst               (rst               ),
    .query_src_ip      (single_query_src_ip),
    .query_dst_ip      (single_query_dst_ip),
    .query_valid_pulse (single_query_valid_pulse),
    .arp_dst_mac       (single_arp_mac    ),
    .arp_src_mac       (single_arp_src_mac_w),
    .arp_miss          (single_arp_miss   ),
    .arp_valid         (single_arp_valid  ),
    .arp_axis_sdata    (single_arp_axis_sdata),
    .arp_axis_skeep    (single_arp_axis_skeep),
    .arp_axis_svalid   (single_arp_axis_svalid),
    .arp_axis_slast    (single_arp_axis_slast),
    .arp_axis_susr     (1'b0              ),
    .arp_axis_sready   (single_arp_axis_sready),
    .arp_axis_mdata    (single_arp_axis_mdata),
    .arp_axis_mkeep    (single_arp_axis_mkeep),
    .arp_axis_mvalid   (single_arp_axis_mvalid),
    .arp_axis_mlast    (single_arp_axis_mlast),
    .arp_axis_musr     (                  ),
    .arp_axis_mready   (single_arp_axis_mready),
    .cfg_local_ip      (single_cfg_local_ip),
    .cfg_local_mac     (single_cfg_local_mac),
    .cfg_gateway_ip    (single_cfg_gateway_ip),
    .cfg_subnet_mask   (single_cfg_subnet_mask),
    .cfg_pending_time  (single_cfg_pending_time),
    .cfg_clear_cache   (single_cfg_clear_cache),
    .cfg_clear_pending (single_cfg_clear_pending),
    .stat_rx_error                    (single_stat_rx_error),
    .stat_ack_fifo_overflow_error     (single_stat_ack_fifo_overflow_error),
    .stat_pending_fifo_overflow_error (single_stat_pending_fifo_overflow_error),
    .stat_lookup_no_resp_error        (single_stat_lookup_no_resp_error),
    .stat_pending_clear_finish        (single_pending_clear_finish),
    .stat_cache_clear_finish          (single_cache_clear_finish_w),
    .stat_query_src_not_local         (                  )
  );

  // ---- single: TX 帧监视 ----
  always @(posedge clk) begin
    if (single_arp_axis_mvalid && single_arp_axis_mready) begin
      single_cnt_tx_frame = single_cnt_tx_frame + 1;
      if (single_arp_axis_mdata[175:160] == le16(16'd1)) begin
        single_cnt_tx_req       = single_cnt_tx_req + 1;
        single_last_req_tpa     = single_arp_axis_mdata[335:304];
        single_last_req_dest_mac= single_arp_axis_mdata[47:0];
        $display("[%0t] TX REQ dest_mac=%012h tpa=%08h", $time, single_arp_axis_mdata[47:0], single_arp_axis_mdata[335:304]);
      end
      else if (single_arp_axis_mdata[175:160] == le16(16'd2)) begin
        single_cnt_tx_rep  = single_cnt_tx_rep + 1;
        single_last_rep_tpa= single_arp_axis_mdata[335:304];
        $display("[%0t] TX REP dest_mac=%012h tpa=%08h", $time, single_arp_axis_mdata[47:0], single_arp_axis_mdata[335:304]);
      end
    end
  end

  // ---- single: 查询响应捕获 ----
  always @(posedge clk) begin
    if (single_arp_valid) begin
      single_resp_seen <= 1'b1;
      single_resp_mac  <= single_arp_mac;
      single_resp_miss <= single_arp_miss;
    end
  end

  // ---- single: 调试探针 ----
  always @(posedge clk) begin
    if (u_dut_single.arp_rx_frame_valid && u_dut_single.arp_rx_frame_ready) begin
      $display("[%0t] RXFRM type=%04h oper=%04h spa=%08h sha=%012h req=%b ack=%b",
               $time, u_dut_single.eth_rx_type, u_dut_single.arp_rx_oper, u_dut_single.arp_rx_spa,
               u_dut_single.arp_rx_sha, u_dut_single.is_arp_req, u_dut_single.is_arp_ack);
    end
  end
  always @(posedge clk) if (u_dut_single.arp_rx_error_pulse) $display("[%0t] RX-ERR(rejected)", $time);
  always @(posedge clk) begin
    if (u_dut_single.eth_ack_frame_valid)
      $display("[%0t] PUSH-ACK spa=%08h full=%b", $time, u_dut_single.arp_rx_spa, u_dut_single.arp_ack_fifo_full);
    if (u_dut_single.eth_pending_frame_valid)
      $display("[%0t] PUSH-PEND ip=%08h full=%b", $time, u_dut_single.pending_req_ip, u_dut_single.arp_pending_fifo_full);
    if (u_dut_single.arp_ack_fifo_rd_en)     $display("[%0t] POP-ACK", $time);
    if (u_dut_single.arp_pending_fifo_rd_en) $display("[%0t] POP-PEND", $time);
  end
  always @(posedge clk) begin
    if (u_dut_single.arp_rr_take) $display("[%0t] TAKE idx=%b", $time, u_dut_single.arp_rr_dout_onehot);
  end
  always @(posedge clk) begin
    if (single_dbg_en)
      $display("[%0t] ST datav=%b frdy=%b mvalid=%b mready=%b take=%b ep=%b ea=%b txhs=%b mhs=%b",
               $time, u_dut_single.tx_frame_data_valid, u_dut_single.arp_tx_frame_ready,
               single_arp_axis_mvalid, single_arp_axis_mready, u_dut_single.arp_rr_take,
               u_dut_single.arp_pending_fifo_empty, u_dut_single.arp_ack_fifo_empty,
               u_dut_single.tx_frame_data_handshake && u_dut_single.tx_frame_data_valid,
               single_arp_axis_mvalid && single_arp_axis_mready);
  end
  always @(posedge clk) begin
    if (u_dut_single.pending_req_valid_pulse)
      $display("[%0t] PEND-REQ ip=%08h", $time, u_dut_single.pending_req_ip);
  end
  always @(posedge clk) begin
    if (u_dut_single.query_valid_pulse_s1)
      $display("[%0t] Q s2: ip=%08h out_subnet=%b bord=%b", $time, u_dut_single.query_dst_ip_s2, u_dut_single.is_out_subnet_s2, u_dut_single.is_broadcast_addr_s3);
  end

  // ---- single: task ----
  task automatic single_send_arp(
    input [15:0] eth_type,
    input [47:0] src_mac ,
    input [31:0] spa     ,
    input [47:0] sha     ,
    input [15:0] oper    ,
    input [47:0] tha     ,
    input [31:0] tpa     ,
    input [63:0] keep
  );
    integer guard;
    begin
      single_arp_axis_sdata  <= {176'd0, le32(tpa), le48(tha), le32(spa), le48(sha), le16(oper),
                                 8'd4, 8'd6, le16(16'h0800), le16(16'd1),
                                 le16(eth_type), le48(src_mac), 48'hFFFF_FFFF_FFFF};
      single_arp_axis_skeep  <= keep;
      single_arp_axis_slast  <= 1'b1;
      single_arp_axis_svalid <= 1'b1;
      guard = 0;
      while (guard < 500) begin
        @(posedge clk);
        if (single_arp_axis_sready) guard = 500;
        else                        guard = guard + 1;
      end
      single_arp_axis_svalid <= 1'b0;
      single_arp_axis_slast  <= 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic single_do_query(input [31:0] ip);
    begin
      single_query_dst_ip      <= ip;
      single_query_valid_pulse <= 1'b1;
      @(posedge clk);
      single_query_valid_pulse <= 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic single_set_mready(input v);
    begin
      @(negedge clk);
      single_arp_axis_mready <= v;
    end
  endtask

  task automatic single_wait_resp(input integer max_cyc, output integer ok);
    integer i;
    begin
      single_resp_seen = 1'b0;
      i  = 0;
      ok = 0;
      while (!single_resp_seen && i < max_cyc) begin
        @(posedge clk);
        i = i + 1;
      end
      if (single_resp_seen) ok = 1;
    end
  endtask

  task automatic single_drain(input integer quiet);
    integer last;
    integer still;
    begin
      still = 0;
      last  = single_cnt_tx_frame;
      while (still < quiet) begin
        @(posedge clk);
        if (single_cnt_tx_frame == last) still = still + 1;
        else begin still = 0; last = single_cnt_tx_frame; end
      end
    end
  endtask

  task automatic single_wait_req(input integer max_cyc, output integer ok);
    integer base;
    integer i;
    begin
      base = single_cnt_tx_req;
      i    = 0;
      ok   = 0;
      while (single_cnt_tx_req == base && i < max_cyc) begin
        @(posedge clk);
        i = i + 1;
      end
      if (single_cnt_tx_req != base) ok = 1;
    end
  endtask

  // ==========================================================================
  // Phase 2 (same) 信号: tb_arp_multi_ip / sub_arp_multi_ip_samesub
  // ==========================================================================
  localparam [31:0] S_IP_A = 32'h0A01_A8C0; // 192.168.1.10
  localparam [31:0] S_IP_B = 32'h1401_A8C0; // 192.168.1.20
  localparam [31:0] S_DST1 = 32'h3201_A8C0; // 192.168.1.50
  localparam [31:0] S_DST2 = 32'h3301_A8C0; // 192.168.1.51
  localparam [31:0] S_DST3 = 32'h3401_A8C0; // 192.168.1.52
  localparam [31:0] S_IP_X = 32'h0100_000A; // 10.0.0.1 (非本地)
  localparam [31:0] S_GW   = 32'h0101_A8C0; // 192.168.1.1
  localparam [31:0] S_MASK = 32'h00FF_FFFF; // /24
  localparam [47:0] S_MAC_L= 48'h0102_0304_0506;
  localparam [47:0] S_SHA_R= 48'h1111_2222_3333;

  reg  [31:0] same_q_src = 0, same_q_dst = 0;
  reg         same_q_valid = 1'b0;
  wire [47:0] same_arp_mac;
  wire        same_arp_miss, same_arp_valid;
  reg  [AXIS_WIDTH-1:0] same_sdata = 0;
  reg  [63:0]           same_skeep = 0;
  reg                   same_svalid = 1'b0, same_slast = 1'b0;
  wire                  same_sready;
  wire [AXIS_WIDTH-1:0] same_mdata;
  wire [63:0]           same_mkeep;
  wire                  same_mvalid, same_mlast;
  reg                   same_mready = 1'b1;
  wire same_stat_rx_error, same_stat_ack_ovf, same_stat_pend_ovf, same_stat_no_resp;
  wire same_stat_pend_clr, same_stat_cache_clr;

  reg [15:0] same_cap_oper = 0;
  reg [31:0] same_cap_spa = 0, same_cap_tpa = 0;
  integer    same_cap_cnt = 0;

  arp_engine_top #(
    .AXIS_WIDTH   (AXIS_WIDTH),
    .CACHE_DEEP   (CACHE_DEEP),
    .PENDING_DEEP (PENDING_DEEP),
    .LOCAL_IP_NUM (2)
  ) u_dut_same (
    .clk(clk), .rst(rst),
    .query_src_ip(same_q_src), .query_dst_ip(same_q_dst), .query_valid_pulse(same_q_valid),
    .arp_dst_mac(same_arp_mac), .arp_src_mac(), .arp_miss(same_arp_miss), .arp_valid(same_arp_valid),
    .arp_axis_sdata(same_sdata), .arp_axis_skeep(same_skeep), .arp_axis_svalid(same_svalid), .arp_axis_slast(same_slast),
    .arp_axis_susr(1'b0), .arp_axis_sready(same_sready),
    .arp_axis_mdata(same_mdata), .arp_axis_mkeep(same_mkeep),
    .arp_axis_mvalid(same_mvalid), .arp_axis_mlast(same_mlast), .arp_axis_musr(), .arp_axis_mready(same_mready),
    .cfg_local_ip({S_IP_B, S_IP_A}),
    .cfg_local_mac({S_MAC_L, S_MAC_L}),
    .cfg_gateway_ip({S_GW, S_GW}),
    .cfg_subnet_mask({S_MASK, S_MASK}),
    .cfg_pending_time(57'd16),
    .cfg_clear_cache(1'b0), .cfg_clear_pending(1'b0),
    .stat_rx_error(same_stat_rx_error), .stat_ack_fifo_overflow_error(same_stat_ack_ovf),
    .stat_pending_fifo_overflow_error(same_stat_pend_ovf), .stat_lookup_no_resp_error(same_stat_no_resp),
    .stat_pending_clear_finish(same_stat_pend_clr), .stat_cache_clear_finish(same_stat_cache_clr),
    .stat_query_src_not_local()
  );

  always @(posedge clk) begin
    if (same_mvalid && same_mready) begin
      same_cap_oper <= same_mdata[175:160];
      same_cap_spa  <= same_mdata[255:224];
      same_cap_tpa  <= same_mdata[335:304];
      same_cap_cnt  <= same_cap_cnt + 1;
    end
  end

  reg same_dbg = 1'b0;
  always @(posedge clk) begin
    if (same_dbg) begin
      $display("[%0t] d req=%b req_r=%b msrc_r=%b mloc_r=%h ack_wr=%b ackEmp=%b pendEmp=%b rr_v=%b rr=%b txV=%b txR=%b mV=%b tpa=%h rerr=%b",
        $time,
        u_dut_same.is_arp_req, u_dut_same.is_arp_req_reg, u_dut_same.match_src_ip_reg, u_dut_same.match_local_ip_reg,
        u_dut_same.eth_ack_frame_valid, u_dut_same.arp_ack_fifo_empty, u_dut_same.arp_pending_fifo_empty,
        u_dut_same.arp_rr_dout_valid, u_dut_same.arp_rr_dout_onehot, u_dut_same.tx_frame_data_valid,
        u_dut_same.arp_tx_frame_ready, same_mvalid, u_dut_same.arp_rx_tpa, u_dut_same.stat_rx_error);
    end
  end

  task automatic same_do_query(input [31:0] s, input [31:0] d);
    begin
      @(negedge clk);
      same_q_src <= s; same_q_dst <= d; same_q_valid <= 1'b1;
      @(negedge clk);
      same_q_valid <= 1'b0;
    end
  endtask

  task automatic same_send_arp_rx(input [15:0] oper, input [31:0] spa, input [31:0] tpa);
    begin
      @(negedge clk);
      same_sdata  <= {176'd0, tpa, 48'h0, spa, S_SHA_R, oper, 8'h04, 8'h06,
                      16'h0008, 16'h0100, 16'h0608, S_SHA_R, 48'hFFFF_FFFF_FFFF};
      same_skeep  <= 64'h0000_03FF_FFFF_FFFF;
      same_slast  <= 1'b1;
      same_svalid <= 1'b1;
      @(posedge clk); while (!(same_svalid && same_sready)) @(posedge clk);
      @(negedge clk);
      same_svalid <= 1'b0;
      same_slast  <= 1'b0;
    end
  endtask

  task automatic same_chk(input [255:0] name, input integer cond);
    begin
      if (!cond) begin $display("  [FAIL] %0s", name); same_err = same_err + 1; end
      else            $display("  [PASS] %0s", name);
    end
  endtask

  task automatic same_wait_resp(input integer maxc, output integer ok);
    integer i;
    begin
      ok = 0;
      for (i = 0; i < maxc && !ok; i = i + 1) begin
        @(posedge clk);
        if (same_arp_valid) ok = 1;
      end
    end
  endtask

  // ==========================================================================
  // Phase 3 (cross) 信号: tb_arp_multi_ip / sub_arp_multi_ip_crosssub
  //   (probe phase 也复用该实例与信号)
  // ==========================================================================
  localparam [31:0] C_IP_A  = 32'h0A01_A8C0; // 192.168.1.10
  localparam [31:0] C_IP_B  = 32'h0A00_000A; // 10.0.0.10
  localparam [31:0] C_GW_A  = 32'h0101_A8C0; // 192.168.1.1
  localparam [31:0] C_GW_B  = 32'h0100_000A; // 10.0.0.1
  localparam [31:0] C_MSK24 = 32'h00FF_FFFF; // 255.255.255.0
  localparam [31:0] C_H_A   = 32'h3201_A8C0; // 192.168.1.50
  localparam [31:0] C_H_B   = 32'h3200_000A; // 10.0.0.50
  localparam [31:0] C_X1    = 32'h0808_0808; // 8.8.8.8
  localparam [31:0] C_X2    = 32'h0909_0909; // 9.9.9.9
  localparam [31:0] C_BC_A  = 32'hFF01_A8C0; // 192.168.1.255
  localparam [31:0] C_IP_Z  = 32'h6400_000A; // 10.0.0.100 非本地
  localparam [47:0] C_MAC_A = 48'h0102_0304_0501;
  localparam [47:0] C_MAC_B = 48'h0102_0304_0502;
  localparam [47:0] C_SHA_R = 48'h1111_2222_3333;

  reg  [31:0] cross_q_src = 0, cross_q_dst = 0;
  reg         cross_q_valid = 1'b0;
  wire [47:0] cross_arp_mac;
  wire        cross_arp_miss, cross_arp_valid;
  reg  [AXIS_WIDTH-1:0] cross_sdata = 0;
  reg  [63:0]           cross_skeep = 0;
  reg                   cross_svalid = 1'b0, cross_slast = 1'b0;
  wire                  cross_sready;
  wire [AXIS_WIDTH-1:0] cross_mdata;
  wire [63:0]           cross_mkeep;
  wire                  cross_mvalid, cross_mlast;
  reg                   cross_mready = 1'b1;
  wire cross_stat_rx_error, cross_stat_ack_ovf, cross_stat_pend_ovf, cross_stat_no_resp;
  wire cross_stat_pend_clr, cross_stat_cache_clr, cross_stat_src_bad;

  reg [47:0] cross_cap_smac = 0;
  reg [15:0] cross_cap_oper = 0;
  reg [31:0] cross_cap_spa = 0, cross_cap_tpa = 0;
  integer    cross_cap_cnt = 0;
  reg [47:0] cross_resp_mac = 0;
  reg        cross_resp_miss = 0;

  arp_engine_top #(
    .AXIS_WIDTH   (AXIS_WIDTH),
    .CACHE_DEEP   (CACHE_DEEP),
    .PENDING_DEEP (PENDING_DEEP),
    .LOCAL_IP_NUM (2)
  ) u_dut_cross (
    .clk(clk), .rst(rst),
    .query_src_ip(cross_q_src), .query_dst_ip(cross_q_dst), .query_valid_pulse(cross_q_valid),
    .arp_dst_mac(cross_arp_mac), .arp_src_mac(), .arp_miss(cross_arp_miss), .arp_valid(cross_arp_valid),
    .arp_axis_sdata(cross_sdata), .arp_axis_skeep(cross_skeep), .arp_axis_svalid(cross_svalid), .arp_axis_slast(cross_slast),
    .arp_axis_susr(1'b0), .arp_axis_sready(cross_sready),
    .arp_axis_mdata(cross_mdata), .arp_axis_mkeep(cross_mkeep),
    .arp_axis_mvalid(cross_mvalid), .arp_axis_mlast(cross_mlast), .arp_axis_musr(), .arp_axis_mready(cross_mready),
    .cfg_local_ip({C_IP_B, C_IP_A}),
    .cfg_local_mac({C_MAC_B, C_MAC_A}),
    .cfg_gateway_ip({C_GW_B, C_GW_A}),
    .cfg_subnet_mask({C_MSK24, C_MSK24}),
    .cfg_pending_time(57'd16),
    .cfg_clear_cache(1'b0), .cfg_clear_pending(1'b0),
    .stat_rx_error(cross_stat_rx_error), .stat_ack_fifo_overflow_error(cross_stat_ack_ovf),
    .stat_pending_fifo_overflow_error(cross_stat_pend_ovf), .stat_lookup_no_resp_error(cross_stat_no_resp),
    .stat_pending_clear_finish(cross_stat_pend_clr), .stat_cache_clear_finish(cross_stat_cache_clr),
    .stat_query_src_not_local(cross_stat_src_bad)
  );

  always @(posedge clk) begin
    if (cross_mvalid && cross_mready) begin
      cross_cap_smac <= cross_mdata[95:48];
      cross_cap_oper <= cross_mdata[175:160];
      cross_cap_spa  <= cross_mdata[255:224];
      cross_cap_tpa  <= cross_mdata[335:304];
      cross_cap_cnt  <= cross_cap_cnt + 1;
    end
  end
  always @(posedge clk) if (cross_arp_valid) begin
    cross_resp_mac <= cross_arp_mac; cross_resp_miss <= cross_arp_miss;
  end

  task automatic cross_do_query(input [31:0] s, input [31:0] d);
    begin
      @(negedge clk);
      cross_q_src <= s; cross_q_dst <= d; cross_q_valid <= 1'b1;
      @(negedge clk);
      cross_q_valid <= 1'b0;
    end
  endtask

  task automatic cross_wait_resp(input integer maxc, output integer got);
    integer i;
    begin
      got = 0;
      for (i = 0; i < maxc && !got; i = i + 1) begin
        @(posedge clk);
        if (cross_arp_valid) got = 1;
      end
      @(posedge clk); // 让 resp_* 抓稳
    end
  endtask

  task automatic cross_send_arp_rx(input [15:0] oper, input [31:0] spa, input [31:0] tpa);
    begin
      @(negedge clk);
      cross_sdata  <= {176'd0, tpa, 48'h0, spa, C_SHA_R, oper, 8'h04, 8'h06,
                       16'h0008, 16'h0100, 16'h0608, C_SHA_R, 48'hFFFF_FFFF_FFFF};
      cross_skeep  <= 64'h0000_03FF_FFFF_FFFF;
      cross_slast  <= 1'b1;
      cross_svalid <= 1'b1;
      @(posedge clk);
      while (!(cross_svalid && cross_sready)) @(posedge clk);
      @(negedge clk);
      cross_svalid <= 1'b0;
      cross_slast  <= 1'b0;
    end
  endtask

  task automatic cross_chk(input [255:0] name, input integer cond);
    begin
      if (!cond) begin $display("  [FAIL] %0s", name); cross_err = cross_err + 1; end
      else            $display("  [PASS] %0s", name);
    end
  endtask

  task automatic cross_chk32(input [255:0] name, input [31:0] got, input [31:0] exp);
    begin
      if (got !== exp) begin $display("  [FAIL] %0s : got=%h exp=%h", name, got, exp); cross_err = cross_err + 1; end
      else                   $display("  [PASS] %0s (%h)", name, got);
    end
  endtask

  // ==========================================================================
  // Phase 4 (learn) 信号: tb_arp_learn_policy
  // ==========================================================================
  localparam [31:0] L_IP_L  = 32'h0A01_A8C0; // 192.168.1.10  本机
  localparam [31:0] L_GW_L  = 32'h0101_A8C0; // 192.168.1.1
  localparam [31:0] L_MSK24 = 32'h00FF_FFFF; // 255.255.255.0
  localparam [31:0] L_H1    = 32'h3201_A8C0; // 192.168.1.50
  localparam [31:0] L_H2    = 32'h3301_A8C0; // 192.168.1.51
  localparam [31:0] L_H3    = 32'h3401_A8C0; // 192.168.1.52
  localparam [31:0] L_OTH   = 32'h6301_A8C0; // 192.168.1.99
  localparam [31:0] L_IP_Z  = 32'h6400_000A; // 10.0.0.100
  localparam [47:0] L_MAC_L = 48'h0102_0304_050A;
  localparam [47:0] L_MAC_H1= 48'hAAAA_0000_0001;
  localparam [47:0] L_MAC_H2= 48'hAAAA_0000_0002;
  localparam [47:0] L_MAC_H3= 48'hAAAA_0000_0003;
  localparam [47:0] L_MAC_NEW=48'hBBBB_0000_0009;

  reg  [31:0] learn_q_src = 0, learn_q_dst = 0;
  reg         learn_q_valid = 1'b0;
  wire [47:0] learn_arp_mac;
  wire [47:0] learn_arp_src_mac;
  wire        learn_arp_miss, learn_arp_valid;
  reg  [AXIS_WIDTH-1:0] learn_sdata = 0;
  reg  [63:0]           learn_skeep = 0;
  reg                   learn_svalid = 1'b0, learn_slast = 1'b0;
  wire                  learn_sready;
  wire [AXIS_WIDTH-1:0] learn_mdata;
  wire [63:0]           learn_mkeep;
  wire                  learn_mvalid, learn_mlast;
  reg                   learn_mready = 1'b1;
  wire learn_stat_rx_error, learn_stat_ack_ovf, learn_stat_pend_ovf, learn_stat_no_resp;
  wire learn_stat_pend_clr, learn_stat_cache_clr, learn_stat_src_bad;

  reg [47:0] learn_cap_smac = 0;
  reg [15:0] learn_cap_oper = 0;
  reg [31:0] learn_cap_spa = 0, learn_cap_tpa = 0;
  integer    learn_cap_cnt = 0;
  reg [47:0] learn_resp_mac = 0;
  reg        learn_resp_miss = 0;

  arp_engine_top #(
    .AXIS_WIDTH   (AXIS_WIDTH),
    .CACHE_DEEP   (CACHE_DEEP),
    .PENDING_DEEP (PENDING_DEEP),
    .LOCAL_IP_NUM (1)
  ) u_dut_learn (
    .clk(clk), .rst(rst),
    .query_src_ip(learn_q_src), .query_dst_ip(learn_q_dst), .query_valid_pulse(learn_q_valid),
    .arp_dst_mac(learn_arp_mac), .arp_src_mac(learn_arp_src_mac),
    .arp_miss(learn_arp_miss), .arp_valid(learn_arp_valid),
    .arp_axis_sdata(learn_sdata), .arp_axis_skeep(learn_skeep), .arp_axis_svalid(learn_svalid), .arp_axis_slast(learn_slast),
    .arp_axis_susr(1'b0), .arp_axis_sready(learn_sready),
    .arp_axis_mdata(learn_mdata), .arp_axis_mkeep(learn_mkeep),
    .arp_axis_mvalid(learn_mvalid), .arp_axis_mlast(learn_mlast), .arp_axis_musr(), .arp_axis_mready(learn_mready),
    .cfg_local_ip(L_IP_L), .cfg_local_mac(L_MAC_L), .cfg_gateway_ip(L_GW_L), .cfg_subnet_mask(L_MSK24),
    .cfg_pending_time(57'd16),
    .cfg_clear_cache(1'b0), .cfg_clear_pending(1'b0),
    .stat_rx_error(learn_stat_rx_error), .stat_ack_fifo_overflow_error(learn_stat_ack_ovf),
    .stat_pending_fifo_overflow_error(learn_stat_pend_ovf), .stat_lookup_no_resp_error(learn_stat_no_resp),
    .stat_pending_clear_finish(learn_stat_pend_clr), .stat_cache_clear_finish(learn_stat_cache_clr),
    .stat_query_src_not_local(learn_stat_src_bad)
  );

  always @(posedge clk) begin
    if (learn_mvalid && learn_mready) begin
      learn_cap_smac <= learn_mdata[95:48];
      learn_cap_oper <= learn_mdata[175:160];
      learn_cap_spa  <= learn_mdata[255:224];
      learn_cap_tpa  <= learn_mdata[335:304];
      learn_cap_cnt  <= learn_cap_cnt + 1;
    end
  end
  always @(posedge clk) if (learn_arp_valid) begin
    learn_resp_mac <= learn_arp_mac; learn_resp_miss <= learn_arp_miss;
  end

  task automatic learn_do_query(input [31:0] s, input [31:0] d);
    begin
      @(negedge clk);
      learn_q_src <= s; learn_q_dst <= d; learn_q_valid <= 1'b1;
      @(negedge clk);
      learn_q_valid <= 1'b0;
    end
  endtask

  task automatic learn_wait_resp(input integer maxc, output integer got);
    integer i;
    begin
      got = 0;
      for (i = 0; i < maxc && !got; i = i + 1) begin
        @(posedge clk);
        if (learn_arp_valid) got = 1;
      end
      @(posedge clk);
    end
  endtask

  task automatic learn_send_arp_rx(input [15:0] oper, input [31:0] spa,
                                   input [47:0] sha,  input [31:0] tpa);
    begin
      @(negedge clk);
      learn_sdata  <= {176'd0, tpa, 48'h0, spa, sha, oper, 8'h04, 8'h06,
                       16'h0008, 16'h0100, 16'h0608, sha, 48'hFFFF_FFFF_FFFF};
      learn_skeep  <= 64'h0000_03FF_FFFF_FFFF;
      learn_slast  <= 1'b1;
      learn_svalid <= 1'b1;
      @(posedge clk);
      while (!(learn_svalid && learn_sready)) @(posedge clk);
      @(negedge clk);
      learn_svalid <= 1'b0;
      learn_slast  <= 1'b0;
    end
  endtask

  task automatic learn_chk(input [255:0] name, input integer cond);
    begin
      if (!cond) begin $display("  [FAIL] %0s", name); learn_err = learn_err + 1; end
      else            $display("  [PASS] %0s", name);
    end
  endtask

  task automatic learn_chk48(input [255:0] name, input [47:0] got, input [47:0] exp);
    begin
      if (got !== exp) begin $display("  [FAIL] %0s : got=%h exp=%h", name, got, exp); learn_err = learn_err + 1; end
      else                   $display("  [PASS] %0s (%h)", name, got);
    end
  endtask

  // ==========================================================================
  // Phase 5 (shared) 信号: tb_arp_shared_table
  // ==========================================================================
  localparam [31:0] SH_A1  = 32'h0A01_A8C0; // 192.168.1.10
  localparam [31:0] SH_A2  = 32'h1401_A8C0; // 192.168.1.20
  localparam [31:0] SH_B1  = 32'h0A01_A8C0; // 192.168.1.10
  localparam [31:0] SH_B2  = 32'h0A00_000A; // 10.0.0.10
  localparam [31:0] SH_GWA = 32'h0101_A8C0; // 192.168.1.1
  localparam [31:0] SH_GWB = 32'h0100_000A; // 10.0.0.1
  localparam [31:0] SH_M24 = 32'h00FF_FFFF; // /24
  localparam [47:0] SH_MA1 = 48'h1111_0000_000A;
  localparam [47:0] SH_MA2 = 48'h2222_0000_0014;
  localparam [47:0] SH_MB1 = 48'h3333_0000_000A;
  localparam [47:0] SH_MB2 = 48'h4444_0000_000B;
  localparam [31:0] SH_H50 = 32'h3201_A8C0; // 192.168.1.50
  localparam [31:0] SH_H99 = 32'h6301_A8C0; // 192.168.1.99
  localparam [47:0] SH_MH50= 48'hAAAA_0000_0050;
  localparam [63:0] SH_KEEP_OK = 64'h0000_03FF_FFFF_FFFF;

  reg  [31:0] sha_q_src = 0, sha_q_dst = 0, shb_q_src = 0, shb_q_dst = 0;
  reg         sha_q_val = 0, shb_q_val = 0;
  wire [47:0] sha_mac, shb_mac;
  wire        sha_miss, shb_miss, sha_val, shb_val;
  reg  [AXIS_WIDTH-1:0] sha_sdata = 0, shb_sdata = 0;
  reg  [63:0]           sha_skeep = 0, shb_skeep = 0;
  reg                   sha_svalid = 0, sha_slast = 0, shb_svalid = 0, shb_slast = 0;
  wire                  sha_sready, shb_sready;
  wire [AXIS_WIDTH-1:0] sha_mdata, shb_mdata;
  wire [63:0]           sha_mkeep, shb_mkeep;
  wire                  sha_mvalid, sha_mlast, shb_mvalid, shb_mlast;
  reg                   sha_mready = 1'b1, shb_mready = 1'b1;
  wire sha_cache_clr, sha_pend_clr, shb_cache_clr, shb_pend_clr;
  wire sha_noresp, shb_noresp;

  integer sha_cap_cnt = 0, shb_cap_cnt = 0;
  reg [31:0] sha_cap_tpa = 0, shb_cap_tpa = 0;
  reg [31:0] sha_cap_spa = 0, shb_cap_spa = 0;
  reg [47:0] sha_rmac = 0, shb_rmac = 0;
  reg        sha_rmiss = 0, shb_rmiss = 0;

  // ---- DUT sha: 两个 IP 在同一二层域 ----
  arp_engine_top #(
    .AXIS_WIDTH(AXIS_WIDTH), .CACHE_DEEP(CACHE_DEEP), .PENDING_DEEP(PENDING_DEEP), .LOCAL_IP_NUM(2)
  ) u_dut_sha (
    .clk(clk), .rst(rst),
    .query_src_ip(sha_q_src), .query_dst_ip(sha_q_dst), .query_valid_pulse(sha_q_val),
    .arp_dst_mac(sha_mac), .arp_src_mac(), .arp_miss(sha_miss), .arp_valid(sha_val),
    .arp_axis_sdata(sha_sdata), .arp_axis_skeep(sha_skeep), .arp_axis_svalid(sha_svalid), .arp_axis_slast(sha_slast),
    .arp_axis_susr(1'b0), .arp_axis_sready(sha_sready), .arp_axis_mdata(sha_mdata), .arp_axis_mkeep(sha_mkeep),
    .arp_axis_mvalid(sha_mvalid), .arp_axis_mlast(sha_mlast), .arp_axis_musr(), .arp_axis_mready(sha_mready),
    .cfg_local_ip({SH_A2, SH_A1}),
    .cfg_local_mac({SH_MA2, SH_MA1}),
    .cfg_gateway_ip({SH_GWA, SH_GWA}),
    .cfg_subnet_mask({SH_M24, SH_M24}),
    .cfg_pending_time(57'd200),
    .cfg_clear_cache(1'b0), .cfg_clear_pending(1'b0),
    .stat_rx_error(), .stat_ack_fifo_overflow_error(), .stat_pending_fifo_overflow_error(),
    .stat_lookup_no_resp_error(sha_noresp),
    .stat_pending_clear_finish(sha_pend_clr), .stat_cache_clear_finish(sha_cache_clr),
    .stat_query_src_not_local()
  );

  // ---- DUT shb: 两个 IP 分属不同二层域/不同网关 ----
  arp_engine_top #(
    .AXIS_WIDTH(AXIS_WIDTH), .CACHE_DEEP(CACHE_DEEP), .PENDING_DEEP(PENDING_DEEP), .LOCAL_IP_NUM(2)
  ) u_dut_shb (
    .clk(clk), .rst(rst),
    .query_src_ip(shb_q_src), .query_dst_ip(shb_q_dst), .query_valid_pulse(shb_q_val),
    .arp_dst_mac(shb_mac), .arp_src_mac(), .arp_miss(shb_miss), .arp_valid(shb_val),
    .arp_axis_sdata(shb_sdata), .arp_axis_skeep(shb_skeep), .arp_axis_svalid(shb_svalid), .arp_axis_slast(shb_slast),
    .arp_axis_susr(1'b0), .arp_axis_sready(shb_sready), .arp_axis_mdata(shb_mdata), .arp_axis_mkeep(shb_mkeep),
    .arp_axis_mvalid(shb_mvalid), .arp_axis_mlast(shb_mlast), .arp_axis_musr(), .arp_axis_mready(shb_mready),
    .cfg_local_ip({SH_B2, SH_B1}),
    .cfg_local_mac({SH_MB2, SH_MB1}),
    .cfg_gateway_ip({SH_GWB, SH_GWA}),
    .cfg_subnet_mask({SH_M24, SH_M24}),
    .cfg_pending_time(57'd200),
    .cfg_clear_cache(1'b0), .cfg_clear_pending(1'b0),
    .stat_rx_error(), .stat_ack_fifo_overflow_error(), .stat_pending_fifo_overflow_error(),
    .stat_lookup_no_resp_error(shb_noresp),
    .stat_pending_clear_finish(shb_pend_clr), .stat_cache_clear_finish(shb_cache_clr),
    .stat_query_src_not_local()
  );

  always @(posedge clk) begin
    if (sha_mvalid && sha_mready) begin sha_cap_cnt <= sha_cap_cnt + 1; sha_cap_tpa <= sha_mdata[335:304]; sha_cap_spa <= sha_mdata[255:224]; end
    if (shb_mvalid && shb_mready) begin shb_cap_cnt <= shb_cap_cnt + 1; shb_cap_tpa <= shb_mdata[335:304]; shb_cap_spa <= shb_mdata[255:224]; end
  end
  always @(posedge clk) begin
    if (sha_val) begin sha_rmac <= sha_mac; sha_rmiss <= sha_miss; end
    if (shb_val) begin shb_rmac <= shb_mac; shb_rmiss <= shb_miss; end
  end

  task automatic sh_chk(input [255:0] name, input integer cond);
    begin
      if (!cond) begin $display("  [FAIL] %0s", name); sh_err = sh_err + 1; end
      else            $display("  [PASS] %0s", name);
    end
  endtask

  task automatic sh_qry_a(input [31:0] s, input [31:0] d);
    begin
      @(negedge clk); sha_q_src <= s; sha_q_dst <= d; sha_q_val <= 1'b1;
      @(negedge clk); sha_q_val <= 1'b0;
    end
  endtask
  task automatic sh_qry_b(input [31:0] s, input [31:0] d);
    begin
      @(negedge clk); shb_q_src <= s; shb_q_dst <= d; shb_q_val <= 1'b1;
      @(negedge clk); shb_q_val <= 1'b0;
    end
  endtask

  task automatic sh_wait_a(input integer n, output integer got);
    integer i;
    begin got = 0; for (i=0;i<n&&!got;i=i+1) begin @(posedge clk); if (sha_val) got=1; end @(posedge clk); end
  endtask
  task automatic sh_wait_b(input integer n, output integer got);
    integer i;
    begin got = 0; for (i=0;i<n&&!got;i=i+1) begin @(posedge clk); if (shb_val) got=1; end @(posedge clk); end
  endtask

  task automatic sh_rx_reply(input integer sel, input [31:0] spa, input [47:0] sha, input [31:0] tpa);
    begin
      @(negedge clk);
      if (sel == 0) begin
        sha_sdata <= {176'd0, tpa, 48'h0, spa, sha, 16'h0200, 8'h04, 8'h06,
                      16'h0008, 16'h0100, 16'h0608, sha, 48'hFFFF_FFFF_FFFF};
        sha_skeep <= SH_KEEP_OK; sha_slast <= 1'b1; sha_svalid <= 1'b1;
        @(posedge clk); while (!(sha_svalid && sha_sready)) @(posedge clk);
        @(negedge clk); sha_svalid <= 1'b0; sha_slast <= 1'b0;
      end else begin
        shb_sdata <= {176'd0, tpa, 48'h0, spa, sha, 16'h0200, 8'h04, 8'h06,
                      16'h0008, 16'h0100, 16'h0608, sha, 48'hFFFF_FFFF_FFFF};
        shb_skeep <= SH_KEEP_OK; shb_slast <= 1'b1; shb_svalid <= 1'b1;
        @(posedge clk); while (!(shb_svalid && shb_sready)) @(posedge clk);
        @(negedge clk); shb_svalid <= 1'b0; shb_slast <= 1'b0;
      end
    end
  endtask

  // ==========================================================================
  // Phase 1 (single) 主流程
  // ==========================================================================
  task automatic run_phase_single;
    integer ok;
    integer i;
    integer req_before;
    begin
      $display("");
      $display("================================================================");
      $display(" PHASE 1 : tb_arp_eth_top (主功能, 9 场景)");
      $display("================================================================");
      single_err = 0;
      single_cnt_tx_frame = 0; single_cnt_tx_req = 0; single_cnt_tx_rep = 0;
      single_last_req_tpa = 0; single_last_req_dest_mac = 0; single_last_rep_tpa = 0;
      single_dbg_en = 1'b0;

      single_query_dst_ip       = 32'd0;
      single_query_src_ip       = le32(L_IP);
      single_query_valid_pulse  = 1'b0;
      single_arp_axis_sdata     = {AXIS_WIDTH{1'b0}};
      single_arp_axis_skeep     = 64'd0;
      single_arp_axis_svalid    = 1'b0;
      single_arp_axis_slast     = 1'b0;
      single_arp_axis_mready    = 1'b1;
      single_cfg_local_ip       = le32(L_IP);
      single_cfg_local_mac      = le48(L_MAC);
      single_cfg_gateway_ip     = le32(GATEWAY);
      single_cfg_subnet_mask    = le32(MASK);
      single_cfg_pending_time   = 200;
      single_cfg_clear_cache    = 1'b0;
      single_cfg_clear_pending  = 1'b0;
      single_resp_seen          = 1'b0;

      // ---- 1. 等待清表完成 ----
      cyc(2);
      wait (u_dut_single.cache_clear_finish === 1'b1);
      wait (single_pending_clear_finish === 1'b1);
      $display("[%0t] [PASS] cache & pending clear finish", $time);

      // ---- 2. 收到 ARP 请求 -> 学习 + 应答 ----
      $display("--- TEST2: rx arp request -> learn + reply ---");
      single_send_arp(16'h0806, HOST_MAC, HOST_IP, HOST_MAC, 16'd1, 48'd0, L_IP, KEEP_OK);
      i = 0;
      while (single_cnt_tx_rep == 0 && i < 100) begin @(posedge clk); i = i + 1; end
      if (single_cnt_tx_rep != 1) begin
        $display("  [FAIL] expect 1 reply, got %0d", single_cnt_tx_rep); single_err = single_err + 1;
      end
      else if (single_last_rep_tpa !== le32(HOST_IP)) begin
        $display("  [FAIL] reply tpa=%08h expect %08h", single_last_rep_tpa, HOST_IP); single_err = single_err + 1;
      end
      else $display("  [PASS] reply to %08h", single_last_rep_tpa);
      single_drain(20);

      // ---- 3. 查询命中 ----
      $display("--- TEST3: query hit ---");
      single_do_query(le32(HOST_IP));
      single_wait_resp(100, ok);
      if (!ok) begin
        $display("  [FAIL] no arp_valid"); single_err = single_err + 1;
      end
      else if (single_resp_miss) begin
        $display("  [FAIL] expect hit, got miss"); single_err = single_err + 1;
      end
      else if (single_resp_mac !== le48(HOST_MAC)) begin
        $display("  [FAIL] mac=%012h expect %012h", single_resp_mac, HOST_MAC); single_err = single_err + 1;
      end
      else $display("  [PASS] hit mac=%012h", single_resp_mac);
      single_drain(20);

      // ---- 4. 查询未命中 -> 发请求 + 去重 ----
      $display("--- TEST4: query miss -> pending request + dedupe ---");
      single_drain(20);
      single_do_query(le32(32'h0A00_0009));
      single_wait_resp(100, ok);
      if (!ok || !single_resp_miss) begin
        $display("  [FAIL] expect miss resp (ok=%0d miss=%0b)", ok, single_resp_miss); single_err = single_err + 1;
      end
      single_wait_req(150, ok);
      if (!ok) begin
        $display("  [FAIL] no request generated"); single_err = single_err + 1;
      end
      else if (single_last_req_tpa !== le32(32'h0A00_0009)) begin
        $display("  [FAIL] req tpa=%08h expect 0a000009", single_last_req_tpa); single_err = single_err + 1;
      end
      else if (single_last_req_dest_mac !== 48'hFFFF_FFFF_FFFF) begin
        $display("  [FAIL] req dest_mac=%012h should be broadcast", single_last_req_dest_mac); single_err = single_err + 1;
      end
      else $display("  [PASS] request tpa=%08h dest=broadcast", single_last_req_tpa);

      // 时间窗内重复查询 -> 不应再发
      single_drain(20);
      req_before = single_cnt_tx_req;
      single_do_query(le32(32'h0A00_0009));
      single_wait_resp(100, ok);
      cyc(60);
      if (single_cnt_tx_req !== req_before) begin
        $display("  [FAIL] dedupe failed, extra req=%0d", single_cnt_tx_req - req_before); single_err = single_err + 1;
      end
      else $display("  [PASS] dedupe ok (no duplicate request within window)");
      single_drain(20);

      // ---- 5. 错误注入 ----
      $display("--- TEST5: error injection ---");
      single_send_arp(16'h0806, 48'hAAAA_0000_0002, 32'h0A00_0077, 48'hAAAA_0000_0002, 16'd1, 48'd0, L_IP, KEEP_BAD);
      cyc(5);
      if (single_stat_rx_error !== 1'b1) begin
        $display("  [FAIL] stat_rx_error not set by short frame"); single_err = single_err + 1;
      end
      else $display("  [PASS] stat_rx_error set by short frame");
      cyc(10);

      // ---- 5a. ARP 帧但 oper 非 1/2 ----
      single_drain(20);
      req_before = single_cnt_tx_rep;
      single_send_arp(16'h0806, 48'hBBBB_0000_0003, 32'h0A00_0078, 48'hBBBB_0000_0003, 16'd3, 48'd0, L_IP, KEEP_OK);
      cyc(30);
      if (single_cnt_tx_rep !== req_before) begin
        $display("  [FAIL] oper!=1/2 frame got a reply"); single_err = single_err + 1;
      end
      else $display("  [PASS] oper!=1/2 frame ignored (no reply)");
      single_do_query(le32(32'h0A00_0078));
      single_wait_resp(100, ok);
      if (ok && !single_resp_miss) begin
        $display("  [FAIL] oper!=1/2 frame was learned"); single_err = single_err + 1;
      end
      else $display("  [PASS] oper!=1/2 frame not learned");
      single_drain(20);

      // ---- 5b. 以太类型非 0x0806 (只记录实测行为, 不计 FAIL) ----
      single_drain(20);
      req_before = single_cnt_tx_rep;
      single_send_arp(16'h0800, 48'hBBBB_0000_0004, 32'h0A00_0079, 48'hBBBB_0000_0004, 16'd1, 48'd0, L_IP, KEEP_OK);
      cyc(30);
      single_do_query(le32(32'h0A00_0079));
      single_wait_resp(100, ok);
      $display("  [INFO] eth_type!=0x0806 实测: reply=%0d learned=%0b (arp_eth_rx 不校验以太类型)",
               (single_cnt_tx_rep !== req_before), (ok && !single_resp_miss));
      single_drain(20);

      // ---- 6. 本网段广播 ----
      $display("--- TEST6: broadcast addr ---");
      single_do_query(le32(32'h0A00_00FF));
      single_wait_resp(100, ok);
      if (!ok || single_resp_miss || single_resp_mac !== 48'hFFFF_FFFF_FFFF) begin
        $display("  [FAIL] broadcast: ok=%0d miss=%0b mac=%012h", ok, single_resp_miss, single_resp_mac); single_err = single_err + 1;
      end
      else $display("  [PASS] broadcast -> mac=ffffffffffff, miss=0");
      single_drain(20);

      // ---- 7. 跨网段 -> 查网关 ----
      $display("--- TEST7: cross subnet -> gateway ---");
      single_do_query(32'h0808_0808);
      single_wait_resp(100, ok);
      single_wait_req(150, ok);
      if (!ok) begin
        $display("  [FAIL] no request for cross-subnet query"); single_err = single_err + 1;
      end
      else if (single_last_req_tpa !== le32(GATEWAY)) begin
        $display("  [FAIL] expect tpa=gateway %08h, got %08h", GATEWAY, single_last_req_tpa); single_err = single_err + 1;
      end
      else $display("  [PASS] cross-subnet -> request gateway %08h", single_last_req_tpa);
      single_drain(20);

      // ---- 8. 下游反压 ----
      $display("--- TEST8: backpressure (frame must be held, not dropped) ---");
      single_set_mready(1'b0);
      cyc(5);
      req_before = single_cnt_tx_req;
      single_dbg_en = 1'b1;
      single_do_query(le32(32'h0A00_0021));
      single_wait_resp(100, ok);
      i = 0;
      while (!single_arp_axis_mvalid && i < 200) begin @(posedge clk); i = i + 1; end
      if (!single_arp_axis_mvalid) begin
        $display("  [FAIL] no frame presented on m axis"); single_err = single_err + 1;
      end
      else if (single_arp_axis_mdata[335:304] !== le32(32'h0A00_0021)) begin
        $display("  [FAIL] presented tpa=%08h expect 0a000021", single_arp_axis_mdata[335:304]); single_err = single_err + 1;
      end
      else $display("  [PASS] frame presented on m axis (tpa=%08h)", single_arp_axis_mdata[335:304]);
      cyc(40);
      if (!single_arp_axis_mvalid || single_arp_axis_mdata[335:304] !== le32(32'h0A00_0021)) begin
        $display("  [FAIL] frame changed/lost while backpressure (mvalid=%b tpa=%08h)",
                 single_arp_axis_mvalid, single_arp_axis_mdata[335:304]); single_err = single_err + 1;
      end
      else $display("  [PASS] frame held stable while mready=0");
      single_set_mready(1'b1);
      cyc(8);
      single_dbg_en = 1'b0;
      if (single_cnt_tx_req !== req_before + 1) begin
        $display("  [FAIL] expect exactly 1 request completed, got %0d", single_cnt_tx_req - req_before); single_err = single_err + 1;
      end
      else $display("  [PASS] exactly one request completed after release");
      single_drain(20);
      if (single_cnt_tx_req !== req_before + 1) begin
        $display("  [FAIL] duplicate after release, got %0d", single_cnt_tx_req - req_before); single_err = single_err + 1;
      end
      else $display("  [PASS] no duplicate after release");

      // ---- 9. ack FIFO 溢出 ----
      $display("--- TEST9: ack fifo overflow ---");
      if (single_stat_ack_fifo_overflow_error !== 1'b0) begin
        $display("  [FAIL] overflow flag already set"); single_err = single_err + 1;
      end
      single_set_mready(1'b0);
      for (i = 0; i < 90; i = i + 1) begin
        single_send_arp(16'h0806, 48'hCCCC_0000_0000 + i, 32'h0A01_0000 + i, 48'hCCCC_0000_0000 + i,
                        16'd1, 48'd0, L_IP, KEEP_OK);
      end
      cyc(10);
      if (single_stat_ack_fifo_overflow_error !== 1'b1) begin
        $display("  [FAIL] stat_ack_fifo_overflow_error not set"); single_err = single_err + 1;
      end
      else $display("  [PASS] stat_ack_fifo_overflow_error set (depth=64, pushed 90)");
      single_set_mready(1'b1);
      single_drain(30);
      $display("  [INFO] frames drained after release: %0d", single_cnt_tx_frame);

      // ---- 10. pending 清零完成 ----
      $display("--- TEST10: pending clear finish ---");
      single_cfg_clear_pending = 1'b1;
      cyc(3);
      if (single_pending_clear_finish !== 1'b0) begin
        $display("  [FAIL] pending_clear_finish should drop during clear"); single_err = single_err + 1;
      end
      else $display("  [PASS] pending_clear_finish=0 during clear");
      single_cfg_clear_pending = 1'b0;
      i = 0;
      while (single_pending_clear_finish !== 1'b1 && i < 200) begin @(posedge clk); i = i + 1; end
      if (single_pending_clear_finish !== 1'b1) begin
        $display("  [FAIL] pending_clear_finish did not rise"); single_err = single_err + 1;
      end
      else $display("  [PASS] pending_clear_finish rose after %0d cycles", i);
      cyc(10);

      // ---- 11. 正常流量下不应有误报 ----
      if (single_stat_lookup_no_resp_error !== 1'b0) begin
        $display("--- [FAIL] stat_lookup_no_resp_error unexpectedly set"); single_err = single_err + 1;
      end
      else $display("--- [PASS] stat_lookup_no_resp_error clean in normal traffic");

      cyc(50);
      $display("PHASE 1 tx frames: total=%0d req=%0d rep=%0d", single_cnt_tx_frame, single_cnt_tx_req, single_cnt_tx_rep);
      if (single_err == 0) $display("PHASE 1 (single) PASSED");
      else                 $display("PHASE 1 (single) %0d CHECK(S) FAILED", single_err);
    end
  endtask

  // ==========================================================================
  // Phase 2 (same) 主流程
  // ==========================================================================
  task automatic run_phase_same;
    integer i, ok;
    begin
      $display("");
      $display("================================================================");
      $display(" PHASE 2 : tb_arp_multi_ip / samesub (一口多 IP, 同子网双 IP)");
      $display("================================================================");
      same_err = 0;
      for (i = 0; i < 200 && !(same_stat_cache_clr && same_stat_pend_clr); i = i + 1) @(posedge clk);
      same_chk("cache/pending 清零完成", same_stat_cache_clr && same_stat_pend_clr);
      cyc(4);

      // ---- A : src = IP_A ----
      same_cap_cnt = 0;
      same_do_query(S_IP_A, S_DST1);
      same_wait_resp(40, ok);
      cyc(30);
      $display("  A: cap_cnt=%0d oper=%h spa=%h tpa=%h", same_cap_cnt, same_cap_oper, same_cap_spa, same_cap_tpa);
      same_chk("A 发出 ARP 请求",            same_cap_cnt >= 1);
      same_chk("A oper = request",          same_cap_oper === 16'h0100);
      same_chk("A SPA = IP_A(192.168.1.10)",same_cap_spa  === S_IP_A);
      same_chk("A TPA = DST1",              same_cap_tpa  === S_DST1);

      // ---- B : src = IP_B ----
      same_cap_cnt = 0;
      same_do_query(S_IP_B, S_DST2);
      same_wait_resp(40, ok);
      cyc(30);
      $display("  B: cap_cnt=%0d oper=%h spa=%h tpa=%h", same_cap_cnt, same_cap_oper, same_cap_spa, same_cap_tpa);
      same_chk("B 发出 ARP 请求",            same_cap_cnt >= 1);
      same_chk("B SPA = IP_B(192.168.1.20)",same_cap_spa  === S_IP_B);
      same_chk("B TPA = DST2",              same_cap_tpa  === S_DST2);

      // ---- C : src 非本地 -> 不发请求 ----
      same_cap_cnt = 0;
      same_do_query(S_IP_X, S_DST3);
      same_wait_resp(40, ok);
      $display("  C: ok=%0d arp_miss=%0b", ok, same_arp_miss);
      same_chk("C arp_valid 有结论",  ok === 1);
      same_chk("C arp_miss = 1",      same_arp_miss  === 1'b1);
      cyc(40);
      same_chk("C 未发出 ARP 请求",   same_cap_cnt === 0);

      // ---- D : 收到询问 IP_B 的 ARP request -> 应答 ----
      same_cap_cnt = 0;
      same_dbg = 1'b1;
      same_send_arp_rx(16'h0100, S_IP_X, S_IP_B);
      cyc(30);
      same_dbg = 1'b0;
      $display("  D: cap_cnt=%0d oper=%h spa=%h tpa=%h", same_cap_cnt, same_cap_oper, same_cap_spa, same_cap_tpa);
      same_chk("D 发出 ARP 应答",      same_cap_cnt >= 1);
      same_chk("D oper = reply",      same_cap_oper === 16'h0200);
      same_chk("D SPA = IP_B",        same_cap_spa  === S_IP_B);
      same_chk("D TPA = 请求者 IP",    same_cap_tpa  === S_IP_X);

      if (same_err == 0) $display("PHASE 2 (same) PASSED");
      else               $display("PHASE 2 (same) %0d CHECK(S) FAILED", same_err);
    end
  endtask

  // ==========================================================================
  // Phase 3 (cross) 主流程
  // ==========================================================================
  task automatic run_phase_cross;
    integer i, ok;
    begin
      $display("");
      $display("================================================================");
      $display(" PHASE 3 : tb_arp_multi_ip / crosssub (跨子网双 IP, 边界/流水线)");
      $display("================================================================");
      cross_err = 0;
      for (i = 0; i < 200 && !(cross_stat_cache_clr && cross_stat_pend_clr); i = i + 1) @(posedge clk);
      cross_chk("cache/pending 清零完成", cross_stat_cache_clr && cross_stat_pend_clr);
      cyc(4);

      // ---- 1 : 同网段 IP_A ----
      cross_cap_cnt = 0;
      cross_do_query(C_IP_A, C_H_A);
      cross_wait_resp(40, ok); cyc(30);
      $display(" 1: cnt=%0d oper=%h smac=%h spa=%h tpa=%h miss=%b",
               cross_cap_cnt, cross_cap_oper, cross_cap_smac, cross_cap_spa, cross_cap_tpa, cross_resp_miss);
      cross_chk  ("1 发出请求",            cross_cap_cnt >= 1);
      cross_chk32("1 SPA = IP_A",          cross_cap_spa,  C_IP_A);
      cross_chk32("1 TPA = 192.168.1.50",  cross_cap_tpa,  C_H_A);
      cross_chk  ("1 eth_src_mac = MAC_A", cross_cap_smac === C_MAC_A);

      // ---- 2 : 同网段 IP_B ----
      cross_cap_cnt = 0;
      cross_do_query(C_IP_B, C_H_B);
      cross_wait_resp(40, ok); cyc(30);
      $display(" 2: cnt=%0d oper=%h smac=%h spa=%h tpa=%h miss=%b",
               cross_cap_cnt, cross_cap_oper, cross_cap_smac, cross_cap_spa, cross_cap_tpa, cross_resp_miss);
      cross_chk  ("2 发出请求",            cross_cap_cnt >= 1);
      cross_chk32("2 SPA = IP_B",          cross_cap_spa,  C_IP_B);
      cross_chk32("2 TPA = 10.0.0.50",     cross_cap_tpa,  C_H_B);
      cross_chk  ("2 eth_src_mac = MAC_B", cross_cap_smac === C_MAC_B);

      // ---- 3 : 跨网段 IP_A -> 网关A ----
      cross_cap_cnt = 0;
      cross_do_query(C_IP_A, C_X1);
      cross_wait_resp(40, ok); cyc(30);
      $display(" 3: cnt=%0d oper=%h smac=%h spa=%h tpa=%h miss=%b",
               cross_cap_cnt, cross_cap_oper, cross_cap_smac, cross_cap_spa, cross_cap_tpa, cross_resp_miss);
      cross_chk  ("3 发出请求",            cross_cap_cnt >= 1);
      cross_chk32("3 SPA = IP_A",          cross_cap_spa,  C_IP_A);
      cross_chk32("3 TPA = 网关192.168.1.1", cross_cap_tpa, C_GW_A);

      // ---- 4 : 跨网段 IP_B -> 网关B ----
      cross_cap_cnt = 0;
      cross_do_query(C_IP_B, C_X2);
      cross_wait_resp(40, ok); cyc(30);
      $display(" 4: cnt=%0d oper=%h smac=%h spa=%h tpa=%h miss=%b",
               cross_cap_cnt, cross_cap_oper, cross_cap_smac, cross_cap_spa, cross_cap_tpa, cross_resp_miss);
      cross_chk  ("4 发出请求",            cross_cap_cnt >= 1);
      cross_chk32("4 SPA = IP_B",          cross_cap_spa,  C_IP_B);
      cross_chk32("4 TPA = 网关10.0.0.1",  cross_cap_tpa,  C_GW_B);

      // ---- 5 : 本网段广播 ----
      cross_cap_cnt = 0;
      cross_do_query(C_IP_A, C_BC_A);
      cross_wait_resp(40, ok); cyc(30);
      $display(" 5: cnt=%0d miss=%b mac=%h", cross_cap_cnt, cross_resp_miss, cross_resp_mac);
      cross_chk  ("5 广播不发 ARP 请求",  cross_cap_cnt === 0);
      cross_chk  ("5 广播 arp_miss = 0",  cross_resp_miss === 1'b0);
      cross_chk  ("5 广播 mac = ffffffffffff", cross_resp_mac === 48'hFFFF_FFFF_FFFF);

      // ---- 6 : 非本地源 IP ----
      cross_cap_cnt = 0;
      cross_do_query(C_IP_Z, C_X1);
      cross_wait_resp(40, ok); cyc(30);
      $display(" 6: cnt=%0d stat_src_not_local=%b", cross_cap_cnt, cross_stat_src_bad);
      cross_chk  ("6 不发 ARP 请求",              cross_cap_cnt === 0);
      cross_chk  ("6 stat_query_src_not_local=1", cross_stat_src_bad === 1'b1);

      // ---- 7 : 收到询问 IP_B 的 request -> 应答 ----
      cross_cap_cnt = 0;
      cross_send_arp_rx(16'h0100, C_IP_Z, C_IP_B);
      cyc(30);
      $display(" 7: cnt=%0d oper=%h smac=%h spa=%h tpa=%h", cross_cap_cnt, cross_cap_oper, cross_cap_smac, cross_cap_spa, cross_cap_tpa);
      cross_chk  ("7 发出应答",            cross_cap_cnt >= 1);
      cross_chk32("7 oper = reply",        cross_cap_oper, 16'h0200);
      cross_chk32("7 SPA = IP_B",          cross_cap_spa,  C_IP_B);
      cross_chk  ("7 eth_src_mac = MAC_B", cross_cap_smac === C_MAC_B);
      cross_chk32("7 TPA = 请求者IP",      cross_cap_tpa,  C_IP_Z);

      // ---- 8 : 先学到网关A的MAC, 再跨网段查询 -> 期望命中 ----
      cross_send_arp_rx(16'h0200, C_GW_A, C_IP_A);
      cyc(20);
      cross_cap_cnt = 0;
      cross_do_query(C_IP_A, C_X1);
      cross_wait_resp(40, ok); cyc(30);
      $display(" 8: cnt=%0d miss=%b mac=%h (网关MAC=111122223333)", cross_cap_cnt, cross_resp_miss, cross_resp_mac);
      cross_chk  ("8 跨网段命中缓存(miss=0)", cross_resp_miss === 1'b0);
      cross_chk  ("8 跨网段不再发请求",       cross_cap_cnt === 0);
      cross_chk  ("8 命中的MAC = 网关MAC",    cross_resp_mac === C_SHA_R);

      // ---- 9 : 决定性场景: 同一目的 IP, 换源 IP 改走另一个网关 ----
      cross_cap_cnt = 0;
      cross_do_query(C_IP_B, C_H_A);
      cross_wait_resp(40, ok); cyc(30);
      $display(" 9: cnt=%0d tpa=%h spa=%h smac=%h miss=%b", cross_cap_cnt, cross_cap_tpa, cross_cap_spa, cross_cap_smac, cross_resp_miss);
      cross_chk  ("9 src=IP_B 查 192.168.1.50 -> 判为跨网段(走网关B)", cross_cap_tpa === C_GW_B);
      cross_chk32("9 SPA = IP_B", cross_cap_spa, C_IP_B);
      cross_chk  ("9 SHA = MAC_B", cross_cap_smac === C_MAC_B);
      cross_cap_cnt = 0;
      cross_do_query(C_IP_A, C_H_A);
      cross_wait_resp(40, ok); cyc(30);
      $display(" 9b: cnt=%0d tpa=%h miss=%b", cross_cap_cnt, cross_cap_tpa, cross_resp_miss);
      cross_chk  ("9b src=IP_A 查同一目的 -> 判为同网段(直连)", cross_cap_tpa === C_H_A);

      if (cross_err == 0) $display("PHASE 3 (cross) PASSED");
      else                $display("PHASE 3 (cross) %0d CHECK(S) FAILED", cross_err);
    end
  endtask

  // ==========================================================================
  // Phase 4 (learn) 主流程
  // ==========================================================================
  task automatic run_phase_learn;
    integer i, ok;
    begin
      $display("");
      $display("================================================================");
      $display(" PHASE 4 : tb_arp_learn_policy (学习策略: 只学问到本机的)");
      $display("================================================================");
      learn_err = 0;
      for (i = 0; i < 200 && !(learn_stat_cache_clr && learn_stat_pend_clr); i = i + 1) @(posedge clk);
      learn_chk("cache/pending 清零完成", learn_stat_cache_clr && learn_stat_pend_clr);
      cyc(4);

      // ---- 1 : Request, TPA = 本机 -> 必须学习 + 应答 ----
      learn_cap_cnt = 0;
      learn_send_arp_rx(16'h0100, L_H1, L_MAC_H1, L_IP_L);
      cyc(30);
      $display(" 1: 收到问本机的 Request -> cnt=%0d oper=%h spa=%h tpa=%h", learn_cap_cnt, learn_cap_oper, learn_cap_spa, learn_cap_tpa);
      learn_chk  ("1 作出应答", learn_cap_cnt >= 1);
      learn_chk  ("1 oper = reply", learn_cap_oper === 16'h0200);
      learn_chk  ("1 应答 SPA = 本机IP", learn_cap_spa === L_IP_L);

      learn_cap_cnt = 0;
      learn_do_query(L_IP_L, L_H1);
      learn_wait_resp(40, ok); cyc(20);
      $display(" 1b: 查 %h -> miss=%b mac=%h", L_H1, learn_resp_miss, learn_resp_mac);
      learn_chk  ("1b 已学习(miss=0)", learn_resp_miss === 1'b0);
      learn_chk48("1b MAC = MAC_H1", learn_resp_mac, L_MAC_H1);
      learn_chk  ("1b 不再发请求", learn_cap_cnt === 0);

      // ---- 2 : Reply, TPA = 本机 -> 必须学习 ----
      learn_send_arp_rx(16'h0200, L_H2, L_MAC_H2, L_IP_L);
      cyc(20);
      learn_cap_cnt = 0;
      learn_do_query(L_IP_L, L_H2);
      learn_wait_resp(40, ok); cyc(20);
      $display(" 2: 收到发给本机的 Reply -> miss=%b mac=%h", learn_resp_miss, learn_resp_mac);
      learn_chk  ("2 已学习(miss=0)", learn_resp_miss === 1'b0);
      learn_chk48("2 MAC = MAC_H2", learn_resp_mac, L_MAC_H2);

      // ---- 3 : Request, TPA = 别人 -> 不得学习 ----
      learn_cap_cnt = 0;
      learn_send_arp_rx(16'h0100, L_H3, L_MAC_H3, L_OTH);
      cyc(30);
      $display(" 3: 收到第三方 Request -> 本端 TX cnt=%0d (应=0, 不是问本机)", learn_cap_cnt);
      learn_chk  ("3 不对第三方请求作应答", learn_cap_cnt === 0);

      learn_cap_cnt = 0;
      learn_do_query(L_IP_L, L_H3);
      learn_wait_resp(40, ok); cyc(20);
      $display(" 3b: 查 H3 -> miss=%b (应=1: 第三方未被学习)", learn_resp_miss);
      learn_chk  ("3b 第三方未被学习(miss=1)", learn_resp_miss === 1'b1);
      learn_chk  ("3b 已发出查询 H3 的 ARP 请求", learn_cap_cnt >= 1);
      learn_chk  ("3b 请求 TPA = H3", learn_cap_tpa === L_H3);

      // ---- 4 : Gratuitous ARP -> 不得学习 ----
      learn_send_arp_rx(16'h0100, L_H3, L_MAC_NEW, L_H3);
      cyc(20);
      learn_cap_cnt = 0;
      learn_do_query(L_IP_L, L_H3);
      learn_wait_resp(40, ok); cyc(20);
      $display(" 4: 第三方 GARP 之后查 H3 -> miss=%b (应=1)", learn_resp_miss);
      learn_chk  ("4 第三方 GARP 不被学习(miss=1)", learn_resp_miss === 1'b1);

      // ---- 5 : Reply, TPA = 别人 -> 不得学习 ----
      learn_send_arp_rx(16'h0200, L_OTH, L_MAC_H3, L_OTH);
      cyc(20);
      learn_cap_cnt = 0;
      learn_do_query(L_IP_L, L_OTH);
      learn_wait_resp(40, ok); cyc(20);
      $display(" 5: 发给别人的 Reply 之后查 OTH -> miss=%b (应=1)", learn_resp_miss);
      learn_chk  ("5 第三方 Reply 不被学习(miss=1)", learn_resp_miss === 1'b1);

      // ---- 6 : 非本地源 IP 查询 ----
      learn_cap_cnt = 0;
      learn_do_query(L_IP_Z, L_H1);
      learn_wait_resp(40, ok); cyc(20);
      $display(" 6: src=非本地 -> cnt=%0d stat_src_not_local=%b", learn_cap_cnt, learn_stat_src_bad);
      learn_chk  ("6 不发 ARP 请求",              learn_cap_cnt === 0);
      learn_chk  ("6 stat_query_src_not_local=1", learn_stat_src_bad === 1'b1);

      // ---- 7 : 已学到的表项仍然可用(回归) ----
      learn_cap_cnt = 0;
      learn_do_query(L_IP_L, L_H1);
      learn_wait_resp(40, ok); cyc(20);
      learn_chk  ("7 已学表项仍命中(miss=0)", learn_resp_miss === 1'b0);
      learn_chk48("7 MAC 仍为 MAC_H1", learn_resp_mac, L_MAC_H1);

      if (learn_err == 0) $display("PHASE 4 (learn) PASSED");
      else                $display("PHASE 4 (learn) %0d CHECK(S) FAILED", learn_err);
    end
  endtask

  // ==========================================================================
  // Phase 5 (shared) 主流程
  // ==========================================================================
  task automatic run_phase_shared;
    integer i, ok;
    begin
      $display("");
      $display("================================================================");
      $display(" PHASE 5 : tb_arp_shared_table (多 IP 共享 ARP/pending 表)");
      $display("================================================================");
      sh_err = 0;
      for (i = 0; i < 200 && !(sha_cache_clr && sha_pend_clr && shb_cache_clr && shb_pend_clr); i = i + 1) @(posedge clk);
      sh_chk("两实例 cache/pending 清零完成", sha_cache_clr && sha_pend_clr && shb_cache_clr && shb_pend_clr);
      cyc(6);

      $display("--- DUT sha: 两个 IP 在同一二层域 (192.168.1.10 / .20, GW 都是 .1) ---");
      sh_rx_reply(0, SH_H50, SH_MH50, SH_A1);
      cyc(30);
      sha_cap_cnt = 0;
      sh_qry_a(SH_A1, SH_H50); sh_wait_a(40, ok); cyc(10);
      $display(" 1) src=IP_A 查 H50 -> miss=%b mac=%h", sha_rmiss, sha_rmac);
      sh_chk("1) IP_A 命中(miss=0)", sha_rmiss === 1'b0);

      sha_cap_cnt = 0;
      sh_qry_a(SH_A2, SH_H50); sh_wait_a(40, ok); cyc(10);
      $display(" 2) src=IP_B 查同一个 H50 -> miss=%b mac=%h cnt=%0d", sha_rmiss, sha_rmac, sha_cap_cnt);
      sh_chk("2) IP_B 也命中同一表项(表是共享的)", sha_rmiss === 1'b0);
      sh_chk("2) IP_B 拿到的 MAC 与 IP_A 相同(同二层域下正确)", sha_rmac === SH_MH50);
      sh_chk("2) 未再发 ARP 请求(省一次广播)", sha_cap_cnt === 0);

      sha_cap_cnt = 0;
      sh_qry_a(SH_A1, SH_H99);
      sh_wait_a(40, ok);
      cyc(80);
      $display(" 3) src=IP_A 查 H99 -> 发请求 TPA=%h SPA=%h cnt=%0d", sha_cap_tpa, sha_cap_spa, sha_cap_cnt);
      sh_chk("3) IP_A 发出了针对 H99 的请求", sha_cap_cnt >= 1);
      sh_chk("3) 请求 SPA = IP_A", sha_cap_spa === SH_A1);
      sha_cap_cnt = 0;
      sh_qry_a(SH_A2, SH_H99); sh_wait_a(40, ok); cyc(80);
      $display(" 4) src=IP_B 紧接着查 H99 -> 新增请求 cnt=%0d (pending 去重则=0)", sha_cap_cnt);
      sh_chk("4) pending 表同样被共享 => 不重复广播", sha_cap_cnt === 0);

      $display("--- DUT shb: 两个 IP 分属不同二层域 (192.168.1.10/GW.1.1 与 10.0.0.10/GW10.0.0.1) ---");
      shb_cap_cnt = 0;
      sh_qry_b(SH_B1, SH_H50);
      sh_wait_b(40, ok); cyc(30);
      $display(" 5) src=192.168.1.10 查 192.168.1.50 -> TPA=%h SPA=%h", shb_cap_tpa, shb_cap_spa);
      sh_chk("5) 同网段: 直接查 dst 本身", shb_cap_tpa === SH_H50);
      sh_chk("5) SPA = 192.168.1.10", shb_cap_spa === SH_B1);

      shb_cap_cnt = 0;
      sh_qry_b(SH_B2, SH_H50);
      sh_wait_b(40, ok); cyc(30);
      $display(" 6) src=10.0.0.10 查同一个 192.168.1.50 -> TPA=%h SPA=%h", shb_cap_tpa, shb_cap_spa);
      sh_chk("6) 跨网段: 查的是自己的网关 10.0.0.1", shb_cap_tpa === SH_GWB);
      sh_chk("6) SPA = 10.0.0.10", shb_cap_spa === SH_B2);
      sh_chk("6) 与 5) 的 cache key 不同 => 不会串扰", (shb_cap_tpa !== SH_H50));

      $display("--- 结论 ---");
      $display("  [INFO] DUT sha(同二层域): 表共享 => 命中同一表项, 不重复广播, 行为正确");
      $display("  [INFO] DUT shb(不同二层域): 解析后 key 分别是 dst / 自己的网关 => 天然不撞");
      $display("  [INFO] M-F 真正发作的唯一条件: 同一物理口跑 802.1Q 多 VLAN,");
      $display("         各 VLAN 用相同私有地址段, 且 RTL 里没有 vid 参与 key");

      if (sh_err == 0) $display("PHASE 5 (shared) PASSED");
      else             $display("PHASE 5 (shared) %0d CHECK(S) FAILED", sh_err);
    end
  endtask

  // ==========================================================================
  // Phase 6 (probe) 主流程: tb_arp_p3_probe (复用 u_dut_cross, 不判定)
  // ==========================================================================
  localparam [31:0] P_OTH1 = 32'h5801_A8C0; // 192.168.1.88
  localparam [47:0] P_MAC_Z= 48'hAAAA_BBBB_CCCC;

  task automatic probe_do_query(input [31:0] s, input [31:0] d);
    begin @(negedge clk); cross_q_src<=s; cross_q_dst<=d; cross_q_valid<=1'b1; @(negedge clk); cross_q_valid<=1'b0; end
  endtask

  task automatic probe_send_arp_rx(input [15:0] oper, input [31:0] spa, input [47:0] sha, input [31:0] tpa);
    begin
      @(negedge clk);
      cross_sdata  <= {176'd0, tpa, 48'h0, spa, sha, oper, 8'h04, 8'h06,
                       16'h0008, 16'h0100, 16'h0608, sha, 48'hFFFF_FFFF_FFFF};
      cross_skeep  <= 64'h0000_03FF_FFFF_FFFF; cross_slast <= 1'b1; cross_svalid <= 1'b1;
      @(posedge clk); while (!(cross_svalid && cross_sready)) @(posedge clk);
      @(negedge clk); cross_svalid <= 1'b0; cross_slast <= 1'b0;
    end
  endtask

  task automatic probe_tap(input [8*24:1] tag);
    begin
      @(negedge clk);
      cross_q_valid <= 1'b1;
      @(posedge clk);   // T0
      $display("   %0s T0: qvalid=%b match_q=%b gw_comb=%h msk_comb=%h",
               tag, u_dut_cross.query_valid_pulse, u_dut_cross.match_query_comb,
               u_dut_cross.match_gateway_ip_comb, u_dut_cross.match_subnet_comb);
      @(posedge clk);   // T1
      $display("   %0s T1: cq_valid=%b(out_subnet判定需等到T2)  cq_ip=%h",
               tag, u_dut_cross.cache_query_valid_pulse, u_dut_cross.cache_query_ip);
      @(posedge clk);   // T2
      $display("   %0s T2: is_out_subnet_s2=%b   <- P3 关注点", tag, u_dut_cross.is_out_subnet_s2);
      @(posedge clk);   // T3
      $display("   %0s T3: is_broadcast_addr_s3=%b <- P3 关注点", tag, u_dut_cross.is_broadcast_addr_s3);
      cross_q_valid <= 1'b0;
      cyc(12);
    end
  endtask

  task automatic run_phase_probe;
    integer i;
    begin
      $display("");
      $display("================================================================");
      $display(" PHASE 6 : tb_arp_p3_probe (诊断探针, 不参与 PASS/FAIL 计数)");
      $display("================================================================");
      // 复位 cross 实例以得到干净的探针输出
      rst = 1'b1; cyc(5); rst = 1'b0;
      for (i = 0; i < 200 && !(cross_stat_cache_clr && cross_stat_pend_clr); i = i + 1) @(posedge clk);
      cyc(4);

      $display("--- A1: src=本地IP_A, dst=8.8.8.8 (真的跨网段) ---");
      cross_q_src = C_IP_A; cross_q_dst = C_X1;  probe_tap("A1");

      $display("--- A2: src=非本地IP_Z, dst=8.8.8.8 (同样跨网段, 但源IP没命中) ---");
      cross_q_src = C_IP_Z; cross_q_dst = C_X1;  probe_tap("A2");

      $display("--- B1: src=本地IP_A, dst=192.168.1.255 (本网段广播) ---");
      cross_q_src = C_IP_A; cross_q_dst = C_BC_A; probe_tap("B1");

      $display("--- B2: src=非本地IP_Z, dst=192.168.1.255 (同样广播, 但源IP没命中) ---");
      cross_q_src = C_IP_Z; cross_q_dst = C_BC_A; probe_tap("B2");

      $display("--- C: 学习不区分本地IP ---");
      $display("  收到 'who has 10.0.0.77 tell 192.168.1.88' (TPA=10.0.0.77 不是我的任何IP)");
      probe_send_arp_rx(16'h0100, P_OTH1, P_MAC_Z, 32'h4D00_000A);
      cyc(6);
      $display("  write_valid_pulse_reg=%b  write_ip=%h  write_mac=%h",
               u_dut_cross.write_valid_pulse_reg, u_dut_cross.write_ip_reg, u_dut_cross.write_mac_reg);
      cyc(20);
      $display("  现在查询 192.168.1.88 (一个我从没主动联系过的主机):");
      cross_q_src = C_IP_A; cross_q_dst = P_OTH1;
      @(negedge clk); cross_q_valid<=1'b1; @(negedge clk); cross_q_valid<=1'b0;
      for (i=0;i<40;i=i+1) begin @(posedge clk); if (cross_arp_valid) i=100; end
      @(posedge clk);
      $display("  -> arp_valid结果: miss=%b mac=%h  %s",
               cross_arp_miss, cross_arp_mac, cross_arp_miss ? "(未命中)" : "(命中! 说明刚才旁听到的ARP被学进cache了)");

      $display("=== probe done ===");
    end
  endtask

  // ==========================================================================
  // 主流程
  // ==========================================================================
  initial begin
    $display("================================================================");
    $display(" tb_arp_engine_top : 合并回归测试台启动");
    $display("================================================================");

    // 全局复位
    rst = 1'b1;
    cyc(10);
    rst = 1'b0;

    run_phase_single();
    run_phase_same();
    run_phase_cross();
    run_phase_learn();
    run_phase_shared();
    run_phase_probe();

    // ---- 汇总 ----
    $display("");
    $display("================================================================");
    $display(" 汇总 (probe 不计入):");
    $display("   Phase1 single : %0d check(s) failed", single_err);
    $display("   Phase2 same   : %0d check(s) failed", same_err);
    $display("   Phase3 cross  : %0d check(s) failed", cross_err);
    $display("   Phase4 learn  : %0d check(s) failed", learn_err);
    $display("   Phase5 shared : %0d check(s) failed", sh_err);
    $display("================================================================");
    if (single_err == 0 && same_err == 0 && cross_err == 0 && learn_err == 0 && sh_err == 0)
      $display(" *** ALL TESTS PASSED ***");
    else
      $display(" *** %0d CHECK(S) FAILED ***",
               single_err + same_err + cross_err + learn_err + sh_err);
    $display("================================================================");
    $finish;
  end

  // 全局看门狗
  initial begin
    #20_000_000;
    $display("[%0t] FATAL: global timeout", $time);
    $finish;
  end

endmodule
`resetall
