`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_ipv4_header_add.v
// Module Name : udp_ipv4_header_add
// Author      : LiXintao
// Date        : 2026-10-8
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，添加头部信息
// 
// ============================================================================

module udp_ipv4_header_add#(
  parameter  AXIS_USER_WIDTH= 4 
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511:0]        udp_axis_sdata  ,
  input  wire          [                  63:0]        udp_axis_skeep  ,
  input  wire                                          udp_axis_slast  ,
  input  wire                                          udp_axis_svalid ,
  input  wire          [   AXIS_USER_WIDTH-1:0]        udp_axis_susr   ,
  output wire                                          udp_axis_sready ,

  input  wire          [                  15:0]        cfg_total_len   ,
  input  wire          [                   7:0]        cfg_ttl         ,
  input  wire          [                  15:0]        cfg_head_checksum,
  input  wire          [                  31:0]        cfg_src_ip      ,
  input  wire          [                  31:0]        cfg_dest_ip     ,

  output wire          [                 511:0]        ipv4_axis_mdata ,
  output wire          [                  63:0]        ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  output wire          [   AXIS_USER_WIDTH-1:0]        ipv4_axis_musr  ,
  input  wire                                          ipv4_axis_mready 
);

  localparam IPV4_HDR_BITS= 160;

  reg                  [                 511:0]        udp_axis_sdata_s1;
  reg                  [                  63:0]        udp_axis_skeep_s1;
  reg                                                  udp_axis_slast_s1;
  reg                                                  udp_axis_svalid_s1;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_susr_s1 ;

  reg                  [                  15:0]        total_len_s1     ;
  reg                  [                   7:0]        ttl_s1           ;
  reg                  [                  15:0]        head_checksum_s1 ;
  reg                  [                  31:0]        src_ip_s1        ;
  reg                  [                  31:0]        dest_ip_s1       ;

  reg                                                  is_first_beat    ;

  reg                  [     IPV4_HDR_BITS-1:0]        data_remain_reg  ;
  reg                  [   IPV4_HDR_BITS/8-1:0]        keep_remain_reg  ;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_susr_remain_reg;

  reg                  [                 511:0]        ipv4_axis_mdata_reg;
  reg                  [                  63:0]        ipv4_axis_mkeep_reg;
  reg                                                  ipv4_axis_mlast_reg;
  reg                                                  ipv4_axis_mvalid_reg;
  reg                  [   AXIS_USER_WIDTH-1:0]        ipv4_axis_musr_reg;

  reg                                                  is_insert_beat_s1,is_insert_beat_s2;// 末拍高 20 字节含有效数据 ⇒ 还需补发一个插入拍

    
  wire                                                 out_reg_free      = !ipv4_axis_mvalid_reg || ipv4_axis_mready;
  wire                                                 insert_en         = is_insert_beat_s2 && out_reg_free        ;
  wire                                                 udp_axis_sready_s1 = out_reg_free && !is_insert_beat_s2       ;
  wire                                                 m_handshake       = ipv4_axis_mvalid&& ipv4_axis_mready      ;
  wire                                                 s_handshake       = udp_axis_sready&& udp_axis_svalid        ;
  wire                                                 s1_handshake      = udp_axis_sready_s1&& udp_axis_svalid_s1  ;
  assign  udp_axis_sready  = (!udp_axis_svalid_s1 || udp_axis_sready_s1) && !is_insert_beat_s1;

  always @(posedge clk) begin
    if (s_handshake) begin
      udp_axis_sdata_s1 <= udp_axis_sdata;
      udp_axis_skeep_s1 <= udp_axis_skeep;
      udp_axis_slast_s1 <= udp_axis_slast;
      udp_axis_susr_s1 <= udp_axis_susr;
      total_len_s1     <= cfg_total_len ;
      ttl_s1           <= cfg_ttl       ;
      head_checksum_s1 <= cfg_head_checksum;
      src_ip_s1        <= cfg_src_ip    ;
      dest_ip_s1       <= cfg_dest_ip   ;
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
        is_insert_beat_s1 <= udp_axis_slast ? udp_axis_skeep[63-:IPV4_HDR_BITS/8] != 'd0 : 'd0;
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
      data_remain_reg <= udp_axis_sdata_s1[511-:IPV4_HDR_BITS];
    end
  end

  // keep_remain_reg
  always @(posedge clk) begin
    if (s1_handshake) begin
      keep_remain_reg <= udp_axis_skeep_s1[63-:IPV4_HDR_BITS/8];
    end
  end

  // udp_axis_susr_remain_reg (帧内保持值; insert 拍沿用)
  always @(posedge clk) begin
    if (s1_handshake) begin
      udp_axis_susr_remain_reg <= udp_axis_susr_s1;
    end
  end

  // ipv4_axis_mdata_reg
  always @(posedge clk) begin
    if (insert_en) begin
      ipv4_axis_mdata_reg <= {{(512-IPV4_HDR_BITS){1'b0}},data_remain_reg};
    end
    else if (s1_handshake && is_first_beat) begin
      ipv4_axis_mdata_reg <= {udp_axis_sdata_s1[511-IPV4_HDR_BITS:0],dest_ip_s1,src_ip_s1,head_checksum_s1,8'h11,ttl_s1,16'h0040,16'h0000,total_len_s1,8'h00,8'h45};
    end
    else if (s1_handshake) begin
      ipv4_axis_mdata_reg <= {udp_axis_sdata_s1[511-IPV4_HDR_BITS:0],data_remain_reg};
    end
  end

  // ipv4_axis_musr_reg
  always @(posedge clk) begin
    if (insert_en) begin
      ipv4_axis_musr_reg <= udp_axis_susr_remain_reg;
    end
    else if (s1_handshake) begin
      ipv4_axis_musr_reg <= udp_axis_susr_s1;
    end
  end

  // ipv4_axis_mkeep_reg
  always @(posedge clk) begin
    if (insert_en) begin
      ipv4_axis_mkeep_reg <= {{(64-IPV4_HDR_BITS/8){1'b0}},keep_remain_reg};
    end
    else if (s1_handshake && is_first_beat) begin
      ipv4_axis_mkeep_reg <= {udp_axis_skeep_s1[63-IPV4_HDR_BITS/8:0],{(IPV4_HDR_BITS/8){1'b1}}};
    end
    else if (s1_handshake) begin
      ipv4_axis_mkeep_reg <= {udp_axis_skeep_s1[63-IPV4_HDR_BITS/8:0],keep_remain_reg};
    end
  end

  // ipv4_axis_mlast_reg
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_mlast_reg <= 'd0;
    end
    else begin
      if (insert_en) begin
        ipv4_axis_mlast_reg <= 1'b1;
      end
      else if (s1_handshake && !is_insert_beat_s1 && udp_axis_slast_s1) begin
        ipv4_axis_mlast_reg <= 1'b1;
      end
      else if(m_handshake) begin
        ipv4_axis_mlast_reg <= 1'b0;
      end
    end
  end

  // ipv4_axis_mvalid_reg
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_mvalid_reg <= 'd0;
    end
    else begin
      if (s1_handshake || is_insert_beat_s2) begin
        ipv4_axis_mvalid_reg <= 1'b1;
      end
      else if (m_handshake) begin
        ipv4_axis_mvalid_reg <= 1'b0;
      end
    end
  end

  assign  ipv4_axis_mdata  = ipv4_axis_mdata_reg;
  assign  ipv4_axis_mkeep  = ipv4_axis_mkeep_reg;
  assign  ipv4_axis_mlast  = ipv4_axis_mlast_reg;
  assign  ipv4_axis_mvalid = ipv4_axis_mvalid_reg;
  assign  ipv4_axis_musr   = ipv4_axis_musr_reg;

endmodule
`resetall
