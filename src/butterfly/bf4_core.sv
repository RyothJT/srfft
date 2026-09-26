// ============================================================================
// File:        bf4_core.sv
// Description: Standard Pipelined Radix-4 DIF Butterfly Core.
//              Latency: 5 clock cycles (1 add/sub + 1 cross + 3 cmult).
//              Requires 3 complex multipliers (W^k, W^2k, W^3k).
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module bf4_core #(
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

    // 4 Complex inputs: [x0, x1, x2, x3]
    input cmplx_t x0,
    input cmplx_t x1,
    input cmplx_t x2,
    input cmplx_t x3,

    // 3 Twiddle factors: W^k, W^(2k), W^(3k)
    input cmplx_t w1,
    input cmplx_t w2,
    input cmplx_t w3,

    // 4 Complex outputs: [y0, y1, y2, y3]
    output cmplx_t y0,
    output cmplx_t y1,
    output cmplx_t y2,
    output cmplx_t y3
);

  // ========================================================================
  // Twiddle Delay Pipeline (2 cycles to align with Stage 3 cmult inputs)
  // ========================================================================
  cmplx_t w1_d1, w1_d2;
  cmplx_t w2_d1, w2_d2;
  cmplx_t w3_d1, w3_d2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      w1_d1 <= '0;
      w1_d2 <= '0;
      w2_d1 <= '0;
      w2_d2 <= '0;
      w3_d1 <= '0;
      w3_d2 <= '0;
    end else begin
      w1_d1 <= w1;
      w1_d2 <= w1_d1;
      w2_d1 <= w2;
      w2_d2 <= w2_d1;
      w3_d1 <= w3;
      w3_d2 <= w3_d1;
    end
  end

  // ========================================================================
  // Stage 1: Preliminary Complex Add/Sub (Latency: 1 cycle)
  // ========================================================================
  logic vld_stg1;
  cmplx_t sum_02, diff_02;  // a = sum_02, b = diff_02
  cmplx_t sum_13, diff_13;  // c = sum_13, d = diff_13

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
  // Stage 2: Second Add/Sub and Cross-Terms (Latency: 1 cycle)
  // ========================================================================
  // Even leg: z0 = a + c, z2 = a - c
  // Odd leg:  t1 = b - j*d = (b.re + d.im) + j*(b.im - d.re)
  //           t3 = b + j*d = (b.re - d.im) + j*(b.im + d.re)
  logic vld_stg2;
  cmplx_t z0, z2;
  cmplx_t t1, t3;

  function automatic logic signed [WIDTH-1:0] process_val(input logic signed [WIDTH:0] val);
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
      z0 <= '0;
      z2 <= '0;
      t1 <= '0;
      t3 <= '0;
    end else begin
      vld_stg2 <= vld_stg1;

      // z0 = a + c
      z0.re <= process_val((WIDTH + 1)'(sum_02.re) + (WIDTH + 1)'(sum_13.re));
      z0.im <= process_val((WIDTH + 1)'(sum_02.im) + (WIDTH + 1)'(sum_13.im));

      // z2 = a - c
      z2.re <= process_val((WIDTH + 1)'(sum_02.re) - (WIDTH + 1)'(sum_13.re));
      z2.im <= process_val((WIDTH + 1)'(sum_02.im) - (WIDTH + 1)'(sum_13.im));

      // t1 = b - j*d = (b.re + d.im) + j*(b.im - d.re)
      t1.re <= process_val((WIDTH + 1)'(diff_02.re) + (WIDTH + 1)'(diff_13.im));
      t1.im <= process_val((WIDTH + 1)'(diff_02.im) - (WIDTH + 1)'(diff_13.re));

      // t3 = b + j*d = (b.re - d.im) + j*(b.im + d.re)
      t3.re <= process_val((WIDTH + 1)'(diff_02.re) - (WIDTH + 1)'(diff_13.im));
      t3.im <= process_val((WIDTH + 1)'(diff_02.im) + (WIDTH + 1)'(diff_13.re));
    end
  end

  // ========================================================================
  // Stage 3: Multipliers & Delay Matching (Latency: 3 cycles)
  // ========================================================================
  // Delay line for y0 = z0 (3 cycles to match cmult)
  cmplx_t z0_pipe[0:2];
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      z0_pipe[0] <= '0;
      z0_pipe[1] <= '0;
      z0_pipe[2] <= '0;
    end else begin
      z0_pipe[0] <= z0;
      z0_pipe[1] <= z0_pipe[0];
      z0_pipe[2] <= z0_pipe[1];
    end
  end

  assign y0 = z0_pipe[2];

  // Multiplier for y1 = t1 * W^k
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
      .p_re     (y1.re),
      .p_im     (y1.im)
  );

  // Multiplier for y2 = z2 * W^(2k)  <-- Strictly required in Radix-4!
  cmult #(
      .WIDTH    (WIDTH),
      .FRAC_BITS(FRAC_BITS),
      .SATURATE (SATURATE)
  ) u_cmult_w2 (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (vld_stg2),
      .valid_out(),
      .a_re     (z2.re),
      .a_im     (z2.im),
      .b_re     (w2_d2.re),
      .b_im     (w2_d2.im),
      .p_re     (y2.re),
      .p_im     (y2.im)
  );

  // Multiplier for y3 = t3 * W^(3k)
  cmult #(
      .WIDTH    (WIDTH),
      .FRAC_BITS(FRAC_BITS),
      .SATURATE (SATURATE)
  ) u_cmult_w3 (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (vld_stg2),
      .valid_out(),
      .a_re     (t3.re),
      .a_im     (t3.im),
      .b_re     (w3_d2.re),
      .b_im     (w3_d2.im),
      .p_re     (y3.re),
      .p_im     (y3.im)
  );

endmodule
