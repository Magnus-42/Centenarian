// -----------------------------------------------------------------------------
// File Name   : arp_announce.v
// Module Name : arp_announce
// Author      : Lixintao
// Created     : 2026-11-22
// Version     : v1.0
// -----------------------------------------------------------------------------
// Description : 按本机地址掩码逐项生成免费ARP公告。
// Note        :
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module arp_announce #(
    parameter integer LocalIpCount = 1
) (
    input wire clk,
    input wire rst,

    input  wire [LocalIpCount-1:0] announce_mask,
    input  wire                    announce_valid,
    output wire                    announce_ready,

    input wire [32*LocalIpCount-1:0] cfg_local_ip,
    input wire [48*LocalIpCount-1:0] cfg_local_mac,

    output wire [223:0] frame_data,
    output wire         frame_valid,
    input  wire         frame_ready
);

  localparam integer IndexWidth = (LocalIpCount > 1) ? $clog2(LocalIpCount) : 1;

  reg  [   LocalIpCount-1:0] pending_mask;
  reg  [     IndexWidth-1:0] slot_index;
  wire                       scan_active;
  wire                       scan_step;

  wire [               31:0] slot_ip;
  wire [               47:0] slot_mac;
  wire                       frame_slot_ready;
  reg  [               31:0] frame_ip_reg;
  reg  [               47:0] frame_mac_reg;
  reg                        frame_valid_reg;

  reg  [32*LocalIpCount-1:0] cfg_local_ip_d1;
  reg  [48*LocalIpCount-1:0] cfg_local_mac_d1;

  assign scan_active = |pending_mask;
  assign frame_slot_ready = !frame_valid_reg || frame_ready;
  assign announce_ready = !scan_active && frame_slot_ready;
  assign scan_step = scan_active && frame_slot_ready;

  assign slot_ip = cfg_local_ip_d1[slot_index*32+:32];
  assign slot_mac = cfg_local_mac_d1[slot_index*48+:48];

  // 寄存配置
  always @(posedge clk) begin
    cfg_local_ip_d1  <= cfg_local_ip;
    cfg_local_mac_d1 <= cfg_local_mac;
  end

  // 计算掩码和槽位索引
  always @(posedge clk) begin
    if (rst) begin
      pending_mask <= 'd0;
      slot_index   <= 'd0;
    end else if (announce_valid && announce_ready) begin
      pending_mask <= announce_mask;
      slot_index   <= 'd0;
    end else if (scan_step) begin
      pending_mask <= pending_mask >> 1;
      slot_index   <= slot_index + 1'b1;
    end
  end

  // 计算输出
  always @(posedge clk) begin
    if (rst) frame_valid_reg <= 1'b0;
    else if (frame_slot_ready) frame_valid_reg <= scan_active && pending_mask[0];

    if (scan_step && pending_mask[0]) begin
      frame_ip_reg  <= slot_ip;
      frame_mac_reg <= slot_mac;
    end
  end

  assign frame_data = {
    frame_mac_reg, 48'hffff_ffff_ffff, 16'h0100, 48'd0, frame_ip_reg, frame_ip_reg
  };
  assign frame_valid = frame_valid_reg;
endmodule
`resetall
