// ============================================================================
// File:        r4_fft_top.sv
// Description: Parameterized Radix-4 SDF Pipelined FFT Processor Top Module
//              Supports all power-of-2 FFT sizes via optional final Radix-2 stage.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module r4_fft_top #(
    parameter int N_FFT            = 64,
    parameter int DATA_WIDTH       = fft_pkg::DATA_WIDTH,
    parameter int USE_REORDER_BUFFER = fft_pkg::USE_REORDER_BUFFER
) (
    input logic clk,
    input logic rst_n,

    input logic            in_valid,
    input fft_pkg::cmplx_t in_data,

    output logic            out_valid,
    output fft_pkg::cmplx_t out_data
);

  localparam int R4_STAGES    = $clog2(N_FFT) / 2;
  localparam bit HAS_EXTRA_R2 = ($clog2(N_FFT) % 2 != 0);
  localparam int TOTAL_STAGES = R4_STAGES + (HAS_EXTRA_R2 ? 1 : 0);

  // ------------------------------------------------------------------------
  // Inter-stage pipeline buses for Radix-4 stages and optional final Radix-2
  // ------------------------------------------------------------------------
  logic            stage_vld[0:TOTAL_STAGES];
  fft_pkg::cmplx_t stage_dat[0:TOTAL_STAGES];

  assign stage_vld[0] = in_valid;
  assign stage_dat[0] = in_data;

  genvar s;
  generate
    for (s = 0; s < R4_STAGES; s++) begin : gen_r4_stages
      bf4_core #(
          .N_FFT(N_FFT),
          .STAGE(s),
          .DATA_WIDTH(DATA_WIDTH)
      ) u_bf4 (
          .clk      (clk),
          .rst_n    (rst_n),
          .in_valid (stage_vld[s]),
          .in_data  (stage_dat[s]),
          .out_valid(stage_vld[s+1]),
          .out_data (stage_dat[s+1])
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
          .in_valid (stage_vld[R4_STAGES]),
          .in_data  (stage_dat[R4_STAGES]),
          .out_valid(pre_reorder_vld),
          .out_data (pre_reorder_dat)
      );
    end else begin : gen_no_final_radix2
      assign pre_reorder_vld = stage_vld[R4_STAGES];
      assign pre_reorder_dat = stage_dat[R4_STAGES];
    end
  endgenerate

  // ------------------------------------------------------------------------
  // Output Reorder Buffer (Digit/Bit-Reversal to Natural Order)
  // ------------------------------------------------------------------------
  generate
    if (USE_REORDER_BUFFER) begin : gen_reorder_buffer
      reorder_buffer #(
          .FFT_SIZE  (N_FFT),
          .DATA_WIDTH(DATA_WIDTH),
          .RADIX     (HAS_EXTRA_R2 ? 2 : 4)
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
