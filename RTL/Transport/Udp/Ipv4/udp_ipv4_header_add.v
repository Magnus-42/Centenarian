`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_ipv4_header_add.v
// Module Name : udp_ipv4_header_add
// Author      : LiXintao
// Date        : 2026-10-8
// Version     : v2.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，插入 20 字节 IPv4 首部
// Note        : 1. 包内计算IPV4校验值以及长度
//               2. usr 位段 (108bit): [3:0]prio [11:4]ttl [27:12]sport
//                                     [43:28]dport [75:44]src_ip [107:76]dst_ip
// ============================================================================

module udp_ipv4_header_add#(
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

  output wire          [                 511:0]        ipv4_axis_mdata ,
  output wire          [                  63:0]        ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  output wire          [   AXIS_USER_WIDTH-1:0]        ipv4_axis_musr  ,
  input  wire                                          ipv4_axis_mready 
);
  //s1 计算得到header
  //s2 树型计算，计算得到 stge1_add_s2 stge2_reg_s2
  //s3 计算得到 stge3_add_s3 fold1_reg_s3
  //s4 计算得到 fold2_add_s4 checksum_reg_s4
  //s5 reg/skid

  localparam IPV4_HDR_BITS= 160;

  // usr 位段契约(与 udp_ipv4_len_checksum / udp_header_add 保持一致)
  localparam USR_PRIO_LSB = 0  ,
             USR_TTL_LSB  = 4  ,
             USR_SPORT_LSB= 12 ,
             USR_DPORT_LSB= 28 ,
             USR_SIP_LSB  = 44 ,
             USR_DIP_LSB  = 76 ,
             USR_W_MIN    = USR_DIP_LSB + 32; // usr 元数据最小位宽

  initial begin
    if (AXIS_USER_WIDTH < USR_W_MIN) begin
      $display("udp_ipv4_header_add: AXIS_USER_WIDTH(%0d) < %0d, usr 位段越界", AXIS_USER_WIDTH, USR_W_MIN);
    end
  end

  wire                 [                  15:0]        udp_len          = {udp_axis_sdata[39:32],udp_axis_sdata[47:40]};
  wire                 [                  15:0]        ipv4_len_msb     = udp_len + 16'd20;
  wire                 [                  15:0]        ipv4_len         = {ipv4_len_msb[7:0],ipv4_len_msb[15:8]};

  reg                  [                 511:0]        udp_axis_sdata_s1;
  reg                  [                  63:0]        udp_axis_skeep_s1;
  reg                                                  udp_axis_slast_s1;
  reg                                                  udp_axis_svalid_s1;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_susr_s1 ;

  reg                  [                 511:0]        udp_axis_sdata_s2;
  reg                  [                  63:0]        udp_axis_skeep_s2;
  reg                                                  udp_axis_slast_s2;
  reg                                                  udp_axis_svalid_s2;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_susr_s2 ;

  reg                  [                 511:0]        udp_axis_sdata_s3;
  reg                  [                  63:0]        udp_axis_skeep_s3;
  reg                                                  udp_axis_slast_s3;
  reg                                                  udp_axis_svalid_s3;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_susr_s3 ;

  reg                  [                 511:0]        udp_axis_sdata_s4;
  reg                  [                  63:0]        udp_axis_skeep_s4;
  reg                                                  udp_axis_slast_s4;
  reg                                                  udp_axis_svalid_s4;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_susr_s4 ;

  reg                  [                  15:0]        total_len_s1,total_len_s2,total_len_s3,total_len_s4     ;
  reg                  [                   7:0]        ttl_s1,ttl_s2,ttl_s3,ttl_s4           ;
  reg                  [                  31:0]        src_ip_s1,src_ip_s2,src_ip_s3,src_ip_s4        ;
  reg                  [                  31:0]        dest_ip_s1,dest_ip_s2,dest_ip_s3,dest_ip_s4       ;

  // IPv4 头校验和: 总线序 10 个 16bit word 求和(校验和字段置 0) -> 折叠 -> 取反
  wire                 [                 159:0]        ipv4_header_s1      = {dest_ip_s1,src_ip_s1,16'h0000,8'h11,ttl_s1,16'h0040,16'h0000,total_len_s1,8'h00,8'h45};
  wire                 [                  16:0]        stge1_add_s2 [0:4];
  reg                  [                  17:0]        stge2_reg_s2 [0:2];
  wire                 [                  18:0]        stge3_add_s3[0:1];
  reg                  [                  19:0]        stge4_reg_s3;
  wire                 [                  16:0]        fold1_add_s3;
  wire                 [                  16:0]        fold2_add_s3;
  reg                  [                  15:0]        checksum_reg_s4;

  reg                                                  is_first_beat_s4  ;

  reg                  [     IPV4_HDR_BITS-1:0]        data_remain_reg  ;
  reg                  [   IPV4_HDR_BITS/8-1:0]        keep_remain_reg  ;
  reg                  [   AXIS_USER_WIDTH-1:0]        usr_remain_reg;

  reg                  [                 511:0]        ipv4_axis_mdata_reg;
  reg                  [                  63:0]        ipv4_axis_mkeep_reg;
  reg                                                  ipv4_axis_mlast_reg;
  reg                                                  ipv4_axis_mvalid_reg;
  reg                  [   AXIS_USER_WIDTH-1:0]        ipv4_axis_musr_reg;

  reg                  [                 511:0]        ipv4_axis_mdata_skid;
  reg                  [                  63:0]        ipv4_axis_mkeep_skid;
  reg                                                  ipv4_axis_mlast_skid;
  reg                                                  ipv4_axis_mvalid_skid;
  reg                  [   AXIS_USER_WIDTH-1:0]        ipv4_axis_musr_skid;

  reg                                                  is_insert_beat_s1,is_insert_beat_s2,is_insert_beat_s3,is_insert_beat_s4,is_insert_beat_s5;// 末拍高 20 字节含有效数据 ⇒ 还需补发一个插入拍

    
  wire out_reg_free      = !ipv4_axis_mvalid_skid;
  wire insert_en         = is_insert_beat_s5 && out_reg_free        ;
  wire s4_ready = out_reg_free && !is_insert_beat_s5       ;
  wire s3_ready = (!udp_axis_svalid_s4 || s4_ready) && !is_insert_beat_s4;
  wire s2_ready = (!udp_axis_svalid_s3 || s3_ready) && !is_insert_beat_s3;
  wire s1_ready = (!udp_axis_svalid_s2 || s2_ready) && !is_insert_beat_s2;
  assign udp_axis_sready  = (!udp_axis_svalid_s1 || s1_ready) && !is_insert_beat_s1;
  wire                                                 m_handshake       = ipv4_axis_mvalid&& ipv4_axis_mready      ;
  wire                                                 s_handshake       = udp_axis_sready&& udp_axis_svalid        ;
  wire                                                 s1_handshake      = s1_ready&& udp_axis_svalid_s1  ;
  wire                                                 s2_handshake      = s2_ready&& udp_axis_svalid_s2  ;
  wire                                                 s3_handshake      = s3_ready&& udp_axis_svalid_s3  ;
  wire                                                 s4_handshake      = s4_ready&& udp_axis_svalid_s4  ;

  // stge1_add_s2
  assign stge1_add_s2[0] = ipv4_header_s1[ 15:  0] + ipv4_header_s1[ 31: 16];
  assign stge1_add_s2[1] = ipv4_header_s1[ 47: 32] + ipv4_header_s1[ 63: 48];
  assign stge1_add_s2[2] = ipv4_header_s1[ 79: 64] + ipv4_header_s1[ 95: 80];
  assign stge1_add_s2[3] = ipv4_header_s1[111: 96] + ipv4_header_s1[127:112];
  assign stge1_add_s2[4] = ipv4_header_s1[143:128] + ipv4_header_s1[159:144];

  // stge2_reg_s2
  always @(posedge clk) begin
    if (s1_handshake) begin
      stge2_reg_s2[0] <= stge1_add_s2[0] + stge1_add_s2[1];
      stge2_reg_s2[1] <= stge1_add_s2[2] + stge1_add_s2[3];
      stge2_reg_s2[2] <= stge1_add_s2[4];
    end
  end

  // stge3_add_s3
  assign stge3_add_s3[0] = stge2_reg_s2[0] + stge2_reg_s2[1];
  assign stge3_add_s3[1] = stge2_reg_s2[2];

  // stge4_reg_s3
  always @(posedge clk) begin
    if (s2_handshake) begin
      stge4_reg_s3 <= stge3_add_s3[0] + stge3_add_s3[1];
    end
  end

  assign fold1_add_s3            = stge4_reg_s3[15:0] + stge4_reg_s3[19:16];
  assign fold2_add_s3            = {1'b0,fold1_add_s3[15:0]} + {16'd0,fold1_add_s3[16]};

  // checksum_reg_s4
  always @(posedge clk) begin
    if (s3_handshake) begin
      checksum_reg_s4 <= ~fold2_add_s3;
    end
  end

  // s1
  always @(posedge clk) begin
    if (s_handshake) begin
      udp_axis_sdata_s1 <= udp_axis_sdata;
      udp_axis_skeep_s1 <= udp_axis_skeep;
      udp_axis_slast_s1 <= udp_axis_slast;
      udp_axis_susr_s1 <= udp_axis_susr;
      total_len_s1     <= ipv4_len ;
      ttl_s1           <= udp_axis_susr[USR_TTL_LSB +: 8 ];
      src_ip_s1        <= udp_axis_susr[USR_SIP_LSB +: 32];
      dest_ip_s1       <= udp_axis_susr[USR_DIP_LSB +: 32];
    end
  end

  always @(posedge clk) begin
    if (rst)               udp_axis_svalid_s1 <= 1'b0;
    else if (s_handshake)  udp_axis_svalid_s1 <= 1'b1;
    else if (s1_handshake) udp_axis_svalid_s1 <= 1'b0;
  end

  // s2
  always @(posedge clk) begin
    if (s1_handshake) begin
      udp_axis_sdata_s2 <= udp_axis_sdata_s1;
      udp_axis_skeep_s2 <= udp_axis_skeep_s1;
      udp_axis_slast_s2 <= udp_axis_slast_s1;
      udp_axis_susr_s2 <= udp_axis_susr_s1;
      total_len_s2     <= total_len_s1 ;
      ttl_s2           <= ttl_s1;
      src_ip_s2        <= src_ip_s1;
      dest_ip_s2       <= dest_ip_s1;
    end
  end

  always @(posedge clk) begin
    if (rst)               udp_axis_svalid_s2 <= 1'b0;
    else if (s1_handshake)  udp_axis_svalid_s2 <= 1'b1;
    else if (s2_handshake) udp_axis_svalid_s2 <= 1'b0;
  end

  // s3
  always @(posedge clk) begin
    if (s2_handshake) begin
      udp_axis_sdata_s3 <= udp_axis_sdata_s2;
      udp_axis_skeep_s3 <= udp_axis_skeep_s2;
      udp_axis_slast_s3 <= udp_axis_slast_s2;
      udp_axis_susr_s3 <= udp_axis_susr_s2;
      total_len_s3     <= total_len_s2 ;
      ttl_s3           <= ttl_s2;
      src_ip_s3        <= src_ip_s2;
      dest_ip_s3       <= dest_ip_s2;
    end
  end

  always @(posedge clk) begin
    if (rst)               udp_axis_svalid_s3 <= 1'b0;
    else if (s2_handshake) udp_axis_svalid_s3 <= 1'b1;
    else if (s3_handshake) udp_axis_svalid_s3 <= 1'b0;
  end

  // s4
  always @(posedge clk) begin
    if (s3_handshake) begin
      udp_axis_sdata_s4 <= udp_axis_sdata_s3;
      udp_axis_skeep_s4 <= udp_axis_skeep_s3;
      udp_axis_slast_s4 <= udp_axis_slast_s3;
      udp_axis_susr_s4 <= udp_axis_susr_s3;
      total_len_s4     <= total_len_s3 ;
      ttl_s4           <= ttl_s3;
      src_ip_s4        <= src_ip_s3;
      dest_ip_s4       <= dest_ip_s3;
    end
  end

  always @(posedge clk) begin
    if (rst)               udp_axis_svalid_s4 <= 1'b0;
    else if (s3_handshake) udp_axis_svalid_s4 <= 1'b1;
    else if (s4_handshake) udp_axis_svalid_s4 <= 1'b0;
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
      else if (s2_handshake) begin
        is_insert_beat_s2 <= 'd0;
      end
    end
  end

  // is_insert_beat_s3
  always @(posedge clk) begin
    if (rst) begin
      is_insert_beat_s3 <= 'd0;
    end
    else begin
      if (s2_handshake) begin
        is_insert_beat_s3 <= is_insert_beat_s2;
      end
      else if (s3_handshake) begin
        is_insert_beat_s3 <= 'd0;
      end
    end
  end

  // is_insert_beat_s4
  always @(posedge clk) begin
    if (rst) begin
      is_insert_beat_s4 <= 'd0;
    end
    else begin
      if (s3_handshake) begin
        is_insert_beat_s4 <= is_insert_beat_s3;
      end
      else if (s4_handshake) begin
        is_insert_beat_s4 <= 'd0;
      end
    end
  end

  // is_insert_beat_s5
  always @(posedge clk) begin
    if (rst) begin
      is_insert_beat_s5 <= 'd0;
    end
    else begin
      if (s4_handshake) begin
        is_insert_beat_s5 <= is_insert_beat_s4;
      end
      else if (out_reg_free) begin
        is_insert_beat_s5 <= 'd0;
      end
    end
  end

  // is_first_beat_s4
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat_s4 <= 1'b1;                                        // 复位后第一拍视为首拍
    end
    else begin
      if (s4_handshake) begin
        is_first_beat_s4 <= udp_axis_slast_s4;                         // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
      end
    end
  end

  // data_remain_reg
  always @(posedge clk) begin
    if (s4_handshake) begin
      data_remain_reg <= udp_axis_sdata_s4[511-:IPV4_HDR_BITS];
    end
  end

  // keep_remain_reg
  always @(posedge clk) begin
    if (s4_handshake) begin
      keep_remain_reg <= udp_axis_skeep_s4[63-:IPV4_HDR_BITS/8];
    end
  end

  // usr_remain_reg (帧内保持值; insert 拍沿用)
  always @(posedge clk) begin
    if (s4_handshake) begin
      usr_remain_reg <= udp_axis_susr_s4;
    end
  end

  wire reg_can_take = !ipv4_axis_mvalid_reg || ipv4_axis_mready;
  wire skid_to_reg = ipv4_axis_mvalid_skid && reg_can_take;
  wire s4_to_reg = (s4_handshake||insert_en) && reg_can_take;
  wire s4_to_skid = (s4_handshake||insert_en) && (!reg_can_take);

  // ipv4_axis_mdata_reg
  always @(posedge clk) begin
    if (s4_to_reg) begin
      if (insert_en) begin
        ipv4_axis_mdata_reg <= {{(512-IPV4_HDR_BITS){1'b0}},data_remain_reg};
      end
      else if (is_first_beat_s4) begin
        ipv4_axis_mdata_reg <= {udp_axis_sdata_s4[511-IPV4_HDR_BITS:0],dest_ip_s4,src_ip_s4,checksum_reg_s4,8'h11,ttl_s4,16'h0040,16'h0000,total_len_s4,8'h00,8'h45};
      end
      else begin
        ipv4_axis_mdata_reg <= {udp_axis_sdata_s4[511-IPV4_HDR_BITS:0],data_remain_reg};
      end
    end
    else if (skid_to_reg) begin
      ipv4_axis_mdata_reg <= ipv4_axis_mdata_skid;
    end

    if (s4_to_skid) begin
      if (insert_en) begin
        ipv4_axis_mdata_skid <= {{(512-IPV4_HDR_BITS){1'b0}},data_remain_reg};
      end
      else if (is_first_beat_s4) begin
        ipv4_axis_mdata_skid <= {udp_axis_sdata_s4[511-IPV4_HDR_BITS:0],dest_ip_s4,src_ip_s4,checksum_reg_s4,8'h11,ttl_s4,16'h0040,16'h0000,total_len_s4,8'h00,8'h45};
      end
      else begin
        ipv4_axis_mdata_skid <= {udp_axis_sdata_s4[511-IPV4_HDR_BITS:0],data_remain_reg};
      end
    end
  end

  // ipv4_axis_musr_reg
  always @(posedge clk) begin
    if (s4_to_reg) begin
      if (insert_en) begin
        ipv4_axis_musr_reg <= usr_remain_reg;
      end
      else begin
        ipv4_axis_musr_reg <= udp_axis_susr_s4;
      end
    end
    else if (skid_to_reg) begin
      ipv4_axis_musr_reg <= ipv4_axis_musr_skid;
    end

    if (s4_to_skid) begin
      if (insert_en) begin
        ipv4_axis_musr_skid <= usr_remain_reg;
      end
      else begin
        ipv4_axis_musr_skid <= udp_axis_susr_s4;
      end
    end
  end

  // ipv4_axis_mkeep_reg
  always @(posedge clk) begin
    if (s4_to_reg) begin
      if (insert_en) begin
        ipv4_axis_mkeep_reg <= {{(64-IPV4_HDR_BITS/8){1'b0}},keep_remain_reg};
      end
      else if (is_first_beat_s4) begin
        ipv4_axis_mkeep_reg <= {udp_axis_skeep_s4[63-IPV4_HDR_BITS/8:0],{(IPV4_HDR_BITS/8){1'b1}}};
      end
      else begin
        ipv4_axis_mkeep_reg <= {udp_axis_skeep_s4[63-IPV4_HDR_BITS/8:0],keep_remain_reg};
      end
    end
    else if (skid_to_reg) begin
      ipv4_axis_mkeep_reg <= ipv4_axis_mkeep_skid;
    end

    if (s4_to_skid) begin
      if (insert_en) begin
        ipv4_axis_mkeep_skid <= {{(64-IPV4_HDR_BITS/8){1'b0}},keep_remain_reg};
      end
      else if (is_first_beat_s4) begin
        ipv4_axis_mkeep_skid <= {udp_axis_skeep_s4[63-IPV4_HDR_BITS/8:0],{(IPV4_HDR_BITS/8){1'b1}}};
      end
      else begin
        ipv4_axis_mkeep_skid <= {udp_axis_skeep_s4[63-IPV4_HDR_BITS/8:0],keep_remain_reg};
      end
    end
  end

  // ipv4_axis_mlast_reg
  always @(posedge clk) begin
    if (s4_to_reg) begin
      if (insert_en) begin
        ipv4_axis_mlast_reg <= 1'b1;
      end
      else if (!is_insert_beat_s4 && udp_axis_slast_s4) begin
        ipv4_axis_mlast_reg <= 1'b1;
      end
      else begin
        ipv4_axis_mlast_reg <= 1'b0;
      end
    end
    else if (skid_to_reg) begin
      ipv4_axis_mlast_reg <= ipv4_axis_mlast_skid;
    end

    if (s4_to_skid) begin
      if (insert_en) begin
        ipv4_axis_mlast_skid <= 1'b1;
      end
      else if (!is_insert_beat_s4 && udp_axis_slast_s4) begin
        ipv4_axis_mlast_skid <= 1'b1;
      end
      else begin
        ipv4_axis_mlast_skid <= 1'b0;
      end
    end
  end

  // ipv4_axis_mvalid_reg
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_mvalid_reg <= 'd0;
      ipv4_axis_mvalid_skid <= 'd0;
    end
    else begin
      if (s4_to_reg || skid_to_reg) begin
        ipv4_axis_mvalid_reg <= 1'b1;
      end
      else if (m_handshake) begin
        ipv4_axis_mvalid_reg <= 1'b0;
      end

      if (s4_to_skid) begin
        ipv4_axis_mvalid_skid <= 1'b1;
      end
      else if (skid_to_reg) begin
        ipv4_axis_mvalid_skid <= 1'b0;
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
