`timescale 1ns/1ps
`default_nettype none

// Wire codes and expected lengths are literals from Docs/05, not copied from RTL macros.
module tb_cfg_port_top;
  reg clk = 0, rst = 1;
  reg [511:0] sdata = 0;
  reg [63:0] skeep = 0;
  reg [336:0] susr = 0;
  reg svalid = 0, slast = 1, mready = 0;
  wire sready, mvalid, mlast;
  wire [511:0] mdata;
  wire [63:0] mkeep;
  wire [227:0] musr;
  wire [95:0] local_ip, udp6_range;
  wire [255:0] src_ipv6;
  wire clear_cache, clear_pending, clear_flags;
  integer clears = 0, replies = 0, sequence_number = 0;
  localparam [31:0] HostIp = 32'h6401a8c0, MgmtIp = 32'h0901a8c0;
  localparam [15:0] HostPort = 16'h3412, MgmtPort = 16'h0600;
  localparam [127:0] Ipv6Value = 128'h0123456789abcdeffedcba9876543210;
  always #5 clk = ~clk;
  cfg_port_top dut (
    .clk(clk), .rst(rst), .axis_sdata(sdata), .axis_skeep(skeep), .axis_susr(susr),
    .axis_svalid(svalid), .axis_slast(slast), .axis_sready(sready),
    .axis_mdata(mdata), .axis_mkeep(mkeep), .axis_musr(musr),
    .axis_mvalid(mvalid), .axis_mlast(mlast), .axis_mready(mready),
    .cfg_local_ip(local_ip), .cfg_udp_ipv6_dst_port_range(udp6_range), .cfg_src_ipv6(src_ipv6),
    .cfg_arp_clear_cache(clear_cache), .cfg_arp_clear_pending(clear_pending), .cfg_stat_clear(clear_flags),
    .cfg_arp_announce_ready(1'b1),
    .stat_link_up(1'b1), .stat_arp_rx_error(1'b0), .stat_arp_ack_fifo_overflow_error(1'b0),
    .stat_arp_pending_fifo_overflow_error(1'b0), .stat_arp_query_src_not_local(1'b0),
    .stat_arp_cache_clear_finish(1'b1), .stat_arp_pending_clear_finish(1'b1),
    .stat_ipv4_tx_drop(1'b0), .stat_ipv6_tx_drop(1'b0), .stat_icmp_ttl_error(1'b0));

  always @(posedge clk) begin
    if (!rst && clear_cache) clears++;
    if (!rst && mvalid && mready) replies++;
  end

  task automatic request(input [2:0] op, input [7:0] item, input [7:0] slot,
      input [7:0] length, input [127:0] value,
      input [7:0] status, input [7:0] reply_length, input [127:0] reply_value);
    reg [183:0] expected;
    reg [511:0] held;
    reg [227:0] held_usr;
    sequence_number = (sequence_number + 1) % 32;
    expected = {reply_value, reply_length, slot, item, status, 5'(sequence_number), 3'd4, 16'h3119};
    @(negedge clk);
    sdata = {336'd0, value, length, slot, item, 5'(sequence_number), op, 16'h3119};
    skeep = 64'h3fffff; svalid = 1; slast = 1;
    do @(posedge clk); while (!sready);
    @(negedge clk); svalid = 0;
    wait (mvalid === 1'b1);
    @(negedge clk);
    if (mdata[183:0] !== expected || mkeep !== 64'h7fffff || mlast !== 1'b1 ||
        musr !== {16'd0, 16'd0, HostPort, MgmtPort, HostIp, MgmtIp, 16'd0, 8'd17, 8'd64,
                  16'h0040, 16'd0, 16'd0, 16'h0045, 4'd14})
      $fatal(1, "configuration response mismatch, item=%h got=%h expected=%h", item, mdata[183:0], expected);
    held = mdata; held_usr = musr;
    repeat (7) begin
      @(negedge clk);
      if (mvalid !== 1'b1 || mdata !== held || musr !== held_usr || mkeep !== 64'h7fffff || !mlast)
        $fatal(1, "configuration response changed under backpressure");
    end
    mready = 1;
    @(negedge clk); mready = 0;
  endtask

  task automatic malformed(input [15:0] stamp, input [63:0] keep, input bit last);
    integer before_count;
    before_count = replies;
    @(negedge clk);
    sdata = {336'd0, 128'd0, 8'd0, 8'd0, 8'h14, 5'd0, 3'd1, stamp};
    skeep = keep; slast = last; svalid = 1;
    do @(posedge clk); while (!sready);
    @(negedge clk); svalid = 0;
    repeat (20) begin
      @(negedge clk);
      if (mvalid || replies != before_count) $fatal(1, "malformed command produced a response");
    end
  endtask

  initial begin
    susr[209+:32] = HostIp;
    susr[273+:16] = HostPort;
    repeat (5) @(negedge clk);
    rst = 0;
    repeat (3) @(negedge clk);
    request(1,8'h14,0,0,0,0,1,1); // Link state.
    request(1,8'h20,0,0,0,0,4,32'h1201a8c0);
    // A pending, stalled response is discarded by reset, then commands recover.
    @(negedge clk);
    sdata = {336'd0,128'd0,8'd0,8'd0,8'h14,5'd0,3'd1,16'h3119};
    skeep = 64'h3fffff; slast = 1; svalid = 1;
    do @(posedge clk); while (!sready);
    @(negedge clk); svalid = 0;
    wait (mvalid);
    @(negedge clk); rst = 1;
    repeat (3) @(negedge clk);
    rst = 0;
    repeat (8) @(negedge clk);
    if (mvalid) $fatal(1, "configuration reset left a pending response");
    request(1,8'h14,0,0,0,0,1,1);
    request(2,8'h20,0,4,32'hc801a8c0,0,0,0);
    request(1,8'h20,0,0,0,0,4,32'hc801a8c0);
    if (local_ip[31:0] !== 32'hc801a8c0) $fatal(1, "IPv4 SET did not reach output");
    request(2,8'h2f,1,4,32'hd007e803,0,0,0);
    request(1,8'h2f,1,0,0,0,4,32'hd007e803);
    if (udp6_range[63:32] !== 32'hd007e803) $fatal(1, "UDP SET did not reach output");
    request(2,8'h40,1,16,Ipv6Value,0,0,0);
    request(1,8'h40,1,0,0,0,16,Ipv6Value);
    if (src_ipv6[255:128] !== Ipv6Value) $fatal(1, "IPv6 SET did not reach output");
    request(0,8'h20,0,0,0,1,0,0); // BAD_OP.
    request(1,8'hff,0,0,0,2,0,0); // BAD_ITEM.
    request(1,8'h20,3,0,0,3,0,0); // BAD_INDEX.
    request(2,8'h14,0,1,0,4,0,0); // ACCESS_DENIED.
    request(2,8'h20,0,3,32'hdeadbeef,5,0,0); // BAD_VALUE_LENGTH.
    request(1,8'h20,0,0,0,0,4,32'hc801a8c0); // Rejected write changed nothing.
    request(3,8'h28,0,0,0,0,0,0);
    if (clears != 1) $fatal(1, "cache clear must pulse once");
    malformed(16'h1234,64'h3fffff,1);
    malformed(16'h3119,64'h1fffff,1);
    malformed(16'h3119,64'h3fffff,0);
    request(1,8'h14,0,0,0,0,1,1); // Recovery after malformed requests.
    request(3,8'h17,0,0,0,0,0,0); // Restore defaults.
    request(1,8'h20,0,0,0,0,4,32'h1201a8c0);
    if (replies != sequence_number) $fatal(1, "configuration reply count mismatch");
    repeat (15) @(negedge clk);
    if (mvalid || clear_cache || clear_pending || clear_flags) $fatal(1, "unexpected trailing response/action");
    $display("PASS: tb_cfg_port_top"); $finish;
  end
  initial begin #100000; $fatal(1, "configuration watchdog"); end
endmodule
`resetall
