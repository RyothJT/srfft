// ============================================================================
// File:        sdf_stage.sv
// Description: Single-Path Delay Feedback (SDF) pipeline stage combining
//              a feedback multiplexer, delay buffer, and butterfly core.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module sdf_stage #(
    parameter int STAGE_DEPTH = 512,
    parameter bit HAS_TWIDDLE = 1'b1,
    parameter int SCALE = 1'b1
) (
    input logic   clk,
    input logic   rst_n,
    input logic   valid_in,
    input cmplx_t data_in,
    input logic   sdf_mode,  // 0: Load delay line, 1: Compute butterfly
    input cmplx_t tw_w,      // Twiddle factor

    output logic   valid_out,
    output cmplx_t data_out
);

  cmplx_t delay_din;
  cmplx_t delay_dout;
  logic   bf_valid;
  cmplx_t bf_y0, bf_y1;

  // Feedback Mux: During CALC mode, loop bf_y1 back into delay buffer.
  // During LOAD mode, feed incoming data_in into delay buffer.
  assign delay_din = sdf_mode ? bf_y1 : data_in;

  delay_buffer #(
      .DEPTH     (STAGE_DEPTH > 0 ? STAGE_DEPTH : 1),
      .DATA_WIDTH($bits(cmplx_t))
  ) u_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(valid_in),
      .din   (delay_din),
      .dout  (delay_dout)
  );

  bf2_core #(
      .WIDTH      (DATA_WIDTH),
      .FRAC_BITS  (FRAC_BITS),
      .SCALE      (SCALE),
      .SATURATE   (1'b1),
      .HAS_TWIDDLE(HAS_TWIDDLE)
  ) u_bf (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (valid_in),
      .valid_out(bf_valid),
      .a        (delay_dout),  // Older sample from delay buffer
      .b        (data_in),     // Current incoming sample
      .w        (tw_w),
      .y0       (bf_y0),       // Forward path to next stage
      .y1       (bf_y1)        // Feedback path
  );

  assign valid_out = bf_valid;
  assign data_out  = bf_y0;

endmodule
