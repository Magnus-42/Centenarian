`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv6_mac_lookup.v
// Module Name : ipv6_mac_lookup
// Author      : LiXintao
// Date        : 2026-10-11
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 纯 IPv6 包 -> 查表得到 dst_mac / src_mac (仅首拍有效), 交给
//               ipv6_mac_add 插以太头; 查不到对应 MAC 的包直接丢弃.
// 
// ============================================================================

module ipv6_mac_lookup #(
  parameter  DEST_MAC_ENTRY_NUM= 8 ,     // 表项数(上游可配)
  parameter  SRC_MAC_ENTRY_NUM= 8 ,
  parameter  AXIS_USER_WIDTH= 4 
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // ============================================================================
  // 上游统一配置的 IP->MAC 映射表(扁平打包)
  // ============================================================================
  input  wire          [128*DEST_MAC_ENTRY_NUM-1:0]    cfg_dest_match_ipv6,
  input  wire          [48*DEST_MAC_ENTRY_NUM-1:0]     cfg_dest_match_mac,

  input  wire          [128*SRC_MAC_ENTRY_NUM-1:0]     cfg_src_match_ipv6,
  input  wire          [48*SRC_MAC_ENTRY_NUM-1:0]      cfg_src_match_mac,

  // ============================================================================
  // 输入 : 纯 IPv6 包
  // ============================================================================
  input  wire          [                 511:0]        ipv6_axis_sdata ,
  input  wire          [                  63:0]        ipv6_axis_skeep ,
  input  wire                                          ipv6_axis_slast ,
  input  wire                                          ipv6_axis_svalid,
  input  wire          [   AXIS_USER_WIDTH-1:0]        ipv6_axis_susr  ,
  output wire                                          ipv6_axis_sready,

  // ============================================================================
  // 输出 : 纯 IPv6 包 (命中直通, 未命中 mvalid 拉低 => 丢弃)
  // ============================================================================
  output wire          [                 511:0]        ipv6_axis_mdata ,
  output wire          [                  63:0]        ipv6_axis_mkeep ,
  output wire                                          ipv6_axis_mlast ,
  output wire                                          ipv6_axis_mvalid,
  output wire          [   AXIS_USER_WIDTH-1:0]        ipv6_axis_musr  ,
  input  wire                                          ipv6_axis_mready,

  // ============================================================================
  // 查表结果 (仅输出首拍有效, 供 ipv6_mac_add 插头用)
  // ============================================================================
  output wire          [                  47:0]        dst_mac         ,
  output wire          [                  47:0]        src_mac         ,

  // 丢包指示: 未命中包的"首拍被接收"时 1 拍脉冲(调试/统计)
  output wire                                          stat_drop_pulse  
);

  // ============================================================================
  // 组合查表
  // ============================================================================
  reg                  [                  47:0]        dst_mac_comb     ;
  reg                  [                  47:0]        src_mac_comb     ;
  reg                                                  dst_hit_comb     ;
  reg                                                  src_hit_comb     ;

  integer                                              i                ;
  always @(*) begin
    dst_mac_comb = 48'd0;
    src_mac_comb = 48'd0;
    dst_hit_comb = 1'b0;
    src_hit_comb = 1'b0;
    for (i = 0; i < DEST_MAC_ENTRY_NUM; i = i + 1) begin
      // 目的 IPv6 地址查 dst_mac (byte24~39)
      if (ipv6_axis_sdata[192 +: 128] == cfg_dest_match_ipv6[i*128 +: 128]) begin
        dst_mac_comb = cfg_dest_match_mac[i*48 +: 48];
        dst_hit_comb = 1'b1;
      end
    end

    for (i = 0; i < SRC_MAC_ENTRY_NUM; i = i + 1) begin
      // 源 IPv6 地址查 src_mac (byte8~23)
      if (ipv6_axis_sdata[64 +: 128] == cfg_src_match_ipv6[i*128 +: 128]) begin
        src_mac_comb = cfg_src_match_mac[i*48 +: 48];
        src_hit_comb = 1'b1;
      end
    end
  end

  reg                                                  is_first_beat    ,is_first_beat_s1;

  reg                  [                 511:0]        ipv6_axis_sdata_s1;
  reg                  [                  63:0]        ipv6_axis_skeep_s1;
  reg                                                  ipv6_axis_slast_s1;
  reg                                                  ipv6_axis_svalid_s1;
  reg                  [   AXIS_USER_WIDTH-1:0]        ipv6_axis_susr_s1;
  reg                  [                  47:0]        dst_mac_s1       ;
  reg                  [                  47:0]        src_mac_s1       ;
    
  reg                  [                 511:0]        ipv6_axis_sdata_s2;
  reg                  [                  63:0]        ipv6_axis_skeep_s2;
  reg                                                  ipv6_axis_slast_s2;
  reg                                                  ipv6_axis_svalid_s2;
  reg                  [   AXIS_USER_WIDTH-1:0]        ipv6_axis_susr_s2;
  reg                  [                  47:0]        dst_mac_s2       ;
  reg                  [                  47:0]        src_mac_s2       ;

  reg                                                  dst_hit_s1       ;
  reg                                                  src_hit_s1       ;

  reg                  [                 511:0]        ipv6_axis_mdata_reg;
  reg                  [                  63:0]        ipv6_axis_mkeep_reg;
  reg                                                  ipv6_axis_mlast_reg;
  reg                                                  ipv6_axis_mvalid_reg;
  reg                  [                  47:0]        dst_mac_reg      ;
  reg                  [                  47:0]        src_mac_reg      ;
  reg                  [   AXIS_USER_WIDTH-1:0]        ipv6_axis_musr_reg;

  reg                  [                 511:0]        ipv6_axis_mdata_skid;
  reg                  [                  63:0]        ipv6_axis_mkeep_skid;
  reg                                                  ipv6_axis_mlast_skid;
  reg                                                  ipv6_axis_mvalid_skid;
  reg                  [                  47:0]        dst_mac_skid     ;
  reg                  [                  47:0]        src_mac_skid     ;
  reg                  [   AXIS_USER_WIDTH-1:0]        ipv6_axis_musr_skid;

  reg                                                  is_drop_reg      ;// 在s2及其本包结束生效

  wire                                                 s2_ready          = !ipv6_axis_mvalid_skid                   ;
  wire                                                 s1_ready          = !ipv6_axis_svalid_s1 || s2_ready         ;
  assign  ipv6_axis_sready = !ipv6_axis_svalid_s1 || s1_ready;

  wire                                                 s_handshake       = ipv6_axis_sready && ipv6_axis_svalid     ;
  wire                                                 s1_handshake      = s1_ready && ipv6_axis_svalid_s1          ;
  wire                                                 s2_handshake      = s2_ready && ipv6_axis_svalid_s2          ;
  wire                                                 m_handshake       = ipv6_axis_mready && ipv6_axis_mvalid     ;

  wire                                                 reg_can_take      = !ipv6_axis_mvalid_reg || ipv6_axis_mready;
  wire                                                 skid_to_reg       = ipv6_axis_mvalid_skid && reg_can_take    ;
  wire                                                 s2_to_reg         = s2_handshake && reg_can_take             ;
  wire                                                 s2_to_skid        = s2_handshake && !reg_can_take            ;

  reg                                                  stat_drop_pulse_reg;

  // s1: valid
  always @(posedge clk) begin
    if (rst) begin
      ipv6_axis_svalid_s1 <= 'd0;
    end
    else begin
      if (s_handshake) begin
        ipv6_axis_svalid_s1 <= 1'b1;
      end
      else if(s1_handshake) begin
        ipv6_axis_svalid_s1 <= 1'b0;
      end
    end
  end

  // s1: data / keep / last / 查表结果
  always @(posedge clk) begin
    if (s_handshake) begin
      ipv6_axis_sdata_s1 <= ipv6_axis_sdata;
      ipv6_axis_skeep_s1 <= ipv6_axis_skeep;
      ipv6_axis_slast_s1 <= ipv6_axis_slast;
      ipv6_axis_susr_s1 <= ipv6_axis_susr;
      if (is_first_beat) begin
        dst_mac_s1 <= dst_mac_comb;
        src_mac_s1 <= src_mac_comb;
        dst_hit_s1 <= dst_hit_comb;
        src_hit_s1 <= src_hit_comb;
      end
    end
  end

  // s2: valid
  always @(posedge clk) begin
    if (rst) begin
      ipv6_axis_svalid_s2 <= 'd0;
    end
    else begin
      if (s1_handshake && is_first_beat_s1 && dst_hit_s1 && src_hit_s1) begin
        ipv6_axis_svalid_s2 <= 1'b1;
      end
      else if (s1_handshake && !is_first_beat_s1) begin
        ipv6_axis_svalid_s2 <= ~is_drop_reg;
      end
      else if(s2_handshake) begin
        ipv6_axis_svalid_s2 <= 1'b0;
      end
    end
  end

  // s2: data / keep / last / 查表结果
  always @(posedge clk) begin
    if (s1_handshake) begin
      ipv6_axis_sdata_s2 <= ipv6_axis_sdata_s1;
      ipv6_axis_skeep_s2 <= ipv6_axis_skeep_s1;
      ipv6_axis_slast_s2 <= ipv6_axis_slast_s1;
      ipv6_axis_susr_s2 <= ipv6_axis_susr_s1;
      dst_mac_s2 <= dst_mac_s1;
      src_mac_s2 <= src_mac_s1;
    end
  end

  // reg skid: valid
  always @(posedge clk) begin
    if (rst) begin
      ipv6_axis_mvalid_reg <= 'd0;
      ipv6_axis_mvalid_skid <= 'd0;
    end
    else begin
      if (s2_to_reg || skid_to_reg) begin
        ipv6_axis_mvalid_reg <= 1'b1;
      end
      else if (m_handshake) begin
        ipv6_axis_mvalid_reg <= 1'b0;
      end

      if (s2_to_skid) begin
        ipv6_axis_mvalid_skid <= 1'b1;
      end
      else if (skid_to_reg) begin
        ipv6_axis_mvalid_skid <= 1'b0;
      end
    end
  end

  // reg skid: data keep last
  always @(posedge clk) begin
    if (skid_to_reg) begin
      ipv6_axis_mdata_reg <= ipv6_axis_mdata_skid;
      ipv6_axis_mkeep_reg <= ipv6_axis_mkeep_skid;
      ipv6_axis_mlast_reg <= ipv6_axis_mlast_skid;
      ipv6_axis_musr_reg <= ipv6_axis_musr_skid;
      dst_mac_reg <= dst_mac_skid;
      src_mac_reg <= src_mac_skid;
    end
    else if (s2_to_reg) begin
      ipv6_axis_mdata_reg <= ipv6_axis_sdata_s2;
      ipv6_axis_mkeep_reg <= ipv6_axis_skeep_s2;
      ipv6_axis_mlast_reg <= ipv6_axis_slast_s2;
      ipv6_axis_musr_reg <= ipv6_axis_susr_s2;
      dst_mac_reg <= dst_mac_s2;
      src_mac_reg <= src_mac_s2;
    end

    if (s2_to_skid) begin
      ipv6_axis_mdata_skid <= ipv6_axis_sdata_s2;
      ipv6_axis_mkeep_skid <= ipv6_axis_skeep_s2;
      ipv6_axis_mlast_skid <= ipv6_axis_slast_s2;
      ipv6_axis_musr_skid <= ipv6_axis_susr_s2;
      dst_mac_skid <= dst_mac_s2;
      src_mac_skid <= src_mac_s2;
    end
  end

  // stat_drop_pulse_reg
  always @(posedge clk) begin
    if (rst) begin
      stat_drop_pulse_reg <= 'd0;
    end
    else begin
      if (s1_handshake&&is_first_beat_s1&& ((!dst_hit_s1) || (!src_hit_s1))) begin
        stat_drop_pulse_reg <= 1'b1;
      end
      else begin
        stat_drop_pulse_reg <= 1'b0;
      end
    end
  end

  // is_drop_reg
  always @(posedge clk) begin
    if (rst) begin
      is_drop_reg <= 'd0;
    end
    else begin
      if (s1_handshake&&is_first_beat_s1&&dst_hit_s1&&src_hit_s1) begin
        is_drop_reg <= 1'b0;
      end
      else if(s1_handshake&&is_first_beat_s1) begin
        is_drop_reg <= 1'b1;
      end
    end
  end

  // is_first_beat
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;                                        // 复位后第一拍视为首拍
    end
    else begin
      if (s_handshake) begin
        is_first_beat <= ipv6_axis_slast;                           // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
      end
    end
  end

  // is_first_beat_s1
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat_s1 <= 1'b0;
    end
    else begin
      if (s_handshake) begin
        is_first_beat_s1 <= is_first_beat;
      end
    end
  end

  assign  ipv6_axis_mdata  = ipv6_axis_mdata_reg;
  assign  ipv6_axis_mkeep  = ipv6_axis_mkeep_reg;
  assign  ipv6_axis_mlast  = ipv6_axis_mlast_reg;
  assign  ipv6_axis_mvalid = ipv6_axis_mvalid_reg;
  assign  ipv6_axis_musr   = ipv6_axis_musr_reg;
  assign  dst_mac          = dst_mac_reg      ;
  assign  src_mac          = src_mac_reg      ;
  assign  stat_drop_pulse  = stat_drop_pulse_reg;

endmodule
`resetall
