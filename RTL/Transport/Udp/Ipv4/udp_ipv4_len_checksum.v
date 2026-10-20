`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_ipv4_len_checksum.v
// Module Name : udp_ipv4_len_checksum
// Author      : LiXintao
// Date        : 2026-10-16
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : udp模块长度和校验和的计算
// Note        : 1. total_len / head_checksum 与首拍对齐,并在本包内保持恒定
//               2. total_len / head_checksum 小端序
//               3. 源/目的 IP、源/目的端口取自 udp_axis_susr, 每包独立;
//                  usr 必须包内恒定
//               4. usr 位段 (108bit): [3:0]prio [11:4]ttl [27:12]sport
//                                     [43:28]dport [75:44]src_ip [107:76]dst_ip
// ============================================================================

module udp_ipv4_len_checksum#(
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

  output wire          [                 511:0]        udp_axis_mdata  ,
  output wire          [                  63:0]        udp_axis_mkeep  ,
  output wire                                          udp_axis_mlast  ,
  output wire                                          udp_axis_mvalid ,
  output wire          [   AXIS_USER_WIDTH-1:0]        udp_axis_musr   ,
  input  wire                                          udp_axis_mready ,

  output wire          [                  15:0]        total_len       ,// UDP长度(=8+载荷)
  output wire          [                  15:0]        head_checksum    // UDP校验和(含伪首部)
);
  // usr 位段契约(与 udp_header_add / udp_ipv4_header_add 保持一致)
  localparam USR_PRIO_LSB = 0  ,
             USR_TTL_LSB  = 4  ,
             USR_SPORT_LSB= 12 ,
             USR_DPORT_LSB= 28 ,
             USR_SIP_LSB  = 44 ,
             USR_DIP_LSB  = 76 ,
             USR_W_MIN    = USR_DIP_LSB + 32; // usr 元数据最小位宽

  initial begin
    if (AXIS_USER_WIDTH < USR_W_MIN) begin
      $display("udp_ipv4_len_checksum: AXIS_USER_WIDTH(%0d) < %0d, usr 位段越界", AXIS_USER_WIDTH, USR_W_MIN);
    end
  end

  // 写入
  // s1 计算data掩码，相加stg1~stg2 src_ip_sum dest_ip_sum port_sum
  // s2 相加stg3~stg4 计算 ip_sum type_port_sum
  // s3 相加stg5~stg6 计算出len type_ip_port_sum
  // s4 计算出payload_sum 计算出head_sum
  // s5 计算出total_sum
  // s6 计算出折叠
  // s7 计算出checksum
  // reg 结果

  // 包模式FIFO： 放置数据
  // 同步FIFO ： 放置total_len(32-16bit)+head_checksum(0-15bit)

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

  reg                  [                 511:0]        udp_axis_sdata_s5;
  reg                  [                  63:0]        udp_axis_skeep_s5;
  reg                                                  udp_axis_slast_s5;
  reg                                                  udp_axis_svalid_s5;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_susr_s5 ;

  reg                  [                 511:0]        udp_axis_sdata_s6;
  reg                  [                  63:0]        udp_axis_skeep_s6;
  reg                                                  udp_axis_slast_s6;
  reg                                                  udp_axis_svalid_s6;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_susr_s6 ;

  reg                  [                 511:0]        udp_axis_sdata_s7;
  reg                  [                  63:0]        udp_axis_skeep_s7;
  reg                                                  udp_axis_slast_s7;
  reg                                                  udp_axis_svalid_s7;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_susr_s7 ;

  reg                  [                 511:0]        fifo_axis_sdata_reg;
  reg                  [                  63:0]        fifo_axis_skeep_reg;
  reg                                                  fifo_axis_slast_reg;
  reg                                                  fifo_axis_svalid_reg;
  reg                  [   AXIS_USER_WIDTH-1:0]        fifo_axis_susr_reg;
  wire                                                 fifo_axis_sready ;
  reg                  [                  15:0]        udp_len_reg      ;
  reg                  [                  15:0]        checksum_reg     ;

  reg                  [                 511:0]        fifo_axis_sdata_skid;
  reg                  [                  63:0]        fifo_axis_skeep_skid;
  reg                                                  fifo_axis_slast_skid;
  reg                                                  fifo_axis_svalid_skid;
  reg                  [   AXIS_USER_WIDTH-1:0]        fifo_axis_susr_skid;
  reg                  [                  15:0]        udp_len_skid     ;
  reg                  [                  15:0]        checksum_skid    ;


  wire                                                 fifo_reg_ready    = !fifo_axis_svalid_skid                   ;
  wire                                                 s7_ready          = !fifo_axis_svalid_reg || fifo_reg_ready  ;
  wire                                                 s6_ready          = !udp_axis_svalid_s7 || s7_ready          ;
  wire                                                 s5_ready          = !udp_axis_svalid_s6 || s6_ready          ;
  wire                                                 s4_ready          = !udp_axis_svalid_s5 || s5_ready          ;
  wire                                                 s3_ready          = !udp_axis_svalid_s4 || s4_ready          ;
  wire                                                 s2_ready          = !udp_axis_svalid_s3 || s3_ready          ;
  wire                                                 s1_ready          = !udp_axis_svalid_s2 || s2_ready          ;
  assign  udp_axis_sready  = !udp_axis_svalid_s1 || s1_ready;

  wire                                                 s_handshake       = udp_axis_svalid && udp_axis_sready       ;
  wire                                                 s1_handshake      = udp_axis_svalid_s1 && s1_ready           ;
  wire                                                 s2_handshake      = udp_axis_svalid_s2 && s2_ready           ;
  wire                                                 s3_handshake      = udp_axis_svalid_s3 && s3_ready           ;
  wire                                                 s4_handshake      = udp_axis_svalid_s4 && s4_ready           ;
  wire                                                 s5_handshake      = udp_axis_svalid_s5 && s5_ready           ;
  wire                                                 s6_handshake      = udp_axis_svalid_s6 && s6_ready           ;
  wire                                                 s7_handshake      = udp_axis_svalid_s7 && s7_ready           ;
  wire                                                 rea_handshake     = fifo_axis_svalid_reg && fifo_axis_sready ;

  // len
  reg                  [                  15:0]        udp_len_s3       , udp_len_s4, udp_len_s5, udp_len_s6, udp_len_s7;
  reg                  [                  31:0]        payload_sum_s4   ;
  reg                  [                  31:0]        head_sum_s4      ;
  reg                  [                  31:0]        total_sum_s5     ;
  wire                 [                  16:0]        fold1             = total_sum_s5[15:0] + total_sum_s5[31:16] ;
  wire                 [                  15:0]        fold2             = fold1[15:0] + fold1[16]                  ;
  reg                  [                  15:0]        checksum_fold_s6 ;
  reg                  [                  15:0]        checksum_s7      ;

  reg                                                  is_first_beat    , is_first_beat_s1, is_first_beat_s2, is_first_beat_s3, is_first_beat_s4;
  reg                                                  is_first_beat_s5 , is_first_beat_s6, is_first_beat_s7;
  
  reg                  [                  31:0]        src_ip_sum_s1    ;
  reg                  [                  31:0]        dest_ip_sum_s1   ;
  reg                  [                  31:0]        port_sum_s1      ;
  reg                  [                  31:0]        type_port_sum_s2 ;
  reg                  [                  31:0]        ip_sum_s2        ;
  reg                  [                  31:0]        type_ip_port_sum_s3;

  // 分段树形计算自加
  wire                 [                  15:0]        stg0_masked_raw [0:31];
  reg                  [                  16:0]        stg1_reg_s1    [0:15];

  wire                 [                  17:0]        stg2_add_s2    [0:7];
  reg                  [                  18:0]        stg3_reg_s2    [0:3];

  wire                 [                  19:0]        stg4_add_s3    [0:1];
  reg                  [                  20:0]        stg5_reg_s3      ;


  reg                                                  is_first_fifo_beat, is_first_fifo_beat_s1, is_first_fifo_beat_s2, is_first_fifo_beat_s3 ;
  reg is_first_fifo_beat_skid;

  wire          [                 511:0]        fifo_axis_mdata ;
  wire          [                  63:0]        fifo_axis_mkeep ;
  wire                                          fifo_axis_mvalid;
  wire                                          fifo_axis_mlast ;
  wire                                          fifo_axis_mready;
  wire          [   AXIS_USER_WIDTH-1:0]        fifo_axis_musr  ;
  wire [15:0] fifo_total_len;
  wire [15:0] fifo_head_checksum;

  reg          [                 511:0]        udp_axis_mdata_s1 ;
  reg          [                  63:0]        udp_axis_mkeep_s1 ;
  reg                                          udp_axis_mlast_s1 ;
  reg                                          udp_axis_mvalid_s1;
  reg          [   AXIS_USER_WIDTH-1:0]        udp_axis_musr_s1  ;

  reg          [                 511:0]        udp_axis_mdata_s2 ;
  reg          [                  63:0]        udp_axis_mkeep_s2 ;
  reg                                          udp_axis_mlast_s2 ;
  reg                                          udp_axis_mvalid_s2;
  reg          [   AXIS_USER_WIDTH-1:0]        udp_axis_musr_s2  ;

  reg          [                 511:0]        udp_axis_mdata_s3 ;
  reg          [                  63:0]        udp_axis_mkeep_s3 ;
  reg                                          udp_axis_mlast_s3 ;
  reg                                          udp_axis_mvalid_s3;
  reg          [   AXIS_USER_WIDTH-1:0]        udp_axis_musr_s3  ;

  reg          [                 511:0]        udp_axis_mdata_reg ;
  reg          [                  63:0]        udp_axis_mkeep_reg ;
  reg                                          udp_axis_mlast_reg ;
  reg                                          udp_axis_mvalid_reg;
  reg          [   AXIS_USER_WIDTH-1:0]        udp_axis_musr_reg  ;
  reg [15:0] total_len_reg;
  reg [15:0] head_checksum_reg;

  reg          [                 511:0]        udp_axis_mdata_skid ;
  reg          [                  63:0]        udp_axis_mkeep_skid ;
  reg                                          udp_axis_mlast_skid ;
  reg                                          udp_axis_mvalid_skid;
  reg          [   AXIS_USER_WIDTH-1:0]        udp_axis_musr_skid;
  reg [15:0] total_len_skid;
  reg [15:0] head_checksum_skid;

  wire m_ready = !udp_axis_mvalid_skid;
  wire ms3_ready = !udp_axis_mvalid_reg || m_ready;
  wire ms2_ready = !udp_axis_mvalid_s3 || ms3_ready;
  wire ms1_ready = !udp_axis_mvalid_s2 || ms2_ready;
  assign fifo_axis_mready = !udp_axis_mvalid_s1 || ms1_ready;

  wire m_handshake = udp_axis_mready && udp_axis_mvalid       ;
  wire fifo_handshake = fifo_axis_mready && fifo_axis_mvalid;
  wire ms1_handshake = udp_axis_mvalid_s1 && ms1_ready;
  wire ms2_handshake = udp_axis_mvalid_s2 && ms2_ready;
  wire ms3_handshake = udp_axis_mvalid_s3 && ms3_ready;

  wire mreg_can_take = !udp_axis_mvalid_reg || m_handshake;
  wire mskid_to_reg = udp_axis_mvalid_skid && mreg_can_take;
  wire ms3_to_reg = ms3_handshake && mreg_can_take;
  wire ms3_to_skid = ms3_handshake && !mreg_can_take;

  wire chelen_fifo_rd_en = is_first_fifo_beat && fifo_handshake;
  reg chelen_fifo_rd_en_s1, chelen_fifo_rd_en_s2;
  wire [31:0] chelen_fifo_dout;

  wire buffre_fifo_rd_en = (ms3_to_reg||ms3_to_skid) && is_first_fifo_beat_s3;


  // 根据keep获取有效长度
  function [6:0] keep64_to_byte;
  input                [                  63:0]        keep            ;
  integer                                              i                ;
    begin
        keep64_to_byte = 7'd0;
        for (i = 0; i < 64; i = i + 1) begin
            if (keep[i]) begin
                keep64_to_byte = i + 1;
            end
        end
    end
  endfunction

  // checksum_s7
  always @(posedge clk) begin
    if (s6_handshake && udp_axis_slast_s6) begin
      checksum_s7 <= (checksum_fold_s6 == 16'h0000) ? 16'hFFFF : checksum_fold_s6;
    end
  end

  // checksum_fold_s6
  always @(posedge clk) begin
    if (s5_handshake && udp_axis_slast_s5) begin
      checksum_fold_s6 <= ~fold2;
    end
  end

  // total_sum_s5
  always @(posedge clk) begin
    if (s4_handshake && udp_axis_slast_s4) begin
      total_sum_s5 <= head_sum_s4 + payload_sum_s4;
    end
  end

  // head_sum_s4
  always @(posedge clk) begin
    if (s3_handshake && udp_axis_slast_s3) begin
      head_sum_s4 <= type_ip_port_sum_s3 + {udp_len_s3[7:0], udp_len_s3[15:8], 1'b0};
    end
  end

  // src_ip_sum_s1
  always @(posedge clk) begin
    if (s_handshake && is_first_beat) begin
      src_ip_sum_s1 <= udp_axis_susr[USR_SIP_LSB+16 +: 16] + udp_axis_susr[USR_SIP_LSB +: 16];
    end
  end

  // dest_ip_sum_s1
  always @(posedge clk) begin
    if (s_handshake && is_first_beat) begin
      dest_ip_sum_s1 <= udp_axis_susr[USR_DIP_LSB+16 +: 16] + udp_axis_susr[USR_DIP_LSB +: 16];
    end
  end

  // ip_sum_s2
  always @(posedge clk) begin
    if (s1_handshake && is_first_beat_s1) begin
      ip_sum_s2 <= dest_ip_sum_s1 + src_ip_sum_s1;
    end
  end

  // port_sum_s1 (usr 端口为 16bit, 零扩展成 17bit 与原口径一致)
  always @(posedge clk) begin
    if (s_handshake && is_first_beat) begin
      port_sum_s1 <= {1'b0,udp_axis_susr[USR_SPORT_LSB +: 16]} + {1'b0,udp_axis_susr[USR_DPORT_LSB +: 16]};
    end
  end

  // type_port_sum_s2
  always @(posedge clk) begin
    if (s1_handshake && is_first_beat_s1) begin
      type_port_sum_s2 <= port_sum_s1 + 16'h1100;
    end
  end

  // type_ip_port_sum_s3
  always @(posedge clk) begin
    if (s2_handshake && is_first_beat_s2) begin
      type_ip_port_sum_s3 <= type_port_sum_s2 + ip_sum_s2;
    end
  end

  genvar g_i;
  generate
    // 掩码+阶段1
    for (g_i = 0; g_i < 32; g_i = g_i + 1) begin : GEN_MASK
        assign stg0_masked_raw[g_i] = (udp_axis_skeep[g_i*2 +: 2] == 2'b11) ? udp_axis_sdata[g_i*16 +: 16] :
                                  (udp_axis_skeep[g_i*2 +: 2] == 2'b01) ? {8'h00, udp_axis_sdata[g_i*16 +: 8]} : 16'd0;
    end
    for (g_i = 0; g_i < 16; g_i = g_i + 1) begin : GEN_STG1
      always @(posedge clk) begin
        if (s_handshake) begin
          stg1_reg_s1[g_i] <= stg0_masked_raw[g_i*2] + stg0_masked_raw[g_i*2+1];
        end
      end
    end
    
    // 阶段2+阶段3
    for (g_i = 0; g_i < 8; g_i = g_i + 1) begin : GEN_STG2
  assign  stg2_add_s2[g_i] = stg1_reg_s1[g_i*2] + stg1_reg_s1[g_i*2+1];
    end
    for (g_i = 0; g_i < 4; g_i = g_i + 1) begin : GEN_STG3
      always @(posedge clk) begin
        if (s1_handshake) begin
          stg3_reg_s2[g_i] <= stg2_add_s2[g_i*2] + stg2_add_s2[g_i*2+1];
        end
      end
    end

    // 阶段4+阶段5
    for (g_i = 0; g_i < 2; g_i = g_i + 1) begin : GEN_STG4
  assign  stg4_add_s3[g_i] = stg3_reg_s2[g_i*2] + stg3_reg_s2[g_i*2+1];
    end
    always @(posedge clk) begin
      if (s2_handshake) begin
        stg5_reg_s3 <= stg4_add_s3[0] + stg4_add_s3[1];
      end
    end
  endgenerate

  // payload_sum_s4
  always @(posedge clk) begin
    if (s3_handshake && is_first_beat_s3) begin
      payload_sum_s4 <= stg5_reg_s3;
    end
    else if (s3_handshake) begin
      payload_sum_s4 <= payload_sum_s4 + stg5_reg_s3;
    end
  end

  // udp_len_s3
  always @(posedge clk) begin
    if (s2_handshake && is_first_beat_s2) begin
      udp_len_s3 <= 16'd8 + keep64_to_byte(udp_axis_skeep_s2);
    end
    else if (s2_handshake) begin
      udp_len_s3 <= udp_len_s3 + keep64_to_byte(udp_axis_skeep_s2);
    end
  end

  // is_first_beat
  always @(posedge clk) begin
    if(rst) begin
      is_first_beat <= 1'b1;
    end
    else begin
      if (s_handshake) begin
        is_first_beat <= udp_axis_slast;
      end
    end
  end

  wire                                                 reg_can_take      = !fifo_axis_svalid_reg || fifo_axis_sready;
  wire                                                 skid_to_reg       = reg_can_take && fifo_axis_svalid_skid    ;
  wire                                                 s7_to_reg         = s7_handshake && reg_can_take             ;
  wire                                                 s7_to_skid        = s7_handshake && !reg_can_take            ;

  // fifo_axis_svalid_reg/skid
  always @(posedge clk) begin
    if(rst) begin
      fifo_axis_svalid_reg <= 1'b0;
      fifo_axis_svalid_skid <= 1'b0;
    end
    else begin
      if (s7_to_reg || skid_to_reg) begin
        fifo_axis_svalid_reg <= 1'b1;
      end
      else if (rea_handshake) begin
        fifo_axis_svalid_reg <= 1'b0;
      end

      if (s7_to_skid) begin
        fifo_axis_svalid_skid <= 1'b1;
      end
      else if (skid_to_reg) begin
        fifo_axis_svalid_skid <= 1'b0;
      end
    end
  end

  // reg/skid
  always @(posedge clk) begin
    if (s7_to_reg) begin
      fifo_axis_sdata_reg  <= udp_axis_sdata_s7;
      fifo_axis_skeep_reg  <= udp_axis_skeep_s7;
      fifo_axis_slast_reg  <= udp_axis_slast_s7;
      fifo_axis_susr_reg   <= udp_axis_susr_s7;
      udp_len_reg          <= udp_len_s7;
      checksum_reg         <= checksum_s7;
    end
    else if (skid_to_reg) begin
      fifo_axis_sdata_reg  <= fifo_axis_sdata_skid;
      fifo_axis_skeep_reg  <= fifo_axis_skeep_skid;
      fifo_axis_slast_reg  <= fifo_axis_slast_skid;
      fifo_axis_susr_reg   <= fifo_axis_susr_skid;
      udp_len_reg          <= udp_len_skid;
      checksum_reg         <= checksum_skid;
    end

    if (s7_to_skid) begin
      fifo_axis_sdata_skid <= udp_axis_sdata_s7;
      fifo_axis_skeep_skid <= udp_axis_skeep_s7;
      fifo_axis_slast_skid <= udp_axis_slast_s7;
      fifo_axis_susr_skid <= udp_axis_susr_s7;
      udp_len_skid <= udp_len_s7;
      checksum_skid <= checksum_s7;
    end
  end

  // 流水线
  always @(posedge clk) begin
    if(rst) begin
      udp_axis_svalid_s1 <= 1'b0;
      udp_axis_svalid_s2 <= 1'b0;
      udp_axis_svalid_s3 <= 1'b0;
      udp_axis_svalid_s4 <= 1'b0;
      udp_axis_svalid_s5 <= 1'b0;
      udp_axis_svalid_s6 <= 1'b0;
      udp_axis_svalid_s7 <= 1'b0;
      is_first_beat_s1 <= 1'b0;
      is_first_beat_s2 <= 1'b0;
      is_first_beat_s3 <= 1'b0;
      is_first_beat_s4 <= 1'b0;
      is_first_beat_s5 <= 1'b0;
      is_first_beat_s6 <= 1'b0;
      is_first_beat_s7 <= 1'b0;
    end
    else begin
      if (s_handshake) begin
        udp_axis_svalid_s1 <= 1'b1;
        is_first_beat_s1 <= is_first_beat;
      end
      else if (s1_handshake) begin
        udp_axis_svalid_s1 <= 1'b0;
      end

      if (s1_handshake) begin
        udp_axis_svalid_s2 <= 1'b1;
        is_first_beat_s2 <= is_first_beat_s1;
      end
      else if (s2_handshake) begin
        udp_axis_svalid_s2 <= 1'b0;
      end

      if (s2_handshake) begin
        udp_axis_svalid_s3 <= 1'b1;
        is_first_beat_s3 <= is_first_beat_s2;
      end
      else if (s3_handshake) begin
        udp_axis_svalid_s3 <= 1'b0;
      end

      if (s3_handshake) begin
        udp_axis_svalid_s4 <= 1'b1;
        is_first_beat_s4 <= is_first_beat_s3;
      end
      else if (s4_handshake) begin
        udp_axis_svalid_s4 <= 1'b0;
      end

      if (s4_handshake) begin
        udp_axis_svalid_s5 <= 1'b1;
        is_first_beat_s5 <= is_first_beat_s4;
      end
      else if (s5_handshake) begin
        udp_axis_svalid_s5 <= 1'b0;
      end

      if (s5_handshake) begin
        udp_axis_svalid_s6 <= 1'b1;
        is_first_beat_s6 <= is_first_beat_s5;
      end
      else if (s6_handshake) begin
        udp_axis_svalid_s6 <= 1'b0;
      end

      if (s6_handshake) begin
        udp_axis_svalid_s7 <= 1'b1;
        is_first_beat_s7 <= is_first_beat_s6;
      end
      else if (s7_handshake) begin
        udp_axis_svalid_s7 <= 1'b0;
      end
    end
  end

  // fifo_axis_svalid_reg/skid
  always @(posedge clk) begin
    if(s_handshake) begin
      udp_axis_sdata_s1 <= udp_axis_sdata;
      udp_axis_skeep_s1 <= udp_axis_skeep;
      udp_axis_slast_s1 <= udp_axis_slast;
      udp_axis_susr_s1  <= udp_axis_susr;
    end

    if(s1_handshake) begin
      udp_axis_sdata_s2 <= udp_axis_sdata_s1;
      udp_axis_skeep_s2 <= udp_axis_skeep_s1;
      udp_axis_slast_s2 <= udp_axis_slast_s1;
      udp_axis_susr_s2  <= udp_axis_susr_s1;
    end

    if(s2_handshake) begin
      udp_axis_sdata_s3 <= udp_axis_sdata_s2;
      udp_axis_skeep_s3 <= udp_axis_skeep_s2;
      udp_axis_slast_s3 <= udp_axis_slast_s2;
      udp_axis_susr_s3  <= udp_axis_susr_s2;
    end

    if(s3_handshake) begin
      udp_axis_sdata_s4 <= udp_axis_sdata_s3;
      udp_axis_skeep_s4 <= udp_axis_skeep_s3;
      udp_axis_slast_s4 <= udp_axis_slast_s3;
      udp_axis_susr_s4  <= udp_axis_susr_s3;
      udp_len_s4 <= udp_len_s3;
    end

    if(s4_handshake) begin
      udp_axis_sdata_s5 <= udp_axis_sdata_s4;
      udp_axis_skeep_s5 <= udp_axis_skeep_s4;
      udp_axis_slast_s5 <= udp_axis_slast_s4;
      udp_axis_susr_s5  <= udp_axis_susr_s4;
      udp_len_s5 <= udp_len_s4;
    end

    if(s5_handshake) begin
      udp_axis_sdata_s6 <= udp_axis_sdata_s5;
      udp_axis_skeep_s6 <= udp_axis_skeep_s5;
      udp_axis_slast_s6 <= udp_axis_slast_s5;
      udp_axis_susr_s6  <= udp_axis_susr_s5;
      udp_len_s6<= udp_len_s5;
    end

    if(s6_handshake) begin
      udp_axis_sdata_s7 <= udp_axis_sdata_s6;
      udp_axis_skeep_s7 <= udp_axis_skeep_s6;
      udp_axis_slast_s7 <= udp_axis_slast_s6;
      udp_axis_susr_s7  <= udp_axis_susr_s6;
      udp_len_s7 <= udp_len_s6;
    end
  end

  axis_fifo_sync#(
    .FIFO_DEPTH       (512              ),// 必须写下完整最长的一包数据帧，512*64=32768字节
    .AXIS_WIDTH       (512              ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .AXIS_ID_WIDTH    (1                ),
    .AXIS_DEST_WIDTH  (1                ),
    .PACKET_FIFO      (1                ),
    .FIFO_MEMORY_TYPE ("auto"           ),
    .BRAM_DO_REG      (2                ),
    .DEADLOCK_RISK    (1                ) 
  )
  u_udp_fifo_sync(
    .rst              (rst              ),// (input)
    .clk              (clk              ),// (input)
    // ============================================================================
    // AXI-Stream 从机接口 (上游写)
    // ============================================================================
    .axis_sdata       (fifo_axis_sdata_reg),// (input)// 数据
    .axis_skeep       (fifo_axis_skeep_reg),// (input)// 字节有效标志
    .axis_svalid      (fifo_axis_svalid_reg),// (input)// 数据有效
    .axis_slast       (fifo_axis_slast_reg),// (input)// 包结束标志
    .axis_sready      (fifo_axis_sready ),// (output)// 反压: 还能写入
    .axis_susr        (fifo_axis_susr_reg),// (input)// 用户自定义信息
    .axis_sstrb       ('d0              ),// (input)// 字节选通
    .axis_sid         ('d0              ),// (input)// 流标识
    .axis_sdest       ('d0              ),// (input)// 路由信息
    // ============================================================================
    // AXI-Stream 主机接口 (下游读)
    // ============================================================================
    .axis_mdata       (fifo_axis_mdata ),// (output)// 数据
    .axis_mkeep       (fifo_axis_mkeep ),// (output)// 字节有效标志
    .axis_mvalid      (fifo_axis_mvalid),// (output)// 有数据可读
    .axis_mlast       (fifo_axis_mlast ),// (output)// 包结束标志
    .axis_mready      (fifo_axis_mready),// (input)// 下游能接收
    .axis_musr        (fifo_axis_musr  ),// (output)// 用户自定义信息
    .axis_mstrb       (                 ),// (output)// 字节选通
    .axis_mid         (                 ),// (output)// 流标识
    .axis_mdest       (                 ),// (output)// 路由信息
    // ============================================================================
    // 状态端口
    // ============================================================================
    .prog_empty       (                 ),// (output)// 剩余深度 <= PROG_EMPTY_THRESH
    .prog_full        (                 ),// (output)// 剩余深度 >= PROG_FULL_THRESH
    .empty            (                 ),// (output)// FIFO 空
    .full             (                 ),// (output)// FIFO 满
    .remain_count     (                 ) // (output)// 当前剩余深度 (已写入未读走的字数)
  );

  fifo_sync#(
    .FIFO_DEPTH       (512              ),// 按照最短帧计算，u_udp_fifo_sync能放下的最大的数
    .DATA_WIDTH       (32               ),
    .FIFO_MEMORY_TYPE ("block"          ),
    .BRAM_DO_REG      (2                ) 
  )
  u_chelen_fifo_sync(
    // ============================================================================
    // 时钟与复位
    // ============================================================================
    .rst              (rst              ),// (input)
    .clk              (clk              ),// (input)
    // ============================================================================
    // FIFO 数据接口
    // ============================================================================
    .din              ({udp_len_reg[7:0],udp_len_reg[15:8],checksum_reg}),// (input)
    .wr_en            (fifo_axis_slast_reg && rea_handshake),// (input)
    .rd_en            (chelen_fifo_rd_en),// (input)
    .dout             (chelen_fifo_dout),// (output)
    .full             (                 ),// (output)
    .empty            (                 ),// (output)
    .prog_full        (                 ),// (output)
    .prog_empty       (                 ),// (output)
    .remain_count     (                 ) // (output)
  );

  fifo_sync#(
    .FIFO_DEPTH       (4              ), // 按照流水线级数最大值设定，但需要为2的幂次
    .DATA_WIDTH       (32               ),
    .FIFO_MEMORY_TYPE ("distributed"           )
  )
  u_buffer_fifo_sync(
    // ============================================================================
    // 时钟与复位
    // ============================================================================
    .rst              (rst              ),// (input)
    .clk              (clk              ),// (input)
    // ============================================================================
    // FIFO 数据接口
    // ============================================================================
    .din              (chelen_fifo_dout),// (input)
    .wr_en            (chelen_fifo_rd_en_s2),// (input)
    .rd_en            (buffre_fifo_rd_en),// (input)
    .dout             ({fifo_total_len,fifo_head_checksum}),// (output)
    .full             (                 ),// (output)
    .empty            (                 ),// (output)
    .prog_full        (                 ),// (output)
    .prog_empty       (                 ),// (output)
    .remain_count     (                 ) // (output)
  );


  always @(posedge clk) begin
    if (rst) begin
      udp_axis_mvalid_s1 <= 'd0;
      udp_axis_mvalid_s2 <= 'd0;
      is_first_fifo_beat_s1 <= 'd0;
      is_first_fifo_beat_s2 <= 'd0;
      is_first_fifo_beat_s3 <= 'd0;
    end
    else begin
      if (fifo_handshake) begin
        udp_axis_mvalid_s1 <= 1'b1;
        is_first_fifo_beat_s1 <= is_first_fifo_beat;
      end
      else if (ms1_handshake) begin
        udp_axis_mvalid_s1 <= 1'b0;
      end

      if (ms1_handshake) begin
        udp_axis_mvalid_s2 <= 1'b1;
        is_first_fifo_beat_s2 <= is_first_fifo_beat_s1;
      end
      else if (ms2_handshake) begin
        udp_axis_mvalid_s2 <= 1'b0;
      end

      if (ms2_handshake) begin
        udp_axis_mvalid_s3 <= 1'b1;
        is_first_fifo_beat_s3 <= is_first_fifo_beat_s2;
      end
      else if (ms3_handshake) begin
        udp_axis_mvalid_s3 <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (fifo_handshake) begin
      udp_axis_mdata_s1 <= fifo_axis_mdata ;
      udp_axis_mkeep_s1 <= fifo_axis_mkeep ;
      udp_axis_mlast_s1 <= fifo_axis_mlast;
      udp_axis_musr_s1 <= fifo_axis_musr;
    end

    if (ms1_handshake) begin
      udp_axis_mdata_s2 <= udp_axis_mdata_s1;
      udp_axis_mkeep_s2 <= udp_axis_mkeep_s1;
      udp_axis_mlast_s2 <= udp_axis_mlast_s1;
      udp_axis_musr_s2 <= udp_axis_musr_s1 ;
    end

    if (ms2_handshake) begin
      udp_axis_mdata_s3 <= udp_axis_mdata_s2;
      udp_axis_mkeep_s3 <= udp_axis_mkeep_s2;
      udp_axis_mlast_s3 <= udp_axis_mlast_s2;
      udp_axis_musr_s3 <= udp_axis_musr_s2 ;
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      udp_axis_mvalid_reg <= 'd0;
      udp_axis_mvalid_skid <= 'd0;
    end
    else begin
      if (mskid_to_reg || ms3_to_reg) begin
        udp_axis_mvalid_reg <= 1'b1;
      end
      else if (m_handshake) begin
        udp_axis_mvalid_reg <= 1'b0;
      end

      if (ms3_to_skid) begin
        udp_axis_mvalid_skid <= 1'b1;
      end
      else if (mskid_to_reg) begin
        udp_axis_mvalid_skid <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (mskid_to_reg) begin
      udp_axis_mdata_reg <= udp_axis_mdata_skid ;
      udp_axis_mkeep_reg <= udp_axis_mkeep_skid ;
      udp_axis_mlast_reg <= udp_axis_mlast_skid ;
      udp_axis_musr_reg <=  udp_axis_musr_skid  ;
      if (is_first_fifo_beat_skid) begin
        total_len_reg <= total_len_skid;
        head_checksum_reg <= head_checksum_skid;
      end
    end
    else if (ms3_to_reg) begin
      udp_axis_mdata_reg <= udp_axis_mdata_s3;
      udp_axis_mkeep_reg <= udp_axis_mkeep_s3;
      udp_axis_mlast_reg <= udp_axis_mlast_s3;
      udp_axis_musr_reg  <= udp_axis_musr_s3;
      if (is_first_fifo_beat_s3) begin  
        total_len_reg <= fifo_total_len;
        head_checksum_reg <= fifo_head_checksum;
      end
    end

    if (ms3_to_skid) begin
      udp_axis_mdata_skid <= udp_axis_mdata_s3;
      udp_axis_mkeep_skid <= udp_axis_mkeep_s3;
      udp_axis_mlast_skid <= udp_axis_mlast_s3;
      udp_axis_musr_skid <=  udp_axis_musr_s3;
      if (is_first_fifo_beat_s3) begin
        total_len_skid <= fifo_total_len;
        head_checksum_skid <= fifo_head_checksum;
      end
      is_first_fifo_beat_skid <= is_first_fifo_beat_s3;
    end
  end

  // is_first_fifo_beat
  always @(posedge clk) begin
    if(rst) begin
      is_first_fifo_beat <= 1'b1;
    end
    else begin
      if (fifo_handshake) begin
        is_first_fifo_beat <= fifo_axis_mlast;
      end
    end
  end

  // chelen_fifo_rd_en_s1
  always @(posedge clk) begin
    if(rst) begin
      chelen_fifo_rd_en_s1 <= 'd0;
      chelen_fifo_rd_en_s2 <= 'd0;
    end
    else begin
      chelen_fifo_rd_en_s1 <= chelen_fifo_rd_en;
      chelen_fifo_rd_en_s2 <= chelen_fifo_rd_en_s1;
    end
  end
   
  assign udp_axis_mdata  = udp_axis_mdata_reg ;
  assign udp_axis_mkeep  = udp_axis_mkeep_reg ;
  assign udp_axis_mlast  = udp_axis_mlast_reg ;
  assign udp_axis_mvalid = udp_axis_mvalid_reg;
  assign udp_axis_musr   = udp_axis_musr_reg  ;
  assign total_len = total_len_reg;
  assign head_checksum = head_checksum_reg;

endmodule
`resetall
