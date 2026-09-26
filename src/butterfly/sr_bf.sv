// ============================================================================
// File:        sr_butterfly.sv
// Description: Pipelined Split-Radix (R2/4) L-shaped Butterfly Unit.
//              Combines two cadd_sub units, cross add/sub with -j rotation,
//              and two cmult multipliers with aligned 5-cycle pipeline latency.
// Reference:   IEEE Document 7451270
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module sr_bf #(
    parameter int WIDTH     = DATA_WIDTH,  // Default: 16
    parameter int FRAC_BITS = FRAC_BITS,   // Default: 15
    parameter bit SCALE     = 1'b0,        // 1: Divide by 2 per addition stage
    parameter bit SATURATE  = 1'b1         // 1: Saturation on overflow
) (
    input logic clk,
    input logic rst_n,

    // Handshake
    input  logic valid_in,
    output logic valid_out,

    // 4 Complex inputs: [x(n), x(n + N/4), x(n + N/2), x(n + 3N/4)]
    input cmplx_t x0,
    input cmplx_t x1,
    input cmplx_t x2,
    input cmplx_t x3,

    // Twiddle factors: W_N^k and W_N^(3k)
    input cmplx_t w1,
    input cmplx_t w3,

    // 4 Complex outputs: [y0, y1, y2, y3]
    output cmplx_t y0,
    output cmplx_t y1,
    output cmplx_t y2,
    output cmplx_t y3
);

  // ========================================================================
  // Pipeline Delay for Twiddle Factors (2 cycles to align with Stage 2)
  // ========================================================================
  cmplx_t w1_d1, w1_d2;
  cmplx_t w3_d1, w3_d2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      w1_d1 <= '0;
      w1_d2 <= '0;
      w3_d1 <= '0;
      w3_d2 <= '0;
    end else begin
      w1_d1 <= w1;
      w1_d2 <= w1_d1;
      w3_d1 <= w3;
      w3_d2 <= w3_d1;
    end
  end

  // ========================================================================
  // Stage 1: Preliminary Complex Add/Sub (Latency: 1 cycle)
  // ========================================================================
  // Pair A: (x0, x2) -> sum_02 = x0 + x2, diff_02 = x0 - x2 (b)
  // Pair B: (x1, x3) -> sum_13 = x1 + x3, diff_13 = x1 - x3 (d)
  logic vld_stg1;
  cmplx_t sum_02, diff_02;
  cmplx_t sum_13, diff_13;

  cadd_sub #(
      .WIDTH     (WIDTH),
      .SCALE_BY_2(SCALE),
      .SATURATE  (SATURATE),
      .PIPELINE  (1)
  ) u_cadd_sub_02 (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (valid_in),
      .valid_out(vld_stg1),
      .sub      (1'b0),
      .a_re     (x0.re),
      .a_im     (x0.im),
      .b_re     (x2.re),
      .b_im     (x2.im),
      .sum_re   (sum_02.re),
      .sum_im   (sum_02.im),
      .diff_re  (diff_02.re),
      .diff_im  (diff_02.im),
      .res_re   (),
      .res_im   ()
  );

  cadd_sub #(
      .WIDTH     (WIDTH),
      .SCALE_BY_2(SCALE),
      .SATURATE  (SATURATE),
      .PIPELINE  (1)
  ) u_cadd_sub_13 (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (valid_in),
      .valid_out(),
      .sub      (1'b0),
      .a_re     (x1.re),
      .a_im     (x1.im),
      .b_re     (x3.re),
      .b_im     (x3.im),
      .sum_re   (sum_13.re),
      .sum_im   (sum_13.im),
      .diff_re  (diff_13.re),
      .diff_im  (diff_13.im),
      .res_re   (),
      .res_im   ()
  );

  // ========================================================================
  // Stage 2: Cross Addition/Subtraction with -j (Latency: 1 cycle)
  // ========================================================================
  // Let b = diff_02, d = diff_13
  // t1 = b - j*d = (b.re + d.im) + j*(b.im - d.re)
  // t2 = b + j*d = (b.re - d.im) + j*(b.im + d.re)
  logic vld_stg2;
  cmplx_t stg2_y0, stg2_y1;
  cmplx_t t1, t2;

  // Helper functions for cross scaling / saturation
  function automatic logic signed [WIDTH-1:0] process_cross(input logic signed [WIDTH:0] val);
    logic signed [WIDTH:0] shifted;
    begin
      if (SCALE) begin
        shifted = (val + 1'b1) >>> 1;
        return shifted[WIDTH-1:0];
      end else if (SATURATE) begin
        if (val > (WIDTH + 1)'(MAX_POS)) return MAX_POS;
        else if (val < (WIDTH + 1)'(MAX_NEG)) return MAX_NEG;
        else return val[WIDTH-1:0];
      end else begin
        return val[WIDTH-1:0];
      end
    end
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vld_stg2 <= 1'b0;
      stg2_y0  <= '0;
      stg2_y1  <= '0;
      t1       <= '0;
      t2       <= '0;
    end else begin
      vld_stg2 <= vld_stg1;
      stg2_y0  <= sum_02;
      stg2_y1  <= sum_13;

      // t1 = (b.re + d.im) + j*(b.im - d.re)
      t1.re    <= process_cross((WIDTH + 1)'(diff_02.re) + (WIDTH + 1)'(diff_13.im));
      t1.im    <= process_cross((WIDTH + 1)'(diff_02.im) - (WIDTH + 1)'(diff_13.re));

      // t2 = (b.re - d.im) + j*(b.im + d.re)
      t2.re    <= process_cross((WIDTH + 1)'(diff_02.re) - (WIDTH + 1)'(diff_13.im));
      t2.im    <= process_cross((WIDTH + 1)'(diff_02.im) + (WIDTH + 1)'(diff_13.re));
    end
  end

  // ========================================================================
  // Stage 3: Multipliers & Delay Matching (Latency: 3 cycles)
  // ========================================================================
  // Delay lines for y0 and y1 to match 3-cycle multiplier latency
  cmplx_t y0_pipe[0:2];
  cmplx_t y1_pipe[0:2];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y0_pipe[0] <= '0;
      y0_pipe[1] <= '0;
      y0_pipe[2] <= '0;
      y1_pipe[0] <= '0;
      y1_pipe[1] <= '0;
      y1_pipe[2] <= '0;
    end else begin
      y0_pipe[0] <= stg2_y0;
      y0_pipe[1] <= y0_pipe[0];
      y0_pipe[2] <= y0_pipe[1];

      y1_pipe[0] <= stg2_y1;
      y1_pipe[1] <= y1_pipe[0];
      y1_pipe[2] <= y1_pipe[1];
    end
  end

  assign y0 = y0_pipe[2];
  assign y1 = y1_pipe[2];

  // Multiplier for y2 = t1 * W_N^k
  cmult #(
      .WIDTH    (WIDTH),
      .FRAC_BITS(FRAC_BITS),
      .SATURATE (SATURATE)
  ) u_cmult_w1 (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (vld_stg2),
      .valid_out(valid_out),
      .a_re     (t1.re),
      .a_im     (t1.im),
      .b_re     (w1_d2.re),
      .b_im     (w1_d2.im),
      .p_re     (y2.re),
      .p_im     (y2.im)
  );

  // Multiplier for y3 = t2 * W_N^(3k)
  cmult #(
      .WIDTH    (WIDTH),
      .FRAC_BITS(FRAC_BITS),
      .SATURATE (SATURATE)
  ) u_cmult_w3 (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (vld_stg2),
      .valid_out(),
      .a_re     (t2.re),
      .a_im     (t2.im),
      .b_re     (w3_d2.re),
      .b_im     (w3_d2.im),
      .p_re     (y3.re),
      .p_im     (y3.im)
  );

endmodule
