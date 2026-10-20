`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : icmpv4_type_demux.v
// Module Name : icmpv4_type_demux
// Author      : LiXintao
// Date        : 2026-10-17
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : ICMP 档内两路分流: Echo Request 与其它
// Note        : 1. 首拍同时满足下列条件才判为 echo:
//                  - IPv4 version=4 且 IHL=5
//                  - 非分片(MF=0 且 frag_off=0)
//                  - 首拍至少 24 字节有效(keep[23:0] 全 1)
//                  - ICMP type/code = 8/0
//               2. 任一不满足即归 other(含畸形帧、分片帧)
//               3. 两路各自 reg + skid, 可独立反压
// ============================================================================

module icmpv4_type_demux#(
  parameter  AXIS_USER_WIDTH= 97
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511:0]        ipv4_icmp_axis_sdata ,
  input  wire          [                  63:0]        ipv4_icmp_axis_skeep ,
  input  wire                                          ipv4_icmp_axis_slast ,
  input  wire                                          ipv4_icmp_axis_svalid,
  input  wire          [   AXIS_USER_WIDTH-1:0]        ipv4_icmp_axis_susr  ,
  output wire                                          ipv4_icmp_axis_sready,

  output wire          [                 511:0]        ipv4_echo_axis_mdata ,
  output wire          [                  63:0]        ipv4_echo_axis_mkeep ,
  output wire                                          ipv4_echo_axis_mlast ,
  output wire                                          ipv4_echo_axis_mvalid,
  output wire          [   AXIS_USER_WIDTH-1:0]        ipv4_echo_axis_musr  ,
  input  wire                                          ipv4_echo_axis_mready,

  output wire          [                 511:0]        ipv4_other_axis_mdata ,
  output wire          [                  63:0]        ipv4_other_axis_mkeep ,
  output wire                                          ipv4_other_axis_mlast ,
  output wire                                          ipv4_other_axis_mvalid,
  output wire          [   AXIS_USER_WIDTH-1:0]        ipv4_other_axis_musr  ,
  input  wire                                          ipv4_other_axis_mready
);

  reg                                                  is_first_beat    ;

  reg                  [                 511:0]        ipv4_icmp_axis_sdata_s1;
  reg                  [                  63:0]        ipv4_icmp_axis_skeep_s1;
  reg                                                  ipv4_icmp_axis_slast_s1;
  reg                                                  ipv4_icmp_axis_svalid_s1;
  reg                  [   AXIS_USER_WIDTH-1:0]        ipv4_icmp_axis_susr_s1;

  // echo 通道
  reg                  [                 511:0]        echo_mdata_reg   ;
  reg                  [                  63:0]        echo_mkeep_reg   ;
  reg                                                  echo_mlast_reg   ;
  reg                                                  echo_mvalid_reg  ;
  reg                  [   AXIS_USER_WIDTH-1:0]        echo_musr_reg    ;
  reg                  [                 511:0]        echo_mdata_skid  ;
  reg                  [                  63:0]        echo_mkeep_skid  ;
  reg                                                  echo_mlast_skid  ;
  reg                                                  echo_mvalid_skid ;
  reg                  [   AXIS_USER_WIDTH-1:0]        echo_musr_skid   ;

  // other 通道
  reg                  [                 511:0]        other_mdata_reg  ;
  reg                  [                  63:0]        other_mkeep_reg  ;
  reg                                                  other_mlast_reg  ;
  reg                                                  other_mvalid_reg ;
  reg                  [   AXIS_USER_WIDTH-1:0]        other_musr_reg   ;
  reg                  [                 511:0]        other_mdata_skid ;
  reg                  [                  63:0]        other_mkeep_skid ;
  reg                                                  other_mlast_skid ;
  reg                                                  other_mvalid_skid;
  reg                  [   AXIS_USER_WIDTH-1:0]        other_musr_skid  ;

  wire                                                 is_non_frag      = !ipv4_icmp_axis_sdata[53] && (ipv4_icmp_axis_sdata[52:48]==5'd0) && (ipv4_icmp_axis_sdata[63:56]==8'd0);
  wire                                                 is_echo_type     = (ipv4_icmp_axis_sdata[175:160]==16'h0008);
  wire                                                 sel_echo         = is_non_frag && is_echo_type;
  reg                                                  sel_echo_s1      ;

  wire                                                 s_handshake      = ipv4_icmp_axis_svalid && ipv4_icmp_axis_sready;
  wire                                                 s1_ready         = (sel_echo_s1  && !echo_mvalid_skid) || (!sel_echo_s1 && !other_mvalid_skid);
  wire                                                 s1_handshake     = s1_ready && ipv4_icmp_axis_svalid_s1;
  assign  ipv4_icmp_axis_sready= !ipv4_icmp_axis_svalid_s1 || s1_ready;

  // sel_echo_s1
  always @(posedge clk) begin
    if (rst) begin
      sel_echo_s1 <= 1'b0;
    end
    else begin
      if (s_handshake && is_first_beat) begin
        sel_echo_s1 <= sel_echo;
      end
    end
  end

  // is_first_beat
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;
    end
    else begin
      if (s_handshake) begin
        is_first_beat <= ipv4_icmp_axis_slast;
      end
    end
  end

  // s1: data keep last
  always @(posedge clk) begin
    if (s_handshake) begin
      ipv4_icmp_axis_sdata_s1 <= ipv4_icmp_axis_sdata;
      ipv4_icmp_axis_skeep_s1 <= ipv4_icmp_axis_skeep;
      ipv4_icmp_axis_slast_s1 <= ipv4_icmp_axis_slast;
      ipv4_icmp_axis_susr_s1  <= ipv4_icmp_axis_susr;
    end
  end

  // s1: valid
  always @(posedge clk) begin
    if (rst) begin
      ipv4_icmp_axis_svalid_s1 <= 1'b0;
    end
    else begin
      if (s_handshake) begin
        ipv4_icmp_axis_svalid_s1 <= 1'b1;
      end
      else if (s1_handshake) begin
        ipv4_icmp_axis_svalid_s1 <= 1'b0;
      end
    end
  end

  // --------------------------------------------------------------------------
  // echo 通道
  // --------------------------------------------------------------------------
  wire                                                 echo_m_handshake  = echo_mvalid_reg && ipv4_echo_axis_mready;
  wire                                                 echo_reg_can_take = !echo_mvalid_reg || echo_m_handshake;
  wire                                                 echo_skid_to_reg  = echo_mvalid_skid && echo_reg_can_take;
  wire                                                 echo_s1_to_reg    = s1_handshake && sel_echo_s1 && echo_reg_can_take;
  wire                                                 echo_s1_to_skid   = s1_handshake && sel_echo_s1 && !echo_reg_can_take;

  always @(posedge clk) begin
    if (rst) begin
      echo_mvalid_reg  <= 1'b0;
      echo_mvalid_skid <= 1'b0;
    end
    else begin
      if (echo_skid_to_reg || echo_s1_to_reg) begin
        echo_mvalid_reg <= 1'b1;
      end
      else if (echo_m_handshake) begin
        echo_mvalid_reg <= 1'b0;
      end

      if (echo_s1_to_skid) begin
        echo_mvalid_skid <= 1'b1;
      end
      else if (echo_skid_to_reg) begin
        echo_mvalid_skid <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (echo_skid_to_reg) begin
      echo_mdata_reg <= echo_mdata_skid;
      echo_mkeep_reg <= echo_mkeep_skid;
      echo_mlast_reg <= echo_mlast_skid;
      echo_musr_reg  <= echo_musr_skid;
    end
    else if (echo_s1_to_reg) begin
      echo_mdata_reg <= ipv4_icmp_axis_sdata_s1;
      echo_mkeep_reg <= ipv4_icmp_axis_skeep_s1;
      echo_mlast_reg <= ipv4_icmp_axis_slast_s1;
      echo_musr_reg  <= ipv4_icmp_axis_susr_s1;
    end

    if (echo_s1_to_skid) begin
      echo_mdata_skid <= ipv4_icmp_axis_sdata_s1;
      echo_mkeep_skid <= ipv4_icmp_axis_skeep_s1;
      echo_mlast_skid <= ipv4_icmp_axis_slast_s1;
      echo_musr_skid  <= ipv4_icmp_axis_susr_s1;
    end
  end

  // --------------------------------------------------------------------------
  // other 通道
  // --------------------------------------------------------------------------
  wire                                                 other_m_handshake = other_mvalid_reg && ipv4_other_axis_mready;
  wire                                                 other_reg_can_take= !other_mvalid_reg || other_m_handshake;
  wire                                                 other_skid_to_reg = other_mvalid_skid && other_reg_can_take;
  wire                                                 other_s1_to_reg   = s1_handshake && !sel_echo_s1 && other_reg_can_take;
  wire                                                 other_s1_to_skid  = s1_handshake && !sel_echo_s1 && !other_reg_can_take;

  always @(posedge clk) begin
    if (rst) begin
      other_mvalid_reg  <= 1'b0;
      other_mvalid_skid <= 1'b0;
    end
    else begin
      if (other_skid_to_reg || other_s1_to_reg) begin
        other_mvalid_reg <= 1'b1;
      end
      else if (other_m_handshake) begin
        other_mvalid_reg <= 1'b0;
      end

      if (other_s1_to_skid) begin
        other_mvalid_skid <= 1'b1;
      end
      else if (other_skid_to_reg) begin
        other_mvalid_skid <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (other_skid_to_reg) begin
      other_mdata_reg <= other_mdata_skid;
      other_mkeep_reg <= other_mkeep_skid;
      other_mlast_reg <= other_mlast_skid;
      other_musr_reg  <= other_musr_skid;
    end
    else if (other_s1_to_reg) begin
      other_mdata_reg <= ipv4_icmp_axis_sdata_s1;
      other_mkeep_reg <= ipv4_icmp_axis_skeep_s1;
      other_mlast_reg <= ipv4_icmp_axis_slast_s1;
      other_musr_reg  <= ipv4_icmp_axis_susr_s1;
    end

    if (other_s1_to_skid) begin
      other_mdata_skid <= ipv4_icmp_axis_sdata_s1;
      other_mkeep_skid <= ipv4_icmp_axis_skeep_s1;
      other_mlast_skid <= ipv4_icmp_axis_slast_s1;
      other_musr_skid  <= ipv4_icmp_axis_susr_s1;
    end
  end

  assign  ipv4_echo_axis_mdata  = echo_mdata_reg ;
  assign  ipv4_echo_axis_mkeep  = echo_mkeep_reg ;
  assign  ipv4_echo_axis_mlast  = echo_mlast_reg ;
  assign  ipv4_echo_axis_mvalid = echo_mvalid_reg;
  assign  ipv4_echo_axis_musr   = echo_musr_reg  ;

  assign  ipv4_other_axis_mdata = other_mdata_reg ;
  assign  ipv4_other_axis_mkeep = other_mkeep_reg ;
  assign  ipv4_other_axis_mlast = other_mlast_reg ;
  assign  ipv4_other_axis_mvalid= other_mvalid_reg;
  assign  ipv4_other_axis_musr  = other_musr_reg  ;

endmodule
`resetall
