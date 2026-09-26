// ============================================================================
// File:        twiddle_rom.sv
// Description: Full-circle single-array Sine/Cosine Twiddle Factor ROM.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module twiddle_rom #(
    parameter int FFT_SIZE  = 1024,
    parameter int WIDTH     = DATA_WIDTH,
    parameter int FRAC_BITS = FRAC_BITS
) (
    input logic clk,
    input logic rst_n,

    input logic [$clog2(FFT_SIZE)-1:0] addr1,
    input logic [$clog2(FFT_SIZE)-1:0] addr2,

    output cmplx_t w1,
    output cmplx_t w3
);

  localparam int ADDR_WIDTH = $clog2(FFT_SIZE);

  logic signed [WIDTH-1:0] cos_rom[0:FFT_SIZE-1];
  logic signed [WIDTH-1:0] sin_rom[0:FFT_SIZE-1];

  initial begin
    int  i;
    real angle;
    real cos_val, sin_val;
    real max_val;

    max_val = real'((1 << FRAC_BITS) - 1);  // 32767.0 for Q1.15

    for (i = 0; i < FFT_SIZE; i = i + 1) begin
      // Standard forward FFT phase convention: W_N^k = exp(-j * 2 * pi * k / N)
      angle   = -(2.0 * 3.141592653589793 * real'(i)) / real'(FFT_SIZE);

      cos_val = $cos(angle) * max_val;
      sin_val = $sin(angle) * max_val;

      // Symmetric rounding & clamping to Q1.15 [-32767, +32767] range
      if (cos_val >= 0.0) cos_rom[i] = WIDTH'($rtoi(cos_val + 0.5));
      else cos_rom[i] = WIDTH'($rtoi(cos_val - 0.5));

      if (sin_val >= 0.0) sin_rom[i] = WIDTH'($rtoi(sin_val + 0.5));
      else sin_rom[i] = WIDTH'($rtoi(sin_val - 0.5));
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      w1.re <= 16'sh7FFF;
      w1.im <= 16'sh0000;
      w3.re <= 16'sh7FFF;
      w3.im <= 16'sh0000;
    end else begin
      w1.re <= cos_rom[addr1];
      w1.im <= sin_rom[addr1];
      w3.re <= cos_rom[addr2];
      w3.im <= sin_rom[addr2];
    end
  end

endmodule
