`resetall
`timescale 1ns/100ps
`include "cfg_map.vh"

// Language: Verilog 2001
// ============================================================================
// File Name   : tb_net_stack_top.v
// Module Name : tb_net_stack_top
// ----------------------------------------------------------------------------
// Description : net_stack_top 全链路仿真（含 cfg 命令通道）
//
//   下行：以太网帧(CMAC 用户接口) -> eth_port_top -> ipv4_top -> udp_ipv4_top
//         -> 命令档(索引 0) -> axis_fifo_sync(512) -> cfg_cmd_top
//   上行：cfg 应答 -> 命令档 TX -> udp/ipv4 TX -> eth TX -> pad60 -> CMAC
//   配置面：cfg_cmd_top 的 cfg_* 直接驱动 net_stack_top，stat_* 反向回读
//
//   依赖 TB/Top/ip_sim/ 下的 IP 仿真桩（cmac_usplus_a/b、axis_slr_crossing）
//   激励：层次引用写 CMAC 桩的 sim_rx_*；捕获：采样 CMAC 的 tx_axis_*
// ============================================================================
module tb_net_stack_top;

  // ==========================================================================
  // 参数（与 subsys_test_top 一致，全部源自 cfg_map）
  // ==========================================================================
  localparam ETH_PORT_NUM        = `CFG_NUM_PORT;
  localparam CFG_NUM_WIDTH       = `CFG_COUNT_WIDTH;
  localparam PENDING_TIME_WIDTH  = `CFG_MAX_PENDING_TIME_WIDTH;
  localparam ARBITER_VAL_WIDTH   = `CFG_MAX_ARBITER_VAL_WIDTH;
  localparam CMD_PORT_SEL        = `CFG_CMD_PORT_SEL;
  localparam AXIS_WIDTH          = 512;

  localparam [CFG_NUM_WIDTH-1:0] MAC_RX_TYPE_NUM_MAX       = `CFG_MAX_MAC_RX_NUM;
  localparam [CFG_NUM_WIDTH-1:0] MAC_TX_TYPE_NUM_MAX       = `CFG_MAX_MAC_TX_NUM;
  localparam [CFG_NUM_WIDTH-1:0] IPV4_RX_TYPE_NUM_MAX      = `CFG_MAX_IPV4_RX_NUM;
  localparam [CFG_NUM_WIDTH-1:0] IPV4_TX_TYPE_NUM_MAX      = `CFG_MAX_IPV4_TX_NUM;
  localparam [CFG_NUM_WIDTH-1:0] ICMP_TX_TYPE_NUM_MAX      = `CFG_MAX_ICMP_TX_NUM;
  localparam [CFG_NUM_WIDTH-1:0] IPV6_RX_TYPE_NUM_MAX      = `CFG_MAX_IPV6_RX_NUM;
  localparam [CFG_NUM_WIDTH-1:0] IPV6_TX_TYPE_NUM_MAX      = `CFG_MAX_IPV6_TX_NUM;
  localparam [CFG_NUM_WIDTH-1:0] UDP_RX_PORT_NUM_MAX       = `CFG_MAX_UDP_RX_NUM;
  localparam [CFG_NUM_WIDTH-1:0] UDP_TX_PORT_NUM_MAX       = `CFG_MAX_UDP_TX_NUM;
  localparam [CFG_NUM_WIDTH-1:0] LOCAL_IPV4_MAC_NUM_MAX    = `CFG_MAX_V4_SET_NUM;
  localparam [CFG_NUM_WIDTH-1:0] LOCAL_DST_IPV6_MAC_NUM_MAX= `CFG_MAX_V6_DST_SET_NUM;
  localparam [CFG_NUM_WIDTH-1:0] LOCAL_SRC_IPV6_MAC_NUM_MAX= `CFG_MAX_V6_SRC_SET_NUM;

  localparam MAC_TX_N_MAX   = (MAC_TX_TYPE_NUM_MAX > 0) ? MAC_TX_TYPE_NUM_MAX : 1;
  localparam MAC_TX_TOT_MAX = MAC_TX_N_MAX + 3;
  localparam IPV4_TX_N_MAX  = (IPV4_TX_TYPE_NUM_MAX > 0) ? IPV4_TX_TYPE_NUM_MAX : 1;
  localparam ICMP_TX_N_MAX  = (ICMP_TX_TYPE_NUM_MAX > 0) ? ICMP_TX_TYPE_NUM_MAX : 1;
  localparam IPV6_TX_N_MAX  = (IPV6_TX_TYPE_NUM_MAX > 0) ? IPV6_TX_TYPE_NUM_MAX : 1;
  localparam IPV6_TX_TOT_MAX= IPV6_TX_N_MAX;
  localparam UDP_TX_N_MAX   = (UDP_TX_PORT_NUM_MAX > 0) ? UDP_TX_PORT_NUM_MAX : 1;
  localparam TX_IDX_WIDTH   = (MAC_TX_TOT_MAX <= 1) ? 1 : $clog2(MAC_TX_TOT_MAX);

  localparam MAC_RX_USR_WIDTH  = 1;
  localparam IPV4_RX_USR_WIDTH = 48 + 48 + MAC_RX_USR_WIDTH;
  localparam IPV6_RX_USR_WIDTH = IPV4_RX_USR_WIDTH;
  localparam UDP_RX_USR_WIDTH  = IPV4_RX_USR_WIDTH + 32+32+8+16+8 + 16+16+16;
  localparam MAC_TX_USR_WIDTH  = ARBITER_VAL_WIDTH;
  localparam IPV4_TX_USR_WIDTH = ARBITER_VAL_WIDTH;
  localparam IPV6_TX_USR_WIDTH = ARBITER_VAL_WIDTH;
  localparam UDP_TX_USR_WIDTH  = 4 + 8 + 16 + 16 + 32 + 32;

  localparam MRX_SLOTS  = (MAC_RX_TYPE_NUM_MAX + 1) * ETH_PORT_NUM;
  localparam V4RX_SLOTS = (IPV4_RX_TYPE_NUM_MAX + 1) * ETH_PORT_NUM;
  localparam V6RX_SLOTS = (IPV6_RX_TYPE_NUM_MAX + 1) * ETH_PORT_NUM;
  localparam UDPRX_SLOTS= (UDP_RX_PORT_NUM_MAX + 1) * ETH_PORT_NUM;

  localparam CMD_FIFO_DEPTH = 512;
  localparam CMD_USR_WIDTH  = 96;
  localparam CMD_TTL        = 8'd64;

  // ---- 测试常量（cfg_map 默认值，线序小端）----
  // cfg 侧的值（小端）：GET 0x00 应答载荷里就是这些字节
  localparam [31:0] DEV_IP    = 32'h0901_A8C0;    // 192.168.1.9
  // 数据面/帧头用网络序数值（大端数值）
  localparam [31:0] DEV_IP_N  = 32'hC0A8_0109;    // 192.168.1.9
  localparam [47:0] DEV_MAC_N = 48'h0019_3100_0001;
  localparam [31:0] PEER_IP_N = 32'hC0A8_0164;    // 192.168.1.100
  localparam [47:0] PEER_MAC_N= 48'h0200_0000_0099;// 02:00:00:00:00:99
  localparam [15:0] CMD_PORT  = 16'hC0DE;
  localparam [15:0] PEER_PORT = 16'h1234;
  localparam [15:0] ETYPE_IPV4= 16'h0800;
  localparam [15:0] ETYPE_ARP = 16'h0806;
  localparam [31:0] BAD_IP_N  = 32'hC0A8_01C8;    // 192.168.1.200

  // ==========================================================================
  // 时钟 / 复位
  // ==========================================================================
  reg  clk        = 1'b0;
  reg  sys_clk    = 1'b0;
  reg  clk_locked = 1'b0;
  reg  usr_rst    = 1'b1;
  always #2.5  clk     = ~clk;
  always #5.0  sys_clk = ~sys_clk;

  wire [48*LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]     cfg_local_mac;
  wire [32*LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]     cfg_local_ip;
  wire [32*LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]     cfg_gateway_ip;
  wire [32*LOCAL_IPV4_MAC_NUM_MAX*ETH_PORT_NUM-1:0]     cfg_subnet_mask;
  wire [128*LOCAL_DST_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]  cfg_dst_ipv6;
  wire [48*LOCAL_DST_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]  cfg_dst_mac;
  wire [128*LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]  cfg_src_ipv6;
  wire [48*LOCAL_SRC_IPV6_MAC_NUM_MAX*ETH_PORT_NUM-1:0]  cfg_src_mac;
  wire [16*MAC_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]        cfg_eth_type;
  wire [8*IPV4_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]        cfg_ipv4_proto;
  wire [8*IPV6_RX_TYPE_NUM_MAX*ETH_PORT_NUM-1:0]        cfg_ipv6_nh;
  wire [32*UDP_RX_PORT_NUM_MAX*ETH_PORT_NUM-1:0]        cfg_udp_port;
  wire [16*ETH_PORT_NUM-1:0]                            cfg_cmd_udp_port;
  wire [PENDING_TIME_WIDTH*ETH_PORT_NUM-1:0]            cfg_pending_time;
  wire [ARBITER_VAL_WIDTH*ETH_PORT_NUM-1:0]             cfg_arp_prio;
  wire [ARBITER_VAL_WIDTH*ETH_PORT_NUM-1:0]             cfg_icmp_prio;
  wire [ETH_PORT_NUM-1:0]                               cfg_arp_cache_clear;
  wire [ETH_PORT_NUM-1:0]                               cfg_arp_pending_clear;
  wire [ETH_PORT_NUM-1:0]                               cfg_stat_clear;
  wire [(MAC_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]       mac_axis_mready;
  wire [(IPV4_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]      ipv4_axis_mready;
  wire [ETH_PORT_NUM-1:0]                               icmp_axis_mready;
  wire [(IPV6_RX_TYPE_NUM_MAX+1)*ETH_PORT_NUM-1:0]      ipv6_axis_mready;
  wire [(UDP_RX_PORT_NUM_MAX+1)*ETH_PORT_NUM-1:0]       udp_axis_mready;
  wire [512*ETH_PORT_NUM-1:0]                           udp_cmd_axis_mdata;
  wire [64*ETH_PORT_NUM-1:0]                            udp_cmd_axis_mkeep;
  wire [ETH_PORT_NUM-1:0]                               udp_cmd_axis_mlast;
  wire [ETH_PORT_NUM-1:0]                               udp_cmd_axis_mvalid;
  wire [UDP_RX_USR_WIDTH*ETH_PORT_NUM-1:0]              udp_cmd_axis_musr;
  wire [ETH_PORT_NUM-1:0]                               udp_cmd_axis_mready;
  wire [512*ETH_PORT_NUM-1:0]                           udp_cmd_axis_sdata;
  wire [64*ETH_PORT_NUM-1:0]                            udp_cmd_axis_skeep;
  wire [ETH_PORT_NUM-1:0]                               udp_cmd_axis_slast;
  wire [ETH_PORT_NUM-1:0]                               udp_cmd_axis_svalid;
  wire [UDP_TX_USR_WIDTH*ETH_PORT_NUM-1:0]              udp_cmd_axis_susr;
  wire [ETH_PORT_NUM-1:0]                               udp_cmd_axis_sready;
  wire [ETH_PORT_NUM-1:0]                               stat_link_status;
  wire [ETH_PORT_NUM-1:0]                               stat_is_df;
  wire [TX_IDX_WIDTH*ETH_PORT_NUM-1:0]                  stat_tx_active_port;
  wire [ETH_PORT_NUM-1:0]                               stat_tx_idle;
  wire [ETH_PORT_NUM-1:0]                               stat_arp_rx_error;
  wire [ETH_PORT_NUM-1:0]                               stat_arp_ack_ovf;
  wire [ETH_PORT_NUM-1:0]                               stat_arp_pend_ovf;
  wire [ETH_PORT_NUM-1:0]                               stat_arp_no_resp;
  wire [ETH_PORT_NUM-1:0]                               stat_arp_pend_clr;
  wire [ETH_PORT_NUM-1:0]                               stat_arp_cache_clr;
  wire [ETH_PORT_NUM-1:0]                               stat_arp_src_not_local;
  wire [ETH_PORT_NUM-1:0]                               stat_ipv6_drop_pulse;
  wire [ETH_PORT_NUM-1:0]                               stat_icmp_drop;
  wire [3*ETH_PORT_NUM-1:0]                             stat_icmp_drop_reason;

  // ==========================================================================
  // DUT
  // ==========================================================================
  net_stack_top #(
    .ETH_PORT_NUM        (ETH_PORT_NUM        ),
    .CMD_PORT_SEL        (CMD_PORT_SEL        ),
    .PENDING_TIME_WIDTH  (PENDING_TIME_WIDTH  ),
    .ARBITER_VAL_WIDTH   (ARBITER_VAL_WIDTH   ),
    .CFG_NUM_WIDTH       (CFG_NUM_WIDTH       ),
    .MAC_RX_TYPE_NUM_MAX (MAC_RX_TYPE_NUM_MAX ),
    .MAC_TX_TYPE_NUM_MAX (MAC_TX_TYPE_NUM_MAX ),
    .IPV4_RX_TYPE_NUM_MAX(IPV4_RX_TYPE_NUM_MAX),
    .IPV4_TX_TYPE_NUM_MAX(IPV4_TX_TYPE_NUM_MAX),
    .ICMP_TX_TYPE_NUM_MAX(ICMP_TX_TYPE_NUM_MAX),
    .IPV6_RX_TYPE_NUM_MAX(IPV6_RX_TYPE_NUM_MAX),
    .IPV6_TX_TYPE_NUM_MAX(IPV6_TX_TYPE_NUM_MAX),
    .UDP_RX_PORT_NUM_MAX (UDP_RX_PORT_NUM_MAX ),
    .UDP_TX_PORT_NUM_MAX (UDP_TX_PORT_NUM_MAX ),
    .LOCAL_IPV4_MAC_NUM_MAX    (LOCAL_IPV4_MAC_NUM_MAX    ),
    .LOCAL_DST_IPV6_MAC_NUM_MAX(LOCAL_DST_IPV6_MAC_NUM_MAX),
    .LOCAL_SRC_IPV6_MAC_NUM_MAX(LOCAL_SRC_IPV6_MAC_NUM_MAX),
    .MAC_RX_TYPE_NUM_ARR       (`CFG_DEF_MAC_RX_NUM_ARR      ),
    .MAC_TX_TYPE_NUM_ARR       (`CFG_DEF_MAC_TX_NUM_ARR      ),
    .IPV4_RX_TYPE_NUM_ARR      (`CFG_DEF_IPV4_RX_NUM_ARR     ),
    .IPV4_TX_TYPE_NUM_ARR      (`CFG_DEF_IPV4_TX_NUM_ARR     ),
    .ICMP_TX_TYPE_NUM_ARR      (`CFG_DEF_ICMP_TX_NUM_ARR     ),
    .IPV6_RX_TYPE_NUM_ARR      (`CFG_DEF_IPV6_RX_NUM_ARR     ),
    .IPV6_TX_TYPE_NUM_ARR      (`CFG_DEF_IPV6_TX_NUM_ARR     ),
    .UDP_RX_PORT_NUM_ARR       (`CFG_DEF_UDP_RX_NUM_ARR      ),
    .UDP_TX_PORT_NUM_ARR       (`CFG_DEF_UDP_TX_NUM_ARR      ),
    .LOCAL_IPV4_MAC_NUM_ARR    (`CFG_DEF_V4_SET_NUM_ARR      ),
    .LOCAL_DST_IPV6_MAC_NUM_ARR(`CFG_DEF_V6_DST_NUM_ARR      ),
    .LOCAL_SRC_IPV6_MAC_NUM_ARR(`CFG_DEF_V6_SRC_NUM_ARR      )
  ) u_dut (
    .sys_clk                (sys_clk),
    .clk                    (clk),
    .clk_locked             (clk_locked),
    .qsfp_gt_rst            (),
    .usr_rst                (usr_rst),
    .gt_txp_out             (),
    .gt_txn_out             (),
    .gt_rxp_in              (0),
    .gt_rxn_in              (0),
    .gt_ref_clk_p           (0),
    .gt_ref_clk_n           (0),
    .qsfp_rstn_port         (),
    .qsfp_lp_mode_port      (),
    .qsfp_seln_port         (),
    .qsfp_prsn_port         ({ETH_PORT_NUM{1'b1}}),
    .qsfp_led_port          (),
    .cfg_local_mac          (cfg_local_mac),
    .cfg_local_ip           (cfg_local_ip),
    .cfg_gateway_ip         (cfg_gateway_ip),
    .cfg_subnet_mask        (cfg_subnet_mask),
    .cfg_dst_ipv6           (cfg_dst_ipv6),
    .cfg_dst_mac            (cfg_dst_mac),
    .cfg_src_ipv6           (cfg_src_ipv6),
    .cfg_src_mac            (cfg_src_mac),
    .cfg_eth_type           (cfg_eth_type),
    .cfg_ipv4_proto         (cfg_ipv4_proto),
    .cfg_ipv6_nh            (cfg_ipv6_nh),
    .cfg_udp_port           (cfg_udp_port),
    .cfg_cmd_udp_port       (cfg_cmd_udp_port),
    .cfg_pending_time       (cfg_pending_time),
    .cfg_arp_prio           (cfg_arp_prio),
    .cfg_icmp_prio          (cfg_icmp_prio),
    .cfg_arp_cache_clear    (cfg_arp_cache_clear),
    .cfg_arp_pending_clear  (cfg_arp_pending_clear),
    .cfg_stat_clear         (cfg_stat_clear),
    .mac_axis_mdata         (),
    .mac_axis_mkeep         (),
    .mac_axis_mlast         (),
    .mac_axis_mvalid        (),
    .mac_axis_mready        (mac_axis_mready),
    .mac_axis_sdata         (0),
    .mac_axis_skeep         (0),
    .mac_axis_slast         (0),
    .mac_axis_svalid        (0),
    .mac_axis_susr          (0),
    .mac_axis_sready        (),
    .ipv4_axis_mdata        (),
    .ipv4_axis_mkeep        (),
    .ipv4_axis_mlast        (),
    .ipv4_axis_mvalid       (),
    .ipv4_axis_musr         (),
    .ipv4_axis_mready       (ipv4_axis_mready),
    .ipv4_axis_sdata        (0),
    .ipv4_axis_skeep        (0),
    .ipv4_axis_slast        (0),
    .ipv4_axis_svalid       (0),
    .ipv4_axis_susr         (0),
    .ipv4_axis_sready       (),
    .icmp_axis_mdata        (),
    .icmp_axis_mkeep        (),
    .icmp_axis_mlast        (),
    .icmp_axis_mvalid       (),
    .icmp_axis_musr         (),
    .icmp_axis_mready       (icmp_axis_mready),
    .icmp_axis_sdata        (0),
    .icmp_axis_skeep        (0),
    .icmp_axis_slast        (0),
    .icmp_axis_svalid       (0),
    .icmp_axis_susr         (0),
    .icmp_axis_sready       (),
    .ipv6_axis_mdata        (),
    .ipv6_axis_mkeep        (),
    .ipv6_axis_mlast        (),
    .ipv6_axis_mvalid       (),
    .ipv6_axis_musr         (),
    .ipv6_axis_mready       (ipv6_axis_mready),
    .ipv6_axis_sdata        (0),
    .ipv6_axis_skeep        (0),
    .ipv6_axis_slast        (0),
    .ipv6_axis_svalid       (0),
    .ipv6_axis_susr         (0),
    .ipv6_axis_sready       (),
    .udp_axis_mdata         (),
    .udp_axis_mkeep         (),
    .udp_axis_mlast         (),
    .udp_axis_mvalid        (),
    .udp_axis_musr          (),
    .udp_axis_mready        (udp_axis_mready),
    .udp_axis_sdata         (0),
    .udp_axis_skeep         (0),
    .udp_axis_slast         (0),
    .udp_axis_svalid        (0),
    .udp_axis_susr          (0),
    .udp_axis_sready        (),
    .udp_cmd_axis_mdata     (udp_cmd_axis_mdata),
    .udp_cmd_axis_mkeep     (udp_cmd_axis_mkeep),
    .udp_cmd_axis_mlast     (udp_cmd_axis_mlast),
    .udp_cmd_axis_mvalid    (udp_cmd_axis_mvalid),
    .udp_cmd_axis_musr      (udp_cmd_axis_musr),
    .udp_cmd_axis_mready    (udp_cmd_axis_mready),
    .udp_cmd_axis_sdata     (udp_cmd_axis_sdata),
    .udp_cmd_axis_skeep     (udp_cmd_axis_skeep),
    .udp_cmd_axis_slast     (udp_cmd_axis_slast),
    .udp_cmd_axis_svalid    (udp_cmd_axis_svalid),
    .udp_cmd_axis_susr      (udp_cmd_axis_susr),
    .udp_cmd_axis_sready    (udp_cmd_axis_sready),
    .stat_link_status       (stat_link_status),
    .stat_is_df             (stat_is_df),
    .stat_tx_active_port    (stat_tx_active_port),
    .stat_tx_idle           (stat_tx_idle),
    .stat_arp_rx_error      (stat_arp_rx_error),
    .stat_arp_ack_ovf       (stat_arp_ack_ovf),
    .stat_arp_pend_ovf      (stat_arp_pend_ovf),
    .stat_arp_no_resp       (stat_arp_no_resp),
    .stat_arp_pend_clr      (stat_arp_pend_clr),
    .stat_arp_cache_clr     (stat_arp_cache_clr),
    .stat_arp_src_not_local (stat_arp_src_not_local),
    .stat_ipv6_drop_pulse   (stat_ipv6_drop_pulse),
    .stat_icmp_drop         (stat_icmp_drop),
    .stat_icmp_drop_reason  (stat_icmp_drop_reason)
  );

  assign mac_axis_mready  = {MRX_SLOTS  {1'b1}};
  assign ipv4_axis_mready = {V4RX_SLOTS {1'b1}};
  assign icmp_axis_mready = {ETH_PORT_NUM{1'b1}};
  assign ipv6_axis_mready = {V6RX_SLOTS {1'b1}};
  assign udp_axis_mready  = {UDPRX_SLOTS{1'b1}};

  // ==========================================================================
  // 命令通道：FIFO + cfg_cmd_top（与 subsys_test_top 一致）
  // ==========================================================================
  wire                        cmd_fifo_sready ;
  wire [511:0]                cmd_fifo_mdata  ;
  wire [63:0]                 cmd_fifo_mkeep  ;
  wire                        cmd_fifo_mlast  ;
  wire                        cmd_fifo_mvalid ;
  wire [UDP_RX_USR_WIDTH-1:0] cmd_fifo_musr   ;
  wire                        cmd_in_ready    ;
  wire                        cmd_rsp_valid   ;
  wire [511:0]                cmd_rsp_data    ;
  wire [63:0]                 cmd_rsp_keep    ;
  wire                        cmd_rsp_last    ;
  wire [UDP_TX_USR_WIDTH-1:0] cmd_rsp_usr     ;
  wire                        cmd_rsp_ready   ;

  genvar gc;
  generate
    for (gc = 0; gc < ETH_PORT_NUM; gc = gc + 1) begin : g_cmd_port
      if (gc == CMD_PORT_SEL) begin : g_sel
  assign  udp_cmd_axis_mready[gc] = cmd_fifo_sready;
  assign  udp_cmd_axis_sdata [gc*512 +: 512] = cmd_rsp_data;
  assign  udp_cmd_axis_skeep [gc*64  +:  64] = cmd_rsp_keep;
  assign  udp_cmd_axis_slast [gc]            = cmd_rsp_last;
  assign  udp_cmd_axis_svalid[gc]            = cmd_rsp_valid;
  assign  udp_cmd_axis_susr  [gc*UDP_TX_USR_WIDTH +: UDP_TX_USR_WIDTH] = cmd_rsp_usr;
  assign  cmd_rsp_ready                      = udp_cmd_axis_sready[gc];
      end
      else begin : g_nosel
  assign  udp_cmd_axis_mready[gc] = 1'b0;
  assign  udp_cmd_axis_sdata [gc*512 +: 512] = 512'd0;
  assign  udp_cmd_axis_skeep [gc*64  +:  64] = 64'd0;
  assign  udp_cmd_axis_slast [gc]            = 1'b0;
  assign  udp_cmd_axis_svalid[gc]            = 1'b0;
  assign  udp_cmd_axis_susr  [gc*UDP_TX_USR_WIDTH +: UDP_TX_USR_WIDTH] = {UDP_TX_USR_WIDTH{1'b0}};
      end
    end
  endgenerate

  axis_fifo_sync #(
    .FIFO_DEPTH      (CMD_FIFO_DEPTH      ),
    .AXIS_WIDTH      (AXIS_WIDTH          ),
    .AXIS_USER_WIDTH (UDP_RX_USR_WIDTH    ),
    .AXIS_ID_WIDTH   (1                   ),
    .AXIS_DEST_WIDTH (1                   ),
    .PACKET_FIFO     (1                   ),
    .FIFO_MEMORY_TYPE("auto"              ),
    .BRAM_DO_REG     (2                   ),
    .DEADLOCK_RISK   (1                   )
  ) u_cmd_fifo (
    .rst             (usr_rst             ),
    .clk             (clk                 ),
    .axis_sdata      (udp_cmd_axis_mdata [CMD_PORT_SEL*512 +: 512]),
    .axis_skeep      (udp_cmd_axis_mkeep [CMD_PORT_SEL*64  +: 64 ]),
    .axis_svalid     (udp_cmd_axis_mvalid[CMD_PORT_SEL]),
    .axis_slast      (udp_cmd_axis_mlast [CMD_PORT_SEL]),
    .axis_sready     (cmd_fifo_sready     ),
    .axis_susr       (udp_cmd_axis_musr  [CMD_PORT_SEL*UDP_RX_USR_WIDTH +: UDP_RX_USR_WIDTH]),
    .axis_sstrb      (64'd0               ),
    .axis_sid        (1'b0                ),
    .axis_sdest      (1'b0                ),
    .axis_mdata      (cmd_fifo_mdata      ),
    .axis_mkeep      (cmd_fifo_mkeep      ),
    .axis_mvalid     (cmd_fifo_mvalid     ),
    .axis_mlast      (cmd_fifo_mlast      ),
    .axis_mready     (cmd_in_ready        ),
    .axis_musr       (cmd_fifo_musr       ),
    .axis_mstrb      (                    ),
    .axis_mid        (                    ),
    .axis_mdest      (                    ),
    .prog_empty      (                    ),
    .prog_full       (                    ),
    .empty           (                    ),
    .full            (                    ),
    .remain_count    (                    )
  );

  cfg_cmd_top #(
    .AXIS_WIDTH        (AXIS_WIDTH        ),
    .CMD_PORT_SEL      (CMD_PORT_SEL      ),
    .CMD_USR_WIDTH     (CMD_USR_WIDTH     ),
    .UDP_RX_USR_WIDTH  (UDP_RX_USR_WIDTH  ),
    .UDP_TX_USR_WIDTH  (UDP_TX_USR_WIDTH  ),
    .CMD_TTL           (CMD_TTL           ),
    .ETH_PORT_NUM      (ETH_PORT_NUM      ),
    .CFG_NUM_WIDTH     (CFG_NUM_WIDTH     ),
    .MAC_RX_TYPE_NUM_MAX       (MAC_RX_TYPE_NUM_MAX       ),
    .MAC_TX_TYPE_NUM_MAX       (MAC_TX_TYPE_NUM_MAX       ),
    .IPV4_RX_TYPE_NUM_MAX      (IPV4_RX_TYPE_NUM_MAX      ),
    .IPV4_TX_TYPE_NUM_MAX      (IPV4_TX_TYPE_NUM_MAX      ),
    .ICMP_TX_TYPE_NUM_MAX      (ICMP_TX_TYPE_NUM_MAX      ),
    .IPV6_RX_TYPE_NUM_MAX      (IPV6_RX_TYPE_NUM_MAX      ),
    .IPV6_TX_TYPE_NUM_MAX      (IPV6_TX_TYPE_NUM_MAX      ),
    .UDP_RX_PORT_NUM_MAX       (UDP_RX_PORT_NUM_MAX       ),
    .UDP_TX_PORT_NUM_MAX       (UDP_TX_PORT_NUM_MAX       ),
    .LOCAL_IPV4_MAC_NUM_MAX    (LOCAL_IPV4_MAC_NUM_MAX    ),
    .LOCAL_DST_IPV6_MAC_NUM_MAX(LOCAL_DST_IPV6_MAC_NUM_MAX),
    .LOCAL_SRC_IPV6_MAC_NUM_MAX(LOCAL_SRC_IPV6_MAC_NUM_MAX),
    .MAC_RX_TYPE_NUM_ARR       (`CFG_DEF_MAC_RX_NUM_ARR      ),
    .MAC_TX_TYPE_NUM_ARR       (`CFG_DEF_MAC_TX_NUM_ARR      ),
    .IPV4_RX_TYPE_NUM_ARR      (`CFG_DEF_IPV4_RX_NUM_ARR     ),
    .IPV4_TX_TYPE_NUM_ARR      (`CFG_DEF_IPV4_TX_NUM_ARR     ),
    .ICMP_TX_TYPE_NUM_ARR      (`CFG_DEF_ICMP_TX_NUM_ARR     ),
    .IPV6_RX_TYPE_NUM_ARR      (`CFG_DEF_IPV6_RX_NUM_ARR     ),
    .IPV6_TX_TYPE_NUM_ARR      (`CFG_DEF_IPV6_TX_NUM_ARR     ),
    .UDP_RX_PORT_NUM_ARR       (`CFG_DEF_UDP_RX_NUM_ARR      ),
    .UDP_TX_PORT_NUM_ARR       (`CFG_DEF_UDP_TX_NUM_ARR      ),
    .LOCAL_IPV4_MAC_NUM_ARR    (`CFG_DEF_V4_SET_NUM_ARR      ),
    .LOCAL_DST_IPV6_MAC_NUM_ARR(`CFG_DEF_V6_DST_NUM_ARR      ),
    .LOCAL_SRC_IPV6_MAC_NUM_ARR(`CFG_DEF_V6_SRC_NUM_ARR      ),
    .DEF_MAC_RX_TYPE_DICT_ARR  (`CFG_DEF_MAC_RX_DICT_ARR     ),
    .DEF_IPV4_RX_TYPE_DICT_ARR (`CFG_DEF_IPV4_RX_DICT_ARR    ),
    .DEF_IPV6_RX_TYPE_DICT_ARR (`CFG_DEF_IPV6_RX_DICT_ARR    ),
    .DEF_UDP_DST_PORT_RANGE_ARR(`CFG_DEF_UDP_PORT_RANGE_ARR  )
  ) u_cfg (
    .clk              (clk                 ),
    .rst              (usr_rst             ),
    .s_axis_cmd_data  (cmd_fifo_mdata      ),
    .s_axis_cmd_keep  (cmd_fifo_mkeep      ),
    .s_axis_cmd_last  (cmd_fifo_mlast      ),
    .s_axis_cmd_valid (cmd_fifo_mvalid     ),
    .s_axis_cmd_ready (cmd_in_ready        ),
    .s_axis_cmd_usr   (cmd_fifo_musr       ),
    .m_axis_data      (cmd_rsp_data        ),
    .m_axis_keep      (cmd_rsp_keep        ),
    .m_axis_last      (cmd_rsp_last        ),
    .m_axis_valid     (cmd_rsp_valid       ),
    .m_axis_ready     (cmd_rsp_ready       ),
    .m_axis_udp_usr   (cmd_rsp_usr         ),
    .cfg_local_mac        (cfg_local_mac        ),
    .cfg_local_ip         (cfg_local_ip         ),
    .cfg_gateway_ip       (cfg_gateway_ip       ),
    .cfg_subnet_mask      (cfg_subnet_mask      ),
    .cfg_src_ipv6         (cfg_src_ipv6         ),
    .cfg_src_mac          (cfg_src_mac          ),
    .cfg_dst_ipv6         (cfg_dst_ipv6         ),
    .cfg_dst_mac          (cfg_dst_mac          ),
    .cfg_eth_type         (cfg_eth_type         ),
    .cfg_ipv4_proto       (cfg_ipv4_proto       ),
    .cfg_ipv6_nh          (cfg_ipv6_nh          ),
    .cfg_udp_port         (cfg_udp_port         ),
    .cfg_pending_time     (cfg_pending_time     ),
    .cfg_arp_prio         (cfg_arp_prio         ),
    .cfg_icmp_prio        (cfg_icmp_prio        ),
    .cfg_cmd_udp_port     (cfg_cmd_udp_port     ),
    .cfg_arp_cache_clear  (cfg_arp_cache_clear  ),
    .cfg_arp_pending_clear(cfg_arp_pending_clear),
    .cfg_stat_clear       (cfg_stat_clear       ),
    .stat_link_status     (stat_link_status     ),
    .stat_tx_idle         (stat_tx_idle         ),
    .stat_tx_active       (stat_tx_active_port  ),
    .stat_is_df           (stat_is_df           ),
    .stat_arp             ({stat_arp_src_not_local, stat_arp_cache_clr, stat_arp_pend_clr,
                            stat_arp_no_resp, stat_arp_pend_ovf, stat_arp_ack_ovf,
                            stat_arp_rx_error}),
    .stat_icmp            ({stat_icmp_drop_reason, stat_icmp_drop})
  );

  // ==========================================================================
  // CMAC 桩：激励注入 / 应答捕获
  // ==========================================================================
`define CMAC0 u_dut.gen_port[0].u_eth_port_top.gen_cmac_a.u_cmac_if.u_cmac_usplus_a
  wire line_clk = `CMAC0.sim_clk;

  reg  [7:0] FR      [0:16383];   // 64 帧 x 256B
  integer    FR_LEN  [0:63];
  time       FR_T    [0:63];
  integer    FR_N    = 0;
  integer    cap_idx = 0;
  integer    ci;
  integer    c_capv = 0;   // 捕获侧看到的 tvalid 拍数

  always @(posedge line_clk) begin
    if (`CMAC0.tx_axis_tvalid) c_capv = c_capv + 1;
    if (`CMAC0.tx_axis_tvalid && (FR_N < 64)) begin
      for (ci = 0; ci < 64; ci = ci + 1) begin
        if (`CMAC0.tx_axis_tkeep[ci] && (cap_idx < 250)) begin
          FR[FR_N*256 + cap_idx] = `CMAC0.tx_axis_tdata[ci*8 +: 8];
          cap_idx = cap_idx + 1;
        end
      end
      if (`CMAC0.tx_axis_tlast) begin
        FR_LEN[FR_N] = cap_idx;
        FR_T  [FR_N] = $time;
        FR_N   = FR_N + 1;
        cap_idx = 0;
      end
    end
  end

  reg  [7:0] TXB [0:255];
  integer    TXL = 0;
  integer    err_total = 0;
  integer err_p10 = 0;
  integer    rd_ptr = 0;
  integer    i;

  task automatic putb(input [7:0] v); begin TXB[TXL] = v; TXL = TXL + 1; end endtask
  task automatic put2(input [15:0] v); begin putb(v[7:0]); putb(v[15:8]); end endtask
  task automatic put4(input [31:0] v);
    begin putb(v[7:0]); putb(v[15:8]); putb(v[23:16]); putb(v[31:24]); end endtask
  task automatic put6(input [47:0] v);
    begin putb(v[7:0]); putb(v[15:8]); putb(v[23:16]);
          putb(v[31:24]); putb(v[39:32]); putb(v[47:40]); end endtask

  // 网络序（大端）写入
  task automatic put_be16(input [15:0] v); begin putb(v[15:8]); putb(v[7:0]); end endtask
  task automatic put_be32(input [31:0] v);
    begin putb(v[31:24]); putb(v[23:16]); putb(v[15:8]); putb(v[7:0]); end endtask
  task automatic put_be48(input [47:0] v);
    begin putb(v[47:40]); putb(v[39:32]); putb(v[31:24]);
          putb(v[23:16]); putb(v[15:8]); putb(v[7:0]); end endtask

  // 帧内第 k 字节（大端数值的第 k 字节）
  function [7:0] macb; input [47:0] m; input integer k; begin macb = m[8*(5-k) +: 8]; end endfunction
  function [7:0] ipb;  input [31:0] w; input integer k; begin ipb  = w[8*(3-k) +: 8]; end endfunction

  function [15:0] ip_cksum;
    input integer base;
    input integer nbytes;
    integer k;
    reg [31:0] sum;
    begin
      sum = 32'd0;
      for (k = 0; k < nbytes; k = k + 2)
        sum = sum + ({16'd0, TXB[base+k]} << 8) + {16'd0, TXB[base+k+1]};
      sum = (sum & 32'h0000_FFFF) + (sum >> 16);
      sum = (sum & 32'h0000_FFFF) + (sum >> 16);
      ip_cksum = ~sum[15:0];
    end
  endfunction

  task automatic send_frame;
    integer b, j, nb;
    reg [511:0] d;
    reg [ 63:0] k;
    begin
      nb = (TXL + 63) / 64;
      for (b = 0; b < nb; b = b + 1) begin
        d = 512'd0; k = 64'd0;
        for (j = 0; j < 64; j = j + 1) begin
          if ((b*64 + j) < TXL) begin
            d[j*8 +: 8] = TXB[b*64 + j];
            k[j]        = 1'b1;
          end
        end
        @(posedge line_clk);
        `CMAC0.sim_rx_data  = d;
        `CMAC0.sim_rx_keep  = k;
        `CMAC0.sim_rx_last  = (b == nb-1);
        `CMAC0.sim_rx_valid = 1'b1;
      end
      @(posedge line_clk);
      `CMAC0.sim_rx_valid = 1'b0;
      `CMAC0.sim_rx_last  = 1'b0;
    end
  endtask

  task automatic build_udp(input [31:0] dst_ip, input [31:0] src_ip,
                           input [47:0] dst_mac, input [47:0] src_mac,
                           input [15:0] sport, input [15:0] dport, input integer plen);
    integer ip_start, total, ck;
    begin
      TXL = 0;
      put_be48(dst_mac); put_be48(src_mac); put_be16(ETYPE_IPV4);
      ip_start = TXL;
      total    = 20 + 8 + plen;
      putb(8'h45); putb(8'h00); put_be16(total[15:0]);
      put_be16(16'h0001); put_be16(16'h4000);
      putb(8'd64);   putb(8'd17);
      put_be16(16'h0000);
      put_be32(src_ip);  put_be32(dst_ip);
      ck = ip_cksum(ip_start, 20);
      TXB[ip_start+10] = ck[15:8];
      TXB[ip_start+11] = ck[7:0];
      put_be16(sport); put_be16(dport); put_be16(8 + plen[15:0]); put_be16(16'h0000);
    end
  endtask

  task automatic frame_pad60;
    begin while (TXL < 60) putb(8'h00); end
  endtask

  task automatic send_cmd(input [7:0] op, input [7:0] seq, input [7:0] item,
                          input [3:0] set, input [3:0] port, input [7:0] len,
                          input [31:0] val, input [31:0] dst_ip);
    integer k;
    begin
      build_udp(dst_ip, PEER_IP_N, DEV_MAC_N, PEER_MAC_N, PEER_PORT, CMD_PORT, 5 + len);  // TLV 头 5B + VAL
      putb(op); putb(seq); putb(item); putb({set, port}); putb(len);
      for (k = 0; k < len; k = k + 1) putb(val[k*8 +: 8]);
      // 真实主机行为：补齐到最小以太网帧 60 字节
      //   填充由 ipv4_eth_rx 按 IPv4 total_length 裁掉（只裁最小帧的填充）
      frame_pad60();
      send_frame();
    end
  endtask

  // 一帧 4 条 GET TLV：载荷 20B => 帧 62B > 60，主机不会补零
  task automatic send_cmd_multi;
    begin
      build_udp(DEV_IP_N, PEER_IP_N, DEV_MAC_N, PEER_MAC_N, PEER_PORT, CMD_PORT, 20);
      putb(8'h02); putb(8'h31); putb(8'h00); putb(8'h00); putb(8'h00);
      putb(8'h02); putb(8'h32); putb(8'h03); putb(8'h00); putb(8'h00);
      putb(8'h02); putb(8'h33); putb(8'h52); putb(8'h00); putb(8'h00);
      putb(8'h02); putb(8'h34); putb(8'h61); putb(8'h00); putb(8'h00);
      frame_pad60();
      send_frame();
    end
  endtask

  // 一帧 4 条 SET TLV（ITEM 0x04 IPv6 SRC，LEN=16）：载荷 84B => 帧 126B => 2 拍
  //   关键：跨 2 拍且每根 TLV 都带 OP/SEQ，验证侧带在多拍多 TLV 下不被后续拍清掉
  task automatic send_cmd_multi_long;
    integer n;
    reg [7:0] sq;
    begin
      build_udp(DEV_IP_N, PEER_IP_N, DEV_MAC_N, PEER_MAC_N, PEER_PORT, CMD_PORT, 84);
      for (n = 0; n < 4; n = n + 1) begin
        sq = 8'hA1 + n;
        putb(8'h01);              // OP = SET
        putb(sq);                 // SEQ
        putb(8'h04);              // ITEM = IPv6 SRC
        putb(8'h00);              // {set, port} = 0
        putb(8'd16);              // LEN = 16
        putb(8'h11); putb(8'h22); putb(8'h33); putb(8'h44);
        putb(8'h55); putb(8'h66); putb(8'h77); putb(8'h88);
        putb(8'h99); putb(8'hAA); putb(8'hBB); putb(8'hCC);
        putb(8'hDD); putb(8'hEE); putb(8'hFF); putb(8'h00);
      end
      frame_pad60();
      send_frame();
    end
  endtask

  // payload 恰好 64B 的命令帧（8 条 TLV）
  //   21(SET 0x04 LEN16) + 9(SET 0x03 LEN4) + 9(SET 0x03 LEN4) + 5*5(GET 0x52 LEN0) = 64
  //   => UDP 层 keep 恰好 64 位全 1、slast=1，帧尾正好落在 beat 最后一个字节，
  //      状态机在 S_VAL_LOOP/S_LEN 里直接跳 S_OP，【跳过 S_IDLE】
  task automatic send_cmd_exact64;
    input [7:0] seq_base;
    integer n; reg [7:0] sq;
    begin
      build_udp(DEV_IP_N, PEER_IP_N, DEV_MAC_N, PEER_MAC_N, PEER_PORT, CMD_PORT, 64);
      // TLV1: SET 0x04 (IPv6 SRC) LEN=16
      sq = seq_base;               putb(8'h01); putb(sq); putb(8'h04); putb(8'h00); putb(8'd16);
      putb(8'h5A); putb(8'h5B); putb(8'h5C); putb(8'h5D); putb(8'h5E); putb(8'h5F); putb(8'h60); putb(8'h61);
      putb(8'h62); putb(8'h63); putb(8'h64); putb(8'h65); putb(8'h66); putb(8'h67); putb(8'h68); putb(8'h69);
      // TLV2/3: SET 0x03 (mask) LEN=4
      sq = seq_base + 8'd1;        putb(8'h01); putb(sq); putb(8'h03); putb(8'h00); putb(8'd4);
      putb(8'hFF); putb(8'hFF); putb(8'h00); putb(8'h00);
      sq = seq_base + 8'd2;        putb(8'h01); putb(sq); putb(8'h03); putb(8'h00); putb(8'd4);
      putb(8'hFF); putb(8'hFF); putb(8'h00); putb(8'h00);
      // TLV4..8: GET 0x52 (LINK_STATUS) LEN=0
      for (n = 3; n < 8; n = n + 1) begin
        sq = seq_base + n;
        putb(8'h02); putb(sq); putb(8'h52); putb(8'h00); putb(8'd0);
      end
      frame_pad60();
      send_frame();
    end
  endtask

  // 3 拍命令帧：7 条 SET 0x04 LEN=16，payload 147B => 帧 189B => 3 拍（64+64+61）
  task automatic send_cmd_3beat;
    integer n; reg [7:0] sq;
    begin
      build_udp(DEV_IP_N, PEER_IP_N, DEV_MAC_N, PEER_MAC_N, PEER_PORT, CMD_PORT, 147);
      for (n = 0; n < 7; n = n + 1) begin
        sq = 8'hC0 + n;
        putb(8'h01); putb(sq); putb(8'h04); putb(8'h00); putb(8'd16);
        putb(8'h11); putb(8'h22); putb(8'h33); putb(8'h44); putb(8'h55); putb(8'h66); putb(8'h77); putb(8'h88);
        putb(8'h99); putb(8'hAA); putb(8'hBB); putb(8'hCC); putb(8'hDD); putb(8'hEE); putb(8'hFF); putb(8'h00);
      end
      frame_pad60();
      send_frame();
    end
  endtask

  // 畸形帧：total_length 被写成 0（违反「60 字节帧 len 一定合法」的约定）
  task automatic send_bad_len_frame;
    begin
      build_udp(DEV_IP_N, PEER_IP_N, DEV_MAC_N, PEER_MAC_N, PEER_PORT, CMD_PORT, 5);
      putb(8'h02); putb(8'h50); putb(8'h00); putb(8'h00); putb(8'h00);
      frame_pad60();
      TXB[16] = 8'h00; TXB[17] = 8'h00;      // total_length = 0
      send_frame();
    end
  endtask

  task automatic send_arp_req(input [31:0] target_ip);
    begin
      TXL = 0;
      put_be48(48'hFFFF_FFFF_FFFF); put_be48(PEER_MAC_N); put_be16(ETYPE_ARP);
      put_be16(16'h0001); put_be16(ETYPE_IPV4); putb(8'd6); putb(8'd4);
      put_be16(16'h0001);
      put_be48(PEER_MAC_N); put_be32(PEER_IP_N);
      put_be48(48'h0);      put_be32(target_ip);
      frame_pad60();
      send_frame();
    end
  endtask

  function [7:0] fb;
    input integer f;
    input integer k;
    begin fb = FR[f*256 + k]; end
  endfunction

  // 在 [rd_ptr, FR_N) 里找第一条 UDP 命令应答
  task automatic find_rsp(output integer idx);
    integer f;
    begin
      idx = -1;
      for (f = rd_ptr; f < FR_N; f = f + 1) begin
        if (idx < 0 && FR_LEN[f] >= 60 &&
            fb(f,12) === 8'h08 && fb(f,13) === 8'h00 &&
            fb(f,23) === 8'h11 &&
            fb(f,36) === PEER_PORT[15:8] && fb(f,37) === PEER_PORT[7:0]) idx = f;
      end
    end
  endtask

  task automatic chk_udp_rsp(input integer f, input [7:0] exp_op, input [7:0] seq,
                             input [7:0] status, input [7:0] item, input [3:0] set,
                             input [3:0] port, input [7:0] len, input [31:0] val);
    integer bad, k;
    begin
      bad = 0;
      for (k = 0; k < 6; k = k + 1) begin
        if (fb(f,k)   !== macb(PEER_MAC_N,k)) begin
          $display("  [FAIL] f%0d 目的 MAC[%0d] = %h (exp %h)", f, k, fb(f,k), macb(PEER_MAC_N,k)); bad=bad+1; end
        if (fb(f,6+k) !== macb(DEV_MAC_N,k)) begin
          $display("  [FAIL] f%0d 源 MAC[%0d] = %h (exp %h)", f, k, fb(f,6+k), macb(DEV_MAC_N,k)); bad=bad+1; end
      end
      if (fb(f,14) !== 8'h45) begin $display("  [FAIL] f%0d IPv4 ver/IHL = %h (exp 45)", f, fb(f,14)); bad=bad+1; end
      if (fb(f,22) !== 8'd64) begin $display("  [FAIL] f%0d TTL = %d (exp 64)", f, fb(f,22)); bad=bad+1; end
      if (fb(f,23) !== 8'd17) begin $display("  [FAIL] f%0d proto = %d (exp 17)", f, fb(f,23)); bad=bad+1; end
      if ({fb(f,26),fb(f,27),fb(f,28),fb(f,29)} !== DEV_IP_N) begin
        $display("  [FAIL] f%0d 源 IP = %h%h%h%h (exp %h)", f, fb(f,26),fb(f,27),fb(f,28),fb(f,29), DEV_IP_N); bad=bad+1; end
      if ({fb(f,30),fb(f,31),fb(f,32),fb(f,33)} !== PEER_IP_N) begin
        $display("  [FAIL] f%0d 目的 IP = %h%h%h%h (exp %h)", f, fb(f,30),fb(f,31),fb(f,32),fb(f,33), PEER_IP_N); bad=bad+1; end
      if ({fb(f,34),fb(f,35)} !== CMD_PORT) begin
        $display("  [FAIL] f%0d UDP 源端口 = %h%h (exp %h)", f, fb(f,34),fb(f,35), CMD_PORT); bad=bad+1; end
      if ({fb(f,36),fb(f,37)} !== PEER_PORT) begin
        $display("  [FAIL] f%0d UDP 目的端口 = %h%h (exp %h)", f, fb(f,36),fb(f,37), PEER_PORT); bad=bad+1; end
      if (fb(f,42) !== exp_op) begin $display("  [FAIL] f%0d 应答 op = %h (exp %h)", f, fb(f,42), exp_op); bad=bad+1; end
      if (fb(f,43) !== seq)    begin $display("  [FAIL] f%0d seq = %h (exp %h)", f, fb(f,43), seq); bad=bad+1; end
      if (fb(f,44) !== status) begin $display("  [FAIL] f%0d status = %h (exp %h)", f, fb(f,44), status); bad=bad+1; end
      if (fb(f,45) !== item)   begin $display("  [FAIL] f%0d item = %h (exp %h)", f, fb(f,45), item); bad=bad+1; end
      if (fb(f,46) !== {set, port}) begin
        $display("  [FAIL] f%0d set/port = %h (exp %h)", f, fb(f,46), {set,port}); bad=bad+1; end
      if (fb(f,47) !== len)    begin $display("  [FAIL] f%0d len = %h (exp %h)", f, fb(f,47), len); bad=bad+1; end
      // val 只有 32 bit，len > 4 时只能比对低 4 字节（避免越界读到 x 造成假失败）
      for (k = 0; k < ((len > 4) ? 4 : len); k = k + 1) begin
        if (fb(f,48+k) !== val[k*8 +: 8]) begin
          $display("  [FAIL] f%0d val[%0d] = %h (exp %h)", f, k, fb(f,48+k), val[k*8+:8]); bad=bad+1; end
      end
      if (bad == 0)
        $display("  [PASS] f%0d 应答: op=%h seq=%h st=%h item=%h setport=%h len=%h val=%h",
                 f, exp_op, seq, status, item, {set,port}, len, val);
      err_total = err_total + bad;
    end
  endtask

  // 等一条命令应答并校验
  task automatic expect_rsp(input [7:0] exp_op, input [7:0] seq, input [7:0] status,
                            input [7:0] item, input [3:0] set, input [3:0] port,
                            input [7:0] len, input [31:0] val, input integer tmo);
    integer t, f;
    begin
      t = 0; f = -1;
      while (f < 0 && t < tmo) begin
        find_rsp(f);
        if (f < 0) begin @(posedge clk); t = t + 1; end
      end
      if (f < 0) begin
        $display("  [FAIL] 超时未收到命令应答（op=%h seq=%h item=%h）", exp_op, seq, item);
        err_total = err_total + 1;
        rd_ptr = FR_N;
      end
      else begin
        chk_udp_rsp(f, exp_op, seq, status, item, set, port, len, val);
        rd_ptr = f + 1;
      end
    end
  endtask

  // ---- TEMP TRACE : 逐拍打 demux/cfg_get 握手 ----
  reg trace_on = 1'b0;
  reg [7:0] fsm = 8'd0;
  always @(posedge clk) begin
    if (trace_on) begin
      $display("    [TRC] rxst=%0d cur=%h wr=%b din=%h | fsm=%0d femp=%b fden=%b rvs1=%b | gv=%b gr=%b gh=%b | r1=%b r2=%b mv=%b mr=%b mhs=%b | rspv=%b rspr=%b",
        u_cfg.u_cfg_cmd_rx.state_reg,
        u_cfg.u_cfg_cmd_rx.active_data,
        u_cfg.u_cfg_cmd_rx.fifo_wr_en,
        u_cfg.u_cfg_cmd_rx.fifo_din[47:0],
        u_cfg.u_cfg_demux.state_reg,
        u_cfg.u_cfg_demux.frame_empty,
        u_cfg.u_cfg_demux.frame_rd_en,
        u_cfg.u_cfg_demux.rec_valid_s1,
        u_cfg.u_cfg_demux.get_valid,
        u_cfg.u_cfg_demux.get_ready,
        u_cfg.u_cfg_demux.get_handshake,
        u_cfg.u_cfg_get.rd_req_s1,
        u_cfg.u_cfg_get.rd_req_s2,
        u_cfg.u_cfg_get.rd_axis_mvalid_reg,
        u_cfg.u_cfg_get.rd_axis_mready,
        u_cfg.u_cfg_get.m_handshake,
        cmd_rsp_valid, cmd_rsp_ready);
    end
  end

  // ---- TEMP: 抓 cmd 口首拍与 cfg_cmd_rx 的 keep/slast ----
  reg mv_d = 0;
  always @(posedge clk) begin
    if (u_dut.udp_cmd_axis_mvalid[0] && !mv_d) begin
      $display("    [KEEP] keep=%h last=%b | proto=%h total_len=%h ttl=%h udp_len=%h dport=%h",
        u_dut.udp_cmd_axis_mkeep[CMD_PORT_SEL*64 +: 64],
        u_dut.udp_cmd_axis_mlast[CMD_PORT_SEL],
        u_dut.udp_cmd_axis_musr[CMD_PORT_SEL*241 +  97 +: 8],
        u_dut.udp_cmd_axis_musr[CMD_PORT_SEL*241 + 105 +: 16],
        u_dut.udp_cmd_axis_musr[CMD_PORT_SEL*241 + 121 +: 8],
        u_dut.udp_cmd_axis_musr[CMD_PORT_SEL*241 + 225 +: 16],
        u_dut.udp_cmd_axis_musr[CMD_PORT_SEL*241 + 193 +: 16]);
    end
    mv_d <= u_dut.udp_cmd_axis_mvalid[0];
    if (u_cfg.u_cfg_cmd_rx.state_reg == 5 && trace_on) begin
      $display("    [LEN] keep_s1=%h last_s1=%b use_last=%b cnt_next=%0d data=%h",
        u_cfg.u_cfg_cmd_rx.axis_skeep_s1,
        u_cfg.u_cfg_cmd_rx.axis_slast_s1,
        u_cfg.u_cfg_cmd_rx.is_use_last_data,
        u_cfg.u_cfg_cmd_rx.used_data_cnt_next,
        u_cfg.u_cfg_cmd_rx.active_data);
    end
  end

  // ---- TEMP: 记录 FIFO 写/读边沿计数 ----
  integer c_wr = 0, c_rd = 0, c_rxvalid = 0;
  reg wr_d = 0, rd_d = 0, rxv_d = 0;
  always @(posedge clk) begin
    if (u_cfg.u_cfg_cmd_rx.fifo_wr_en && !wr_d) c_wr = c_wr + 1;
    wr_d <= u_cfg.u_cfg_cmd_rx.fifo_wr_en;
    if (u_cfg.u_cfg_cmd_rx.fifo_rd_en && !rd_d) c_rd = c_rd + 1;
    rd_d <= u_cfg.u_cfg_cmd_rx.fifo_rd_en;
    if (u_dut.udp_cmd_axis_mvalid[0] && !rxv_d) c_rxvalid = c_rxvalid + 1;
    rxv_d <= u_dut.udp_cmd_axis_mvalid[0];
  end

  // ---- TEMP DEBUG : 各级脉冲计数 ----
  integer c_cr = 0, c_slr = 0, c_rxfifo = 0, c_skid = 0, c_mac = 0, c_ipv4 = 0;
  integer c_tx = 0, c_cmdfifo = 0, c_udp = 0;
  integer c_cmdmv = 0, c_cmdsv = 0, c_cmdsr = 0, c_rspv = 0, c_rspr = 0;
  integer c_rdreq = 0, c_dmx = 0, c_rxrec = 0;
  always @(posedge line_clk) begin
    if (u_dut.gen_port[0].u_eth_port_top.cr_valid)     c_cr  = c_cr + 1;
    if (u_dut.gen_port[0].u_eth_port_top.slr_rx_valid) c_slr = c_slr + 1;
    if (u_dut.gen_port[0].u_eth_port_top.ct_valid)     c_tx  = c_tx + 1;
  end
  always @(posedge clk) begin
    if (u_dut.gen_port[0].u_eth_port_top.fifo_rx_valid) c_rxfifo = c_rxfifo + 1;
    if (u_dut.gen_port[0].u_eth_port_top.skid_rx_valid) c_skid   = c_skid + 1;
    if (|u_dut.mac_axis_mvalid)  c_mac  = c_mac + 1;
    if (|u_dut.ipv4_axis_mvalid) c_ipv4 = c_ipv4 + 1;
    if (|u_dut.udp_axis_mvalid)  c_udp  = c_udp + 1;
    if (cmd_fifo_mvalid)   c_cmdfifo = c_cmdfifo + 1;
    if (u_dut.udp_cmd_axis_mvalid[0]) c_cmdmv = c_cmdmv + 1;
    if (u_dut.udp_cmd_axis_svalid[0]) c_cmdsv = c_cmdsv + 1;
    if (u_dut.udp_cmd_axis_sready[0]) c_cmdsr = c_cmdsr + 1;
    if (cmd_rsp_valid) c_rspv = c_rspv + 1;
    if (u_cfg.u_cfg_get.rd_req) c_rdreq = c_rdreq + 1;
    if (u_cfg.u_cfg_demux.get_valid) c_dmx = c_dmx + 1;

    if (cmd_rsp_ready) c_rspr = c_rspr + 1;
  end
  task automatic dbg_rep;
    begin
      $display("    [DBG] WR=%0d RD=%0d RXFRM=%0d | cr=%0d slr=%0d rxfifo=%0d skid=%0d udp=%0d | cmdmv=%0d cmdfifo=%0d rspv=%0d rspr=%0d tx=%0d | rxrec=%0d dmx=%0d rdreq=%0d",
               c_wr, c_rd, c_rxvalid, c_cr, c_slr, c_rxfifo, c_skid, c_udp,
               c_cmdmv, c_cmdfifo, c_rspv, c_rspr, c_tx,
               c_rxrec, c_dmx, c_rdreq);
    end
  endtask

  // ==========================================================================
  // 主流程
  // ==========================================================================
  initial begin
    $display("================================================================");
    $display(" net_stack_top 全链路仿真（含 cfg 命令通道）");
    $display("================================================================");

    #100; clk_locked = 1'b1;
    #100; usr_rst    = 1'b0;
    repeat (300) @(posedge clk);

    // ---------------- P1 链路上报 ----------------
    $display("--- P1: 复位后 stat_link_status 两口都应为 1 ---");
    if (stat_link_status !== {ETH_PORT_NUM{1'b1}}) begin
      $display("  [FAIL] stat_link_status = %b (exp 全 1)；口0 源=stat_rx_aligned，口1 源=stat_rx_status",
               stat_link_status);
      err_total = err_total + 1;
    end else $display("  [PASS] stat_link_status = %b（口0 stat_rx_aligned / 口1 stat_rx_status）",
                      stat_link_status);

    // ---------------- P2 ARP 学习 ----------------
    $display("--- P2: 对端 ARP 请求 -> 设备应答（并学习 ARP 表）---");
    send_arp_req(DEV_IP_N);
    begin : wait_arp
      integer t;
      t = 0;
      while (FR_N < 1 && t < 6000) begin @(posedge clk); t = t + 1; end
    end
    if (FR_N < 1) begin
      $display("  [FAIL] 未收到 ARP 应答");
      err_total = err_total + 1;
    end
    else if (fb(0,12) !== 8'h08 || fb(0,13) !== 8'h06) begin
      $display("  [FAIL] f0 以太类型 = %h%h (exp 0806)", fb(0,12), fb(0,13));
      err_total = err_total + 1;
    end
    else if ({fb(0,20),fb(0,21)} !== 16'h0002 ||
             {fb(0,38),fb(0,39),fb(0,40),fb(0,41)} !== PEER_IP_N) begin
      $display("  [FAIL] f0 ARP 应答: op=%h%h tpa=%h%h%h%h (exp 0002 / %h)",
               fb(0,20),fb(0,21), fb(0,38),fb(0,39),fb(0,40),fb(0,41), PEER_IP_N);
      err_total = err_total + 1;
    end
    else if ({fb(0,28),fb(0,29),fb(0,30),fb(0,31)} !== DEV_IP_N) begin
      $display("  [FAIL] f0 ARP 应答 spa = %h%h%h%h (exp %h)",
               fb(0,28),fb(0,29),fb(0,30),fb(0,31), DEV_IP_N);
      err_total = err_total + 1;
    end
    else $display("  [PASS] f0 ARP 应答正确（op=reply, spa=本机 IP, tpa=对端 IP）");
    dbg_rep();

    // ---------------- P3 GET 0x00 ----------------
    $display("--- P3: GET 0x00（本机 IPv4）---");
    send_cmd(8'h02, 8'h01, 8'h00, 4'd0, 4'd0, 8'd0, 32'd0, DEV_IP_N);
    trace_on = 1'b1;
    repeat (40) @(posedge clk);
    trace_on = 1'b0;
    repeat (80) @(posedge clk);
    expect_rsp(8'h82, 8'h01, 8'h00, 8'h00, 4'd0, 4'd0, 8'd4, DEV_IP, 6000);
    dbg_rep();

    // ---------------- P4 GET 0x52 LINK_STATUS ----------------
    $display("--- P4: GET 0x52（LINK_STATUS）---");
    send_cmd(8'h02, 8'h02, 8'h52, 4'd0, 4'd0, 8'd0, 32'd0, DEV_IP_N);
    expect_rsp(8'h82, 8'h02, 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 6000);
    dbg_rep();

    // ---------------- P5 SET/GET 0x03 ----------------
    $display("--- P5: SET 0x03 = 255.255.0.0，再 GET 读回 ---");
    send_cmd(8'h01, 8'h03, 8'h03, 4'd0, 4'd0, 8'd4, 32'h0000_FFFF, DEV_IP_N);
    expect_rsp(8'h81, 8'h03, 8'h00, 8'h03, 4'd0, 4'd0, 8'd4, 32'd0, 6000);   // SET 应答回显请求 LEN
    dbg_rep();
    send_cmd(8'h02, 8'h04, 8'h03, 4'd0, 4'd0, 8'd0, 32'd0, DEV_IP_N);
    expect_rsp(8'h82, 8'h04, 8'h00, 8'h03, 4'd0, 4'd0, 8'd4, 32'h0000_FFFF, 6000);
    dbg_rep();

    // ---------------- P6 目的 IP 非本机 ----------------
    $display("--- P6: 目的 IP 非本机 -> 不应有应答 ---");
    send_cmd(8'h02, 8'h05, 8'h00, 4'd0, 4'd0, 8'd0, 32'd0, BAD_IP_N);
    repeat (3000) @(posedge clk);
    begin : chk_drop
      integer f;
      f = -1; find_rsp(f);
      if (f >= 0) begin
        $display("  [FAIL] 期望无应答，却收到 f%0d", f);
        err_total = err_total + 1;
      end else $display("  [PASS] 无应答（准入过滤生效）");
      rd_ptr = FR_N;
    end

    // ---------------- P7 统计项 ----------------
    $display("--- P7: GET 0x60 ARP_STAT / 0x61 ICMP_STAT ---");
    send_cmd(8'h02, 8'h06, 8'h60, 4'd0, 4'd0, 8'd0, 32'd0, DEV_IP_N);
    begin : chk_arpstat
      integer t, f;
      t = 0; f = -1;
      while (f < 0 && t < 6000) begin find_rsp(f); if (f<0) begin @(posedge clk); t=t+1; end end
      if (f < 0) begin $display("  [FAIL] 0x60 无应答"); err_total=err_total+1; end
      else if (fb(f,47) !== 8'd4) begin
        $display("  [FAIL] 0x60 len = %d (exp 4)", fb(f,47)); err_total=err_total+1; end
      else $display("  [PASS] 0x60 ARP_STAT = %h%h%h%h（7bit sticky 在最低字节）",
                    fb(f,51),fb(f,50),fb(f,49),fb(f,48));
      rd_ptr = FR_N;
    end

    send_cmd(8'h02, 8'h07, 8'h61, 4'd0, 4'd0, 8'd0, 32'd0, DEV_IP_N);
    begin : chk_icmpstat
      integer t, f;
      t = 0; f = -1;
      while (f < 0 && t < 6000) begin find_rsp(f); if (f<0) begin @(posedge clk); t=t+1; end end
      if (f < 0) begin $display("  [FAIL] 0x61 无应答"); err_total=err_total+1; end
      else if (fb(f,47) !== 8'd1) begin
        $display("  [FAIL] 0x61 len = %d (exp 1)", fb(f,47)); err_total=err_total+1; end
      else $display("  [PASS] 0x61 ICMP_STAT = %h（4bit sticky）", fb(f,48));
      rd_ptr = FR_N;
    end

    // ---------------- P8 单帧多 TLV（62B，>最小帧 → 不得裁剪）----------------
    $display("--- P8: 单帧 4 条 GET TLV（帧 62B，不填充）---");
    send_cmd_multi;
    expect_rsp(8'h82, 8'h31, 8'h00, 8'h00, 4'd0, 4'd0, 8'd4, DEV_IP,              8000);
    expect_rsp(8'h82, 8'h32, 8'h00, 8'h03, 4'd0, 4'd0, 8'd4, 32'h0000_FFFF,       8000);
    expect_rsp(8'h82, 8'h33, 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001,       8000);
    expect_rsp(8'h82, 8'h34, 8'h00, 8'h61, 4'd0, 4'd0, 8'd1, 32'h0000_0000,       8000);

    // ---------------- P9 连续 3 条命令背靠背（帧间无空隙）----------------
    $display("--- P9: 连续 3 条命令背靠背 ---");
    send_cmd(8'h02, 8'h41, 8'h00, 4'd0, 4'd0, 8'd0, 32'd0, DEV_IP_N);
    send_cmd(8'h02, 8'h42, 8'h52, 4'd0, 4'd0, 8'd0, 32'd0, DEV_IP_N);
    send_cmd(8'h02, 8'h43, 8'h03, 4'd0, 4'd0, 8'd0, 32'd0, DEV_IP_N);
    expect_rsp(8'h82, 8'h41, 8'h00, 8'h00, 4'd0, 4'd0, 8'd4, DEV_IP,        8000);
    expect_rsp(8'h82, 8'h42, 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 8000);
    expect_rsp(8'h82, 8'h43, 8'h00, 8'h03, 4'd0, 4'd0, 8'd4, 32'h0000_FFFF, 8000);

    // ---------------- P10 畸形帧 total_length=0（契约外，验证不卡死）----------------
    $display("--- P10: 畸形帧 total_length=0 -> 命令通道不得卡死 ---");
    send_bad_len_frame;
    repeat (3000) @(posedge clk);
    send_cmd(8'h02, 8'h51, 8'h00, 4'd0, 4'd0, 8'd0, 32'd0, DEV_IP_N);
    expect_rsp(8'h82, 8'h51, 8'h00, 8'h00, 4'd0, 4'd0, 8'd4, DEV_IP, 8000);
    if (err_total == err_p10) $display("  [PASS] 畸形帧未卡死命令通道，后续命令正常");
    else                      $display("  [FAIL] 畸形帧影响后续命令");
    err_p10 = err_total;

    // ---------------- P11 跨拍多 TLV（126B / 2 拍）----------------
    $display("--- P11: 126B 两拍帧，4 条 SET TLV（每根都带 OP/SEQ）---");
    send_cmd_multi_long;
    expect_rsp(8'h81, 8'hA1, 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);   // SET 应答回显 LEN，不带 VAL
    expect_rsp(8'h81, 8'hA2, 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);   // SET 应答回显 LEN，不带 VAL
    expect_rsp(8'h81, 8'hA3, 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);   // SET 应答回显 LEN，不带 VAL
    expect_rsp(8'h81, 8'hA4, 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);   // SET 应答回显 LEN，不带 VAL
    // 读回确认最后一次写入生效
    send_cmd(8'h02, 8'hA5, 8'h04, 4'd0, 4'd0, 8'd0, 32'd0, DEV_IP_N);
    expect_rsp(8'h82, 8'hA5, 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'h4433_2211, 8000);

    // ---------------- P12 帧尾正好落在 beat 末字节（payload 恰好 64B）----------------
    //   UDP 层 keep = 64 位全 1、slast=1 => 帧尾正好是 beat 最后一个字节，
    //   状态机从 S_VAL_LOOP 直接跳 S_OP、跳过 S_IDLE；连发两帧验证侧带不串
    $display("--- P12: 两帧各 64B payload / 8 条 TLV（帧尾对齐 beat 末字节，跳过 S_IDLE）---");
    send_cmd_exact64(8'hD0);
    send_cmd_exact64(8'hE0);
    expect_rsp(8'h81, (8'hD0 + 8'd0), 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);
    expect_rsp(8'h81, (8'hD0 + 8'd1), 8'h00, 8'h03, 4'd0, 4'd0, 8'd4, 32'd0, 8000);
    expect_rsp(8'h81, (8'hD0 + 8'd2), 8'h00, 8'h03, 4'd0, 4'd0, 8'd4, 32'd0, 8000);
    expect_rsp(8'h82, (8'hD0 + 8'd3), 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 8000);
    expect_rsp(8'h82, (8'hD0 + 8'd4), 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 8000);
    expect_rsp(8'h82, (8'hD0 + 8'd5), 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 8000);
    expect_rsp(8'h82, (8'hD0 + 8'd6), 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 8000);
    expect_rsp(8'h82, (8'hD0 + 8'd7), 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 8000);
    expect_rsp(8'h81, (8'hE0 + 8'd0), 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);
    expect_rsp(8'h81, (8'hE0 + 8'd1), 8'h00, 8'h03, 4'd0, 4'd0, 8'd4, 32'd0, 8000);
    expect_rsp(8'h81, (8'hE0 + 8'd2), 8'h00, 8'h03, 4'd0, 4'd0, 8'd4, 32'd0, 8000);
    expect_rsp(8'h82, (8'hE0 + 8'd3), 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 8000);
    expect_rsp(8'h82, (8'hE0 + 8'd4), 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 8000);
    expect_rsp(8'h82, (8'hE0 + 8'd5), 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 8000);
    expect_rsp(8'h82, (8'hE0 + 8'd6), 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 8000);
    expect_rsp(8'h82, (8'hE0 + 8'd7), 8'h00, 8'h52, 4'd0, 4'd0, 8'd1, 32'h0000_0001, 8000);

    // ---------------- P13 3 拍命令帧（payload 147B / 7 条 SET）----------------
    $display("--- P13: 189B 三拍帧，7 条 SET 0x04 LEN=16 ---");
    send_cmd_3beat;
    expect_rsp(8'h81, (8'hC0 + 8'd0), 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);
    expect_rsp(8'h81, (8'hC0 + 8'd1), 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);
    expect_rsp(8'h81, (8'hC0 + 8'd2), 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);
    expect_rsp(8'h81, (8'hC0 + 8'd3), 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);
    expect_rsp(8'h81, (8'hC0 + 8'd4), 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);
    expect_rsp(8'h81, (8'hC0 + 8'd5), 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);
    expect_rsp(8'h81, (8'hC0 + 8'd6), 8'h00, 8'h04, 4'd0, 4'd0, 8'd16, 32'd0, 8000);

    // ---------------- 帧 dump ----------------
    $display("--- 捕获帧一览 ---");
    for (i = 0; i < FR_N; i = i + 1) begin
      if (fb(i,12) === 8'h08 && fb(i,13) === 8'h06)
        $display("  f%0d len=%0d ARP op=%h%h", i, FR_LEN[i], fb(i,20), fb(i,21));
      else if (fb(i,12) === 8'h08 && fb(i,13) === 8'h00 && fb(i,23) === 8'h11)
        $display("  f%0d t=%0t len=%0d UDP %h%h->%h%h op=%h seq=%h st=%h item=%h lenB=%h sp=%h val=%h%h%h%h",
                 i, FR_T[i], FR_LEN[i], fb(i,34),fb(i,35), fb(i,36),fb(i,37),
                 fb(i,42), fb(i,43), fb(i,44), fb(i,45), fb(i,47), fb(i,46),
                 fb(i,48),fb(i,49),fb(i,50),fb(i,51));
      else
        $display("  f%0d len=%0d et=%h%h proto=%h", i, FR_LEN[i], fb(i,12), fb(i,13), fb(i,23));
    end

    // ---------------- 汇总 ----------------
    $display("================================================================");
    $display(" 收到帧总数 = %0d（捕获侧 tvalid 拍数 = %0d）", FR_N, c_capv);
    if (err_total == 0) $display(" *** ALL TESTS PASSED ***");
    else                $display(" *** %0d CHECK(S) FAILED ***", err_total);
    $display("================================================================");
    $finish;
  end

  initial begin
    #40_000_000;
    $display("  [FAIL] GLOBAL TIMEOUT");
    $finish;
  end

endmodule
`resetall
