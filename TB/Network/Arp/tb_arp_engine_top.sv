`timescale 1ns/1ps
`default_nettype none

// Public frame/query interfaces only. Millisecond timers are accelerated for simulation.
module tb_arp_engine_top;
  localparam [31:0] LocalIp = 32'h0a01a8c0, PeerIp = 32'h1401a8c0;
  localparam [31:0] Gateway = 32'h0101a8c0, AnnounceIp = 32'h1501a8c0;
  localparam [47:0] LocalMac = 48'h0a0000000002, PeerMac = 48'h140000000002;
  localparam [47:0] GatewayMac = 48'h010000000002, AnnounceMac = 48'h150000000002;
  localparam [47:0] Broadcast = 48'hffffffffffff;
  reg clk = 0, rst = 1, query_valid = 0;
  reg [31:0] query_src = LocalIp, query_dst = PeerIp;
  wire [47:0] dst_mac, src_mac;
  wire miss, valid;
  reg [511:0] sdata = 0;
  reg svalid = 0, serror = 0, clear_cache = 0, clear_pending = 0;
  wire sready, mvalid, mlast, cache_ready, pending_ready, rx_error, bad_source;
  wire [511:0] mdata;
  wire [63:0] mkeep;
  wire [3:0] musr;
  integer cycle = 0, expected_count = 0, received = 0;
  wire mready = !rst && cycle % 17 >= 8;
  reg [335:0] expected[0:7];
  reg [580:0] held;
  reg stalled = 0;
  always #5 clk = ~clk;
  always @(posedge clk) cycle <= cycle + 1;

  // 引擎只处理ARP报文，Ethernet封装由MAC层提供。
  wire [511:0] arp_sdata, arp_mdata, eth_mdata;
  wire [63:0] arp_skeep, arp_mkeep, eth_mkeep;
  wire [112:0] arp_susr;
  wire [115:0] arp_musr;
  wire [3:0] eth_musr;
  wire arp_svalid, arp_slast, arp_sready, arp_mvalid, arp_mlast, arp_mready;
  wire eth_mvalid, eth_mlast, eth_mready;
  eth_header_strip eth_rx_inst (
      .clk(clk), .rst(rst), .axis_sdata(sdata), .axis_skeep(64'h0fffffffffffffff),
      .axis_susr(serror), .axis_svalid(svalid), .axis_slast(1'b1), .axis_sready(sready),
      .axis_mdata(arp_sdata), .axis_mkeep(arp_skeep), .axis_musr(arp_susr),
      .axis_mvalid(arp_svalid), .axis_mlast(arp_slast), .axis_mready(arp_sready)
  );
  eth_header_add eth_tx_inst (
      .clk(clk), .rst(rst), .axis_sdata(arp_mdata), .axis_skeep(arp_mkeep), .axis_susr(arp_musr),
      .axis_svalid(arp_mvalid), .axis_slast(arp_mlast), .axis_sready(arp_mready),
      .axis_mdata(eth_mdata), .axis_mkeep(eth_mkeep), .axis_musr(eth_musr),
      .axis_mvalid(eth_mvalid), .axis_mlast(eth_mlast), .axis_mready(eth_mready)
  );
  assign musr = eth_musr;
  eth_frame_pad60 eth_pad_inst (
      .clk(clk), .rst(rst), .axis_sdata(eth_mdata), .axis_skeep(eth_mkeep),
      .axis_svalid(eth_mvalid), .axis_slast(eth_mlast), .axis_sready(eth_mready),
      .axis_mdata(mdata), .axis_mkeep(mkeep), .axis_mvalid(mvalid), .axis_mlast(mlast), .axis_mready(mready)
  );
  arp_engine_top #(.CacheDepth(16), .PendingDepth(16), .HashWayCount(2), .ClkFreqHz(1000)) dut (
    .clk(clk), .rst(rst), .announce_mask(1'b0), .announce_valid(1'b0), .announce_ready(),
    .query_src_ip(query_src), .query_dst_ip(query_dst), .query_valid_pulse(query_valid),
    .arp_dst_mac(dst_mac), .arp_src_mac(src_mac), .arp_miss(miss), .arp_valid(valid),
    .axis_sdata(arp_sdata), .axis_skeep(arp_skeep), .axis_svalid(arp_svalid), .axis_slast(arp_slast),
    .axis_susr(arp_susr), .axis_sready(arp_sready),
    .axis_mdata(arp_mdata), .axis_mkeep(arp_mkeep), .axis_mvalid(arp_mvalid), .axis_mlast(arp_mlast),
    .axis_musr(arp_musr), .axis_mready(arp_mready), .cfg_arp_priority(4'd9),
    .cfg_local_ip(LocalIp), .cfg_local_mac(LocalMac), .cfg_gateway_ip(Gateway),
    .cfg_subnet_mask(32'h00ffffff), .cfg_pending_time(24'd1000),
    .cfg_clear_cache(clear_cache), .cfg_clear_pending(clear_pending), .cfg_stat_clear(1'b0),
    .stat_rx_error(rx_error), .stat_query_src_not_local(bad_source),
    .stat_ack_fifo_overflow_error(), .stat_pending_fifo_overflow_error(),
    .stat_cache_clear_finish(cache_ready), .stat_pending_clear_finish(pending_ready));

  function automatic [335:0] frame(input [47:0] eth_dst, input [47:0] sender_mac,
      input [31:0] sender_ip, input [15:0] opcode, input [47:0] target_mac, input [31:0] target_ip);
    return {target_ip,target_mac,sender_ip,sender_mac,opcode,8'd4,8'd6,16'h0008,16'h0100,
            16'h0608,sender_mac,eth_dst};
  endfunction

  always @(posedge clk) begin
    if (!rst) begin
      if (stalled && (mvalid !== 1'b1 || {mdata,mkeep,musr,mlast} !== held))
        $fatal(1, "ARP changed output under backpressure");
      if (mvalid && mready) begin
        if (received >= expected_count || mdata !== {176'd0,expected[received]} ||
            mkeep !== 64'h0fffffffffffffff || !mlast || musr !== 4'd9)
          $fatal(1, "ARP frame mismatch, frame=%0d", received);
        received++;
      end
      held = {mdata,mkeep,musr,mlast}; stalled = mvalid && !mready;
    end else stalled = 0;
  end

  task automatic query(input [31:0] target, input bit expected_miss, input [47:0] expected_mac);
    @(negedge clk); query_dst = target; query_valid = 1;
    @(negedge clk); query_valid = 0;
    do @(posedge clk); while (!valid);
    if (miss !== expected_miss || src_mac !== LocalMac || (!expected_miss && dst_mac !== expected_mac))
      $fatal(1, "ARP lookup mismatch, target=%h miss=%b mac=%h", target, miss, dst_mac);
  endtask

  task automatic inject(input [335:0] packet, input bit error);
    @(negedge clk); sdata = {176'd0,packet}; svalid = 1; serror = error;
    do @(posedge clk); while (!sready);
    @(negedge clk); svalid = 0; serror = 0;
    repeat (25) @(negedge clk);
  endtask

  initial begin
    repeat (5) @(negedge clk); rst = 0;
    wait (cache_ready && pending_ready);
    repeat (5) @(negedge clk);
    expected[expected_count++] = frame(Broadcast,LocalMac,LocalIp,16'h0100,0,PeerIp);
    query(PeerIp,1,0);
    wait (received == expected_count);
    inject(frame(LocalMac,PeerMac,PeerIp,16'h0200,LocalMac,LocalIp),0);
    query(PeerIp,0,PeerMac);
    expected[expected_count++] = frame(Broadcast,LocalMac,LocalIp,16'h0100,0,Gateway);
    query(32'h08080808,1,0);
    wait (received == expected_count);
    inject(frame(LocalMac,GatewayMac,Gateway,16'h0200,LocalMac,LocalIp),0);
    query(32'h08080808,0,GatewayMac);
    inject(frame(Broadcast,AnnounceMac,AnnounceIp,16'h0100,0,AnnounceIp),0);
    query(AnnounceIp,0,AnnounceMac); // Gratuitous ARP learns a non-local target.
    expected[expected_count++] = frame(PeerMac,LocalMac,LocalIp,16'h0200,PeerMac,PeerIp);
    inject(frame(Broadcast,PeerMac,PeerIp,16'h0100,0,LocalIp),0);
    wait (received == expected_count);
    inject(frame(LocalMac,48'hdeadbeef0002,PeerIp,16'h0200,LocalMac,LocalIp),1);
    if (!rx_error) $fatal(1, "ARP MAC error was not reported");
    query(PeerIp,0,PeerMac); // Invalid frame must not poison the cache.
    query(32'hffffffff,0,Broadcast);
    @(negedge clk); clear_cache = 1; clear_pending = 1;
    @(negedge clk); clear_cache = 0; clear_pending = 0;
    wait (!cache_ready); wait (cache_ready && pending_ready);
    repeat (8) @(negedge clk);
    expected[expected_count++] = frame(Broadcast,LocalMac,LocalIp,16'h0100,0,PeerIp);
    query(PeerIp,1,0);
    wait (received == expected_count);
    repeat (30) @(negedge clk);
    if (mvalid || received != 4 || bad_source) $fatal(1, "ARP final count/source mismatch");
    $display("PASS: tb_arp_engine_top"); $finish;
  end
  initial begin #100000; $fatal(1, "ARP watchdog"); end
endmodule
`resetall
