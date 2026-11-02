`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : icmpv4_echo_reply.v
// Module Name : icmpv4_echo_reply
// Author      : LiXintao
// Date        : 2026-10-10
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : ICMPV4 的ping包回复，支持任意ping包长度
// Note        : 
// ============================================================================
module icmpv4_echo_reply#(
  parameter AXIS_USER_WIDTH  = 4, // TX 侧仲裁值位宽
  parameter AXIS_RX_USER_WIDTH= 97 // RX 侧 usr 每通道位宽(来自 IPv4 层)
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [    AXIS_USER_WIDTH-1:0]       arbiter_val     ,

  input  wire          [                 511:0]        ipv4_axis_sdata,
  input  wire          [                  63:0]        ipv4_axis_skeep,
  input  wire                                          ipv4_axis_slast,
  input  wire                                          ipv4_axis_svalid,
  input  wire          [AXIS_RX_USER_WIDTH-1:0]        ipv4_axis_susr  ,
  output wire                                          ipv4_axis_sready,

  output wire          [                 511:0]        ipv4_axis_mdata,
  output wire          [                  63:0]        ipv4_axis_mkeep,
  output wire                                          ipv4_axis_mlast,
  output wire                                          ipv4_axis_mvalid,
  output wire          [    AXIS_USER_WIDTH-1:0]       ipv4_axis_musr  ,
  input  wire                                          ipv4_axis_mready,

  output wire                                          stat_drop_pulse ,
  output wire          [                   2:0]        stat_drop_reason // [0]TTL=0 [1]MAC错 [2]非echo(防御)
);
  // +0------7-------15---------------31
  // |  Type | Code  |    Checksum    |
  // +--------------------------------+
  // |   Identifier  | Sequence Number|
  // +--------------------------------+
  // |             Data               |
  // +--------------------------------+

  // +-----------------+-------+------------------------------------------------------------------------------------------------------------+
  // | 字段            | 长度  | 含义                                                                                                       |
  // |-----------------+-------+------------------------------------------------------------------------------------------------------------|
  // | Type            | 1字节 | 消息类型：                                                                                                 |
  // | 0：回显应答报文 |       |                                                                                                            |
  // | 8：请求回显报文 |       |                                                                                                            |
  // | Code            | 1字节 | 消息代码，此处值为0。                                                                                      |
  // | Checksum        | 2字节 | 检验和，使用和IP相同的加法校验和算法，但是ICMP校验和仅覆盖ICMP报文。                                       |
  // | Identifier      | 2字节 | 标识符，发送端标示此发送的报文。                                                                           |
  // | Sequence Number | 2字节 | 序列号，发送端发送的报文的顺序号。每发送一次顺序号就加1。                                                  |
  // | Data            | 可变  | 选项数据，是一个可变长的字段，其中包含要返回给发送者的数据。回显应答通常返回与所收到的数据完全相同的数据。 |
  // +-----------------+-------+------------------------------------------------------------------------------------------------------------+

  reg is_first_beat,is_first_beat_s1;
  reg          [                 511:0]        ipv4_axis_sdata_s1;
  reg          [                  63:0]        ipv4_axis_skeep_s1;
  reg                                          ipv4_axis_slast_s1;
  reg                                          ipv4_axis_svalid_s1;
  reg          [AXIS_RX_USER_WIDTH-1:0]        ipv4_axis_susr_s1;

  reg          [                 511:0]        ipv4_axis_sdata_s2;
  reg          [                  63:0]        ipv4_axis_skeep_s2;
  reg                                          ipv4_axis_slast_s2;
  reg                                          ipv4_axis_svalid_s2;
  reg          [AXIS_RX_USER_WIDTH-1:0]        ipv4_axis_susr_s2;

  reg          [                 511:0]        ipv4_axis_mdata_reg;
  reg          [                  63:0]        ipv4_axis_mkeep_reg;
  reg                                          ipv4_axis_mlast_reg;
  reg                                          ipv4_axis_mvalid_reg;
  reg          [    AXIS_USER_WIDTH-1:0]        ipv4_axis_musr_reg;

  reg          [                 511:0]        ipv4_axis_mdata_skid;
  reg          [                  63:0]        ipv4_axis_mkeep_skid;
  reg                                          ipv4_axis_mlast_skid;
  reg                                          ipv4_axis_mvalid_skid;
  reg          [    AXIS_USER_WIDTH-1:0]        ipv4_axis_musr_skid;

  // s1 计算是否为请求帧、ttl、源/目的ip、校验checksum
  // s2 给输出
  // s3 将输出给skid和reg

  wire s2_ready = !ipv4_axis_mvalid_skid;
  wire s1_ready = !ipv4_axis_svalid_s2 || s2_ready;
  assign ipv4_axis_sready = s1_ready || !ipv4_axis_svalid_s1;

  wire s_handshake = ipv4_axis_sready && ipv4_axis_svalid;
  wire s1_handshake = s1_ready && ipv4_axis_svalid_s1;
  wire s2_handshake = s2_ready && ipv4_axis_svalid_s2;
  wire m_handshake = ipv4_axis_mready && ipv4_axis_mvalid;

  wire reg_can_take = !ipv4_axis_mvalid_reg || ipv4_axis_mready;
  wire skid_to_reg = ipv4_axis_mvalid_skid && reg_can_take;
  wire s2_to_reg = s2_handshake && reg_can_take;
  wire s2_to_skid = s2_handshake && !reg_can_take;

  wire is_ttl_live = ipv4_axis_sdata[71:64] != 8'h00;
  reg is_ttl_live_s1;

  wire is_echo_req = ipv4_axis_sdata[175:160] == 16'h0008;
  reg is_echo_req_s1;

  wire [31:0] dst_ip = ipv4_axis_sdata[159:128];
  wire [31:0] src_ip = ipv4_axis_sdata[127:96];
  reg [31:0] dst_ip_s1;
  reg [31:0] src_ip_s1;

  wire [16:0] checksum_tmp = {1'b0,ipv4_axis_sdata[191:176]} + 17'h0008;
  reg [15:0] checksum_s1;

  wire is_frame_valid_s1 = ipv4_axis_susr_s1[0] == 1'b0; // 校验0bit需要为0，否则为错误帧

  reg is_drop_reg;

  reg stat_drop_pulse_reg;
  reg [2:0] stat_drop_reason_reg;

  // s1: valid
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_svalid_s1 <= 'b0;
    end
    else begin
      if (s_handshake) begin
        ipv4_axis_svalid_s1 <= 1'b1;
      end
      else if (s1_handshake) begin
        ipv4_axis_svalid_s1 <= 1'b0;
      end
    end
  end

  // s1: data keep last
  always @(posedge clk) begin
    if (s_handshake) begin
      ipv4_axis_sdata_s1 <= ipv4_axis_sdata;
      ipv4_axis_skeep_s1 <= ipv4_axis_skeep;
      ipv4_axis_slast_s1 <= ipv4_axis_slast;
      ipv4_axis_susr_s1  <= ipv4_axis_susr;
    end
  end

  // is_drop_reg
  always @(posedge clk) begin
    if (rst) begin
      is_drop_reg <= 'b0;
    end
    else begin
      if (s1_handshake && is_first_beat_s1 && is_ttl_live_s1 && is_echo_req_s1 && is_frame_valid_s1) begin
        is_drop_reg <= 1'b0;
      end
      else if(s1_handshake && is_first_beat_s1) begin
        is_drop_reg <= 1'b1;
      end
    end
  end

  // s2: valid
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_svalid_s2 <= 'b0;
    end
    else begin
      if (s1_handshake) begin
        if (is_first_beat_s1) begin
          ipv4_axis_svalid_s2 <= is_ttl_live_s1 && is_echo_req_s1 && is_frame_valid_s1;
        end
        else begin
          ipv4_axis_svalid_s2 <= ~is_drop_reg;
        end
      end
      else if (s2_handshake) begin
        ipv4_axis_svalid_s2 <= 1'b0;
      end
    end
  end

  // s2: data keep last
  always @(posedge clk) begin
    if (s1_handshake) begin
      if (is_first_beat_s1) begin
        ipv4_axis_sdata_s2 <= {ipv4_axis_sdata_s1[511:192],checksum_s1,16'h0000,src_ip_s1,dst_ip_s1,ipv4_axis_sdata_s1[95:0]};
      end
      else begin
        ipv4_axis_sdata_s2 <= ipv4_axis_sdata_s1;
      end
      ipv4_axis_skeep_s2 <= ipv4_axis_skeep_s1;
      ipv4_axis_slast_s2 <= ipv4_axis_slast_s1;
      ipv4_axis_susr_s2  <= arbiter_val;
    end
  end

  // reg skid: valid
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_mvalid_reg <= 'd0;
      ipv4_axis_mvalid_skid <= 'd0;
    end
    else begin
      if (s2_to_reg || skid_to_reg) begin
        ipv4_axis_mvalid_reg <= 1'b1;
      end
      else if (m_handshake) begin
        ipv4_axis_mvalid_reg <= 1'b0;
      end

      if (s2_to_skid) begin
        ipv4_axis_mvalid_skid <= 1'b1;
      end
      else if (skid_to_reg) begin
        ipv4_axis_mvalid_skid <= 1'b0;
      end
    end
  end

  // reg skid: data keep last
  always @(posedge clk) begin
    if (skid_to_reg) begin
      ipv4_axis_mdata_reg <= ipv4_axis_mdata_skid;
      ipv4_axis_mkeep_reg <= ipv4_axis_mkeep_skid;
      ipv4_axis_mlast_reg <= ipv4_axis_mlast_skid;
      ipv4_axis_musr_reg  <= ipv4_axis_musr_skid;
    end
    else if (s2_to_reg) begin
      ipv4_axis_mdata_reg <= ipv4_axis_sdata_s2;
      ipv4_axis_mkeep_reg <= ipv4_axis_skeep_s2;
      ipv4_axis_mlast_reg <= ipv4_axis_slast_s2;
      ipv4_axis_musr_reg  <= ipv4_axis_susr_s2;
    end

    if (s2_to_skid) begin
      ipv4_axis_mdata_skid <= ipv4_axis_sdata_s2;
      ipv4_axis_mkeep_skid <= ipv4_axis_skeep_s2;
      ipv4_axis_mlast_skid <= ipv4_axis_slast_s2;
      ipv4_axis_musr_skid  <= ipv4_axis_susr_s2;
    end
  end

  // is_ttl_live_s1
  always @(posedge clk) begin
    if (rst) begin
      is_ttl_live_s1 <= 'b0;
    end
    else begin
      if (s_handshake) begin
        is_ttl_live_s1 <= is_ttl_live;
      end
    end
  end

  // is_echo_req_s1
  always @(posedge clk) begin
    if (rst) begin
      is_echo_req_s1 <= 'b0;
    end
    else begin
      if (s_handshake) begin
        is_echo_req_s1 <= is_echo_req;
      end
    end
  end

  // dst_ip_s1 src_ip_s1
  always @(posedge clk) begin
    if (s_handshake) begin
      dst_ip_s1 <= dst_ip;
      src_ip_s1 <= src_ip;
    end
  end

  // checksum_s1
  always @(posedge clk) begin
    if (s_handshake) begin
      checksum_s1 <= checksum_tmp[16] + checksum_tmp[15:0];
    end
  end

  // is_first_beat
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;                                        // 复位后第一拍视为首拍
      is_first_beat_s1 <= 1'b0;
    end
    else begin
      if (s_handshake) begin
        is_first_beat <= ipv4_axis_slast;                           // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
        is_first_beat_s1 <= is_first_beat;
      end
    end
  end

  // stat_drop_pulse_reg
  always @(posedge clk) begin
    if (rst) begin
      stat_drop_pulse_reg <= 'd0;
      stat_drop_reason_reg <= 'd0;
    end
    else begin
      if (s1_handshake && is_first_beat_s1) begin
        stat_drop_pulse_reg <= ~(is_ttl_live_s1 && is_echo_req_s1 && is_frame_valid_s1);
      end
      else begin
        stat_drop_pulse_reg <= 1'b0;
      end
      // 原因码保持到下一次丢弃, 便于 ILA / 计数器观测
      if (s1_handshake && is_first_beat_s1 && ~(is_ttl_live_s1 && is_echo_req_s1 && is_frame_valid_s1)) begin
        stat_drop_reason_reg <= {~is_echo_req_s1,~is_frame_valid_s1,~is_ttl_live_s1};
      end
    end
  end

  assign ipv4_axis_mdata  = ipv4_axis_mdata_reg;
  assign ipv4_axis_mkeep  = ipv4_axis_mkeep_reg;
  assign ipv4_axis_mlast  = ipv4_axis_mlast_reg;
  assign ipv4_axis_mvalid = ipv4_axis_mvalid_reg;
  assign ipv4_axis_musr   = ipv4_axis_musr_reg;
  assign stat_drop_pulse = stat_drop_pulse_reg;
  assign stat_drop_reason = stat_drop_reason_reg;

endmodule
`resetall
