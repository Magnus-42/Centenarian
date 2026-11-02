`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_eth_rx.v
// Module Name : ipv4_eth_rx
// Author      : LiXintao
// Date        : 2026-09-19
// Version     : v2.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，剥离mac头部，以及去除pading
// Note        ：仅支持上游去除FCS模式
//               对于IPV4 46字节的帧，需要确保ipv4的len字段正确
// 
// ============================================================================

module ipv4_eth_rx#(
  parameter  AXIS_USER_WIDTH= 1 // MAC 层 usr 每通道位宽（帧错误标志）
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511:0]        eth_ipv4_axis_sdata,
  input  wire          [                  63:0]        eth_ipv4_axis_skeep,
  input  wire                                          eth_ipv4_axis_slast,
  input  wire                                          eth_ipv4_axis_svalid,
  input  wire          [AXIS_USER_WIDTH-1:0]           eth_ipv4_axis_susr,
  output wire                                          eth_ipv4_axis_sready,

  output wire          [                 511:0]        ipv4_axis_mdata ,
  output wire          [                  63:0]        ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  output wire          [AXIS_USER_WIDTH-1:0]           ipv4_axis_musr  ,
  input  wire                                          ipv4_axis_mready,

  output wire          [                  47:0]        dest_mac        ,
  output wire          [                  47:0]        src_mac          
);
  reg                  [                 511:0]        eth_ipv4_axis_sdata_s1;
  reg                  [                  63:0]        eth_ipv4_axis_skeep_s1;
  reg                                                  eth_ipv4_axis_slast_s1;
  reg                                                  eth_ipv4_axis_svalid_s1;
  reg                  [AXIS_USER_WIDTH-1:0]           eth_ipv4_axis_susr_s1;

  reg                  [                 511:0]        ipv4_axis_mdata_s2;
  reg                  [                  63:0]        ipv4_axis_mkeep_s2;
  reg                                                  ipv4_axis_mlast_s2;
  reg                                                  ipv4_axis_mvalid_s2;
  reg                  [AXIS_USER_WIDTH-1:0]           ipv4_axis_musr_s2;
  reg                  [                  47:0]        dest_mac_s2     ;
  reg                  [                  47:0]        src_mac_s2      ;

  reg                  [                 511:0]        ipv4_axis_mdata_reg;
  reg                  [                  63:0]        ipv4_axis_mkeep_reg;
  reg                                                  ipv4_axis_mlast_reg;
  reg                                                  ipv4_axis_mvalid_reg;
  reg                  [AXIS_USER_WIDTH-1:0]           ipv4_axis_musr_reg;
  reg                  [                  47:0]        dest_mac_reg     ;
  reg                  [                  47:0]        src_mac_reg      ;
  
  reg                                                  is_first_beat    , is_first_beat_s1, is_first_beat_s2;

  wire                                                 reg_ready         = !ipv4_axis_mvalid_reg || ipv4_axis_mready                                   ; 
  wire                                                 s2_ready          = !ipv4_axis_mvalid_s2 || reg_ready                                           ;
  wire                                                 s1_ready          = !ipv4_axis_mvalid_s2 || s2_ready                                            ;
  assign  eth_ipv4_axis_sready= !eth_ipv4_axis_svalid_s1 || s1_ready;
  
  wire                                                 tail_has_data     = eth_ipv4_axis_slast_s1 && (eth_ipv4_axis_skeep_s1[14] != 1'b0)                ;
  wire                                                 tail_no_data      = eth_ipv4_axis_slast_s1 && (eth_ipv4_axis_skeep_s1[14] == 1'b0)                ;
  wire                                                 s1_handshake      = s1_ready && eth_ipv4_axis_svalid_s1 && (tail_has_data || eth_ipv4_axis_svalid);
  wire                                                 s_handshake       = eth_ipv4_axis_sready&&eth_ipv4_axis_svalid                                    ;
  wire                                                 s2_handshake      = ipv4_axis_mvalid_s2 && s2_ready                                               ;
  wire                                                 m_handshake       = ipv4_axis_mvalid_reg && ipv4_axis_mready                                      ;
  
  reg                  [                  63:0]        frame_keep_s2;
  reg                                                  is_frame_short;
  wire                 [                  15:0]        frame_len = {eth_ipv4_axis_sdata_s1[135:128], eth_ipv4_axis_sdata_s1[143:136]};

  // s1: data keep last
  always @(posedge clk) begin
    if (s_handshake) begin
      eth_ipv4_axis_sdata_s1 <= eth_ipv4_axis_sdata;
      eth_ipv4_axis_skeep_s1 <= eth_ipv4_axis_skeep;
      eth_ipv4_axis_slast_s1 <= eth_ipv4_axis_slast;
      eth_ipv4_axis_susr_s1 <= eth_ipv4_axis_susr;
    end
  end

  // s1: valid
  always @(posedge clk) begin
    if (rst) begin
      eth_ipv4_axis_svalid_s1 <= 1'b0;
    end
    else begin
      if (s_handshake) begin
        eth_ipv4_axis_svalid_s1 <= 1'b1;
      end
      else if (s1_handshake) begin
        eth_ipv4_axis_svalid_s1 <= 1'b0;
      end
    end
  end

  // s2: data keep last
  always @(posedge clk) begin
    if (s1_handshake) begin
      if (eth_ipv4_axis_svalid && eth_ipv4_axis_slast && eth_ipv4_axis_skeep[14] == 0) begin// 提前最后一拍
        ipv4_axis_mdata_s2 <= {eth_ipv4_axis_sdata[111:0],eth_ipv4_axis_sdata_s1[511:112]};
        ipv4_axis_mkeep_s2 <= {eth_ipv4_axis_skeep[13:0],eth_ipv4_axis_skeep_s1[63:14]};
        ipv4_axis_mlast_s2 <= 1'b1;
        ipv4_axis_musr_s2 <= eth_ipv4_axis_susr_s1;
      end
      else if(tail_has_data) begin                                  // 最后一拍
        ipv4_axis_mdata_s2 <= {112'd0,eth_ipv4_axis_sdata_s1[511:112]};
        ipv4_axis_mkeep_s2 <= {14'd0,eth_ipv4_axis_skeep_s1[63:14]};
        ipv4_axis_mlast_s2 <= 1'b1;
        ipv4_axis_musr_s2 <= eth_ipv4_axis_susr_s1;
      end
      else begin
        ipv4_axis_mdata_s2 <= {eth_ipv4_axis_sdata[111:0],eth_ipv4_axis_sdata_s1[511:112]};
        ipv4_axis_mkeep_s2 <= {eth_ipv4_axis_skeep[13:0],eth_ipv4_axis_skeep_s1[63:14]};
        ipv4_axis_mlast_s2 <= 1'b0;
        ipv4_axis_musr_s2 <= eth_ipv4_axis_susr_s1;
      end
    end
  end

  // s2: valid
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_mvalid_s2 <= 1'b0;
    end
    else begin
      if (s1_handshake) begin
        if (tail_no_data) begin
          ipv4_axis_mvalid_s2 <= 1'b0;                             // 末拍无载荷 => 本拍不产生输出
        end
        else begin
          ipv4_axis_mvalid_s2 <= 1'b1;
        end
      end
      else if (s2_handshake) begin
        ipv4_axis_mvalid_s2 <= 1'b0;
      end
    end
  end

  // dest_mac_s2 src_mac_s2
  always @(posedge clk) begin
    if (s1_handshake) begin
      if (is_first_beat_s1) begin                                   // 提前最后一拍
        dest_mac_s2 <= eth_ipv4_axis_sdata_s1[47:0];
        src_mac_s2 <= eth_ipv4_axis_sdata_s1[95:48];
      end
    end
  end

  // frame_keep_s2 is_frame_short
  always @(posedge clk) begin
    if (s1_handshake && is_first_beat_s1) begin
      is_frame_short  <= frame_len <= 16'd46;
      frame_keep_s2 <= (64'd1 << frame_len) - 64'd1;
    end
  end

  wire is_frame_pad = is_frame_short && ipv4_axis_mlast_s2 && ipv4_axis_mkeep_s2[45] && !ipv4_axis_mkeep_s2[46];

  // reg: data keep last
  always @(posedge clk) begin
    if (s2_handshake) begin
      ipv4_axis_mdata_reg <= ipv4_axis_mdata_s2;
      if (is_first_beat_s2) begin
        ipv4_axis_mkeep_reg <= is_frame_pad?frame_keep_s2:ipv4_axis_mkeep_s2;
      end
      else begin
        ipv4_axis_mkeep_reg <= ipv4_axis_mkeep_s2;
      end
      ipv4_axis_mlast_reg <= ipv4_axis_mlast_s2;
      ipv4_axis_musr_reg  <= ipv4_axis_musr_s2;
    end
  end

  // reg: valid
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_mvalid_reg <= 1'b0;
    end
    else begin
      if (s2_handshake) begin
        ipv4_axis_mvalid_reg <= ipv4_axis_mvalid_s2;
      end
      else if (m_handshake) begin
        ipv4_axis_mvalid_reg <= 1'b0;
      end
    end
  end

  // dest_mac_reg src_mac_reg
  always @(posedge clk) begin
    if (s2_handshake) begin
      if (is_first_beat_s2) begin
        dest_mac_reg <= dest_mac_s2;
        src_mac_reg <= src_mac_s2;
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
        is_first_beat <= eth_ipv4_axis_slast;                       // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
      end
    end
  end

  // is_first_beat_s1
  always @(posedge clk) begin
    if (s_handshake) begin
      is_first_beat_s1 <= is_first_beat;
    end
  end

  // is_first_beat_s2
  always @(posedge clk) begin
    if (s1_handshake) begin
      is_first_beat_s2 <= is_first_beat_s1;
    end
  end

  assign  dest_mac         = dest_mac_reg     ;
  assign  src_mac          = src_mac_reg      ;
  assign  ipv4_axis_mdata  = ipv4_axis_mdata_reg;
  assign  ipv4_axis_mkeep  = ipv4_axis_mkeep_reg;
  assign  ipv4_axis_mlast  = ipv4_axis_mlast_reg;
  assign  ipv4_axis_mvalid = ipv4_axis_mvalid_reg;
  assign  ipv4_axis_musr   = ipv4_axis_musr_reg;

endmodule
`resetall
