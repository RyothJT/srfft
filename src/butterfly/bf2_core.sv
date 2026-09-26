// ============================================================================
// File:        bf2_core.sv
// Description: Pipelined Radix-2 DIF Butterfly Core.
//              Computes y0 = a + b, y1 = (a - b) * w.
//              HAS_TWIDDLE=1: Latency = 4 cycles (cadd_sub + cmult).
//              HAS_TWIDDLE=0: Latency = 1 cycle  (cadd_sub only, for final stage).
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module bf2_core #(
    parameter int WIDTH       = DATA_WIDTH,  // Default: 16
    parameter int FRAC_BITS   = FRAC_BITS,   // Default: 15
    parameter bit SCALE       = 1'b0,        // 1: Divide by 2 per addition
    parameter bit SATURATE    = 1'b1,        // 1: Saturation on overflow
    parameter bit HAS_TWIDDLE = 1'b1         // 1: Instantiate cmult, 0: Bypass twiddle
) (
    input logic clk,
    input logic rst_n,

    // Handshake
    input  logic valid_in,
    output logic valid_out,

    // Complex inputs
    input cmplx_t a,
    input cmplx_t b,

    // Twiddle factor: W_N^k (ignored if HAS_TWIDDLE = 0)
    input cmplx_t w,

    // Complex outputs
    output cmplx_t y0,
    output cmplx_t y1
);

  // ========================================================================
  // Stage 1: Complex Add/Sub (Latency: 1 cycle)
  // ========================================================================
  logic   vld_addsub;
  cmplx_t sum_ab;
  cmplx_t diff_ab;

  cadd_sub #(
      .WIDTH     (WIDTH),
      .SCALE_BY_2(SCALE),
      .SATURATE  (SATURATE),
      .PIPELINE  (1)
  ) u_cadd_sub (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (valid_in),
      .valid_out(vld_addsub),
      .sub      (1'b0),
      .a_re     (a.re),
      .a_im     (a.im),
      .b_re     (b.re),
      .b_im     (b.im),
      .sum_re   (sum_ab.re),
      .sum_im   (sum_ab.im),
      .diff_re  (diff_ab.re),
      .diff_im  (diff_ab.im),
      .res_re   (),
      .res_im   ()
  );

  // ========================================================================
  // Stage 2: Twiddle Multiplication or Direct Output
  // ========================================================================
  generate
    if (HAS_TWIDDLE) begin : gen_twiddle
      // Delay twiddle factor by 1 cycle to align with cadd_sub output
      cmplx_t w_d1;
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          w_d1 <= '0;
        end else begin
          w_d1 <= w;
        end
      end

      // 3-cycle delay line for sum_ab to match cmult latency
      cmplx_t sum_pipe[0:2];
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          sum_pipe[0] <= '0;
          sum_pipe[1] <= '0;
          sum_pipe[2] <= '0;
        end else begin
          sum_pipe[0] <= sum_ab;
          sum_pipe[1] <= sum_pipe[0];
          sum_pipe[2] <= sum_pipe[1];
        end
      end

      assign y0 = sum_pipe[2];

      // Complex multiplier on difference path: y1 = diff_ab * w
      cmult #(
          .WIDTH    (WIDTH),
          .FRAC_BITS(FRAC_BITS),
          .SATURATE (SATURATE)
      ) u_cmult (
          .clk      (clk),
          .rst_n    (rst_n),
          .valid_in (vld_addsub),
          .valid_out(valid_out),
          .a_re     (diff_ab.re),
          .a_im     (diff_ab.im),
          .b_re     (w_d1.re),
          .b_im     (w_d1.im),
          .p_re     (y1.re),
          .p_im     (y1.im)
      );

    end else begin : gen_no_twiddle
      // Terminal stage: No multiplier needed (Latency: 1 cycle total)
      assign y0        = sum_ab;
      assign y1        = diff_ab;
      assign valid_out = vld_addsub;
    end
  endgenerate

endmodule
