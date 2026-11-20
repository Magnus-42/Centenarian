// -----------------------------------------------------------------------------
// File Name   : crc32_d32.v
// Module Name : crc32_d32
// Author      : LiXintao
// Created     : 2026-11-05
// Version     : 1.1
// -----------------------------------------------------------------------------
// Description : 32位并行CRC-32组合计算单元，采用IEEE 802.3多项式0xEDB88320
// Note        : 原始CRC矩阵由 https://bues.ch/cms/hacking/crcgen 生成。
//               当前版本由项目脚本再生，请勿手工编辑；数据按小端映射，纯组合逻辑
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module crc32_d32 (
    input  wire [31:0] crc,
    input  wire [31:0] data,
    output wire [31:0] crc_next
);

  // 按低位先行的位序并行展开CRC更新。
  // 组合异或矩阵直接输出下一CRC状态，不增加寄存级。

  // CRC状态更新
  assign crc_next[0] = crc[0] ^ crc[1] ^ crc[2] ^ crc[3] ^ crc[4] ^ crc[6] ^ crc[7] ^ crc[8] ^
      crc[16] ^ crc[20] ^ crc[22] ^ crc[23] ^ crc[26] ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^
      data[4] ^ data[6] ^ data[7] ^ data[8] ^ data[16] ^ data[20] ^ data[22] ^ data[23] ^
      data[26];
  assign crc_next[1] = crc[1] ^ crc[2] ^ crc[3] ^ crc[4] ^ crc[5] ^ crc[7] ^ crc[8] ^ crc[9] ^
      crc[17] ^ crc[21] ^ crc[23] ^ crc[24] ^ crc[27] ^ data[1] ^ data[2] ^ data[3] ^ data[4] ^
      data[5] ^ data[7] ^ data[8] ^ data[9] ^ data[17] ^ data[21] ^ data[23] ^ data[24] ^
      data[27];
  assign crc_next[2] = crc[0] ^ crc[2] ^ crc[3] ^ crc[4] ^ crc[5] ^ crc[6] ^ crc[8] ^ crc[9] ^
      crc[10] ^ crc[18] ^ crc[22] ^ crc[24] ^ crc[25] ^ crc[28] ^ data[0] ^ data[2] ^ data[3] ^
      data[4] ^ data[5] ^ data[6] ^ data[8] ^ data[9] ^ data[10] ^ data[18] ^ data[22] ^ data[24] ^
      data[25] ^ data[28];
  assign crc_next[3] = crc[1] ^ crc[3] ^ crc[4] ^ crc[5] ^ crc[6] ^ crc[7] ^ crc[9] ^ crc[10] ^
      crc[11] ^ crc[19] ^ crc[23] ^ crc[25] ^ crc[26] ^ crc[29] ^ data[1] ^ data[3] ^ data[4] ^
      data[5] ^ data[6] ^ data[7] ^ data[9] ^ data[10] ^ data[11] ^ data[19] ^ data[23] ^ data[25] ^
      data[26] ^ data[29];
  assign crc_next[4] = crc[2] ^ crc[4] ^ crc[5] ^ crc[6] ^ crc[7] ^ crc[8] ^ crc[10] ^ crc[11] ^
      crc[12] ^ crc[20] ^ crc[24] ^ crc[26] ^ crc[27] ^ crc[30] ^ data[2] ^ data[4] ^ data[5] ^
      data[6] ^ data[7] ^ data[8] ^ data[10] ^ data[11] ^ data[12] ^ data[20] ^ data[24] ^
      data[26] ^ data[27] ^ data[30];
  assign crc_next[5] = crc[0] ^ crc[3] ^ crc[5] ^ crc[6] ^ crc[7] ^ crc[8] ^ crc[9] ^ crc[11] ^
      crc[12] ^ crc[13] ^ crc[21] ^ crc[25] ^ crc[27] ^ crc[28] ^ crc[31] ^ data[0] ^ data[3] ^
      data[5] ^ data[6] ^ data[7] ^ data[8] ^ data[9] ^ data[11] ^ data[12] ^ data[13] ^ data[21] ^
      data[25] ^ data[27] ^ data[28] ^ data[31];
  assign crc_next[6] = crc[0] ^ crc[2] ^ crc[3] ^ crc[9] ^ crc[10] ^ crc[12] ^ crc[13] ^ crc[14] ^
      crc[16] ^ crc[20] ^ crc[23] ^ crc[28] ^ crc[29] ^ data[0] ^ data[2] ^ data[3] ^ data[9] ^
      data[10] ^ data[12] ^ data[13] ^ data[14] ^ data[16] ^ data[20] ^ data[23] ^ data[28] ^
      data[29];
  assign crc_next[7] = crc[1] ^ crc[3] ^ crc[4] ^ crc[10] ^ crc[11] ^ crc[13] ^ crc[14] ^ crc[15] ^
      crc[17] ^ crc[21] ^ crc[24] ^ crc[29] ^ crc[30] ^ data[1] ^ data[3] ^ data[4] ^ data[10] ^
      data[11] ^ data[13] ^ data[14] ^ data[15] ^ data[17] ^ data[21] ^ data[24] ^ data[29] ^
      data[30];
  assign crc_next[8] = crc[0] ^ crc[2] ^ crc[4] ^ crc[5] ^ crc[11] ^ crc[12] ^ crc[14] ^ crc[15] ^
      crc[16] ^ crc[18] ^ crc[22] ^ crc[25] ^ crc[30] ^ crc[31] ^ data[0] ^ data[2] ^ data[4] ^
      data[5] ^ data[11] ^ data[12] ^ data[14] ^ data[15] ^ data[16] ^ data[18] ^ data[22] ^
      data[25] ^ data[30] ^ data[31];
  assign crc_next[9] = crc[0] ^ crc[2] ^ crc[4] ^ crc[5] ^ crc[7] ^ crc[8] ^ crc[12] ^ crc[13] ^
      crc[15] ^ crc[17] ^ crc[19] ^ crc[20] ^ crc[22] ^ crc[31] ^ data[0] ^ data[2] ^ data[4] ^
      data[5] ^ data[7] ^ data[8] ^ data[12] ^ data[13] ^ data[15] ^ data[17] ^ data[19] ^
      data[20] ^ data[22] ^ data[31];
  assign crc_next[10] = crc[0] ^ crc[2] ^ crc[4] ^ crc[5] ^ crc[7] ^ crc[9] ^ crc[13] ^ crc[14] ^
      crc[18] ^ crc[21] ^ crc[22] ^ crc[26] ^ data[0] ^ data[2] ^ data[4] ^ data[5] ^ data[7] ^
      data[9] ^ data[13] ^ data[14] ^ data[18] ^ data[21] ^ data[22] ^ data[26];
  assign crc_next[11] = crc[1] ^ crc[3] ^ crc[5] ^ crc[6] ^ crc[8] ^ crc[10] ^ crc[14] ^ crc[15] ^
      crc[19] ^ crc[22] ^ crc[23] ^ crc[27] ^ data[1] ^ data[3] ^ data[5] ^ data[6] ^ data[8] ^
      data[10] ^ data[14] ^ data[15] ^ data[19] ^ data[22] ^ data[23] ^ data[27];
  assign crc_next[12] = crc[2] ^ crc[4] ^ crc[6] ^ crc[7] ^ crc[9] ^ crc[11] ^ crc[15] ^ crc[16] ^
      crc[20] ^ crc[23] ^ crc[24] ^ crc[28] ^ data[2] ^ data[4] ^ data[6] ^ data[7] ^ data[9] ^
      data[11] ^ data[15] ^ data[16] ^ data[20] ^ data[23] ^ data[24] ^ data[28];
  assign crc_next[13] = crc[0] ^ crc[3] ^ crc[5] ^ crc[7] ^ crc[8] ^ crc[10] ^ crc[12] ^ crc[16] ^
      crc[17] ^ crc[21] ^ crc[24] ^ crc[25] ^ crc[29] ^ data[0] ^ data[3] ^ data[5] ^ data[7] ^
      data[8] ^ data[10] ^ data[12] ^ data[16] ^ data[17] ^ data[21] ^ data[24] ^ data[25] ^
      data[29];
  assign crc_next[14] = crc[0] ^ crc[1] ^ crc[4] ^ crc[6] ^ crc[8] ^ crc[9] ^ crc[11] ^ crc[13] ^
      crc[17] ^ crc[18] ^ crc[22] ^ crc[25] ^ crc[26] ^ crc[30] ^ data[0] ^ data[1] ^ data[4] ^
      data[6] ^ data[8] ^ data[9] ^ data[11] ^ data[13] ^ data[17] ^ data[18] ^ data[22] ^
      data[25] ^ data[26] ^ data[30];
  assign crc_next[15] = crc[1] ^ crc[2] ^ crc[5] ^ crc[7] ^ crc[9] ^ crc[10] ^ crc[12] ^ crc[14] ^
      crc[18] ^ crc[19] ^ crc[23] ^ crc[26] ^ crc[27] ^ crc[31] ^ data[1] ^ data[2] ^ data[5] ^
      data[7] ^ data[9] ^ data[10] ^ data[12] ^ data[14] ^ data[18] ^ data[19] ^ data[23] ^
      data[26] ^ data[27] ^ data[31];
  assign crc_next[16] = crc[1] ^ crc[4] ^ crc[7] ^ crc[10] ^ crc[11] ^ crc[13] ^ crc[15] ^ crc[16] ^
      crc[19] ^ crc[22] ^ crc[23] ^ crc[24] ^ crc[26] ^ crc[27] ^ crc[28] ^ data[1] ^ data[4] ^
      data[7] ^ data[10] ^ data[11] ^ data[13] ^ data[15] ^ data[16] ^ data[19] ^ data[22] ^
      data[23] ^ data[24] ^ data[26] ^ data[27] ^ data[28];
  assign crc_next[17] = crc[2] ^ crc[5] ^ crc[8] ^ crc[11] ^ crc[12] ^ crc[14] ^ crc[16] ^ crc[17] ^
      crc[20] ^ crc[23] ^ crc[24] ^ crc[25] ^ crc[27] ^ crc[28] ^ crc[29] ^ data[2] ^ data[5] ^
      data[8] ^ data[11] ^ data[12] ^ data[14] ^ data[16] ^ data[17] ^ data[20] ^ data[23] ^
      data[24] ^ data[25] ^ data[27] ^ data[28] ^ data[29];
  assign crc_next[18] = crc[0] ^ crc[3] ^ crc[6] ^ crc[9] ^ crc[12] ^ crc[13] ^ crc[15] ^ crc[17] ^
      crc[18] ^ crc[21] ^ crc[24] ^ crc[25] ^ crc[26] ^ crc[28] ^ crc[29] ^ crc[30] ^ data[0] ^
      data[3] ^ data[6] ^ data[9] ^ data[12] ^ data[13] ^ data[15] ^ data[17] ^ data[18] ^
      data[21] ^ data[24] ^ data[25] ^ data[26] ^ data[28] ^ data[29] ^ data[30];
  assign crc_next[19] = crc[0] ^ crc[1] ^ crc[4] ^ crc[7] ^ crc[10] ^ crc[13] ^ crc[14] ^ crc[16] ^
      crc[18] ^ crc[19] ^ crc[22] ^ crc[25] ^ crc[26] ^ crc[27] ^ crc[29] ^ crc[30] ^ crc[31] ^
      data[0] ^ data[1] ^ data[4] ^ data[7] ^ data[10] ^ data[13] ^ data[14] ^ data[16] ^ data[18] ^
      data[19] ^ data[22] ^ data[25] ^ data[26] ^ data[27] ^ data[29] ^ data[30] ^ data[31];
  assign crc_next[20] = crc[0] ^ crc[3] ^ crc[4] ^ crc[5] ^ crc[6] ^ crc[7] ^ crc[11] ^ crc[14] ^
      crc[15] ^ crc[16] ^ crc[17] ^ crc[19] ^ crc[22] ^ crc[27] ^ crc[28] ^ crc[30] ^ crc[31] ^
      data[0] ^ data[3] ^ data[4] ^ data[5] ^ data[6] ^ data[7] ^ data[11] ^ data[14] ^ data[15] ^
      data[16] ^ data[17] ^ data[19] ^ data[22] ^ data[27] ^ data[28] ^ data[30] ^ data[31];
  assign crc_next[21] = crc[0] ^ crc[2] ^ crc[3] ^ crc[5] ^ crc[12] ^ crc[15] ^ crc[17] ^ crc[18] ^
      crc[22] ^ crc[26] ^ crc[28] ^ crc[29] ^ crc[31] ^ data[0] ^ data[2] ^ data[3] ^ data[5] ^
      data[12] ^ data[15] ^ data[17] ^ data[18] ^ data[22] ^ data[26] ^ data[28] ^ data[29] ^
      data[31];
  assign crc_next[22] = crc[2] ^ crc[7] ^ crc[8] ^ crc[13] ^ crc[18] ^ crc[19] ^ crc[20] ^ crc[22] ^
      crc[26] ^ crc[27] ^ crc[29] ^ crc[30] ^ data[2] ^ data[7] ^ data[8] ^ data[13] ^ data[18] ^
      data[19] ^ data[20] ^ data[22] ^ data[26] ^ data[27] ^ data[29] ^ data[30];
  assign crc_next[23] = crc[0] ^ crc[3] ^ crc[8] ^ crc[9] ^ crc[14] ^ crc[19] ^ crc[20] ^ crc[21] ^
      crc[23] ^ crc[27] ^ crc[28] ^ crc[30] ^ crc[31] ^ data[0] ^ data[3] ^ data[8] ^ data[9] ^
      data[14] ^ data[19] ^ data[20] ^ data[21] ^ data[23] ^ data[27] ^ data[28] ^ data[30] ^
      data[31];
  assign crc_next[24] = crc[2] ^ crc[3] ^ crc[6] ^ crc[7] ^ crc[8] ^ crc[9] ^ crc[10] ^ crc[15] ^
      crc[16] ^ crc[21] ^ crc[23] ^ crc[24] ^ crc[26] ^ crc[28] ^ crc[29] ^ crc[31] ^ data[2] ^
      data[3] ^ data[6] ^ data[7] ^ data[8] ^ data[9] ^ data[10] ^ data[15] ^ data[16] ^ data[21] ^
      data[23] ^ data[24] ^ data[26] ^ data[28] ^ data[29] ^ data[31];
  assign crc_next[25] = crc[1] ^ crc[2] ^ crc[6] ^ crc[9] ^ crc[10] ^ crc[11] ^ crc[17] ^ crc[20] ^
      crc[23] ^ crc[24] ^ crc[25] ^ crc[26] ^ crc[27] ^ crc[29] ^ crc[30] ^ data[1] ^ data[2] ^
      data[6] ^ data[9] ^ data[10] ^ data[11] ^ data[17] ^ data[20] ^ data[23] ^ data[24] ^
      data[25] ^ data[26] ^ data[27] ^ data[29] ^ data[30];
  assign crc_next[26] = crc[2] ^ crc[3] ^ crc[7] ^ crc[10] ^ crc[11] ^ crc[12] ^ crc[18] ^ crc[21] ^
      crc[24] ^ crc[25] ^ crc[26] ^ crc[27] ^ crc[28] ^ crc[30] ^ crc[31] ^ data[2] ^ data[3] ^
      data[7] ^ data[10] ^ data[11] ^ data[12] ^ data[18] ^ data[21] ^ data[24] ^ data[25] ^
      data[26] ^ data[27] ^ data[28] ^ data[30] ^ data[31];
  assign crc_next[27] = crc[0] ^ crc[1] ^ crc[2] ^ crc[6] ^ crc[7] ^ crc[11] ^ crc[12] ^ crc[13] ^
      crc[16] ^ crc[19] ^ crc[20] ^ crc[23] ^ crc[25] ^ crc[27] ^ crc[28] ^ crc[29] ^ crc[31] ^
      data[0] ^ data[1] ^ data[2] ^ data[6] ^ data[7] ^ data[11] ^ data[12] ^ data[13] ^ data[16] ^
      data[19] ^ data[20] ^ data[23] ^ data[25] ^ data[27] ^ data[28] ^ data[29] ^ data[31];
  assign crc_next[28] = crc[0] ^ crc[4] ^ crc[6] ^ crc[12] ^ crc[13] ^ crc[14] ^ crc[16] ^ crc[17] ^
      crc[21] ^ crc[22] ^ crc[23] ^ crc[24] ^ crc[28] ^ crc[29] ^ crc[30] ^ data[0] ^ data[4] ^
      data[6] ^ data[12] ^ data[13] ^ data[14] ^ data[16] ^ data[17] ^ data[21] ^ data[22] ^
      data[23] ^ data[24] ^ data[28] ^ data[29] ^ data[30];
  assign crc_next[29] = crc[0] ^ crc[1] ^ crc[5] ^ crc[7] ^ crc[13] ^ crc[14] ^ crc[15] ^ crc[17] ^
      crc[18] ^ crc[22] ^ crc[23] ^ crc[24] ^ crc[25] ^ crc[29] ^ crc[30] ^ crc[31] ^ data[0] ^
      data[1] ^ data[5] ^ data[7] ^ data[13] ^ data[14] ^ data[15] ^ data[17] ^ data[18] ^
      data[22] ^ data[23] ^ data[24] ^ data[25] ^ data[29] ^ data[30] ^ data[31];
  assign crc_next[30] = crc[3] ^ crc[4] ^ crc[7] ^ crc[14] ^ crc[15] ^ crc[18] ^ crc[19] ^ crc[20] ^
      crc[22] ^ crc[24] ^ crc[25] ^ crc[30] ^ crc[31] ^ data[3] ^ data[4] ^ data[7] ^ data[14] ^
      data[15] ^ data[18] ^ data[19] ^ data[20] ^ data[22] ^ data[24] ^ data[25] ^ data[30] ^
      data[31];
  assign crc_next[31] = crc[0] ^ crc[1] ^ crc[2] ^ crc[3] ^ crc[5] ^ crc[6] ^ crc[7] ^ crc[15] ^
      crc[19] ^ crc[21] ^ crc[22] ^ crc[25] ^ crc[31] ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^
      data[5] ^ data[6] ^ data[7] ^ data[15] ^ data[19] ^ data[21] ^ data[22] ^ data[25] ^
      data[31];

endmodule
`resetall
