// -----------------------------------------------------------------------------
// File Name   : cfg_protocol.vh
// Description : 单口配置协议的操作码、应答状态和配置项编号。
// -----------------------------------------------------------------------------

`ifndef ETH_STACK_CFG_PROTOCOL_VH
`define ETH_STACK_CFG_PROTOCOL_VH

// 协议标识
`define CFG_PROTOCOL_STAMP 16'h3119

// 操作码
`define CFG_OP_GET 3'd1
`define CFG_OP_SET 3'd2
`define CFG_OP_EXEC 3'd3
`define CFG_OP_RESPONSE 3'd4

// 应答状态
`define CFG_ST_OK 8'h00
`define CFG_ST_BAD_OP 8'h01
`define CFG_ST_BAD_ITEM 8'h02
`define CFG_ST_BAD_INDEX 8'h03
`define CFG_ST_ACCESS_DENIED 8'h04
`define CFG_ST_BAD_VALUE_LENGTH 8'h05

// 0x10～0x1F 本口管理
`define CFG_MGMT_MAC_ADDR 8'h10
`define CFG_MGMT_IPV4_ADDR 8'h11
`define CFG_MGMT_UDP_PORT 8'h12
`define CFG_LINK_STATE 8'h13
`define CFG_IP_TX_DROP_FLAGS 8'h14
`define CFG_CLEAR_PORT_FLAGS 8'h15
`define CFG_RESTORE_PORT_DEFAULTS 8'h16

// 0x20～0x2F IPv4、ARP、ICMPv4 和 UDP 分流配置。
//// IPv4地址配置
`define CFG_IPV4_LOCAL_IP 8'h20
`define CFG_IPV4_LOCAL_MAC 8'h21
`define CFG_IPV4_GATEWAY 8'h22
`define CFG_IPV4_MASK 8'h23

//// ARP配置与状态
`define CFG_ARP_PENDING_TIMEOUT_MS 8'h24
`define CFG_ARP_TX_PRIORITY 8'h25
`define CFG_ARP_ERROR_FLAGS 8'h26
`define CFG_ARP_CLEAR_STATE 8'h27
`define CFG_ARP_CLEAR_CACHE 8'h28
`define CFG_ARP_CLEAR_PENDING 8'h29
`define CFG_ARP_ANNOUNCE_MASK 8'h2a
`define CFG_ARP_ANNOUNCE_SEND 8'h2b

//// ICMP配置与状态
`define CFG_ICMP_ECHO_PRIORITY 8'h2c
`define CFG_ICMP_ERROR_FLAGS 8'h2d

//// UDP接收端口配置
`define CFG_UDP_IPV4_RX_PORT_RANGE 8'h2e
`define CFG_UDP_IPV6_RX_PORT_RANGE 8'h2f

// 0x40～0x5F IPv6相关配置，0x50～0x5F预留给新增模块。
`define CFG_IPV6_SRC_IP 8'h40
`define CFG_IPV6_SRC_MAC 8'h41
`define CFG_IPV6_DST_IP 8'h42
`define CFG_IPV6_DST_MAC 8'h43

`endif
