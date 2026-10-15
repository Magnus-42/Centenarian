`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_arp_eth_top.v
// Module Name : tb_arp_eth_top
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-09-17
// ----------------------------------------------------------------------------
// Description : arp_eth_top 自测平台
//   覆盖场景:
//     1. 上电 / cache 与 pending 清表完成
//     2. 收到 ARP 请求 -> 学习 + 应答(oper=2)
//     3. 查询命中 / 查询未命中(触发 pending 请求)
//     4. pending 去重(时间窗内不重复发请求)
//     5. 错误注入: 长度不合规帧 / 以太类型不是 0x0806
//     6. 本网段广播地址 / 跨网段走网关
//     7. 下游反压不丢帧、不重复
//     8. ack FIFO 溢出
//     9. pending 清零完成 pending_clear_finish
//   NOTE: 激励一律用非阻塞赋值, 避免与时钟沿的读写竞争(阻塞赋值会让 DUT 在
//         同一时间步里读到被改写后的 slast/svalid)
// ============================================================================

module tb_arp_eth_top;

  // --------------------------------------------------------------------------
  // 参数: 用小容量表加速仿真(清表需要 2^ADDR 个周期)
  // --------------------------------------------------------------------------
  localparam AXIS_WIDTH        = 512;
  localparam CACHE_ITEM_WIDTH  = 81;
  localparam CACHE_DEEP        = 8;
  localparam PENDING_ITEM_WIDTH= 90;
  localparam PENDING_DEEP      = 8;
  localparam PENDING_TIME_WIDTH= 57;
  localparam HASH_WAY_CNT      = 4;

  localparam CLK_PERIOD = 10;            // 100MHz

  // 网络配置: 10.0.0.0/24, 本端 10.0.0.2, 网关 10.0.0.1
  localparam [31:0] L_IP    = 32'h0A00_0002;
  localparam [31:0] GATEWAY = 32'h0A00_0001;
  localparam [31:0] MASK    = 32'hFFFF_FF00;
  localparam [47:0] L_MAC   = 48'h0011_2233_4455;

  localparam [47:0] HOST_MAC = 48'hAABB_CCDD_0001;
  localparam [31:0] HOST_IP  = 32'h0A00_0005;

  localparam [63:0] KEEP_OK  = 64'h0FFF_FFFF_FFFF_FFFF;   // 60 字节(ARP 最小帧)
  localparam [63:0] KEEP_BAD = 64'h0000_0000_FFFF_FFFF;   // 32 字节(非法)

  reg                       clk             ;
  reg                       rst             ;

  reg  [31:0]               query_ip        ;
  reg                       query_valid_pulse;
  wire [47:0]               arp_mac         ;
  wire                      arp_miss        ;
  wire                      arp_valid       ;

  reg  [AXIS_WIDTH-1:0]     arp_axis_sdata  ;
  reg  [AXIS_WIDTH/8-1:0]   arp_axis_skeep  ;
  reg                       arp_axis_svalid ;
  reg                       arp_axis_slast  ;
  wire                      arp_axis_sready ;

  wire [AXIS_WIDTH-1:0]     arp_axis_mdata  ;
  wire [AXIS_WIDTH/8-1:0]   arp_axis_mkeep  ;
  wire                      arp_axis_mvalid ;
  wire                      arp_axis_mlast  ;
  reg                       arp_axis_mready ;

  reg  [31:0]               cfg_local_ip    ;
  reg  [47:0]               cfg_local_mac   ;
  reg  [31:0]               cfg_gateway_ip  ;
  reg  [31:0]               cfg_subnet_mask ;
  reg  [PENDING_TIME_WIDTH-1:0] cfg_pending_time;
  reg                       cfg_clear_cache ;
  reg                       cfg_clear_pending;

  wire                      stat_rx_error                    ;
  wire                      stat_ack_fifo_overflow_error     ;
  wire                      stat_pending_fifo_overflow_error ;
  wire                      stat_lookup_no_resp_error        ;
  wire                      pending_clear_finish             ;

  // --------------------------------------------------------------------------
  // DUT
  // --------------------------------------------------------------------------
  arp_eth_top#(
    .AXIS_WIDTH        (AXIS_WIDTH        ),
    .CACHE_ITEM_WIDTH  (CACHE_ITEM_WIDTH  ),
    .CACHE_DEEP        (CACHE_DEEP        ),
    .PENDING_ITEM_WIDTH(PENDING_ITEM_WIDTH),
    .PENDING_DEEP      (PENDING_DEEP      ),
    .PENDING_TIME_WIDTH(PENDING_TIME_WIDTH),
    .HASH_WAY_CNT      (HASH_WAY_CNT      )
  ) u_dut(
    .clk               (clk               ),
    .rst               (rst               ),
    .query_ip          (query_ip          ),
    .query_valid_pulse (query_valid_pulse ),
    .arp_mac           (arp_mac           ),
    .arp_miss          (arp_miss          ),
    .arp_valid         (arp_valid         ),
    .arp_axis_sdata    (arp_axis_sdata    ),
    .arp_axis_skeep    (arp_axis_skeep    ),
    .arp_axis_svalid   (arp_axis_svalid   ),
    .arp_axis_slast    (arp_axis_slast    ),
    .arp_axis_sready   (arp_axis_sready   ),
    .arp_axis_mdata    (arp_axis_mdata    ),
    .arp_axis_mkeep    (arp_axis_mkeep    ),
    .arp_axis_mvalid   (arp_axis_mvalid   ),
    .arp_axis_mlast    (arp_axis_mlast    ),
    .arp_axis_mready   (arp_axis_mready   ),
    .cfg_local_ip      (cfg_local_ip      ),
    .cfg_local_mac     (cfg_local_mac     ),
    .cfg_gateway_ip    (cfg_gateway_ip    ),
    .cfg_subnet_mask   (cfg_subnet_mask   ),
    .cfg_pending_time  (cfg_pending_time  ),
    .cfg_clear_cache   (cfg_clear_cache   ),
    .cfg_clear_pending (cfg_clear_pending ),
    .stat_rx_error                    (stat_rx_error                    ),
    .stat_ack_fifo_overflow_error     (stat_ack_fifo_overflow_error     ),
    .stat_pending_fifo_overflow_error (stat_pending_fifo_overflow_error ),
    .stat_lookup_no_resp_error        (stat_lookup_no_resp_error        ),
    .pending_clear_finish             (pending_clear_finish             )
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

  // --------------------------------------------------------------------------
  // 发送帧监视
  // --------------------------------------------------------------------------
  integer cnt_tx_frame ;
  integer cnt_tx_req   ;
  integer cnt_tx_rep   ;
  reg  [31:0] last_req_tpa      ;
  reg  [47:0] last_req_dest_mac ;
  reg  [31:0] last_rep_tpa      ;

  initial begin
    cnt_tx_frame = 0; cnt_tx_req = 0; cnt_tx_rep = 0;
    last_req_tpa = 0; last_req_dest_mac = 0; last_rep_tpa = 0;
  end

  always @(posedge clk) begin
    if (arp_axis_mvalid && arp_axis_mready) begin
      cnt_tx_frame = cnt_tx_frame + 1;
      if (arp_axis_mdata[175:160] == 16'd1) begin
        cnt_tx_req       = cnt_tx_req + 1;
        last_req_tpa     = arp_axis_mdata[335:304];
        last_req_dest_mac= arp_axis_mdata[47:0];
        $display("[%0t] TX REQ dest_mac=%012h tpa=%08h", $time, arp_axis_mdata[47:0], arp_axis_mdata[335:304]);
      end
      else if (arp_axis_mdata[175:160] == 16'd2) begin
        cnt_tx_rep  = cnt_tx_rep + 1;
        last_rep_tpa= arp_axis_mdata[335:304];
        $display("[%0t] TX REP dest_mac=%012h tpa=%08h", $time, arp_axis_mdata[47:0], arp_axis_mdata[335:304]);
      end
    end
  end

  // 查询响应捕获
  reg        resp_seen;
  reg [47:0] resp_mac ;
  reg        resp_miss;
  always @(posedge clk) begin
    if (arp_valid) begin
      resp_seen <= 1'b1;
      resp_mac  <= arp_mac;
      resp_miss <= arp_miss;
    end
  end

  // --------------------------------------------------------------------------
  // 调试探针
  // --------------------------------------------------------------------------
  always @(posedge clk) begin
    if (u_dut.arp_rx_frame_valid && u_dut.arp_rx_frame_ready) begin
      $display("[%0t] RXFRM type=%04h oper=%04h spa=%08h sha=%012h valid_arp=%b req=%b",
               $time, u_dut.eth_rx_type, u_dut.arp_rx_oper, u_dut.arp_rx_spa,
               u_dut.arp_rx_sha, u_dut.is_valid_arp, u_dut.is_arp_req);
    end
  end
  always @(posedge clk) if (u_dut.arp_rx_error_pulse) $display("[%0t] RX-ERR(rejected)", $time);
  always @(posedge clk) begin
    if (u_dut.eth_ack_frame_valid)
      $display("[%0t] PUSH-ACK spa=%08h full=%b", $time, u_dut.arp_rx_spa, u_dut.arp_ack_fifo_full);
    if (u_dut.eth_pending_frame_valid)
      $display("[%0t] PUSH-PEND ip=%08h full=%b", $time, u_dut.permit_ip, u_dut.arp_pending_fifo_full);
    if (u_dut.arp_ack_fifo_rd_en)     $display("[%0t] POP-ACK", $time);
    if (u_dut.arp_pending_fifo_rd_en) $display("[%0t] POP-PEND", $time);
  end

  always @(posedge clk) begin
    if (u_dut.arp_rr_take) $display("[%0t] TAKE idx=%b", $time, u_dut.arp_rr_out_index);
  end

  reg dbg_en;
  initial dbg_en = 1'b0;
  always @(posedge clk) begin
    if (dbg_en)
      $display("[%0t] ST datav=%b frdy=%b mvalid=%b mready=%b take=%b ep=%b ea=%b txhs=%b mhs=%b",
               $time, u_dut.tx_frame_data_valid, u_dut.arp_tx_frame_ready,
               arp_axis_mvalid, arp_axis_mready, u_dut.arp_rr_take,
               u_dut.arp_pending_fifo_empty, u_dut.arp_ack_fifo_empty,
               u_dut.tx_frame_data_handshake && u_dut.tx_frame_data_valid,
               arp_axis_mvalid && arp_axis_mready);
  end

  always @(posedge clk) begin
    if (u_dut.pending_req_valid_pulse)
      $display("[%0t] PEND-REQ ip=%08h", $time, u_dut.pending_req_ip);
  end

  always @(posedge clk) begin
    if (u_dut.query_valid_pulse_s1)
      $display("[%0t] Q s1: ip=%08h out_subnet=%b bord=%b", $time, u_dut.query_ip_s1, u_dut.is_out_subnet, u_dut.is_bordcase_addr);
  end

  // --------------------------------------------------------------------------
  // 任务(全部使用非阻塞赋值)
  // --------------------------------------------------------------------------
  task automatic send_arp(
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
      arp_axis_sdata  <= {176'd0, tpa, tha, spa, sha, oper, 8'd4, 8'd6, 16'h0800, 16'h1,
                          eth_type, src_mac, 48'hFFFF_FFFF_FFFF};
      arp_axis_skeep  <= keep;
      arp_axis_slast  <= 1'b1;
      arp_axis_svalid <= 1'b1;
      guard = 0;
      while (guard < 500) begin
        @(posedge clk);
        if (arp_axis_sready) guard = 500;      // 本沿完成握手
        else                 guard = guard + 1;
      end
      arp_axis_svalid <= 1'b0;
      arp_axis_slast  <= 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic do_query(input [31:0] ip);
    begin
      query_ip          <= ip;
      query_valid_pulse <= 1'b1;
      @(posedge clk);
      query_valid_pulse <= 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic cyc(input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
  endtask

  // 异步激励必须在时钟沿之外改, 否则 DUT(active 区采样) 与探针(NBA 区) 会看到不同值
  task automatic set_mready(input v);
    begin
      @(negedge clk);
      arp_axis_mready <= v;
    end
  endtask

  // 等待查询响应
  task automatic wait_resp(input integer max_cyc, output ok);
    integer i;
    begin
      resp_seen = 1'b0;
      i  = 0;
      ok = 0;
      while (!resp_seen && i < max_cyc) begin
        @(posedge clk);
        i = i + 1;
      end
      if (resp_seen) ok = 1;
    end
  endtask

  // 等待总线静默(用于隔离各测试之间的残余请求/应答)
  task automatic drain(input integer quiet);
    integer last;
    integer still;
    begin
      still = 0;
      last  = cnt_tx_frame;
      while (still < quiet) begin
        @(posedge clk);
        if (cnt_tx_frame == last) still = still + 1;
        else begin still = 0; last = cnt_tx_frame; end
      end
    end
  endtask

  // 等待出现一个新的请求帧
  task automatic wait_req(input integer max_cyc, output ok);
    integer base;
    integer i;
    begin
      base = cnt_tx_req;
      i    = 0;
      ok   = 0;
      while (cnt_tx_req == base && i < max_cyc) begin
        @(posedge clk);
        i = i + 1;
      end
      if (cnt_tx_req != base) ok = 1;
    end
  endtask

  // --------------------------------------------------------------------------
  // 主流程
  // --------------------------------------------------------------------------
  integer err;
  integer ok ;
  integer i  ;
  integer req_before;

  initial begin
    $display("================================================================");
    $display(" tb_arp_eth_top start");
    $display("================================================================");
    err = 0;

    query_ip           = 32'd0;
    query_valid_pulse  = 1'b0;
    arp_axis_sdata     = {AXIS_WIDTH{1'b0}};
    arp_axis_skeep     = 64'd0;
    arp_axis_svalid    = 1'b0;
    arp_axis_slast     = 1'b0;
    arp_axis_mready    = 1'b1;
    cfg_local_ip       = L_IP;
    cfg_local_mac      = L_MAC;
    cfg_gateway_ip     = GATEWAY;
    cfg_subnet_mask    = MASK;
    cfg_pending_time   = 200;
    cfg_clear_cache    = 1'b0;
    cfg_clear_pending  = 1'b0;
    resp_seen          = 1'b0;

    // ---- 复位 ----
    rst = 1'b1;
    cyc(10);
    rst = 1'b0;

    // ---- 1. 等待清表完成 ----
    cyc(2);
    wait (u_dut.cache_clear_finish === 1'b1);
    wait (pending_clear_finish === 1'b1);
    $display("[%0t] [PASS] cache & pending clear finish", $time);

    // ---- 2. 收到 ARP 请求 -> 学习 + 应答 ----
    $display("--- TEST2: rx arp request -> learn + reply ---");
    send_arp(16'h0806, HOST_MAC, HOST_IP, HOST_MAC, 16'd1, 48'd0, L_IP, KEEP_OK);
    i = 0;
    while (cnt_tx_rep == 0 && i < 100) begin @(posedge clk); i = i + 1; end
    if (cnt_tx_rep != 1) begin
      $display("  [FAIL] expect 1 reply, got %0d", cnt_tx_rep); err = err + 1;
    end
    else if (last_rep_tpa !== HOST_IP) begin
      $display("  [FAIL] reply tpa=%08h expect %08h", last_rep_tpa, HOST_IP); err = err + 1;
    end
    else $display("  [PASS] reply to %08h", last_rep_tpa);
    drain(20);

    // ---- 3. 查询命中 ----
    $display("--- TEST3: query hit ---");
    do_query(HOST_IP);
    wait_resp(100, ok);
    if (!ok) begin
      $display("  [FAIL] no arp_valid"); err = err + 1;
    end
    else if (resp_miss) begin
      $display("  [FAIL] expect hit, got miss"); err = err + 1;
    end
    else if (resp_mac !== HOST_MAC) begin
      $display("  [FAIL] mac=%012h expect %012h", resp_mac, HOST_MAC); err = err + 1;
    end
    else $display("  [PASS] hit mac=%012h", resp_mac);
    drain(20);

    // ---- 4. 查询未命中 -> 发请求 + 去重 ----
    $display("--- TEST4: query miss -> pending request + dedupe ---");
    drain(20);
    do_query(32'h0A00_0009);
    wait_resp(100, ok);
    if (!ok || !resp_miss) begin
      $display("  [FAIL] expect miss resp (ok=%0d miss=%0b)", ok, resp_miss); err = err + 1;
    end
    wait_req(150, ok);
    if (!ok) begin
      $display("  [FAIL] no request generated"); err = err + 1;
    end
    else if (last_req_tpa !== 32'h0A00_0009) begin
      $display("  [FAIL] req tpa=%08h expect 0a000009", last_req_tpa); err = err + 1;
    end
    else if (last_req_dest_mac !== 48'hFFFF_FFFF_FFFF) begin
      $display("  [FAIL] req dest_mac=%012h should be broadcast", last_req_dest_mac); err = err + 1;
    end
    else $display("  [PASS] request tpa=%08h dest=broadcast", last_req_tpa);

    // 时间窗内重复查询 -> 不应再发
    drain(20);
    req_before = cnt_tx_req;
    do_query(32'h0A00_0009);
    wait_resp(100, ok);
    cyc(60);
    if (cnt_tx_req !== req_before) begin
      $display("  [FAIL] dedupe failed, extra req=%0d", cnt_tx_req - req_before); err = err + 1;
    end
    else $display("  [PASS] dedupe ok (no duplicate request within window)");
    drain(20);

    // ---- 5. 错误注入 ----
    $display("--- TEST5: error injection ---");
    send_arp(16'h0806, 48'hAAAA_0000_0002, 32'h0A00_0077, 48'hAAAA_0000_0002, 16'd1, 48'd0, L_IP, KEEP_BAD);
    cyc(5);
    if (stat_rx_error !== 1'b1) begin
      $display("  [FAIL] stat_rx_error not set by short frame"); err = err + 1;
    end
    else $display("  [PASS] stat_rx_error set by short frame");
    cyc(10);

    // 非 ARP 以太类型: 不应答 / 不学习
    drain(20);
    req_before = cnt_tx_rep;
    send_arp(16'h0800, 48'hBBBB_0000_0003, 32'h0A00_0078, 48'hBBBB_0000_0003, 16'd1, 48'd0, L_IP, KEEP_OK);
    cyc(30);
    if (cnt_tx_rep !== req_before) begin
      $display("  [FAIL] non-arp frame got a reply"); err = err + 1;
    end
    else $display("  [PASS] non-arp frame ignored (no reply)");
    do_query(32'h0A00_0078);
    wait_resp(100, ok);
    if (ok && !resp_miss) begin
      $display("  [FAIL] non-arp frame was learned"); err = err + 1;
    end
    else $display("  [PASS] non-arp frame not learned");
    drain(20);

    // ---- 6. 本网段广播 ----
    $display("--- TEST6: broadcast addr ---");
    do_query(32'h0A00_00FF);
    wait_resp(100, ok);
    if (!ok || resp_miss || resp_mac !== 48'hFFFF_FFFF_FFFF) begin
      $display("  [FAIL] broadcast: ok=%0d miss=%0b mac=%012h", ok, resp_miss, resp_mac); err = err + 1;
    end
    else $display("  [PASS] broadcast -> mac=ffffffffffff, miss=0");
    drain(20);

    // ---- 7. 跨网段 -> 查网关 ----
    $display("--- TEST7: cross subnet -> gateway ---");
    do_query(32'h0808_0808);
    wait_resp(100, ok);
    wait_req(150, ok);
    if (!ok) begin
      $display("  [FAIL] no request for cross-subnet query"); err = err + 1;
    end
    else if (last_req_tpa !== GATEWAY) begin
      $display("  [FAIL] expect tpa=gateway %08h, got %08h", GATEWAY, last_req_tpa); err = err + 1;
    end
    else $display("  [PASS] cross-subnet -> request gateway %08h", last_req_tpa);
    drain(20);

    // ---- 8. 下游反压: 帧必须停在出口保持, 不能被覆盖/丢失/重复 ----
    $display("--- TEST8: backpressure (frame must be held, not dropped) ---");
    set_mready(1'b0);
    cyc(5);
    req_before = cnt_tx_req;
    dbg_en = 1'b1;
    do_query(32'h0A00_0021);
    wait_resp(100, ok);
    // 帧应出现在 m axis 上并一直保持(mready=0 时无法完成握手)
    i = 0;
    while (!arp_axis_mvalid && i < 200) begin @(posedge clk); i = i + 1; end
    if (!arp_axis_mvalid) begin
      $display("  [FAIL] no frame presented on m axis"); err = err + 1;
    end
    else if (arp_axis_mdata[335:304] !== 32'h0A00_0021) begin
      $display("  [FAIL] presented tpa=%08h expect 0a000021", arp_axis_mdata[335:304]); err = err + 1;
    end
    else $display("  [PASS] frame presented on m axis (tpa=%08h)", arp_axis_mdata[335:304]);
    // 保持期间不应被后续帧覆盖
    cyc(40);
    if (!arp_axis_mvalid || arp_axis_mdata[335:304] !== 32'h0A00_0021) begin
      $display("  [FAIL] frame changed/lost while backpressure (mvalid=%b tpa=%08h)",
               arp_axis_mvalid, arp_axis_mdata[335:304]); err = err + 1;
    end
    else $display("  [PASS] frame held stable while mready=0");
    // 释放后应只完成一次, 不重复
    set_mready(1'b1);
    cyc(8);
    dbg_en = 1'b0;
    if (cnt_tx_req !== req_before + 1) begin
      $display("  [FAIL] expect exactly 1 request completed, got %0d", cnt_tx_req - req_before); err = err + 1;
    end
    else $display("  [PASS] exactly one request completed after release");
    drain(20);
    if (cnt_tx_req !== req_before + 1) begin
      $display("  [FAIL] duplicate after release, got %0d", cnt_tx_req - req_before); err = err + 1;
    end
    else $display("  [PASS] no duplicate after release");

    // ---- 9. ack FIFO 溢出 ----
    $display("--- TEST9: ack fifo overflow ---");
    if (stat_ack_fifo_overflow_error !== 1'b0) begin
      $display("  [FAIL] overflow flag already set"); err = err + 1;
    end
    set_mready(1'b0);                             // 堵住出口
    for (i = 0; i < 90; i = i + 1) begin
      send_arp(16'h0806, 48'hCCCC_0000_0000 + i, 32'h0A01_0000 + i, 48'hCCCC_0000_0000 + i,
               16'd1, 48'd0, L_IP, KEEP_OK);
    end
    cyc(10);
    if (stat_ack_fifo_overflow_error !== 1'b1) begin
      $display("  [FAIL] stat_ack_fifo_overflow_error not set"); err = err + 1;
    end
    else $display("  [PASS] stat_ack_fifo_overflow_error set (depth=64, pushed 90)");
    set_mready(1'b1);
    drain(30);
    $display("  [INFO] frames drained after release: %0d", cnt_tx_frame);

    // ---- 10. pending 清零完成 ----
    $display("--- TEST10: pending clear finish ---");
    cfg_clear_pending = 1'b1;
    cyc(3);
    if (pending_clear_finish !== 1'b0) begin
      $display("  [FAIL] pending_clear_finish should drop during clear"); err = err + 1;
    end
    else $display("  [PASS] pending_clear_finish=0 during clear");
    cfg_clear_pending = 1'b0;
    i = 0;
    while (pending_clear_finish !== 1'b1 && i < 200) begin @(posedge clk); i = i + 1; end
    if (pending_clear_finish !== 1'b1) begin
      $display("  [FAIL] pending_clear_finish did not rise"); err = err + 1;
    end
    else $display("  [PASS] pending_clear_finish rose after %0d cycles", i);
    cyc(10);

    // ---- 11. 正常流量下不应有误报 ----
    if (stat_lookup_no_resp_error !== 1'b0) begin
      $display("--- [FAIL] stat_lookup_no_resp_error unexpectedly set"); err = err + 1;
    end
    else $display("--- [PASS] stat_lookup_no_resp_error clean in normal traffic");

    cyc(50);
    $display("================================================================");
    $display(" tx frames: total=%0d req=%0d rep=%0d", cnt_tx_frame, cnt_tx_req, cnt_tx_rep);
    if (err == 0) $display(" *** ALL TESTS PASSED ***");
    else          $display(" *** %0d CHECK(S) FAILED ***", err);
    $display("================================================================");
    $finish;
  end

  initial begin
    #5_000_000;
    $display("[%0t] FATAL: global timeout", $time);
    $finish;
  end

endmodule
`resetall
