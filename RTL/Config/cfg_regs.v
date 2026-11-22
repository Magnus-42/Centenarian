// -----------------------------------------------------------------------------
// File Name   : cfg_regs.v
// Module Name : cfg_regs
// Author      : Codex
// Created     : 2026-11-19
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 译码本口配置项，保存配置并采样状态。
// Note        : 译码、结果和提交依次在三个时钟沿完成。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

`include "cfg_protocol.vh"

module cfg_regs #(
    parameter integer LocalIpv4Count = 3,  // 小于255
    parameter integer SrcIpv6Count = 2,
    parameter integer DstIpv6Count = 3,
    parameter integer UdpIpv4RxCount = 3,
    parameter integer UdpIpv6RxCount = 3,
    parameter integer ReqWidth = 4,
    parameter integer PendingTimeWidth = 24,
    parameter [32*LocalIpv4Count-1:0] DefaultLocalIp = {
      32'h1001_a8c0, 32'h1101_a8c0, 32'h1201_a8c0
    },
    parameter [48*LocalIpv4Count-1:0] DefaultLocalMac = {
      48'h0100_3119_0000, 48'h0200_3119_0000, 48'h0300_3119_0000
    },
    parameter [32*LocalIpv4Count-1:0] DefaultGatewayIp = {
      32'h0101_a8c0, 32'h0101_a8c0, 32'h0101_a8c0
    },
    parameter [32*LocalIpv4Count-1:0] DefaultSubnetMask = {
      32'h00ff_ffff, 32'h00ff_ffff, 32'h00ff_ffff
    },
    parameter [128*SrcIpv6Count-1:0] DefaultSrcIpv6 = {
      128'h1100_3119_0000_0000_0000_0000_0000_80FE, 128'h1200_3119_0000_0000_0000_0000_0000_80FE
    },
    parameter [48*SrcIpv6Count-1:0] DefaultSrcMac = {48'h1100_3119_0000, 48'h1200_3119_0000},
    parameter [128*DstIpv6Count-1:0] DefaultDstIpv6 = {
      128'h2100_3119_0000_0000_0000_0000_0000_80FE,
      128'h2200_3119_0000_0000_0000_0000_0000_80FE,
      128'h2300_3119_0000_0000_0000_0000_0000_80FE
    },
    parameter [48*DstIpv6Count-1:0] DefaultDstMac = {
      48'h2100_3119_0000, 48'h2200_3119_0000, 48'h2300_3119_0000
    },
    parameter [32*UdpIpv4RxCount-1:0] DefaultUdpIpv4Range = {
      32'h3000_2000, 32'h1000_1000, 32'h0800_0000
    },
    parameter [32*UdpIpv6RxCount-1:0] DefaultUdpIpv6Range = {
      32'h3000_2000, 32'h1000_1000, 32'h0800_0000
    },
    parameter [PendingTimeWidth-1:0] DefaultPendingTime = 24'd1000,
    parameter [ReqWidth-1:0] DefaultArpPriority = {ReqWidth{1'b1}},
    parameter [ReqWidth-1:0] DefaultIcmpPriority = 4'd12,
    parameter [31:0] DefaultMgmtIpv4Addr = 32'h0901_a8c0,
    parameter [15:0] DefaultMgmtUdpPort = 16'h0600,
    parameter [47:0] DefaultMgmtMac = 48'hf100_3119_0000
) (
    input wire clk,
    input wire rst,

    input  wire         exec_valid,
    input  wire [  2:0] req_op,
    input  wire [  7:0] req_item,
    input  wire [  7:0] req_index,
    input  wire [  7:0] req_len,
    input  wire [127:0] req_value,
    output wire [  7:0] rsp_status,
    output wire [  7:0] rsp_len,
    output wire [127:0] rsp_value,

    // IPv4地址配置
    output wire [32*LocalIpv4Count-1:0] cfg_local_ip,
    output wire [48*LocalIpv4Count-1:0] cfg_local_mac,
    output wire [32*LocalIpv4Count-1:0] cfg_gateway_ip,
    output wire [32*LocalIpv4Count-1:0] cfg_subnet_mask,

    // IPv6地址配置
    output wire [128*SrcIpv6Count-1:0] cfg_src_ipv6,
    output wire [ 48*SrcIpv6Count-1:0] cfg_src_mac,
    output wire [128*DstIpv6Count-1:0] cfg_dst_ipv6,
    output wire [ 48*DstIpv6Count-1:0] cfg_dst_mac,

    // UDP接收端口配置
    output wire [32*UdpIpv4RxCount-1:0] cfg_udp_ipv4_dst_port_range,
    output wire [32*UdpIpv6RxCount-1:0] cfg_udp_ipv6_dst_port_range,

    // ARP与ICMP配置
    output wire [PendingTimeWidth-1:0] cfg_pending_time,
    output wire [ReqWidth-1:0] cfg_arp_priority,
    output wire [ReqWidth-1:0] cfg_icmp_priority,

    // 管理地址与端口配置
    output wire [31:0] cfg_mgmt_ipv4_addr,
    output wire [15:0] cfg_mgmt_udp_port,
    output wire [47:0] cfg_mgmt_mac,

    // 清除命令
    output wire cfg_arp_clear_cache,
    output wire cfg_arp_clear_pending,
    output wire cfg_stat_clear,

    // 免费ARP
    output wire [LocalIpv4Count:0] cfg_arp_announce_mask,
    output wire                    cfg_arp_announce_valid,
    input  wire                    cfg_arp_announce_ready,

    // 业务状态
    input wire stat_link_up,
    input wire stat_arp_rx_error,
    input wire stat_arp_ack_fifo_overflow_error,
    input wire stat_arp_pending_fifo_overflow_error,
    input wire stat_arp_query_src_not_local,
    input wire stat_arp_cache_clear_finish,
    input wire stat_arp_pending_clear_finish,
    input wire stat_ipv4_tx_drop,
    input wire stat_ipv6_tx_drop,
    input wire stat_icmp_ttl_error
);

  // p1 译码配置项，缓存请求、权限与读值。
  // p2 校验请求，寄存应答与写入/动作提交。
  // p3 更新配置，寄存清除脉冲。

  // 参数范围检查
  initial begin
    if (ReqWidth < 3 || ReqWidth > 8) begin
      $display("错误：cfg_regs：ARP优先级位宽必须为3至8位。");
      $finish;
    end
    if (LocalIpv4Count < 1 || LocalIpv4Count >= 255 || SrcIpv6Count < 1 || SrcIpv6Count >= 255 ||
        DstIpv6Count < 1 || DstIpv6Count >= 255 || UdpIpv4RxCount < 1 ||
        UdpIpv4RxCount >= 255 || UdpIpv6RxCount < 1 || UdpIpv6RxCount >= 255) begin
      $display("错误：cfg_regs：地址表和端口范围数量必须为1至254。");
      $finish;
    end
  end

  // 权限常量
  // 权限掩码的位2、1、0依次对应EXEC、SET、GET。
  localparam [2:0] ReadWrite = 3'b011;
  localparam [2:0] ReadOnly = 3'b001;
  localparam [2:0] ActionOnly = 3'b100;

  // 每个配置索引访问32位。槽0为管理地址，业务地址从槽1开始。
  localparam integer AnnounceMaskWidth = LocalIpv4Count + 1;
  localparam [AnnounceMaskWidth-1:0] DefaultArpAnnounceMask = {(LocalIpv4Count + 1) {1'b1}};

  // 配置寄存器
  reg  [32*LocalIpv4Count-1:0] cfg_local_ip_reg;
  reg  [48*LocalIpv4Count-1:0] cfg_local_mac_reg;
  reg  [32*LocalIpv4Count-1:0] cfg_gateway_ip_reg;
  reg  [32*LocalIpv4Count-1:0] cfg_subnet_mask_reg;
  reg  [ 128*SrcIpv6Count-1:0] cfg_src_ipv6_reg;
  reg  [  48*SrcIpv6Count-1:0] cfg_src_mac_reg;
  reg  [ 128*DstIpv6Count-1:0] cfg_dst_ipv6_reg;
  reg  [  48*DstIpv6Count-1:0] cfg_dst_mac_reg;
  reg  [32*UdpIpv4RxCount-1:0] cfg_udp_ipv4_dst_port_range_reg;
  reg  [32*UdpIpv6RxCount-1:0] cfg_udp_ipv6_dst_port_range_reg;
  reg  [ PendingTimeWidth-1:0] cfg_pending_time_reg;
  reg  [         ReqWidth-1:0] cfg_arp_priority_reg;
  reg  [         ReqWidth-1:0] cfg_icmp_priority_reg;
  reg  [                 31:0] cfg_mgmt_ipv4_addr_reg;
  reg  [                 15:0] cfg_mgmt_udp_port_reg;
  reg  [                 47:0] cfg_mgmt_mac_reg;
  reg  [AnnounceMaskWidth-1:0] arp_announce_mask_reg;
  reg  [AnnounceMaskWidth-1:0] arp_announce_req_mask_reg;
  reg                          arp_announce_req_valid_reg;
  wire                         arp_announce_commit;

  // 组合译码
  reg  [                  2:0] item_access;
  reg  [                  7:0] item_count;
  reg  [                  7:0] item_bytes;
  reg                          item_known;
  reg  [                127:0] read_value;

  // p1 请求与译码缓存
  reg                          exec_valid_d1;
  reg                          op_get_d1;
  reg                          op_set_d1;
  reg                          op_exec_d1;
  reg  [                  7:0] req_item_d1;
  reg  [                  7:0] req_index_d1;
  reg  [                  7:0] req_len_d1;
  reg  [                127:0] req_value_d1;
  reg  [                  7:0] item_count_d1;
  reg  [                  7:0] item_bytes_d1;
  reg                          item_known_d1;
  reg  [                127:0] read_value_d1;
  reg                          access_allowed;
  reg  [                  7:0] expected_len;

  // p2 应答与提交缓存
  reg  [                  7:0] status;
  wire                         execute_action;
  reg  [                  7:0] rsp_status_reg;
  reg  [                  7:0] rsp_len_reg;
  reg  [                127:0] rsp_value_reg;
  reg                          write_commit;
  reg                          action_commit;
  reg                          restore_defaults;
  reg  [                  7:0] req_item_d2;
  reg  [                  7:0] req_index_d2;
  reg  [                127:0] req_value_d2;

  // p3 清除命令
  reg                          cfg_arp_clear_cache_reg;
  reg                          cfg_arp_clear_pending_reg;
  reg                          cfg_stat_clear_reg;

  // p1 配置项译码与请求缓存
  //// 字段权限、长度和读值
  always @* begin
    item_access = ReadWrite;
    item_count  = 8'd1;
    item_bytes  = 8'd0;
    item_known  = 1'b1;
    read_value  = 'd0;
    case (req_item)
      `CFG_MGMT_IPV4_ADDR: begin
        item_bytes = 8'd4;
        read_value[31:0] = cfg_mgmt_ipv4_addr_reg;
      end
      `CFG_MGMT_UDP_PORT: begin
        item_bytes = 8'd2;
        read_value[15:0] = cfg_mgmt_udp_port_reg;
      end
      `CFG_LINK_STATE: begin
        item_access = ReadOnly;
        item_bytes = 8'd1;
        read_value[0] = stat_link_up;
      end
      `CFG_IP_TX_DROP_FLAGS: begin
        item_access = ReadOnly;
        item_bytes = 8'd1;
        read_value[1:0] = {stat_ipv6_tx_drop, stat_ipv4_tx_drop};
      end
      `CFG_CLEAR_PORT_FLAGS, `CFG_RESTORE_PORT_DEFAULTS: item_access = ActionOnly;
      `CFG_MGMT_MAC_ADDR: begin
        item_bytes = 8'd6;
        read_value[47:0] = cfg_mgmt_mac_reg;
      end
      `CFG_IPV4_LOCAL_IP: begin
        item_bytes = 8'd4;
        item_count = LocalIpv4Count[7:0];
        if (req_index < item_count) begin
          read_value[31:0] = cfg_local_ip_reg[req_index*32+:32];
        end
      end
      `CFG_IPV4_LOCAL_MAC: begin
        item_bytes = 8'd6;
        item_count = LocalIpv4Count[7:0];
        if (req_index < item_count) begin
          read_value[47:0] = cfg_local_mac_reg[req_index*48+:48];
        end
      end
      `CFG_IPV4_GATEWAY: begin
        item_bytes = 8'd4;
        item_count = LocalIpv4Count[7:0];
        if (req_index < item_count) begin
          read_value[31:0] = cfg_gateway_ip_reg[req_index*32+:32];
        end
      end
      `CFG_IPV4_MASK: begin
        item_bytes = 8'd4;
        item_count = LocalIpv4Count[7:0];
        if (req_index < item_count) begin
          read_value[31:0] = cfg_subnet_mask_reg[req_index*32+:32];
        end
      end
      `CFG_ARP_PENDING_TIMEOUT_MS: begin
        item_bytes = 8'd8;
        read_value[PendingTimeWidth-1:0] = cfg_pending_time_reg;
      end
      `CFG_ARP_TX_PRIORITY: begin
        item_bytes = 8'd1;
        read_value[ReqWidth-1:0] = cfg_arp_priority_reg;
      end
      `CFG_ARP_ERROR_FLAGS: begin
        item_access = ReadOnly;
        item_bytes = 8'd1;
        read_value[3:0] = {
          stat_arp_query_src_not_local,
          stat_arp_pending_fifo_overflow_error,
          stat_arp_ack_fifo_overflow_error,
          stat_arp_rx_error
        };
      end
      `CFG_ARP_CLEAR_STATE: begin
        item_access = ReadOnly;
        item_bytes = 8'd1;
        read_value[1:0] = {stat_arp_pending_clear_finish, stat_arp_cache_clear_finish};
      end
      `CFG_ARP_CLEAR_CACHE, `CFG_ARP_CLEAR_PENDING: item_access = ActionOnly;
      `CFG_ARP_ANNOUNCE_MASK: begin
        item_bytes = (AnnounceMaskWidth + 7) / 8;
        read_value[AnnounceMaskWidth-1:0] = arp_announce_mask_reg;
      end
      `CFG_ARP_ANNOUNCE_SEND: item_access = ActionOnly;
      `CFG_ICMP_ECHO_PRIORITY: begin
        item_bytes = 8'd1;
        read_value[ReqWidth-1:0] = cfg_icmp_priority_reg;
      end
      `CFG_ICMP_ERROR_FLAGS: begin
        item_access = ReadOnly;
        item_bytes = 8'd1;
        read_value[0] = stat_icmp_ttl_error;
      end
      `CFG_UDP_IPV4_RX_PORT_RANGE: begin
        item_bytes = 8'd4;
        item_count = UdpIpv4RxCount[7:0];
        if (req_index < item_count) begin
          read_value[31:0] = cfg_udp_ipv4_dst_port_range_reg[req_index*32+:32];
        end
      end
      `CFG_UDP_IPV6_RX_PORT_RANGE: begin
        item_bytes = 8'd4;
        item_count = UdpIpv6RxCount[7:0];
        if (req_index < item_count) begin
          read_value[31:0] = cfg_udp_ipv6_dst_port_range_reg[req_index*32+:32];
        end
      end
      `CFG_IPV6_SRC_IP: begin
        item_bytes = 8'd16;
        item_count = SrcIpv6Count[7:0];
        if (req_index < item_count) begin
          read_value[127:0] = cfg_src_ipv6_reg[req_index*128+:128];
        end
      end
      `CFG_IPV6_SRC_MAC: begin
        item_bytes = 8'd6;
        item_count = SrcIpv6Count[7:0];
        if (req_index < item_count) begin
          read_value[47:0] = cfg_src_mac_reg[req_index*48+:48];
        end
      end
      `CFG_IPV6_DST_IP: begin
        item_bytes = 8'd16;
        item_count = DstIpv6Count[7:0];
        if (req_index < item_count) begin
          read_value[127:0] = cfg_dst_ipv6_reg[req_index*128+:128];
        end
      end
      `CFG_IPV6_DST_MAC: begin
        item_bytes = 8'd6;
        item_count = DstIpv6Count[7:0];
        if (req_index < item_count) begin
          read_value[47:0] = cfg_dst_mac_reg[req_index*48+:48];
        end
      end
      default: item_known = 1'b0;
    endcase
  end
  //// 请求与译码结果缓存
  always @(posedge clk) begin
    exec_valid_d1 <= exec_valid;
    if (exec_valid) begin
      op_get_d1 <= req_op == `CFG_OP_GET;
      op_set_d1 <= req_op == `CFG_OP_SET;
      op_exec_d1 <= req_op == `CFG_OP_EXEC;
      req_item_d1 <= req_item;
      req_index_d1 <= req_index;
      req_len_d1 <= req_len;
      req_value_d1 <= req_value;
      item_count_d1 <= item_count;
      item_bytes_d1 <= item_bytes;
      item_known_d1 <= item_known;
      read_value_d1 <= read_value;
      access_allowed <=
            |(item_access &{req_op == `CFG_OP_EXEC, req_op == `CFG_OP_SET, req_op == `CFG_OP_GET});
      expected_len <= (req_op == `CFG_OP_SET) ? item_bytes : 8'd0;
    end
  end

  // p2 请求校验与结果寄存
  //// 操作码、配置项、索引、权限和长度校验
  always @* begin
    status = `CFG_ST_OK;
    if (!(op_get_d1 || op_set_d1 || op_exec_d1)) status = `CFG_ST_BAD_OP;
    else if (!item_known_d1) status = `CFG_ST_BAD_ITEM;
    else if (req_index_d1 >= item_count_d1) status = `CFG_ST_BAD_INDEX;
    else if (!access_allowed) status = `CFG_ST_ACCESS_DENIED;
    else if (req_len_d1 != expected_len) status = `CFG_ST_BAD_VALUE_LENGTH;
  end
  //// 应答结果
  always @(posedge clk) begin
    if (rst) begin
      rsp_status_reg <= 'd0;
      rsp_len_reg <= 'd0;
      rsp_value_reg <= 'd0;
    end else if (exec_valid_d1) begin
      rsp_status_reg <= status;
      rsp_len_reg <= (op_get_d1 && status == `CFG_ST_OK) ? item_bytes_d1 : 8'd0;
      rsp_value_reg <= (op_get_d1 && status == `CFG_ST_OK) ? read_value_d1 : 128'd0;
    end
  end
  assign rsp_status = rsp_status_reg;
  assign rsp_len = rsp_len_reg;
  assign rsp_value = rsp_value_reg;
  //// 写入与动作提交
  assign execute_action = exec_valid_d1 && op_exec_d1 && status == `CFG_ST_OK;
  always @(posedge clk) begin
    if (rst) begin
      write_commit <= 1'b0;
      action_commit <= 1'b0;
      restore_defaults <= 1'b0;
    end else begin
      write_commit <= exec_valid_d1 && op_set_d1 && status == `CFG_ST_OK;
      action_commit <= execute_action;
      restore_defaults <= execute_action && req_item_d1 == `CFG_RESTORE_PORT_DEFAULTS;
      if (exec_valid_d1) begin
        req_item_d2  <= req_item_d1;
        req_index_d2 <= req_index_d1;
        req_value_d2 <= req_value_d1;
      end
    end
  end

  // p3 配置与动作提交
  //// 清除命令
  always @(posedge clk) begin
    if (rst) cfg_arp_clear_cache_reg <= 1'b0;
    else cfg_arp_clear_cache_reg <= action_commit && req_item_d2 == `CFG_ARP_CLEAR_CACHE;
  end
  assign cfg_arp_clear_cache = cfg_arp_clear_cache_reg;

  always @(posedge clk) begin
    if (rst) cfg_arp_clear_pending_reg <= 1'b0;
    else cfg_arp_clear_pending_reg <= action_commit && req_item_d2 == `CFG_ARP_CLEAR_PENDING;
  end
  assign cfg_arp_clear_pending = cfg_arp_clear_pending_reg;

  always @(posedge clk) begin
    if (rst) cfg_stat_clear_reg <= 1'b0;
    else cfg_stat_clear_reg <= action_commit && req_item_d2 == `CFG_CLEAR_PORT_FLAGS;
  end
  assign cfg_stat_clear = cfg_stat_clear_reg;
  //// ARP掩码
  assign arp_announce_commit = action_commit && req_item_d2 == `CFG_ARP_ANNOUNCE_SEND;
  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      arp_announce_mask_reg <= DefaultArpAnnounceMask;
    end else if (write_commit && req_item_d2 == `CFG_ARP_ANNOUNCE_MASK) begin
      arp_announce_mask_reg <= req_value_d2[AnnounceMaskWidth-1:0];
    end
  end
  always @(posedge clk) begin
    if (rst) begin
      arp_announce_req_valid_reg <= 1'b0;
    end else if (arp_announce_commit) begin
      arp_announce_req_valid_reg <= 1'b1;
      arp_announce_req_mask_reg  <= arp_announce_mask_reg;
    end else if (cfg_arp_announce_ready) begin
      arp_announce_req_valid_reg <= 1'b0;
    end
  end
  assign cfg_arp_announce_mask  = arp_announce_req_mask_reg;
  assign cfg_arp_announce_valid = arp_announce_req_valid_reg;
  //// IPv4地址配置
  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_local_ip_reg <= DefaultLocalIp;
    end else if (write_commit && req_item_d2 == `CFG_IPV4_LOCAL_IP) begin
      cfg_local_ip_reg[req_index_d2*32+:32] <= req_value_d2[31:0];
    end
  end
  assign cfg_local_ip = cfg_local_ip_reg;

  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_local_mac_reg <= DefaultLocalMac;
    end else if (write_commit && req_item_d2 == `CFG_IPV4_LOCAL_MAC) begin
      cfg_local_mac_reg[req_index_d2*48+:48] <= req_value_d2[47:0];
    end
  end
  assign cfg_local_mac = cfg_local_mac_reg;

  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_gateway_ip_reg <= DefaultGatewayIp;
    end else if (write_commit && req_item_d2 == `CFG_IPV4_GATEWAY) begin
      cfg_gateway_ip_reg[req_index_d2*32+:32] <= req_value_d2[31:0];
    end
  end
  assign cfg_gateway_ip = cfg_gateway_ip_reg;

  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_subnet_mask_reg <= DefaultSubnetMask;
    end else if (write_commit && req_item_d2 == `CFG_IPV4_MASK) begin
      cfg_subnet_mask_reg[req_index_d2*32+:32] <= req_value_d2[31:0];
    end
  end
  assign cfg_subnet_mask = cfg_subnet_mask_reg;
  //// IPv6地址配置
  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_src_ipv6_reg <= DefaultSrcIpv6;
    end else if (write_commit && req_item_d2 == `CFG_IPV6_SRC_IP) begin
      cfg_src_ipv6_reg[req_index_d2*128+:128] <= req_value_d2[127:0];
    end
  end
  assign cfg_src_ipv6 = cfg_src_ipv6_reg;

  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_src_mac_reg <= DefaultSrcMac;
    end else if (write_commit && req_item_d2 == `CFG_IPV6_SRC_MAC) begin
      cfg_src_mac_reg[req_index_d2*48+:48] <= req_value_d2[47:0];
    end
  end
  assign cfg_src_mac = cfg_src_mac_reg;

  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_dst_ipv6_reg <= DefaultDstIpv6;
    end else if (write_commit && req_item_d2 == `CFG_IPV6_DST_IP) begin
      cfg_dst_ipv6_reg[req_index_d2*128+:128] <= req_value_d2[127:0];
    end
  end
  assign cfg_dst_ipv6 = cfg_dst_ipv6_reg;

  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_dst_mac_reg <= DefaultDstMac;
    end else if (write_commit && req_item_d2 == `CFG_IPV6_DST_MAC) begin
      cfg_dst_mac_reg[req_index_d2*48+:48] <= req_value_d2[47:0];
    end
  end
  assign cfg_dst_mac = cfg_dst_mac_reg;
  //// UDP接收端口配置
  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_udp_ipv4_dst_port_range_reg <= DefaultUdpIpv4Range;
    end else if (write_commit && req_item_d2 == `CFG_UDP_IPV4_RX_PORT_RANGE) begin
      cfg_udp_ipv4_dst_port_range_reg[req_index_d2*32+:32] <= req_value_d2[31:0];
    end
  end
  assign cfg_udp_ipv4_dst_port_range = cfg_udp_ipv4_dst_port_range_reg;
  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_udp_ipv6_dst_port_range_reg <= DefaultUdpIpv6Range;
    end else if (write_commit && req_item_d2 == `CFG_UDP_IPV6_RX_PORT_RANGE) begin
      cfg_udp_ipv6_dst_port_range_reg[req_index_d2*32+:32] <= req_value_d2[31:0];
    end
  end
  assign cfg_udp_ipv6_dst_port_range = cfg_udp_ipv6_dst_port_range_reg;
  //// ARP与ICMP配置
  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_pending_time_reg <= DefaultPendingTime[PendingTimeWidth-1:0];
    end else if (write_commit && req_item_d2 == `CFG_ARP_PENDING_TIMEOUT_MS) begin
      cfg_pending_time_reg <= req_value_d2[PendingTimeWidth-1:0];
    end
  end
  assign cfg_pending_time = cfg_pending_time_reg;

  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_arp_priority_reg <= DefaultArpPriority;
    end else if (write_commit && req_item_d2 == `CFG_ARP_TX_PRIORITY) begin
      cfg_arp_priority_reg <= req_value_d2[ReqWidth-1:0];
    end
  end
  assign cfg_arp_priority = cfg_arp_priority_reg;

  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_icmp_priority_reg <= DefaultIcmpPriority;
    end else if (write_commit && req_item_d2 == `CFG_ICMP_ECHO_PRIORITY) begin
      cfg_icmp_priority_reg <= req_value_d2[ReqWidth-1:0];
    end
  end
  assign cfg_icmp_priority = cfg_icmp_priority_reg;
  //// 管理配置
  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_mgmt_ipv4_addr_reg <= DefaultMgmtIpv4Addr;
    end else if (write_commit && req_item_d2 == `CFG_MGMT_IPV4_ADDR) begin
      cfg_mgmt_ipv4_addr_reg <= req_value_d2[31:0];
    end
  end
  assign cfg_mgmt_ipv4_addr = cfg_mgmt_ipv4_addr_reg;

  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_mgmt_udp_port_reg <= DefaultMgmtUdpPort;
    end else if (write_commit && req_item_d2 == `CFG_MGMT_UDP_PORT) begin
      cfg_mgmt_udp_port_reg <= req_value_d2[15:0];
    end
  end
  assign cfg_mgmt_udp_port = cfg_mgmt_udp_port_reg;

  always @(posedge clk) begin
    if (rst || restore_defaults) begin
      cfg_mgmt_mac_reg <= DefaultMgmtMac;
    end else if (write_commit && req_item_d2 == `CFG_MGMT_MAC_ADDR) begin
      cfg_mgmt_mac_reg <= req_value_d2[47:0];
    end
  end
  assign cfg_mgmt_mac = cfg_mgmt_mac_reg;

endmodule
`resetall
