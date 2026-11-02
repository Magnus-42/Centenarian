`resetall
`default_nettype none
`timescale 1ns/100ps
`include "cfg_map.vh"

// Language: Verilog 2001
// ============================================================================
// File Name   : cfg_cmd_top.v
// Module Name : cfg_cmd_top
// Author      : LiXintao
// Date        : 2026-10-26
// Version     : v1.2
// ----------------------------------------------------------------------------
// Description : 配置命令子系统顶层 —— UDP 命令帧 <-> 运行期配置
//
// 数据流：
//   s_axis_cmd_*  --> cfg_cmd_rx --> cfg_demux --+--> cfg_set   --+
//                                                +--> cfg_get   --+--> cfg_reg_bank
//                                                +--> cfg_error
//   三路应答 cfg_set / cfg_get / cfg_error --> axis_n_to_1 --> m_axis_*
// ============================================================================
module cfg_cmd_top #(
  parameter AXIS_WIDTH    = 512,                    // 命令/应答总线位宽（应答侧固定 512）
  parameter MAX_VALUE_BYTES= `CFG_MAX_VALUE_BYTES,  // TLV 值字段最大字节数 (16 = IPv6 地址)
  parameter CALLBACK_MSG  = 1,                      // cfg_set 是否回写应答 (1 = 回写)

  // ---- 命令通道 ----
  parameter [3:0] CMD_PORT_SEL = `CFG_CMD_PORT_SEL, // 命令通道绑定的网口号（必须 < ETH_PORT_NUM）
  parameter UDP_RX_USR_WIDTH = 241,                 // 标准 UDP RX 侧带位宽（s_axis_cmd_usr）
  parameter CMD_USR_WIDTH = 96,                     // 内部请求四元组位宽（不对外）
  parameter UDP_TX_USR_WIDTH = 108,                 // 数据面 UDP TX 元数据位宽
  parameter [7:0] CMD_TTL = 8'd64,                  // 应答固定 TTL

  // ---- 全局 ----
  parameter ETH_PORT_NUM   = `CFG_NUM_PORT,         // 网口数
  parameter CFG_NUM_WIDTH  = `CFG_COUNT_WIDTH,      // 档数/套数计数字段位宽

  // ---- 档数 / 套数上限 (MAX) ----
  parameter [CFG_NUM_WIDTH-1:0] MAC_RX_TYPE_NUM_MAX      = `CFG_MAX_MAC_RX_NUM,
  parameter [CFG_NUM_WIDTH-1:0] MAC_TX_TYPE_NUM_MAX      = `CFG_MAX_MAC_TX_NUM,
  parameter [CFG_NUM_WIDTH-1:0] IPV4_RX_TYPE_NUM_MAX     = `CFG_MAX_IPV4_RX_NUM,
  parameter [CFG_NUM_WIDTH-1:0] IPV4_TX_TYPE_NUM_MAX     = `CFG_MAX_IPV4_TX_NUM,
  parameter [CFG_NUM_WIDTH-1:0] ICMP_TX_TYPE_NUM_MAX     = `CFG_MAX_ICMP_TX_NUM,
  parameter [CFG_NUM_WIDTH-1:0] IPV6_RX_TYPE_NUM_MAX     = `CFG_MAX_IPV6_RX_NUM,
  parameter [CFG_NUM_WIDTH-1:0] IPV6_TX_TYPE_NUM_MAX     = `CFG_MAX_IPV6_TX_NUM,
  parameter [CFG_NUM_WIDTH-1:0] UDP_RX_PORT_NUM_MAX      = `CFG_MAX_UDP_RX_NUM,
  parameter [CFG_NUM_WIDTH-1:0] UDP_TX_PORT_NUM_MAX      = `CFG_MAX_UDP_TX_NUM,
  parameter [CFG_NUM_WIDTH-1:0] LOCAL_IPV4_MAC_NUM_MAX   = `CFG_MAX_V4_SET_NUM,
  parameter [CFG_NUM_WIDTH-1:0] LOCAL_DST_IPV6_MAC_NUM_MAX= `CFG_MAX_V6_DST_SET_NUM,
  parameter [CFG_NUM_WIDTH-1:0] LOCAL_SRC_IPV6_MAC_NUM_MAX= `CFG_MAX_V6_SRC_SET_NUM,
  parameter [CFG_NUM_WIDTH-1:0] PENDING_TIME_WIDTH_MAX   = `CFG_MAX_PENDING_TIME_WIDTH,
  parameter [CFG_NUM_WIDTH-1:0] ARBITER_VAL_WIDTH_MAX    = `CFG_MAX_ARBITER_VAL_WIDTH,

  // ---- 每口实际档数 / 套数 (ARR) ----
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] MAC_RX_TYPE_NUM_ARR      = `CFG_DEF_MAC_RX_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] MAC_TX_TYPE_NUM_ARR      = `CFG_DEF_MAC_TX_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] IPV4_RX_TYPE_NUM_ARR     = `CFG_DEF_IPV4_RX_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] IPV4_TX_TYPE_NUM_ARR     = `CFG_DEF_IPV4_TX_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] ICMP_TX_TYPE_NUM_ARR     = `CFG_DEF_ICMP_TX_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] IPV6_RX_TYPE_NUM_ARR     = `CFG_DEF_IPV6_RX_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] IPV6_TX_TYPE_NUM_ARR     = `CFG_DEF_IPV6_TX_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] UDP_RX_PORT_NUM_ARR      = `CFG_DEF_UDP_RX_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] UDP_TX_PORT_NUM_ARR      = `CFG_DEF_UDP_TX_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] LOCAL_IPV4_MAC_NUM_ARR   = `CFG_DEF_V4_SET_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] LOCAL_DST_IPV6_MAC_NUM_ARR= `CFG_DEF_V6_DST_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] LOCAL_SRC_IPV6_MAC_NUM_ARR= `CFG_DEF_V6_SRC_NUM_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] PENDING_TIME_WIDTH_ARR   = `CFG_DEF_PT_WIDTH_ARR,
  parameter [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] ARBITER_VAL_WIDTH_ARR    = `CFG_DEF_ARB_VAL_WIDTH_ARR,

  // ---- 分流表默认值 ----
  parameter [(MAC_RX_TYPE_NUM_MAX*16)*ETH_PORT_NUM-1:0]  DEF_MAC_RX_TYPE_DICT_ARR  = `CFG_DEF_MAC_RX_DICT_ARR,
  parameter [(IPV4_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0]  DEF_IPV4_RX_TYPE_DICT_ARR = `CFG_DEF_IPV4_RX_DICT_ARR,
  parameter [(IPV6_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0]  DEF_IPV6_RX_TYPE_DICT_ARR = `CFG_DEF_IPV6_RX_DICT_ARR,
  parameter [(UDP_RX_PORT_NUM_MAX*32)*ETH_PORT_NUM-1:0]  DEF_UDP_DST_PORT_RANGE_ARR= `CFG_DEF_UDP_PORT_RANGE_ARR,

  // ---- 地址 / 行为参数默认值 ----
  parameter [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0] DEF_V4_ARR     = { `CFG_DEF_IPV4_IP_P1, `CFG_DEF_IPV4_IP_P0 },
  parameter [48 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0] DEF_MAC_ARR    = { `CFG_DEF_IPV4_MAC_P1, `CFG_DEF_IPV4_MAC_P0 },
  parameter [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0] DEF_GW_ARR     = { `CFG_DEF_IPV4_GW_P1, `CFG_DEF_IPV4_GW_P0 },
  parameter [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0] DEF_MK_ARR     = { `CFG_DEF_IPV4_MASK_P1, `CFG_DEF_IPV4_MASK_P0 },
  parameter [128*LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0] DEF_SRC_V6_ARR = { `CFG_DEF_IPV6_SRC_P1, `CFG_DEF_IPV6_SRC_P0 },
  parameter [48 *LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0] DEF_SRC_MAC_ARR= { `CFG_DEF_IPV6_SRC_MAC_P1, `CFG_DEF_IPV6_SRC_MAC_P0 },
  parameter [128*LOCAL_DST_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0] DEF_DST_V6_ARR = { `CFG_DEF_IPV6_DST_P1, `CFG_DEF_IPV6_DST_P0 },
  parameter [48 *LOCAL_DST_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0] DEF_DST_MAC_ARR= { `CFG_DEF_IPV6_DST_MAC_P1, `CFG_DEF_IPV6_DST_MAC_P0 },
  parameter [PENDING_TIME_WIDTH_MAX*ETH_PORT_NUM-1:0] DEF_PENDING_TIME  = `CFG_DEF_PENDING,
  parameter [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0]  DEF_ARP_PRIORITY  = `CFG_DEF_ARP_PRIO,
  parameter [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0]  DEF_ICMPV4_PRIORITY = `CFG_DEF_ICMP_PRIO,
  parameter [                 16*ETH_PORT_NUM-1:0]  DEF_CMD_UDP_PORT  = `CFG_DEF_CMD_UDP_PORT,
  parameter [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0]  DEF_CMD_UDP_PRIO  = `CFG_DEF_CMD_UDP_PRIO,

  // ---- 内部推导（与 cfg_reg_bank 保持一致）----
  localparam MAC_TX_N_MAX   = (MAC_TX_TYPE_NUM_MAX > 0) ? MAC_TX_TYPE_NUM_MAX : 1,
  localparam MAC_TX_TOT_MAX = MAC_TX_N_MAX + 3,
  localparam TX_IDX_WIDTH   = (MAC_TX_TOT_MAX <= 1) ? 1 : $clog2(MAC_TX_TOT_MAX)
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // ============================================================================
  // 命令输入（UDP RX 载荷，AXI-Stream）
  // ============================================================================
  input  wire          [        AXIS_WIDTH-1:0]        s_axis_cmd_data ,
  input  wire          [      AXIS_WIDTH/8-1:0]        s_axis_cmd_keep ,
  input  wire                                          s_axis_cmd_last ,
  input  wire                                          s_axis_cmd_valid,
  output wire                                          s_axis_cmd_ready,
  input  wire          [ UDP_RX_USR_WIDTH-1:0]         s_axis_cmd_usr  ,

  // ============================================================================
  // 应答输出（UDP TX 载荷，AXI-Stream）
  // ============================================================================
  output wire          [        AXIS_WIDTH-1:0]        m_axis_data     ,
  output wire          [      AXIS_WIDTH/8-1:0]        m_axis_keep     ,
  output wire                                          m_axis_last     ,
  output wire                                          m_axis_valid    ,
  input  wire                                          m_axis_ready    ,
  output wire          [  UDP_TX_USR_WIDTH-1:0]        m_axis_udp_usr  ,

  // ============================================================================
  // 生效配置输出（接数据面 net_stack_top）
  // ============================================================================
  output wire [48 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]    cfg_local_mac      ,
  output wire [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]    cfg_local_ip       ,
  output wire [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]    cfg_gateway_ip     ,
  output wire [32 *LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]    cfg_subnet_mask    ,
  output wire [128*LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_src_ipv6       ,
  output wire [48 *LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_src_mac        ,
  output wire [128*LOCAL_DST_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_dst_ipv6       ,
  output wire [48 *LOCAL_DST_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]cfg_dst_mac        ,
  output wire [16 *MAC_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]       cfg_eth_type       ,
  output wire [8  *IPV4_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]      cfg_ipv4_proto     ,
  output wire [8  *IPV6_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]      cfg_ipv6_nh        ,
  output wire [32 *UDP_RX_PORT_NUM_MAX*ETH_PORT_NUM-1:0]       cfg_udp_port       ,
  output wire [PENDING_TIME_WIDTH_MAX*ETH_PORT_NUM-1:0]        cfg_pending_time   ,
  output wire [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0]         cfg_arp_prio       ,
  output wire [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0]         cfg_icmp_prio      ,
  output wire [16 *ETH_PORT_NUM-1:0]                           cfg_cmd_udp_port   ,
  output wire [    ETH_PORT_NUM-1:0]                           cfg_arp_cache_clear  ,
  output wire [    ETH_PORT_NUM-1:0]                           cfg_arp_pending_clear,
  output wire [    ETH_PORT_NUM-1:0]                           cfg_stat_clear     ,

  // ============================================================================
  // 只读状态输入（接数据面）
  // ============================================================================
  input  wire [         ETH_PORT_NUM-1:0]              stat_link_status ,
  input  wire [         ETH_PORT_NUM-1:0]              stat_tx_idle     ,
  input  wire [TX_IDX_WIDTH*ETH_PORT_NUM-1:0]          stat_tx_active   ,
  input  wire [         ETH_PORT_NUM-1:0]              stat_is_df       ,
  input  wire [       7*ETH_PORT_NUM-1:0]              stat_arp         ,
  input  wire [       4*ETH_PORT_NUM-1:0]              stat_icmp
);

  // ============================================================================
  // 标准 UDP RX 
  // src_ip[160:129] dst_ip[192:161] dst_port[208:193]  src_port[224:209]
  // ============================================================================
  localparam UDP_USR_SRC_IP_LSB    = 129;
  localparam UDP_USR_DST_IP_LSB    = 161;
  localparam UDP_USR_DST_PORT_LSB  = 193;
  localparam UDP_USR_SRC_PORT_LSB  = 209;
  localparam UDP_USR_UDP_LEN_LSB   = 225;

  wire [                   31:0]              cmd_ctrl_ip;
  wire                                        cmd_beat1_drop;
  wire [      CMD_USR_WIDTH-1:0]              cmd_req_usr;

  // 准入判据：请求的目的 IP 必须等于本网口控制地址（只接受发往本机的帧）
  assign cmd_ctrl_ip    = cfg_local_ip[CMD_PORT_SEL*(32*LOCAL_IPV4_MAC_NUM_MAX) +: 32];
  assign cmd_beat1_drop = (s_axis_cmd_usr[UDP_USR_DST_IP_LSB +: 32] != cmd_ctrl_ip);
  assign cmd_req_usr    = { s_axis_cmd_usr[UDP_USR_SRC_IP_LSB   +: 32],
                            s_axis_cmd_usr[UDP_USR_DST_IP_LSB   +: 32],
                            s_axis_cmd_usr[UDP_USR_SRC_PORT_LSB +: 16],
                            s_axis_cmd_usr[UDP_USR_DST_PORT_LSB +: 16] };

  // ============================================================================
  // 内部连线：cfg_cmd_rx -> cfg_demux
  // ============================================================================
  wire                                        rx_frame_rd_en;
  wire                                        rx_frame_empty;
  wire [                    7:0]              rx_op;
  wire [                    7:0]              rx_seq;
  wire [                    7:0]              rx_item;
  wire [                    3:0]              rx_set;
  wire [                    3:0]              rx_port;
  wire [                    7:0]              rx_len;
  wire [      MAX_VALUE_BYTES*8-1:0]          rx_val;
  wire [      CMD_USR_WIDTH-1:0]              rx_usr;

  // ============================================================================
  // 内部连线：cfg_demux -> cfg_set
  // ============================================================================
  wire                                        set_ready;
  wire                                        set_valid;
  wire [                    7:0]              set_op;
  wire [                    7:0]              set_seq;
  wire [                    7:0]              set_item;
  wire [                    3:0]              set_set;
  wire [                    3:0]              set_port;
  wire [                    7:0]              set_len;
  wire [      MAX_VALUE_BYTES*8-1:0]          set_val;
  wire [      CMD_USR_WIDTH-1:0]              set_usr;

  // ============================================================================
  // 内部连线：cfg_demux -> cfg_get
  // ============================================================================
  wire                                        get_ready;
  wire                                        get_valid;
  wire [                    7:0]              get_op;
  wire [                    7:0]              get_seq;
  wire [                    7:0]              get_item;
  wire [                    3:0]              get_set;
  wire [                    3:0]              get_port;
  wire [                    7:0]              get_len;
  wire [      MAX_VALUE_BYTES*8-1:0]          get_val;
  wire [      CMD_USR_WIDTH-1:0]              get_usr;

  // ============================================================================
  // 内部连线：cfg_demux -> cfg_error
  // ============================================================================
  wire                                        error_ready;
  wire                                        error_valid;
  wire [                    7:0]              error_op;
  wire [                    7:0]              error_seq;
  wire [                    7:0]              error_item;
  wire [                    3:0]              error_set;
  wire [                    3:0]              error_port;
  wire [                    7:0]              error_len;
  wire [      MAX_VALUE_BYTES*8-1:0]          error_val;
  wire [      CMD_USR_WIDTH-1:0]              error_usr;
  wire [                    7:0]              error_status;

  // ============================================================================
  // 内部连线：cfg_set -> cfg_reg_bank（写端口）
  // ============================================================================
  wire                                        wr_en;
  wire [                    7:0]              wr_item;
  wire [                    3:0]              wr_set;
  wire [                    3:0]              wr_port;
  wire [      MAX_VALUE_BYTES*8-1:0]          wr_val;

  // ============================================================================
  // 内部连线：cfg_get <-> cfg_reg_bank（读端口）
  // ============================================================================
  wire                                        rd_req;
  wire [                    7:0]              rd_item;
  wire [                    3:0]              rd_set;
  wire [                    3:0]              rd_port;
  wire [                    7:0]              rd_len;
  wire [      MAX_VALUE_BYTES*8-1:0]          rd_val;

  // ============================================================================
  // 内部连线：三路应答 -> axis_n_to_1（端口序 0=error / 1=get / 2=set）
  // ============================================================================
  wire [      AXIS_WIDTH-1:0]                err_mdata;
  wire [    AXIS_WIDTH/8-1:0]                err_mkeep;
  wire                                       err_mlast;
  wire                                       err_mvalid;
  wire                                       err_mready;
  wire [      CMD_USR_WIDTH-1:0]             err_musr;

  wire [      AXIS_WIDTH-1:0]                rd_mdata;
  wire [    AXIS_WIDTH/8-1:0]                rd_mkeep;
  wire                                       rd_mlast;
  wire                                       rd_mvalid;
  wire                                       rd_mready;
  wire [      CMD_USR_WIDTH-1:0]             rd_musr;

  wire [      AXIS_WIDTH-1:0]                cb_mdata;
  wire [    AXIS_WIDTH/8-1:0]                cb_mkeep;
  wire                                       cb_mlast;
  wire                                       cb_mvalid;
  wire                                       cb_mready;
  wire [      CMD_USR_WIDTH-1:0]             cb_musr;

  // 仲裁后的应答侧带
  wire [      CMD_USR_WIDTH-1:0]             rsp_usr;

  // ============================================================================
  // cfg_cmd_rx：命令帧解析，多 TLV 存入 FIFO
  // ============================================================================
  cfg_cmd_rx #(
    .AXIS_WIDTH      (AXIS_WIDTH     ),
    .MAX_VALUE_BYTES (MAX_VALUE_BYTES),
    .CMD_USR_WIDTH   (CMD_USR_WIDTH  )
  ) u_cfg_cmd_rx (
    .clk             (clk            ),
    .rst             (rst            ),
    // 命令输入
    .axis_sdata      (s_axis_cmd_data ),
    .axis_skeep      (s_axis_cmd_keep ),
    .axis_slast      (s_axis_cmd_last ),
    .axis_svalid     (s_axis_cmd_valid),
    .axis_sready     (s_axis_cmd_ready),
    .axis_susr       (cmd_req_usr     ),
    .is_beat1_drop   (cmd_beat1_drop  ),
    // 解析结果 FIFO
    .frame_rd_en     (rx_frame_rd_en ),
    .frame_empty     (rx_frame_empty ),
    .rec_op          (rx_op          ),
    .rec_seq         (rx_seq         ),
    .rec_item        (rx_item        ),
    .rec_set         (rx_set         ),
    .rec_port        (rx_port        ),
    .rec_len         (rx_len         ),
    .rec_val         (rx_val         ),
    .rec_usr         (rx_usr         )
  );

  // ============================================================================
  // cfg_demux：TLV 校验 + 分流到 SET / GET / ERROR 三通道
  // ============================================================================
  cfg_demux #(
    .MAX_VALUE_BYTES (MAX_VALUE_BYTES),
    .CMD_USR_WIDTH   (CMD_USR_WIDTH  )
  ) u_cfg_demux (
    .clk             (clk            ),
    .rst             (rst            ),
    // 上游 FIFO
    .frame_rd_en     (rx_frame_rd_en ),
    .frame_empty     (rx_frame_empty ),
    .rec_op          (rx_op          ),
    .rec_seq         (rx_seq         ),
    .rec_item        (rx_item        ),
    .rec_set         (rx_set         ),
    .rec_port        (rx_port        ),
    .rec_len         (rx_len         ),
    .rec_val         (rx_val         ),
    .rec_usr         (rx_usr         ),
    // SET 通道
    .set_ready       (set_ready      ),
    .set_valid       (set_valid      ),
    .set_op          (set_op         ),
    .set_seq         (set_seq        ),
    .set_item        (set_item       ),
    .set_set         (set_set        ),
    .set_port        (set_port       ),
    .set_len         (set_len        ),
    .set_val         (set_val        ),
    .set_usr         (set_usr        ),
    // GET 通道
    .get_ready       (get_ready      ),
    .get_valid       (get_valid      ),
    .get_op          (get_op         ),
    .get_seq         (get_seq        ),
    .get_item        (get_item       ),
    .get_set         (get_set        ),
    .get_port        (get_port       ),
    .get_len         (get_len        ),
    .get_val         (get_val        ),
    .get_usr         (get_usr        ),
    // ERROR 通道
    .error_ready     (error_ready    ),
    .error_valid     (error_valid    ),
    .error_op        (error_op       ),
    .error_seq       (error_seq      ),
    .error_item      (error_item     ),
    .error_set       (error_set      ),
    .error_port      (error_port     ),
    .error_len       (error_len      ),
    .error_val       (error_val      ),
    .error_usr       (error_usr      ),
    .error_status    (error_status   )
  );

  // ============================================================================
  // cfg_set：SET 命令落库 + 可选回写应答
  // ============================================================================
  cfg_set #(
    .CALLBACK_MSG    (CALLBACK_MSG   ),
    .MAX_VALUE_BYTES (MAX_VALUE_BYTES),
    .CMD_USR_WIDTH   (CMD_USR_WIDTH  )
  ) u_cfg_set (
    .clk                  (clk               ),
    .rst                  (rst               ),
    // TLV 命令
    .rec_valid            (set_valid         ),
    .rec_ready            (set_ready         ),
    .rec_op               (set_op            ),
    .rec_seq              (set_seq           ),
    .rec_item             (set_item          ),
    .rec_set              (set_set           ),
    .rec_port             (set_port          ),
    .rec_len              (set_len           ),
    .rec_val              (set_val           ),
    .rec_usr              (set_usr           ),
    // 写入
    .wr_en                (wr_en             ),
    .wr_item              (wr_item           ),
    .wr_set               (wr_set            ),
    .wr_port              (wr_port           ),
    .wr_val               (wr_val            ),
    // 应答
    .callback_axis_mdata  (cb_mdata          ),
    .callback_axis_mkeep  (cb_mkeep          ),
    .callback_axis_mlast  (cb_mlast          ),
    .callback_axis_mvalid (cb_mvalid         ),
    .callback_axis_mready (cb_mready         ),
    .callback_axis_musr   (cb_musr           )
  );

  // ============================================================================
  // cfg_get：GET 命令读库 + 回写应答
  // ============================================================================
  cfg_get #(
    .MAX_VALUE_BYTES (MAX_VALUE_BYTES),
    .CMD_USR_WIDTH   (CMD_USR_WIDTH  )
  ) u_cfg_get (
    .clk             (clk            ),
    .rst             (rst            ),
    // TLV 命令
    .rec_valid       (get_valid      ),
    .rec_ready       (get_ready      ),
    .rec_op          (get_op         ),
    .rec_seq         (get_seq        ),
    .rec_item        (get_item       ),
    .rec_set         (get_set        ),
    .rec_port        (get_port       ),
    .rec_len         (get_len        ),
    .rec_val         (get_val        ),
    .rec_usr         (get_usr        ),
    // 读回
    .rd_req          (rd_req         ),
    .rd_item         (rd_item        ),
    .rd_set          (rd_set         ),
    .rd_port         (rd_port        ),
    .rd_len          (rd_len         ),
    .rd_val          (rd_val         ),
    // 应答
    .rd_axis_mdata   (rd_mdata       ),
    .rd_axis_mkeep   (rd_mkeep       ),
    .rd_axis_mlast   (rd_mlast       ),
    .rd_axis_mvalid  (rd_mvalid      ),
    .rd_axis_mready  (rd_mready      ),
    .rd_axis_musr    (rd_musr        )
  );

  // ============================================================================
  // cfg_error：错误帧组帧应答
  // ============================================================================
  cfg_error #(
    .MAX_VALUE_BYTES (MAX_VALUE_BYTES),
    .CMD_USR_WIDTH   (CMD_USR_WIDTH  )
  ) u_cfg_error (
    .clk             (clk            ),
    .rst             (rst            ),
    // TLV 命令
    .err_ready       (error_ready    ),
    .err_valid       (error_valid    ),
    .err_op          (error_op       ),
    .err_seq         (error_seq      ),
    .err_item        (error_item     ),
    .err_set         (error_set      ),
    .err_port        (error_port     ),
    .err_len         (error_len      ),
    .err_val         (error_val      ),
    .err_usr         (error_usr      ),
    .err_status      (error_status   ),
    // 应答
    .err_axis_mdata  (err_mdata      ),
    .err_axis_mkeep  (err_mkeep      ),
    .err_axis_mlast  (err_mlast      ),
    .err_axis_mvalid (err_mvalid     ),
    .err_axis_mready (err_mready     ),
    .err_axis_musr   (err_musr       )
  );

  // ============================================================================
  // cfg_reg_bank：配置寄存器组（写 / 读 / 生效输出 / 状态输入）
  // ============================================================================
  cfg_reg_bank #(
    .ETH_PORT_NUM               (ETH_PORT_NUM              ),
    .MAX_VALUE_BYTES            (MAX_VALUE_BYTES           ),
    .CFG_NUM_WIDTH              (CFG_NUM_WIDTH             ),
    .MAC_RX_TYPE_NUM_MAX        (MAC_RX_TYPE_NUM_MAX       ),
    .MAC_TX_TYPE_NUM_MAX        (MAC_TX_TYPE_NUM_MAX       ),
    .IPV4_RX_TYPE_NUM_MAX       (IPV4_RX_TYPE_NUM_MAX      ),
    .IPV4_TX_TYPE_NUM_MAX       (IPV4_TX_TYPE_NUM_MAX      ),
    .ICMP_TX_TYPE_NUM_MAX       (ICMP_TX_TYPE_NUM_MAX      ),
    .IPV6_RX_TYPE_NUM_MAX       (IPV6_RX_TYPE_NUM_MAX      ),
    .IPV6_TX_TYPE_NUM_MAX       (IPV6_TX_TYPE_NUM_MAX      ),
    .UDP_RX_PORT_NUM_MAX        (UDP_RX_PORT_NUM_MAX       ),
    .UDP_TX_PORT_NUM_MAX        (UDP_TX_PORT_NUM_MAX       ),
    .LOCAL_IPV4_MAC_NUM_MAX     (LOCAL_IPV4_MAC_NUM_MAX    ),
    .LOCAL_DST_IPV6_MAC_NUM_MAX (LOCAL_DST_IPV6_MAC_NUM_MAX),
    .LOCAL_SRC_IPV6_MAC_NUM_MAX (LOCAL_SRC_IPV6_MAC_NUM_MAX),
    .PENDING_TIME_WIDTH_MAX     (PENDING_TIME_WIDTH_MAX    ),
    .ARBITER_VAL_WIDTH_MAX      (ARBITER_VAL_WIDTH_MAX     ),
    .MAC_RX_TYPE_NUM_ARR        (MAC_RX_TYPE_NUM_ARR       ),
    .MAC_TX_TYPE_NUM_ARR        (MAC_TX_TYPE_NUM_ARR       ),
    .IPV4_RX_TYPE_NUM_ARR       (IPV4_RX_TYPE_NUM_ARR      ),
    .IPV4_TX_TYPE_NUM_ARR       (IPV4_TX_TYPE_NUM_ARR      ),
    .ICMP_TX_TYPE_NUM_ARR       (ICMP_TX_TYPE_NUM_ARR      ),
    .IPV6_RX_TYPE_NUM_ARR       (IPV6_RX_TYPE_NUM_ARR      ),
    .IPV6_TX_TYPE_NUM_ARR       (IPV6_TX_TYPE_NUM_ARR      ),
    .UDP_RX_PORT_NUM_ARR        (UDP_RX_PORT_NUM_ARR       ),
    .UDP_TX_PORT_NUM_ARR        (UDP_TX_PORT_NUM_ARR       ),
    .LOCAL_IPV4_MAC_NUM_ARR     (LOCAL_IPV4_MAC_NUM_ARR    ),
    .LOCAL_DST_IPV6_MAC_NUM_ARR (LOCAL_DST_IPV6_MAC_NUM_ARR),
    .LOCAL_SRC_IPV6_MAC_NUM_ARR (LOCAL_SRC_IPV6_MAC_NUM_ARR),
    .PENDING_TIME_WIDTH_ARR     (PENDING_TIME_WIDTH_ARR    ),
    .ARBITER_VAL_WIDTH_ARR      (ARBITER_VAL_WIDTH_ARR     ),
    .DEF_MAC_RX_TYPE_DICT_ARR   (DEF_MAC_RX_TYPE_DICT_ARR  ),
    .DEF_IPV4_RX_TYPE_DICT_ARR  (DEF_IPV4_RX_TYPE_DICT_ARR ),
    .DEF_IPV6_RX_TYPE_DICT_ARR  (DEF_IPV6_RX_TYPE_DICT_ARR ),
    .DEF_UDP_DST_PORT_RANGE_ARR (DEF_UDP_DST_PORT_RANGE_ARR),
    .DEF_V4_ARR                 (DEF_V4_ARR                ),
    .DEF_MAC_ARR                (DEF_MAC_ARR               ),
    .DEF_GW_ARR                 (DEF_GW_ARR                ),
    .DEF_MK_ARR                 (DEF_MK_ARR                ),
    .DEF_SRC_V6_ARR             (DEF_SRC_V6_ARR            ),
    .DEF_SRC_MAC_ARR            (DEF_SRC_MAC_ARR           ),
    .DEF_DST_V6_ARR             (DEF_DST_V6_ARR            ),
    .DEF_DST_MAC_ARR            (DEF_DST_MAC_ARR           ),
    .DEF_PENDING_TIME           (DEF_PENDING_TIME          ),
    .DEF_ARP_PRIORITY           (DEF_ARP_PRIORITY          ),
    .DEF_ICMPV4_PRIORITY        (DEF_ICMPV4_PRIORITY       ),
    .DEF_CMD_UDP_PORT           (DEF_CMD_UDP_PORT          ),
    .DEF_CMD_UDP_PRIO           (DEF_CMD_UDP_PRIO          )
  ) u_cfg_reg_bank (
    .clk                 (clk                ),
    .rst                 (rst                ),
    // 写
    .wr_en               (wr_en              ),
    .wr_item             (wr_item            ),
    .wr_set              (wr_set             ),
    .wr_port             (wr_port            ),
    .wr_val              (wr_val             ),
    // 读
    .rd_req              (rd_req             ),
    .rd_item             (rd_item            ),
    .rd_set              (rd_set             ),
    .rd_port             (rd_port            ),
    .rd_len              (rd_len             ),
    .rd_val              (rd_val             ),
    .rd_valid            (                   ),
    // 生效配置
    .cfg_local_mac       (cfg_local_mac      ),
    .cfg_local_ip        (cfg_local_ip       ),
    .cfg_gateway_ip      (cfg_gateway_ip     ),
    .cfg_subnet_mask     (cfg_subnet_mask    ),
    .cfg_src_ipv6        (cfg_src_ipv6       ),
    .cfg_src_mac         (cfg_src_mac        ),
    .cfg_dst_ipv6        (cfg_dst_ipv6       ),
    .cfg_dst_mac         (cfg_dst_mac        ),
    .cfg_eth_type        (cfg_eth_type       ),
    .cfg_ipv4_proto      (cfg_ipv4_proto     ),
    .cfg_ipv6_nh         (cfg_ipv6_nh        ),
    .cfg_udp_port        (cfg_udp_port       ),
    .cfg_pending_time    (cfg_pending_time   ),
    .cfg_arp_prio        (cfg_arp_prio       ),
    .cfg_icmp_prio       (cfg_icmp_prio      ),
    .cfg_cmd_udp_port    (cfg_cmd_udp_port   ),
    .cfg_cmd_udp_prio    (cmd_udp_prio_arr   ),
    .cfg_arp_cache_clear (cfg_arp_cache_clear),
    .cfg_arp_pending_clear(cfg_arp_pending_clear),
    .cfg_stat_clear      (cfg_stat_clear     ),
    // 状态
    .stat_link_status    (stat_link_status   ),
    .stat_tx_idle        (stat_tx_idle       ),
    .stat_tx_active      (stat_tx_active     ),
    .stat_is_df          (stat_is_df         ),
    .stat_arp            (stat_arp           ),
    .stat_icmp           (stat_icmp          )
  );

  // ============================================================================
  // axis_n_to_1：三路应答仲裁合并 -> m_axis
  // ============================================================================
  axis_n_to_1 #(
    .NUM_PORTS       (3             ),
    .AXIS_WIDTH      (AXIS_WIDTH    ),
    .AXIS_ID_WIDTH   (1             ),
    .AXIS_USER_WIDTH (CMD_USR_WIDTH ),
    .ARB_TYPE        (0             ),   // 0 = 轮询
    .UPDATE_TID      (0             )
  ) u_axis_n_to_1 (
    .clk             (clk                          ),
    .rst             (rst                          ),
    // N 路输入：{port2=set, port1=get, port0=error}
    .axis_sdata      ({cb_mdata, rd_mdata, err_mdata}    ),
    .axis_skeep      ({cb_mkeep, rd_mkeep, err_mkeep}    ),
    .axis_sid        (3'd0                               ),
    .axis_susr       ({cb_musr, rd_musr, err_musr}       ),
    .axis_svalid     ({cb_mvalid, rd_mvalid, err_mvalid} ),
    .axis_slast      ({cb_mlast, rd_mlast, err_mlast}    ),
    .axis_sready     ({cb_mready, rd_mready, err_mready} ),
    // 1 路输出
    .axis_mdata      (m_axis_data  ),
    .axis_mkeep      (m_axis_keep  ),
    .axis_mid        (             ),
    .axis_musr       (rsp_usr      ),
    .axis_mvalid     (m_axis_valid ),
    .axis_mlast      (m_axis_last  ),
    .axis_mready     (m_axis_ready ),
    // 状态
    .stat_active_port(             ),
    .stat_idle       (             )
  );

  // ============================================================================
  //     prio[3:0] / ttl[11:4] / sport[27:12] / dport[43:28] / src_ip[75:44] / dst_ip[107:76]
  // ============================================================================
  wire [ARBITER_VAL_WIDTH_MAX*ETH_PORT_NUM-1:0] cmd_udp_prio_arr;
  wire [ARBITER_VAL_WIDTH_MAX-1:0]              cmd_prio;
  assign cmd_prio = cmd_udp_prio_arr[CMD_PORT_SEL*ARBITER_VAL_WIDTH_MAX +: ARBITER_VAL_WIDTH_MAX];
  assign m_axis_udp_usr = { rsp_usr, CMD_TTL, cmd_prio[3:0] };

endmodule
`resetall
