`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : axis_fifo_sync.v
// Module Name : axis_fifo_sync
// Author      : LiXintao
// Date        : 2026-08-13
// Version     : v2.1
// ----------------------------------------------------------------------------
// Description : 同步 AXI-Stream FIFO, 支持包为单位传输
//               1. 读写同钟, 内部以 RAM (distributed/block) 实现
//               2. 支持包模式 (PACKET_FIFO), 输出侧按整包交付
//               3. 输出空/满/可编程阈值/剩余深度等状态
// Note        : 1. FIFO_DEPTH 包模式下深度需 >= 最大包 beat 数,
//                  否则大包无法完整放入会卡死
//               2. axis_sready 为反压信号: 满时拉低, 上游需 hold 数据等待,
//                  不会丢包
//               3. distributed 实现为组合读 (异步读), block 实现为输出寄存器
//                  形式 (同步读, 自带一拍延迟，可配置BRAM_DO_REG再增加延迟以提升时序)
//               4. 支持自动计算RAM类型
//               5. DEADLOCK_RISK避免包模式死锁
// ============================================================================
module axis_fifo_sync #(
  parameter  FIFO_DEPTH= 32,                    // FIFO 深度, 需为 2 的幂
  parameter  AXIS_WIDTH= 64,                    // 数据位宽 (字节整数倍)
  parameter  AXIS_USER_WIDTH= 100,                   // 用户自定义信息位宽
  parameter  AXIS_ID_WIDTH= 1 ,                     // 流标识位宽
  parameter  AXIS_DEST_WIDTH= 1 ,                     // 路由信息位宽
  parameter  PACKET_FIFO= 1 ,                     // 包模式开关: 1 开启, 0 关闭
  parameter  FIFO_MEMORY_TYPE= "distributed",         // 存储类型: distributed / block / auto
  parameter  PROG_EMPTY_THRESH= FIFO_DEPTH/4,          // 可编程空阈值 (剩余 <= 该值拉高 prog_empty)
  parameter  PROG_FULL_THRESH= FIFO_DEPTH/2,          // 可编程满阈值 (剩余 >= 该值拉高 prog_full)
  parameter  REMAIN_COUNT_WIDTH= $clog2(FIFO_DEPTH) + 1, // 剩余深度计数输出位宽
  parameter  BRAM_DO_REG= 2 , // BRAM的输出流水线级数，推荐为2，可以提高时序
  parameter  DEADLOCK_RISK= 0 
) (
  input  wire                                          rst             ,
  input  wire                                          clk             ,

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
  output wire                                          prog_empty      ,// 剩余深度 <= PROG_EMPTY_THRESH
  output wire                                          prog_full       ,// 剩余深度 >= PROG_FULL_THRESH

  output wire                                          empty           ,// FIFO 空
  output wire                                          full            ,// FIFO 满

  output wire          [REMAIN_COUNT_WIDTH-1:0]        remain_count     // 当前剩余深度 (已写入未读走的字数)
);
  initial begin
    if (REMAIN_COUNT_WIDTH != $clog2(FIFO_DEPTH) + 1) begin
      $display("REMAIN_COUNT_WIDTH长度应该设置为$clog2(FIFO_DEPTH) + 1");
      $finish;
    end
  end

  // ----------------------------------------------------------------------------
  // 地址位宽与剩余深度高位补零位宽
  // ----------------------------------------------------------------------------
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

  // ----------------------------------------------------------------------------
  // RAM 存储 (ram_style 由 FIFO_MEMORY_TYPE 决定)
  // ----------------------------------------------------------------------------
(* ram_style = DATA_MEMORY_TYPE *)   reg                  [        AXIS_WIDTH-1:0]        ram_data[0:FIFO_DEPTH-1];
(* ram_style = KEEP_MEMORY_TYPE *)   reg                  [      AXIS_WIDTH/8-1:0]        ram_keep[0:FIFO_DEPTH-1];
(* ram_style = LAST_MEMORY_TYPE *)   reg                                                  ram_last[0:FIFO_DEPTH-1];
(* ram_style = USER_MEMORY_TYPE *)   reg                  [   AXIS_USER_WIDTH-1:0]        ram_usr[0:FIFO_DEPTH-1];
(* ram_style = STRB_MEMORY_TYPE *)   reg                  [      AXIS_WIDTH/8-1:0]        ram_strb[0:FIFO_DEPTH-1];
(* ram_style = ID_MEMORY_TYPE *)   reg                  [     AXIS_ID_WIDTH-1:0]        ram_id[0:FIFO_DEPTH-1];
(* ram_style = DEST_MEMORY_TYPE *)   reg                  [   AXIS_DEST_WIDTH-1:0]        ram_dest[0:FIFO_DEPTH-1];

  // ------------------------------------------
  // RAM 仿真及上电初始化 (综合工具支持)
  // ------------------------------------------
  integer                                              i                ;
  initial begin
    for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
      ram_data[i] = {AXIS_WIDTH{1'b0}};
      ram_keep[i] = {AXIS_WIDTH/8{1'b0}};
      ram_last[i] = 1'b0;
      ram_usr[i]  = {AXIS_USER_WIDTH{1'b0}};
      ram_strb[i] = 'd0;
      ram_id  [i] = 'd0;
      ram_dest[i] = 'd0;
    end
  end

  // ----------------------------------------------------------------------------
  // 指针与计数 (多 1 位用于满检测的回绕判断)
  // ----------------------------------------------------------------------------
  reg                  [    FIFO_DEPTH_WIDTH:0]        wr_ptr           ;
  reg                  [    FIFO_DEPTH_WIDTH:0]        wr_packet_cnt    ;
  reg                  [    FIFO_DEPTH_WIDTH:0]        rd_ptr           ;
  reg                  [    FIFO_DEPTH_WIDTH:0]        rd_packet_cnt    ;
  wire                 [  FIFO_DEPTH_WIDTH-1:0]        wr_addr           = wr_ptr[FIFO_DEPTH_WIDTH-1:0]                                                                       ;
  wire                 [  FIFO_DEPTH_WIDTH-1:0]        rd_addr           = rd_ptr[FIFO_DEPTH_WIDTH-1:0]                                                                       ;

  wire                                                 deadlock_risk    ;
  // ----------------------------------------------------------------------------
  // 状态信号
  // ----------------------------------------------------------------------------
  assign  remain_count     = wr_ptr - rd_ptr  ;
  /* verilator lint_off WIDTH */
  assign  prog_empty       = (remain_count <= PROG_EMPTY_THRESH);
  assign  prog_full        = (remain_count >= PROG_FULL_THRESH);
  /* verilator lint_on WIDTH */

  wire                                                 internal_empty    = (wr_ptr == rd_ptr)                                                                                 ;
  assign  deadlock_risk    = (remain_count >= (FIFO_DEPTH - 4));
  assign full = (wr_ptr[FIFO_DEPTH_WIDTH] != rd_ptr[FIFO_DEPTH_WIDTH]) &&
                wr_ptr[FIFO_DEPTH_WIDTH-1:0] == rd_ptr[FIFO_DEPTH_WIDTH-1:0];
  wire                                                 s_handshake       = axis_svalid && axis_sready                                                                         ;
  wire                                                 m_handshake       = axis_mvalid && axis_mready                                                                         ;
  wire                                                 packet_empty      = wr_packet_cnt == rd_packet_cnt                                                                     ;
  // wire packet_full = (wr_packet_cnt[FIFO_DEPTH_WIDTH] != rd_packet_cnt[FIFO_DEPTH_WIDTH]) &&
  //                    wr_packet_cnt[FIFO_DEPTH_WIDTH-1:0] == rd_packet_cnt[FIFO_DEPTH_WIDTH-1:0];
  assign  axis_sready      = !full            ;// 满时拉低反压, 上游 hold 等待

  // ============================================================================
  // 写逻辑
  // ============================================================================
  always @(posedge clk) begin
    if (s_handshake) begin
      ram_data[wr_addr] <= axis_sdata;
      ram_keep[wr_addr] <= axis_skeep;
      ram_last[wr_addr] <= axis_slast;
      ram_usr[wr_addr] <= axis_susr;
      ram_strb[wr_addr] <= axis_sstrb;
      ram_id[wr_addr]   <= axis_sid;
      ram_dest[wr_addr] <= axis_sdest;
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      wr_ptr <= 'd0;
      wr_packet_cnt <= 'd0;
    end else begin
      if (s_handshake) begin
        wr_ptr <= wr_ptr + 1'b1;

        if (axis_slast) wr_packet_cnt <= wr_packet_cnt + 1'b1;
        else wr_packet_cnt <= wr_packet_cnt;
      end
    end
  end

  // ============================================================================
  // 读逻辑 : distributed 为组合读, block 为输出寄存器形式
  // ============================================================================
  generate
    if (FIFO_MEMORY_TYPE == "distributed" || ALL_DISTRIBUTED) begin : gen_dist_ram
  assign  empty            = internal_empty   ;
  assign  axis_mvalid      = PACKET_FIFO ? (DEADLOCK_RISK ? !packet_empty : !packet_empty||deadlock_risk) : !empty;// 包模式下无完整包则无效
  assign  axis_mdata       = ram_data[rd_addr];
  assign  axis_mkeep       = ram_keep[rd_addr];
  assign  axis_mlast       = ram_last[rd_addr];
  assign  axis_musr        = ram_usr[rd_addr] ;
  assign  axis_mstrb       = ram_strb[rd_addr];
  assign  axis_mid         = ram_id[rd_addr]  ;
  assign  axis_mdest       = ram_dest[rd_addr];

      always @(posedge clk) begin
        if (rst) begin
          rd_ptr <= 'd0;
          rd_packet_cnt <= 'd0;
        end else begin
          if (m_handshake) begin
            rd_ptr <= rd_ptr + 1'b1;

            if (axis_mlast) rd_packet_cnt <= rd_packet_cnt + 1'b1;
            else rd_packet_cnt <= rd_packet_cnt;
          end
        end
      end
    end else begin : gen_block_ram
      // block RAM 为同步读, 需输出寄存器打一拍 (FWFT 形式)
  reg                  [        AXIS_WIDTH-1:0]        mdata_reg        ;
  reg                  [      AXIS_WIDTH/8-1:0]        mkeep_reg        ;
  reg                                                  mlast_reg        ;
  reg                  [   AXIS_USER_WIDTH-1:0]        musr_reg         ;
  reg                  [      AXIS_WIDTH/8-1:0]        mstrb_reg        ;
  reg                  [     AXIS_ID_WIDTH-1:0]        mid_reg          ;
  reg                  [   AXIS_DEST_WIDTH-1:0]        mdest_reg        ;
  reg                                                  mvalid_reg       ;

  reg                  [    FIFO_DEPTH_WIDTH:0]        rd_packet_cnt_plus1;
  wire                                                 is_holding_last  ;
  wire                 [    FIFO_DEPTH_WIDTH:0]        cmp_rd_pkt_cnt   ;
  wire                                                 allow_read       ;
  wire                                                 ram_read_en      ;


  assign  axis_mdata       = mdata_reg        ;
  assign  axis_mkeep       = mkeep_reg        ;
  assign  axis_mlast       = mlast_reg        ;
  assign  axis_musr        = musr_reg         ;
  assign  axis_mstrb       = mstrb_reg        ;
  assign  axis_mid         = mid_reg          ;
  assign  axis_mdest       = mdest_reg        ;
  assign  axis_mvalid      = mvalid_reg       ;

      if (BRAM_DO_REG == 1) begin : gen_direct
  assign  empty            = internal_empty && !mvalid_reg;// RAM 空且输出寄存器无数据才空
  assign  is_holding_last  = mvalid_reg && mlast_reg;
  assign  cmp_rd_pkt_cnt   = is_holding_last ? rd_packet_cnt_plus1 : rd_packet_cnt;
  assign  allow_read       = PACKET_FIFO ? (DEADLOCK_RISK ? (wr_packet_cnt != cmp_rd_pkt_cnt) : (wr_packet_cnt != cmp_rd_pkt_cnt)||deadlock_risk) : !internal_empty;
  assign  ram_read_en      = allow_read && (!mvalid_reg || axis_mready);

        always @(posedge clk) begin
          if (rst) begin
            rd_ptr        <= 'd0;
            rd_packet_cnt <= 'd0;
            rd_packet_cnt_plus1 <= 'd1;
            mvalid_reg    <= 'b0;
          end else begin
            // 从 BRAM 中读取数据并推入输出寄存器
            if (ram_read_en) begin
              rd_ptr <= rd_ptr + 1'b1;
            end

            if (ram_read_en) mvalid_reg <= 1'b1;
            else if (m_handshake) mvalid_reg <= 1'b0;

            if (m_handshake && mlast_reg) begin
              rd_packet_cnt <= rd_packet_cnt + 1'b1;
              rd_packet_cnt_plus1 <= rd_packet_cnt_plus1 + 1'b1;
            end
          end
        end
        
        always @(posedge clk) begin
          // 从 BRAM 中读取数据并推入输出寄存器
          if (ram_read_en) begin
            mdata_reg <= ram_data[rd_addr];
            mkeep_reg <= ram_keep[rd_addr];
            mlast_reg <= ram_last[rd_addr];
            musr_reg <= ram_usr[rd_addr];
            mstrb_reg <= ram_strb[rd_addr];
            mid_reg <= ram_id[rd_addr];
            mdest_reg <= ram_dest[rd_addr];
          end
        end
      end
      else if (BRAM_DO_REG == 2) begin : gen_do_reg
  reg                  [        AXIS_WIDTH-1:0]        mdata_direct     ;
  reg                  [      AXIS_WIDTH/8-1:0]        mkeep_direct     ;
  reg                                                  mlast_direct     ;
  reg                  [   AXIS_USER_WIDTH-1:0]        musr_direct      ;
  reg                  [      AXIS_WIDTH/8-1:0]        mstrb_direct     ;
  reg                  [     AXIS_ID_WIDTH-1:0]        mid_direct       ;
  reg                  [   AXIS_DEST_WIDTH-1:0]        mdest_direct     ;
  reg                                                  mvalid_direct    ;

  wire                                                 mready_direct     = !mvalid_reg || axis_mready                                                                         ;
  wire                                                 direct_handshake  = mvalid_direct && mready_direct                                                                     ;

  assign  empty            = internal_empty && !mvalid_direct && !mvalid_reg;// RAM 空且输出寄存器无数据才空
  assign  is_holding_last  = mvalid_direct && mlast_direct;
  assign  cmp_rd_pkt_cnt   = is_holding_last ? rd_packet_cnt_plus1 : rd_packet_cnt;
  assign  allow_read       = PACKET_FIFO ? (DEADLOCK_RISK ? (wr_packet_cnt != cmp_rd_pkt_cnt) : (wr_packet_cnt != cmp_rd_pkt_cnt)||deadlock_risk) : !internal_empty;
  assign  ram_read_en      = allow_read && (!mvalid_direct || !mvalid_reg || axis_mready);

        always @(posedge clk) begin
          if (direct_handshake) begin
            mdata_reg  <= mdata_direct;
            mkeep_reg  <= mkeep_direct;
            mlast_reg  <= mlast_direct;
            musr_reg  <= musr_direct;
            mstrb_reg  <= mstrb_direct;
            mid_reg    <= mid_direct;
            mdest_reg  <= mdest_direct;
          end
        end

        always @(posedge clk) begin
          if (rst) begin
            rd_ptr        <= 'd0;
            rd_packet_cnt <= 'd0;
            rd_packet_cnt_plus1 <= 'd1;
            mvalid_reg    <= 'b0;
            mvalid_direct <= 'b0;
          end else begin
            // 从 BRAM 中读取数据并推入输出寄存器
            if (ram_read_en) begin
              rd_ptr <= rd_ptr + 1'b1;
            end

            if (ram_read_en) mvalid_direct <= 1'b1;
            else if (direct_handshake) mvalid_direct <= 1'b0;

            if (direct_handshake) mvalid_reg <= 1'b1;
            else if (m_handshake) mvalid_reg <= 1'b0;

            if (direct_handshake && mlast_direct) begin
              rd_packet_cnt <= rd_packet_cnt + 1'b1;
              rd_packet_cnt_plus1 <= rd_packet_cnt_plus1 + 1'b1;
            end
          end
        end
        
        always @(posedge clk) begin
          // 从 BRAM 中读取数据并推入输出寄存器
          if (ram_read_en) begin
            mdata_direct <= ram_data[rd_addr];
            mkeep_direct <= ram_keep[rd_addr];
            mlast_direct <= ram_last[rd_addr];
            musr_direct <= ram_usr[rd_addr];
            mstrb_direct <= ram_strb[rd_addr];
            mid_direct <= ram_id[rd_addr];
            mdest_direct <= ram_dest[rd_addr];
          end
        end
      end

    end
  endgenerate

endmodule
`resetall
