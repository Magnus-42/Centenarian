// -----------------------------------------------------------------------------
// File Name   : tb_arp_announce_integration.sv
// Module Name : tb_arp_announce_integration
// Description : 从CMAC和管理UDP验证免费ARP启动、选槽、排队和背压。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 1ps
`include "cfg_protocol.vh"

`define ANN_PORT_A dut.eth_stack_port_a_inst.eth_stack_port_inst
`define ANN_PORT_B dut.eth_stack_port_b_inst.eth_stack_port_inst
`define ANN_CMAC_A `ANN_PORT_A.eth_port_top_inst.gen_cmac_a.cmac_a_if_inst.cmac_usplus_a_inst
`define ANN_CMAC_B `ANN_PORT_B.eth_port_top_inst.gen_cmac_b.cmac_b_if_inst.cmac_usplus_b_inst

module tb_arp_announce_integration;
  localparam [47:0] Broadcast = 48'hffff_ffff_ffff;
  localparam [127:0] IpA = {32'h1001_a8c0, 32'h1101_a8c0, 32'h1201_a8c0, 32'h0901_a8c0};
  localparam [191:0] MacA = {48'h0100_3119_0000, 48'h0200_3119_0000,
                            48'h0300_3119_0000, 48'hf100_3119_0000};
  localparam [95:0] IpB = {32'h9001_a8c0, 32'h9101_a8c0, 32'h8901_a8c0};
  localparam [143:0] MacB = {48'h8100_3119_0000, 48'h8200_3119_0000, 48'hf180_3119_0000};

  reg init_clk = 1'b0;
  reg clk = 1'b0;
  reg rst = 1'b1;
  reg cfg_inject = 1'b0;
  reg [511:0] cfg_frame = '0;
  integer count_a = 0;
  integer count_b = 0;
  reg [3:0] expected_a [0:6];

  reg          unit_request = 1'b0;
  reg          unit_frame_ready = 1'b0;
  wire         unit_request_ready;
  wire         unit_frame_valid;
  wire [223:0] unit_frame_data;
  reg          unit_done = 1'b0;

  always #5 init_clk = !init_clk;
  always #1.25 clk = !clk;

  // Accelerate millisecond counters only; this is not a wall-clock startup-time measurement.
  defparam dut.eth_stack_port_a_inst.ArpStartupDelayMs = 3;
  defparam dut.eth_stack_port_b_inst.ArpStartupDelayMs = 3;
  eth_stack_top #(
      .ClkFreqHz(1000)
  ) dut (
      .init_clk(init_clk), .clk(clk), .rst(rst), .clk_locked(1'b1),
      .a_gt_rxp_in(4'd0), .a_gt_rxn_in(4'd0),
      .a_gt_ref_clk_p(init_clk), .a_gt_ref_clk_n(!init_clk), .a_qsfp_present_n(1'b0),
      .b_gt_rxp_in(4'd0), .b_gt_rxn_in(4'd0),
      .b_gt_ref_clk_p(init_clk), .b_gt_ref_clk_n(!init_clk), .b_qsfp_present_n(1'b0),
      .a_mac_axis_mready('1), .a_ipv4_axis_mready('1), .a_icmp_axis_mready(1'b1),
      .a_ipv6_axis_mready('1), .a_udp_ipv4_axis_mready('1), .a_udp_ipv6_axis_mready('1),
      .b_mac_axis_mready('1), .b_ipv4_axis_mready('1), .b_icmp_axis_mready(1'b1),
      .b_ipv6_axis_mready('1), .b_udp_ipv4_axis_mready('1), .b_udp_ipv6_axis_mready('1),
      .a_mac_axis_svalid('0), .a_ipv4_axis_svalid('0), .a_icmp_axis_svalid(1'b0),
      .a_ipv6_axis_svalid('0), .a_udp_ipv4_axis_svalid('0), .a_udp_ipv6_axis_svalid('0),
      .b_mac_axis_svalid('0), .b_ipv4_axis_svalid('0), .b_icmp_axis_svalid(1'b0),
      .b_ipv6_axis_svalid('0), .b_udp_ipv4_axis_svalid('0), .b_udp_ipv6_axis_svalid('0)
  );

  arp_announce #(
      .LocalIpCount(3)
  ) unit_announce (
      .clk(clk),
      .rst(rst),
      .announce_mask(3'b101),
      .announce_valid(unit_request),
      .announce_ready(unit_request_ready),
      .cfg_local_ip(IpA[95:0]),
      .cfg_local_mac(MacA[143:0]),
      .frame_data(unit_frame_data),
      .frame_valid(unit_frame_valid),
      .frame_ready(unit_frame_ready)
  );

  initial begin
    wait (!rst);
    @(negedge clk);
    unit_request = 1'b1;
    do @(posedge clk); while (!unit_request_ready);
    @(negedge clk);
    unit_request = 1'b0;
    wait (unit_frame_valid);
    repeat (20) begin
      @(negedge clk);
      if (!unit_frame_valid || unit_frame_data[63:0] !== {IpA[31:0], IpA[31:0]})
        $fatal(1, "announcement changed under backpressure");
    end
    unit_frame_ready = 1'b1;
    @(posedge clk);
    do @(posedge clk); while (!unit_frame_valid);
    if (unit_frame_data[63:0] !== {IpA[95:64], IpA[95:64]})
      $fatal(1, "unselected middle slot was not skipped");
    repeat (6) begin
      @(negedge clk);
      if (unit_frame_valid) $fatal(1, "unexpected unit announcement");
    end
    unit_done = 1'b1;
  end

  function automatic [335:0] announcement(input [31:0] ip, input [47:0] mac);
    return {ip, 48'd0, ip, mac, 16'h0100, 8'h04, 8'h06,
            16'h0008, 16'h0100, 16'h0608, mac, Broadcast};
  endfunction

  // 只统计SPA等于TPA的ARP帧，普通ARP解析帧可同时发送。
  always @(negedge `ANN_CMAC_A.sim_clk) begin
    if (`ANN_CMAC_A.sim_tx_valid && `ANN_CMAC_A.sim_tx_data[111:96] == 16'h0608 &&
        `ANN_CMAC_A.sim_tx_data[255:224] == `ANN_CMAC_A.sim_tx_data[335:304]) begin
      if (count_a >= 7)
        $fatal(1, "unexpected A announcement: SPA=%h SHA=%h",
               `ANN_CMAC_A.sim_tx_data[255:224], `ANN_CMAC_A.sim_tx_data[223:176]);
      if (`ANN_CMAC_A.sim_tx_data !==
          {176'd0, announcement(IpA[expected_a[count_a]*32+:32], MacA[expected_a[count_a]*48+:48])} ||
          `ANN_CMAC_A.sim_tx_keep !== 64'h0fff_ffff_ffff_ffff || !`ANN_CMAC_A.sim_tx_last)
        $fatal(1, "incorrect A announcement %0d: expected slot %0d, got SPA=%h SHA=%h",
               count_a, expected_a[count_a], `ANN_CMAC_A.sim_tx_data[255:224],
               `ANN_CMAC_A.sim_tx_data[223:176]);
      count_a = count_a + 1;
    end
    `ANN_CMAC_A.sim_rx_data = cfg_frame;
    `ANN_CMAC_A.sim_rx_keep = '1;
    `ANN_CMAC_A.sim_rx_last = cfg_inject;
    `ANN_CMAC_A.sim_rx_valid = cfg_inject;
  end

  always @(negedge `ANN_CMAC_B.sim_clk) begin
    if (`ANN_CMAC_B.sim_tx_valid && `ANN_CMAC_B.sim_tx_data[111:96] == 16'h0608) begin
      if (count_b >= 3 || `ANN_CMAC_B.sim_tx_data[335:0] !==
          announcement(IpB[count_b*32+:32], MacB[count_b*48+:48]))
        $fatal(1, "incorrect B announcement %0d", count_b);
      count_b = count_b + 1;
    end
  end

  // 注入管理报文，并在配置应答入口核对线上的应答状态和值。
  task automatic cfg_request(
      input [2:0] op, input [7:0] item, input [7:0] index,
      input [7:0] len, input [31:0] value, input [7:0] expected_status,
      input [7:0] expected_len, input [31:0] expected_value
  );
    reg [159:0] ipv4_header;
    integer unsigned sum;
    ipv4_header = {32'h0901_a8c0, 32'h9101_a8c0, 16'd0, 8'h11, 8'h40,
                   16'h0040, 16'd0, 16'h3200, 8'h00, 8'h45};
    sum = 0;
    for (integer i = 0; i < 10; i++) sum += int'(ipv4_header[i*16+:16]);
    while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
    ipv4_header[95:80] = ~sum[15:0];
    cfg_frame = {96'd0, value, len, index, item, 5'd17, op, `CFG_PROTOCOL_STAMP,
                 16'd0, 16'h1e00, 16'h0600, 16'h3412, ipv4_header,
                 16'h0008, 48'h8200_3119_0000, 48'hf100_3119_0000};
    @(posedge `ANN_CMAC_A.sim_clk);
    #1 cfg_inject = 1'b1;
    @(posedge `ANN_CMAC_A.sim_clk);
    #1 cfg_inject = 1'b0;
    do @(posedge clk); while (!(`ANN_PORT_A.cmd_tx_valid && `ANN_PORT_A.cmd_tx_ready));
    if (`ANN_PORT_A.cmd_tx_data[87:0] !==
        {expected_value, expected_len, index, item, expected_status, 5'd17,
         `CFG_OP_RESPONSE, `CFG_PROTOCOL_STAMP})
      $fatal(1, "wrong command response, item=%h response=%h", item, `ANN_PORT_A.cmd_tx_data[87:0]);
  endtask

  initial begin
    expected_a[0] = 0;
    expected_a[1] = 1;
    expected_a[2] = 2;
    expected_a[3] = 3;
    expected_a[4] = 1;
    expected_a[5] = 3;
    expected_a[6] = 0;

    // CMAC桩默认未完成FEC对齐；分别模拟两个网口建链。
    force `ANN_CMAC_B.stat_rx_rsfec_lane_alignment_status = 1'b1;
    repeat (100) @(negedge clk);
    rst = 1'b0;
    wait (count_b == 3);
    repeat (100) @(negedge clk);
    if (count_a != 0) $fatal(1, "A sent ahead of link readiness");
    force `ANN_CMAC_A.stat_rx_rsfec_lane_alignment_status = 1'b1;
    wait (count_a == 4);

    force `ANN_CMAC_A.stat_rx_rsfec_lane_alignment_status = 1'b0;
    repeat (40) @(negedge clk);
    force `ANN_CMAC_A.stat_rx_rsfec_lane_alignment_status = 1'b1;
    repeat (120) @(negedge clk);
    if (count_a != 4 || count_b != 3) $fatal(1, "unexpected second automatic round");

    cfg_request(`CFG_OP_GET, 8'h2a, 0, 0, 0, `CFG_ST_OK, 1, 32'hf);
    cfg_request(`CFG_OP_GET, 8'h2a, 1, 0, 0, `CFG_ST_BAD_INDEX, 0, 0);
    cfg_request(`CFG_OP_SET, 8'h2a, 0, 4, 32'h1, `CFG_ST_BAD_VALUE_LENGTH, 0, 0);
    cfg_request(`CFG_OP_SET, 8'h2a, 0, 1, 32'hf1, `CFG_ST_OK, 0, 0);
    cfg_request(`CFG_OP_GET, 8'h2a, 0, 0, 0, `CFG_ST_OK, 1, 32'h1);
    repeat (120) @(negedge clk);
    if (count_a != 4) $fatal(1, "SET triggered a transmission");

    force `ANN_PORT_A.arp_announce_ready = 1'b0;
    cfg_request(`CFG_OP_EXEC, 8'h2b, 0, 0, 0, `CFG_ST_OK, 0, 0);
    cfg_request(`CFG_OP_SET, 8'h2a, 0, 1, 32'ha, `CFG_ST_OK, 0, 0);
    cfg_request(`CFG_OP_EXEC, 8'h2b, 0, 0, 0, `CFG_ST_OK, 0, 0);
    // 仅写掩码不会改变已经锁存的待发请求。
    cfg_request(`CFG_OP_SET, 8'h2a, 0, 1, 32'h1, `CFG_ST_OK, 0, 0);
    cfg_request(`CFG_OP_GET, 8'h2a, 0, 0, 0, `CFG_ST_OK, 1, 32'h1);
    if (count_a != 4) $fatal(1, "queued request advanced during stall");
    @(negedge clk);
    release `ANN_PORT_A.arp_announce_ready;
    wait (count_a == 6);

    cfg_request(`CFG_OP_EXEC, 8'h2b, 0, 0, 0, `CFG_ST_OK, 0, 0);
    wait (count_a == 7);

    cfg_request(`CFG_OP_SET, 8'h2a, 0, 1, 0, `CFG_ST_OK, 0, 0);
    cfg_request(`CFG_OP_EXEC, 8'h2b, 0, 0, 0, `CFG_ST_OK, 0, 0);
    cfg_request(`CFG_OP_EXEC, `CFG_RESTORE_PORT_DEFAULTS, 0, 0, 0, `CFG_ST_OK, 0, 0);
    cfg_request(`CFG_OP_GET, 8'h2a, 0, 0, 0, `CFG_ST_OK, 1, 32'hf);
    repeat (120) @(negedge clk);
    if (count_a != 7 || count_b != 3) $fatal(1, "incorrect port isolation or frame count");
    if (!unit_done) $fatal(1, "unit backpressure test did not complete");

    $display("PASS: tb_arp_announce_integration");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "Timeout: announcements A=%0d B=%0d", count_a, count_b);
  end
endmodule

`undef ANN_PORT_A
`undef ANN_PORT_B
`undef ANN_CMAC_A
`undef ANN_CMAC_B
`resetall
