`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_header_add.v
// Module Name : udp_header_add
// Author      : LiXintao
// Date        : 2026-10-17
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，插入 8 字节 UDP 首部（应用载荷 -> UDP 数据报）
// Note        : 1. 首部字 {校验和[63:48], 长度[47:32], 目的端口[31:16], 源端口[15:0]}
//               2. usr 位段 (108bit): [3:0]prio [11:4]ttl [27:12]sport
//                                     [43:28]dport [75:44]src_ip [107:76]dst_ip
// ============================================================================

module udp_header_add#(
  parameter  AXIS_USER_WIDTH= 108
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511:0]        udp_axis_sdata  ,
  input  wire          [                  63:0]        udp_axis_skeep  ,
  input  wire                                          udp_axis_slast  ,
  input  wire                                          udp_axis_svalid ,
  input  wire          [   AXIS_USER_WIDTH-1:0]        udp_axis_susr   ,
  output wire                                          udp_axis_sready ,

  input  wire          [                  15:0]        pkt_total_len   ,// UDP 长度(=8+载荷), 线序
  input  wire          [                  15:0]        pkt_head_checksum,// UDP 校验和(含伪首部), 线序

  output wire          [                 511:0]        udp_axis_mdata  ,
  output wire          [                  63:0]        udp_axis_mkeep  ,
  output wire                                          udp_axis_mlast  ,
  output wire                                          udp_axis_mvalid ,
  output wire          [   AXIS_USER_WIDTH-1:0]        udp_axis_musr   ,
  input  wire                                          udp_axis_mready 
);

  localparam UDP_HDR_BITS= 64;

  // usr 位段契约(与 udp_ipv4_len_checksum / udp_ipv4_header_add 保持一致)
  localparam USR_PRIO_LSB = 0  ,
             USR_TTL_LSB  = 4  ,
             USR_SPORT_LSB= 12 ,
             USR_DPORT_LSB= 28 ,
             USR_SIP_LSB  = 44 ,
             USR_DIP_LSB  = 76 ,
             USR_W_MIN    = USR_DIP_LSB + 32; // usr 元数据最小位宽

  initial begin
    if (AXIS_USER_WIDTH < USR_W_MIN) begin
      $display("udp_header_add: AXIS_USER_WIDTH(%0d) < %0d, usr 位段越界", AXIS_USER_WIDTH, USR_W_MIN);
    end
  end

  reg                  [                 511:0]        udp_axis_sdata_s1;
  reg                  [                  63:0]        udp_axis_skeep_s1;
  reg                                                  udp_axis_slast_s1;
  reg                                                  udp_axis_svalid_s1;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_susr_s1 ;

  reg                  [                  15:0]        total_len_s1     ;
  reg                  [                  15:0]        head_checksum_s1 ;
  reg                  [                  15:0]        src_port_s1      ;
  reg                  [                  15:0]        dst_port_s1      ;

  reg                                                  is_first_beat    ;

  reg                  [     UDP_HDR_BITS-1:0]         data_remain_reg  ;
  reg                  [   UDP_HDR_BITS/8-1:0]         keep_remain_reg  ;
  reg                  [   AXIS_USER_WIDTH-1:0]        usr_remain_reg;

  reg                  [                 511:0]        udp_axis_mdata_reg;
  reg                  [                  63:0]        udp_axis_mkeep_reg;
  reg                                                  udp_axis_mlast_reg;
  reg                                                  udp_axis_mvalid_reg;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_musr_reg;

  reg                  [                 511:0]        udp_axis_mdata_skid;
  reg                  [                  63:0]        udp_axis_mkeep_skid;
  reg                                                  udp_axis_mlast_skid;
  reg                                                  udp_axis_mvalid_skid;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_musr_skid;

  reg                                                  is_insert_beat_s1,is_insert_beat_s2;// 末拍高 8 字节含有效数据 => 还需补发一个插入拍

  wire                                                 out_reg_free      = !udp_axis_mvalid_skid                    ;
  wire                                                 insert_en         = is_insert_beat_s2 && out_reg_free         ;
  wire                                                 s1_ready          = out_reg_free && !is_insert_beat_s2         ;
  wire                                                 m_handshake       = udp_axis_mvalid && udp_axis_mready        ;
  wire                                                 s_handshake       = udp_axis_sready && udp_axis_svalid        ;
  wire                                                 s1_handshake      = s1_ready && udp_axis_svalid_s1             ;
  assign  udp_axis_sready  = (!udp_axis_svalid_s1 || s1_ready) && !is_insert_beat_s1;

  wire                                                 reg_can_take      = !udp_axis_mvalid_reg || udp_axis_mready   ;
  wire                                                 skid_to_reg       = udp_axis_mvalid_skid && reg_can_take      ;
  wire                                                 s1_to_reg         = (s1_handshake || insert_en) && reg_can_take;
  wire                                                 s1_to_skid        = (s1_handshake || insert_en) && (!reg_can_take);

  always @(posedge clk) begin
    if (s_handshake) begin
      udp_axis_sdata_s1 <= udp_axis_sdata;
      udp_axis_skeep_s1 <= udp_axis_skeep;
      udp_axis_slast_s1 <= udp_axis_slast;
      udp_axis_susr_s1  <= udp_axis_susr;
      total_len_s1      <= pkt_total_len;
      head_checksum_s1  <= pkt_head_checksum;
      src_port_s1       <= udp_axis_susr[USR_SPORT_LSB +: 16];
      dst_port_s1       <= udp_axis_susr[USR_DPORT_LSB +: 16];
    end
  end

  always @(posedge clk) begin
    if (rst)               udp_axis_svalid_s1 <= 1'b0;
    else if (s_handshake)  udp_axis_svalid_s1 <= 1'b1;
    else if (s1_handshake) udp_axis_svalid_s1 <= 1'b0;
  end

  // is_insert_beat_s1
  always @(posedge clk) begin
    if (rst) begin
      is_insert_beat_s1 <= 'd0;
    end
    else begin
      if (s_handshake) begin
        is_insert_beat_s1 <= udp_axis_slast ? udp_axis_skeep[63-:UDP_HDR_BITS/8] != 'd0 : 'd0;
      end
      else if (s1_handshake) begin
        is_insert_beat_s1 <= 'd0;
      end
    end
  end

  // is_insert_beat_s2
  always @(posedge clk) begin
    if (rst) begin
      is_insert_beat_s2 <= 'd0;
    end
    else begin
      if (s1_handshake) begin
        is_insert_beat_s2 <= is_insert_beat_s1;
      end
      else if (insert_en) begin
        is_insert_beat_s2 <= 'd0;
      end
    end
  end

  // is_first_beat
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;                                        // 复位后第一拍视为首拍
    end
    else begin
      if (s1_handshake) begin
        is_first_beat <= udp_axis_slast_s1;                         // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
      end
    end
  end

  // data_remain_reg
  always @(posedge clk) begin
    if (s1_handshake) begin
      data_remain_reg <= udp_axis_sdata_s1[511-:UDP_HDR_BITS];
    end
  end

  // keep_remain_reg
  always @(posedge clk) begin
    if (s1_handshake) begin
      keep_remain_reg <= udp_axis_skeep_s1[63-:UDP_HDR_BITS/8];
    end
  end

  // usr_remain_reg (帧内保持值; insert 拍沿用)
  always @(posedge clk) begin
    if (s1_handshake) begin
      usr_remain_reg <= udp_axis_susr_s1;
    end
  end

  // udp_axis_mdata_reg / udp_axis_mdata_skid
  always @(posedge clk) begin
    if (s1_to_reg) begin
      if (insert_en) begin
        udp_axis_mdata_reg <= {{(512-UDP_HDR_BITS){1'b0}},data_remain_reg};
      end
      else if (is_first_beat) begin
        udp_axis_mdata_reg <= {udp_axis_sdata_s1[511-UDP_HDR_BITS:0],head_checksum_s1,total_len_s1,dst_port_s1,src_port_s1};
      end
      else begin
        udp_axis_mdata_reg <= {udp_axis_sdata_s1[511-UDP_HDR_BITS:0],data_remain_reg};
      end
    end
    else if (skid_to_reg) begin
      udp_axis_mdata_reg <= udp_axis_mdata_skid;
    end

    if (s1_to_skid) begin
      if (insert_en) begin
        udp_axis_mdata_skid <= {{(512-UDP_HDR_BITS){1'b0}},data_remain_reg};
      end
      else if (is_first_beat) begin
        udp_axis_mdata_skid <= {udp_axis_sdata_s1[511-UDP_HDR_BITS:0],head_checksum_s1,total_len_s1,dst_port_s1,src_port_s1};
      end
      else begin
        udp_axis_mdata_skid <= {udp_axis_sdata_s1[511-UDP_HDR_BITS:0],data_remain_reg};
      end
    end
  end

  // udp_axis_musr_reg / udp_axis_musr_skid
  always @(posedge clk) begin
    if (s1_to_reg) begin
      if (insert_en) begin
        udp_axis_musr_reg <= usr_remain_reg;
      end
      else begin
        udp_axis_musr_reg <= udp_axis_susr_s1;
      end
    end
    else if (skid_to_reg) begin
      udp_axis_musr_reg <= udp_axis_musr_skid;
    end

    if (s1_to_skid) begin
      if (insert_en) begin
        udp_axis_musr_skid <= usr_remain_reg;
      end
      else begin
        udp_axis_musr_skid <= udp_axis_susr_s1;
      end
    end
  end

  // udp_axis_mkeep_reg / udp_axis_mkeep_skid
  always @(posedge clk) begin
    if (s1_to_reg) begin
      if (insert_en) begin
        udp_axis_mkeep_reg <= {{(64-UDP_HDR_BITS/8){1'b0}},keep_remain_reg};
      end
      else if (is_first_beat) begin
        udp_axis_mkeep_reg <= {udp_axis_skeep_s1[63-UDP_HDR_BITS/8:0],{(UDP_HDR_BITS/8){1'b1}}};
      end
      else begin
        udp_axis_mkeep_reg <= {udp_axis_skeep_s1[63-UDP_HDR_BITS/8:0],keep_remain_reg};
      end
    end
    else if (skid_to_reg) begin
      udp_axis_mkeep_reg <= udp_axis_mkeep_skid;
    end

    if (s1_to_skid) begin
      if (insert_en) begin
        udp_axis_mkeep_skid <= {{(64-UDP_HDR_BITS/8){1'b0}},keep_remain_reg};
      end
      else if (is_first_beat) begin
        udp_axis_mkeep_skid <= {udp_axis_skeep_s1[63-UDP_HDR_BITS/8:0],{(UDP_HDR_BITS/8){1'b1}}};
      end
      else begin
        udp_axis_mkeep_skid <= {udp_axis_skeep_s1[63-UDP_HDR_BITS/8:0],keep_remain_reg};
      end
    end
  end

  // udp_axis_mlast_reg / udp_axis_mlast_skid
  always @(posedge clk) begin
    if (rst) begin
      udp_axis_mlast_reg  <= 'd0;
      udp_axis_mlast_skid <= 'd0;
    end
    else begin
      if (s1_to_reg) begin
        udp_axis_mlast_reg <= insert_en ? 1'b1 : (!is_insert_beat_s1 && udp_axis_slast_s1);
      end
      else if (skid_to_reg) begin
        udp_axis_mlast_reg <= udp_axis_mlast_skid;
      end
      else if (m_handshake) begin
        udp_axis_mlast_reg <= 1'b0;
      end

      if (s1_to_skid) begin
        udp_axis_mlast_skid <= insert_en ? 1'b1 : (!is_insert_beat_s1 && udp_axis_slast_s1);
      end
    end
  end

  // udp_axis_mvalid_reg / udp_axis_mvalid_skid
  always @(posedge clk) begin
    if (rst) begin
      udp_axis_mvalid_reg  <= 'd0;
      udp_axis_mvalid_skid <= 'd0;
    end
    else begin
      if (s1_to_reg || skid_to_reg) begin
        udp_axis_mvalid_reg <= 1'b1;
      end
      else if (m_handshake) begin
        udp_axis_mvalid_reg <= 1'b0;
      end

      if (s1_to_skid) begin
        udp_axis_mvalid_skid <= 1'b1;
      end
      else if (skid_to_reg) begin
        udp_axis_mvalid_skid <= 1'b0;
      end
    end
  end

  assign  udp_axis_mdata  = udp_axis_mdata_reg;
  assign  udp_axis_mkeep  = udp_axis_mkeep_reg;
  assign  udp_axis_mlast  = udp_axis_mlast_reg;
  assign  udp_axis_mvalid = udp_axis_mvalid_reg;
  assign  udp_axis_musr   = udp_axis_musr_reg;

endmodule
`resetall
