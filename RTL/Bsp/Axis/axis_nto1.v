`resetall
`default_nettype none
`timescale 1ns / 100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : axis_nto1.v
// Module Name : axis_nto1
// Author      : LiXintao
// Date        : 2026-08-14
// Version     : v2.0
// ----------------------------------------------------------------------------
// Description : 支持有前提流水线设计的 N 路 AXI-Stream 输入仲裁复用到 1 路输出 (带 skid 缓冲)
// Note        : 三级流水 d0 -> d1 -> m+skid, 下游反压时由 skid 缓冲吸收一拍
//
// ============================================================================
module axis_nto1 #(
    parameter NUM_PORTS = 4,
    parameter IDX_W = (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS),
    parameter AXIS_WIDTH = 64,
    parameter AXIS_ID_WIDTH = 8,
    parameter AXIS_USER_WIDTH = 1,
    parameter ARB_TYPE = 0,  // 0=RR, 1=Strict Priority
    parameter UPDATE_TID = 0 // 是否在输出端覆写 tid 为当前选中的端口号
) (
    input wire clk,
    input wire rst,

    // --- N 路 Slave 输入 (Packed Array) ---
    // 数据通道
    input  wire [     NUM_PORTS*AXIS_WIDTH-1:0] axis_sdata,
    input  wire [   NUM_PORTS*AXIS_WIDTH/8-1:0] axis_skeep,
    input  wire [  NUM_PORTS*AXIS_ID_WIDTH-1:0] axis_sid,
    input  wire [NUM_PORTS*AXIS_USER_WIDTH-1:0] axis_susr,
    input  wire [                NUM_PORTS-1:0] axis_svalid,
    input  wire [                NUM_PORTS-1:0] axis_slast,
    output wire [                NUM_PORTS-1:0] axis_sready,

    // --- 1 路 Master 输出 ---
    output wire [     AXIS_WIDTH-1:0] axis_mdata,
    output wire [   AXIS_WIDTH/8-1:0] axis_mkeep,
    output wire [  AXIS_ID_WIDTH-1:0] axis_mid,
    output wire [AXIS_USER_WIDTH-1:0] axis_musr,
    output wire                       axis_mvalid,
    output wire                       axis_mlast,
    input  wire                       axis_mready,

    // --- 状态 / 调试 ---
    output wire [IDX_W-1:0] stat_active_port,  // 当前正在传输的端口号
    output wire             stat_idle          // 空闲状态指示
);
  // valid输入 s1
  // 仲裁结果 s2 d0
  // 计算ID，截取单路（这一步可以去掉） s3 d1
  // 输出结果 reg skid

  localparam UPDATE_TID_PAD = (AXIS_ID_WIDTH > IDX_W) ? (AXIS_ID_WIDTH - IDX_W) : 1;

  // 参数检查: 覆写 tid 时 id 位宽需能容纳端口号
  initial begin
    if (UPDATE_TID && AXIS_ID_WIDTH < IDX_W) begin
      $display("开启UPDATE_TID，AXIS_ID_WIDTH需要大于等于IDX_W");
      $finish;
    end
  end

  // ----------------------------------------------------------------------------
  // d0 级寄存器 (N 路输入寄存)
  // ----------------------------------------------------------------------------
  reg [NUM_PORTS*AXIS_WIDTH-1:0]      axis_sdata_d0;
  reg [NUM_PORTS*AXIS_WIDTH/8-1:0]    axis_skeep_d0;
  reg [NUM_PORTS*AXIS_ID_WIDTH-1:0]   axis_sid_d0;
  reg [NUM_PORTS*AXIS_USER_WIDTH-1:0] axis_susr_d0;
  reg [NUM_PORTS-1:0]                 axis_svalid_d0;
  reg [NUM_PORTS-1:0]                 axis_slast_d0;

  // ----------------------------------------------------------------------------
  // d1 级寄存器 (选中路寄存)
  // ----------------------------------------------------------------------------
  reg [AXIS_WIDTH-1:0]      axis_sdata_d1;
  reg [AXIS_WIDTH/8-1:0]    axis_skeep_d1;
  reg [AXIS_ID_WIDTH-1:0]   axis_sid_d1;
  reg [AXIS_USER_WIDTH-1:0] axis_susr_d1;
  reg                       axis_svalid_d1;
  reg                       axis_slast_d1;

  // ----------------------------------------------------------------------------
  // axis_m 输出寄存器
  // ----------------------------------------------------------------------------
  reg [AXIS_WIDTH-1:0]      axis_mdata_reg;
  reg [AXIS_WIDTH/8-1:0]    axis_mkeep_reg;
  reg [AXIS_ID_WIDTH-1:0]   axis_mid_reg;
  reg [AXIS_USER_WIDTH-1:0] axis_musr_reg;
  reg                       axis_mvalid_reg;
  reg                       axis_mlast_reg;

  // ----------------------------------------------------------------------------
  // skid 缓冲寄存器
  // ----------------------------------------------------------------------------
  reg [AXIS_WIDTH-1:0]      skid_data_reg;
  reg [AXIS_WIDTH/8-1:0]    skid_keep_reg;
  reg [AXIS_ID_WIDTH-1:0]   skid_id_reg;
  reg [AXIS_USER_WIDTH-1:0] skid_usr_reg;
  reg                       skid_valid_reg;
  reg                       skid_last_reg;

  // ----------------------------------------------------------------------------
  // 仲裁输出 (由 arbiter 例化驱动)
  // ----------------------------------------------------------------------------
  wire [IDX_W-1:0] arbiter_out;
  wire [NUM_PORTS-1:0] arbiter_onehot;
  wire             arbiter_valid;

  // ----------------------------------------------------------------------------
  // ready / handshake
  // ----------------------------------------------------------------------------
  wire                axis_sready_d1  = !skid_valid_reg;
  // 仅选中的一路获得反向 ready
  wire [NUM_PORTS-1:0] axis_sready_d0 = (arbiter_valid && axis_sready_d1) ? arbiter_onehot : 'd0;
  // 各级握手
  wire [NUM_PORTS-1:0] s_handshake    = axis_sready & axis_svalid;
  wire [NUM_PORTS-1:0] d0_handshake   = axis_sready_d0 & axis_svalid_d0;
  wire                 d1_handshake   = axis_sready_d1 && axis_svalid_d1;
  wire                 m_handshake = axis_mready && axis_mvalid_reg;

  // ----------------------------------------------------------------------------
  // 仲裁组合逻辑
  // ----------------------------------------------------------------------------
  wire arbiter_ack = d0_handshake[arbiter_out] & axis_slast_d0[arbiter_out];
  // 引入axis_svalid，但是必须已经握手，否则以axis_svalid_d0管道中的为准。而axis_svalid_d0管道中需要屏蔽掉已经服务过的位
  wire [NUM_PORTS-1:0] axis_svalid_mask = axis_svalid_d0&(~arbiter_onehot); // 屏蔽掉已经服务过的位，是管道的残留
  wire [NUM_PORTS-1:0] arbiter_din = (axis_svalid_mask| s_handshake);

  // ============================================================================
  // sready 输出: 选中路且 d1 可收, 或该路 d0 为空
  // ============================================================================
  assign axis_sready = axis_sready_d0 | ~axis_svalid_d0;

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
      if (d0_handshake[arbiter_out]) begin
        // 有新数据进来且被选中, 抓取数据并拉高 valid
        axis_sdata_d1 <= axis_sdata_d0[arbiter_out*AXIS_WIDTH+:AXIS_WIDTH];
        axis_skeep_d1 <= axis_skeep_d0[arbiter_out*AXIS_WIDTH/8+:AXIS_WIDTH/8];
        axis_sid_d1 <= UPDATE_TID ?
                    {{UPDATE_TID_PAD{1'b0}}, arbiter_out} :
                    axis_sid_d0[arbiter_out*AXIS_ID_WIDTH+:AXIS_ID_WIDTH];
        axis_susr_d1 <= axis_susr_d0[arbiter_out*AXIS_USER_WIDTH+:AXIS_USER_WIDTH];
        axis_slast_d1 <= axis_slast_d0[arbiter_out];
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
  wire reg_can_take = !axis_mvalid_reg || axis_mready;
  wire skid_to_reg = skid_valid_reg && reg_can_take;
  wire d1_to_reg = d1_handshake && reg_can_take;
  wire d1_to_skid = d1_handshake && !reg_can_take;

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
  assign axis_mdata = axis_mdata_reg;
  assign axis_mkeep = axis_mkeep_reg;
  assign axis_mid = axis_mid_reg;
  assign axis_musr = axis_musr_reg;
  assign axis_mvalid = axis_mvalid_reg;
  assign axis_mlast = axis_mlast_reg;

  assign stat_active_port = arbiter_valid ? arbiter_out : 'd0;
  assign stat_idle = ~arbiter_valid && !axis_svalid_d1 && !axis_mvalid_reg && !skid_valid_reg;

  // ============================================================================
  // 仲裁器例化
  // ============================================================================
  arbiter #(
      .ARB_TYPE        (ARB_TYPE),   // 0=RR, 1=Strict Priority
      .ARB_SOUT_REG    (1),          // Strict Priority输出自带一拍延时
      .ARB_BLOCK       (1),          // 锁定结果 ARB_SOUT_REG 为0时失效
      .ARB_BLOCK_BY_ACK(1),          // 0 依靠Request 1依靠ACK
      .WIDTH           (NUM_PORTS),  // 输入位宽
      .LOW_FIRST       (1),          // 1: 从低位找第一个 1; 0: 从高位找
      .IDX_W           (IDX_W)
  ) u_arbiter (
      .rst(rst),
      .clk(clk),

      // --- 请求输入 ---
      .din(arbiter_din),

      // --- 授予输出 / 应答 ---
      .dout_onehot(arbiter_onehot),
      .index (arbiter_out),
      .valid(arbiter_valid),
      .ack  (arbiter_ack)
  );

endmodule
`resetall
