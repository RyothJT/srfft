// ============================================================================
// File:        r22_fft_top.sv
// Description: Fully Parameterized Linear Radix-2^2 SDF Pipelined FFT Processor
//              Supports power-of-4 FFT sizes up to 1024 (N = 16, 64, 256, 1024)
// ============================================================================

`timescale 1ns / 1ps

module r22_fft_top #(
    parameter int N_FFT = 64,  // e.g. 16, 64, 256, 1024
    parameter int DATA_WIDTH = fft_pkg::DATA_WIDTH,
    parameter int USE_REORDER_BUFFER = fft_pkg::USE_REORDER_BUFFER
) (
    input logic clk,
    input logic rst_n,

    input logic            in_valid,
    input fft_pkg::cmplx_t in_data,

    output logic            out_valid,
    output fft_pkg::cmplx_t out_data
);

  import fft_pkg::*;

  localparam int NUM_PAIRS = $clog2(N_FFT) / 2;

  // Inter-stage pipeline buses
  logic   stage_vld[0:NUM_PAIRS];
  cmplx_t stage_dat[0:NUM_PAIRS];

  assign stage_vld[0] = in_valid;
  assign stage_dat[0] = in_data;

  // Linear cascade of Radix-2^2 stage pairs
  genvar i;
  generate
    for (i = 0; i < NUM_PAIRS; i++) begin : gen_r22_stages
      localparam int STAGE_N = N_FFT / (4 ** i);

      r22_stage_pair #(
          .N            (STAGE_N),
          .DATA_WIDTH   (DATA_WIDTH),
          .IS_LAST_STAGE(i == NUM_PAIRS - 1)
      ) u_pair (
          .clk      (clk),
          .rst_n    (rst_n),
          .in_valid (stage_vld[i]),
          .in_data  (stage_dat[i]),
          .out_valid(stage_vld[i+1]),
          .out_data (stage_dat[i+1])
      );
    end
  endgenerate

  generate
    if (USE_REORDER_BUFFER) begin : gen_reorder_buffer
      reorder_buffer #(
          .FFT_SIZE  (N_FFT),
          .DATA_WIDTH(DATA_WIDTH)
      ) u_reorder (
          .clk     (clk),
          .rst_n   (rst_n),
          .wr_valid(stage_vld[NUM_PAIRS]),
          .wr_data (stage_dat[NUM_PAIRS]),
          .rd_ready(1'b1),                  // Continuously stream out once ready
          .rd_valid(out_valid),             // Now in natural order 0, 1, 2, ..., N-1
          .rd_data (out_data)
      );
    end else begin : gen_reorder_bypass
      assign out_valid = stage_vld[NUM_PAIRS];
      assign out_data  = stage_dat[NUM_PAIRS];
    end
  endgenerate


endmodule
