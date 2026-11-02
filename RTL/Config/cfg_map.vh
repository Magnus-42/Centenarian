`ifndef CFG_MAP_VH
`define CFG_MAP_VH
// ============================================================================
// File Name   : cfg_map.vh
// Module Name : (header)
// Author      : LiXintao
// Date        : 2026-10-22
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 配置命令协议常量表 —— 操作码 / 状态码 / ITEM 编号 / 逐口逐套默认值
// ============================================================================


`define CFG_MAX_VALUE_BYTES 16 // TLV字段V最长的字节数，暂定为IPV6的地址长度

// ----------------------------------------------------------------------------
// 操作码
// ----------------------------------------------------------------------------
// 请求码
`define CFG_OP_SET          8'h01
`define CFG_OP_GET          8'h02

// 应答码（与请求码一一对应）
`define CFG_OP_SET_RSP      8'h81
`define CFG_OP_GET_RSP      8'h82
`define CFG_OP_ERR_RSP      8'h8F // 请求 OP 无法识别时使用。

// ----------------------------------------------------------------------------
// 状态码: 应答帧第 3 字节 STATUS
// ----------------------------------------------------------------------------
`define CFG_ST_OK           8'h00
`define CFG_ST_BAD_OP       8'h01
`define CFG_ST_BAD_ITEM     8'h02
`define CFG_ST_BAD_SET      8'h03
`define CFG_ST_BAD_PORT     8'h04
`define CFG_ST_BAD_LEN      8'h05
`define CFG_ST_WRITE_ONLY   8'h06
`define CFG_ST_READ_ONLY    8'h07

// MAC 和 IP 
`define CFG_RW_IPV4_LOCAL_IP      8'h00 
`define CFG_RW_IPV4_LOCAL_MAC     8'h01 
`define CFG_RW_IPV4_GATEWAY       8'h02 
`define CFG_RW_IPV4_MASK          8'h03 
`define CFG_RW_IPV6_SRC_LOCAL     8'h04
`define CFG_RW_IPV6_SRC_MAC       8'h05 
`define CFG_RW_IPV6_DST_LOCAL     8'h06
`define CFG_RW_IPV6_DST_MAC       8'h07

// 分流规则
`define CFG_RW_ETH_TYPE_DICT      8'h10
`define CFG_RW_IPV4_PROTO_DICT    8'h11
`define CFG_RW_IPV6_NH_DICT       8'h12
`define CFG_RW_UDP_PORT_RANGE     8'h13

// 行为参数
`define CFG_RW_PENDING_TIME  8'h30
`define CFG_RW_ARP_PRIO      8'h31
`define CFG_RW_ICMP_PRIO     8'h32
`define CFG_RW_CMD_UDP_PORT  8'h33
`define CFG_RW_CMD_UDP_PRIO  8'h34

// 动作 TODO: 发送ARP
`define CFG_W_RESET_DEF     8'h40
`define CFG_W_CACHE_CLEAR   8'h41
`define CFG_W_PEND_CLEAR    8'h42
`define CFG_W_STAT_CLEAR    8'h43

// 全局信息 / 状态
`define CFG_R_VERSION       8'h51
`define CFG_R_LINK_STATUS   8'h52
`define CFG_R_TX_IDLE       8'h53
`define CFG_R_TX_ACTIVE     8'h54
`define CFG_R_IS_DF         8'h55

// 逐口统计 / 计数
`define CFG_R_ARP_STAT      8'h60
`define CFG_R_ICMP_STAT     8'h61

// 配置边界
`define CFG_R_GEOMETRY      8'h70
`define CFG_R_GEOMETRY_MAX  8'h71
`define CFG_R_PORT_NUM      8'h72

// ----------------------------------------------------------------------------
// 默认值
// ----------------------------------------------------------------------------
// ---- 口 0 默认地址（套数必须与 CFG_MAX_V4_SET_NUM 一致，否则打包时被静默截断）----
`define CFG_DEF_IPV4_IP_P0        {32'h0901_A8C0}                                  // 192.168.1.9
`define CFG_DEF_IPV4_MAC_P0       {48'h010000_311900}                             // 00:19:31:00:00:01
`define CFG_DEF_IPV4_GW_P0        {32'h0101_A8C0}                                  // 192.168.1.1
`define CFG_DEF_IPV4_MASK_P0      {32'h00FF_FFFF}                                  // 255.255.255.0


`define CFG_DEF_IPV6_SRC_P0       {128'h0100_0000_0000_0000_0000_0100_b80d_0120, 128'h0100_0000_0000_0000_0000_0000_b80d_0120}
`define CFG_DEF_IPV6_SRC_MAC_P0   {48'h0B0000_311900, 48'h090000_311900}
`define CFG_DEF_IPV6_DST_P0      {128'h0200_0000_0000_0000_0000_0100_b80d_0120, 128'h0200_0000_0000_0000_0000_0000_b80d_0120}
`define CFG_DEF_IPV6_DST_MAC_P0  {48'h0C0000_311900, 48'h0A0000_311900}


// ---- 口 1 默认地址（套数必须与 CFG_MAX_V4_SET_NUM 一致，否则打包时被静默截断）----
`define CFG_DEF_IPV4_IP_P1        {32'h0801_A8C0}                                  // 192.168.1.8
`define CFG_DEF_IPV4_MAC_P1       {48'h020000_311900}                             // 00:19:31:00:00:02
`define CFG_DEF_IPV4_GW_P1        {32'h0101_A8C0}                                  // 192.168.1.1
`define CFG_DEF_IPV4_MASK_P1      {32'h00FF_FFFF}                                  // 255.255.255.0

`define CFG_DEF_IPV6_SRC_P1       {128'h0200_0000_0000_0000_0000_0100_b80d_0120, 128'h0200_0000_0000_0000_0000_0000_b80d_0120}
`define CFG_DEF_IPV6_SRC_MAC_P1   {48'h0F0000_311900, 48'h0D0000_311900}
`define CFG_DEF_IPV6_DST_P1      {128'h0100_0000_0000_0000_0000_0100_b80d_0120, 128'h0100_0000_0000_0000_0000_0000_b80d_0120}
`define CFG_DEF_IPV6_DST_MAC_P1  {48'h100000_311900, 48'h0E0000_311900}

`define CFG_NUM_PORT            4'd2       // 网口数，等价ETH_PORT_NUM
`define CFG_COUNT_WIDTH         8       // 档数/套数计数字段位宽，等价CFG_NUM_WIDTH

// ---- 每口档数 / 套数上限 ----（"能改每档认什么，不能改有几档"）
`define CFG_MAX_MAC_RX_NUM      ({`CFG_COUNT_WIDTH{1'b0}} | 2'd2)       // 用户自定义 MAC 类型 RX 档数
`define CFG_MAX_MAC_TX_NUM      ({`CFG_COUNT_WIDTH{1'b0}} | 2'd3)       // 用户自定义 MAC 类型 TX 档数
`define CFG_MAX_IPV4_RX_NUM     ({`CFG_COUNT_WIDTH{1'b0}} | 2'd3)       // IPv4 协议号 RX 档数
`define CFG_MAX_IPV4_TX_NUM     ({`CFG_COUNT_WIDTH{1'b0}} | 3'd4)       // IPv4 协议号 TX 档数
`define CFG_MAX_ICMP_TX_NUM     ({`CFG_COUNT_WIDTH{1'b0}} | 1'd0)       // ICMPv4 用户 TX 档数（0 = 只做内部 echo）
`define CFG_MAX_IPV6_RX_NUM     ({`CFG_COUNT_WIDTH{1'b0}} | 2'd3)       // IPv6 下一首部 RX 档数
`define CFG_MAX_IPV6_TX_NUM     ({`CFG_COUNT_WIDTH{1'b0}} | 2'd3)       // IPv6 下一首部 TX 档数
`define CFG_MAX_UDP_RX_NUM      ({`CFG_COUNT_WIDTH{1'b0}} | 2'd3)       // UDP 目的端口区间 RX 路数
`define CFG_MAX_UDP_TX_NUM      ({`CFG_COUNT_WIDTH{1'b0}} | 4'd8)       // UDP 目的端口 TX 路数
`define CFG_MAX_V4_SET_NUM      ({`CFG_COUNT_WIDTH{1'b0}} | 1'd1)       // 每口 IPv4 地址套数（本机 IP/MAC/网关/掩码）
`define CFG_MAX_V6_SRC_SET_NUM  ({`CFG_COUNT_WIDTH{1'b0}} | 2'd2)       // 每口本机 IPv6 套数
`define CFG_MAX_V6_DST_SET_NUM  ({`CFG_COUNT_WIDTH{1'b0}} | 2'd2)       // 每口邻居 IPv6 套数
`define CFG_MAX_PENDING_TIME_WIDTH  ({`CFG_COUNT_WIDTH{1'b0}} | 6'd57)
`define CFG_MAX_ARBITER_VAL_WIDTH  ({`CFG_COUNT_WIDTH{1'b0}} | 3'd4)  

// ---- 每口实际档数 / 套数（口 1 在高位、口 0 在低位）----
`define CFG_DEF_MAC_RX_NUM_ARR      {({`CFG_COUNT_WIDTH{1'b0}} | 1'd1), ({`CFG_COUNT_WIDTH{1'b0}} | 2'd2)}
`define CFG_DEF_MAC_TX_NUM_ARR      {({`CFG_COUNT_WIDTH{1'b0}} | 2'd3), ({`CFG_COUNT_WIDTH{1'b0}} | 2'd2)}
`define CFG_DEF_IPV4_RX_NUM_ARR     {({`CFG_COUNT_WIDTH{1'b0}} | 2'd3), ({`CFG_COUNT_WIDTH{1'b0}} | 2'd3)}
`define CFG_DEF_IPV4_TX_NUM_ARR     {({`CFG_COUNT_WIDTH{1'b0}} | 3'd4), ({`CFG_COUNT_WIDTH{1'b0}} | 3'd4)}
`define CFG_DEF_ICMP_TX_NUM_ARR     {({`CFG_COUNT_WIDTH{1'b0}} | 1'd0), ({`CFG_COUNT_WIDTH{1'b0}} | 1'd0)}
`define CFG_DEF_IPV6_RX_NUM_ARR     {({`CFG_COUNT_WIDTH{1'b0}} | 2'd3), ({`CFG_COUNT_WIDTH{1'b0}} | 2'd3)}
`define CFG_DEF_IPV6_TX_NUM_ARR     {({`CFG_COUNT_WIDTH{1'b0}} | 2'd3), ({`CFG_COUNT_WIDTH{1'b0}} | 2'd3)}
`define CFG_DEF_UDP_RX_NUM_ARR      {({`CFG_COUNT_WIDTH{1'b0}} | 2'd2), ({`CFG_COUNT_WIDTH{1'b0}} | 2'd3)}
`define CFG_DEF_UDP_TX_NUM_ARR      {({`CFG_COUNT_WIDTH{1'b0}} | 3'd4), ({`CFG_COUNT_WIDTH{1'b0}} | 4'd8)}
`define CFG_DEF_V4_SET_NUM_ARR      {({`CFG_COUNT_WIDTH{1'b0}} | 1'd1), ({`CFG_COUNT_WIDTH{1'b0}} | 1'd1)}
`define CFG_DEF_V6_SRC_NUM_ARR      {({`CFG_COUNT_WIDTH{1'b0}} | 2'd2), ({`CFG_COUNT_WIDTH{1'b0}} | 2'd2)}
`define CFG_DEF_V6_DST_NUM_ARR      {({`CFG_COUNT_WIDTH{1'b0}} | 2'd2), ({`CFG_COUNT_WIDTH{1'b0}} | 2'd2)}
`define CFG_DEF_PT_WIDTH_ARR      {({`CFG_COUNT_WIDTH{1'b0}} | 6'd57),({`CFG_COUNT_WIDTH{1'b0}} | 6'd57)}
`define CFG_DEF_ARB_VAL_WIDTH_ARR   {({`CFG_COUNT_WIDTH{1'b0}} | 3'd4), ({`CFG_COUNT_WIDTH{1'b0}} | 3'd4)}

// ---- 分流表默认值（口1 在高位、口0 在低位；槽 0 = 每口的最低位字）----
// 用户自定义 MAC 类型：口1 = 槽0:0x88B5 / 槽1:未用；口0 = 槽0:0x88B5 / 槽1:0x88CC
`define CFG_DEF_MAC_RX_DICT_ARR     {16'h0000, 16'hB588, 16'hCC88, 16'hB588}
// IPv4 协议号：口1 = 槽0:0x06 / 槽1:0x01 / 槽2:0x59；口0 = 槽0:0x01 / 槽1:0x59 / 槽2:0x06
`define CFG_DEF_IPV4_RX_DICT_ARR    {8'h59, 8'h01, 8'h06, 8'h06, 8'h59, 8'h01}
// IPv6 下一首部：口1 = 槽0:0x11 / 槽1:0x59 / 槽2:0x3A；口0 = 槽0:0x11 / 槽1:0x3A / 槽2:0x59
`define CFG_DEF_IPV6_RX_DICT_ARR    {8'h3A, 8'h59, 8'h11, 8'h59, 8'h3A, 8'h11}
// UDP 目的端口区间：口1 = 槽0 [2,2] / 槽1 [4,8] / 槽2 未用；口0 = 槽0 [0,0] / 槽1 [1,1] / 槽2 [2,8]
`define CFG_DEF_UDP_PORT_RANGE_ARR  {32'd0, 32'h0008_0004, 32'h0002_0002, 32'h0008_0002, 32'h0001_0001, 32'h0000_0000}

// ---- 行为参数 ----
`define CFG_DEF_PENDING      {({`CFG_MAX_PENDING_TIME_WIDTH{1'b0}} | 57'd200_000_000),({`CFG_MAX_PENDING_TIME_WIDTH{1'b0}} | 57'd400_000_000)}   // 口1 = 0.5 s、口0 = 1 s @400MHz
`define CFG_DEF_ARP_PRIO     {({`CFG_MAX_ARBITER_VAL_WIDTH{1'b0}} | 4'd15),({`CFG_MAX_ARBITER_VAL_WIDTH{1'b0}} | 4'd15)}            // 同时作 net_stack_top 的 ARP_PRIORITY(取低 4 位)
`define CFG_DEF_ICMP_PRIO    {({`CFG_MAX_ARBITER_VAL_WIDTH{1'b0}} | 4'd12),({`CFG_MAX_ARBITER_VAL_WIDTH{1'b0}} | 4'd12)}             // 同时作 net_stack_top 的 ICMPV4_PRIORITY(取低 4 位)

// ---- 命令通道（UDP 内部档）----
// 命令通道只绑定一个网口：该口接 UDP 命令档 <-> cfg_cmd_top，其余口的命令档恒不匹配
`define CFG_CMD_PORT_SEL    4'd0                                                                                                 // 命令通道绑定的网口号(必须 < CFG_NUM_PORT)
`define CFG_DEF_CMD_UDP_PORT {16'hC0DE, 16'hC0DE}                                                                                  // 每口一份：命令通道 UDP 端口
`define CFG_DEF_CMD_UDP_PRIO {({`CFG_MAX_ARBITER_VAL_WIDTH{1'b0}} | 4'd9),({`CFG_MAX_ARBITER_VAL_WIDTH{1'b0}} | 4'd9)}             // 每口一份：应答仲裁优先级(0=禁用)

`define CFG_VERSION_WORD     32'h0001_0100  // {主, 次, 构建, 协议}

`endif
