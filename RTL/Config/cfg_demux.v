`resetall
`default_nettype none
`timescale 1ns/100ps
`include "cfg_map.vh"

// Language: Verilog 2001
// ============================================================================
// File Name   : cfg_demux.v
// Module Name : cfg_demux
// Author      : LiXintao
// Date        : 2026-10-22
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 配置命令分流, 将上游的 TLV 命令分流到 SET/GET/Error 三个通道
//
// ============================================================================

module cfg_demux#(
  parameter  MAX_VALUE_BYTES= 16,
  localparam MAX_VALUE_BIT= MAX_VALUE_BYTES*8,
  parameter  CMD_USR_WIDTH= 96
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  output  wire                                          frame_rd_en     ,
  input   wire                                          frame_empty     ,
  input   wire          [                   7:0]        rec_op          ,
  input   wire          [                   7:0]        rec_seq         ,
  input   wire          [                   7:0]        rec_item        ,
  input   wire          [                   3:0]        rec_set         ,
  input   wire          [                   3:0]        rec_port        ,
  input   wire          [                   7:0]        rec_len         ,
  input   wire          [     MAX_VALUE_BIT-1:0]        rec_val         ,
  input   wire          [     CMD_USR_WIDTH-1:0]        rec_usr         ,

  input  wire                                          set_ready       ,
  output wire                                          set_valid       ,
  output wire          [                   7:0]        set_op          ,
  output wire          [                   7:0]        set_seq         ,
  output wire          [                   7:0]        set_item        ,
  output wire          [                   3:0]        set_set         ,
  output wire          [                   3:0]        set_port        ,
  output wire          [                   7:0]        set_len         ,
  output wire          [     MAX_VALUE_BIT-1:0]        set_val         ,
  output wire          [     CMD_USR_WIDTH-1:0]        set_usr         ,

  input  wire                                          get_ready       ,
  output wire                                          get_valid       ,
  output wire          [                   7:0]        get_op          ,
  output wire          [                   7:0]        get_seq         ,
  output wire          [                   7:0]        get_item        ,
  output wire          [                   3:0]        get_set         ,
  output wire          [                   3:0]        get_port        ,
  output wire          [                   7:0]        get_len         ,
  output wire          [     MAX_VALUE_BIT-1:0]        get_val         ,
  output wire          [     CMD_USR_WIDTH-1:0]        get_usr         ,

  input  wire                                          error_ready       ,
  output wire                                          error_valid       ,
  output wire          [                   7:0]        error_op          ,
  output wire          [                   7:0]        error_seq         ,
  output wire          [                   7:0]        error_item        ,
  output wire          [                   3:0]        error_set         ,
  output wire          [                   3:0]        error_port        ,
  output wire          [                   7:0]        error_len         ,
  output wire          [     MAX_VALUE_BIT-1:0]        error_val         ,
  output wire          [     CMD_USR_WIDTH-1:0]        error_usr         ,
  output wire          [                   7:0]        error_status        
);

  // 低速，状态机控制
  reg                                          rec_valid_s1         ;
  reg          [                   7:0]        rec_op_s1         ;
  reg          [                   7:0]        rec_seq_s1        ;
  reg          [                   7:0]        rec_item_s1       ;
  reg          [                   3:0]        rec_set_s1        ;
  reg          [                   3:0]        rec_port_s1       ;
  reg          [                   7:0]        rec_len_s1        ;
  reg          [     MAX_VALUE_BIT-1:0]        rec_val_s1        ;
  reg          [     CMD_USR_WIDTH-1:0]        rec_usr_s1        ;


  reg                                          set_valid_reg ;
  reg          [                   7:0]        set_op_reg    ;
  reg          [                   7:0]        set_seq_reg   ;
  reg          [                   7:0]        set_item_reg  ;
  reg          [                   3:0]        set_set_reg   ;
  reg          [                   3:0]        set_port_reg  ;
  reg          [                   7:0]        set_len_reg   ;
  reg          [     MAX_VALUE_BIT-1:0]        set_val_reg   ;
  reg          [     CMD_USR_WIDTH-1:0]        set_usr_reg   ;

  reg                                          get_valid_reg ;
  reg          [                   7:0]        get_op_reg    ;
  reg          [                   7:0]        get_seq_reg   ;
  reg          [                   7:0]        get_item_reg  ;
  reg          [                   3:0]        get_set_reg   ;
  reg          [                   3:0]        get_port_reg  ;
  reg          [                   7:0]        get_len_reg   ;
  reg          [     MAX_VALUE_BIT-1:0]        get_val_reg   ;
  reg          [     CMD_USR_WIDTH-1:0]        get_usr_reg   ;

  reg                                          error_valid_reg ;
  reg          [                   7:0]        error_op_reg    ;
  reg          [                   7:0]        error_seq_reg   ;
  reg          [                   7:0]        error_item_reg  ;
  reg          [                   3:0]        error_set_reg   ;
  reg          [                   3:0]        error_port_reg  ;
  reg          [                   7:0]        error_len_reg   ;
  reg          [     MAX_VALUE_BIT-1:0]        error_val_reg   ;
  reg          [     CMD_USR_WIDTH-1:0]        error_usr_reg   ;
  reg          [                   7:0]        error_status_reg ;
  wire err_reg_ready = !error_valid_reg || error_ready;
  wire set_reg_ready = !set_valid_reg || set_ready;
  wire get_reg_ready = !get_valid_reg || get_ready;
  wire  err_handshake = error_ready && error_valid;
  wire  set_handshake = set_ready && set_valid;
  wire  get_handshake = get_ready && get_valid;

  wire is_reg_to_err;
  wire is_reg_to_set;
  wire is_reg_to_get;

  localparam STATE_WIDTH = 4;

  localparam [STATE_WIDTH-1:0] S_IDLE = 'd0;
  localparam [STATE_WIDTH-1:0] S_READ = 'd1; // 默认上游使用时延为2的BRAM
  localparam [STATE_WIDTH-1:0] S_WAIT_RTR_1 = 'd2;
  localparam [STATE_WIDTH-1:0] S_WAIT_RTR_2 = 'd3;
  localparam [STATE_WIDTH-1:0] S_READ_TO_REG = 'd4;
  localparam [STATE_WIDTH-1:0] S_REG_CHECK = 'd5;
  localparam [STATE_WIDTH-1:0] S_REG_TO_GET = 'd6;
  localparam [STATE_WIDTH-1:0] S_REG_TO_SET = 'd7;
  localparam [STATE_WIDTH-1:0] S_REG_TO_ERROR = 'd8;

  reg [STATE_WIDTH-1:0]  state_reg, state_next;

  reg frame_rd_en_reg;


  always @(posedge clk) begin
    if (rst) begin
      state_reg <= S_IDLE;
    end
    else begin
      state_reg <= state_next;
    end
  end

  always @(*) begin
    state_next = state_reg;

    case (state_reg)
      S_IDLE: begin
        if (!rec_valid_s1 && !frame_empty) begin
          state_next = S_READ;
        end
      end
      S_READ: begin
        state_next = S_WAIT_RTR_1;
      end
      S_WAIT_RTR_1: begin
        state_next = S_WAIT_RTR_2;
      end
      S_WAIT_RTR_2: begin
        state_next = S_READ_TO_REG;
      end
      S_READ_TO_REG: begin
        state_next = S_REG_CHECK;
      end
      S_REG_CHECK: begin
        if (is_reg_to_err &&  err_reg_ready) begin
            state_next = S_REG_TO_ERROR;
        end
        else if (is_reg_to_set &&  set_reg_ready) begin
            state_next = S_REG_TO_SET;
        end
        else if (is_reg_to_get && get_reg_ready) begin
          state_next = S_REG_TO_GET;
        end
      end
      S_REG_TO_GET: begin
        if (get_handshake) begin
          state_next = S_IDLE;
        end
      end
      S_REG_TO_SET: begin
        if (set_handshake) begin
          state_next = S_IDLE;
        end
      end
      S_REG_TO_ERROR :begin
        if (err_handshake) begin
          state_next = S_IDLE;
        end
      end
      default: begin
        state_next = S_IDLE;
      end
    endcase
  end

  // frame_rd_en_reg
  always @(posedge clk) begin
    if (rst) begin
      frame_rd_en_reg <= 'd0;
    end
    else begin
      if (state_reg == S_READ) begin
        frame_rd_en_reg <= 'd1;
      end
      else begin
        frame_rd_en_reg <= 'd0;
      end
    end
  end
  assign frame_rd_en = frame_rd_en_reg;

  // rec_valid_s1
  always @(posedge clk) begin
    if (rst) begin
      rec_valid_s1 <= 'd0;
    end
    else begin
      if (state_reg == S_READ_TO_REG) begin
        rec_valid_s1 <= 'd1;
      end
      else if (state_reg == S_REG_TO_SET || state_reg == S_REG_TO_GET || state_reg == S_REG_TO_ERROR) begin
        rec_valid_s1 <= 'd0;
      end
    end
  end

  // s1 data
  always @(posedge clk) begin
    if (state_reg == S_READ_TO_REG) begin
      rec_op_s1   <= rec_op   ;
      rec_seq_s1  <= rec_seq  ;
      rec_item_s1 <= rec_item ;
      rec_set_s1  <= rec_set  ;
      rec_port_s1 <= rec_port ;
      rec_len_s1  <= rec_len  ;
      rec_val_s1  <= rec_val  ;
      rec_usr_s1  <= rec_usr  ;
    end
  end

  // 判断error
  // 1. 操作码不符
  // 2. item不符
  // 3. 端口超限
  // 4. set超限
  // 5. len超限
  // 6. 写操作但item不可写
  // 7. 读操作但item不可读
  localparam [7:0] OP_SET      = `CFG_OP_SET;
  localparam [7:0] OP_GET      = `CFG_OP_GET;
  localparam [7:0] RW_ETH_TYPE_DICT = `CFG_RW_ETH_TYPE_DICT;
  localparam [7:0] RW_UDP_PORT_RANGE = `CFG_RW_UDP_PORT_RANGE;
  localparam [7:0] RW_PENDING_TIME = `CFG_RW_PENDING_TIME;
  localparam [7:0] RW_ARP_PRIO = `CFG_RW_ARP_PRIO;
  localparam [7:0] RW_ICMP_PRIO = `CFG_RW_ICMP_PRIO;
  localparam [7:0] RW_CMD_UDP_PORT = `CFG_RW_CMD_UDP_PORT;
  localparam [7:0] RW_CMD_UDP_PRIO = `CFG_RW_CMD_UDP_PRIO;
  localparam [7:0] W_RESET_DEF = `CFG_W_RESET_DEF;
  localparam [7:0] W_STAT_CLEAR = `CFG_W_STAT_CLEAR;
  localparam [7:0] R_VERSION = `CFG_R_VERSION;
  localparam [7:0] R_LINK_STATUS = `CFG_R_LINK_STATUS;
  localparam [7:0] R_TX_IDLE = `CFG_R_TX_IDLE;
  localparam [7:0] R_TX_ACTIVE = `CFG_R_TX_ACTIVE;
  localparam [7:0] R_IS_DF = `CFG_R_IS_DF;
  localparam [7:0] R_ARP_STAT = `CFG_R_ARP_STAT;
  localparam [7:0] R_ICMP_STAT = `CFG_R_ICMP_STAT;
  localparam [7:0] R_GEOMETRY = `CFG_R_GEOMETRY;
  localparam [7:0] R_PORT_NUM = `CFG_R_PORT_NUM;

  localparam [7:0] RW_IPV4_LOCAL_IP = `CFG_RW_IPV4_LOCAL_IP;
  localparam [7:0] RW_IPV4_LOCAL_MAC = `CFG_RW_IPV4_LOCAL_MAC;
  localparam [7:0] RW_IPV4_GATEWAY = `CFG_RW_IPV4_GATEWAY;
  localparam [7:0] RW_IPV4_MASK = `CFG_RW_IPV4_MASK;
  localparam [7:0] RW_IPV6_SRC_LOCAL = `CFG_RW_IPV6_SRC_LOCAL;
  localparam [7:0] RW_IPV6_SRC_MAC = `CFG_RW_IPV6_SRC_MAC;
  localparam [7:0] RW_IPV6_DST_LOCAL = `CFG_RW_IPV6_DST_LOCAL;
  localparam [7:0] RW_IPV6_DST_MAC = `CFG_RW_IPV6_DST_MAC;

  localparam [3:0] NUM_PORT = `CFG_NUM_PORT;
  localparam COUNT_WIDTH = `CFG_COUNT_WIDTH;
  localparam [COUNT_WIDTH*NUM_PORT-1:0] DEF_V4_SET_NUM_ARR = `CFG_DEF_V4_SET_NUM_ARR;
  localparam [COUNT_WIDTH*NUM_PORT-1:0] DEF_V6_SRC_NUM_ARR = `CFG_DEF_V6_SRC_NUM_ARR;
  localparam [COUNT_WIDTH*NUM_PORT-1:0] DEF_V6_DST_NUM_ARR = `CFG_DEF_V6_DST_NUM_ARR;
  localparam [COUNT_WIDTH*NUM_PORT-1:0] DEF_MAC_RX_NUM_ARR = `CFG_DEF_MAC_RX_NUM_ARR;
  localparam [COUNT_WIDTH*NUM_PORT-1:0] DEF_IPV4_RX_NUM_ARR = `CFG_DEF_IPV4_RX_NUM_ARR;
  localparam [COUNT_WIDTH*NUM_PORT-1:0] DEF_IPV6_RX_NUM_ARR = `CFG_DEF_IPV6_RX_NUM_ARR;
  localparam [COUNT_WIDTH*NUM_PORT-1:0] DEF_UDP_RX_NUM_ARR = `CFG_DEF_UDP_RX_NUM_ARR;

  localparam [7:0] RW_IPV4_PROTO_DICT = `CFG_RW_IPV4_PROTO_DICT;
  localparam [7:0] RW_IPV6_NH_DICT = `CFG_RW_IPV6_NH_DICT;

  localparam PENDING_TIME_WIDTH_MAX = `CFG_MAX_PENDING_TIME_WIDTH;
  localparam ARBITER_VAL_WIDTH_MAX = `CFG_MAX_ARBITER_VAL_WIDTH;

  // 判断是否错误帧
  wire is_good_op = (rec_op_s1 == OP_SET) || (rec_op_s1 == OP_GET);

  wire is_item_1 = rec_item_s1 <= RW_IPV6_DST_MAC;
  wire is_item_2 = (rec_item_s1 >= RW_ETH_TYPE_DICT) && (rec_item_s1 <= RW_UDP_PORT_RANGE);
  wire is_item_3 = (rec_item_s1 >= RW_PENDING_TIME) && (rec_item_s1 <= RW_CMD_UDP_PRIO);
  wire is_item_4 = (rec_item_s1 >= W_RESET_DEF) && (rec_item_s1 <= W_STAT_CLEAR);
  wire is_item_5 = (rec_item_s1 >= R_VERSION) && (rec_item_s1 <= R_IS_DF);
  wire is_item_6 = (rec_item_s1 >= R_ARP_STAT) && (rec_item_s1 <= R_ICMP_STAT);
  wire is_item_7 = (rec_item_s1 >= R_GEOMETRY) && (rec_item_s1 <= R_PORT_NUM);
  wire is_good_item = is_item_1 || is_item_2 || is_item_3 || is_item_4 || is_item_5 || is_item_6 || is_item_7;

  wire is_ipv4_set = (rec_item_s1 == RW_IPV4_LOCAL_IP || 
      rec_item_s1 == RW_IPV4_LOCAL_MAC || 
      rec_item_s1 == RW_IPV4_GATEWAY || 
      rec_item_s1 == RW_IPV4_MASK) && 
      rec_set_s1 < DEF_V4_SET_NUM_ARR[COUNT_WIDTH*rec_port_s1 +: COUNT_WIDTH];
  wire is_ipv6_src_set = (rec_item_s1 == RW_IPV6_SRC_LOCAL || 
      rec_item_s1 == RW_IPV6_SRC_MAC) && 
      rec_set_s1 < DEF_V6_SRC_NUM_ARR[COUNT_WIDTH*rec_port_s1 +: COUNT_WIDTH];
  wire is_ipv6_dst_set = (rec_item_s1 == RW_IPV6_DST_LOCAL || 
      rec_item_s1 == RW_IPV6_DST_MAC) &&
      rec_set_s1 < DEF_V6_DST_NUM_ARR[COUNT_WIDTH*rec_port_s1 +: COUNT_WIDTH];
  wire is_eth_dict_set = rec_item_s1 == RW_ETH_TYPE_DICT && 
      rec_set_s1 < DEF_MAC_RX_NUM_ARR[COUNT_WIDTH*rec_port_s1 +: COUNT_WIDTH];
  wire is_ipv4_dict_set = rec_item_s1 == RW_IPV4_PROTO_DICT && 
      rec_set_s1 < DEF_IPV4_RX_NUM_ARR[COUNT_WIDTH*rec_port_s1 +: COUNT_WIDTH];
  wire is_ipv6_dict_set = rec_item_s1 == RW_IPV6_NH_DICT && 
      rec_set_s1 < DEF_IPV6_RX_NUM_ARR[COUNT_WIDTH*rec_port_s1 +: COUNT_WIDTH];
  wire is_udp_range_set = rec_item_s1 == RW_UDP_PORT_RANGE && 
      rec_set_s1 < DEF_UDP_RX_NUM_ARR[COUNT_WIDTH*rec_port_s1 +: COUNT_WIDTH];
  wire is_good_set = is_ipv4_set || is_ipv6_src_set || is_ipv6_dst_set || is_eth_dict_set || is_ipv4_dict_set || is_ipv6_dict_set || is_udp_range_set || is_item_3 || is_item_4 || is_item_5 || is_item_6 || is_item_7;

  wire is_good_port = rec_port_s1 < NUM_PORT;

  // 每条 SET 项的值宽度；8'hFF = 不校验（动作/状态/统计/边界类）
  reg [7:0] exp_len;
  always @(*) begin
    case (rec_item_s1)
      RW_IPV4_LOCAL_IP   : exp_len = 8'd4;
      RW_IPV4_LOCAL_MAC  : exp_len = 8'd6;
      RW_IPV4_GATEWAY    : exp_len = 8'd4;
      RW_IPV4_MASK       : exp_len = 8'd4;
      RW_IPV6_SRC_LOCAL  : exp_len = 8'd16;
      RW_IPV6_SRC_MAC    : exp_len = 8'd6;
      RW_IPV6_DST_LOCAL  : exp_len = 8'd16;
      RW_IPV6_DST_MAC    : exp_len = 8'd6;
      RW_ETH_TYPE_DICT   : exp_len = 8'd2;
      RW_IPV4_PROTO_DICT : exp_len = 8'd1;
      RW_IPV6_NH_DICT    : exp_len = 8'd1;
      RW_UDP_PORT_RANGE  : exp_len = 8'd4;
      RW_PENDING_TIME    : exp_len = (PENDING_TIME_WIDTH_MAX + 7) / 8;
      RW_ARP_PRIO        : exp_len = (ARBITER_VAL_WIDTH_MAX  + 7) / 8;
      RW_ICMP_PRIO       : exp_len = (ARBITER_VAL_WIDTH_MAX  + 7) / 8;
      RW_CMD_UDP_PORT    : exp_len = 8'd2;
      RW_CMD_UDP_PRIO    : exp_len = (ARBITER_VAL_WIDTH_MAX  + 7) / 8;
      default            : exp_len = 8'hFF;      // 动作类 0x40~0x43 等：不查
    endcase
  end
  wire is_set_len_ok = (exp_len == 8'hFF) || (rec_len_s1 == exp_len);
  wire is_good_len   = (rec_len_s1 <= MAX_VALUE_BYTES) && (rec_op_s1 != OP_SET || is_set_len_ok);

  wire item_writable = is_item_1 || is_item_2 || is_item_3 || is_item_4;

  wire item_readable = !is_item_4;



  reg [7:0] err_status_code; // 错误状态码

  assign is_reg_to_err = !is_good_op || !is_good_item || !is_good_set || !is_good_port || !is_good_len || (rec_op_s1 == OP_SET && !item_writable) || (rec_op_s1 == OP_GET  && !item_readable);
  assign is_reg_to_set = !is_reg_to_err && rec_op_s1 == OP_SET;
  assign is_reg_to_get = !is_reg_to_err && rec_op_s1 == OP_GET;

  localparam [7:0] ST_BAD_OP = `CFG_ST_BAD_OP;
  localparam [7:0] ST_BAD_ITEM = `CFG_ST_BAD_ITEM;
  localparam [7:0] ST_BAD_SET = `CFG_ST_BAD_SET;
  localparam [7:0] ST_BAD_PORT = `CFG_ST_BAD_PORT;
  localparam [7:0] ST_BAD_LEN = `CFG_ST_BAD_LEN;
  localparam [7:0] ST_WRITE_ONLY = `CFG_ST_WRITE_ONLY;
  localparam [7:0] ST_READ_ONLY = `CFG_ST_READ_ONLY;

  // err_status_code
  always @(posedge clk) begin
    if (rst) begin
      err_status_code <= 'd0;
    end
    else begin
      if (state_reg == S_REG_CHECK) begin
        if (!is_good_op) begin
          err_status_code <= ST_BAD_OP;
        end
        else if (!is_good_item) begin
          err_status_code <= ST_BAD_ITEM;
        end
        else if (!is_good_set) begin
          err_status_code <= ST_BAD_SET;
        end
        else if (!is_good_port) begin
          err_status_code <= ST_BAD_PORT;
        end
        else if (!is_good_len) begin
          err_status_code <= ST_BAD_LEN;
        end
        else if (rec_op_s1 == OP_SET && !item_writable) begin
          err_status_code <= ST_READ_ONLY;
        end
        else if (rec_op_s1 == OP_GET  && !item_readable) begin
          err_status_code <= ST_WRITE_ONLY;
        end
        else begin
          err_status_code <= 'd0;
        end
      end
    end
  end

  // reg valid
  always @(posedge clk) begin
    if (rst) begin
      set_valid_reg   <= 'd0;
      get_valid_reg   <= 'd0;
      error_valid_reg <= 'd0;
    end
    else begin
      if (state_reg == S_REG_TO_ERROR) begin
        error_valid_reg <= ~err_handshake;
      end

      if (state_reg == S_REG_TO_SET) begin
        set_valid_reg <= ~set_handshake;
      end

      if (state_reg == S_REG_TO_GET) begin
        get_valid_reg <= ~get_handshake;
      end
    end
  end

  // reg data
  always @(posedge clk) begin
    if (state_reg == S_REG_TO_ERROR) begin
      error_op_reg   <= rec_op_s1   ;
      error_seq_reg  <= rec_seq_s1  ;
      error_item_reg <= rec_item_s1 ;
      error_set_reg  <= rec_set_s1  ;
      error_port_reg <= rec_port_s1 ;
      error_len_reg  <= rec_len_s1  ;
      error_val_reg  <= rec_val_s1  ;
      error_usr_reg  <= rec_usr_s1  ;
      error_status_reg <= err_status_code;
    end

    if (state_reg == S_REG_TO_SET) begin
      set_op_reg   <= rec_op_s1   ;
      set_seq_reg  <= rec_seq_s1  ;
      set_item_reg <= rec_item_s1 ;
      set_set_reg  <= rec_set_s1  ;
      set_port_reg <= rec_port_s1 ;
      set_len_reg  <= rec_len_s1  ;
      set_val_reg  <= rec_val_s1  ;
      set_usr_reg  <= rec_usr_s1  ;
    end

    if (state_reg == S_REG_TO_GET) begin
      get_op_reg   <= rec_op_s1   ;
      get_seq_reg  <= rec_seq_s1  ;
      get_item_reg <= rec_item_s1 ;
      get_set_reg  <= rec_set_s1  ;
      get_port_reg <= rec_port_s1 ;
      get_len_reg  <= rec_len_s1  ;
      get_val_reg  <= rec_val_s1  ;
      get_usr_reg  <= rec_usr_s1  ;
    end
  end

  assign set_valid   = set_valid_reg;
  assign set_op      = set_op_reg   ;
  assign set_seq     = set_seq_reg  ;
  assign set_item    = set_item_reg ;
  assign set_set     = set_set_reg  ;
  assign set_port    = set_port_reg ;
  assign set_len     = set_len_reg  ;
  assign set_val     = set_val_reg  ;
  assign set_usr     = set_usr_reg  ;

  assign get_valid   = get_valid_reg;
  assign get_op      = get_op_reg   ;
  assign get_seq     = get_seq_reg  ;
  assign get_item    = get_item_reg ;
  assign get_set     = get_set_reg  ;
  assign get_port    = get_port_reg ;
  assign get_len     = get_len_reg  ;
  assign get_val     = get_val_reg  ;
  assign get_usr     = get_usr_reg  ;

  assign error_valid   = error_valid_reg;
  assign error_op      = error_op_reg   ;
  assign error_seq     = error_seq_reg  ;
  assign error_item    = error_item_reg ;
  assign error_set     = error_set_reg  ;
  assign error_port    = error_port_reg ;
  assign error_len     = error_len_reg  ;
  assign error_val     = error_val_reg  ;
  assign error_usr     = error_usr_reg  ;
  assign error_status  = error_status_reg;

endmodule
`resetall
