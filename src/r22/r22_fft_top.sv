// ============================================================================
// File:        r22_fft_top.sv
// Description: Fully Parameterized Linear Radix-2^2 / Radix-2 SDF Pipelined FFT
//              Supports ALL power-of-2 FFT sizes:
//                - Even powers (N = 16, 64, 256, 1024) -> Pure Radix-2^2
//                - Odd powers  (N = 32, 128, 512, 2048) -> Radix-2^2 + Final Radix-2
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module r22_fft_top #(
    parameter int N_FFT = 512,  // Any power of 2: 16, 32, 64, 128, 256, etc.
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

  localparam int TOTAL_STAGES = $clog2(N_FFT);
  localparam int NUM_PAIRS = TOTAL_STAGES / 2;
  localparam bit HAS_EXTRA_R2 = (TOTAL_STAGES % 2 != 0);

  // ------------------------------------------------------------------------
  // Inter-stage pipeline buses for Radix-2^2 stage pairs
  // ------------------------------------------------------------------------
  logic            stage_vld[0:NUM_PAIRS];
  fft_pkg::cmplx_t stage_dat[0:NUM_PAIRS];

  assign stage_vld[0] = in_valid;
  assign stage_dat[0] = in_data;

  genvar i;
  generate
    for (i = 0; i < NUM_PAIRS; i++) begin : gen_r22_stages
      localparam int STAGE_N = N_FFT / (4 ** i);

      // Note: IS_LAST_STAGE is only true when STAGE_N == 4.
      // For N_FFT = 32, the last pair has STAGE_N = 8, whose twiddles must NOT be bypassed.
      r22_stage_pair #(
          .N            (STAGE_N),
          .DATA_WIDTH   (DATA_WIDTH),
          .IS_LAST_STAGE(STAGE_N == 4)
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

  // ------------------------------------------------------------------------
  // Optional Final Radix-2 Stage (Only for odd powers of 2: 32, 128, 512, etc.)
  // ------------------------------------------------------------------------
  logic            pre_reorder_vld;
  fft_pkg::cmplx_t pre_reorder_dat;

  generate
    if (HAS_EXTRA_R2) begin : gen_final_radix2
      r2_butterfly #(
          .DATA_WIDTH(DATA_WIDTH)
      ) u_r2_final (
          .clk      (clk),
          .rst_n    (rst_n),
          .in_valid (stage_vld[NUM_PAIRS]),
          .in_data  (stage_dat[NUM_PAIRS]),
          .out_valid(pre_reorder_vld),
          .out_data (pre_reorder_dat)
      );
    end else begin : gen_no_final_radix2
      assign pre_reorder_vld = stage_vld[NUM_PAIRS];
      assign pre_reorder_dat = stage_dat[NUM_PAIRS];
    end
  endgenerate

  // ------------------------------------------------------------------------
  // Output Reorder Buffer (Bit-Reversal to Natural Order)
  // ------------------------------------------------------------------------
  generate
    if (USE_REORDER_BUFFER) begin : gen_reorder_buffer
      reorder_buffer #(
          .FFT_SIZE  (N_FFT),
          .DATA_WIDTH(DATA_WIDTH)
      ) u_reorder (
          .clk     (clk),
          .rst_n   (rst_n),
          .wr_valid(pre_reorder_vld),
          .wr_data (pre_reorder_dat),
          .rd_ready(1'b1),
          .rd_valid(out_valid),
          .rd_data (out_data)
      );
    end else begin : gen_reorder_bypass
      assign out_valid = pre_reorder_vld;
      assign out_data  = pre_reorder_dat;
    end
  endgenerate

endmodule
