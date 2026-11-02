`timescale 1ns/100ps
`include "cfg_map.vh"

// Language: Verilog 2001
// ============================================================================
// File Name   : tb_cfg_cmd_top.v
// Module Name : tb_cfg_cmd_top
// Author      : LiXintao
// Date        : 2026-10-27
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : cfg_cmd_top 端到端单元验证
//   方法: 构造命令帧(OP+SEQ+TLV)按 512b AXIS 送入 s_axis_cmd_*, 解析 m_axis_* 应答帧
//         (OP/SEQ/STATUS/ITEM/SET|PORT/LEN/VAL), 与期望严格比对; 并抽样核对 cfg_* 生效输出
//   用例:
//     T1  GET 默认 IPv4 IP   -> 0x82 OK + 默认值
//     T2  SET IPv4 IP         -> 0x81 OK + cfg_local_ip 生效
//     T3  GET 回读 IPv4 IP    -> 0x82 OK + 新值
//     T4  GET VERSION         -> 0x82 OK + 版本字
//     T5  SET PENDING_TIME    -> 0x81 OK + cfg_pending_time 生效
//     T6  非法 OP             -> 0x8F BAD_OP
//     T7  非法 ITEM           -> 0x8F BAD_ITEM
//     T8  非法 PORT           -> 0x8F BAD_PORT
//     T9  RESET_DEF 动作      -> 0x81 OK + 配置恢复默认
//     T10 port1 set0 IPv4 IP 的 SET/GET
//     T11 port1 set1 UDP 区间的 SET/GET
//     T12 port1 set0 eth_type 的 SET/GET
//     T13 RESET_DEF 覆盖全部端口/套
//     T14 GET 默认命令通道端口 0xC0DE
//     T15 port1 命令通道端口的 SET/GET
//     T16 port1 命令应答优先级的 SET/GET
//     T17 已删除的 0x62        -> 0x8F BAD_ITEM
//     T18 RESET_DEF 恢复命令通道默认
//     T19 未分配编号 0x56      -> 0x8F BAD_ITEM
//     T20 状态组边界 0x51/0x52/0x55 仍可读
//     T21 目的 IP 非本机       -> 整帧丢弃、无应答
//     T22 单帧多 TLV           -> 两条应答各自正确
//     T23 78B 多拍帧           -> usr 仅首拍有效仍正确解析（4 条应答）
//     T24 78B 多拍帧 + 目的 IP 不符 -> 整帧丢弃、跨 beat 保持
//     T25 135B 三拍帧         -> usr 仅首拍有效仍正确解析（7 条应答）
//     T26 135B 三拍帧 + 目的 IP 不符 -> 丢帧结论跨 3 拍保持（后续拍给合法 usr 也不放行）
//     T27 侧带无关字段脏值 + 四元组换值 -> 仍正确应答（抽取位段无错位）
//     T28 错误状态码全覆盖：BAD_SET(03) / BAD_LEN(05) / WRITE_ONLY(06) / READ_ONLY(07)
//     T29 配置边界 0x70 GEOMETRY / 0x71 GEOMETRY_MAX / 0x72 PORT_NUM
//     T30 IPv6 地址类 0x04/0x06/0x07 读写
//     T31 分流表 0x11/0x12 读写
//     T32 统计项 0x60/0x61
//     T33 clear 动作 0x41/0x42/0x43 各产生 1 拍脉冲
//     T34 剩余 ITEM：0x01 MAC / 0x02 GW / 0x03 MASK / 0x05 IPv6 SRC MAC /
//         0x31 ARP_PRIO / 0x32 ICMP_PRIO / 0x53 TX_IDLE / 0x54 TX_ACTIVE
//     T35 m_axis 反压下 3 条命令排队，放开后内容/顺序/侧带均正确
//   所有应答均校验 m_axis_udp_usr（四元组互换 + ttl=64 + prio=ITEM 0x34）
//   侧带约定: s_axis_cmd_usr / m_axis_udp_usr 均为标准 UDP 侧带
//             (RX 241b 由 mk_usr 组装 / TX 108b)，与 udp_ipv4_top 直接对接
//   注: 字节序 cfg 值小端; 应答字段序与请求一致 ({set,port} 在同一字节, set 高 4 位)
// ============================================================================
module tb_cfg_cmd_top;

  localparam W = 512;

  // ---------------------------------------------------------------- 时钟 / 复位
  reg clk = 1'b0;
  always #2.5 clk = ~clk;   // 200 MHz（功能仿真，频率不影响逻辑正确性）
  reg rst = 1'b1;

  // ---------------------------------------------------------------- DUT 连线
  wire [W-1:0]        s_cmd_data;
  wire [W/8-1:0]      s_cmd_keep;
  wire                s_cmd_last;
  wire                s_cmd_valid;
  wire                s_cmd_ready;
  reg  [240:0]        s_cmd_usr = 241'd0;  // 标准 UDP RX 侧带（mk_usr 由四元组组装）

  wire [W-1:0]        m_data;
  wire [W/8-1:0]      m_keep;
  wire                m_last;
  wire                m_valid;
  wire [107:0]        m_udp_usr;
  reg                 m_ready = 1'b1;
  reg                 bp_hold = 1'b0;   // 1 = 反压（m_ready 拉低），时钟同步避免采样错拍
  always @(posedge clk) begin
    if (rst) m_ready <= 1'b1;
    else     m_ready <= ~bp_hold;
  end

  // 命令通道路由：设备本机 IP(请求目的 / 应答源) / 测试仪 IP·端口(请求源 / 应答目的)
  localparam [15:0] P_CMD_PORT  = 16'hC0DE;
  reg [31:0] tb_lcl_ip   = 32'h0901_A8C0;   // 192.168.1.9 = 口0 set0 默认本机 IP
  reg [31:0] tb_peer_ip  = 32'h0A01_A8C0;   // 192.168.1.10 测试仪
  reg [15:0] tb_peer_port= 16'h1234;

  // cfg 生效输出（宽度由 cfg_map.vh 推导，避免手写常量与参数脱节）
  localparam P_NUM   = `CFG_NUM_PORT;
  localparam P_NW    = `CFG_COUNT_WIDTH;
  localparam P_V4N   = `CFG_MAX_V4_SET_NUM;
  localparam P_V6SN  = `CFG_MAX_V6_SRC_SET_NUM;
  localparam P_V6DN  = `CFG_MAX_V6_DST_SET_NUM;
  localparam P_ETHN  = `CFG_MAX_MAC_RX_NUM;
  localparam P_V4PN  = `CFG_MAX_IPV4_RX_NUM;
  localparam P_V6NHN = `CFG_MAX_IPV6_RX_NUM;
  localparam P_UDPN  = `CFG_MAX_UDP_RX_NUM;
  localparam P_PTW   = `CFG_MAX_PENDING_TIME_WIDTH;
  localparam P_AVW   = `CFG_MAX_ARBITER_VAL_WIDTH;
  // cfg_cmd_udp_prio 已不再引出端口；应答 prio 取 CMD_PORT_SEL(=0) 口的值，
  // 全用例只改 port1 的 0x34，故 port0 恒为默认 9
  localparam [P_AVW-1:0] EXP_RSP_PRIO = 9;
  localparam P_TXW   = $clog2(`CFG_MAX_MAC_TX_NUM + 3);   // TX_IDX_WIDTH，与 cfg_reg_bank 一致

  // 口1 的字段偏移（索引 = port*每口套数 + set）
  localparam P_IP1_OFF   = P_V4N * 32;          // 口1 set0 IPv4 IP
  localparam P_ETH1_OFF  = P_ETHN * 16;         // 口1 set0 eth_type
  localparam P_UDP11_OFF = (P_UDPN + 1) * 32;   // 口1 set1 UDP 区间

  // 宏不能直接做位选（VRFC 10-4982），先整体接收再切片
  localparam [P_NW*P_NUM-1:0] A_UDP_RX = `CFG_DEF_UDP_RX_NUM_ARR;
  localparam [P_NW*P_NUM-1:0] A_V6RX   = `CFG_DEF_IPV6_RX_NUM_ARR;
  localparam [P_NW*P_NUM-1:0] A_V4RX   = `CFG_DEF_IPV4_RX_NUM_ARR;
  localparam [P_NW*P_NUM-1:0] A_MACRX  = `CFG_DEF_MAC_RX_NUM_ARR;
  localparam [P_NW*P_NUM-1:0] A_V6D    = `CFG_DEF_V6_DST_NUM_ARR;
  localparam [P_NW*P_NUM-1:0] A_V6S    = `CFG_DEF_V6_SRC_NUM_ARR;
  localparam [P_NW*P_NUM-1:0] A_V4     = `CFG_DEF_V4_SET_NUM_ARR;
  localparam [P_NW*P_NUM-1:0] A_PT     = `CFG_DEF_PT_WIDTH_ARR;
  localparam [P_NW*P_NUM-1:0] A_ARB    = `CFG_DEF_ARB_VAL_WIDTH_ARR;

  localparam [P_NW-1:0] G_UDP_RX0 = A_UDP_RX[0+:P_NW];
  localparam [P_NW-1:0] G_V6RX0   = A_V6RX  [0+:P_NW];
  localparam [P_NW-1:0] G_V4RX0   = A_V4RX  [0+:P_NW];
  localparam [P_NW-1:0] G_MACRX0  = A_MACRX [0+:P_NW];
  localparam [P_NW-1:0] G_V6D0    = A_V6D   [0+:P_NW];
  localparam [P_NW-1:0] G_V6S0    = A_V6S   [0+:P_NW];
  localparam [P_NW-1:0] G_V40     = A_V4    [0+:P_NW];
  localparam [P_NW-1:0] G_PT0     = A_PT    [0+:P_NW];
  localparam [P_NW-1:0] G_ARB0    = A_ARB   [0+:P_NW];

  localparam [255:0] A_V6S_DEF = `CFG_DEF_IPV6_SRC_P0;   // {set1, set0}
  localparam [255:0] A_V6D_DEF = `CFG_DEF_IPV6_DST_P0;
  localparam [ 95:0] A_V6S_MAC = `CFG_DEF_IPV6_SRC_MAC_P0;
  localparam [ 95:0] A_V6D_MAC = `CFG_DEF_IPV6_DST_MAC_P0;
  localparam [127:0] G_V6S0_IP  = A_V6S_DEF[0+:128];
  localparam [127:0] G_V6D0_IP  = A_V6D_DEF[0+:128];
  localparam [ 47:0] G_V6S0_MAC = A_V6S_MAC[0+:48];
  localparam [ 47:0] G_V6D0_MAC = A_V6D_MAC[0+:48];
  // 分流表默认值（口0 槽0）
  localparam [207:0] A_V4P_DICT = `CFG_DEF_IPV4_RX_DICT_ARR;   // 6 口·槽
  localparam [ 47:0] A_V6NH_DICT= `CFG_DEF_IPV6_RX_DICT_ARR;
  localparam [  7:0] G_V4P0     = A_V4P_DICT [0+:8];
  localparam [  7:0] G_V6NH0    = A_V6NH_DICT[0+:8];

  wire [48 *P_V4N *P_NUM-1:0]  cfg_local_mac;
  wire [32 *P_V4N *P_NUM-1:0]  cfg_local_ip;
  wire [32 *P_V4N *P_NUM-1:0]  cfg_gateway_ip;
  wire [32 *P_V4N *P_NUM-1:0]  cfg_subnet_mask;
  wire [128*P_V6SN*P_NUM-1:0]  cfg_src_ipv6;
  wire [48 *P_V6SN*P_NUM-1:0]  cfg_src_mac;
  wire [128*P_V6DN*P_NUM-1:0]  cfg_dst_ipv6;
  wire [48 *P_V6DN*P_NUM-1:0]  cfg_dst_mac;
  wire [16 *P_ETHN*P_NUM-1:0]  cfg_eth_type;
  wire [8  *P_V4PN*P_NUM-1:0]  cfg_ipv4_proto;
  wire [47:0]  cfg_ipv6_nh;
  wire [191:0] cfg_udp_port;
  wire [P_PTW*P_NUM-1:0] cfg_pending_time;
  wire [P_AVW*P_NUM-1:0] cfg_arp_prio;
  wire [P_AVW*P_NUM-1:0] cfg_icmp_prio;
  wire [1:0]   cfg_arp_cache_clear;
  wire [1:0]   cfg_arp_pending_clear;
  wire [1:0]   cfg_stat_clear;

  // 只读状态输入
  reg [1:0]   stat_link_status = 2'b11;
  reg [1:0]   stat_tx_idle     = 2'b00;
  reg [P_TXW*P_NUM-1:0] stat_tx_active = 'd0;
  reg [1:0]   stat_is_df       = 2'b11;
  reg [13:0]  stat_arp         = 14'd0;
  reg [7:0]   stat_icmp        = 8'd0;

  // 命令通道配置输出
  wire [16*P_NUM-1:0]  cfg_cmd_udp_port;

  cfg_cmd_top u_dut (
    .clk(clk), .rst(rst),
    .s_axis_cmd_data(s_cmd_data), .s_axis_cmd_keep(s_cmd_keep),
    .s_axis_cmd_last(s_cmd_last), .s_axis_cmd_valid(s_cmd_valid), .s_axis_cmd_ready(s_cmd_ready),
    .s_axis_cmd_usr(s_cmd_usr),
    .m_axis_data(m_data), .m_axis_keep(m_keep),
    .m_axis_last(m_last), .m_axis_valid(m_valid), .m_axis_ready(m_ready),
    .m_axis_udp_usr(m_udp_usr),
    .cfg_local_mac(cfg_local_mac), .cfg_local_ip(cfg_local_ip),
    .cfg_gateway_ip(cfg_gateway_ip), .cfg_subnet_mask(cfg_subnet_mask),
    .cfg_src_ipv6(cfg_src_ipv6), .cfg_src_mac(cfg_src_mac),
    .cfg_dst_ipv6(cfg_dst_ipv6), .cfg_dst_mac(cfg_dst_mac),
    .cfg_eth_type(cfg_eth_type), .cfg_ipv4_proto(cfg_ipv4_proto),
    .cfg_ipv6_nh(cfg_ipv6_nh), .cfg_udp_port(cfg_udp_port),
    .cfg_pending_time(cfg_pending_time), .cfg_arp_prio(cfg_arp_prio), .cfg_icmp_prio(cfg_icmp_prio),
    .cfg_cmd_udp_port(cfg_cmd_udp_port),
    .cfg_arp_cache_clear(cfg_arp_cache_clear), .cfg_arp_pending_clear(cfg_arp_pending_clear),
    .cfg_stat_clear(cfg_stat_clear),
    .stat_link_status(stat_link_status), .stat_tx_idle(stat_tx_idle), .stat_tx_active(stat_tx_active),
    .stat_is_df(stat_is_df), .stat_arp(stat_arp), .stat_icmp(stat_icmp)
  );

  // ---------------------------------------------------------------- CALLBACK_MSG=0 支路
  // 该分支不产生应答，但 rec_ready 必须仍为 1，否则 cfg_demux 会永远卡在 S_REG_TO_SET
  wire set_nocb_ready;
  cfg_set #(.CALLBACK_MSG(0), .MAX_VALUE_BYTES(16), .CMD_USR_WIDTH(96)) u_set_nocb (
    .clk(clk), .rst(rst),
    .rec_valid(1'b0), .rec_ready(set_nocb_ready),
    .rec_op(8'd0), .rec_seq(8'd0), .rec_item(8'd0), .rec_set(4'd0), .rec_port(4'd0),
    .rec_len(8'd0), .rec_val(128'd0), .rec_usr(96'd0),
    .wr_en(), .wr_item(), .wr_set(), .wr_port(), .wr_val(),
    .callback_axis_mdata(), .callback_axis_mkeep(), .callback_axis_mlast(),
    .callback_axis_mvalid(), .callback_axis_mready(1'b1), .callback_axis_musr()
  );

  // ---------------------------------------------------------------- 命令帧激励
  reg [W-1:0] cmd_data = 'd0;
  reg [W/8-1:0] cmd_keep = 'd0;
  reg           cmd_valid = 1'b0;
  reg           cmd_last  = 1'b0;
  reg [240:0]   dirty_usr = 241'd0;   // T27 用：无关字段带脏值的标准侧带
  assign s_cmd_data  = cmd_data;
  assign s_cmd_keep  = cmd_keep;
  assign s_cmd_valid = cmd_valid;
  assign s_cmd_last  = cmd_last;

  // ---------------------------------------------------------------- 侧带组装
  // 把内部四元组 tuple = {dst_port, dst_ip, src_port, src_ip}(96b) 组装成
  // 标准 UDP RX 侧带(241b)，位段与 udp_ipv4_top.udp_axis_musr 一致：
  //   src_ip[160:129] dst_ip[192:161] dst_port[208:193] src_port[224:209]
  // 其余字段（MAC/err/proto/len/ttl）填固定合理值
  function [240:0] mk_usr;
    input [95:0] t;
    begin
      mk_usr              = 241'd0;
      mk_usr[47:0]        = 48'h0019_3100_0002;   // src_mac
      mk_usr[95:48]       = 48'h0019_3100_0001;   // dst_mac
      mk_usr[96]          = 1'b0;                 // err
      mk_usr[104:97]      = 8'd17;                // proto = UDP
      mk_usr[120:105]     = 16'd64;               // total_len
      mk_usr[128:121]     = 8'd64;                // ttl
      mk_usr[160:129]     = t[31:0];              // src_ip
      mk_usr[192:161]     = t[79:48];             // dst_ip
      mk_usr[208:193]     = t[95:80];             // dst_port
      mk_usr[224:209]     = t[47:32];             // src_port
      mk_usr[240:225]     = 16'd20;               // udp_len
    end
  endfunction

  // 发送单拍命令帧（单 TLV）
  task automatic send_cmd;
    input [7:0]   op;
    input [7:0]   seq;
    input [7:0]   item;
    input [3:0]   set;
    input [3:0]   port;
    input [7:0]   len;
    input [127:0] val;
    integer i;
    begin
      cmd_data = 'd0;
      cmd_data[7:0]    = op;
      cmd_data[15:8]   = seq;
      cmd_data[23:16]  = item;
      cmd_data[27:24]  = port;                 // TAG 高字节低 4 位 = port
      cmd_data[31:28]  = set;                  // TAG 高字节高 4 位 = set
      cmd_data[39:32]  = len;
      cmd_data[40 +: 128] = val;               // VAL 小端, 首字节在最低位(固定 128b 宽)
      cmd_keep = (64'd1 << (5+len)) - 64'd1;   // 有效字节数 = 5 + len
      s_cmd_usr = mk_usr({P_CMD_PORT, tb_lcl_ip, tb_peer_port, tb_peer_ip});
      cmd_valid = 1'b1;
      cmd_last  = 1'b1;
      @(posedge clk);
      i = 0;
      while (!(s_cmd_valid && s_cmd_ready) && i < 1000) begin
        @(posedge clk); i = i + 1;
      end
      cmd_valid = 1'b0;
      cmd_last  = 1'b0;
      @(posedge clk);
    end
  endtask

  // 发送单拍命令帧（单 TLV），可指定目的 IP —— 用于准入控制用例
  task automatic send_cmd_to;
    input [7:0]   op;
    input [7:0]   seq;
    input [7:0]   item;
    input [3:0]   set;
    input [3:0]   port;
    input [7:0]   len;
    input [127:0] val;
    input [31:0]  dst_ip;
    integer i;
    begin
      cmd_data = 'd0;
      cmd_data[7:0]    = op;
      cmd_data[15:8]   = seq;
      cmd_data[23:16]  = item;
      cmd_data[27:24]  = port;
      cmd_data[31:28]  = set;
      cmd_data[39:32]  = len;
      cmd_data[40 +: 128] = val;
      cmd_keep = (64'd1 << (5+len)) - 64'd1;
      s_cmd_usr = mk_usr({P_CMD_PORT, dst_ip, tb_peer_port, tb_peer_ip});
      cmd_valid = 1'b1;
      cmd_last  = 1'b1;
      @(posedge clk);
      i = 0;
      while (!(s_cmd_valid && s_cmd_ready) && i < 1000) begin
        @(posedge clk); i = i + 1;
      end
      cmd_valid = 1'b0;
      cmd_last  = 1'b0;
      @(posedge clk);
    end
  endtask

  // 发送单拍命令帧（两条 LEN=0 的 TLV：VERSION + LINK_STATUS）
  //   验证多 TLV 场景下每条应答的侧带都能正确对应
  task automatic send_cmd2;
    input [7:0] op;
    input [7:0] seq;
    integer i;
    begin
      cmd_data = 'd0;
      // 协议：每根 TLV 都是 OP(1) SEQ(1) TAG(2) LEN(1) VAL
      // TLV1: OP + SEQ + ITEM=0x51(VERSION) + TAG{set,port}=0 + LEN=0
      cmd_data[7:0]   = op;
      cmd_data[15:8]  = seq;
      cmd_data[23:16] = 8'h51;
      cmd_data[31:24] = 8'h00;
      cmd_data[39:32] = 8'd0;
      // TLV2: OP + SEQ + ITEM=0x52(LINK_STATUS) + TAG{set,port}=0 + LEN=0
      cmd_data[47:40] = op;
      cmd_data[55:48] = seq;
      cmd_data[63:56] = 8'h52;
      cmd_data[71:64] = 8'h00;
      cmd_data[79:72] = 8'd0;
      cmd_keep = 64'h0000_0000_0000_03FF;
      s_cmd_usr = mk_usr({P_CMD_PORT, tb_lcl_ip, tb_peer_port, tb_peer_ip});
      cmd_valid = 1'b1;
      cmd_last  = 1'b1;
      @(posedge clk);
      i = 0;
      while (!(s_cmd_valid && s_cmd_ready) && i < 1000) begin
        @(posedge clk); i = i + 1;
      end
      cmd_valid = 1'b0;
      cmd_last  = 1'b0;
      @(posedge clk);
    end
  endtask

  // 发送单拍 AXIS（用于拼多拍帧；注意 usr 只在第一拍给有效值）
  task automatic send_beat;
    input [W-1:0]    d;
    input [W/8-1:0]  k;
    input            lst;
    input [240:0]    u;   // 标准 UDP RX 侧带（用 mk_usr 由四元组组装）
    integer t;
    begin
      cmd_data  = d;
      cmd_keep  = k;
      cmd_last  = lst;
      s_cmd_usr = u;
      cmd_valid = 1'b1;
      @(posedge clk);
      t = 0;
      while (!(s_cmd_valid && s_cmd_ready) && t < 2000) begin
        @(posedge clk); t = t + 1;
      end
      cmd_valid = 1'b0;
      cmd_last  = 1'b0;
      @(posedge clk);
    end
  endtask

  // 构造命令帧：ntlv 条 {OP, SEQ, ITEM=0x51, TAG=0, LEN=16, VAL=16B}
  //   协议要求每根 TLV 都带 OP+SEQ，故单根 21B
  //   帧长 = ntlv*21；512b = 64B ⇒ 帧长 >64 就跨多个 AXIS beat
  //     ntlv=4 → 84B  → 2 拍（64 + 20）
  //     ntlv=7 → 147B → 3 拍（64 + 64 + 19）
  reg [2047:0] lf;
  task automatic build_frame;
    input [7:0]   op;
    input [7:0]   seq;
    input integer ntlv;
    integer n, b;
    begin
      lf = {2048{1'b0}};
      for (n = 0; n < ntlv; n = n + 1) begin
        b = n*21;
        lf[ b     *8 +: 8] = op;      // OP
        lf[(b+1)  *8 +: 8] = seq;     // SEQ
        lf[(b+2)  *8 +: 8] = 8'h51;   // ITEM = VERSION
        lf[(b+3)  *8 +: 8] = 8'h00;   // TAG 高字节 = {SET,PORT} = 0
        lf[(b+4)  *8 +: 8] = 8'd16;   // LEN = 16（GET 时值被忽略）
        // VAL 16B 保持 0
      end
    end
  endtask

  // ---------------------------------------------------------------- 应答统计
  // 多拍帧用例的 4 条应答内容完全相同，逐条核对意义有限；
  // 改用计数器统计"应答条数 + 每条 usr 是否正确"，更直观也更严格。
  reg     clear_rsp = 1'b0;
  integer rsp_cnt   = 0;
  integer rsp_usr_err = 0;

  always @(posedge clk) begin
    if (rst || clear_rsp) begin
      rsp_cnt     <= 0;
      rsp_usr_err <= 0;
    end
    else if (m_valid && m_ready) begin
      rsp_cnt <= rsp_cnt + 1;
      if (m_udp_usr[75:44]  !== tb_lcl_ip   || m_udp_usr[107:76] !== tb_peer_ip ||
          m_udp_usr[27:12]  !== P_CMD_PORT  || m_udp_usr[43:28]  !== tb_peer_port ||
          m_udp_usr[11:4]   !== 8'd64)
        rsp_usr_err <= rsp_usr_err + 1;
    end
  end

  task automatic clear_stat;
    begin
      clear_rsp = 1'b1;
      @(posedge clk);
      clear_rsp = 1'b0;
      @(posedge clk);
    end
  endtask

  // ---------------------------------------------------------------- clear 脉冲监视（T33）
  // 只统计 port0：三个动作各应产生恰好 1 拍脉冲
  reg        clr_clr  = 1'b0;
  reg [2:0]  clr_seen = 3'b000;
  integer    clr_cnt  = 0;

  always @(posedge clk) begin
    if (clr_clr) begin
      clr_seen <= 3'b000;
      clr_cnt  <= 0;
    end
    else begin
      if (cfg_arp_cache_clear[0])   clr_seen[0] <= 1'b1;
      if (cfg_arp_pending_clear[0]) clr_seen[1] <= 1'b1;
      if (cfg_stat_clear[0])        clr_seen[2] <= 1'b1;
      if (cfg_arp_cache_clear[0] || cfg_arp_pending_clear[0] || cfg_stat_clear[0])
        clr_cnt <= clr_cnt + 1;
    end
  end

  task automatic clr_clear;
    begin
      clr_clr = 1'b1;
      @(posedge clk);
      clr_clr = 1'b0;
      @(posedge clk);
    end
  endtask

  // ---------------------------------------------------------------- 应答内容快照（T35）
  // 反压放开那拍 check_rsp 的采样点会错拍，改用计数器逐条记录
  reg [7:0] cap_seq  [0:7];
  reg [7:0] cap_item [0:7];
  integer   cap_n = 0;
  reg       cap_clr = 1'b0;

  always @(posedge clk) begin
    if (rst || cap_clr) cap_n <= 0;
    else if (m_valid && m_ready && cap_n < 8) begin
      cap_seq [cap_n] <= m_data[15:8];
      cap_item[cap_n] <= m_data[31:24];
      cap_n <= cap_n + 1;
    end
  end

  task automatic cap_clear;
    begin
      cap_clr = 1'b1;
      @(posedge clk);
      cap_clr = 1'b0;
      @(posedge clk);
    end
  endtask

  integer err_total;

  task automatic cyc(input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
  endtask

  // ---------------------------------------------------------------- 应答采样
  // 直接采样 m_axis（不经寄存器中转，避免 rsp_valid 标志的 NBA 时序错位）
  task automatic check_rsp;
    input [7:0] e_op, e_seq, e_status, e_item;
    input [3:0] e_set, e_port;
    input [7:0] e_len;
    input [127:0] e_val;
    integer t;
    begin
      t = 0;
      while (!(m_valid && m_ready) && t < 2000) begin @(posedge clk); t = t + 1; end
      if (t >= 2000) begin
        $display("  [FAIL] 应答超时 (期望 op=%h item=%h)", e_op, e_item);
        err_total = err_total + 1;
      end
      else if (m_data[7:0] !== e_op || m_data[15:8] !== e_seq || m_data[23:16] !== e_status ||
               m_data[31:24] !== e_item || m_data[39:36] !== e_set || m_data[35:32] !== e_port ||
               m_data[47:40] !== e_len || m_data[175:48] !== e_val) begin
        $display("  [FAIL] 应答不符: op=%h(exp %h) seq=%h(%h) st=%h(%h) item=%h(%h) set=%h(%h) port=%h(%h) len=%h(%h) val=%h(%h)",
          m_data[7:0], e_op, m_data[15:8], e_seq, m_data[23:16], e_status, m_data[31:24], e_item,
          m_data[39:36], e_set, m_data[35:32], e_port, m_data[47:40], e_len, m_data[175:48], e_val);
        err_total = err_total + 1;
      end
      // 应答 UDP 元数据：四元组互换 + ttl/prio 固定
      else if (m_udp_usr[107:76] !== tb_peer_ip  || m_udp_usr[75:44] !== tb_lcl_ip ||
               m_udp_usr[43:28] !== tb_peer_port || m_udp_usr[27:12] !== P_CMD_PORT ||
               m_udp_usr[11:4]  !== 8'd64         || m_udp_usr[3:0]   !== EXP_RSP_PRIO) begin
        $display("  [FAIL] 应答 udp_usr 不符: dst=%h(exp %h) src=%h(exp %h) dport=%h(exp %h) sport=%h(exp %h) ttl=%h(exp 40) prio=%h(exp %h)",
          m_udp_usr[107:76], tb_peer_ip, m_udp_usr[75:44], tb_lcl_ip,
          m_udp_usr[43:28],  tb_peer_port, m_udp_usr[27:12], P_CMD_PORT,
          m_udp_usr[11:4],   m_udp_usr[3:0], EXP_RSP_PRIO);
        err_total = err_total + 1;
      end
      else begin
        $display("  [PASS] 应答一致 op=%h st=%h item=%h val=%h usr_ok", m_data[7:0], m_data[23:16], m_data[31:24], m_data[175:48]);
      end
      @(posedge clk);   // 让本次握手完成（m_ready 恒 1，m_valid 下一拍清零）
    end
  endtask

  // ---------------------------------------------------------------- 主激励
  // 默认 set0 IP = 192.168.1.9 -> cfg 值小端 0x0901A8C0
  localparam [31:0] DEF_IP0 = 32'h0901_A8C0;
  localparam [31:0] NEW_IP0 = 32'h6401_A8C0;   // 192.168.1.100
  localparam [31:0] VERSION = 32'h0001_0100;

  initial begin
    err_total = 0;
    rst = 1'b1;
    cyc(10);
    rst = 1'b0;
    cyc(5);

    // ---------------- T0 CALLBACK_MSG=0 支路必须可用 ----------------
    $display("--- T0: cfg_set CALLBACK_MSG=0 时 rec_ready 必须为 1 ---");
    if (set_nocb_ready !== 1'b1) begin
      $display("  [FAIL] rec_ready = %b，cfg_demux 会卡死在 S_REG_TO_SET（死锁）", set_nocb_ready);
      err_total = err_total + 1;
    end else $display("  [PASS] rec_ready = 1'b1（不回写应答时仍能接收命令）");

    // ---------------- T1 GET 默认 IPv4 IP ----------------
    $display("--- T1: GET 默认 IPv4 IP (port0 set0) ---");
    send_cmd(8'h02, 8'h01, 8'h00, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h01, 8'h00, 8'h00, 4'd0, 4'd0, 8'd4, {96'd0, DEF_IP0});

    // ---------------- T2 SET IPv4 IP ----------------
    $display("--- T2: SET IPv4 IP (port0 set0 -> 192.168.1.100) ---");
    send_cmd(8'h01, 8'h02, 8'h00, 4'd0, 4'd0, 8'd4, {96'd0, NEW_IP0});
    check_rsp(8'h81, 8'h02, 8'h00, 8'h00, 4'd0, 4'd0, 8'd4, 128'd0);
    if (cfg_local_ip[31:0] !== NEW_IP0) begin
      $display("  [FAIL] cfg_local_ip[31:0]=%h exp %h", cfg_local_ip[31:0], NEW_IP0);
      err_total = err_total + 1;
    end else $display("  [PASS] cfg_local_ip 已生效 = %h", cfg_local_ip[31:0]);

    // 白名单跟随本机 IP：后续命令必须打到新地址
    tb_lcl_ip = NEW_IP0;

    // ---------------- T3 GET 回读 ----------------
    $display("--- T3: GET 回读 IPv4 IP ---");
    send_cmd(8'h02, 8'h03, 8'h00, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h03, 8'h00, 8'h00, 4'd0, 4'd0, 8'd4, {96'd0, NEW_IP0});

    // ---------------- T4 GET VERSION ----------------
    $display("--- T4: GET VERSION ---");
    send_cmd(8'h02, 8'h04, 8'h51, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h04, 8'h00, 8'h51, 4'd0, 4'd0, 8'd4, {96'd0, VERSION});

    // ---------------- T5 SET PENDING_TIME ----------------
    $display("--- T5: SET PENDING_TIME (port0 = 100_000_000) ---");
    send_cmd(8'h01, 8'h05, 8'h30, 4'd0, 4'd0, 8'd8, {64'd0, 57'd100_000_000});
    check_rsp(8'h81, 8'h05, 8'h00, 8'h30, 4'd0, 4'd0, 8'd8, 128'd0);
    if (cfg_pending_time[56:0] !== 57'd100_000_000) begin
      $display("  [FAIL] cfg_pending_time[56:0]=%h exp %h", cfg_pending_time[56:0], 57'd100_000_000);
      err_total = err_total + 1;
    end else $display("  [PASS] cfg_pending_time 已生效 = %h", cfg_pending_time[56:0]);

    // ---------------- T6 非法 OP ----------------
    $display("--- T6: 非法 OP (0x05) ---");
    send_cmd(8'h05, 8'h06, 8'h00, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h8F, 8'h06, 8'h01, 8'h00, 4'd0, 4'd0, 8'd0, 128'd0);

    // ---------------- T7 非法 ITEM ----------------
    $display("--- T7: 非法 ITEM (0x20) ---");
    send_cmd(8'h02, 8'h07, 8'h20, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h8F, 8'h07, 8'h02, 8'h20, 4'd0, 4'd0, 8'd0, 128'd0);

    // ---------------- T8 非法 PORT ----------------
    $display("--- T8: 非法 PORT (0xE) ---");
    send_cmd(8'h02, 8'h08, 8'h00, 4'd0, 4'hE, 8'd0, 128'd0);
    check_rsp(8'h8F, 8'h08, 8'h04, 8'h00, 4'd0, 4'hE, 8'd0, 128'd0);

    // ---------------- T9 RESET_DEF 动作 ----------------
    $display("--- T9: RESET_DEF 动作 ---");
    send_cmd(8'h01, 8'h09, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h81, 8'h09, 8'h00, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);
    if (cfg_local_ip[31:0] !== DEF_IP0) begin
      $display("  [FAIL] RESET_DEF 后 cfg_local_ip[31:0]=%h exp %h", cfg_local_ip[31:0], DEF_IP0);
      err_total = err_total + 1;
    end else $display("  [PASS] RESET_DEF 后 cfg_local_ip 恢复默认 = %h", cfg_local_ip[31:0]);

    tb_lcl_ip = DEF_IP0;

    // ---------------- T10 SET/GET 端口1 地址类（索引 = port*套数 + set） ----------------
    $display("--- T10: SET/GET IPv4 IP port1 set0 ---");
    send_cmd(8'h01, 8'h0A, 8'h00, 4'd0, 4'd1, 8'd4, {96'd0, 32'h6501_A8C0});
    check_rsp(8'h81, 8'h0A, 8'h00, 8'h00, 4'd0, 4'd1, 8'd4, 128'd0);
    if (cfg_local_ip[P_IP1_OFF +: 32] !== 32'h6501_A8C0) begin
      $display("  [FAIL] port1 IP=%h exp 6501a8c0", cfg_local_ip[P_IP1_OFF +: 32]);
      err_total = err_total + 1;
    end else $display("  [PASS] port1 IP 已生效 = %h", cfg_local_ip[P_IP1_OFF +: 32]);

    send_cmd(8'h02, 8'h0B, 8'h00, 4'd0, 4'd1, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h0B, 8'h00, 8'h00, 4'd0, 4'd1, 8'd4, {96'd0, 32'h6501_A8C0});

    // ---------------- T11 SET/GET 端口1 set1 分流表 ----------------
    $display("--- T11: SET/GET UDP_PORT_RANGE port1 set1 ---");
    send_cmd(8'h01, 8'h0C, 8'h13, 4'd1, 4'd1, 8'd4, {96'd0, 32'hDEAD_0011});
    check_rsp(8'h81, 8'h0C, 8'h00, 8'h13, 4'd1, 4'd1, 8'd4, 128'd0);
    if (cfg_udp_port[P_UDP11_OFF +: 32] !== 32'hDEAD_0011) begin
      $display("  [FAIL] port1.set1 udp=%h exp dead0011", cfg_udp_port[P_UDP11_OFF +: 32]);
      err_total = err_total + 1;
    end else $display("  [PASS] port1.set1 udp 已生效 = %h", cfg_udp_port[P_UDP11_OFF +: 32]);

    send_cmd(8'h02, 8'h0D, 8'h13, 4'd1, 4'd1, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h0D, 8'h00, 8'h13, 4'd1, 4'd1, 8'd4, {96'd0, 32'hDEAD_0011});

    // ---------------- T12 SET/GET 端口1 eth_type ----------------
    $display("--- T12: SET/GET ETH_TYPE port1 set0 ---");
    send_cmd(8'h01, 8'h0E, 8'h10, 4'd0, 4'd1, 8'd2, {112'd0, 16'hB588});
    check_rsp(8'h81, 8'h0E, 8'h00, 8'h10, 4'd0, 4'd1, 8'd2, 128'd0);
    if (cfg_eth_type[P_ETH1_OFF +: 16] !== 16'hB588) begin
      $display("  [FAIL] port1 eth_type=%h exp b588", cfg_eth_type[P_ETH1_OFF +: 16]);
      err_total = err_total + 1;
    end else $display("  [PASS] port1 eth_type 已生效 = %h", cfg_eth_type[P_ETH1_OFF +: 16]);

    send_cmd(8'h02, 8'h0F, 8'h10, 4'd0, 4'd1, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h0F, 8'h00, 8'h10, 4'd0, 4'd1, 8'd2, {112'd0, 16'hB588});

    // ---------------- T13 RESET_DEF 覆盖全部端口/套 ----------------
    $display("--- T13: RESET_DEF 复位全部端口 ---");
    send_cmd(8'h01, 8'h10, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h81, 8'h10, 8'h00, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);
    if (cfg_local_ip[P_IP1_OFF +: 32] !== 32'h0801_A8C0) begin
      $display("  [FAIL] RESET_DEF 后 port1 IP=%h exp 0801a8c0", cfg_local_ip[P_IP1_OFF +: 32]);
      err_total = err_total + 1;
    end else $display("  [PASS] RESET_DEF 后 port1 IP 恢复默认 = %h", cfg_local_ip[P_IP1_OFF +: 32]);
    if (cfg_udp_port[P_UDP11_OFF +: 32] !== 32'h0008_0004) begin
      $display("  [FAIL] RESET_DEF 后 port1 set1 udp=%h exp 00080004", cfg_udp_port[P_UDP11_OFF +: 32]);
      err_total = err_total + 1;
    end else $display("  [PASS] RESET_DEF 后 port1 set1 udp 恢复默认 = %h", cfg_udp_port[P_UDP11_OFF +: 32]);
    if (cfg_eth_type[P_ETH1_OFF +: 16] !== 16'hB588) begin
      $display("  [FAIL] RESET_DEF 后 port1 eth_type=%h exp b588", cfg_eth_type[P_ETH1_OFF +: 16]);
      err_total = err_total + 1;
    end else $display("  [PASS] RESET_DEF 后 port1 eth_type 恢复默认 = %h", cfg_eth_type[P_ETH1_OFF +: 16]);

    // ---------------- T14 GET 默认命令通道端口 ----------------
    $display("--- T14: GET 默认 CMD_UDP_PORT (port0) ---");
    send_cmd(8'h02, 8'h11, 8'h33, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h11, 8'h00, 8'h33, 4'd0, 4'd0, 8'd2, {112'd0, 16'hC0DE});

    // ---------------- T15 SET/GET 命令通道端口（port1）----------------
    $display("--- T15: SET/GET CMD_UDP_PORT port1 = 0x1234 ---");
    send_cmd(8'h01, 8'h12, 8'h33, 4'd0, 4'd1, 8'd2, {112'd0, 16'h1234});
    check_rsp(8'h81, 8'h12, 8'h00, 8'h33, 4'd0, 4'd1, 8'd2, 128'd0);
    if (cfg_cmd_udp_port[16 +: 16] !== 16'h1234) begin
      $display("  [FAIL] cfg_cmd_udp_port[16+:16]=%h exp 1234", cfg_cmd_udp_port[16 +: 16]);
      err_total = err_total + 1;
    end else $display("  [PASS] cfg_cmd_udp_port[16+:16] 已生效 = %h", cfg_cmd_udp_port[16 +: 16]);

    send_cmd(8'h02, 8'h13, 8'h33, 4'd0, 4'd1, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h13, 8'h00, 8'h33, 4'd0, 4'd1, 8'd2, {112'd0, 16'h1234});

    // ---------------- T16 SET/GET 命令应答优先级（port1）----------------
    $display("--- T16: SET/GET CMD_UDP_PRIO port1 = 11 ---");
    send_cmd(8'h01, 8'h14, 8'h34, 4'd0, 4'd1, 8'd1, {120'd0, 8'd11});
    check_rsp(8'h81, 8'h14, 8'h00, 8'h34, 4'd0, 4'd1, 8'd1, 128'd0);
    send_cmd(8'h02, 8'h15, 8'h34, 4'd0, 4'd1, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h15, 8'h00, 8'h34, 4'd0, 4'd1, 8'd1, {120'd0, 8'd11});

    // ---------------- T17 已删除项 0x62 应为 BAD_ITEM ----------------
    $display("--- T17: 已删除的 RX_ERR_CNT(0x62) -> BAD_ITEM ---");
    send_cmd(8'h02, 8'h16, 8'h62, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h8F, 8'h16, 8'h02, 8'h62, 4'd0, 4'd0, 8'd0, 128'd0);

    // ---------------- T18 RESET_DEF 恢复命令通道默认值 ----------------
    $display("--- T18: RESET_DEF 恢复 CMD 通道默认 ---");
    send_cmd(8'h01, 8'h17, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h81, 8'h17, 8'h00, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);
    if (cfg_cmd_udp_port[16 +: 16] !== 16'hC0DE) begin
      $display("  [FAIL] RESET_DEF 后 cmd_udp_port[port1]=%h exp c0de", cfg_cmd_udp_port[16 +: 16]);
      err_total = err_total + 1;
    end else $display("  [PASS] RESET_DEF 后 cmd_udp_port[port1] = %h", cfg_cmd_udp_port[16 +: 16]);
    // prio 已不再引出端口，改用 GET 0x34 回读校验（比读镜像更直接）
    send_cmd(8'h02, 8'hF1, 8'h34, 4'd0, 4'd1, 8'd0, 128'd0);
    check_rsp(8'h82, 8'hF1, 8'h00, 8'h34, 4'd0, 4'd1, 8'd1, {120'd0, 8'd9});

    // ---------------- T19 未分配编号 0x56 应为 BAD_ITEM ----------------
    // 状态组重编号后有效范围为 0x51~0x55（原 0x53 起整体前移一位），0x56 已废弃
    $display("--- T19: 未分配编号 (0x56) -> BAD_ITEM ---");
    send_cmd(8'h02, 8'h18, 8'h56, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h8F, 8'h18, 8'h02, 8'h56, 4'd0, 4'd0, 8'd0, 128'd0);

    // ---------------- T20 状态组边界仍须可读（确认没误伤）----------------
    $display("--- T20: 0x51/0x52/0x55 仍可读（状态组边界）---");
    send_cmd(8'h02, 8'h19, 8'h51, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h19, 8'h00, 8'h51, 4'd0, 4'd0, 8'd4, {96'd0, `CFG_VERSION_WORD});
    send_cmd(8'h02, 8'h1A, 8'h52, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h1A, 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, {127'd0, stat_link_status[0]});
    send_cmd(8'h02, 8'h1B, 8'h55, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h1B, 8'h00, 8'h55, 4'd0, 4'd0, 8'd1, {127'd0, stat_is_df[0]});

    // ---------------- T21 目的地址不符的命令帧应被整帧丢弃 ----------------
    // 只门控 valid、ready 照常 ⇒ 不解析、不占 FIFO、不应答；同时不得影响后续命令
    $display("--- T21: 目的 IP 非本机 -> 整帧丢弃，无应答 ---");
    send_cmd_to(8'h02, 8'h1C, 8'h51, 4'd0, 4'd0, 8'd0, 128'd0, 32'hFF01_A8C0);
    cyc(300);
    if (m_valid) begin
      $display("  [FAIL] 目的 IP 不符却产生了应答");
      err_total = err_total + 1;
    end else $display("  [PASS] 无应答（整帧已丢弃）");
    // 通道未被污染：紧接着一条正常命令必须正常应答
    send_cmd(8'h02, 8'h1D, 8'h51, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h1D, 8'h00, 8'h51, 4'd0, 4'd0, 8'd4, {96'd0, `CFG_VERSION_WORD});

    // ---------------- T22 命令行含多条 TLV 时 usr 逐条对应 ----------------
    $display("--- T22: 单帧多 TLV，两条应答的 udp_usr 均正确 ---");
    send_cmd2(8'h02, 8'h1E);
    check_rsp(8'h82, 8'h1E, 8'h00, 8'h51, 4'd0, 4'd0, 8'd4, {96'd0, `CFG_VERSION_WORD});
    check_rsp(8'h82, 8'h1E, 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, {127'd0, stat_link_status[0]});

    // ---------------- T23 多拍帧：usr 只在第一拍有效 ----------------
    // 78 字节帧跨 2 个 beat；第 2 拍故意把 usr 置 0（模拟上游只在首拍给值），
    // 验证准入判定与侧带锁存都只依赖首拍，不会因后续拍无效而丢帧/错值
    $display("--- T23: 84B 多拍帧，usr 仅首拍有效 ---");
    clear_stat();
    build_frame(8'h02, 8'h20, 4);
    send_beat(lf[511:0],    64'hFFFF_FFFF_FFFF_FFFF, 1'b0, mk_usr({P_CMD_PORT, tb_lcl_ip, tb_peer_port, tb_peer_ip}));
    send_beat(lf[1023:512], 64'h0000_0000_000F_FFFF, 1'b1, 241'd0);   // 第 2 拍 usr 故意无效（dst_ip=0 => 不合格）
    cyc(400);
    if (rsp_cnt !== 4) begin
      $display("  [FAIL] 应答条数=%0d exp 4（4 条 TLV 应各回一条）", rsp_cnt);
      err_total = err_total + 1;
    end
    else if (rsp_usr_err !== 0) begin
      $display("  [FAIL] 有 %0d 条应答的 udp_usr 错误（首拍锁存失效）", rsp_usr_err);
      err_total = err_total + 1;
    end
    else $display("  [PASS] 4 条应答且 udp_usr 全部正确（第 2 拍无效 usr 未污染侧带）");

    // ---------------- T24 多拍帧 + 目的 IP 不符：整帧丢弃 ----------------
    // 关键：丢帧结论必须跨 beat 保持，不能在第 2 拍的握手处被无效 usr 覆盖
    $display("--- T24: 84B 多拍帧，目的 IP 不符 -> 整帧丢弃 ---");
    clear_stat();
    build_frame(8'h02, 8'h21, 4);
    send_beat(lf[511:0],    64'hFFFF_FFFF_FFFF_FFFF, 1'b0, mk_usr({P_CMD_PORT, 32'hFF01_A8C0, tb_peer_port, tb_peer_ip}));
    send_beat(lf[1023:512], 64'h0000_0000_000F_FFFF, 1'b1, mk_usr({P_CMD_PORT, tb_lcl_ip,    tb_peer_port, tb_peer_ip}));
    cyc(400);
    if (rsp_cnt !== 0) begin
      $display("  [FAIL] 目的 IP 不符却产生 %0d 条应答（丢帧结论未跨 beat 保持）", rsp_cnt);
      err_total = err_total + 1;
    end else $display("  [PASS] 无应答（多拍帧整帧已丢弃，跨 beat 保持）");
    // 通道未被污染
    send_cmd(8'h02, 8'h22, 8'h51, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h22, 8'h00, 8'h51, 4'd0, 4'd0, 8'd4, {96'd0, `CFG_VERSION_WORD});

    // ---------------- T25 三拍帧：usr 仅首拍有效 ----------------
    // 135 字节帧跨 3 个 beat；第 2、3 拍 usr 都置 0
    $display("--- T25: 147B 三拍帧，usr 仅首拍有效 ---");
    clear_stat();
    build_frame(8'h02, 8'h23, 7);
    send_beat(lf[511:0],     64'hFFFF_FFFF_FFFF_FFFF, 1'b0, mk_usr({P_CMD_PORT, tb_lcl_ip, tb_peer_port, tb_peer_ip}));
    send_beat(lf[1023:512],  64'hFFFF_FFFF_FFFF_FFFF, 1'b0, 241'd0);
    send_beat(lf[1535:1024], 64'h0000_0000_0007_FFFF, 1'b1, 241'd0);
    cyc(600);
    if (rsp_cnt !== 7) begin
      $display("  [FAIL] 应答条数=%0d exp 7（7 条 TLV 应各回一条）", rsp_cnt);
      err_total = err_total + 1;
    end
    else if (rsp_usr_err !== 0) begin
      $display("  [FAIL] 有 %0d 条应答的 udp_usr 错误", rsp_usr_err);
      err_total = err_total + 1;
    end
    else $display("  [PASS] 7 条应答且 udp_usr 全部正确（第 2/3 拍无效 usr 未污染）");

    // ---------------- T26 三拍帧 + 目的 IP 不符：丢帧结论必须跨 3 拍保持 ----------------
    // 第 2、3 拍故意给【合法】usr：若 is_drop_reg 在帧中间的握手被清 0，
    // 从第 3 拍起残帧会被当成有效帧解析，此用例即失败
    $display("--- T26: 147B 三拍帧，目的 IP 不符 -> 整帧丢弃 ---");
    clear_stat();
    build_frame(8'h02, 8'h24, 7);
    send_beat(lf[511:0],     64'hFFFF_FFFF_FFFF_FFFF, 1'b0, mk_usr({P_CMD_PORT, 32'hFF01_A8C0, tb_peer_port, tb_peer_ip}));
    send_beat(lf[1023:512],  64'hFFFF_FFFF_FFFF_FFFF, 1'b0, mk_usr({P_CMD_PORT, tb_lcl_ip,    tb_peer_port, tb_peer_ip}));
    send_beat(lf[1535:1024], 64'h0000_0000_0007_FFFF, 1'b1, mk_usr({P_CMD_PORT, tb_lcl_ip,    tb_peer_port, tb_peer_ip}));
    cyc(600);
    if (rsp_cnt !== 0) begin
      $display("  [FAIL] 目的 IP 不符却产生 %0d 条应答（丢帧结论未跨 3 拍保持）", rsp_cnt);
      err_total = err_total + 1;
    end else $display("  [PASS] 无应答（三拍帧整帧已丢弃）");
    // 通道未被污染
    send_cmd(8'h02, 8'h25, 8'h51, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h25, 8'h00, 8'h51, 4'd0, 4'd0, 8'd4, {96'd0, `CFG_VERSION_WORD});

    // ---------------- T27 标准 UDP 侧带：无关字段脏值 + 四元组换值 ----------------
    // 准入只看 dst_ip；MAC / err / proto / total_len / ttl / udp_len 给脏值也必须正常应答。
    // 同时把 src_ip / src_port 换成另一组值，验证 241b -> 96b 的字段抽取位段无错位。
    $display("--- T27: 侧带无关字段脏值 + 四元组换值，仍正确应答 ---");
    clear_stat();
    tb_peer_ip    = 32'h0B01_A8C0;   // 192.168.1.11
    tb_peer_port  = 16'hABCD;
    dirty_usr             = mk_usr({P_CMD_PORT, tb_lcl_ip, tb_peer_port, tb_peer_ip});
    dirty_usr[47:0]       = 48'hFFFF_FFFF_FFFF;   // src_mac 脏
    dirty_usr[95:48]      = 48'hAAAA_AAAA_AAAA;   // dst_mac 脏
    dirty_usr[96]         = 1'b1;                 // err 置位
    dirty_usr[104:97]     = 8'hFF;                // proto 非 UDP
    dirty_usr[120:105]    = 16'h1234;             // total_len 脏
    dirty_usr[128:121]    = 8'h01;                // ttl 脏
    dirty_usr[240:225]    = 16'h5678;             // udp_len 脏
    build_frame(8'h02, 8'h26, 1);                 // 21B，单拍
    send_beat(lf[511:0], 64'h0000_0000_001F_FFFF, 1'b1, dirty_usr);
    check_rsp(8'h82, 8'h26, 8'h00, 8'h51, 4'd0, 4'd0, 8'd4, {96'd0, `CFG_VERSION_WORD});
    cyc(50);
    if (rsp_usr_err !== 0) begin
      $display("  [FAIL] 有 %0d 条应答的 udp_usr 错误（四元组抽取位段错位）", rsp_usr_err);
      err_total = err_total + 1;
    end else $display("  [PASS] 应答 udp_usr 正确（脏字段未干扰，四元组抽取无错位）");
    tb_peer_ip    = 32'h0A01_A8C0;
    tb_peer_port  = 16'h1234;

    // ---------------- T28 错误状态码全覆盖 ----------------
    // 补 BAD_SET / BAD_LEN / WRITE_ONLY / READ_ONLY 四个此前未覆盖的状态码
    $display("--- T28: 错误状态码 BAD_SET(03) ---");
    // item=0x00 为地址类，set 维度上限 = CFG_MAX_V4_SET_NUM = 1，故 set=5 越界
    send_cmd(8'h01, 8'h30, 8'h00, 4'd5, 4'd0, 8'd4, {96'd0, NEW_IP0});
    check_rsp(8'h8F, 8'h30, 8'h03, 8'h00, 4'd5, 4'd0, 8'd4, 128'd0);

    $display("--- T28: 错误状态码 BAD_LEN(05) ---");
    // ① 上界：MAX_VALUE_BYTES = 16，len=17 越界
    send_cmd(8'h02, 8'h31, 8'h51, 4'd0, 4'd0, 8'd17, 128'd0);
    check_rsp(8'h8F, 8'h31, 8'h05, 8'h51, 4'd0, 4'd0, 8'd17, 128'd0);
    // ② SET 时 LEN 必须等于 ITEM 期望长度（否则会静默写错值）
    //    IPv4 IP(0x00) 期望 4 字节，发 1 字节必须被拒
    send_cmd(8'h01, 8'h35, 8'h00, 4'd0, 4'd0, 8'd1, {120'd0, 8'h64});
    check_rsp(8'h8F, 8'h35, 8'h05, 8'h00, 4'd0, 4'd0, 8'd1, 128'd0);
    //    eth_type(0x10) 期望 2 字节，发 1 字节必须被拒
    send_cmd(8'h01, 8'h36, 8'h10, 4'd0, 4'd0, 8'd1, {120'd0, 8'h88});
    check_rsp(8'h8F, 8'h36, 8'h05, 8'h10, 4'd0, 4'd0, 8'd1, 128'd0);
    //    PENDING_TIME(0x30) 期望 8 字节，发 4 字节必须被拒
    send_cmd(8'h01, 8'h37, 8'h30, 4'd0, 4'd0, 8'd4, {96'd0, 32'd1});
    check_rsp(8'h8F, 8'h37, 8'h05, 8'h30, 4'd0, 4'd0, 8'd4, 128'd0);
    //    被拒的 SET 不得改动配置（IP 应仍是 tb_lcl_ip）
    send_cmd(8'h02, 8'h38, 8'h00, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h38, 8'h00, 8'h00, 4'd0, 4'd0, 8'd4, {96'd0, tb_lcl_ip});
    // ③ GET 的 LEN 只查上界，不比对期望长度（保持协议兼容）
    send_cmd(8'h02, 8'h39, 8'h00, 4'd0, 4'd0, 8'd15, 128'd0);
    check_rsp(8'h82, 8'h39, 8'h00, 8'h00, 4'd0, 4'd0, 8'd4, {96'd0, tb_lcl_ip});

    $display("--- T28: 错误状态码 READ_ONLY(07) ---");
    // SET 只读项 0x51 VERSION -> 该寄存器只读
    send_cmd(8'h01, 8'h32, 8'h51, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h8F, 8'h32, 8'h07, 8'h51, 4'd0, 4'd0, 8'd0, 128'd0);

    $display("--- T28: 错误状态码 WRITE_ONLY(06) ---");
    // GET 只写项 0x40 RESET_DEF -> 该寄存器只写
    send_cmd(8'h02, 8'h33, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h8F, 8'h33, 8'h06, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);
    // 错误命令不得改动配置
    send_cmd(8'h02, 8'h34, 8'h00, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h34, 8'h00, 8'h00, 4'd0, 4'd0, 8'd4, {96'd0, tb_lcl_ip});

    // ---------------- T29 配置边界 0x70 / 0x71 / 0x72 ----------------
    // GEOMETRY 9 个字段，从高到低：udprx / v6rx / v4rx / macrx / v6d / v6s / v4 / pt宽度 / 仲裁宽度
    $display("--- T29: GET GEOMETRY(0x70) port0 ---");
    send_cmd(8'h02, 8'h40, 8'h70, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h40, 8'h00, 8'h70, 4'd0, 4'd0, 8'd9,
              {56'd0, G_UDP_RX0, G_V6RX0,
                     G_V4RX0, G_MACRX0,
                     G_V6D0, G_V6S0,
                     G_V40, G_PT0,
                     G_ARB0});

    $display("--- T29: GET GEOMETRY_MAX(0x71) port0 ---");
    send_cmd(8'h02, 8'h41, 8'h71, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h41, 8'h00, 8'h71, 4'd0, 4'd0, 8'd9,
              {56'd0, `CFG_MAX_UDP_RX_NUM, `CFG_MAX_IPV6_RX_NUM, `CFG_MAX_IPV4_RX_NUM,
                     `CFG_MAX_MAC_RX_NUM, `CFG_MAX_V6_DST_SET_NUM, `CFG_MAX_V6_SRC_SET_NUM,
                     `CFG_MAX_V4_SET_NUM, `CFG_MAX_PENDING_TIME_WIDTH, `CFG_MAX_ARBITER_VAL_WIDTH});

    $display("--- T29: GET PORT_NUM(0x72) ---");
    send_cmd(8'h02, 8'h42, 8'h72, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h42, 8'h00, 8'h72, 4'd0, 4'd0, 8'd1, {124'd0, `CFG_NUM_PORT});

    // ---------------- T30 IPv6 地址类读写 ----------------
    $display("--- T30: GET/SET IPv6 本机地址(0x04) port0 set0 ---");
    send_cmd(8'h02, 8'h50, 8'h04, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h50, 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, G_V6S0_IP);
    send_cmd(8'h01, 8'h51, 8'h04, 4'd0, 4'd0, 8'd16,
             128'hFE80_0000_0000_0000_0000_0000_0000_0001);
    check_rsp(8'h81, 8'h51, 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 128'd0);
    if (cfg_src_ipv6[0+:128] !== 128'hFE80_0000_0000_0000_0000_0000_0000_0001) begin
      $display("  [FAIL] cfg_src_ipv6[0+:128]=%h exp fe80::1", cfg_src_ipv6[0+:128]);
      err_total = err_total + 1;
    end else $display("  [PASS] cfg_src_ipv6[0+:128] 已生效");
    send_cmd(8'h02, 8'h52, 8'h04, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h52, 8'h00, 8'h04, 4'd0, 4'd0, 8'd16,
              128'hFE80_0000_0000_0000_0000_0000_0000_0001);

    $display("--- T30: GET IPv6 邻居地址(0x06) / MAC(0x07) port0 set0 ---");
    send_cmd(8'h02, 8'h53, 8'h06, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h53, 8'h00, 8'h06, 4'd0, 4'd0, 8'd16, G_V6D0_IP);
    send_cmd(8'h02, 8'h54, 8'h07, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h54, 8'h00, 8'h07, 4'd0, 4'd0, 8'd6, {80'd0, G_V6D0_MAC});

    // ---------------- T31 分流表 0x11 / 0x12 读写 ----------------
    $display("--- T31: GET/SET IPv4_PROTO_DICT(0x11) port0 set0 ---");
    send_cmd(8'h02, 8'h60, 8'h11, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h60, 8'h00, 8'h11, 4'd0, 4'd0, 8'd1, {120'd0, G_V4P0});
    send_cmd(8'h01, 8'h61, 8'h11, 4'd0, 4'd0, 8'd1, {120'd0, 8'h2F});
    check_rsp(8'h81, 8'h61, 8'h00, 8'h11, 4'd0, 4'd0, 8'd1, 128'd0);
    if (cfg_ipv4_proto[0+:8] !== 8'h2F) begin
      $display("  [FAIL] cfg_ipv4_proto[0+:8]=%h exp 2f", cfg_ipv4_proto[0+:8]);
      err_total = err_total + 1;
    end else $display("  [PASS] cfg_ipv4_proto[0+:8] 已生效 = 2f");

    $display("--- T31: GET IPv6_NH_DICT(0x12) port0 set0 ---");
    send_cmd(8'h02, 8'h62, 8'h12, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h62, 8'h00, 8'h12, 4'd0, 4'd0, 8'd1, {120'd0, G_V6NH0});

    // ---------------- T32 统计项 0x60 / 0x61 ----------------
    $display("--- T32: GET ARP_STAT(0x60) / ICMP_STAT(0x61) port0 ---");
    send_cmd(8'h02, 8'h70, 8'h60, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h70, 8'h00, 8'h60, 4'd0, 4'd0, 8'd4,
              {96'd0, 25'd0, stat_arp[0+:7]});
    send_cmd(8'h02, 8'h71, 8'h61, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h71, 8'h00, 8'h61, 4'd0, 4'd0, 8'd1,
              {120'd0, 4'd0, stat_icmp[0+:4]});

    // ---------------- T33 三个 clear 动作必须产生单拍脉冲 ----------------
    $display("--- T33: CACHE_CLEAR(0x41) / PEND_CLEAR(0x42) / STAT_CLEAR(0x43) port0 ---");
    clr_clear();
    send_cmd(8'h01, 8'h80, 8'h41, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h81, 8'h80, 8'h00, 8'h41, 4'd0, 4'd0, 8'd0, 128'd0);
    cyc(5);
    send_cmd(8'h01, 8'h81, 8'h42, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h81, 8'h81, 8'h00, 8'h42, 4'd0, 4'd0, 8'd0, 128'd0);
    cyc(5);
    send_cmd(8'h01, 8'h82, 8'h43, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h81, 8'h82, 8'h00, 8'h43, 4'd0, 4'd0, 8'd0, 128'd0);
    cyc(5);
    if (clr_seen !== 3'b111) begin
      $display("  [FAIL] clear 脉冲未全部出现: %b (exp 111)", clr_seen);
      err_total = err_total + 1;
    end else if (clr_cnt !== 3) begin
      $display("  [FAIL] clear 脉冲个数 = %0d (exp 3，每个动作 1 拍)", clr_cnt);
      err_total = err_total + 1;
    end else $display("  [PASS] 三个 clear 各产生 1 拍脉冲，且只作用于 port0");
    // 脉宽必须是 1 拍：随后 50 拍内不得再出现
    cyc(50);
    if (clr_cnt !== 3) begin
      $display("  [FAIL] clear 脉冲非单拍，之后又出现 %0d 次", clr_cnt - 3);
      err_total = err_total + 1;
    end else $display("  [PASS] clear 脉冲为单拍（50 拍内无重复）");

    // 复位回默认，避免影响后续
    send_cmd(8'h01, 8'h83, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h81, 8'h83, 8'h00, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);

    // ---------------- T34 剩余 ITEM：MAC / 网关 / 掩码 / 优先级 / TX 状态 ----------------
    $display("--- T34: SET IPv4 MAC(0x01) port0 set0 ---");
    send_cmd(8'h01, 8'h90, 8'h01, 4'd0, 4'd0, 8'd6, {80'd0, 48'h0C0B_0A09_0807});
    check_rsp(8'h81, 8'h90, 8'h00, 8'h01, 4'd0, 4'd0, 8'd6, 128'd0);
    if (cfg_local_mac[0+:48] !== 48'h0C0B_0A09_0807) begin
      $display("  [FAIL] cfg_local_mac[0+:48]=%h exp 0c0b0a090807", cfg_local_mac[0+:48]);
      err_total = err_total + 1;
    end else $display("  [PASS] cfg_local_mac[0+:48] 已生效");

    $display("--- T34: SET IPv4 GW(0x02) / MASK(0x03) port0 set0 ---");
    send_cmd(8'h01, 8'h91, 8'h02, 4'd0, 4'd0, 8'd4, {96'd0, 32'h0102_A8C0});
    check_rsp(8'h81, 8'h91, 8'h00, 8'h02, 4'd0, 4'd0, 8'd4, 128'd0);
    send_cmd(8'h02, 8'h92, 8'h02, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h92, 8'h00, 8'h02, 4'd0, 4'd0, 8'd4, {96'd0, 32'h0102_A8C0});
    send_cmd(8'h01, 8'h93, 8'h03, 4'd0, 4'd0, 8'd4, {96'd0, 32'h00FF_FF00});
    check_rsp(8'h81, 8'h93, 8'h00, 8'h03, 4'd0, 4'd0, 8'd4, 128'd0);
    if (cfg_subnet_mask[0+:32] !== 32'h00FF_FF00) begin
      $display("  [FAIL] cfg_subnet_mask=%h exp 00ffff00", cfg_subnet_mask[0+:32]);
      err_total = err_total + 1;
    end else $display("  [PASS] cfg_subnet_mask 已生效");

    $display("--- T34: SET IPv6 SRC MAC(0x05) port0 set0 ---");
    send_cmd(8'h01, 8'h94, 8'h05, 4'd0, 4'd0, 8'd6, {80'd0, 48'h0F0E_0D0C_0B0A});
    check_rsp(8'h81, 8'h94, 8'h00, 8'h05, 4'd0, 4'd0, 8'd6, 128'd0);
    if (cfg_src_mac[0+:48] !== 48'h0F0E_0D0C_0B0A) begin
      $display("  [FAIL] cfg_src_mac[0+:48]=%h exp 0f0e0d0c0b0a", cfg_src_mac[0+:48]);
      err_total = err_total + 1;
    end else $display("  [PASS] cfg_src_mac[0+:48] 已生效");

    $display("--- T34: SET ARP_PRIO(0x31) / ICMP_PRIO(0x32) port0 ---");
    send_cmd(8'h01, 8'h95, 8'h31, 4'd0, 4'd0, 8'd1, {120'd0, 4'd7});
    check_rsp(8'h81, 8'h95, 8'h00, 8'h31, 4'd0, 4'd0, 8'd1, 128'd0);
    if (cfg_arp_prio[0+:4] !== 4'd7) begin
      $display("  [FAIL] cfg_arp_prio[0+:4]=%0d exp 7", cfg_arp_prio[0+:4]);
      err_total = err_total + 1;
    end else $display("  [PASS] cfg_arp_prio 已生效 = 7");
    send_cmd(8'h01, 8'h96, 8'h32, 4'd0, 4'd0, 8'd1, {120'd0, 4'd5});
    check_rsp(8'h81, 8'h96, 8'h00, 8'h32, 4'd0, 4'd0, 8'd1, 128'd0);
    if (cfg_icmp_prio[0+:4] !== 4'd5) begin
      $display("  [FAIL] cfg_icmp_prio[0+:4]=%0d exp 5", cfg_icmp_prio[0+:4]);
      err_total = err_total + 1;
    end else $display("  [PASS] cfg_icmp_prio 已生效 = 5");

    $display("--- T34: GET TX_IDLE(0x53) / TX_ACTIVE(0x54) port0 ---");
    send_cmd(8'h02, 8'h97, 8'h53, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h97, 8'h00, 8'h53, 4'd0, 4'd0, 8'd1, {127'd0, stat_tx_idle[0]});
    send_cmd(8'h02, 8'h98, 8'h54, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h82, 8'h98, 8'h00, 8'h54, 4'd0, 4'd0, 8'd1,
              {120'd0, stat_tx_active[0+:P_TXW]});

    // ---------------- T35 m_axis 反压下多命令排队的一致性 ----------------
    // 关掉 m_ready 让 3 条应答全部挂在输出侧，再放开：内容与顺序都必须正确。
    // 这条守护 cfg_get 的组帧寄存器（曾被"每拍重装载 rd_val"污染，反压时前一条应答被后一次读取改写）
    $display("--- T35: m_axis 反压期间 3 条命令排队，放开后各自正确 ---");
    cap_clear();
    clear_stat();
    bp_hold = 1'b1;
    cyc(2);                                                     // 等 m_ready 真正拉低
    send_cmd(8'h02, 8'hA0, 8'h00, 4'd0, 4'd0, 8'd0, 128'd0);   // IPv4 IP
    send_cmd(8'h02, 8'hA1, 8'h51, 4'd0, 4'd0, 8'd0, 128'd0);   // VERSION
    send_cmd(8'h02, 8'hA2, 8'h52, 4'd0, 4'd0, 8'd0, 128'd0);   // LINK_STATUS
    cyc(60);                                                    // 应答全部挂起
    bp_hold = 1'b0;                                             // 放开
    cyc(80);
    if (cap_n !== 3) begin
      $display("  [FAIL] 应答条数 = %0d (exp 3)", cap_n);
      err_total = err_total + 1;
    end
    else if (cap_seq[0] !== 8'hA0 || cap_seq[1] !== 8'hA1 || cap_seq[2] !== 8'hA2) begin
      $display("  [FAIL] 应答顺序错误: seq = %h %h %h (exp a0 a1 a2)",
               cap_seq[0], cap_seq[1], cap_seq[2]);
      err_total = err_total + 1;
    end
    else if (cap_item[0] !== 8'h00 || cap_item[1] !== 8'h51 || cap_item[2] !== 8'h52) begin
      $display("  [FAIL] 应答 ITEM 错误: %h %h %h (exp 00 51 52)",
               cap_item[0], cap_item[1], cap_item[2]);
      err_total = err_total + 1;
    end
    else if (rsp_usr_err !== 0) begin
      $display("  [FAIL] 有 %0d 条应答 udp_usr 错误", rsp_usr_err);
      err_total = err_total + 1;
    end
    else $display("  [PASS] 3 条应答内容/顺序/侧带均正确（反压未造成重复或丢失）");

    // 收尾：恢复默认，保证用例间独立
    send_cmd(8'h01, 8'hA3, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);
    check_rsp(8'h81, 8'hA3, 8'h00, 8'h40, 4'd0, 4'd0, 8'd0, 128'd0);

    // ---------------- 汇总 ----------------
    $display("================================================================");
    if (err_total == 0) $display(" *** ALL TESTS PASSED ***");
    else                 $display(" *** %0d CHECK(S) FAILED ***", err_total);
    $display("================================================================");
    $finish;
  end

  initial begin #4_000_000; $display("[%0t] [FAIL] FATAL: timeout", $time); $display(" *** 1 CHECK(S) FAILED ***"); $finish; end

endmodule
