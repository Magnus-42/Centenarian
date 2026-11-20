// -----------------------------------------------------------------------------
// File Name   : cfg_cmd.v
// Module Name : cfg_cmd
// Author      : Codex
// Created     : 2026-11-19
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 接收本口UDP配置请求，统一发送读写与错误应答。
// Note        : 每个UDP载荷一条请求；应答单拍，背压期间保持不变。
//               如果修改的是本机的配置IP，则收不到应答帧
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

`include "cfg_protocol.vh"

module cfg_cmd #(
    parameter          [         7:0] ReplyTtl      = 8'd64,
    parameter  integer                ReqWidth      = 4,
    parameter          [ReqWidth-1:0] ReplyPriority = 4'd9,
    localparam integer                TxUsrWidth    = 104 + ReqWidth
) (
    input wire clk,
    input wire rst,

    input  wire [511:0] axis_sdata,
    input  wire [ 63:0] axis_skeep,
    input  wire [240:0] axis_susr,
    input  wire         axis_svalid,
    input  wire         axis_slast,
    output wire         axis_sready,

    output wire [         511:0] axis_mdata,
    output wire [          63:0] axis_mkeep,
    output wire [TxUsrWidth-1:0] axis_musr,
    output wire                  axis_mvalid,
    output wire                  axis_mlast,
    input  wire                  axis_mready,

    input wire [31:0] cfg_mgmt_ipv4_addr,
    input wire [15:0] cfg_mgmt_udp_port,

    output wire         exec_valid,
    output wire [  2:0] req_op,
    output wire [  7:0] req_item,
    output wire [  7:0] req_index,
    output wire [  7:0] req_len,
    output wire [127:0] req_value,
    input  wire [  7:0] rsp_status,
    input  wire [  7:0] rsp_len,
    input  wire [127:0] rsp_value
);

  // 接收单拍22字节请求，缓存命令与应答目的地址。
  // 解析命令并发起执行，等待配置寄存器处理。
  // 生成单拍23字节应答，握手完成后接收下一条请求。

  // 参数范围检查
  initial begin
    if (ReplyTtl == 8'd0 || ReplyPriority == 4'd0) begin
      $display("错误：cfg_cmd：应答TTL和优先级必须非零。");
      $finish;
    end
  end

  // 状态编码
  localparam integer StateWidth = 3;
  localparam [StateWidth-1:0] StateIdle = 3'd0;
  localparam [StateWidth-1:0] StateExecute = 3'd1;
  localparam [StateWidth-1:0] StateWait0 = 3'd2;
  localparam [StateWidth-1:0] StateWait1 = 3'd3;
  localparam [StateWidth-1:0] StateReply = 3'd4;

  // 接收usr字段位置
  localparam integer SrcIpLsb = 129;
  localparam integer SrcPortLsb = 209;

  // 状态机
  reg  [StateWidth-1:0] state;
  reg  [StateWidth-1:0] state_next;

  // 握手与请求格式判断
  wire                  s_handshake;
  wire                  m_handshake;
  wire                  is_cfg_frame;

  // 请求缓存
  reg  [         511:0] req_data_held;
  reg  [         240:0] req_usr_held;

  // 配置执行字段
  reg                   exec_valid_reg;
  reg  [           2:0] op_reg;
  reg  [           4:0] seq_reg;
  reg  [           7:0] item_reg;
  reg  [           7:0] index_reg;
  reg  [           7:0] len_reg;
  reg  [         127:0] value_reg;

  // 应答缓存
  reg  [         511:0] axis_mdata_reg;
  reg  [          63:0] axis_mkeep_reg;
  reg  [TxUsrWidth-1:0] axis_musr_reg;
  reg                   axis_mvalid_reg;
  reg                   axis_mlast_reg;

  // 应答目的地址
  wire [          31:0] dest_ip;
  wire [          15:0] dest_port;

  // 握手
  assign axis_sready = (state == StateIdle || (state == StateReply && m_handshake));
  assign s_handshake = axis_svalid && axis_sready;
  assign m_handshake = axis_mvalid && axis_mready;

  // 请求格式检查：单拍22字节，标识匹配。
  assign is_cfg_frame = (axis_sdata[15:0] == `CFG_PROTOCOL_STAMP) && axis_slast &&
      axis_skeep == {42'd0, {22{1'b1}}};

  // 状态机
  always @(posedge clk) begin
    if (rst) state <= StateIdle;
    else state <= state_next;
  end
  always @* begin
    state_next = state;
    case (state)
      StateIdle: begin
        if (s_handshake && is_cfg_frame) state_next = StateExecute;
      end
      StateExecute: state_next = StateWait0;
      StateWait0: state_next = StateWait1;
      StateWait1: state_next = StateReply;
      StateReply: begin
        if (m_handshake && s_handshake && is_cfg_frame) state_next = StateExecute;
        else if (m_handshake) state_next = StateIdle;
      end
      default: state_next = StateIdle;
    endcase
  end

  // 请求缓存
  always @(posedge clk) begin
    if (s_handshake) begin
      req_data_held <= axis_sdata;
      req_usr_held  <= axis_susr;
    end
  end

  // 解析输入命令
  always @(posedge clk) begin
    if (rst) begin
      exec_valid_reg <= 'd0;
    end else begin
      if (state == StateExecute) begin
        exec_valid_reg <= 1'b1;
        op_reg         <= req_data_held[18:16];
        seq_reg        <= req_data_held[23:19];
        item_reg       <= req_data_held[31:24];
        index_reg      <= req_data_held[39:32];
        len_reg        <= req_data_held[47:40];
        value_reg      <= req_data_held[48+:128];
      end else begin
        exec_valid_reg <= 'd0;
      end
    end
  end
  //// 执行请求
  assign exec_valid = exec_valid_reg;
  assign req_op     = op_reg;
  assign req_item   = item_reg;
  assign req_index  = index_reg;
  assign req_len    = len_reg;
  assign req_value  = value_reg;

  // 回复
  //// 应答目的地址提取
  assign dest_ip    = req_usr_held[SrcIpLsb+:32];
  assign dest_port  = req_usr_held[SrcPortLsb+:16];
  //// 应答数据与usr
  always @(posedge clk) begin
    if (state == StateReply && !axis_mvalid_reg) begin
      axis_mdata_reg <= {
        328'd0,
        rsp_value,
        rsp_len,
        index_reg,
        item_reg,
        rsp_status,
        seq_reg,
        `CFG_OP_RESPONSE,
        `CFG_PROTOCOL_STAMP
      };
      axis_mkeep_reg <= {41'd0, {23{1'b1}}};
      axis_musr_reg <= {
        dest_ip,
        cfg_mgmt_ipv4_addr,
        dest_port,
        cfg_mgmt_udp_port[7:0],
        cfg_mgmt_udp_port[15:8],
        ReplyTtl,
        ReplyPriority
      };
      axis_mlast_reg <= 1'b1;
    end
  end
  //// 应答有效位
  always @(posedge clk) begin
    if (rst) begin
      axis_mvalid_reg <= 'd0;
    end else begin
      if (state == StateReply && !axis_mvalid_reg) begin
        axis_mvalid_reg <= 1'b1;
      end else if (m_handshake) begin
        axis_mvalid_reg <= 'd0;
      end
    end
  end

  // 输出
  assign axis_mdata  = axis_mdata_reg;
  assign axis_mkeep  = axis_mkeep_reg;
  assign axis_musr   = axis_musr_reg;
  assign axis_mvalid = axis_mvalid_reg;
  assign axis_mlast  = axis_mlast_reg;
endmodule
`resetall
