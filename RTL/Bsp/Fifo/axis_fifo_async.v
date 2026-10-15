`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : axis_fifo_async.v
// Module Name : axis_fifo_async
// Author      : LiXintao
// Date        : 2026-09-14
// Version     : v3.0
// ----------------------------------------------------------------------------
// Description : 异步 AXI-Stream FIFO，支持分布式或块 RAM 存储及整包读取
// Note        :
//   1. FIFO_DEPTH 必须为 2 的幂，跨时钟域指针采用格雷码同步；
//   2. BRAM的格式为SDP的形式；
//   3. 支持自动计算RAM类型
// ============================================================================
module axis_fifo_async #(
  parameter  FIFO_DEPTH= 512,  // FIFO 深度, 需为 2 的幂
  parameter  AXIS_WIDTH= 512,  // 数据位宽 (字节整数倍)
  parameter  AXIS_USER_WIDTH= 1 ,  // 用户自定义信息位宽
  parameter  AXIS_ID_WIDTH= 1 ,  // 流标识位宽
  parameter  AXIS_DEST_WIDTH= 1 ,  // 路由信息位宽
  parameter  PACKET_FIFO= 1 ,  // 包模式开关: 1 开启, 0 关闭
  parameter  FIFO_MEMORY_TYPE= "auto",  // 存储类型: distributed / block / auto
  parameter  PROG_EMPTY_THRESH= FIFO_DEPTH/4,          // 可编程空阈值 (剩余 <= 该值拉高 prog_empty)
  parameter  PROG_FULL_THRESH= FIFO_DEPTH/2,          // 可编程满阈值 (剩余 >= 该值拉高 prog_full)
  parameter  REMAIN_COUNT_WIDTH= $clog2(FIFO_DEPTH) + 1,  // 剩余深度计数输出位宽
  parameter  BRAM_DO_REG= 2 , // BRAM的输出流水线级数，推荐为2，可以提高时序
  parameter  DEADLOCK_RISK= 0 // 是否能被长包锁死，如果包很长，置0的情况下，会在还差4个包的时候，使能读取，防止死锁；否则严格按照包模式执行，可能锁死
) (
  input  wire                                          srst            ,
  input  wire                                          sclk            ,
  input  wire                                          mclk            ,

    // ============================================================================
    // AXI-Stream 从机接口 (上游写)
    // ============================================================================
  input  wire          [        AXIS_WIDTH-1:0]        axis_sdata      ,// 数据
  input  wire          [      AXIS_WIDTH/8-1:0]        axis_skeep      ,// 字节有效标志
  input  wire                                          axis_svalid     ,// 数据有效
  input  wire                                          axis_slast      ,// 包结束标志
  output wire                                          axis_sready     ,// 反压: 还能写入
  input  wire          [   AXIS_USER_WIDTH-1:0]        axis_susr       ,// 用户自定义信息
  input  wire          [      AXIS_WIDTH/8-1:0]        axis_sstrb      ,// 字节选通
  input  wire          [     AXIS_ID_WIDTH-1:0]        axis_sid        ,// 流标识
  input  wire          [   AXIS_DEST_WIDTH-1:0]        axis_sdest      ,// 路由信息

    // ============================================================================
    // AXI-Stream 主机接口 (下游读)
    // ============================================================================
  output wire          [        AXIS_WIDTH-1:0]        axis_mdata      ,// 数据
  output wire          [      AXIS_WIDTH/8-1:0]        axis_mkeep      ,// 字节有效标志
  output wire                                          axis_mvalid     ,// 有数据可读
  output wire                                          axis_mlast      ,// 包结束标志
  input  wire                                          axis_mready     ,// 下游能接收
  output wire          [   AXIS_USER_WIDTH-1:0]        axis_musr       ,// 用户自定义信息
  output wire          [      AXIS_WIDTH/8-1:0]        axis_mstrb      ,// 字节选通
  output wire          [     AXIS_ID_WIDTH-1:0]        axis_mid        ,// 流标识
  output wire          [   AXIS_DEST_WIDTH-1:0]        axis_mdest      ,// 路由信息

    // ============================================================================
    // 状态端口
    // ============================================================================
  output wire                                          prog_almost_empty,// 剩余深度 <= PROG_EMPTY_THRESH
  output wire                                          prog_almost_full,// 剩余深度 >= PROG_FULL_THRESH

  output wire                                          almost_empty    ,// FIFO 空
  output wire                                          almost_full     ,// FIFO 满

  output wire          [REMAIN_COUNT_WIDTH-1:0]        wr_almost_remain_count,
  output wire          [REMAIN_COUNT_WIDTH-1:0]        rd_almost_remain_count 
);

  // --- 参数与复位 ---
  localparam FIFO_DEPTH_WIDTH= $clog2(FIFO_DEPTH);

  // 基于容量/位宽/深度 设计ram类型
  // ≤ 64	任意	分布式 RAM
  // ≤1K 且	≤9Kb	分布式 RAM
  // > 1K	任意	BRAM
  // 任意	> 18Kb	BRAM
  // 任意（浅）	位宽 ≥ 256	BRAM	超宽位宽分布式要成片 LUT
  function is_distributed;
  input                                                integer width   ;
  input                                                integer depth   ;
    begin
      is_distributed = (depth <= 64 || (depth <= 1024 && width*depth <= 9216)) && width < 256;
    end
  endfunction

  localparam DATA_AUTO_TYPE= is_distributed(AXIS_WIDTH,      FIFO_DEPTH) ? "distributed" : "block";
  localparam KEEP_AUTO_TYPE= is_distributed(AXIS_WIDTH/8,    FIFO_DEPTH) ? "distributed" : "block";
  localparam USER_AUTO_TYPE= is_distributed(AXIS_USER_WIDTH, FIFO_DEPTH) ? "distributed" : "block";
  localparam ID_AUTO_TYPE= is_distributed(AXIS_ID_WIDTH,   FIFO_DEPTH) ? "distributed" : "block";
  localparam DEST_AUTO_TYPE= is_distributed(AXIS_DEST_WIDTH, FIFO_DEPTH) ? "distributed" : "block";
  localparam STRB_AUTO_TYPE= is_distributed(AXIS_WIDTH/8,    FIFO_DEPTH) ? "distributed" : "block";
  localparam LAST_AUTO_TYPE= is_distributed(1,    FIFO_DEPTH) ? "distributed" : "block";

  localparam DATA_MEMORY_TYPE= FIFO_MEMORY_TYPE == "auto" ? DATA_AUTO_TYPE : FIFO_MEMORY_TYPE;
  localparam KEEP_MEMORY_TYPE= FIFO_MEMORY_TYPE == "auto" ? KEEP_AUTO_TYPE : FIFO_MEMORY_TYPE;
  localparam USER_MEMORY_TYPE= FIFO_MEMORY_TYPE == "auto" ? USER_AUTO_TYPE : FIFO_MEMORY_TYPE;
  localparam ID_MEMORY_TYPE= FIFO_MEMORY_TYPE   == "auto" ? ID_AUTO_TYPE : FIFO_MEMORY_TYPE;
  localparam DEST_MEMORY_TYPE= FIFO_MEMORY_TYPE == "auto" ? DEST_AUTO_TYPE : FIFO_MEMORY_TYPE;
  localparam STRB_MEMORY_TYPE= FIFO_MEMORY_TYPE == "auto" ? STRB_AUTO_TYPE : FIFO_MEMORY_TYPE;
  localparam LAST_MEMORY_TYPE= FIFO_MEMORY_TYPE == "auto" ? LAST_AUTO_TYPE : FIFO_MEMORY_TYPE;

  localparam ALL_DISTRIBUTED= FIFO_MEMORY_TYPE == "auto" &&
                              DATA_MEMORY_TYPE == "distributed" &&
                              KEEP_MEMORY_TYPE == "distributed" &&
                              LAST_MEMORY_TYPE == "distributed" &&
                              USER_MEMORY_TYPE == "distributed" &&
                              STRB_MEMORY_TYPE == "distributed" &&
                              ID_MEMORY_TYPE  == "distributed" &&
                              DEST_MEMORY_TYPE == "distributed";

(* ASYNC_REG = "true" *)   reg                                                  mrst_d0          , mrst_d1;

  // --- FIFO 存储体 ---
(* ram_style = DATA_MEMORY_TYPE *)   reg                  [        AXIS_WIDTH-1:0]        ram_data[0:FIFO_DEPTH-1];
(* ram_style = KEEP_MEMORY_TYPE *)   reg                  [      AXIS_WIDTH/8-1:0]        ram_keep[0:FIFO_DEPTH-1];
(* ram_style = USER_MEMORY_TYPE *)   reg                  [   AXIS_USER_WIDTH-1:0]        ram_usr[0:FIFO_DEPTH-1];
(* ram_style = ID_MEMORY_TYPE *)   reg                  [     AXIS_ID_WIDTH-1:0]        ram_id[0:FIFO_DEPTH-1];
(* ram_style = DEST_MEMORY_TYPE *)   reg                  [   AXIS_DEST_WIDTH-1:0]        ram_dest[0:FIFO_DEPTH-1];
(* ram_style = STRB_MEMORY_TYPE *)   reg                  [      AXIS_WIDTH/8-1:0]        ram_strb[0:FIFO_DEPTH-1];
(* ram_style = LAST_MEMORY_TYPE *)   reg                                                  ram_last[0:FIFO_DEPTH-1];

  // --- 读写指针及跨时钟域同步 ---
  reg                  [    FIFO_DEPTH_WIDTH:0]        wr_ptr_gray      ;
  reg                  [    FIFO_DEPTH_WIDTH:0]        wr_ptr_bin       ;
  reg                  [    FIFO_DEPTH_WIDTH:0]        wr_ptr_bin_sync  ;
  reg                  [    FIFO_DEPTH_WIDTH:0]        rd_ptr_gray      ;
  reg                  [    FIFO_DEPTH_WIDTH:0]        rd_ptr_bin       ;
  wire                 [    FIFO_DEPTH_WIDTH:0]        rd_ptr_bin_next  ;
  reg                  [    FIFO_DEPTH_WIDTH:0]        rd_ptr_bin_sync  ;
  wire                 [    FIFO_DEPTH_WIDTH:0]        wr_ptr_bin_next  ;

(* ASYNC_REG = "true" *)   reg                  [    FIFO_DEPTH_WIDTH:0]        wr_ptr_gray_sync_0;
(* ASYNC_REG = "true" *)   reg                  [    FIFO_DEPTH_WIDTH:0]        rd_ptr_gray_sync_0;
(* ASYNC_REG = "true" *)   reg                  [    FIFO_DEPTH_WIDTH:0]        wr_ptr_gray_sync_1;
(* ASYNC_REG = "true" *)   reg                  [    FIFO_DEPTH_WIDTH:0]        rd_ptr_gray_sync_1;

  // --- 状态与握手 ---
  wire                                                 internal_empty   ;
  wire                                                 s_handshake      ;
  wire                                                 m_handshake      ;
  wire                                                 deadlock_risk    ;

  // --- 包计数 ---
  reg                  [    FIFO_DEPTH_WIDTH:0]        wr_pkt_cnt_gray  ;
  reg                  [    FIFO_DEPTH_WIDTH:0]        wr_pkt_cnt_bin   ;
(* ASYNC_REG = "true" *)   reg                  [    FIFO_DEPTH_WIDTH:0]        wr_pkt_cnt_gray_sync_0;
(* ASYNC_REG = "true" *)   reg                  [    FIFO_DEPTH_WIDTH:0]        wr_pkt_cnt_gray_sync_1;
  reg                  [    FIFO_DEPTH_WIDTH:0]        rd_pkt_cnt_gray  ;
  reg                  [    FIFO_DEPTH_WIDTH:0]        rd_pkt_cnt_bin   ;
  wire                 [    FIFO_DEPTH_WIDTH:0]        rd_pkt_cnt_bin_next;
  reg                  [    FIFO_DEPTH_WIDTH:0]        wr_pkt_cnt_bin_sync;
  wire                 [    FIFO_DEPTH_WIDTH:0]        wr_pkt_cnt_bin_next;

  reg                  [    FIFO_DEPTH_WIDTH:0]        wr_almost_remain_count_reg;
  reg                  [    FIFO_DEPTH_WIDTH:0]        rd_almost_remain_count_reg;
  reg                                                  prog_almost_empty_reg;
  reg                                                  prog_almost_full_reg;

  // --- 格雷码转换索引 ---
  integer                                              i                ;

  // --- 状态组合信号 ---
  wire                 [    FIFO_DEPTH_WIDTH:0]        wr_remain_count  ;
  wire                 [    FIFO_DEPTH_WIDTH:0]        rd_remain_count  ;
  assign  wr_remain_count  = wr_ptr_bin - rd_ptr_bin_sync;// 因为同步比真实值大于等于
  assign  rd_remain_count  = wr_ptr_bin_sync - rd_ptr_bin;// 因为同步比真实值小于等于

  assign  internal_empty   = (wr_ptr_gray_sync_1 == rd_ptr_gray);// 等价： rd_remain_count == 'd0;，但是时序好
  
  assign  deadlock_risk    = (rd_remain_count >= (FIFO_DEPTH - 4));

  assign  almost_full    = (wr_ptr_gray[FIFO_DEPTH_WIDTH] != rd_ptr_gray_sync_1[FIFO_DEPTH_WIDTH]) &&
                        (wr_ptr_gray[FIFO_DEPTH_WIDTH-1] != rd_ptr_gray_sync_1[FIFO_DEPTH_WIDTH-1]) &&
                        (wr_ptr_gray[FIFO_DEPTH_WIDTH-2:0] == rd_ptr_gray_sync_1[FIFO_DEPTH_WIDTH-2:0]);// 等价：wr_remain_count == FIFO_DEPTH ;
  assign  wr_almost_remain_count= wr_almost_remain_count_reg;
  assign  rd_almost_remain_count= rd_almost_remain_count_reg;
  assign  prog_almost_empty= prog_almost_empty_reg;
  assign  prog_almost_full = prog_almost_full_reg;
  assign  axis_sready      = !almost_full     ;

  assign  s_handshake      = axis_svalid & axis_sready;
  assign  m_handshake      = axis_mvalid & axis_mready;

  always @(posedge sclk) begin
    if (srst) begin
      wr_almost_remain_count_reg <= 'd0;
      prog_almost_full_reg <= 'd0;
    end
    else begin
      wr_almost_remain_count_reg <= wr_remain_count;
      prog_almost_full_reg <= (wr_remain_count >= PROG_FULL_THRESH);
    end
  end

  always @(posedge mclk) begin
    if (mrst_d1) begin
      rd_almost_remain_count_reg <= 'd0;
      prog_almost_empty_reg <= 'd0;
    end
    else begin
      rd_almost_remain_count_reg <= rd_remain_count;
      prog_almost_empty_reg <= (rd_remain_count <= PROG_EMPTY_THRESH);
    end
  end

  // ============================================================================
  // 格雷码转二进制
  // ============================================================================
  always @(*) begin
    rd_ptr_bin_sync[FIFO_DEPTH_WIDTH] = rd_ptr_gray_sync_1[FIFO_DEPTH_WIDTH];
    wr_ptr_bin_sync[FIFO_DEPTH_WIDTH] = wr_ptr_gray_sync_1[FIFO_DEPTH_WIDTH];
    wr_pkt_cnt_bin_sync[FIFO_DEPTH_WIDTH] = wr_pkt_cnt_gray_sync_1[FIFO_DEPTH_WIDTH];
    for (i = FIFO_DEPTH_WIDTH - 1; i >= 0; i = i - 1) begin
      wr_ptr_bin_sync[i] = wr_ptr_bin_sync[i+1] ^ wr_ptr_gray_sync_1[i];
      rd_ptr_bin_sync[i] = rd_ptr_bin_sync[i+1] ^ rd_ptr_gray_sync_1[i];
      wr_pkt_cnt_bin_sync[i] = wr_pkt_cnt_bin_sync[i+1] ^ wr_pkt_cnt_gray_sync_1[i];
    end
  end

  // ============================================================================
  // 复位同步
  // ============================================================================
  always @(posedge mclk or posedge srst) begin
    if (srst) {mrst_d1, mrst_d0} <= 2'b11;
    else {mrst_d1, mrst_d0} <= {mrst_d0, 1'b0};
  end

  // ============================================================================
  // 写指针与写包计数
  // ============================================================================
  always @(posedge sclk) begin
    if (srst) begin
      wr_ptr_bin <= 'd0;
      wr_ptr_gray <= 'd0;
      rd_ptr_gray_sync_0 <= 'd0;
      rd_ptr_gray_sync_1 <= 'd0;
      wr_pkt_cnt_bin <= 'd0;
      wr_pkt_cnt_gray <= 'd0;
    end else begin
      {rd_ptr_gray_sync_1, rd_ptr_gray_sync_0} <= {rd_ptr_gray_sync_0, rd_ptr_gray};

      if (s_handshake) begin
        wr_ptr_bin  <= wr_ptr_bin_next;
        wr_ptr_gray <= (wr_ptr_bin_next >> 1) ^ wr_ptr_bin_next;
        if (axis_slast) begin
          wr_pkt_cnt_bin <= wr_pkt_cnt_bin_next;
          wr_pkt_cnt_gray <= (wr_pkt_cnt_bin_next >> 1) ^ wr_pkt_cnt_bin_next;// 二进制码转回格雷码，需要同步周期打拍
        end
      end
    end
  end
  assign  wr_ptr_bin_next  = wr_ptr_bin + 1'b1;
  assign  wr_pkt_cnt_bin_next= wr_pkt_cnt_bin + 1'b1;

  // ============================================================================
  // AXI-Stream 写入 RAM
  // ============================================================================
  always @(posedge sclk) begin
    if (s_handshake) begin
      ram_data[wr_ptr_bin[FIFO_DEPTH_WIDTH-1:0]] <= axis_sdata;
      ram_keep[wr_ptr_bin[FIFO_DEPTH_WIDTH-1:0]] <= axis_skeep;
      ram_usr[wr_ptr_bin[FIFO_DEPTH_WIDTH-1:0]] <= axis_susr;
      ram_id[wr_ptr_bin[FIFO_DEPTH_WIDTH-1:0]]   <= axis_sid;
      ram_dest[wr_ptr_bin[FIFO_DEPTH_WIDTH-1:0]] <= axis_sdest;
      ram_strb[wr_ptr_bin[FIFO_DEPTH_WIDTH-1:0]] <= axis_sstrb;
      ram_last[wr_ptr_bin[FIFO_DEPTH_WIDTH-1:0]] <= axis_slast;
    end
  end

  // ============================================================================
  // 写指针与包计数跨时钟域同步
  // ============================================================================
  always @(posedge mclk) begin
    if (mrst_d1) begin
      wr_ptr_gray_sync_0 <= 'd0;
      wr_ptr_gray_sync_1 <= 'd0;
      wr_pkt_cnt_gray_sync_0 <= 'd0;
      wr_pkt_cnt_gray_sync_1 <= 'd0;
    end else begin
      {wr_ptr_gray_sync_1, wr_ptr_gray_sync_0} <= {wr_ptr_gray_sync_0, wr_ptr_gray};
      {wr_pkt_cnt_gray_sync_1, wr_pkt_cnt_gray_sync_0} <= {wr_pkt_cnt_gray_sync_0, wr_pkt_cnt_gray};
    end
  end

  // ============================================================================
  // 读通路：分布式 RAM 或块 RAM
  // ============================================================================
  assign  rd_pkt_cnt_bin_next= rd_pkt_cnt_bin + 1'b1;
  assign  rd_ptr_bin_next  = rd_ptr_bin + 1'b1;
  generate
    if (FIFO_MEMORY_TYPE == "distributed" || ALL_DISTRIBUTED) begin : g_distributed

  reg                  [        AXIS_WIDTH-1:0]        axis_mdata_direct;
  reg                  [      AXIS_WIDTH/8-1:0]        axis_mkeep_direct;
  reg                  [   AXIS_USER_WIDTH-1:0]        axis_musr_direct ;
  reg                  [     AXIS_ID_WIDTH-1:0]        axis_mid_direct  ;
  reg                  [   AXIS_DEST_WIDTH-1:0]        axis_mdest_direct;
  reg                  [      AXIS_WIDTH/8-1:0]        axis_mstrb_direct;
  reg                                                  axis_mlast_direct;
  reg                                                  axis_mvalid_direct;

  reg                  [    FIFO_DEPTH_WIDTH:0]        rd_pkt_cnt_bin_plus1;
  reg                  [    FIFO_DEPTH_WIDTH:0]        wr_pkt_cnt_bin_sync_reg;
  wire                                                 allow_read       ;
  wire                                                 ram_read_en      ;
  wire                                                 is_holding_last  ;
  wire                 [    FIFO_DEPTH_WIDTH:0]        cmp_rd_pkt_cnt   ;

      // ========================================================================
      // 分布式 RAM 组合读出
      // ========================================================================
  assign  almost_empty     = internal_empty && !axis_mvalid_direct;
  assign  axis_mvalid      = axis_mvalid_direct;
  assign  is_holding_last  = axis_mvalid_direct && axis_mlast_direct;
  assign  cmp_rd_pkt_cnt   = is_holding_last ? rd_pkt_cnt_bin_plus1 : rd_pkt_cnt_bin;
  assign  allow_read       = PACKET_FIFO ? (DEADLOCK_RISK ? wr_pkt_cnt_bin_sync_reg != cmp_rd_pkt_cnt : ((wr_pkt_cnt_bin_sync_reg != cmp_rd_pkt_cnt) || deadlock_risk)) : !internal_empty;
  assign  ram_read_en      = allow_read && (!axis_mvalid_direct || axis_mready);

  
  assign  axis_mdata       = axis_mdata_direct;
  assign  axis_mkeep       = axis_mkeep_direct;
  assign  axis_musr        = axis_musr_direct ;
  assign  axis_mid         = axis_mid_direct  ;
  assign  axis_mdest       = axis_mdest_direct;
  assign  axis_mstrb       = axis_mstrb_direct;
  assign  axis_mlast       = axis_mlast_direct;

  // 使用延后感知包写入，来换取时序
  always @(posedge mclk) begin
    if (mrst_d1) begin
      wr_pkt_cnt_bin_sync_reg <= 'd0;
    end else begin
      wr_pkt_cnt_bin_sync_reg <= wr_pkt_cnt_bin_sync;
    end
  end

  always @(posedge mclk) begin
    if (ram_read_en) begin
      axis_mdata_direct <= ram_data[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
      axis_mkeep_direct <= ram_keep[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
      axis_musr_direct <= ram_usr[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
      axis_mid_direct   <= ram_id[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
      axis_mdest_direct <= ram_dest[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
      axis_mstrb_direct <= ram_strb[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
      axis_mlast_direct <= ram_last[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
    end
  end

  always @(posedge mclk) begin
    if (mrst_d1) begin
      rd_ptr_bin         <= 'd0;
      rd_ptr_gray        <= 'd0;
      rd_pkt_cnt_bin     <= 'd0;
      rd_pkt_cnt_bin_plus1 <= 'd1;
      rd_pkt_cnt_gray    <= 'd0;
      axis_mvalid_direct <= 1'b0;
    end else begin
      if (ram_read_en) begin
        rd_ptr_bin  <= rd_ptr_bin_next;
        rd_ptr_gray <= (rd_ptr_bin_next >> 1) ^ rd_ptr_bin_next;
      end
      
      if (axis_mlast_direct && m_handshake) begin
        rd_pkt_cnt_bin  <= rd_pkt_cnt_bin_next;
        rd_pkt_cnt_bin_plus1 <= rd_pkt_cnt_bin_plus1 + 1'b1;
        rd_pkt_cnt_gray <= (rd_pkt_cnt_bin_next >> 1) ^ rd_pkt_cnt_bin_next;
      end

      if (ram_read_en) axis_mvalid_direct <= 1'b1;
      else if (m_handshake) axis_mvalid_direct <= 1'b0;
    end
  end

    end else begin : g_block
  reg                  [        AXIS_WIDTH-1:0]        axis_mdata_direct;
  reg                  [      AXIS_WIDTH/8-1:0]        axis_mkeep_direct;
  reg                  [   AXIS_USER_WIDTH-1:0]        axis_musr_direct ;
  reg                  [     AXIS_ID_WIDTH-1:0]        axis_mid_direct  ;
  reg                  [   AXIS_DEST_WIDTH-1:0]        axis_mdest_direct;
  reg                  [      AXIS_WIDTH/8-1:0]        axis_mstrb_direct;
  reg                                                  axis_mlast_direct;
  reg                                                  axis_mvalid_direct;

  reg                  [    FIFO_DEPTH_WIDTH:0]        rd_pkt_cnt_bin_plus1;
  reg                  [    FIFO_DEPTH_WIDTH:0]        wr_pkt_cnt_bin_sync_reg;
  wire                                                 allow_read       ;
  wire                                                 ram_read_en      ;
  wire                                                 is_holding_last  ;
  wire                 [    FIFO_DEPTH_WIDTH:0]        cmp_rd_pkt_cnt   ;

      // 使用延后感知包写入，来换取时序
      always @(posedge mclk) begin
        if (mrst_d1) begin
          wr_pkt_cnt_bin_sync_reg <= 'd0;
        end else begin
          wr_pkt_cnt_bin_sync_reg <= wr_pkt_cnt_bin_sync;
        end
      end

      
      always @(posedge mclk) begin
        if (ram_read_en) begin
          axis_mdata_direct <= ram_data[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
          axis_mkeep_direct <= ram_keep[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
          axis_musr_direct <= ram_usr[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
          axis_mid_direct    <= ram_id[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
          axis_mdest_direct <= ram_dest[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
          axis_mstrb_direct <= ram_strb[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
          axis_mlast_direct <= ram_last[rd_ptr_bin[FIFO_DEPTH_WIDTH-1:0]];
        end
      end

      if (BRAM_DO_REG == 1) begin : gen_direct_reg
  assign  almost_empty     = internal_empty && !axis_mvalid_direct;
  assign  axis_mvalid      = axis_mvalid_direct;
  assign  is_holding_last  = axis_mvalid_direct && axis_mlast_direct;
  assign  cmp_rd_pkt_cnt   = is_holding_last ? rd_pkt_cnt_bin_plus1 : rd_pkt_cnt_bin;
        // 包模式下仅在已写入完整包时读取。
  assign  allow_read       = PACKET_FIFO ? (DEADLOCK_RISK ? wr_pkt_cnt_bin_sync_reg != cmp_rd_pkt_cnt : ((wr_pkt_cnt_bin_sync_reg != cmp_rd_pkt_cnt) || deadlock_risk)) : !internal_empty;
        // 输出寄存器空闲，或当前拍完成传输后装载下一拍数据。
  assign  ram_read_en      = allow_read && (!axis_mvalid_direct || axis_mready);

        always @(posedge mclk) begin
          if (mrst_d1) begin
            rd_ptr_bin <= 'd0;
            rd_ptr_gray <= 'd0;
            rd_pkt_cnt_bin <= 'd0;
            rd_pkt_cnt_bin_plus1 <= 'd1;
            rd_pkt_cnt_gray <= 'd0;
            axis_mvalid_direct <= 1'b0;
          end else begin
            if (ram_read_en) begin
              rd_ptr_bin <= rd_ptr_bin_next;
              rd_ptr_gray <= (rd_ptr_bin_next >> 1) ^ rd_ptr_bin_next;
            end

            if (axis_mlast_direct && m_handshake) begin
              rd_pkt_cnt_bin  <= rd_pkt_cnt_bin_next;
              rd_pkt_cnt_bin_plus1 <= rd_pkt_cnt_bin_plus1 + 1'b1;
              rd_pkt_cnt_gray <= (rd_pkt_cnt_bin_next >> 1) ^ rd_pkt_cnt_bin_next;
            end

            if (ram_read_en) axis_mvalid_direct <= 1'b1;
            else if (m_handshake) axis_mvalid_direct <= 1'b0;
          end
        end

  assign  axis_mdata       = axis_mdata_direct;
  assign  axis_mkeep       = axis_mkeep_direct;
  assign  axis_musr        = axis_musr_direct ;
  assign  axis_mid         = axis_mid_direct  ;
  assign  axis_mdest       = axis_mdest_direct;
  assign  axis_mstrb       = axis_mstrb_direct;
  assign  axis_mlast       = axis_mlast_direct;
      end
      else if (BRAM_DO_REG == 2) begin : gen_do_reg
  reg                  [        AXIS_WIDTH-1:0]        axis_mdata_do_reg;
  reg                  [      AXIS_WIDTH/8-1:0]        axis_mkeep_do_reg;
  reg                  [   AXIS_USER_WIDTH-1:0]        axis_musr_do_reg ;
  reg                  [     AXIS_ID_WIDTH-1:0]        axis_mid_do_reg  ;
  reg                  [   AXIS_DEST_WIDTH-1:0]        axis_mdest_do_reg;
  reg                  [      AXIS_WIDTH/8-1:0]        axis_mstrb_do_reg;
  reg                                                  axis_mlast_do_reg;
  reg                                                  axis_mvalid_do_reg;
        
  wire                                                 axis_mready_do_reg = m_handshake||!axis_mvalid_do_reg                                                                   ;
  wire                                                 do_handshake      = m_handshake                                                                                        ;
  wire                                                 axis_mready_direct = axis_mready_do_reg||!axis_mvalid_direct                                                            ;
  wire                                                 direct_handshake  = axis_mready_direct&&axis_mvalid_direct                                                             ;

  assign  almost_empty     = internal_empty && !axis_mvalid_direct && !axis_mvalid_do_reg;
  assign  axis_mvalid      = axis_mvalid_do_reg;
  assign  is_holding_last  = axis_mvalid_direct && axis_mlast_direct;
  assign  cmp_rd_pkt_cnt   = is_holding_last ? rd_pkt_cnt_bin_plus1 : rd_pkt_cnt_bin;
        // 包模式下仅在已写入完整包时读取。
  assign  allow_read       = PACKET_FIFO ? (DEADLOCK_RISK ? wr_pkt_cnt_bin_sync_reg != cmp_rd_pkt_cnt : ((wr_pkt_cnt_bin_sync_reg != cmp_rd_pkt_cnt) || deadlock_risk)) : !internal_empty;
        // 输出寄存器空闲，或当前拍完成传输后装载下一拍数据。
  assign  ram_read_en      = allow_read && (!axis_mvalid_direct || !axis_mvalid_do_reg || axis_mready);

        always @(posedge mclk) begin
          if (axis_mready_do_reg && axis_mvalid_direct) begin
            axis_mdata_do_reg <= axis_mdata_direct;
            axis_mkeep_do_reg <= axis_mkeep_direct;
            axis_musr_do_reg <= axis_musr_direct;
            axis_mid_do_reg   <= axis_mid_direct  ;
            axis_mdest_do_reg <= axis_mdest_direct;
            axis_mstrb_do_reg <= axis_mstrb_direct;
            axis_mlast_do_reg <= axis_mlast_direct;
          end
        end

        always @(posedge mclk) begin
          if (mrst_d1) begin
            rd_ptr_bin <= 'd0;
            rd_ptr_gray <= 'd0;
            rd_pkt_cnt_bin <= 'd0;
            rd_pkt_cnt_bin_plus1 <= 'd1;
            rd_pkt_cnt_gray <= 'd0;
            axis_mvalid_direct <= 1'b0;
            axis_mvalid_do_reg <= 1'b0;
          end else begin
            if (ram_read_en) begin
              rd_ptr_bin <= rd_ptr_bin_next;
              rd_ptr_gray <= (rd_ptr_bin_next >> 1) ^ rd_ptr_bin_next;
            end

            if (axis_mlast_direct && direct_handshake) begin
              rd_pkt_cnt_bin  <= rd_pkt_cnt_bin_next;
              rd_pkt_cnt_bin_plus1 <= rd_pkt_cnt_bin_plus1 + 1'b1;
              rd_pkt_cnt_gray <= (rd_pkt_cnt_bin_next >> 1) ^ rd_pkt_cnt_bin_next;
            end

            if (ram_read_en) axis_mvalid_direct <= 1'b1;
            else if (direct_handshake) axis_mvalid_direct <= 1'b0;

            if (axis_mready_do_reg && axis_mvalid_direct) axis_mvalid_do_reg <= 1'b1;
            else if (do_handshake) axis_mvalid_do_reg <= 1'b0;
          end
        end
        
  assign  axis_mdata       = axis_mdata_do_reg;
  assign  axis_mkeep       = axis_mkeep_do_reg;
  assign  axis_musr        = axis_musr_do_reg ;
  assign  axis_mid         = axis_mid_do_reg  ;
  assign  axis_mdest       = axis_mdest_do_reg;
  assign  axis_mstrb       = axis_mstrb_do_reg;
  assign  axis_mlast       = axis_mlast_do_reg;
      end

    end
  endgenerate

endmodule
`resetall
