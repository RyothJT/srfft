// ============================================================================
// File:        r2_fft_top.sv
// Description: Parameterized Radix-2 SDF Pipelined FFT Processor Top Module
//              Using clean inter-stage array buses and conditional reordering.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module r2_fft_top #(
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

  localparam int STAGES = $clog2(N_FFT);

  // ------------------------------------------------------------------------
  // Inter-stage pipeline buses for Radix-2 stages
  // ------------------------------------------------------------------------
  logic            stage_vld[0:STAGES];
  fft_pkg::cmplx_t stage_dat[0:STAGES];

  assign stage_vld[0] = in_valid;
  assign stage_dat[0] = in_data;

  genvar s;
  generate
    for (s = 0; s < STAGES; s++) begin : gen_r2_stages
      bf2_core #(
          .N_FFT(N_FFT),
          .STAGE(s),
          .DATA_WIDTH(DATA_WIDTH)
      ) u_bf2 (
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
  // Output Reorder Buffer (Bit-Reversal to Natural Order)
  // ------------------------------------------------------------------------
  generate
    if (USE_REORDER_BUFFER) begin : gen_reorder_buffer
      reorder_buffer #(
          .FFT_SIZE  (N_FFT),
          .DATA_WIDTH(DATA_WIDTH),
          .RADIX     (2)
      ) u_reorder (
          .clk     (clk),
          .rst_n   (rst_n),
          .wr_valid(stage_vld[STAGES]),
          .wr_data (stage_dat[STAGES]),
          .rd_ready(1'b1),
          .rd_valid(out_valid),
          .rd_data (out_data)
      );
    end else begin : gen_reorder_bypass
      assign out_valid = stage_vld[STAGES];
      assign out_data  = stage_dat[STAGES];
    end
  endgenerate

endmodule
