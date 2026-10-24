// ============================================================================
// File:        twiddle_rom.sv
// Description: Full-circle single-array Sine/Cosine Twiddle Factor ROM.
//              Uses full Q(FRAC_BITS) scale with saturated positive clamping.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module twiddle_rom #(
    parameter int FFT_SIZE  = 1024,
    parameter int WIDTH     = fft_pkg::DATA_WIDTH,
    parameter int FRAC_BITS = fft_pkg::FRAC_BITS
) (
    input logic clk,
    input logic rst_n,

    input logic [$clog2(FFT_SIZE)-1:0] addr1,
    input logic [$clog2(FFT_SIZE)-1:0] addr2,

    output cmplx_t w1,
    output cmplx_t w3
);

  localparam int ADDR_WIDTH = $clog2(FFT_SIZE);

  // Maximum and minimum representable values in signed WIDTH-bit two's complement
  localparam logic signed [WIDTH-1:0] MAX_POS = {1'b0, {(WIDTH - 1) {1'b1}}};  // +32767 for 16-bit
  localparam logic signed [WIDTH-1:0] MIN_NEG = {1'b1, {(WIDTH - 1) {1'b0}}};  // -32768 for 16-bit

  logic signed [WIDTH-1:0] cos_rom[0:FFT_SIZE-1];
  logic signed [WIDTH-1:0] sin_rom[0:FFT_SIZE-1];

  initial begin
    int  i;
    real angle;
    real scale;
    int  c_int, s_int;
    int  max_val, min_val;

    scale   = real'(1 << FRAC_BITS);            // Exact scale factor: 32768.0 for Q15
    max_val = (1 << (WIDTH - 1)) - 1;           // +32767
    min_val = -(1 << (WIDTH - 1));              // -32768

    for (i = 0; i < FFT_SIZE; i = i + 1) begin
      // Standard forward FFT phase convention: W_N^k = exp(-j * 2 * pi * k / N)
      angle = -(2.0 * 3.141592653589793 * real'(i)) / real'(FFT_SIZE);

      // Round to nearest integer using true full-scale factor
      c_int = $rtoi($floor($cos(angle) * scale + 0.5));
      s_int = $rtoi($floor($sin(angle) * scale + 0.5));

      // Saturated clamp: prevents +1.0 (32768) from overflowing into -32768 (16'h8000)
      if (c_int > max_val) c_int = max_val;
      if (c_int < min_val) c_int = min_val;

      if (s_int > max_val) s_int = max_val;
      if (s_int < min_val) s_int = min_val;

      cos_rom[i] = c_int[WIDTH-1:0];
      sin_rom[i] = s_int[WIDTH-1:0];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      w1.re <= MAX_POS;
      w1.im <= '0;
      w3.re <= MAX_POS;
      w3.im <= '0;
    end else begin
      w1.re <= cos_rom[addr1];
      w1.im <= sin_rom[addr1];
      w3.re <= cos_rom[addr2];
      w3.im <= sin_rom[addr2];
    end
  end

endmodule
