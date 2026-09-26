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

  logic signed [WIDTH-1:0] sin_rom[0:FFT_SIZE-1];

  initial begin
    int  i;
    real angle;
    for (i = 0; i < FFT_SIZE; i = i + 1) begin
      if (i == 0 || i == FFT_SIZE / 2) begin
        sin_rom[i] = 16'sh0000;
      end else if (i == FFT_SIZE / 4) begin
        sin_rom[i] = 16'sh7FFF;  // +1.0 represented as +32767
      end else if (i == (3 * FFT_SIZE) / 4) begin
        sin_rom[i] = 16'sh8001;  // -1.0 represented as -32767 to match symmetric complement range
      end else begin
        angle = (2.0 * 3.141592653589793 * real'(i)) / real'(FFT_SIZE);
        sin_rom[i] = WIDTH
            '($rtoi($sin(angle) * real'((1 << FRAC_BITS) - 1) + ($sin(angle) >= 0 ? 0.5 : -0.5)));
      end
    end
  end

  function automatic cmplx_t get_twiddle(input logic [ADDR_WIDTH-1:0] k);
    cmplx_t tw;
    int idx, cos_idx;
    begin
      idx = int'(k);
      cos_idx = (idx + (FFT_SIZE / 4)) % FFT_SIZE;

      tw.re = sin_rom[cos_idx];
      tw.im = -sin_rom[idx];

      if (k == 0) begin
        $display(
            "[ROM LOOKUP k=0] idx=%0d, cos_idx=%0d, sin_rom[cos_idx]=0x%h (%d), sin_rom[idx]=0x%h (%d)",
            idx, cos_idx, sin_rom[cos_idx], sin_rom[cos_idx], sin_rom[idx], sin_rom[idx]);
      end

      return tw;
    end
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      w1.re <= 16'sh7FFF;
      w1.im <= 16'sh0000;
      w3.re <= 16'sh7FFF;
      w3.im <= 16'sh0000;
    end else begin
      w1 <= get_twiddle(addr1);
      w3 <= get_twiddle(addr2);
    end
  end

endmodule
