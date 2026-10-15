`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : tb_ipv4_top.v
// Module Name : tb_ipv4_top   (单 module 链式测试台)
// Author      : LiXintao
// Date        : 2026-09-19 / 2026-10-15 接口适配(packed demux/mux + by_val usr)
//               / 2026-10-15 合并: tb_ipv4_top(loopback+arp_after_traffic)
//                              + tb_ipv4_chain + tb_ipv4_dual_flow => 本文件
// Version     : v5.0
// ----------------------------------------------------------------------------
// Description : 测同一链路(ipv4_top)的 4 个场景合并成单个 module, 顺序 phase 执行:
//
//   PHASE 1 loopback       200MHz 单 IP 自环 (ARP 自解析 / 反压 / 长跑)
//   PHASE 2 after_traffic  400MHz 双 IP + 外部 ARP/TCP 注入 ("打流后 ARP 仍须应答")
//   PHASE 3 chain          200MHz <-> ~322MHz 两个异步 FIFO 跨时钟域 + 停流排空
//   PHASE 4 dual_flow      双网口直连 (两个 ipv4_top 对接): P1 打流 -> P2 应答 -> 数据直达
//
//   每个 phase 各自带完整 DUT/时钟/激励, 时钟按各自频率独立生成, 互不影响;
//   phase 之间顺序执行(各自的 rst 在该 phase 开始前才释放), 末尾统一汇总累计 err。
//
// 接口统一(packed / usr)约定:
//   eth_type_demux : TYPE_NUM=2, TYPE_DICT={16'h0608,16'h0008}
//                    => ch0=ipv4 / ch1=arp / ch2=other 兜底
//   eth_tx_mux     : TYPE_NUM=2 => lane[0]=arp(usr=ARP_PRIORITY 15) lane[1]=ipv4(usr=8)
//   ipv4_top       : RX flat 5 路(档0=UDP -> tester RX, 其余 mready 恒 1 丢弃)
//                    TX flat 1 路(tester 接入)
//   打流机         : .AXIS_USER_VAL(TESTER_USR=4'd8), 必须非 0 才能过 by_val 仲裁
//
// Note: 1. helper 模块 axis_reg_slice 全文件仅保留一份(放文件末尾)
//       2. 合并后 tb_ipv4_chain.v / tb_ipv4_dual_flow.v 已删除
// ============================================================================
module tb_ipv4_top;

  // ---------------- 公共参数(四个 phase 一致) ----------------
  localparam AW = 512;
  localparam UW = 4  ;                   // AXIS_USER_WIDTH: by_val 仲裁优先级位宽
  localparam [UW-1:0] TESTER_USR = 4'd8; // 打流机 usr(过 by_val 仲裁须非 0)
  localparam [15:0] ETH_ARP  = 16'h0608; // 线上字节顺序: 0x08,0x06 => 16'h0608
  localparam [15:0] ETH_IPV4 = 16'h0008; // 0x08,0x00 => 16'h0008

  // ---------------- 全局累计错误 ----------------
  integer g_err;

  // ============================================================================
  // PHASE 1 : loopback   (原 sub_ipv4_top_loopback)
  // 200MHz 单 IP 自环: 纯 IPv4 打流 -> 插头 -> 剥头 -> 校验, + 反压 + 长跑
  // ============================================================================
  localparam [31:0] loop_CFG_LOCAL_IP  = 32'h0201_A8C0;   // 192.168.1.2
  localparam [47:0] loop_CFG_LOCAL_MAC = 48'h554433221100;
  localparam [31:0] loop_CFG_GW_IP     = 32'h0101_A8C0;   // 192.168.1.1
  localparam [31:0] loop_CFG_SUBNET    = 32'h00FF_FFFF;   // /24
  localparam [56:0] loop_CFG_PEND_TIME = 57'd20_000;      // 100us @200MHz
  localparam integer loop_PKT_BEATS    = 4;               // 纯 IPv4 包 = 4*64 = 256 字节

  reg loop_clk = 1'b0;
  always #2.5 loop_clk = ~loop_clk;              // 200MHz
  reg loop_rst = 1'b1;

  // 连线
  wire [AW-1:0]   loop_tst_tx_data ;  wire [AW/8-1:0] loop_tst_tx_keep ;
  wire            loop_tst_tx_last ;  wire            loop_tst_tx_valid;
  wire [UW-1:0]   loop_tst_tx_user ;  wire            loop_tst_tx_ready;

  wire [AW-1:0]   loop_p_tx_data   ;  wire [AW/8-1:0] loop_p_tx_keep   ;
  wire            loop_p_tx_last   ;  wire            loop_p_tx_valid  ;
  wire [UW-1:0]   loop_p_tx_usr    ;  wire            loop_p_tx_ready  ;

  wire [AW-1:0]   loop_a_tx_data   ;  wire [AW/8-1:0] loop_a_tx_keep   ;
  wire            loop_a_tx_last   ;  wire            loop_a_tx_valid  ;
  wire [UW-1:0]   loop_a_tx_usr    ;  wire            loop_a_tx_ready  ;

  wire [AW*2-1:0]   loop_mx_sdata = {loop_p_tx_data , loop_a_tx_data };
  wire [AW/8*2-1:0] loop_mx_skeep = {loop_p_tx_keep , loop_a_tx_keep };
  wire [1:0]        loop_mx_slast = {loop_p_tx_last , loop_a_tx_last };
  wire [1:0]        loop_mx_svalid= {loop_p_tx_valid, loop_a_tx_valid};
  wire [UW*2-1:0]   loop_mx_susr  = {loop_p_tx_usr  , loop_a_tx_usr  };
  wire [1:0]        loop_mx_sready;
  assign {loop_p_tx_ready, loop_a_tx_ready} = loop_mx_sready;

  wire [AW-1:0]   loop_mx_data     ;  wire [AW/8-1:0] loop_mx_keep     ;
  wire            loop_mx_last     ;  wire            loop_mx_valid    ;  wire loop_mx_ready;
  wire [UW-1:0]   loop_mx_user     ;

  wire [AW-1:0]   loop_pd_data     ;  wire [AW/8-1:0] loop_pd_keep     ;
  wire            loop_pd_last     ;  wire            loop_pd_valid    ;  wire loop_pd_ready;

  wire [AW-1:0]   loop_lb_data     ;  wire [AW/8-1:0] loop_lb_keep     ;
  wire            loop_lb_last     ;  wire            loop_lb_valid    ;  wire loop_lb_ready;

  wire [AW*3-1:0]   loop_dm_mdata;
  wire [AW/8*3-1:0] loop_dm_mkeep;
  wire [2:0]        loop_dm_mlast, loop_dm_mvalid, loop_dm_musr;
  wire [2:0]        loop_dm_mready;

  wire [AW-1:0]   loop_dm_ipv4_data  = loop_dm_mdata[0*AW +: AW];
  wire [AW/8-1:0] loop_dm_ipv4_keep  = loop_dm_mkeep[0*(AW/8) +: AW/8];
  wire            loop_dm_ipv4_last  = loop_dm_mlast[0];
  wire            loop_dm_ipv4_valid = loop_dm_mvalid[0];
  wire [AW-1:0]   loop_dm_arp_data   = loop_dm_mdata[1*AW +: AW];
  wire [AW/8-1:0] loop_dm_arp_keep   = loop_dm_mkeep[1*(AW/8) +: AW/8];
  wire            loop_dm_arp_last   = loop_dm_mlast[1];
  wire            loop_dm_arp_valid  = loop_dm_mvalid[1];
  wire            loop_dm_ipv4_ready, loop_dm_arp_ready;
  assign loop_dm_mready = {1'b1, loop_dm_arp_ready, loop_dm_ipv4_ready};   // ch2 other 恒 ready(丢弃)

  wire [AW*5-1:0]   loop_rxflat_mdata;
  wire [AW/8*5-1:0] loop_rxflat_mkeep;
  wire [4:0]        loop_rxflat_mlast, loop_rxflat_mvalid;
  wire [97*5-1:0]   loop_rxflat_musr ;
  wire [4:0]        loop_rxflat_mready;
  wire [AW-1:0]     loop_p_rx_data   = loop_rxflat_mdata[0*AW +: AW];
  wire [AW/8-1:0]   loop_p_rx_keep   = loop_rxflat_mkeep[0*(AW/8) +: AW/8];
  wire              loop_p_rx_last   = loop_rxflat_mlast[0];
  wire              loop_p_rx_valid  = loop_rxflat_mvalid[0];
  wire              loop_p_rx_ready;
  assign loop_rxflat_mready = {4'b1111, loop_p_rx_ready};

  wire [31:0]     loop_q_ip        ;  wire            loop_q_valid_pulse;
  wire [31:0]     loop_q_src_ip    ;
  wire [47:0]     loop_r_mac       ;  wire [47:0]     loop_r_src_mac;
  wire            loop_r_miss      ;  wire            loop_r_valid     ;

  wire            loop_stat_rx_error, loop_stat_ack_ovf, loop_stat_pend_ovf, loop_stat_no_resp;
  wire            loop_stat_pend_clr_fin, loop_stat_cache_clr_fin;
  wire            loop_stat_arb_port;
  wire            loop_stat_arb_idle;

  reg  [47:0]     loop_resp_mac = 48'd0;
  always @(posedge loop_clk) if (loop_r_valid) loop_resp_mac <= loop_r_mac;

  // 环回 slice : 补齐后的帧 -> (1拍寄存) -> demux
  axis_reg_slice #(.W(AW)) u_loop_eth_loop (
    .clk(loop_clk), .rst(loop_rst),
    .sdata(loop_pd_data), .skeep(loop_pd_keep), .slast(loop_pd_last),
    .svalid(loop_pd_valid), .sready(loop_pd_ready),
    .mdata(loop_lb_data), .mkeep(loop_lb_keep), .mlast(loop_lb_last),
    .mvalid(loop_lb_valid), .mready(loop_lb_ready)
  );

  eth_type_demux #(
    .TYPE_NUM            (2                  ),
    .TYPE_DICT           ({16'h0608,16'h0008})
  ) u_loop_demux (
    .clk                 (loop_clk            ),
    .rst                 (loop_rst            ),
    .eth_axis_sdata      (loop_lb_data        ),
    .eth_axis_skeep      (loop_lb_keep        ),
    .eth_axis_slast      (loop_lb_last        ),
    .eth_axis_svalid     (loop_lb_valid       ),
    .eth_axis_susr       (1'b0                ),
    .eth_axis_sready     (loop_lb_ready       ),
    .eth_axis_mdata      (loop_dm_mdata       ),
    .eth_axis_mkeep      (loop_dm_mkeep       ),
    .eth_axis_mlast      (loop_dm_mlast       ),
    .eth_axis_mvalid     (loop_dm_mvalid      ),
    .eth_axis_musr       (loop_dm_musr        ),
    .eth_axis_mready     (loop_dm_mready      )
  );

  eth_tx_mux #(
    .TYPE_NUM         (2                ),
    .AXIS_USER_WIDTH  (UW               )
  ) u_loop_tx_mux (
    .clk              (loop_clk              ),
    .rst              (loop_rst              ),
    .eth_axis_sdata   (loop_mx_sdata         ),
    .eth_axis_skeep   (loop_mx_skeep         ),
    .eth_axis_slast   (loop_mx_slast         ),
    .eth_axis_svalid  (loop_mx_svalid        ),
    .eth_axis_susr    (loop_mx_susr          ),
    .eth_axis_sready  (loop_mx_sready        ),
    .eth_axis_mdata   (loop_mx_data          ),
    .eth_axis_mkeep   (loop_mx_keep          ),
    .eth_axis_mlast   (loop_mx_last          ),
    .eth_axis_mvalid  (loop_mx_valid         ),
    .eth_axis_musr    (loop_mx_user          ),
    .eth_axis_mready  (loop_mx_ready         ),
    .stat_active_port (loop_stat_arb_port    ),
    .stat_idle        (loop_stat_arb_idle    )
  );

  eth_frame_pad60 #(
    .MIN_FRAME_BYTES  (60               )
  ) u_loop_frame_pad (
    .clk              (loop_clk              ),
    .rst              (loop_rst              ),
    .eth_axis_sdata   (loop_mx_data          ),
    .eth_axis_skeep   (loop_mx_keep          ),
    .eth_axis_slast   (loop_mx_last          ),
    .eth_axis_svalid  (loop_mx_valid         ),
    .eth_axis_sready  (loop_mx_ready         ),
    .eth_axis_mdata   (loop_pd_data          ),
    .eth_axis_mkeep   (loop_pd_keep          ),
    .eth_axis_mlast   (loop_pd_last          ),
    .eth_axis_mvalid  (loop_pd_valid         ),
    .eth_axis_mready  (loop_pd_ready         )
  );

  ipv4_top #(
    .RX_TYPE_NUM      (4                ),
    .TX_TYPE_NUM      (1                ),
    .AXIS_USER_WIDTH  (UW               )
  ) u_loop_dut (
    .clk                 (loop_clk              ),
    .rst                 (loop_rst              ),
    .eth_ipv4_axis_sdata (loop_dm_ipv4_data     ),
    .eth_ipv4_axis_skeep (loop_dm_ipv4_keep     ),
    .eth_ipv4_axis_slast (loop_dm_ipv4_last     ),
    .eth_ipv4_axis_svalid(loop_dm_ipv4_valid    ),
    .eth_ipv4_axis_susr  (1'b0                  ),
    .eth_ipv4_axis_sready(loop_dm_ipv4_ready    ),
    .ipv4_axis_mdata     (loop_rxflat_mdata     ),
    .ipv4_axis_mkeep     (loop_rxflat_mkeep     ),
    .ipv4_axis_mlast     (loop_rxflat_mlast     ),
    .ipv4_axis_mvalid    (loop_rxflat_mvalid    ),
    .ipv4_axis_musr      (loop_rxflat_musr      ),
    .ipv4_axis_mready    (loop_rxflat_mready    ),
    .ipv4_axis_sdata     (loop_tst_tx_data      ),
    .ipv4_axis_skeep     (loop_tst_tx_keep      ),
    .ipv4_axis_slast     (loop_tst_tx_last      ),
    .ipv4_axis_svalid    (loop_tst_tx_valid     ),
    .ipv4_axis_susr      (loop_tst_tx_user      ),
    .ipv4_axis_sready    (loop_tst_tx_ready     ),
    .eth_tx_axis_mdata   (loop_p_tx_data        ),
    .eth_tx_axis_mkeep   (loop_p_tx_keep        ),
    .eth_tx_axis_mlast   (loop_p_tx_last        ),
    .eth_tx_axis_mvalid  (loop_p_tx_valid       ),
    .eth_tx_axis_musr    (loop_p_tx_usr         ),
    .eth_tx_axis_mready  (loop_p_tx_ready       ),
    .query_src_ip        (loop_q_src_ip         ),
    .query_dst_ip        (loop_q_ip             ),
    .query_valid_pulse   (loop_q_valid_pulse    ),
    .arp_dst_mac         (loop_r_mac            ),
    .arp_src_mac         (loop_r_src_mac        ),
    .arp_miss            (loop_r_miss           ),
    .arp_valid           (loop_r_valid          ),
    .stat_tx_active_port (                      ),
    .stat_tx_idle        (                      )
  );

  arp_engine_top #(
    .AXIS_WIDTH       (AW               ),
    .AXIS_TX_USR_WID  (UW               ),
    .LOCAL_IP_NUM     (1                )
  ) u_loop_arp_eng (
    .clk                          (loop_clk              ),
    .rst                          (loop_rst              ),
    .query_src_ip                 (loop_q_src_ip         ),
    .query_dst_ip                 (loop_q_ip             ),
    .query_valid_pulse            (loop_q_valid_pulse    ),
    .arp_dst_mac                  (loop_r_mac            ),
    .arp_src_mac                  (loop_r_src_mac        ),
    .arp_miss                     (loop_r_miss           ),
    .arp_valid                    (loop_r_valid          ),
    .arp_axis_sdata               (loop_dm_arp_data      ),
    .arp_axis_skeep               (loop_dm_arp_keep      ),
    .arp_axis_svalid              (loop_dm_arp_valid     ),
    .arp_axis_slast               (loop_dm_arp_last      ),
    .arp_axis_susr                (1'b0                  ),
    .arp_axis_sready              (loop_dm_arp_ready     ),
    .arp_axis_mdata               (loop_a_tx_data        ),
    .arp_axis_mkeep               (loop_a_tx_keep        ),
    .arp_axis_mvalid              (loop_a_tx_valid       ),
    .arp_axis_mlast               (loop_a_tx_last        ),
    .arp_axis_musr                (loop_a_tx_usr         ),
    .arp_axis_mready              (loop_a_tx_ready       ),
    .cfg_local_ip                 (loop_CFG_LOCAL_IP     ),
    .cfg_local_mac                (loop_CFG_LOCAL_MAC    ),
    .cfg_gateway_ip               (loop_CFG_GW_IP        ),
    .cfg_subnet_mask              (loop_CFG_SUBNET       ),
    .cfg_pending_time             (loop_CFG_PEND_TIME    ),
    .cfg_clear_cache              (1'b0                  ),
    .cfg_clear_pending            (1'b0                  ),
    .stat_rx_error                (loop_stat_rx_error    ),
    .stat_ack_fifo_overflow_error (loop_stat_ack_ovf     ),
    .stat_pending_fifo_overflow_error(loop_stat_pend_ovf ),
    .stat_lookup_no_resp_error    (loop_stat_no_resp     ),
    .stat_pending_clear_finish    (loop_stat_pend_clr_fin),
    .stat_cache_clear_finish      (loop_stat_cache_clr_fin),
    .stat_query_src_not_local     (                      )
  );

  // 反压注入 : ipv4_axis_m -> (1拍寄存) -> tester RX
  reg  loop_bp_en    = 1'b0;
  reg  [7:0] loop_bp_lfsr = 8'hA5;
  wire loop_bp_stall = loop_bp_en && (loop_bp_lfsr[0] ^ loop_bp_lfsr[3]);
  always @(posedge loop_clk) if (!loop_rst) loop_bp_lfsr <= {loop_bp_lfsr[6:0], loop_bp_lfsr[7]^loop_bp_lfsr[5]^loop_bp_lfsr[4]^loop_bp_lfsr[3]};

  wire [AW-1:0]   loop_sk_data ;  wire [AW/8-1:0] loop_sk_keep ;
  wire            loop_sk_last ;  wire            loop_sk_mvalid;
  wire            loop_sk_valid;  wire            loop_sk_ready;
  wire            loop_tst_rx_ready;

  axis_reg_slice #(.W(AW)) u_loop_rx_bp (
    .clk(loop_clk), .rst(loop_rst),
    .sdata(loop_p_rx_data), .skeep(loop_p_rx_keep), .slast(loop_p_rx_last),
    .svalid(loop_p_rx_valid), .sready(loop_p_rx_ready),
    .mdata(loop_sk_data), .mkeep(loop_sk_keep), .mlast(loop_sk_last),
    .mvalid(loop_sk_mvalid), .mready(loop_sk_ready)
  );

  reg  loop_test_enable = 1'b0;
  ipv4_100g_tester #(
    .AXIS_WIDTH       (AW),
    .AXIS_USER_WIDTH  (UW),
    .PKT_LEN_BEATS    (loop_PKT_BEATS),
    .ONE_SEC_CYCLES   (32'd2000),
    .AXIS_USER_VAL    (TESTER_USR),
    .DST_IP_LE        (loop_CFG_LOCAL_IP),
    .SRC_IP_LE        (loop_CFG_LOCAL_IP)
  ) u_loop_tester (
    .clk              (loop_clk              ),
    .rst              (loop_rst              ),
    .axis_mdata       (loop_tst_tx_data      ),
    .axis_mkeep       (loop_tst_tx_keep      ),
    .axis_mvalid      (loop_tst_tx_valid     ),
    .axis_mlast       (loop_tst_tx_last      ),
    .axis_musr        (loop_tst_tx_user      ),
    .axis_mready      (loop_tst_tx_ready     ),
    .axis_sdata       (loop_sk_data          ),
    .axis_skeep       (loop_sk_keep          ),
    .axis_svalid      (loop_sk_valid         ),
    .axis_slast       (loop_sk_last          ),
    .axis_susr        (4'd0                  ),
    .axis_sready      (loop_tst_rx_ready     ),
    .test_enable      (loop_test_enable      )
  );

  assign loop_sk_valid = loop_sk_mvalid & ~loop_bp_stall;
  assign loop_sk_ready = loop_tst_rx_ready & ~loop_bp_stall;

  // 监视器
  reg          loop_tx_sof = 1'b1;
  reg [15:0]   loop_tx_type_lat = 16'd0;
  integer      loop_tx_beat_run = 0;
  integer      loop_offered_pkt = 0;
  integer      loop_tx_arp_cnt  = 0;
  integer      loop_tx_ipv4_cnt = 0;
  integer      loop_tx_other_cnt= 0;
  integer      loop_tx_frame_cnt= 0;
  integer      loop_rx_frame_cnt= 0;
  integer      loop_arb_port_err= 0;
  integer      loop_onebeat_cnt = 0;
  integer      loop_short_keep_err = 0;

  always @(posedge loop_clk) begin
    if (loop_rst) begin
      loop_offered_pkt <= 0; loop_tx_arp_cnt <= 0; loop_tx_ipv4_cnt <= 0;
      loop_tx_other_cnt<= 0; loop_tx_frame_cnt<= 0; loop_rx_frame_cnt <= 0;
      loop_arb_port_err<= 0; loop_onebeat_cnt <= 0; loop_short_keep_err <= 0;
    end else begin
      if (loop_tst_tx_valid && loop_tst_tx_ready && loop_tst_tx_last) loop_offered_pkt <= loop_offered_pkt + 1;

      if (loop_pd_valid && loop_pd_ready) begin
        if (loop_tx_sof) loop_tx_type_lat <= loop_pd_data[111:96];
        loop_tx_beat_run <= loop_tx_beat_run + 1;
        if (loop_pd_last) begin
          loop_tx_frame_cnt <= loop_tx_frame_cnt + 1;
          if (loop_tx_beat_run == 0) begin
            loop_onebeat_cnt <= loop_onebeat_cnt + 1;
            if (loop_pd_keep[59:0] !== 60'hFFF_FFFF_FFFF_FFFF) begin
              loop_short_keep_err <= loop_short_keep_err + 1;
              $display("[SHORT] 单拍帧 keep=%h (低60位应为全1)", loop_pd_keep);
            end
            if (loop_pd_data[111:96] == ETH_ARP) loop_tx_arp_cnt  <= loop_tx_arp_cnt  + 1;
            else                                 loop_tx_other_cnt<= loop_tx_other_cnt+ 1;
          end
          else if (loop_tx_type_lat == ETH_IPV4) loop_tx_ipv4_cnt <= loop_tx_ipv4_cnt + 1;
          else                                   loop_tx_other_cnt<= loop_tx_other_cnt+ 1;
          loop_tx_beat_run <= 0;
        end
        if ((loop_tx_beat_run > 0) && !loop_pd_last && (loop_stat_arb_port != 1'd1))
          loop_arb_port_err <= loop_arb_port_err + 1;
        loop_tx_sof <= loop_pd_last;
      end

      if (loop_p_rx_valid && loop_p_rx_ready && loop_p_rx_last) loop_rx_frame_cnt <= loop_rx_frame_cnt + 1;
    end
  end

  wire [31:0] loop_tst_err_cnt = u_loop_tester.rx_error_cnt;

  reg loop_first_pkt_seen = 1'b0;
  always @(posedge loop_clk) if (!loop_rst && loop_p_rx_valid && loop_p_rx_ready && loop_p_rx_last) loop_first_pkt_seen <= 1'b1;

  integer loop_err_total;
  integer loop_base_tx, loop_base_rx, loop_base_err;
  task automatic loop_cyc(input integer n); integer i; begin for (i=0;i<n;i=i+1) @(posedge loop_clk); end endtask

  task phase_loopback;
    begin
      loop_err_total = 0;
      loop_rst = 1'b1;
      loop_cyc(20);
      loop_rst = 1'b0;
      loop_cyc(20);

      // T1: 上电自解析 ARP + 全链环回
      $display("--- [PHASE1 loopback] T1: 上电自解析 ARP + 全链环回 ---");
      loop_base_tx = loop_tx_ipv4_cnt; loop_base_err = loop_tst_err_cnt;
      loop_test_enable = 1'b1;
      loop_cyc(4000);
      if (loop_tx_arp_cnt < 1) begin
        $display("  [FAIL] 未发出 ARP 请求帧 (tx_arp=%0d)", loop_tx_arp_cnt); loop_err_total=loop_err_total+1;
      end else $display("  [PASS] ARP 请求已发出 (tx_arp=%0d)", loop_tx_arp_cnt);
      if (loop_tx_ipv4_cnt == loop_base_tx) begin
        $display("  [FAIL] 未发出任何 IPv4 业务帧 (ARP 未解析成功?)"); loop_err_total=loop_err_total+1;
      end else $display("  [PASS] IPv4 业务帧已发出 (tx_ipv4=%0d)", loop_tx_ipv4_cnt);
      if (loop_rx_frame_cnt < 1) begin
        $display("  [FAIL] 环回后未收到任何剥头 IPv4 包"); loop_err_total=loop_err_total+1;
      end else $display("  [PASS] 环回收到 IPv4 包 (rx_frame=%0d)", loop_rx_frame_cnt);
      if (loop_tst_err_cnt != 0) begin
        $display("  [FAIL] 逐字节比对有误码 (%0d 处)", loop_tst_err_cnt); loop_err_total=loop_err_total+1;
      end else $display("  [PASS] 逐字节比对 0 误码");
      if (!loop_first_pkt_seen) begin
        $display("  [FAIL] 未完成首包正确接收"); loop_err_total=loop_err_total+1;
      end else $display("  [PASS] first_pkt_seen 已置起 (链路已通)");
      if (loop_resp_mac !== loop_CFG_LOCAL_MAC) begin
        $display("  [FAIL] arp_dst_mac 结果=%h, 期望=%h", loop_resp_mac, loop_CFG_LOCAL_MAC); loop_err_total=loop_err_total+1;
      end else $display("  [PASS] arp_dst_mac = %h (ARP 解析出的目的 MAC)", loop_resp_mac);
      if (loop_arb_port_err != 0) begin
        $display("  [FAIL] 仲裁端口号与帧类型不符 %0d 次 (IPv4 应为 1)", loop_arb_port_err); loop_err_total=loop_err_total+1;
      end else $display("  [PASS] 仲裁端口号与帧类型一致 (IPv4=port1)");
      if (loop_short_keep_err != 0) begin
        $display("  [FAIL] 单拍帧未补齐到最小帧长 %0d 次", loop_short_keep_err); loop_err_total=loop_err_total+1;
      end else $display("  [PASS] 所有单拍帧已补齐到 60B (含 ARP 帧)");
      if (loop_stat_rx_error||loop_stat_ack_ovf||loop_stat_pend_ovf||loop_stat_no_resp)
        $display("  [INFO] ARP 错误锁存: rx_err=%b ack_ovf=%b pend_ovf=%b no_resp=%b",
                 loop_stat_rx_error,loop_stat_ack_ovf,loop_stat_pend_ovf,loop_stat_no_resp);

      // T2: 校验机侧反压
      $display("--- [PHASE1 loopback] T2: 校验机侧反压 (随机 stall) ---");
      loop_base_rx = loop_rx_frame_cnt; loop_base_err = loop_tst_err_cnt;
      loop_bp_en = 1'b1;
      loop_cyc(4000);
      loop_bp_en = 1'b0;
      loop_cyc(400);
      if (loop_tst_err_cnt != loop_base_err) begin
        $display("  [FAIL] 反压下出现误码 (+%0d)", loop_tst_err_cnt-loop_base_err); loop_err_total=loop_err_total+1;
      end else $display("  [PASS] 反压下无误码");
      if (loop_rx_frame_cnt - loop_base_rx < 1) begin
        $display("  [FAIL] 反压期间未收到新包 (疑似死锁)"); loop_err_total=loop_err_total+1;
      end else $display("  [PASS] 反压期间仍收到 %0d 个包 (未死锁)", loop_rx_frame_cnt-loop_base_rx);

      // T3: 长跑稳定性
      $display("--- [PHASE1 loopback] T3: 长跑稳定性 ---");
      loop_cyc(20000);
      if (loop_tst_err_cnt != 0) begin
        $display("  [FAIL] 长跑出现误码 (%0d)", loop_tst_err_cnt); loop_err_total=loop_err_total+1;
      end else $display("  [PASS] 长跑 0 误码");
      $display("  [INFO] offered=%0d  tx(arp=%0d ipv4=%0d other=%0d)  rx=%0d  丢(ARP未解析)=%0d",
               loop_offered_pkt, loop_tx_arp_cnt, loop_tx_ipv4_cnt, loop_tx_other_cnt, loop_rx_frame_cnt,
               loop_offered_pkt - loop_tx_ipv4_cnt);
      $display("  [INFO] 单拍帧=%0d (合法 ARP; 幽灵帧会表现为类型非 ARP 的单拍帧)", loop_onebeat_cnt);
      $display("  [INFO] 1秒等效吞吐: %0d Byte/s  %0d pkt/s", u_loop_tester.rx_bw_bytes_per_s, u_loop_tester.rx_pkt_per_s);

      loop_test_enable = 1'b0;
      loop_cyc(50);
      if (loop_stat_arb_idle !== 1'b1) $display("  [INFO] 停流后 stat_tx_idle=%b (未回到空闲)", loop_stat_arb_idle);
      else $display("  [PASS] 停流后 stat_tx_idle=1 (仲裁器回到空闲)");

      $display("----------------------------------------------------------------");
      if (loop_err_total == 0) $display(" [PHASE1 loopback] *** PASS ***  (rx=%0d, 0 err)", loop_rx_frame_cnt);
      else                      $display(" [PHASE1 loopback] *** %0d CHECK(S) FAILED ***", loop_err_total);
      $display("----------------------------------------------------------------");
    end
  endtask

  // ============================================================================
  // PHASE 2 : after_traffic   (原 sub_arp_after_traffic)
  // 400MHz 双 IP: 复现 "打流之后, 主机再发 ARP 请求, FPGA 不再应答"
  // ============================================================================
  localparam integer aft_PKT_BEATS = 16;              // 16 拍 = 1024 字节
  localparam integer aft_LOCAL_IP_NUM = 2;
  localparam [32*2-1:0] aft_CFG_LOCAL_IP  = {32'hf101_A8C0, 32'hf001_A8C0};
  localparam [48*2-1:0] aft_CFG_LOCAL_MAC = {48'h554433221100, 48'h665544332200};
  localparam [32*2-1:0] aft_CFG_GW_IP     = {32'h0101_A8C0, 32'h0101_A8C0};
  localparam [32*2-1:0] aft_CFG_SUBNET    = {32'h00FF_FFFF, 32'h00FF_FFFF};
  localparam [56:0]     aft_CFG_PEND_TIME = 57'd4000;
  localparam [31:0] aft_IP0_LE = 32'hf001_A8C0;       // 192.168.1.240
  localparam [31:0] aft_IP1_LE = 32'hf101_A8C0;       // 192.168.1.241
  localparam [31:0] aft_HOST_IP_LE = 32'h1401_A8C0;   // 192.168.1.20
  localparam [47:0] aft_HOST_MAC   = 48'h9070_6911_b36c;
  localparam [63:0] aft_ARP_KEEP   = 64'h0000_03FF_FFFF_FFFF;   // 42 字节

  reg aft_clk = 1'b0;
  always #1.25 aft_clk = ~aft_clk;                   // 400MHz
  reg aft_rst = 1'b1;

  wire [AW-1:0]   aft_tst_tx_data; wire [AW/8-1:0] aft_tst_tx_keep;
  wire            aft_tst_tx_last, aft_tst_tx_valid, aft_tst_tx_ready;
  wire [UW-1:0]   aft_tst_tx_user;
  wire [AW-1:0]   aft_p_tx_data  ; wire [AW/8-1:0] aft_p_tx_keep  ;
  wire            aft_p_tx_last  , aft_p_tx_valid , aft_p_tx_ready ;
  wire [UW-1:0]   aft_p_tx_usr   ;
  wire [AW-1:0]   aft_a_tx_data  ; wire [AW/8-1:0] aft_a_tx_keep  ;
  wire            aft_a_tx_last  , aft_a_tx_valid , aft_a_tx_ready ;
  wire [UW-1:0]   aft_a_tx_usr   ;
  wire [AW-1:0]   aft_mx_data    ; wire [AW/8-1:0] aft_mx_keep    ;
  wire            aft_mx_last    , aft_mx_valid   , aft_mx_ready   ; wire [UW-1:0] aft_mx_user;
  wire [AW-1:0]   aft_pd_data    ; wire [AW/8-1:0] aft_pd_keep    ;
  wire            aft_pd_last    , aft_pd_valid   , aft_pd_ready   ;
  wire [AW-1:0]   aft_lb_data    ; wire [AW/8-1:0] aft_lb_keep    ;
  wire            aft_lb_last    , aft_lb_valid   , aft_lb_ready   ;
  wire [AW-1:0]   aft_p_rx_data  ; wire [AW/8-1:0] aft_p_rx_keep  ;
  wire            aft_p_rx_last  , aft_p_rx_valid , aft_p_rx_ready ;

  wire [AW*2-1:0]   aft_mx_sdata = {aft_p_tx_data , aft_a_tx_data };
  wire [AW/8*2-1:0] aft_mx_skeep = {aft_p_tx_keep , aft_a_tx_keep };
  wire [1:0]        aft_mx_slast = {aft_p_tx_last , aft_a_tx_last };
  wire [1:0]        aft_mx_svalid= {aft_p_tx_valid, aft_a_tx_valid};
  wire [UW*2-1:0]   aft_mx_susr  = {aft_p_tx_usr  , aft_a_tx_usr  };
  wire [1:0]        aft_mx_sready;
  assign {aft_p_tx_ready, aft_a_tx_ready} = aft_mx_sready;

  wire [AW*3-1:0]   aft_dm_mdata ;
  wire [AW/8*3-1:0] aft_dm_mkeep ;
  wire [2:0]        aft_dm_mlast , aft_dm_mvalid, aft_dm_musr ;
  wire [2:0]        aft_dm_mready;

  wire [AW-1:0]   aft_dm_ipv4_data  = aft_dm_mdata[0*AW +: AW];
  wire [AW/8-1:0] aft_dm_ipv4_keep  = aft_dm_mkeep[0*(AW/8) +: AW/8];
  wire            aft_dm_ipv4_last  = aft_dm_mlast[0];
  wire            aft_dm_ipv4_valid = aft_dm_mvalid[0];
  wire [AW-1:0]   aft_dm_arp_data   = aft_dm_mdata[1*AW +: AW];
  wire [AW/8-1:0] aft_dm_arp_keep   = aft_dm_mkeep[1*(AW/8) +: AW/8];
  wire            aft_dm_arp_last   = aft_dm_mlast[1];
  wire            aft_dm_arp_valid  = aft_dm_mvalid[1];
  wire            aft_dm_ipv4_ready, aft_dm_arp_ready;
  assign aft_dm_mready = {1'b1, aft_dm_arp_ready, aft_dm_ipv4_ready};

  wire [31:0] aft_q_ip, aft_q_src_ip; wire aft_q_valid_pulse;
  wire [47:0] aft_r_mac, aft_r_src_mac; wire aft_r_miss, aft_r_valid;
  wire aft_stat_rx_err, aft_stat_ack_ovf, aft_stat_pend_ovf, aft_stat_no_resp;
  wire aft_stat_pend_clr, aft_stat_cache_clr;
  wire aft_stat_arb_port; wire aft_stat_arb_idle;

  // ARP RX 源选择 : 0=环回(demux ch1) 1=外部注入(主机)
  reg          aft_arp_rx_sel = 1'b0;
  reg  [AW-1:0]  aft_inj_data = 0;
  reg  [AW/8-1:0] aft_inj_keep = 0;
  reg            aft_inj_last = 0, aft_inj_valid = 0;
  wire           aft_inj_ready;

  wire           aft_arp_rx_ready_w;
  wire [AW-1:0]   aft_arp_rx_data = aft_arp_rx_sel ? aft_inj_data  : aft_dm_arp_data ;
  wire [AW/8-1:0] aft_arp_rx_keep = aft_arp_rx_sel ? aft_inj_keep  : aft_dm_arp_keep ;
  wire            aft_arp_rx_last = aft_arp_rx_sel ? aft_inj_last  : aft_dm_arp_last ;
  wire            aft_arp_rx_valid= aft_arp_rx_sel ? aft_inj_valid : aft_dm_arp_valid;
  assign aft_dm_arp_ready  = aft_arp_rx_sel ? 1'b1 : aft_arp_rx_ready_w;
  assign aft_inj_ready     = aft_arp_rx_sel ? aft_arp_rx_ready_w : 1'b0;

  // IPv4 RX 源选择 : 0=环回(demux ch0) 1=外部注入(主机 IPv4 帧)
  reg             aft_i4_rx_sel = 1'b0;
  reg  [AW-1:0]     aft_i4_data = 0;   reg [AW/8-1:0] aft_i4_keep = 0;
  reg               aft_i4_last = 0,   aft_i4_valid = 0;  wire aft_i4_ready;
  wire            aft_ipv4_rx_ready_w;
  wire [AW-1:0]   aft_ipv4_rx_data = aft_i4_rx_sel ? aft_i4_data  : aft_dm_ipv4_data ;
  wire [AW/8-1:0] aft_ipv4_rx_keep = aft_i4_rx_sel ? aft_i4_keep  : aft_dm_ipv4_keep ;
  wire            aft_ipv4_rx_last = aft_i4_rx_sel ? aft_i4_last  : aft_dm_ipv4_last ;
  wire            aft_ipv4_rx_valid= aft_i4_rx_sel ? aft_i4_valid : aft_dm_ipv4_valid;
  assign aft_dm_ipv4_ready = aft_i4_rx_sel ? 1'b1 : aft_ipv4_rx_ready_w;
  assign aft_i4_ready      = aft_i4_rx_sel ? aft_ipv4_rx_ready_w : 1'b0;

  // demux 输入源选择 : 0=环回 1=注入主机发来的任意以太帧(TCP 等)
  reg             aft_dm_sel = 1'b0;
  reg  [AW-1:0]     aft_tcp_data = 0;  reg [AW/8-1:0] aft_tcp_keep = 0;
  reg               aft_tcp_last = 0,  aft_tcp_valid = 0; wire aft_tcp_ready;
  wire [AW-1:0]   aft_dem_in_data = aft_dm_sel ? aft_tcp_data : aft_lb_data ;
  wire [AW/8-1:0] aft_dem_in_keep = aft_dm_sel ? aft_tcp_keep : aft_lb_keep ;
  wire            aft_dem_in_last = aft_dm_sel ? aft_tcp_last : aft_lb_last ;
  wire            aft_dem_in_valid= aft_dm_sel ? aft_tcp_valid: aft_lb_valid;
  wire            aft_dem_in_ready;
  assign aft_lb_ready  = aft_dm_sel ? 1'b1 : aft_dem_in_ready;
  assign aft_tcp_ready = aft_dm_sel ? aft_dem_in_ready : 1'b0;

  wire [AW*5-1:0]   aft_rxflat_mdata;
  wire [AW/8*5-1:0] aft_rxflat_mkeep;
  wire [4:0]        aft_rxflat_mlast, aft_rxflat_mvalid;
  wire [97*5-1:0]   aft_rxflat_musr ;
  wire [4:0]        aft_rxflat_mready;
  assign aft_p_rx_data   = aft_rxflat_mdata[0*AW +: AW];
  assign aft_p_rx_keep   = aft_rxflat_mkeep[0*(AW/8) +: AW/8];
  assign aft_p_rx_last   = aft_rxflat_mlast[0];
  assign aft_p_rx_valid  = aft_rxflat_mvalid[0];
  assign aft_rxflat_mready = {4'b1111, aft_p_rx_ready};

  axis_reg_slice #(.W(AW)) u_aft_eth_loop (
    .clk(aft_clk), .rst(aft_rst),
    .sdata(aft_pd_data), .skeep(aft_pd_keep), .slast(aft_pd_last), .svalid(aft_pd_valid), .sready(aft_pd_ready),
    .mdata(aft_lb_data), .mkeep(aft_lb_keep), .mlast(aft_lb_last), .mvalid(aft_lb_valid), .mready(aft_lb_ready)
  );

  eth_type_demux #(
    .TYPE_NUM            (2                  ),
    .TYPE_DICT           ({16'h0608,16'h0008})
  ) u_aft_demux (
    .clk(aft_clk), .rst(aft_rst),
    .eth_axis_sdata(aft_dem_in_data), .eth_axis_skeep(aft_dem_in_keep), .eth_axis_slast(aft_dem_in_last),
    .eth_axis_svalid(aft_dem_in_valid), .eth_axis_susr(1'b0), .eth_axis_sready(aft_dem_in_ready),
    .eth_axis_mdata(aft_dm_mdata), .eth_axis_mkeep(aft_dm_mkeep), .eth_axis_mlast(aft_dm_mlast),
    .eth_axis_mvalid(aft_dm_mvalid), .eth_axis_musr(aft_dm_musr), .eth_axis_mready(aft_dm_mready)
  );

  eth_tx_mux #(
    .TYPE_NUM        (2                ),
    .AXIS_USER_WIDTH (UW               )
  ) u_aft_tx_mux (
    .clk(aft_clk), .rst(aft_rst),
    .eth_axis_sdata(aft_mx_sdata), .eth_axis_skeep(aft_mx_skeep), .eth_axis_slast(aft_mx_slast),
    .eth_axis_svalid(aft_mx_svalid), .eth_axis_susr(aft_mx_susr), .eth_axis_sready(aft_mx_sready),
    .eth_axis_mdata(aft_mx_data), .eth_axis_mkeep(aft_mx_keep), .eth_axis_mlast(aft_mx_last),
    .eth_axis_mvalid(aft_mx_valid), .eth_axis_musr(aft_mx_user), .eth_axis_mready(aft_mx_ready),
    .stat_active_port(aft_stat_arb_port), .stat_idle(aft_stat_arb_idle)
  );

  eth_frame_pad60 #(.MIN_FRAME_BYTES(60)) u_aft_frame_pad (
    .clk(aft_clk), .rst(aft_rst),
    .eth_axis_sdata(aft_mx_data), .eth_axis_skeep(aft_mx_keep), .eth_axis_slast(aft_mx_last),
    .eth_axis_svalid(aft_mx_valid), .eth_axis_sready(aft_mx_ready),
    .eth_axis_mdata(aft_pd_data), .eth_axis_mkeep(aft_pd_keep), .eth_axis_mlast(aft_pd_last),
    .eth_axis_mvalid(aft_pd_valid), .eth_axis_mready(aft_pd_ready)
  );

  ipv4_top #(
    .RX_TYPE_NUM     (4                ),
    .TX_TYPE_NUM     (1                ),
    .AXIS_USER_WIDTH (UW               )
  ) u_aft_ipv4 (
    .clk(aft_clk), .rst(aft_rst),
    .eth_ipv4_axis_sdata(aft_ipv4_rx_data), .eth_ipv4_axis_skeep(aft_ipv4_rx_keep),
    .eth_ipv4_axis_slast(aft_ipv4_rx_last), .eth_ipv4_axis_svalid(aft_ipv4_rx_valid),
    .eth_ipv4_axis_susr(1'b0),
    .eth_ipv4_axis_sready(aft_ipv4_rx_ready_w),
    .ipv4_axis_mdata(aft_rxflat_mdata), .ipv4_axis_mkeep(aft_rxflat_mkeep),
    .ipv4_axis_mlast(aft_rxflat_mlast), .ipv4_axis_mvalid(aft_rxflat_mvalid),
    .ipv4_axis_musr(aft_rxflat_musr), .ipv4_axis_mready(aft_rxflat_mready),
    .ipv4_axis_sdata(aft_tst_tx_data), .ipv4_axis_skeep(aft_tst_tx_keep),
    .ipv4_axis_slast(aft_tst_tx_last), .ipv4_axis_svalid(aft_tst_tx_valid),
    .ipv4_axis_susr(aft_tst_tx_user), .ipv4_axis_sready(aft_tst_tx_ready),
    .eth_tx_axis_mdata(aft_p_tx_data), .eth_tx_axis_mkeep(aft_p_tx_keep), .eth_tx_axis_mlast(aft_p_tx_last),
    .eth_tx_axis_mvalid(aft_p_tx_valid), .eth_tx_axis_musr(aft_p_tx_usr), .eth_tx_axis_mready(aft_p_tx_ready),
    .query_src_ip(aft_q_src_ip), .query_dst_ip(aft_q_ip), .query_valid_pulse(aft_q_valid_pulse),
    .arp_dst_mac(aft_r_mac), .arp_src_mac(aft_r_src_mac), .arp_miss(aft_r_miss), .arp_valid(aft_r_valid),
    .stat_tx_active_port(), .stat_tx_idle()
  );

  arp_engine_top #(
    .AXIS_WIDTH(AW), .AXIS_TX_USR_WID(UW), .LOCAL_IP_NUM(aft_LOCAL_IP_NUM)
  ) u_aft_arp_eng (
    .clk(aft_clk), .rst(aft_rst),
    .query_src_ip(aft_q_src_ip), .query_dst_ip(aft_q_ip), .query_valid_pulse(aft_q_valid_pulse),
    .arp_dst_mac(aft_r_mac), .arp_src_mac(aft_r_src_mac), .arp_miss(aft_r_miss), .arp_valid(aft_r_valid),
    .arp_axis_sdata(aft_arp_rx_data), .arp_axis_skeep(aft_arp_rx_keep), .arp_axis_slast(aft_arp_rx_last),
    .arp_axis_svalid(aft_arp_rx_valid), .arp_axis_susr(1'b0), .arp_axis_sready(aft_arp_rx_ready_w),
    .arp_axis_mdata(aft_a_tx_data), .arp_axis_mkeep(aft_a_tx_keep), .arp_axis_mlast(aft_a_tx_last),
    .arp_axis_mvalid(aft_a_tx_valid), .arp_axis_musr(aft_a_tx_usr), .arp_axis_mready(aft_a_tx_ready),
    .cfg_local_ip(aft_CFG_LOCAL_IP), .cfg_local_mac(aft_CFG_LOCAL_MAC),
    .cfg_gateway_ip(aft_CFG_GW_IP), .cfg_subnet_mask(aft_CFG_SUBNET),
    .cfg_pending_time(aft_CFG_PEND_TIME),
    .cfg_clear_cache(1'b0), .cfg_clear_pending(1'b0),
    .stat_rx_error(aft_stat_rx_err), .stat_ack_fifo_overflow_error(aft_stat_ack_ovf),
    .stat_pending_fifo_overflow_error(aft_stat_pend_ovf),
    .stat_lookup_no_resp_error(aft_stat_no_resp),
    .stat_pending_clear_finish(aft_stat_pend_clr), .stat_cache_clear_finish(aft_stat_cache_clr),
    .stat_query_src_not_local()
  );

  reg aft_test_enable = 1'b0;
  reg aft_GRACEFUL = 1'b0;
  ipv4_100g_tester #(
    .AXIS_WIDTH(AW), .AXIS_USER_WIDTH(UW), .PKT_LEN_BEATS(aft_PKT_BEATS),
    .ONE_SEC_CYCLES(32'd2000), .AXIS_USER_VAL(TESTER_USR),
    .DST_IP_LE(aft_IP0_LE), .SRC_IP_LE(aft_IP0_LE)
  ) u_aft_tester (
    .clk(aft_clk), .rst(aft_rst),
    .axis_mdata(aft_tst_tx_data), .axis_mkeep(aft_tst_tx_keep), .axis_mvalid(aft_tst_tx_valid),
    .axis_mlast(aft_tst_tx_last), .axis_musr(aft_tst_tx_user), .axis_mready(aft_tst_tx_ready),
    .axis_sdata(aft_p_rx_data), .axis_skeep(aft_p_rx_keep), .axis_svalid(aft_p_rx_valid),
    .axis_slast(aft_p_rx_last), .axis_susr({UW{1'b0}}), .axis_sready(aft_p_rx_ready),
    .test_enable(aft_test_enable)
  );

  // 观测
  integer aft_tx_beats = 0;
  integer aft_tx_pkts  = 0;
  always @(posedge aft_clk) begin
    if (aft_rst) begin aft_tx_beats <= 0; aft_tx_pkts <= 0; end
    else if (aft_tst_tx_valid && aft_tst_tx_ready) begin
      aft_tx_beats <= aft_tx_beats + 1;
      if (aft_tst_tx_last) aft_tx_pkts <= aft_tx_pkts + 1;
    end
  end

  integer aft_arp_tx_cnt = 0;
  integer aft_rep_cnt    = 0;
  integer aft_err = 0, aft_i;
  reg     aft_tx_sof = 1'b1;
  always @(posedge aft_clk) begin
    if (aft_rst) begin aft_arp_tx_cnt <= 0; aft_rep_cnt <= 0; aft_tx_sof <= 1'b1; end
    else if (aft_a_tx_valid && aft_a_tx_ready) begin
      if (aft_tx_sof) begin
        aft_arp_tx_cnt <= aft_arp_tx_cnt + 1;
        if (aft_a_tx_data[175:160] == 16'h0200) aft_rep_cnt <= aft_rep_cnt + 1;   // oper(LE) = reply
      end
      aft_tx_sof <= aft_a_tx_last;
    end
  end

  task automatic aft_cyc(input integer n);
    begin for (aft_i = 0; aft_i < n; aft_i = aft_i + 1) @(posedge aft_clk); end
  endtask

  task automatic aft_chk(input [255:0] name, input integer cond);
    begin
      if (!cond) begin $display("  [FAIL] %0s", name); aft_err = aft_err + 1; end
      else            $display("  [PASS] %0s", name);
    end
  endtask

  // 注入一帧 proto=6(TCP) 的以太帧
  task automatic aft_host_tcp_frame;
    begin
      @(negedge aft_clk);
      aft_tcp_data  <= {240'd0,
                        32'hf001_A8C0,
                        32'h1401_A8C0,
                        16'h0000,
                        8'h06,
                        8'h40,
                        16'h0000,
                        16'h0000,
                        16'h0028,
                        8'h00,
                        8'h45,
                        16'h0008,
                        aft_HOST_MAC,
                        48'h5544_3322_1100};
      aft_tcp_keep  <= {AW/8{1'b1}};
      aft_tcp_last  <= 1'b0;
      aft_tcp_valid <= 1'b1;
      @(posedge aft_clk);
      while (!(aft_tcp_valid && aft_tcp_ready)) @(posedge aft_clk);
      @(negedge aft_clk);
      aft_tcp_data  <= {AW{1'b0}};
      aft_tcp_keep  <= 64'h0000_03FF_FFFF_FFFF;
      aft_tcp_last  <= 1'b1;
      @(posedge aft_clk);
      while (!(aft_tcp_valid && aft_tcp_ready)) @(posedge aft_clk);
      @(negedge aft_clk);
      aft_tcp_valid <= 1'b0; aft_tcp_last <= 1'b0;
    end
  endtask

  // 从"主机"注入一帧 ARP Request
  task automatic aft_host_arp_req(input [31:0] tpa_le);
    begin
      @(negedge aft_clk);
      aft_inj_data  <= {176'd0, tpa_le, 48'h0, aft_HOST_IP_LE, aft_HOST_MAC, 16'h0100,
                        8'h04, 8'h06, 16'h0008, 16'h0100, 16'h0608,
                        aft_HOST_MAC, 48'hFFFF_FFFF_FFFF};
      aft_inj_keep  <= aft_ARP_KEEP;
      aft_inj_last  <= 1'b1;
      aft_inj_valid <= 1'b1;
      @(posedge aft_clk);
      while (!(aft_inj_valid && aft_inj_ready)) @(posedge aft_clk);
      @(negedge aft_clk);
      aft_inj_valid <= 1'b0; aft_inj_last <= 1'b0;
    end
  endtask

  integer aft_rep_before;
  reg aft_dbg = 1'b0;
  always @(posedge aft_clk) if (aft_dbg)
    $display("[%0t] ack_v=%b rr_v=%b txV=%b aV=%b aR=%b | muxV=%b muxR=%b pdV=%b pdR=%b lbV=%b lbR=%b | idle=%b port=%d | ipv4V=%b ipv4R=%b",
      $time, u_aft_arp_eng.eth_ack_frame_valid, u_aft_arp_eng.arp_rr_dout_valid,
      u_aft_arp_eng.tx_frame_data_valid, aft_a_tx_valid, aft_a_tx_ready,
      aft_mx_valid, aft_mx_ready, aft_pd_valid, aft_pd_ready, aft_lb_valid, aft_lb_ready,
      aft_stat_arb_idle, aft_stat_arb_port, aft_p_tx_valid, aft_p_tx_ready);
  always @(posedge aft_clk) if (aft_dbg)
    $display("        arb: valid=%b onehot=%b reqval=%b mask=%b sval_d0=%b ready_d0=%b skidV=%b srdy_d1=%b mV=%b",
      u_aft_tx_mux.u_axis_nto1_by_val.arbiter_valid,
      u_aft_tx_mux.u_axis_nto1_by_val.arbiter_onehot,
      u_aft_tx_mux.u_axis_nto1_by_val.arbiter_req_val,
      u_aft_tx_mux.u_axis_nto1_by_val.axis_svalid_mask,
      u_aft_tx_mux.u_axis_nto1_by_val.axis_svalid_d0,
      u_aft_tx_mux.u_axis_nto1_by_val.axis_sready_d0,
      u_aft_tx_mux.u_axis_nto1_by_val.skid_valid_reg,
      u_aft_tx_mux.u_axis_nto1_by_val.axis_sready_d1,
      u_aft_tx_mux.u_axis_nto1_by_val.axis_mvalid_reg);
  always @(posedge aft_clk) if (aft_dbg)
    $display("        demux: sval_s1=%b sel=%b s1_rdy=%b srdy=%b inV=%b | rx_ready_w=%b rxV=%b rx_sel=%b",
      u_aft_ipv4.u_ipv4_type_demux.ipv4_axis_svalid_s1,
      u_aft_ipv4.u_ipv4_type_demux.sel_type_one_hot_s1,
      u_aft_ipv4.u_ipv4_type_demux.s1_ready,
      u_aft_ipv4.u_ipv4_type_demux.ipv4_axis_sready,
      u_aft_ipv4.u_ipv4_type_demux.ipv4_axis_svalid,
      aft_ipv4_rx_ready_w, aft_ipv4_rx_valid, aft_i4_rx_sel);

  task phase_after_traffic;
    begin
      $display("=== [PHASE2 after_traffic] 复现 '打流后 ARP 不再应答' ===");
      aft_err = 0;
      aft_rst = 1'b1; aft_cyc(20); aft_rst = 1'b0;
      for (aft_i = 0; aft_i < 4000 && !(aft_stat_cache_clr && aft_stat_pend_clr); aft_i = aft_i + 1) @(posedge aft_clk);
      aft_chk("清表完成", aft_stat_cache_clr && aft_stat_pend_clr);
      aft_cyc(10);

      // T1 基线
      $display("--- [PHASE2] T1 基线(未打流): 主机 ARP -> 应收到应答 ---");
      aft_arp_rx_sel = 1'b1;
      aft_rep_before = aft_rep_cnt;
      aft_host_arp_req(aft_IP0_LE);  aft_cyc(60);
      $display("    .240 应答数 %0d -> %0d", aft_rep_before, aft_rep_cnt);
      aft_chk("T1a 打流前 .240 有应答", (aft_rep_cnt - aft_rep_before) >= 1);
      aft_rep_before = aft_rep_cnt;
      aft_host_arp_req(aft_IP1_LE);  aft_cyc(60);
      $display("    .241 应答数 %0d -> %0d", aft_rep_before, aft_rep_cnt);
      aft_chk("T1b 打流前 .241 有应答", (aft_rep_cnt - aft_rep_before) >= 1);

      // T2 打流
      $display("--- [PHASE2] T2 打流(test_enable=1, 3000 拍) ---");
      aft_arp_rx_sel = 1'b0;
      aft_test_enable = 1'b1;
      aft_cyc(3000);
      $display("    打流期间 ARP 引擎发帧=%0d (reply=%0d)", aft_arp_tx_cnt, aft_rep_cnt);
      $display("    打流吞吐: 3000 拍内 tester 发出 %0d 拍 / %0d 包", aft_tx_beats, aft_tx_pkts);

      // T3 停流排空
      if (aft_GRACEFUL) begin
        while (!(aft_tst_tx_valid && aft_tst_tx_ready && aft_tst_tx_last)) @(posedge aft_clk);
        $display("    (优雅停止: 已等到最后一拍 tlast 握手)");
      end else begin
        $display("    (粗暴停止: test_enable 立即拉低, 当前包无 tlast)");
      end
      aft_test_enable = 1'b0;
      aft_dbg = 1'b1;
      aft_cyc(60);
      aft_dbg = 1'b0;
      aft_cyc(940);
      $display("--- [PHASE2] T3 停流排空: arb_idle=%b mux_arp_ready=%b ---", aft_stat_arb_idle, aft_a_tx_ready);

      // T4 复现点
      $display("--- [PHASE2] T4 打流后: 主机 ARP -> 是否还有应答 ---");
      aft_arp_rx_sel = 1'b1;
      aft_rep_before = aft_rep_cnt;
      aft_host_arp_req(aft_IP0_LE);  aft_cyc(80);
      $display("    .240 应答数 %0d -> %0d  (rx_ready=%b)", aft_rep_before, aft_rep_cnt, aft_arp_rx_ready_w);
      aft_chk("T4a 打流后 .240 仍有应答", (aft_rep_cnt - aft_rep_before) >= 1);
      aft_rep_before = aft_rep_cnt;
      aft_dbg = 1'b1;
      aft_host_arp_req(aft_IP1_LE);  aft_cyc(40);
      aft_dbg = 1'b0;
      aft_cyc(40);
      $display("    .241 应答数 %0d -> %0d  (rx_ready=%b)", aft_rep_before, aft_rep_cnt, aft_arp_rx_ready_w);
      aft_chk("T4b 打流后 .241 仍有应答", (aft_rep_cnt - aft_rep_before) >= 1);

      // T5 再打一轮
      $display("--- [PHASE2] T5 第二轮 打流 -> ARP ---");
      aft_arp_rx_sel = 1'b0; aft_test_enable = 1'b1; aft_cyc(1500); aft_test_enable = 1'b0; aft_cyc(600);
      aft_arp_rx_sel = 1'b1;
      aft_rep_before = aft_rep_cnt;
      aft_host_arp_req(aft_IP0_LE);  aft_cyc(80);
      $display("    .240 应答数 %0d -> %0d", aft_rep_before, aft_rep_cnt);
      aft_chk("T5 第二轮打流后 .240 仍有应答", (aft_rep_cnt - aft_rep_before) >= 1);

      $display("    stat: rx_err=%b ack_ovf=%b pend_ovf=%b no_resp=%b",
               aft_stat_rx_err, aft_stat_ack_ovf, aft_stat_pend_ovf, aft_stat_no_resp);

      // T6 复现点: 收到 TCP 帧之后
      $display("--- [PHASE2] T6 注入 proto=6(TCP) 的 IPv4 帧 -> 之后 ARP 是否还通 ---");
      aft_dm_sel = 1'b1;
      aft_dbg = 1'b1;
      aft_host_tcp_frame();
      aft_cyc(30);
      aft_dbg = 1'b0;
      aft_cyc(70);
      $display("    TCP 帧已注入");
      aft_rep_before = aft_rep_cnt;
      aft_host_arp_req(aft_IP0_LE);  aft_cyc(80);
      $display("    .240 应答数 %0d -> %0d", aft_rep_before, aft_rep_cnt);
      aft_chk("T6a 收到 TCP 帧后 .240 仍应答", (aft_rep_cnt - aft_rep_before) >= 1);
      aft_rep_before = aft_rep_cnt;
      aft_host_arp_req(aft_IP1_LE);  aft_cyc(80);
      aft_chk("T6b 收到 TCP 帧后 .241 仍应答", (aft_rep_cnt - aft_rep_before) >= 1);

      $display("    最终: ARP 引擎累计发帧=%0d (reply=%0d)", aft_arp_tx_cnt, aft_rep_cnt);
      $display("----------------------------------------------------------------");
      if (aft_err == 0) $display(" [PHASE2 after_traffic] *** PASS ***");
      else              $display(" [PHASE2 after_traffic] *** %0d CHECK(S) FAILED ***", aft_err);
      $display("----------------------------------------------------------------");
    end
  endtask

  // ============================================================================
  // PHASE 3 : chain   (原 tb_ipv4_chain)
  // 200MHz <-> ~322MHz 两个异步 FIFO 跨时钟域 + 停流排空
  // ============================================================================
  localparam [31:0] ch_LOCAL_IP  = 32'h0201_A8C0;
  localparam [47:0] ch_LOCAL_MAC = 48'h554433221100;
  localparam [31:0] ch_GW_IP     = 32'h0101_A8C0;
  localparam [31:0] ch_SUBNET    = 32'h00FF_FFFF;
  localparam [56:0] ch_PEND_TIME = 57'd200_000;

  reg ch_clk200 = 1'b0;
  always #2.5 ch_clk200 = ~ch_clk200;              // 200 MHz
  reg ch_usr_clk = 1'b0;
  always #1.55 ch_usr_clk = ~ch_usr_clk;           // ~322 MHz
  reg ch_rst = 1'b1;

  wire [AW-1:0]    ch_eth_tx_mdata ;  wire [AW/8-1:0] ch_eth_tx_mkeep ;
  wire             ch_eth_tx_mlast ;  wire            ch_eth_tx_mvalid;
  wire             ch_eth_tx_mready;  wire [UW-1:0]   ch_eth_tx_musr  ;
  wire [AW-1:0]    ch_tst_tx_mdata ;  wire [AW/8-1:0] ch_tst_tx_mkeep ;
  wire             ch_tst_tx_mlast ;  wire            ch_tst_tx_mvalid;
  wire             ch_tst_tx_mready;  wire [UW-1:0]   ch_tst_tx_musr  ;
  wire [AW-1:0]    ch_eth_rx_sdata ;  wire [AW/8-1:0] ch_eth_rx_skeep ;
  wire             ch_eth_rx_slast ;  wire            ch_eth_rx_svalid;
  wire             ch_eth_rx_sready;

  wire ch_stat_rx_error, ch_stat_ack_ovf, ch_stat_pend_ovf, ch_stat_no_resp;
  wire ch_stat_pend_clr, ch_stat_cache_clr;
  wire ch_stat_arb_port, ch_stat_arb_idle;

  wire [AW-1:0]    ch_a_tx_mdata ;  wire [AW/8-1:0] ch_a_tx_mkeep ;
  wire             ch_a_tx_mlast ;  wire            ch_a_tx_mvalid;
  wire             ch_a_tx_mready;  wire [UW-1:0]   ch_a_tx_musr  ;
  wire [31:0]      ch_q_ip       ;  wire            ch_q_valid_pulse;
  wire [31:0]      ch_q_src_ip   ;
  wire [47:0]      ch_r_mac      ;  wire [47:0]     ch_r_src_mac;
  wire             ch_r_miss     ;  wire            ch_r_valid     ;

  wire [AW*2-1:0]   ch_mx_sdata = {ch_eth_tx_mdata , ch_a_tx_mdata };
  wire [AW/8*2-1:0] ch_mx_skeep = {ch_eth_tx_mkeep , ch_a_tx_mkeep };
  wire [1:0]        ch_mx_slast = {ch_eth_tx_mlast , ch_a_tx_mlast };
  wire [1:0]        ch_mx_svalid= {ch_eth_tx_mvalid, ch_a_tx_mvalid};
  wire [UW*2-1:0]   ch_mx_susr  = {ch_eth_tx_musr  , ch_a_tx_musr  };
  wire [1:0]        ch_mx_sready;
  assign {ch_eth_tx_mready, ch_a_tx_mready} = ch_mx_sready;

  wire [AW-1:0]    ch_mx_mdata ;  wire [AW/8-1:0] ch_mx_mkeep ;
  wire             ch_mx_mlast ;  wire            ch_mx_mvalid;
  wire             ch_mx_mready;  wire [UW-1:0]   ch_mx_musr  ;
  wire [AW-1:0]    ch_pd_mdata ;  wire [AW/8-1:0] ch_pd_mkeep ;
  wire             ch_pd_mlast ;  wire            ch_pd_mvalid;
  wire             ch_pd_mready;

  wire [AW*3-1:0]   ch_dm1_mdata;
  wire [AW/8*3-1:0] ch_dm1_mkeep;
  wire [2:0]        ch_dm1_mlast, ch_dm1_mvalid, ch_dm1_musr;
  wire [2:0]        ch_dm1_mready;

  wire [AW-1:0]   ch_dm1_ipv4_data  = ch_dm1_mdata[0*AW +: AW];
  wire [AW/8-1:0] ch_dm1_ipv4_keep  = ch_dm1_mkeep[0*(AW/8) +: AW/8];
  wire            ch_dm1_ipv4_last  = ch_dm1_mlast[0];
  wire            ch_dm1_ipv4_valid = ch_dm1_mvalid[0];
  wire [AW-1:0]   ch_dm1_arp_data   = ch_dm1_mdata[1*AW +: AW];
  wire [AW/8-1:0] ch_dm1_arp_keep   = ch_dm1_mkeep[1*(AW/8) +: AW/8];
  wire            ch_dm1_arp_last   = ch_dm1_mlast[1];
  wire            ch_dm1_arp_valid  = ch_dm1_mvalid[1];
  wire            ch_dm1_ipv4_ready, ch_dm1_arp_ready;
  assign ch_dm1_mready = {1'b1, ch_dm1_arp_ready, ch_dm1_ipv4_ready};

  eth_type_demux #(
    .TYPE_NUM            (2                  ),
    .TYPE_DICT           ({16'h0608,16'h0008})
  ) u_ch_demux (
    .clk                  (ch_clk200          ),
    .rst                  (ch_rst             ),
    .eth_axis_sdata       (ch_eth_rx_sdata    ),
    .eth_axis_skeep       (ch_eth_rx_skeep    ),
    .eth_axis_slast       (ch_eth_rx_slast    ),
    .eth_axis_svalid      (ch_eth_rx_svalid   ),
    .eth_axis_susr        (1'b0               ),
    .eth_axis_sready      (ch_eth_rx_sready   ),
    .eth_axis_mdata       (ch_dm1_mdata       ),
    .eth_axis_mkeep       (ch_dm1_mkeep       ),
    .eth_axis_mlast       (ch_dm1_mlast       ),
    .eth_axis_mvalid      (ch_dm1_mvalid      ),
    .eth_axis_musr        (ch_dm1_musr        ),
    .eth_axis_mready      (ch_dm1_mready      )
  );

  wire [AW*5-1:0]   ch_rxflat_mdata;
  wire [AW/8*5-1:0] ch_rxflat_mkeep;
  wire [4:0]        ch_rxflat_mlast, ch_rxflat_mvalid;
  wire [97*5-1:0]   ch_rxflat_musr ;
  wire [4:0]        ch_rxflat_mready;
  wire [AW-1:0]     ch_ipv4_rx_mdata = ch_rxflat_mdata[0*AW +: AW];
  wire [AW/8-1:0]   ch_ipv4_rx_mkeep = ch_rxflat_mkeep[0*(AW/8) +: AW/8];
  wire              ch_ipv4_rx_mlast = ch_rxflat_mlast[0];
  wire              ch_ipv4_rx_mvalid= ch_rxflat_mvalid[0];
  wire [96:0]       ch_ipv4_rx_musr  = ch_rxflat_musr[0*97 +: 97];
  wire              ch_ipv4_rx_mready;
  assign ch_rxflat_mready = {4'b1111, ch_ipv4_rx_mready};
  wire [47:0]      ch_rx_dest_mac = ch_ipv4_rx_musr[48:1];

  ipv4_top #(
    .RX_TYPE_NUM      (4                ),
    .TX_TYPE_NUM      (1                ),
    .AXIS_USER_WIDTH  (UW               )
  ) u_ch_dut (
    .clk                       (ch_clk200          ),
    .rst                       (ch_rst             ),
    .eth_ipv4_axis_sdata       (ch_dm1_ipv4_data   ),
    .eth_ipv4_axis_skeep       (ch_dm1_ipv4_keep   ),
    .eth_ipv4_axis_slast       (ch_dm1_ipv4_last   ),
    .eth_ipv4_axis_svalid      (ch_dm1_ipv4_valid  ),
    .eth_ipv4_axis_susr        (1'b0               ),
    .eth_ipv4_axis_sready      (ch_dm1_ipv4_ready  ),
    .ipv4_axis_mdata           (ch_rxflat_mdata    ),
    .ipv4_axis_mkeep           (ch_rxflat_mkeep    ),
    .ipv4_axis_mlast           (ch_rxflat_mlast    ),
    .ipv4_axis_mvalid          (ch_rxflat_mvalid   ),
    .ipv4_axis_musr            (ch_rxflat_musr     ),
    .ipv4_axis_mready          (ch_rxflat_mready   ),
    .ipv4_axis_sdata           (ch_tst_tx_mdata    ),
    .ipv4_axis_skeep           (ch_tst_tx_mkeep    ),
    .ipv4_axis_slast           (ch_tst_tx_mlast    ),
    .ipv4_axis_svalid          (ch_tst_tx_mvalid   ),
    .ipv4_axis_susr            (ch_tst_tx_musr     ),
    .ipv4_axis_sready          (ch_tst_tx_mready   ),
    .eth_tx_axis_mdata         (ch_eth_tx_mdata    ),
    .eth_tx_axis_mkeep         (ch_eth_tx_mkeep    ),
    .eth_tx_axis_mlast         (ch_eth_tx_mlast    ),
    .eth_tx_axis_mvalid        (ch_eth_tx_mvalid   ),
    .eth_tx_axis_musr          (ch_eth_tx_musr     ),
    .eth_tx_axis_mready        (ch_eth_tx_mready   ),
    .query_src_ip              (ch_q_src_ip        ),
    .query_dst_ip              (ch_q_ip            ),
    .query_valid_pulse         (ch_q_valid_pulse   ),
    .arp_dst_mac               (ch_r_mac           ),
    .arp_src_mac               (ch_r_src_mac       ),
    .arp_miss                  (ch_r_miss          ),
    .arp_valid                 (ch_r_valid         ),
    .stat_tx_active_port       (                   ),
    .stat_tx_idle              (                   )
  );

  arp_engine_top #(
    .AXIS_WIDTH(AW), .AXIS_TX_USR_WID(UW)
  ) u_ch_arp_eng (
    .clk                          (ch_clk200          ),
    .rst                          (ch_rst             ),
    .query_src_ip                 (ch_q_src_ip        ),
    .query_dst_ip                 (ch_q_ip            ),
    .query_valid_pulse            (ch_q_valid_pulse   ),
    .arp_dst_mac                  (ch_r_mac           ),
    .arp_src_mac                  (ch_r_src_mac       ),
    .arp_miss                     (ch_r_miss          ),
    .arp_valid                    (ch_r_valid         ),
    .arp_axis_sdata               (ch_dm1_arp_data    ),
    .arp_axis_skeep               (ch_dm1_arp_keep    ),
    .arp_axis_svalid              (ch_dm1_arp_valid   ),
    .arp_axis_slast               (ch_dm1_arp_last    ),
    .arp_axis_susr                (1'b0               ),
    .arp_axis_sready              (ch_dm1_arp_ready   ),
    .arp_axis_mdata               (ch_a_tx_mdata      ),
    .arp_axis_mkeep               (ch_a_tx_mkeep      ),
    .arp_axis_mvalid              (ch_a_tx_mvalid     ),
    .arp_axis_mlast               (ch_a_tx_mlast      ),
    .arp_axis_musr                (ch_a_tx_musr       ),
    .arp_axis_mready              (ch_a_tx_mready     ),
    .cfg_local_ip                 (ch_LOCAL_IP        ),
    .cfg_local_mac                (ch_LOCAL_MAC       ),
    .cfg_gateway_ip               (ch_GW_IP           ),
    .cfg_subnet_mask              (ch_SUBNET          ),
    .cfg_pending_time             (ch_PEND_TIME       ),
    .cfg_clear_cache              (1'b0               ),
    .cfg_clear_pending            (1'b0               ),
    .stat_rx_error                (ch_stat_rx_error   ),
    .stat_ack_fifo_overflow_error (ch_stat_ack_ovf    ),
    .stat_pending_fifo_overflow_error(ch_stat_pend_ovf),
    .stat_lookup_no_resp_error    (ch_stat_no_resp    ),
    .stat_pending_clear_finish    (ch_stat_pend_clr   ),
    .stat_cache_clear_finish      (ch_stat_cache_clr  ),
    .stat_query_src_not_local     (                   )
  );

  eth_tx_mux #(
    .TYPE_NUM         (2                ),
    .AXIS_USER_WIDTH  (UW               )
  ) u_ch_tx_mux (
    .clk(ch_clk200), .rst(ch_rst),
    .eth_axis_sdata(ch_mx_sdata), .eth_axis_skeep(ch_mx_skeep),
    .eth_axis_slast(ch_mx_slast), .eth_axis_svalid(ch_mx_svalid),
    .eth_axis_susr(ch_mx_susr),   .eth_axis_sready(ch_mx_sready),
    .eth_axis_mdata(ch_mx_mdata), .eth_axis_mkeep(ch_mx_mkeep), .eth_axis_mlast(ch_mx_mlast),
    .eth_axis_mvalid(ch_mx_mvalid), .eth_axis_musr(ch_mx_musr), .eth_axis_mready(ch_mx_mready),
    .stat_active_port(ch_stat_arb_port), .stat_idle(ch_stat_arb_idle)
  );

  eth_frame_pad60 #(.MIN_FRAME_BYTES(60)) u_ch_frame_pad (
    .clk(ch_clk200), .rst(ch_rst),
    .eth_axis_sdata(ch_mx_mdata), .eth_axis_skeep(ch_mx_mkeep),
    .eth_axis_slast(ch_mx_mlast), .eth_axis_svalid(ch_mx_mvalid), .eth_axis_sready(ch_mx_mready),
    .eth_axis_mdata(ch_pd_mdata), .eth_axis_mkeep(ch_pd_mkeep),
    .eth_axis_mlast(ch_pd_mlast), .eth_axis_mvalid(ch_pd_mvalid), .eth_axis_mready(ch_pd_mready)
  );

  // TX 异步 FIFO : 200M -> usr_clk
  wire [AW-1:0]    ch_tx_mdata ;  wire [AW/8-1:0] ch_tx_mkeep ;
  wire             ch_tx_mlast ;  wire            ch_tx_mvalid;
  wire             ch_tx_mready;
  axis_fifo_async #(
    .FIFO_DEPTH(512), .AXIS_WIDTH(AW), .AXIS_USER_WIDTH(UW), .PACKET_FIFO(0)
  ) u_ch_fifo_tx (
    .srst(ch_rst), .sclk(ch_clk200), .mclk(ch_usr_clk),
    .axis_sdata(ch_pd_mdata), .axis_skeep(ch_pd_mkeep), .axis_svalid(ch_pd_mvalid),
    .axis_slast(ch_pd_mlast), .axis_sready(ch_pd_mready), .axis_susr(1'b0),
    .axis_sstrb(64'd0), .axis_sid(1'b0), .axis_sdest(1'b0),
    .axis_mdata(ch_tx_mdata), .axis_mkeep(ch_tx_mkeep), .axis_mvalid(ch_tx_mvalid),
    .axis_mlast(ch_tx_mlast), .axis_mready(ch_tx_mready), .axis_musr(),
    .axis_mstrb(), .axis_mid(), .axis_mdest()
  );

  // RX 异步 FIFO : usr_clk -> 200M
  axis_fifo_async #(
    .FIFO_DEPTH(512), .AXIS_WIDTH(AW), .AXIS_USER_WIDTH(UW), .PACKET_FIFO(0)
  ) u_ch_fifo_rx (
    .srst(ch_rst), .sclk(ch_usr_clk), .mclk(ch_clk200),
    .axis_sdata(ch_tx_mdata), .axis_skeep(ch_tx_mkeep), .axis_svalid(ch_tx_mvalid),
    .axis_slast(ch_tx_mlast), .axis_sready(ch_tx_mready), .axis_susr(1'b0),
    .axis_sstrb(64'd0), .axis_sid(1'b0), .axis_sdest(1'b0),
    .axis_mdata(ch_eth_rx_sdata), .axis_mkeep(ch_eth_rx_skeep), .axis_mvalid(ch_eth_rx_svalid),
    .axis_mlast(ch_eth_rx_slast), .axis_mready(ch_eth_rx_sready), .axis_musr(),
    .axis_mstrb(), .axis_mid(), .axis_mdest()
  );

  reg ch_test_enable = 1'b0;
  ipv4_100g_tester #(
    .AXIS_WIDTH(AW), .AXIS_USER_WIDTH(UW), .PKT_LEN_BEATS(4),
    .ONE_SEC_CYCLES(32'd2_000), .AXIS_USER_VAL(TESTER_USR),
    .DST_IP_LE(ch_LOCAL_IP), .SRC_IP_LE(ch_LOCAL_IP)
  ) u_ch_tester (
    .clk(ch_clk200), .rst(ch_rst),
    .axis_mdata(ch_tst_tx_mdata), .axis_mkeep(ch_tst_tx_mkeep), .axis_mvalid(ch_tst_tx_mvalid),
    .axis_mlast(ch_tst_tx_mlast), .axis_musr(ch_tst_tx_musr), .axis_mready(ch_tst_tx_mready),
    .axis_sdata(ch_ipv4_rx_mdata), .axis_skeep(ch_ipv4_rx_mkeep), .axis_svalid(ch_ipv4_rx_mvalid),
    .axis_slast(ch_ipv4_rx_mlast), .axis_susr(4'd0), .axis_sready(ch_ipv4_rx_mready),
    .test_enable(ch_test_enable)
  );

  // 监视
  integer ch_tx_frame_cnt = 0, ch_rx_frame_cnt = 0, ch_rx_eth_frame_cnt = 0;
  integer ch_bad_mac_cnt = 0, ch_x_frame_cnt = 0;
  reg ch_tx_x_seen = 1'b0;

  always @(posedge ch_clk200) if (!ch_rst) begin
    if (ch_pd_mvalid && ch_pd_mready) begin
      if (^ch_pd_mdata === 1'bx) ch_tx_x_seen <= 1'b1;
      if (ch_pd_mlast) begin
        ch_tx_frame_cnt <= ch_tx_frame_cnt + 1;
        if (ch_tx_x_seen) ch_x_frame_cnt <= ch_x_frame_cnt + 1;
        ch_tx_x_seen <= 1'b0;
      end
    end
  end

  always @(posedge ch_clk200) if (!ch_rst)
    if (ch_eth_rx_svalid && ch_eth_rx_sready && ch_eth_rx_slast) ch_rx_eth_frame_cnt <= ch_rx_eth_frame_cnt + 1;

  always @(posedge ch_clk200) if (!ch_rst)
    if (ch_ipv4_rx_mvalid && ch_ipv4_rx_mready && ch_ipv4_rx_mlast) ch_rx_frame_cnt <= ch_rx_frame_cnt + 1;

  wire [31:0] ch_tst_err = u_ch_tester.rx_error_cnt;
  wire [35:0] ch_tst_bw  = u_ch_tester.rx_bw_bytes_per_s;
  reg         ch_tst_1st = 1'b0;
  always @(posedge ch_clk200) if (!ch_rst && ch_ipv4_rx_mvalid && ch_ipv4_rx_mready && ch_ipv4_rx_mlast) ch_tst_1st <= 1'b1;

  integer ch_err_total;
  task automatic ch_cyc(input integer n); integer i; begin for (i=0;i<n;i=i+1) @(posedge ch_clk200); end endtask

  task phase_chain;
    begin
      ch_err_total = 0;
      ch_rst = 1'b1;
      ch_cyc(20);
      ch_rst = 1'b0;
      ch_cyc(20);
      ch_test_enable = 1'b1;

      // T1: 清表期 + 首包(ARP 自解析)
      $display("--- [PHASE3 chain] T1: 上电 + ARP 自解析(经两个异步FIFO环回) ---");
      ch_cyc(4000);
      if (ch_tx_frame_cnt < 1) begin
        $display("  [FAIL] 线上未发出任何以太帧 (tx=%0d)", ch_tx_frame_cnt); ch_err_total=ch_err_total+1;
      end else $display("  [PASS] 线上已发出以太帧 %0d 帧", ch_tx_frame_cnt);
      if (ch_rx_eth_frame_cnt < 1) begin
        $display("  [FAIL] FIFO 环回后未收到以太帧"); ch_err_total=ch_err_total+1;
      end else $display("  [PASS] FIFO 环回收到以太帧 %0d 帧", ch_rx_eth_frame_cnt);
      if (ch_rx_frame_cnt < 1) begin
        $display("  [FAIL] 未收到剥头后的 IPv4 包"); ch_err_total=ch_err_total+1;
      end else $display("  [PASS] 收到剥头 IPv4 包 %0d 帧", ch_rx_frame_cnt);
      if (!ch_tst_1st) begin $display("  [FAIL] tester 未完成首包正确接收"); ch_err_total=ch_err_total+1; end
      else $display("  [PASS] tester 首包正确接收 (链路已通)");
      if (ch_tst_err !== 32'd0) begin
        $display("  [FAIL] 逐字节比对有误码: %0d", ch_tst_err); ch_err_total=ch_err_total+1;
      end else $display("  [PASS] 逐字节比对 0 误码 (跨两个异步FIFO)");
      if (ch_rx_dest_mac !== ch_LOCAL_MAC) begin
        $display("  [FAIL] dest_mac=%h 期望 %h", ch_rx_dest_mac, ch_LOCAL_MAC); ch_err_total=ch_err_total+1;
      end else $display("  [PASS] dest_mac = %h", ch_LOCAL_MAC);
      if (ch_bad_mac_cnt != 0 || ch_x_frame_cnt != 0) begin
        $display("  [FAIL] 线上异常帧: 坏目的MAC=%0d 含X=%0d", ch_bad_mac_cnt, ch_x_frame_cnt); ch_err_total=ch_err_total+1;
      end else $display("  [PASS] 线上帧目的 MAC 正常、无 X");

      // T2: 长跑 + 停流后 FIFO 必须排空
      $display("--- [PHASE3 chain] T2: 长跑 + 停流后 FIFO 排空 ---");
      ch_cyc(6000);
      if (ch_tst_err !== 32'd0) begin
        $display("  [FAIL] 长跑出现误码 %0d", ch_tst_err); ch_err_total=ch_err_total+1;
      end else $display("  [PASS] 长跑 0 误码 (rx=%0d 帧)", ch_rx_frame_cnt);
      ch_test_enable = 1'b0;
      ch_cyc(600);
      if (ch_eth_rx_svalid || ch_tx_mvalid || ch_pd_mvalid)
        $display("  [INFO] 停流后仍在途: fifo_tx_mv=%b fifo_rx_mv=%b dut_tx_mv=%b", ch_tx_mvalid, ch_eth_rx_svalid, ch_pd_mvalid);
      else
        $display("  [PASS] 停流后所有 FIFO/通路已排空(无残留)");

      $display(" 统计: 线上以太帧=%0d | FIFO环回以太帧=%0d | 剥头IPv4=%0d | 误码=%0d | 坏MAC=%0d 含X=%0d",
               ch_tx_frame_cnt, ch_rx_eth_frame_cnt, ch_rx_frame_cnt, ch_tst_err, ch_bad_mac_cnt, ch_x_frame_cnt);
      $display("       (1秒等效吞吐: %0d Byte/s)", ch_tst_bw);
      $display("----------------------------------------------------------------");
      if (ch_err_total==0) $display(" [PHASE3 chain] *** PASS ***");
      else                 $display(" [PHASE3 chain] *** %0d CHECK(S) FAILED ***", ch_err_total);
      $display("----------------------------------------------------------------");
    end
  endtask

  // ============================================================================
  // PHASE 4 : dual_flow   (原 tb_ipv4_dual_flow)
  // 双网口直连: 两个 ipv4_top 对接, P1 打流 -> P2 应答 -> P3 数据直达
  // ============================================================================
  localparam integer df_PKT_B = 4;
  localparam [31:0] df_P1_IP   = 32'h0101_A8C0;   // 网口1: 192.168.1.1
  localparam [47:0] df_P1_MAC  = 48'h554433221101;
  localparam [31:0] df_P2_IP   = 32'h0201_A8C0;   // 网口2: 192.168.1.2
  localparam [47:0] df_P2_MAC  = 48'h665544332202;
  localparam [31:0] df_GW_IP   = 32'h0101_A8C0;
  localparam [31:0] df_SUBNET  = 32'h00FF_FFFF;
  localparam [56:0] df_PEND_T  = 57'd200_000;
  localparam integer df_MAX_WAIT = 200_000;

  reg df_clk = 1'b0;
  always #2.5 df_clk = ~df_clk;                     // 200 MHz
  reg df_rst = 1'b1;

  // ---- 网口1 ----
  wire [AW-1:0]    df_p1_tx_data ;  wire [AW/8-1:0] df_p1_tx_keep ;
  wire             df_p1_tx_last ;  wire            df_p1_tx_valid;
  wire             df_p1_tx_ready;  wire [UW-1:0]   df_p1_tx_user ;

  wire [AW*5-1:0]   df_p1_rxflat_mdata;
  wire [AW/8*5-1:0] df_p1_rxflat_mkeep;
  wire [4:0]        df_p1_rxflat_mlast, df_p1_rxflat_mvalid;
  wire [97*5-1:0]   df_p1_rxflat_musr ;
  wire [4:0]        df_p1_rxflat_mready;
  wire [AW-1:0]     df_p1_rx_data    = df_p1_rxflat_mdata   [0*AW     +: AW  ];
  wire [AW/8-1:0]   df_p1_rx_keep    = df_p1_rxflat_mkeep   [0*(AW/8) +: AW/8];
  wire              df_p1_rx_last    = df_p1_rxflat_mlast   [0               ];
  wire              df_p1_rx_valid   = df_p1_rxflat_mvalid  [0               ];
  wire [96:0]       df_p1_rx_usr     = df_p1_rxflat_musr    [0*97     +: 97  ];
  wire              df_p1_rx_ready;
  assign df_p1_rxflat_mready = {4'b1111, df_p1_rx_ready};
  wire [47:0]      df_p1_dest_mac   = df_p1_rx_usr[48:1];

  wire [AW-1:0]    df_t1_data ;  wire [AW/8-1:0] df_t1_keep ;
  wire             df_t1_last ;  wire            df_t1_valid;
  wire             df_t1_ready;  wire [UW-1:0]   df_t1_user ;

  wire        df_p1_stat_rx_error, df_p1_stat_ack_ovf, df_p1_stat_pend_ovf, df_p1_stat_no_resp;
  wire        df_p1_pend_clr, df_p1_cache_clr, df_p1_arb_port, df_p1_arb_idle;

  wire [AW*3-1:0]   df_dm1_mdata;
  wire [AW/8*3-1:0] df_dm1_mkeep;
  wire [2:0]        df_dm1_mlast, df_dm1_mvalid, df_dm1_musr;
  wire [2:0]        df_dm1_mready;

  wire [AW-1:0]     df_dm1_ipv4_data  = df_dm1_mdata [0*AW     +: AW  ];
  wire [AW/8-1:0]   df_dm1_ipv4_keep  = df_dm1_mkeep [0*(AW/8) +: AW/8];
  wire              df_dm1_ipv4_last  = df_dm1_mlast [0               ];
  wire              df_dm1_ipv4_valid = df_dm1_mvalid[0               ];
  wire [AW-1:0]     df_dm1_arp_data   = df_dm1_mdata [1*AW     +: AW  ];
  wire [AW/8-1:0]   df_dm1_arp_keep   = df_dm1_mkeep [1*(AW/8) +: AW/8];
  wire              df_dm1_arp_last   = df_dm1_mlast [1               ];
  wire              df_dm1_arp_valid  = df_dm1_mvalid[1               ];
  wire              df_dm1_ipv4_ready, df_dm1_arp_ready;
  assign df_dm1_mready = {1'b1, df_dm1_arp_ready, df_dm1_ipv4_ready};

  wire [AW*3-1:0]   df_dm2_mdata;
  wire [AW/8*3-1:0] df_dm2_mkeep;
  wire [2:0]        df_dm2_mlast, df_dm2_mvalid, df_dm2_musr;
  wire [2:0]        df_dm2_mready;

  wire [AW-1:0]     df_dm2_ipv4_data  = df_dm2_mdata [0*AW     +: AW  ];
  wire [AW/8-1:0]   df_dm2_ipv4_keep  = df_dm2_mkeep [0*(AW/8) +: AW/8];
  wire              df_dm2_ipv4_last  = df_dm2_mlast [0               ];
  wire              df_dm2_ipv4_valid = df_dm2_mvalid[0               ];
  wire [AW-1:0]     df_dm2_arp_data   = df_dm2_mdata [1*AW     +: AW  ];
  wire [AW/8-1:0]   df_dm2_arp_keep   = df_dm2_mkeep [1*(AW/8) +: AW/8];
  wire              df_dm2_arp_last   = df_dm2_mlast [1               ];
  wire              df_dm2_arp_valid  = df_dm2_mvalid[1               ];
  wire              df_dm2_ipv4_ready, df_dm2_arp_ready;
  assign df_dm2_mready = {1'b1, df_dm2_arp_ready, df_dm2_ipv4_ready};

  // 网口2 线上帧 net 前置声明(供 u_df_demux_1 引用, 避免前向引用导致的隐式声明)
  wire [AW-1:0]    df_p2_tx_data ;
  wire [AW/8-1:0]  df_p2_tx_keep ;
  wire             df_p2_tx_last ;
  wire             df_p2_tx_valid;
  wire             df_p2_tx_ready;
  wire [UW-1:0]    df_p2_tx_user ;

  eth_type_demux #(
    .TYPE_NUM            (2                  ),
    .TYPE_DICT           ({ETH_ARP,ETH_IPV4} )
  ) u_df_demux_1 (
    .clk                 (df_clk             ),
    .rst                 (df_rst             ),
    .eth_axis_sdata      (df_p2_tx_data      ),
    .eth_axis_skeep      (df_p2_tx_keep      ),
    .eth_axis_slast      (df_p2_tx_last      ),
    .eth_axis_svalid     (df_p2_tx_valid     ),
    .eth_axis_susr       (1'b0               ),
    .eth_axis_sready     (df_p2_tx_ready     ),
    .eth_axis_mdata      (df_dm1_mdata       ),
    .eth_axis_mkeep      (df_dm1_mkeep       ),
    .eth_axis_mlast      (df_dm1_mlast       ),
    .eth_axis_mvalid     (df_dm1_mvalid      ),
    .eth_axis_musr       (df_dm1_musr        ),
    .eth_axis_mready     (df_dm1_mready      )
  );

  eth_type_demux #(
    .TYPE_NUM            (2                  ),
    .TYPE_DICT           ({ETH_ARP,ETH_IPV4} )
  ) u_df_demux_2 (
    .clk                 (df_clk             ),
    .rst                 (df_rst             ),
    .eth_axis_sdata      (df_p1_tx_data      ),
    .eth_axis_skeep      (df_p1_tx_keep      ),
    .eth_axis_slast      (df_p1_tx_last      ),
    .eth_axis_svalid     (df_p1_tx_valid     ),
    .eth_axis_susr       (1'b0               ),
    .eth_axis_sready     (df_p1_tx_ready     ),
    .eth_axis_mdata      (df_dm2_mdata       ),
    .eth_axis_mkeep      (df_dm2_mkeep       ),
    .eth_axis_mlast      (df_dm2_mlast       ),
    .eth_axis_mvalid     (df_dm2_mvalid      ),
    .eth_axis_musr       (df_dm2_musr        ),
    .eth_axis_mready     (df_dm2_mready      )
  );

  // ---- 网口1: ipv4_top TX 以太帧 / ARP 引擎 TX / 查询握手 ----
  wire [AW-1:0]    df_p1_i4tx_data ;  wire [AW/8-1:0] df_p1_i4tx_keep ;
  wire             df_p1_i4tx_last ;  wire            df_p1_i4tx_valid;
  wire             df_p1_i4tx_ready;  wire [UW-1:0]   df_p1_i4tx_usr  ;
  wire [AW-1:0]    df_p1_atx_data  ;  wire [AW/8-1:0] df_p1_atx_keep  ;
  wire             df_p1_atx_last  ;  wire            df_p1_atx_valid ;
  wire             df_p1_atx_ready ;  wire [UW-1:0]   df_p1_atx_usr   ;

  wire [31:0]      df_p1_q_src     ;  wire [31:0]      df_p1_q_dst    ;
  wire             df_p1_q_valid   ;
  wire [47:0]      df_p1_r_mac     ;  wire [47:0]      df_p1_r_src_mac;
  wire             df_p1_r_miss, df_p1_r_valid;

  ipv4_top #(
    .RX_TYPE_NUM      (4                ),
    .TX_TYPE_NUM      (1                ),
    .AXIS_USER_WIDTH  (UW               )
  ) u_df_port1 (
    .clk                       (df_clk            ),
    .rst                       (df_rst            ),
    .eth_ipv4_axis_sdata       (df_dm1_ipv4_data  ),
    .eth_ipv4_axis_skeep       (df_dm1_ipv4_keep  ),
    .eth_ipv4_axis_slast       (df_dm1_ipv4_last  ),
    .eth_ipv4_axis_svalid      (df_dm1_ipv4_valid ),
    .eth_ipv4_axis_susr        (1'b0              ),
    .eth_ipv4_axis_sready      (df_dm1_ipv4_ready ),
    .ipv4_axis_mdata           (df_p1_rxflat_mdata ),
    .ipv4_axis_mkeep           (df_p1_rxflat_mkeep ),
    .ipv4_axis_mlast           (df_p1_rxflat_mlast ),
    .ipv4_axis_mvalid          (df_p1_rxflat_mvalid),
    .ipv4_axis_musr            (df_p1_rxflat_musr  ),
    .ipv4_axis_mready          (df_p1_rxflat_mready),
    .ipv4_axis_sdata           (df_t1_data        ),
    .ipv4_axis_skeep           (df_t1_keep        ),
    .ipv4_axis_slast           (df_t1_last        ),
    .ipv4_axis_svalid          (df_t1_valid       ),
    .ipv4_axis_susr            (df_t1_user        ),
    .ipv4_axis_sready          (df_t1_ready       ),
    .eth_tx_axis_mdata         (df_p1_i4tx_data   ),
    .eth_tx_axis_mkeep         (df_p1_i4tx_keep   ),
    .eth_tx_axis_mlast         (df_p1_i4tx_last   ),
    .eth_tx_axis_mvalid        (df_p1_i4tx_valid  ),
    .eth_tx_axis_musr          (df_p1_i4tx_usr    ),
    .eth_tx_axis_mready        (df_p1_i4tx_ready  ),
    .query_src_ip              (df_p1_q_src       ),
    .query_dst_ip              (df_p1_q_dst       ),
    .query_valid_pulse         (df_p1_q_valid     ),
    .arp_dst_mac               (df_p1_r_mac       ),
    .arp_src_mac               (df_p1_r_src_mac   ),
    .arp_miss                  (df_p1_r_miss      ),
    .arp_valid                 (df_p1_r_valid     ),
    .stat_tx_active_port       (                  ),
    .stat_tx_idle              (                  )
  );

  arp_engine_top #(
    .AXIS_WIDTH(AW), .CACHE_DEEP(64), .PENDING_DEEP(64), .LOCAL_IP_NUM(1),
    .AXIS_TX_USR_WID(UW)
  ) u_df_arp_eng1 (
    .clk                          (df_clk            ),
    .rst                          (df_rst            ),
    .query_src_ip                 (df_p1_q_src       ),
    .query_dst_ip                 (df_p1_q_dst       ),
    .query_valid_pulse            (df_p1_q_valid     ),
    .arp_dst_mac                  (df_p1_r_mac       ),
    .arp_src_mac                  (df_p1_r_src_mac   ),
    .arp_miss                     (df_p1_r_miss      ),
    .arp_valid                    (df_p1_r_valid     ),
    .arp_axis_sdata               (df_dm1_arp_data   ),
    .arp_axis_skeep               (df_dm1_arp_keep   ),
    .arp_axis_svalid              (df_dm1_arp_valid  ),
    .arp_axis_slast               (df_dm1_arp_last   ),
    .arp_axis_susr                (1'b0              ),
    .arp_axis_sready              (df_dm1_arp_ready  ),
    .arp_axis_mdata               (df_p1_atx_data    ),
    .arp_axis_mkeep               (df_p1_atx_keep    ),
    .arp_axis_mvalid              (df_p1_atx_valid   ),
    .arp_axis_mlast               (df_p1_atx_last    ),
    .arp_axis_musr                (df_p1_atx_usr     ),
    .arp_axis_mready              (df_p1_atx_ready   ),
    .cfg_local_ip                 (df_P1_IP          ),
    .cfg_local_mac                (df_P1_MAC         ),
    .cfg_gateway_ip               (df_GW_IP          ),
    .cfg_subnet_mask              (df_SUBNET         ),
    .cfg_pending_time             (df_PEND_T         ),
    .cfg_clear_cache              (1'b0              ),
    .cfg_clear_pending            (1'b0              ),
    .stat_rx_error                    (df_p1_stat_rx_error ),
    .stat_ack_fifo_overflow_error     (df_p1_stat_ack_ovf  ),
    .stat_pending_fifo_overflow_error (df_p1_stat_pend_ovf ),
    .stat_lookup_no_resp_error        (df_p1_stat_no_resp  ),
    .stat_pending_clear_finish        (df_p1_pend_clr      ),
    .stat_cache_clear_finish          (df_p1_cache_clr     ),
    .stat_query_src_not_local         (                    )
  );

  wire [AW*2-1:0]   df_mx1_sdata = {df_p1_i4tx_data , df_p1_atx_data };
  wire [AW/8*2-1:0] df_mx1_skeep = {df_p1_i4tx_keep , df_p1_atx_keep };
  wire [1:0]        df_mx1_slast = {df_p1_i4tx_last , df_p1_atx_last };
  wire [1:0]        df_mx1_svalid= {df_p1_i4tx_valid, df_p1_atx_valid};
  wire [UW*2-1:0]   df_mx1_susr  = {df_p1_i4tx_usr  , df_p1_atx_usr  };
  wire [1:0]        df_mx1_sready;
  assign {df_p1_i4tx_ready, df_p1_atx_ready} = df_mx1_sready;

  eth_tx_mux #(
    .TYPE_NUM         (2                ),
    .AXIS_USER_WIDTH  (UW               )
  ) u_df_tx_mux1 (
    .clk              (df_clk              ),
    .rst              (df_rst              ),
    .eth_axis_sdata   (df_mx1_sdata        ),
    .eth_axis_skeep   (df_mx1_skeep        ),
    .eth_axis_slast   (df_mx1_slast        ),
    .eth_axis_svalid  (df_mx1_svalid       ),
    .eth_axis_susr    (df_mx1_susr         ),
    .eth_axis_sready  (df_mx1_sready       ),
    .eth_axis_mdata   (df_p1_tx_data       ),
    .eth_axis_mkeep   (df_p1_tx_keep       ),
    .eth_axis_mlast   (df_p1_tx_last       ),
    .eth_axis_mvalid  (df_p1_tx_valid      ),
    .eth_axis_musr    (df_p1_tx_user       ),
    .eth_axis_mready  (df_p1_tx_ready      ),
    .stat_active_port (df_p1_arb_port      ),
    .stat_idle        (df_p1_arb_idle      )
  );

  // ---- 网口2 ----
  wire [AW*5-1:0]   df_p2_rxflat_mdata;
  wire [AW/8*5-1:0] df_p2_rxflat_mkeep;
  wire [4:0]        df_p2_rxflat_mlast, df_p2_rxflat_mvalid;
  wire [97*5-1:0]   df_p2_rxflat_musr ;
  wire [4:0]        df_p2_rxflat_mready;
  wire [AW-1:0]     df_p2_rx_data    = df_p2_rxflat_mdata   [0*AW     +: AW  ];
  wire [AW/8-1:0]   df_p2_rx_keep    = df_p2_rxflat_mkeep   [0*(AW/8) +: AW/8];
  wire              df_p2_rx_last    = df_p2_rxflat_mlast   [0               ];
  wire              df_p2_rx_valid   = df_p2_rxflat_mvalid  [0               ];
  wire [96:0]       df_p2_rx_usr     = df_p2_rxflat_musr    [0*97     +: 97  ];
  wire              df_p2_rx_ready;
  assign df_p2_rxflat_mready = {4'b1111, df_p2_rx_ready};
  wire [47:0]      df_p2_dest_mac   = df_p2_rx_usr[48:1];

  wire [AW-1:0]    df_t2_data ;  wire [AW/8-1:0] df_t2_keep ;
  wire             df_t2_last ;  wire            df_t2_valid;
  wire             df_t2_ready;  wire [UW-1:0]   df_t2_user ;

  wire        df_p2_stat_rx_error, df_p2_stat_ack_ovf, df_p2_stat_pend_ovf, df_p2_stat_no_resp;
  wire        df_p2_pend_clr, df_p2_cache_clr, df_p2_arb_port, df_p2_arb_idle;

  wire [AW-1:0]    df_p2_i4tx_data ;  wire [AW/8-1:0] df_p2_i4tx_keep ;
  wire             df_p2_i4tx_last ;  wire            df_p2_i4tx_valid;
  wire             df_p2_i4tx_ready;  wire [UW-1:0]   df_p2_i4tx_usr  ;
  wire [AW-1:0]    df_p2_atx_data  ;  wire [AW/8-1:0] df_p2_atx_keep  ;
  wire             df_p2_atx_last  ;  wire            df_p2_atx_valid ;
  wire             df_p2_atx_ready ;  wire [UW-1:0]   df_p2_atx_usr   ;

  wire [31:0]      df_p2_q_src     ;  wire [31:0]      df_p2_q_dst    ;
  wire             df_p2_q_valid   ;
  wire [47:0]      df_p2_r_mac     ;  wire [47:0]      df_p2_r_src_mac;
  wire             df_p2_r_miss, df_p2_r_valid;

  ipv4_top #(
    .RX_TYPE_NUM      (4                ),
    .TX_TYPE_NUM      (1                ),
    .AXIS_USER_WIDTH  (UW               )
  ) u_df_port2 (
    .clk                       (df_clk            ),
    .rst                       (df_rst            ),
    .eth_ipv4_axis_sdata       (df_dm2_ipv4_data  ),
    .eth_ipv4_axis_skeep       (df_dm2_ipv4_keep  ),
    .eth_ipv4_axis_slast       (df_dm2_ipv4_last  ),
    .eth_ipv4_axis_svalid      (df_dm2_ipv4_valid ),
    .eth_ipv4_axis_susr        (1'b0              ),
    .eth_ipv4_axis_sready      (df_dm2_ipv4_ready ),
    .ipv4_axis_mdata           (df_p2_rxflat_mdata ),
    .ipv4_axis_mkeep           (df_p2_rxflat_mkeep ),
    .ipv4_axis_mlast           (df_p2_rxflat_mlast ),
    .ipv4_axis_mvalid          (df_p2_rxflat_mvalid),
    .ipv4_axis_musr            (df_p2_rxflat_musr  ),
    .ipv4_axis_mready          (df_p2_rxflat_mready),
    .ipv4_axis_sdata           (df_t2_data        ),
    .ipv4_axis_skeep           (df_t2_keep        ),
    .ipv4_axis_slast           (df_t2_last        ),
    .ipv4_axis_svalid          (df_t2_valid       ),
    .ipv4_axis_susr            (df_t2_user        ),
    .ipv4_axis_sready          (df_t2_ready       ),
    .eth_tx_axis_mdata         (df_p2_i4tx_data   ),
    .eth_tx_axis_mkeep         (df_p2_i4tx_keep   ),
    .eth_tx_axis_mlast         (df_p2_i4tx_last   ),
    .eth_tx_axis_mvalid        (df_p2_i4tx_valid  ),
    .eth_tx_axis_musr          (df_p2_i4tx_usr    ),
    .eth_tx_axis_mready        (df_p2_i4tx_ready  ),
    .query_src_ip              (df_p2_q_src       ),
    .query_dst_ip              (df_p2_q_dst       ),
    .query_valid_pulse         (df_p2_q_valid     ),
    .arp_dst_mac               (df_p2_r_mac       ),
    .arp_src_mac               (df_p2_r_src_mac   ),
    .arp_miss                  (df_p2_r_miss      ),
    .arp_valid                 (df_p2_r_valid     ),
    .stat_tx_active_port       (                  ),
    .stat_tx_idle              (                  )
  );

  arp_engine_top #(
    .AXIS_WIDTH(AW), .CACHE_DEEP(64), .PENDING_DEEP(64), .LOCAL_IP_NUM(1),
    .AXIS_TX_USR_WID(UW)
  ) u_df_arp_eng2 (
    .clk                          (df_clk            ),
    .rst                          (df_rst            ),
    .query_src_ip                 (df_p2_q_src       ),
    .query_dst_ip                 (df_p2_q_dst       ),
    .query_valid_pulse            (df_p2_q_valid     ),
    .arp_dst_mac                  (df_p2_r_mac       ),
    .arp_src_mac                  (df_p2_r_src_mac   ),
    .arp_miss                     (df_p2_r_miss      ),
    .arp_valid                    (df_p2_r_valid     ),
    .arp_axis_sdata               (df_dm2_arp_data   ),
    .arp_axis_skeep               (df_dm2_arp_keep   ),
    .arp_axis_svalid              (df_dm2_arp_valid  ),
    .arp_axis_slast               (df_dm2_arp_last   ),
    .arp_axis_susr                (1'b0              ),
    .arp_axis_sready              (df_dm2_arp_ready  ),
    .arp_axis_mdata               (df_p2_atx_data    ),
    .arp_axis_mkeep               (df_p2_atx_keep    ),
    .arp_axis_mvalid              (df_p2_atx_valid   ),
    .arp_axis_mlast               (df_p2_atx_last    ),
    .arp_axis_musr                (df_p2_atx_usr     ),
    .arp_axis_mready              (df_p2_atx_ready   ),
    .cfg_local_ip                 (df_P2_IP          ),
    .cfg_local_mac                (df_P2_MAC         ),
    .cfg_gateway_ip               (df_GW_IP          ),
    .cfg_subnet_mask              (df_SUBNET         ),
    .cfg_pending_time             (df_PEND_T         ),
    .cfg_clear_cache              (1'b0              ),
    .cfg_clear_pending            (1'b0              ),
    .stat_rx_error                    (df_p2_stat_rx_error ),
    .stat_ack_fifo_overflow_error     (df_p2_stat_ack_ovf  ),
    .stat_pending_fifo_overflow_error (df_p2_stat_pend_ovf ),
    .stat_lookup_no_resp_error        (df_p2_stat_no_resp  ),
    .stat_pending_clear_finish        (df_p2_pend_clr      ),
    .stat_cache_clear_finish          (df_p2_cache_clr     ),
    .stat_query_src_not_local         (                    )
  );

  wire [AW*2-1:0]   df_mx2_sdata = {df_p2_i4tx_data , df_p2_atx_data };
  wire [AW/8*2-1:0] df_mx2_skeep = {df_p2_i4tx_keep , df_p2_atx_keep };
  wire [1:0]        df_mx2_slast = {df_p2_i4tx_last , df_p2_atx_last };
  wire [1:0]        df_mx2_svalid= {df_p2_i4tx_valid, df_p2_atx_valid};
  wire [UW*2-1:0]   df_mx2_susr  = {df_p2_i4tx_usr  , df_p2_atx_usr  };
  wire [1:0]        df_mx2_sready;
  assign {df_p2_i4tx_ready, df_p2_atx_ready} = df_mx2_sready;

  eth_tx_mux #(
    .TYPE_NUM         (2                ),
    .AXIS_USER_WIDTH  (UW               )
  ) u_df_tx_mux2 (
    .clk              (df_clk              ),
    .rst              (df_rst              ),
    .eth_axis_sdata   (df_mx2_sdata        ),
    .eth_axis_skeep   (df_mx2_skeep        ),
    .eth_axis_slast   (df_mx2_slast        ),
    .eth_axis_svalid  (df_mx2_svalid       ),
    .eth_axis_susr    (df_mx2_susr         ),
    .eth_axis_sready  (df_mx2_sready       ),
    .eth_axis_mdata   (df_p2_tx_data       ),
    .eth_axis_mkeep   (df_p2_tx_keep       ),
    .eth_axis_mlast   (df_p2_tx_last       ),
    .eth_axis_mvalid  (df_p2_tx_valid      ),
    .eth_axis_musr    (df_p2_tx_user       ),
    .eth_axis_mready  (df_p2_tx_ready      ),
    .stat_active_port (df_p2_arb_port      ),
    .stat_idle        (df_p2_arb_idle      )
  );

  // 打流机(网口1) / 校验机(网口2)
  ipv4_100g_tester #(
    .AXIS_WIDTH(AW), .AXIS_USER_WIDTH(UW), .PKT_LEN_BEATS(df_PKT_B),
    .ONE_SEC_CYCLES(32'd2_000), .AXIS_USER_VAL(TESTER_USR),
    .DST_IP_LE(df_P2_IP), .SRC_IP_LE(df_P1_IP)
  ) u_df_tester1 (
    .clk(df_clk), .rst(df_rst),
    .axis_mdata(df_t1_data), .axis_mkeep(df_t1_keep), .axis_mvalid(df_t1_valid),
    .axis_mlast(df_t1_last), .axis_musr(df_t1_user), .axis_mready(df_t1_ready),
    .axis_sdata(df_p1_rx_data), .axis_skeep(df_p1_rx_keep), .axis_svalid(df_p1_rx_valid),
    .axis_slast(df_p1_rx_last), .axis_susr(4'd0), .axis_sready(df_p1_rx_ready),
    .test_enable(1'b1)
  );

  ipv4_100g_tester #(
    .AXIS_WIDTH(AW), .AXIS_USER_WIDTH(UW), .PKT_LEN_BEATS(df_PKT_B),
    .ONE_SEC_CYCLES(32'd2_000), .AXIS_USER_VAL(TESTER_USR),
    .DST_IP_LE(df_P2_IP), .SRC_IP_LE(df_P1_IP)
  ) u_df_tester2 (
    .clk(df_clk), .rst(df_rst),
    .axis_mdata(df_t2_data), .axis_mkeep(df_t2_keep), .axis_mvalid(df_t2_valid),
    .axis_mlast(df_t2_last), .axis_musr(df_t2_user), .axis_mready(df_t2_ready),
    .axis_sdata(df_p2_rx_data), .axis_skeep(df_p2_rx_keep), .axis_svalid(df_p2_rx_valid),
    .axis_slast(df_p2_rx_last), .axis_susr(4'd0), .axis_sready(df_p2_rx_ready),
    .test_enable(1'b0)
  );

  // ARP 帧识别
  wire        df_p1_is_arp = (df_p1_tx_last && (df_p1_tx_data[111:96] == 16'h0608));
  wire        df_p2_is_arp = (df_p2_tx_last && (df_p2_tx_data[111:96] == 16'h0608));
  wire [15:0] df_p1_oper   = df_p1_tx_data[175:160];
  wire [15:0] df_p2_oper   = df_p2_tx_data[175:160];

  reg df_p1_arp_req_seen = 1'b0;
  reg df_p2_arp_rep_seen = 1'b0;
  always @(posedge df_clk) begin
    if (df_rst) begin
      df_p1_arp_req_seen <= 1'b0;
      df_p2_arp_rep_seen <= 1'b0;
    end else begin
      if (df_p1_tx_valid && df_p1_tx_ready && df_p1_is_arp && (df_p1_oper == 16'h0100)) df_p1_arp_req_seen <= 1'b1;
      if (df_p2_tx_valid && df_p2_tx_ready && df_p2_is_arp && (df_p2_oper == 16'h0200)) df_p2_arp_rep_seen <= 1'b1;
    end
  end

  // 计数
  integer df_offered_cnt = 0;
  integer df_p1_tx_frame = 0;
  integer df_p2_rx_frame = 0;
  always @(posedge df_clk) begin
    if (!df_rst) begin
      if (df_t1_valid && df_t1_ready && df_t1_last)          df_offered_cnt <= df_offered_cnt + 1;
      if (df_p1_tx_valid && df_p1_tx_ready && df_p1_tx_last) df_p1_tx_frame <= df_p1_tx_frame + 1;
      if (df_p2_rx_valid && df_p2_rx_ready && df_p2_rx_last) df_p2_rx_frame <= df_p2_rx_frame + 1;
    end
  end

  reg df_p2_first_pkt_seen = 1'b0;
  always @(posedge df_clk) begin
    if (df_rst) df_p2_first_pkt_seen <= 1'b0;
    else if (df_p2_rx_valid && df_p2_rx_ready && df_p2_rx_last) df_p2_first_pkt_seen <= 1'b1;
  end
  wire df_p1_data_ok = df_p2_first_pkt_seen;

  integer df_err_cnt = 0;
  integer df_wait_cnt = 0;

  task phase_dual_flow;
    begin
      df_rst = 1'b1;
      repeat (20) @(posedge df_clk);
      df_rst = 1'b0;
      $display("================================================================");
      $display(" [PHASE4 dual_flow] IPv4 双网口打流实验:  网口1 -> 网口2 (目的 IP = 192.168.1.2)");
      $display("================================================================");

      // P1
      $display("--- [PHASE4] P1: 网口1 打流(无网口2 信息) => 业务包丢弃 + 发 ARP 请求 ---");
      df_wait_cnt = 0;
      while (!df_p1_arp_req_seen && (df_wait_cnt < df_MAX_WAIT)) begin @(posedge df_clk); df_wait_cnt = df_wait_cnt + 1; end
      if (!df_p1_arp_req_seen) begin
        $display("  [FAIL] P1 未发出 ARP 请求"); df_err_cnt = df_err_cnt + 1;
      end else begin
        $display("  [PASS] 网口1 已发出 ARP 请求 (等待 %0d 拍)", df_wait_cnt);
        $display("  [INFO] 期间打流 %0d 包, 线上仅 %0d 帧 => 丢弃 %0d 个 (符合预期)",
                 df_offered_cnt, df_p1_tx_frame, df_offered_cnt - df_p1_tx_frame);
      end
      if (df_p1_data_ok) begin
        $display("  [FAIL] P1 阶段网口2 不应收到业务包"); df_err_cnt = df_err_cnt + 1;
      end else $display("  [PASS] 此时网口2 尚未收到业务包(符合预期)");

      // P2
      $display("--- [PHASE4] P2: 网口2 收到 ARP 请求并作出应答 ---");
      df_wait_cnt = 0;
      while (!df_p2_arp_rep_seen && (df_wait_cnt < df_MAX_WAIT)) begin @(posedge df_clk); df_wait_cnt = df_wait_cnt + 1; end
      if (!df_p2_arp_rep_seen) begin
        $display("  [FAIL] P2 网口2 未发出 ARP 应答"); df_err_cnt = df_err_cnt + 1;
      end else $display("  [PASS] 网口2 已作出 ARP 应答 (等待 %0d 拍)", df_wait_cnt);
      if ((df_p2_stat_rx_error !== 1'b0) || (df_p2_stat_ack_ovf !== 1'b0) || (df_p2_stat_pend_ovf !== 1'b0)) begin
        $display("  [FAIL] 网口2 内部统计异常: rx_err=%b ack_ovf=%b pend_ovf=%b",
                 df_p2_stat_rx_error, df_p2_stat_ack_ovf, df_p2_stat_pend_ovf); df_err_cnt = df_err_cnt + 1;
      end else $display("  [PASS] 网口2 ARP 引擎统计干净");

      // P3
      $display("--- [PHASE4] P3: 网口1 收到 ARP 应答 => 业务包不再丢弃, 直达网口2 ---");
      df_wait_cnt = 0;
      while (!df_p1_data_ok && (df_wait_cnt < df_MAX_WAIT)) begin @(posedge df_clk); df_wait_cnt = df_wait_cnt + 1; end
      if (!df_p1_data_ok) begin
        $display("  [FAIL] P3 网口2 始终未正确收到业务包"); df_err_cnt = df_err_cnt + 1;
      end else begin
        $display("  [PASS] 网口2 已正确收到业务包 (解析后等待 %0d 拍)", df_wait_cnt);
        if (u_df_tester2.rx_error_cnt !== 32'd0) begin
          $display("  [FAIL] 校验机误码 = %0d", u_df_tester2.rx_error_cnt); df_err_cnt = df_err_cnt + 1;
        end else $display("  [PASS] 校验机逐字节比对 0 误码");
        if (df_p2_dest_mac !== df_P2_MAC) begin
          $display("  [FAIL] 业务帧目的 MAC=%h, 应为网口2 的 MAC %h", df_p2_dest_mac, df_P2_MAC); df_err_cnt = df_err_cnt + 1;
        end else $display("  [PASS] 业务帧目的 MAC = 网口2 的 MAC (%h) = ARP 解析结果", df_P2_MAC);
        repeat (2000) @(posedge df_clk);
        if (u_df_tester2.rx_error_cnt !== 32'd0) begin
          $display("  [FAIL] 持续打流出现误码 %0d", u_df_tester2.rx_error_cnt); df_err_cnt = df_err_cnt + 1;
        end else $display("  [PASS] 持续打流 0 误码 (网口2 已收 %0d 包)", df_p2_rx_frame);
      end

      $display("================================================================");
      $display(" [PHASE4] 实验结束报告");
      $display("   网口1 打流包数           = %0d", df_offered_cnt);
      $display("   网口1 线上以太帧数       = %0d", df_p1_tx_frame);
      $display("   丢弃(ARP 未解析期, 估算) = %0d", df_offered_cnt - df_p1_tx_frame);
      $display("   网口2 收到业务包数       = %0d", df_p2_rx_frame);
      $display("   网口2 校验误码           = %0d", u_df_tester2.rx_error_cnt);
      $display("   ARP 请求=%b  应答=%b  数据直达=%b", df_p1_arp_req_seen, df_p2_arp_rep_seen, df_p1_data_ok);
      $display("   网口1 内部: rx_err=%b no_resp=%b | 网口2 内部: rx_err=%b no_resp=%b",
               df_p1_stat_rx_error, df_p1_stat_no_resp, df_p2_stat_rx_error, df_p2_stat_no_resp);
      $display("----------------------------------------------------------------");
      if (df_err_cnt == 0) $display(" [PHASE4 dual_flow] *** PASS ***");
      else                 $display(" [PHASE4 dual_flow] *** %0d CHECK(S) FAILED ***", df_err_cnt);
      $display("----------------------------------------------------------------");
    end
  endtask

  // ============================================================================
  // 主序列 : 顺序执行 4 个 phase, 最后统一汇总
  // ============================================================================
  initial begin
    g_err = 0;
    $display("================================================================");
    $display(" tb_ipv4_top : 同一链路(ipv4_top) 4 个场景链式验证");
    $display("================================================================");

    phase_loopback();       g_err = g_err + loop_err_total;
    phase_after_traffic();  g_err = g_err + aft_err;
    phase_chain();          g_err = g_err + ch_err_total;
    phase_dual_flow();      g_err = g_err + df_err_cnt;

    $display("================================================================");
    $display(" MERGED TB SUMMARY");
    $display("----------------------------------------------------------------");
    $display("  %-24s err=%0d", "phase1 loopback",       loop_err_total);
    $display("  %-24s err=%0d", "phase2 after_traffic",  aft_err);
    $display("  %-24s err=%0d", "phase3 chain",          ch_err_total);
    $display("  %-24s err=%0d", "phase4 dual_flow",      df_err_cnt);
    $display("----------------------------------------------------------------");
    if (g_err == 0) $display(" *** ALL TESTS PASSED ***");
    else            $display(" *** %0d CHECK(S) FAILED ***", g_err);
    $display("================================================================");
    $finish;
  end

  // 全局超时兜底
  initial begin
    #500_000_000;
    $display("*** GLOBAL TIMEOUT ***");
    $finish;
  end

endmodule

// ============================================================================
// 通用 1 拍寄存 AXIS 切片 (全吞吐: 空 或 正在排空 时可收)
// 全文件仅保留这一份 helper 定义
// ============================================================================
module axis_reg_slice #(
  parameter W = 512
) (
  input  wire                clk    ,
  input  wire                rst    ,
  input  wire [W-1:0]        sdata  ,
  input  wire [W/8-1:0]      skeep  ,
  input  wire                slast  ,
  input  wire                svalid ,
  output wire                sready ,
  output wire [W-1:0]        mdata  ,
  output wire [W/8-1:0]      mkeep  ,
  output wire                mlast  ,
  output wire                mvalid ,
  input  wire                mready
);
  reg [W-1:0]   d_r;
  reg [W/8-1:0] k_r;
  reg           l_r;
  reg           v_r;

  wire sready_i = !v_r || mready;

  always @(posedge clk) begin
    if (rst) begin
      v_r <= 1'b0; l_r <= 1'b0; d_r <= {W{1'b0}}; k_r <= {(W/8){1'b0}};
    end else if (sready_i) begin
      v_r <= svalid; l_r <= slast; d_r <= sdata; k_r <= skeep;
    end
  end

  assign sready = sready_i;
  assign mdata  = d_r;
  assign mkeep  = k_r;
  assign mlast  = l_r;
  assign mvalid = v_r;

endmodule
