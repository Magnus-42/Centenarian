// -----------------------------------------------------------------------------
// File Name   : tb_udp_ipv6_top.sv
// Module Name : tb_udp_ipv6_top
// Author      : LiXintao
// Created     : 2026-11-22
// Version     : v1.0

// Description : 验证IPv6 UDP封装、解封装、校验和、端口分流与背压。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module tb_udp_ipv6_top;

  localparam integer MaxPayload = 65527;
  localparam integer RxUsrWidth = 433;
  localparam [127:0] SrcIp = 128'hEFCDAB896745230110000000B80D0120;
  localparam [127:0] DstIp = 128'hA98867452301674508070000B80D0120;
  localparam [96:0] NetworkUsr = {48'h010203040506, 48'hA1A2A3A4A5A6, 1'b0};
  localparam [7:0] HopLimit = 8'h40;
  localparam [3:0] Request = 4'd7;

  reg clk = 1'b0;
  reg rst = 1'b1;
  integer cycle_count = 0;

  reg [511:0] tx_sdata = '0;
  reg [63:0] tx_skeep = '0;
  reg tx_slast = 1'b0;
  reg tx_svalid = 1'b0;
  reg [299:0] tx_susr = '0;
  wire tx_sready;
  wire [511:0] tx_mdata;
  wire [63:0] tx_mkeep;
  wire tx_mlast;
  wire tx_mvalid;
  wire [3:0] tx_musr;
  wire tx_mready = !rst && (cycle_count % 11 >= 4);

  reg [511:0] rx_sdata = '0;
  reg [63:0] rx_skeep = '0;
  reg rx_slast = 1'b0;
  reg rx_svalid = 1'b0;
  wire rx_sready;
  wire [1023:0] rx_mdata;
  wire [127:0] rx_mkeep;
  wire [1:0] rx_mlast;
  wire [1:0] rx_mvalid;
  wire [2*RxUsrWidth-1:0] rx_musr;
  wire [1:0] rx_mready = {!rst && (cycle_count % 7 >= 2), !rst && (cycle_count % 5 >= 3)};

  reg [7:0] packet_bytes[0:MaxPayload+47];

  always #5 clk = !clk;
  always @(posedge clk) cycle_count <= cycle_count + 1;

  udp_ipv6_top #(
      .RxPortCount(1),
      .TxChannelCount(1)
  ) udp_ipv6_top_inst (
      .clk               (clk),
      .rst               (rst),
      .cfg_dst_port_range(32'hE803E803),  // 端口1000，保留总线字节序。
      .rx_axis_sdata     (rx_sdata),
      .rx_axis_skeep     (rx_skeep),
      .rx_axis_slast     (rx_slast),
      .rx_axis_svalid    (rx_svalid),
      .rx_axis_susr      (NetworkUsr),
      .rx_axis_sready    (rx_sready),
      .rx_axis_mdata     (rx_mdata),
      .rx_axis_mkeep     (rx_mkeep),
      .rx_axis_mlast     (rx_mlast),
      .rx_axis_mvalid    (rx_mvalid),
      .rx_axis_musr      (rx_musr),
      .rx_axis_mready    (rx_mready),
      .tx_axis_sdata     (tx_sdata),
      .tx_axis_skeep     (tx_skeep),
      .tx_axis_slast     (tx_slast),
      .tx_axis_svalid    (tx_svalid),
      .tx_axis_susr      (tx_susr),
      .tx_axis_sready    (tx_sready),
      .tx_axis_mdata     (tx_mdata),
      .tx_axis_mkeep     (tx_mkeep),
      .tx_axis_mlast     (tx_mlast),
      .tx_axis_mvalid    (tx_mvalid),
      .tx_axis_musr      (tx_musr),
      .tx_axis_mready    (tx_mready)
  );

  // Every valid stalled beat must retain all meaningful interface fields.
  reg tx_stalled = 0;
  reg [580:0] tx_held;
  reg [1:0] rx_stalled = 0;
  reg [512+64+RxUsrWidth:0] rx_held[0:1];
  always @(posedge clk) begin
    if (rst) begin tx_stalled = 0; rx_stalled = 0; end
    else begin
      if (tx_stalled && (tx_mvalid !== 1'b1 || {tx_mdata,tx_mkeep,tx_musr,tx_mlast} !== tx_held))
        $fatal(1, "UDP TX changed under backpressure");
      tx_stalled = tx_mvalid && !tx_mready;
      tx_held = {tx_mdata,tx_mkeep,tx_musr,tx_mlast};
      for (integer ch = 0; ch < 2; ch++) begin
        if (rx_stalled[ch] && (rx_mvalid[ch] !== 1'b1 ||
            {rx_mdata[ch*512+:512],rx_mkeep[ch*64+:64],rx_musr[ch*RxUsrWidth+:RxUsrWidth],rx_mlast[ch]} !== rx_held[ch]))
          $fatal(1, "UDP RX changed under backpressure");
        rx_stalled[ch] = rx_mvalid[ch] && !rx_mready[ch];
        rx_held[ch] = {rx_mdata[ch*512+:512],rx_mkeep[ch*64+:64],rx_musr[ch*RxUsrWidth+:RxUsrWidth],rx_mlast[ch]};
      end
    end
  end

  function automatic [15:0] bus_word(input [15:0] word_value);
    return {word_value[7:0], word_value[15:8]};
  endfunction

  function automatic [7:0] payload_byte(input integer index);
    return 8'((index * 73) ^ (index / 64) ^ 8'hA5);
  endfunction

  // 按网络字节序独立计算校验和，使用逐字折叠核对RTL的分级累加。
  function automatic [15:0] ref_checksum(input integer size, input [15:0] src_port,
                                         input [15:0] dst_port);
    integer unsigned sum;
    sum = 17 + 2 * (size + 8) + int'(src_port) + int'(dst_port);
    for (integer i = 0; i < 8; i++) begin
      sum += int'(bus_word(SrcIp[i*16+:16])) + int'(bus_word(DstIp[i*16+:16]));
    end
    for (integer i = 0; i < size; i += 2) begin
      sum += int'({payload_byte(i), (i + 1 < size) ? payload_byte(i + 1) : 8'd0});
      sum = (sum & 65535) + (sum >> 16);
    end
    while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
    return ~sum[15:0];
  endfunction

  task automatic send_tx(input integer size, input [15:0] src_port, input [15:0] dst_port);
    integer offset;
    offset = 0;
    do begin
      @(negedge clk);
      tx_sdata = '1;
      for (integer lane = 0; lane < 64; lane++) begin
        tx_skeep[lane] = offset + lane < size;
        if (tx_skeep[lane]) tx_sdata[lane*8+:8] = payload_byte(offset + lane);
      end
      tx_susr   = {DstIp, SrcIp, bus_word(dst_port), bus_word(src_port), HopLimit, Request};
      tx_svalid = 1'b1;
      tx_slast  = offset + 64 >= size;
      do @(posedge clk); while (!tx_sready);
      offset += 64;
    end while (offset < size);
    @(negedge clk);
    tx_svalid = 1'b0;
  endtask

  task automatic capture_tx(input integer size, input [15:0] src_port, input [15:0] dst_port);
    integer offset;
    reg [383:0] expected_header;
    reg [15:0] checksum;
    checksum = ref_checksum(size, src_port, dst_port);
    if (checksum == 0) checksum = 16'hFFFF;
    expected_header = {
      bus_word(checksum),
      bus_word(16'(size + 8)),
      bus_word(dst_port),
      bus_word(src_port),
      DstIp,
      SrcIp,
      HopLimit,
      8'd17,
      bus_word(16'(size + 8)),
      32'h00000060
    };
    offset = 0;
    while (offset < size + 48) begin
      @(posedge clk);
      if (tx_mvalid && tx_mready) begin
        if (tx_mlast !== (offset + 64 >= size + 48) || tx_musr !== Request)
          $fatal(1, "TX last/usr mismatch, size=%0d offset=%0d", size, offset);
        for (integer lane = 0; lane < 64; lane++) begin
          if (tx_mkeep[lane] !== (offset + lane < size + 48))
            $fatal(1, "TX keep mismatch, size=%0d offset=%0d lane=%0d", size, offset, lane);
          if (tx_mkeep[lane]) begin
            packet_bytes[offset+lane] = tx_mdata[lane*8+:8];
            if (packet_bytes[offset+lane] !==
                ((offset+lane < 48) ? expected_header[(offset+lane)*8+:8] :
                 payload_byte(
                    offset + lane - 48
                )))
              $fatal(1, "TX data mismatch, size=%0d byte=%0d", size, offset + lane);
          end
        end
        offset += 64;
      end
    end
  endtask

  task automatic send_rx(input integer size);
    integer offset;
    offset = 0;
    while (offset < size) begin
      @(negedge clk);
      rx_sdata = '1;
      for (integer lane = 0; lane < 64; lane++) begin
        rx_skeep[lane] = offset + lane < size;
        if (rx_skeep[lane]) rx_sdata[lane*8+:8] = packet_bytes[offset+lane];
      end
      rx_svalid = 1'b1;
      rx_slast  = offset + 64 >= size;
      do @(posedge clk); while (!rx_sready);
      offset += 64;
    end
    @(negedge clk);
    rx_svalid = 1'b0;
  endtask

  task automatic check_rx(input integer size, input [15:0] src_port, input [15:0] dst_port);
    integer offset;
    integer channel;
    reg [RxUsrWidth-1:0] expected_usr;
    channel = (dst_port == 1000) ? 0 : 1;
    expected_usr = {
      {packet_bytes[45], packet_bytes[44]},
      bus_word(src_port),
      bus_word(dst_port),
      DstIp,
      SrcIp,
      HopLimit,
      {packet_bytes[5], packet_bytes[4]},
      8'd17,
      NetworkUsr
    };
    offset = 0;
    do begin
      @(posedge clk);
      if (rx_mvalid[1-channel]) $fatal(1, "RX wrong channel, size=%0d", size);
      if (rx_mvalid[channel] && rx_mready[channel]) begin
        if (rx_musr[channel*RxUsrWidth+:RxUsrWidth] !== expected_usr ||
            rx_mlast[channel] !== (offset + 64 >= size))
          $fatal(1, "RX last/usr mismatch, size=%0d offset=%0d", size, offset);
        for (integer lane = 0; lane < 64; lane++) begin
          if (rx_mkeep[channel*64+lane] !== (offset + lane < size))
            $fatal(1, "RX keep mismatch, size=%0d offset=%0d lane=%0d", size, offset, lane);
          if (offset + lane < size &&
              rx_mdata[channel*512+lane*8+:8] !== packet_bytes[48+offset+lane])
            $fatal(1, "RX data mismatch, size=%0d byte=%0d", size, offset + lane);
        end
        offset += 64;
      end
    end while (offset < size || offset == 0);
  endtask

  task automatic replay_rx(input integer size, input [15:0] src_port, input [15:0] dst_port);
    fork
      send_rx(size + 48);
      check_rx(size, src_port, dst_port);
    join
    repeat (20) begin
      @(posedge clk);
      if (|rx_mvalid) $fatal(1, "UDP RX produced extra output");
    end
  endtask

  task automatic round_trip(input integer size, input [15:0] src_port, input [15:0] dst_port);
    fork
      send_tx(size, src_port, dst_port);
      capture_tx(size, src_port, dst_port);
    join
    replay_rx(size, src_port, dst_port);
  endtask

  task automatic expect_rx_drop(input integer size);
    fork
      send_rx(size);
      repeat (80) begin
        @(posedge clk);
        if (|rx_mvalid) $fatal(1, "RX delivered an invalid datagram");
      end
    join
  endtask

  task automatic reset_partial_packet;
    @(negedge clk); tx_svalid = 1; tx_slast = 0; tx_skeep = '1; tx_sdata = '1;
    do @(posedge clk); while (!tx_sready);
    @(negedge clk); tx_svalid = 0;
    repeat (3) @(negedge clk);
    rst = 1;
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (30) begin
      @(posedge clk);
      if (tx_mvalid || |rx_mvalid) $fatal(1, "UDP reset left stale data");
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst = 1'b0;

    round_trip(0, ref_checksum(0, 0, 1000), 1000);  // 全零计算值编码为FFFF。
    round_trip(1, 12345, 1001);
    round_trip(16, 12345, 1000);
    round_trip(17, 12345, 1000);
    round_trip(56, 12345, 1001);
    round_trip(57, 12345, 1000);
    round_trip(64, 12345, 1000);
    round_trip(65, 12345, 1001);
    round_trip(MaxPayload, 12345, 1000);

    round_trip(65, 12345, 1000);

    // RX按输入的有效字节及末拍转发，UDP校验和和长度字段不参与丢帧判定。
    packet_bytes[65] ^= 8'h80;
    replay_rx(65, 12345, 1000);
    packet_bytes[65] ^= 8'h80;
    {packet_bytes[46], packet_bytes[47]} = 16'd0;
    replay_rx(65, 12345, 1000);
    packet_bytes[5] ^= 8'h01;
    replay_rx(65, 12345, 1000);
    packet_bytes[5] ^= 8'h01;
    packet_bytes[45] ^= 8'h01;
    replay_rx(65, 12345, 1000);
    packet_bytes[45] ^= 8'h01;
    replay_rx(64, 12345, 1000);
    packet_bytes[6] = 8'd44;
    expect_rx_drop(113);
    reset_partial_packet();
    round_trip(3, 12345, 1001);
    repeat (30) begin
      @(posedge clk);
      if (tx_mvalid || |rx_mvalid) $fatal(1, "UDP trailing output");
    end

    $display("PASS: tb_udp_ipv6_top");
    $finish;
  end

  initial begin
    #500000;
    $fatal(1, "Timeout: tb_udp_ipv6_top");
  end

endmodule
`resetall
