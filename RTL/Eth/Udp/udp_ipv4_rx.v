`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_ipv4_rx.v
// Module Name : udp_ipv4_rx
// Author      : LiXintao
// Date        : 2026-10-8
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，剥离ipv4头部
// 
// ============================================================================

module udp_ipv4_rx(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511:0]        ipv4_axis_sdata ,
  input  wire          [                  63:0]        ipv4_axis_skeep ,
  input  wire                                          ipv4_axis_slast ,
  input  wire                                          ipv4_axis_svalid,
  input  wire          [                  96:0]        ipv4_axis_susr  ,
  output wire                                          ipv4_axis_sready,

  output wire          [                 511:0]        udp_axis_mdata  ,
  output wire          [                  63:0]        udp_axis_mkeep  ,
  output wire                                          udp_axis_mlast  ,
  output wire                                          udp_axis_mvalid ,
  output wire          [                  96:0]        udp_axis_musr   ,
  input  wire                                          udp_axis_mready ,

  output wire          [                   7:0]        protocol        ,
  output wire          [                  15:0]        total_len       ,
  output wire          [                   7:0]        ttl             ,
  output wire          [                  31:0]        src_ip          ,
  output wire          [                  31:0]        dest_ip         ,

  output wire                                          stat_is_df       // 禁止分片
);

  reg                  [                 511:0]        ipv4_axis_sdata_s1;
  reg                  [                  63:0]        ipv4_axis_skeep_s1;
  reg                                                  ipv4_axis_slast_s1;
  reg                                                  ipv4_axis_svalid_s1;
  reg                  [                  96:0]        ipv4_axis_susr_s1;

  reg                  [                 511:0]        udp_axis_mdata_reg;
  reg                  [                  63:0]        udp_axis_mkeep_reg;
  reg                                                  udp_axis_mlast_reg;
  reg                                                  udp_axis_mvalid_reg;
  reg                  [                  96:0]        udp_axis_musr_reg;

  reg                  [                   7:0]        protocol_reg     ;
  reg                  [                  15:0]        total_len_reg    ;
  reg                  [                   7:0]        ttl_reg          ;
  reg                  [                  31:0]        src_ip_reg       ;
  reg                  [                  31:0]        dest_ip_reg      ;

  reg                                                  is_df_reg        ;// 禁止分片

  reg                                                  is_first_beat    , is_first_beat_s1;

  wire                                                 reg_ready         = !udp_axis_mvalid_reg||udp_axis_mready                              ;
  wire                                                 s1_ready          = !udp_axis_mvalid_reg||reg_ready                                    ;
  assign  ipv4_axis_sready = !ipv4_axis_svalid_s1 || s1_ready;

  wire                                                 tail_has_data     = ipv4_axis_slast_s1&&(ipv4_axis_skeep_s1[20]!= 1'b0)                ;
  wire                                                 tail_no_data      = ipv4_axis_slast_s1&&(ipv4_axis_skeep_s1[20]== 1'b0)                ;
  wire                                                 s1_handshake      = s1_ready&&ipv4_axis_svalid_s1&& (tail_has_data || ipv4_axis_svalid);// 同时监听第一拍存在数据
  wire                                                 s_handshake       = ipv4_axis_sready&&ipv4_axis_svalid                                 ;
  wire                                                 m_handshake       = udp_axis_mready&&udp_axis_mvalid                                   ;

  // ipv4_axis_svalid_s1
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_svalid_s1 <= 'd0;
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
      ipv4_axis_sdata_s1  <= ipv4_axis_sdata;
      ipv4_axis_skeep_s1  <= ipv4_axis_skeep;
      ipv4_axis_slast_s1  <= ipv4_axis_slast;
      ipv4_axis_susr_s1   <= ipv4_axis_susr;
    end
  end

  // reg: data keep last
  always @(posedge clk) begin
    if (s1_handshake) begin
      if (ipv4_axis_svalid && ipv4_axis_slast && ipv4_axis_skeep[20] == 0) begin// 提前最后一拍
        udp_axis_mdata_reg <= {ipv4_axis_sdata[159:0],ipv4_axis_sdata_s1[511:160]};
        udp_axis_mkeep_reg <= {ipv4_axis_skeep[19:0],ipv4_axis_skeep_s1[63:20]};
        udp_axis_mlast_reg <= 1'b1;
        udp_axis_musr_reg  <= ipv4_axis_susr_s1;
      end
      else if(tail_has_data) begin                                  // 最后一拍
        udp_axis_mdata_reg <= {160'd0,ipv4_axis_sdata_s1[511:160]};
        udp_axis_mkeep_reg <= {20'd0,ipv4_axis_skeep_s1[63:20]};
        udp_axis_mlast_reg <= 1'b1;
        udp_axis_musr_reg  <= ipv4_axis_susr_s1;
      end
      else begin
        udp_axis_mdata_reg <= {ipv4_axis_sdata[159:0],ipv4_axis_sdata_s1[511:160]};
        udp_axis_mkeep_reg <= {ipv4_axis_skeep[19:0],ipv4_axis_skeep_s1[63:20]};
        udp_axis_mlast_reg <= 1'b0;
        udp_axis_musr_reg  <= ipv4_axis_susr_s1;
      end
    end
  end

  // reg: valid
  always @(posedge clk) begin
    if (rst) begin
      udp_axis_mvalid_reg <= 1'b0;
    end
    else begin
      if (s1_handshake) begin
        if (tail_no_data) begin
          udp_axis_mvalid_reg <= 1'b0;                              // 末拍无载荷 => 本拍不产生输出
        end
        else begin
          udp_axis_mvalid_reg <= 1'b1;
        end
      end
      else if (m_handshake) begin
        udp_axis_mvalid_reg <= 1'b0;
      end
    end
  end

  // protocol_reg total_len_reg ttl_reg src_ip_reg dest_ip_reg
  always @(posedge clk) begin
    if (s1_handshake) begin
      if (is_first_beat_s1) begin                                   // 提前最后一拍
        protocol_reg <= ipv4_axis_sdata_s1[79:72];
        total_len_reg <= ipv4_axis_sdata_s1[31:16];
        ttl_reg <= ipv4_axis_sdata_s1[71:64];
        src_ip_reg <= ipv4_axis_sdata_s1[127:96];
        dest_ip_reg <= ipv4_axis_sdata_s1[159:128];
      end
    end
  end

  // is_df_reg
  always @(posedge clk) begin
    if (s1_handshake) begin
      if (is_first_beat_s1) begin                                   // 提前最后一拍
        is_df_reg <= ipv4_axis_sdata_s1[54];
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
        is_first_beat <= ipv4_axis_slast;                           // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
      end
    end
  end

  // is_first_beat_s1
  always @(posedge clk) begin
    if (s_handshake) begin
      is_first_beat_s1 <= is_first_beat;
    end
  end

  assign  udp_axis_mdata   = udp_axis_mdata_reg;
  assign  udp_axis_mkeep   = udp_axis_mkeep_reg;
  assign  udp_axis_mlast   = udp_axis_mlast_reg;
  assign  udp_axis_mvalid  = udp_axis_mvalid_reg;
  assign  udp_axis_musr    = udp_axis_musr_reg;
   
  assign  protocol         = protocol_reg     ;
  assign  total_len        = total_len_reg    ;
  assign  ttl              = ttl_reg          ;
  assign  src_ip           = src_ip_reg       ;
  assign  dest_ip          = dest_ip_reg      ;
  assign  stat_is_df       = is_df_reg        ;

endmodule
`resetall
