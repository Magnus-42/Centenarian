`resetall
`default_nettype none
`timescale 1ns / 100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : axis_nto1_by_val.v
// Module Name : axis_nto1_by_val
// Author      : LiXintao
// Date        : 2026-10-11
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持有前提流水线设计的 N 路 AXI-Stream 输入仲裁复用到 1 路输出 (带 skid 缓冲)
// Note        : 三级流水 d0 -> d1 -> m+skid, 下游反压时由 skid 缓冲吸收一拍
//
// ============================================================================
module axis_nto1_by_val #(
  parameter  NUM_PORTS= 4 ,
  parameter  IDX_W= (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS),
  parameter  AXIS_WIDTH= 64,
  parameter  AXIS_ID_WIDTH= 8 ,
  parameter  AXIS_USER_WIDTH= 4 ,
  parameter  ARBITER_VAL_WIDTH= 4 , // 要求仲裁优先级不能为0，为0则会忽略这个端口，永远不选中
  parameter  LOW_FIRST= 1 ,
  parameter  UPDATE_TID= 0 // 是否在输出端覆写 tid 为当前选中的端口号
) (
  input  wire                                          clk             ,
  input  wire                                          rst             ,

    // --- N 路 Slave 输入 (Packed Array) ---
    // 数据通道
  input  wire          [NUM_PORTS*AXIS_WIDTH-1:0]      axis_sdata      ,
  input  wire          [NUM_PORTS*AXIS_WIDTH/8-1:0]    axis_skeep      ,
  input  wire          [NUM_PORTS*AXIS_ID_WIDTH-1:0]   axis_sid        ,
  input  wire          [NUM_PORTS*AXIS_USER_WIDTH-1:0] axis_susr       ,
  input  wire          [         NUM_PORTS-1:0]        axis_svalid     ,
  input  wire          [         NUM_PORTS-1:0]        axis_slast      ,
  output wire          [         NUM_PORTS-1:0]        axis_sready     ,

    // --- 1 路 Master 输出 ---
  output wire          [        AXIS_WIDTH-1:0]        axis_mdata      ,
  output wire          [      AXIS_WIDTH/8-1:0]        axis_mkeep      ,
  output wire          [     AXIS_ID_WIDTH-1:0]        axis_mid        ,
  output wire          [   AXIS_USER_WIDTH-1:0]        axis_musr       ,
  output wire                                          axis_mvalid     ,
  output wire                                          axis_mlast      ,
  input  wire                                          axis_mready     ,

    // --- 状态 / 调试 ---
  output wire          [             IDX_W-1:0]        stat_active_port,// 当前正在传输的端口号
  output wire                                          stat_idle        // 空闲状态指示
);
  // valid输入 s1
  // 仲裁结果 s2 d0
  // 计算ID，截取单路（这一步可以去掉） s3 d1
  // 输出结果 reg skid

  // 注: tid 覆写用 tid_idx (由 onehot 本地编码; 仅 UPDATE_TID=1 时使用, 否则被综合裁除)

  // 参数检查: 覆写 tid 时 id 位宽需能容纳端口号
  initial begin
    if (UPDATE_TID && AXIS_ID_WIDTH < IDX_W) begin
      $display("开启UPDATE_TID，AXIS_ID_WIDTH需要大于等于IDX_W");
      $finish;
    end

    if (AXIS_USER_WIDTH < ARBITER_VAL_WIDTH) begin
      $display("ARBITER_VAL_WIDTH位宽过大，请拓宽AXIS_USER_WIDTH");
      $finish;
    end
  end

  // ----------------------------------------------------------------------------
  // d0 级寄存器 (N 路输入寄存)
  // ----------------------------------------------------------------------------
  reg                  [NUM_PORTS*AXIS_WIDTH-1:0]      axis_sdata_d0    ;
  reg                  [NUM_PORTS*AXIS_WIDTH/8-1:0]    axis_skeep_d0    ;
  reg                  [NUM_PORTS*AXIS_ID_WIDTH-1:0]   axis_sid_d0      ;
  reg                  [NUM_PORTS*AXIS_USER_WIDTH-1:0] axis_susr_d0     ;
  reg                  [         NUM_PORTS-1:0]        axis_svalid_d0   ;
  reg                  [         NUM_PORTS-1:0]        axis_slast_d0    ;

  // ----------------------------------------------------------------------------
  // d1 级寄存器 (选中路寄存)
  // ----------------------------------------------------------------------------
  reg                  [        AXIS_WIDTH-1:0]        axis_sdata_d1    ;
  reg                  [      AXIS_WIDTH/8-1:0]        axis_skeep_d1    ;
  reg                  [     AXIS_ID_WIDTH-1:0]        axis_sid_d1      ;
  reg                  [   AXIS_USER_WIDTH-1:0]        axis_susr_d1     ;
  reg                                                  axis_svalid_d1   ;
  reg                                                  axis_slast_d1    ;

  // ----------------------------------------------------------------------------
  // axis_m 输出寄存器
  // ----------------------------------------------------------------------------
  reg                  [        AXIS_WIDTH-1:0]        axis_mdata_reg   ;
  reg                  [      AXIS_WIDTH/8-1:0]        axis_mkeep_reg   ;
  reg                  [     AXIS_ID_WIDTH-1:0]        axis_mid_reg     ;
  reg                  [   AXIS_USER_WIDTH-1:0]        axis_musr_reg    ;
  reg                                                  axis_mvalid_reg  ;
  reg                                                  axis_mlast_reg   ;

  // ----------------------------------------------------------------------------
  // skid 缓冲寄存器
  // ----------------------------------------------------------------------------
  reg                  [        AXIS_WIDTH-1:0]        skid_data_reg    ;
  reg                  [      AXIS_WIDTH/8-1:0]        skid_keep_reg    ;
  reg                  [     AXIS_ID_WIDTH-1:0]        skid_id_reg      ;
  reg                  [   AXIS_USER_WIDTH-1:0]        skid_usr_reg     ;
  reg                                                  skid_valid_reg   ;
  reg                                                  skid_last_reg    ;

  // ----------------------------------------------------------------------------
  // 仲裁输出 (由 arbiter 例化驱动)
  // ----------------------------------------------------------------------------
  wire                 [         NUM_PORTS-1:0]        arbiter_onehot   ;
  wire                                                 arbiter_valid    ;

  // ----------------------------------------------------------------------------
  // ready / handshake
  // ----------------------------------------------------------------------------
  wire                                                 axis_sready_d1    = !skid_valid_reg                      ;
  // 仅选中的一路获得反向 ready
  wire                 [         NUM_PORTS-1:0]        axis_sready_d0    = axis_sready_d1 ? arbiter_onehot : 'd0;
  // 各级握手
  wire                 [         NUM_PORTS-1:0]        s_handshake       = axis_sready & axis_svalid            ;
  wire                 [         NUM_PORTS-1:0]        d0_handshake      = axis_sready_d0 & axis_svalid_d0      ;
  wire                                                 d1_handshake      = axis_sready_d1 && axis_svalid_d1     ;
  wire                                                 m_handshake       = axis_mready && axis_mvalid_reg       ;

  // ----------------------------------------------------------------------------
  // 仲裁组合逻辑
  // ----------------------------------------------------------------------------
  wire                                                 arbiter_ack       = |(d0_handshake & axis_slast_d0)      ;
  wire                 [         NUM_PORTS-1:0]        axis_svalid_mask  = axis_svalid_d0&(~arbiter_onehot)     ;

  wire                 [NUM_PORTS * ARBITER_VAL_WIDTH -1 : 0]arbiter_req_val  ;
  genvar j;
  generate
    for (j = 0; j < NUM_PORTS; j = j + 1) begin : gen_arb_req
    assign arbiter_req_val[j*ARBITER_VAL_WIDTH +: ARBITER_VAL_WIDTH] = 
             axis_svalid_mask[j] ? axis_susr_d0[j*AXIS_USER_WIDTH +: ARBITER_VAL_WIDTH] :
             s_handshake[j]      ? axis_susr   [j*AXIS_USER_WIDTH +: ARBITER_VAL_WIDTH] :
                                   {ARBITER_VAL_WIDTH{1'b0}};
    end
  endgenerate
  

  // ============================================================================
  // sready 输出: 选中路且 d1 可收, 或该路 d0 为空
  // ============================================================================
  assign  axis_sready      = axis_sready_d0 | ~axis_svalid_d0;

  // ============================================================================
  // axis_d0 输入寄存器 (N 路)
  // ============================================================================
  genvar i;
  generate
    for (i = 0; i < NUM_PORTS; i = i + 1) begin : gen_d0_reg
      always @(posedge clk) begin
        if (rst) begin
          axis_sdata_d0[AXIS_WIDTH*i+:AXIS_WIDTH]           <= 'd0;
          axis_skeep_d0[AXIS_WIDTH/8*i+:AXIS_WIDTH/8]       <= 'd0;
          axis_sid_d0[AXIS_ID_WIDTH*i+:AXIS_ID_WIDTH]       <= 'd0;
          axis_susr_d0[AXIS_USER_WIDTH*i+:AXIS_USER_WIDTH] <= 'd0;
          axis_svalid_d0[i]                                 <= 'd0;
          axis_slast_d0[i]                                  <= 'd0;
        end else begin
          if (s_handshake[i]) begin
            axis_sdata_d0[AXIS_WIDTH*i+:AXIS_WIDTH]           <= axis_sdata[AXIS_WIDTH*i+:AXIS_WIDTH];
            axis_skeep_d0[AXIS_WIDTH/8*i+:AXIS_WIDTH/8]       <= axis_skeep[AXIS_WIDTH/8*i+:AXIS_WIDTH/8];
            axis_sid_d0[AXIS_ID_WIDTH*i+:AXIS_ID_WIDTH]       <= axis_sid[AXIS_ID_WIDTH*i+:AXIS_ID_WIDTH];
            axis_susr_d0[AXIS_USER_WIDTH*i+:AXIS_USER_WIDTH] <= axis_susr[AXIS_USER_WIDTH*i+:AXIS_USER_WIDTH];
            axis_svalid_d0[i]                                 <= axis_svalid[i];
            axis_slast_d0[i]                                  <= axis_slast[i];
          end else if (d0_handshake[i]) begin
            axis_svalid_d0[i] <= 'd0;
            axis_slast_d0[i]  <= 'd0;
          end
        end
      end
    end
  endgenerate

  // ============================================================================
  // 选中路数据选择（onehot 直接选择; 不再依赖 arbiter 的 index 输出）
  // ============================================================================
  function [IDX_W-1:0] oh2bin;
  input                [         NUM_PORTS-1:0]        oh              ;
  integer                                              kk               ;
    begin
        oh2bin = {IDX_W{1'b0}};
        for (kk = NUM_PORTS-1; kk >= 0; kk = kk - 1)
            if (oh[kk]) oh2bin = kk[IDX_W-1:0];
    end
  endfunction

  wire                 [             IDX_W-1:0]        tid_idx           = oh2bin(arbiter_onehot)               ;// 仅 UPDATE_TID=1 时使用

  reg                  [        AXIS_WIDTH-1:0]        sdata_sel        ;
  reg                  [      AXIS_WIDTH/8-1:0]        skeep_sel        ;
  reg                  [     AXIS_ID_WIDTH-1:0]        sid_sel          ;
  reg                  [   AXIS_USER_WIDTH-1:0]        susr_sel         ;
  wire                                                 slast_sel         = |(axis_slast_d0 & arbiter_onehot)    ;
  integer                                              q2               ;
  always @(*) begin
    sdata_sel = {AXIS_WIDTH{1'b0}};
    skeep_sel = {AXIS_WIDTH/8{1'b0}};
    sid_sel   = {AXIS_ID_WIDTH{1'b0}};
    susr_sel = {AXIS_USER_WIDTH{1'b0}};
    for (q2 = 0; q2 < NUM_PORTS; q2 = q2 + 1) begin
      sdata_sel = sdata_sel | ({AXIS_WIDTH{arbiter_onehot[q2]}}      & axis_sdata_d0[q2*AXIS_WIDTH +: AXIS_WIDTH]);
      skeep_sel = skeep_sel | ({AXIS_WIDTH/8{arbiter_onehot[q2]}}    & axis_skeep_d0[q2*AXIS_WIDTH/8 +: AXIS_WIDTH/8]);
      sid_sel   = sid_sel   | ({AXIS_ID_WIDTH{arbiter_onehot[q2]}}   & axis_sid_d0[q2*AXIS_ID_WIDTH +: AXIS_ID_WIDTH]);
      susr_sel = susr_sel | ({AXIS_USER_WIDTH{arbiter_onehot[q2]}} & axis_susr_d0[q2*AXIS_USER_WIDTH +: AXIS_USER_WIDTH]);
    end
  end

  // ============================================================================
  // axis_d1 选中路寄存器
  // ============================================================================
  always @(posedge clk) begin
    if (rst) begin
      axis_svalid_d1 <= 1'b0;
      axis_sdata_d1 <= 'd0;
      axis_skeep_d1 <= 'd0;
      axis_sid_d1 <= 'd0;
      axis_susr_d1 <= 'd0;
      axis_slast_d1 <= 'd0;
    end else begin
      if (|d0_handshake) begin
        // 有新数据进来且被选中, 抓取数据并拉高 valid（onehot 直选, 无 index）
        axis_sdata_d1 <= sdata_sel;
        axis_skeep_d1 <= skeep_sel;
        axis_sid_d1 <= UPDATE_TID ?
                    tid_idx :
                    sid_sel;
        axis_susr_d1 <= susr_sel;
        axis_slast_d1 <= slast_sel;
        axis_svalid_d1 <= 1'b1;
      end else if (d1_handshake) begin
        // 下游拿走了数据且无新数据进来, 清零 valid 防止幽灵数据
        axis_svalid_d1 <= 'd0;
        axis_slast_d1  <= 'd0;
      end
    end
  end

  // ============================================================================
  // axis_m 输出 + skid 缓冲
  // ============================================================================
  wire                                                 reg_can_take      = !axis_mvalid_reg || axis_mready      ;
  wire                                                 skid_to_reg       = skid_valid_reg && reg_can_take       ;
  wire                                                 d1_to_reg         = d1_handshake && reg_can_take         ;
  wire                                                 d1_to_skid        = d1_handshake && !reg_can_take        ;

  // data path
  always @(posedge clk) begin
    if(skid_to_reg) begin
      axis_mdata_reg <= skid_data_reg;
      axis_mkeep_reg <= skid_keep_reg;
      axis_mid_reg   <= skid_id_reg;
      axis_musr_reg <= skid_usr_reg;
      axis_mlast_reg <= skid_last_reg;
    end
    else if(d1_to_reg) begin
      axis_mdata_reg <= axis_sdata_d1;
      axis_mkeep_reg <= axis_skeep_d1;
      axis_mid_reg   <= axis_sid_d1;
      axis_musr_reg <= axis_susr_d1;
      axis_mlast_reg <= axis_slast_d1;
    end
  end

  always @(posedge clk) begin
    if(d1_to_skid) begin
      skid_data_reg <= axis_sdata_d1;
      skid_keep_reg <= axis_skeep_d1;
      skid_id_reg   <= axis_sid_d1;
      skid_usr_reg <= axis_susr_d1;
      skid_last_reg <= axis_slast_d1;
    end
  end

  // ctrl path
  always @(posedge clk) begin
    if (rst) begin
      axis_mvalid_reg <= 1'b0;
    end
    else begin
      if(skid_to_reg || d1_to_reg) begin
        axis_mvalid_reg <= 1'b1;
      end
      else if(m_handshake) begin
        axis_mvalid_reg <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      skid_valid_reg <= 1'b0;
    end
    else begin
      if(d1_to_skid) begin
        skid_valid_reg <= 1'b1;
      end
      else if(skid_to_reg) begin
        skid_valid_reg <= 1'b0;
      end
    end
  end

  // ============================================================================
  // 输出
  // ============================================================================
  assign  axis_mdata       = axis_mdata_reg   ;
  assign  axis_mkeep       = axis_mkeep_reg   ;
  assign  axis_mid         = axis_mid_reg     ;
  assign  axis_musr        = axis_musr_reg    ;
  assign  axis_mvalid      = axis_mvalid_reg  ;
  assign  axis_mlast       = axis_mlast_reg   ;

  reg                  [             IDX_W-1:0]        stat_active_port_reg;
  reg                  [         NUM_PORTS-1:0]        stat_oh_reg      ;
  reg                                                  stat_busy_d1     ;
  reg                                                  stat_idle_reg    ;
  always @(posedge clk) begin
    if (rst) begin
      stat_active_port_reg <= 'd0;
      stat_oh_reg          <= {NUM_PORTS{1'b0}};
      stat_busy_d1         <= 1'b0;
      stat_idle_reg        <= 1'b1;
    end else begin
      // 快照寄存器(与主路径隔离, 编码器输入为本寄存器输出)
      stat_oh_reg          <= arbiter_valid ? arbiter_onehot : {NUM_PORTS{1'b0}};
      stat_busy_d1         <= (arbiter_valid || axis_svalid_d1 || axis_mvalid_reg || skid_valid_reg);
      stat_active_port_reg <= oh2bin(stat_oh_reg);
      stat_idle_reg        <= ~stat_busy_d1;
    end
  end
  assign  stat_active_port = stat_active_port_reg;
  assign  stat_idle        = stat_idle_reg    ;

  // ============================================================================
  // 仲裁器例化
  // ============================================================================
  arbiter_by_val #(
    .N                (NUM_PORTS        ),
    .WIDTH            (ARBITER_VAL_WIDTH),// 位宽必须是 USER_WIDTH
    .PIPELINE         (1                ),// 必须使用 PIPELINE=1 维持无气泡
    .LOW_FIRST        (LOW_FIRST        ) // 根据需求配置高低位优先
  ) u_arbiter (
    .clk              (clk              ),
    .rst              (rst              ),
    .req_val          (arbiter_req_val  ),
    .grant_ack        (arbiter_ack      ),

    .grant_onehot     (arbiter_onehot   ),
    .grant_val        (                 ),// 不接出
    .grant_valid      (arbiter_valid    ) 
  );

endmodule
`resetall
