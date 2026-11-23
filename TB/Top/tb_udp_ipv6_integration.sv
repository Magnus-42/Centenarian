// -----------------------------------------------------------------------------
// File Name   : tb_udp_ipv6_integration.sv
// Module Name : tb_udp_ipv6_integration
// Description : 双口CMAC仿真回环，验证板级UDP/IPv6测试机和端口字典读写。
// Note        : 与TB/Top/ip_sim下的CMAC和SLR行为模型一同编译。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 1ps
`include "cfg_protocol.vh"

`define UDP6_PORT_A dut.u_eth_stack_top.eth_stack_port_a_inst.eth_stack_port_inst
`define UDP6_PORT_B dut.u_eth_stack_top.eth_stack_port_b_inst.eth_stack_port_inst
`define UDP6_CMAC_A `UDP6_PORT_A.eth_port_top_inst.gen_cmac_a.cmac_a_if_inst.cmac_usplus_a_inst
`define UDP6_CMAC_B `UDP6_PORT_B.eth_port_top_inst.gen_cmac_b.cmac_b_if_inst.cmac_usplus_b_inst

module tb_udp_ipv6_integration;
  reg sys_clk = 1'b0;
  reg cfg_inject = 1'b0;
  reg [511:0] cfg_frame = '0;

  always #5 sys_clk = !sys_clk;

  subsys_test_top dut (
      .sys_clk(sys_clk),
      .gt_rxp_in_a(4'd0),
      .gt_rxn_in_a(4'd0),
      .gt_ref_clk_p_a(sys_clk),
      .gt_ref_clk_n_a(!sys_clk),
      .qsfp_prsn_port_a(1'b0),
      .gt_rxp_in_b(4'd0),
      .gt_rxn_in_b(4'd0),
      .gt_ref_clk_p_b(sys_clk),
      .gt_ref_clk_n_b(!sys_clk),
      .qsfp_prsn_port_b(1'b0)
  );

  // CMAC边界回环包括以太网封装、查表、异步FIFO和整个接收路径。
  always @(negedge `UDP6_CMAC_A.sim_clk) begin
    `UDP6_CMAC_A.sim_rx_data  = cfg_inject ? cfg_frame : `UDP6_CMAC_B.sim_tx_data;
    `UDP6_CMAC_A.sim_rx_keep  = cfg_inject ? '1 : `UDP6_CMAC_B.sim_tx_keep;
    `UDP6_CMAC_A.sim_rx_last  = cfg_inject || `UDP6_CMAC_B.sim_tx_last;
    `UDP6_CMAC_A.sim_rx_valid = cfg_inject || `UDP6_CMAC_B.sim_tx_valid;
  end
  always @(negedge `UDP6_CMAC_B.sim_clk) begin
    `UDP6_CMAC_B.sim_rx_data  = `UDP6_CMAC_A.sim_tx_data;
    `UDP6_CMAC_B.sim_rx_keep  = `UDP6_CMAC_A.sim_tx_keep;
    `UDP6_CMAC_B.sim_rx_last  = `UDP6_CMAC_A.sim_tx_last;
    `UDP6_CMAC_B.sim_rx_valid = `UDP6_CMAC_A.sim_tx_valid;
  end

  // 从A口的CMAC注入一拍配置请求。在配置应答进入UDP/IPv4发送前检查应答字段。
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
    @(posedge `UDP6_CMAC_A.sim_clk);
    #1 cfg_inject = 1'b1;
    @(posedge `UDP6_CMAC_A.sim_clk);
    #1 cfg_inject = 1'b0;
    do @(posedge dut.clk_400m); while (!(`UDP6_PORT_A.cmd_tx_valid && `UDP6_PORT_A.cmd_tx_ready));
    if (`UDP6_PORT_A.cmd_tx_data[87:0] !==
        {expected_value, expected_len, index, item, expected_status, 5'd17,
         `CFG_OP_RESPONSE, `CFG_PROTOCOL_STAMP}) begin
      $fatal(1, "cfg response mismatch: item=%h index=%0d reply=%h", item, index,
             `UDP6_PORT_A.cmd_tx_data[88:0]);
    end
  endtask

  initial begin
    force `UDP6_CMAC_A.stat_rx_rsfec_lane_alignment_status = 1'b1;
    force `UDP6_CMAC_B.stat_rx_rsfec_lane_alignment_status = 1'b1;
    wait (dut.usr_rst === 1'b0);
    repeat (120) @(negedge dut.clk_400m);

    // Use the documented wire code independently of the DUT's definition.
    cfg_request(`CFG_OP_GET, 8'h2c, 0, 0, 0, `CFG_ST_OK, 1, 32'd13);
    cfg_request(`CFG_OP_GET, 8'h2d, 0, 0, 0, `CFG_ST_OK, 1, 32'd0);
    cfg_request(`CFG_OP_GET, 8'h2e, 0, 0, 0,
                `CFG_ST_OK, 4, 32'h0800_0000);
    cfg_request(`CFG_OP_GET, 8'h2f, 0, 0, 0,
                `CFG_ST_OK, 4, 32'h0800_0000);
    cfg_request(`CFG_OP_GET, 8'h4c, 0, 0, 0,
                `CFG_ST_BAD_ITEM, 0, 0);
    cfg_request(`CFG_OP_GET, `CFG_UDP_IPV6_RX_PORT_RANGE, 3, 0, 0,
                `CFG_ST_BAD_INDEX, 0, 0);
    cfg_request(`CFG_OP_SET, `CFG_UDP_IPV6_RX_PORT_RANGE, 0, 2, 0,
                `CFG_ST_BAD_VALUE_LENGTH, 0, 0);

    // VIO 24–27分别启动两路业务和两路兜底测试。
    @(negedge dut.clk_400m);
    dut.u_test_vio_enable.ipv6_enable = 4'b1111;
    wait (dut.u_ta_udp_ipv6.pkt_cnt_acc >= 3 && dut.u_tb_udp_ipv6.pkt_cnt_acc >= 3 &&
          dut.u_ta_fb_udp_ipv6.pkt_cnt_acc >= 3 && dut.u_tb_fb_udp_ipv6.pkt_cnt_acc >= 3);
    @(negedge dut.clk_400m);
    dut.u_test_vio_enable.ipv6_enable = 0;
    repeat (600) @(negedge dut.clk_400m);
    if ({dut.u_ta_udp_ipv6.rx_error_cnt, dut.u_tb_udp_ipv6.rx_error_cnt,
         dut.u_ta_fb_udp_ipv6.rx_error_cnt, dut.u_tb_fb_udp_ipv6.rx_error_cnt,
         dut.u_ta_udp_ipv6.rx_len_err_cnt, dut.u_tb_udp_ipv6.rx_len_err_cnt,
         dut.u_ta_fb_udp_ipv6.rx_len_err_cnt, dut.u_tb_fb_udp_ipv6.rx_len_err_cnt} !== '0)
      $fatal(1, "IPv6 UDP tester payload or length error");

    cfg_request(`CFG_OP_SET, `CFG_UDP_IPV6_RX_PORT_RANGE, 0, 4, 32'h0800_0300,
                `CFG_ST_OK, 0, 0);
    cfg_request(`CFG_OP_GET, `CFG_UDP_IPV6_RX_PORT_RANGE, 0, 0, 0,
                `CFG_ST_OK, 4, 32'h0800_0300);
    cfg_request(`CFG_OP_GET, `CFG_UDP_IPV4_RX_PORT_RANGE, 0, 0, 0,
                `CFG_ST_OK, 4, 32'h0800_0000);
    if (`UDP6_PORT_B.cfg_udp_ipv6_dst_port_range[31:0] !== 32'h0800_0000)
      $fatal(1, "A-side SET changed B-side dictionary");

    // 端口2离开A口档0的区间。仅打开B口业务TX，确认流量改走A口兜底。
    @(negedge dut.clk_400m);
    dut.u_test_vio_enable.ipv6_enable = 4'b0010;
    do @(posedge dut.clk_400m); while (!(dut.a_udp_ipv6_axis_mvalid[3] &&
                                        dut.a_udp_ipv6_axis_mlast[3]));
    @(negedge dut.clk_400m);
    dut.u_test_vio_enable.ipv6_enable = 0;
    repeat (600) @(negedge dut.clk_400m);

    cfg_request(`CFG_OP_EXEC, `CFG_RESTORE_PORT_DEFAULTS, 0, 0, 0, `CFG_ST_OK, 0, 0);
    cfg_request(`CFG_OP_GET, `CFG_UDP_IPV6_RX_PORT_RANGE, 0, 0, 0,
                `CFG_ST_OK, 4, 32'h0800_0000);
    @(negedge dut.clk_400m);
    dut.u_test_vio_enable.ipv6_enable = 4'b0010;
    do @(posedge dut.clk_400m); while (!(dut.a_udp_ipv6_axis_mvalid[0] &&
                                        dut.a_udp_ipv6_axis_mlast[0]));
    $display("PASS: tb_udp_ipv6_integration");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "Timeout: tb_udp_ipv6_integration");
  end
endmodule

// 板级调试IP的仿真接口。包间隔留出回环FIFO和CMAC模型所需的余量。
module vio_enable (
    input wire clk,
    input wire [15:0] probe_in0,
    output wire probe_out0, probe_out1, probe_out2, probe_out3, probe_out4,
    output wire probe_out5, probe_out6, probe_out7, probe_out8, probe_out9,
    output wire probe_out10, probe_out11, probe_out12, probe_out13, probe_out14,
    output wire probe_out15, probe_out16, probe_out17, probe_out18, probe_out19,
    output wire probe_out20, probe_out21, probe_out22,
    output wire [15:0] probe_out23,
    output wire probe_out24, probe_out25, probe_out26, probe_out27
);
  reg [3:0] ipv6_enable = 0;
  assign {probe_out27, probe_out26, probe_out25, probe_out24} = ipv6_enable;
  assign probe_out23 = 16'd200;
  assign {probe_out22, probe_out21, probe_out20, probe_out19, probe_out18, probe_out17,
          probe_out16, probe_out15, probe_out14, probe_out13, probe_out12, probe_out11,
          probe_out10, probe_out9, probe_out8, probe_out7, probe_out6, probe_out5,
          probe_out4, probe_out3, probe_out2, probe_out1, probe_out0} = 23'd0;
endmodule

module ila_tester (
    input wire clk,
    input wire [31:0] probe0,
    input wire [35:0] probe1, probe2,
    input wire [31:0] probe3,
    input wire probe4
);
endmodule

module clk_100_to_400m (
    input wire clk_100m,
    output reg clk_400m = 0,
    output wire locked
);
  always #1.25 clk_400m = !clk_400m;
  assign locked = 1'b1;
endmodule

`undef UDP6_CMAC_A
`undef UDP6_CMAC_B
`undef UDP6_PORT_A
`undef UDP6_PORT_B
`resetall
