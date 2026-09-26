// ============================================================================
// File:        tb_fft_pkg.sv
// Description: Sanity check for fft_pkg.sv types and functions
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module tb_fft_pkg;

  cmplx_t a, b;
  cmplx_ext_t ext_sum;
  rot_mode_t  mode;
  sdf_state_t state;

  initial begin
    $display("Testing fft_pkg compilation & types...");

    a.re = 16'sh4000;  // 0.5 in Q1.15
    a.im = -16'sh4000;  // -0.5 in Q1.15

    b.re = 16'sh4000;
    b.im = 16'sh4000;

    ext_sum.re = (DATA_WIDTH + 1)'(a.re) + (DATA_WIDTH + 1)'(b.re);
    ext_sum.im = (DATA_WIDTH + 1)'(a.im) + (DATA_WIDTH + 1)'(b.im);

    mode = ROT_W1;
    state = SDF_CALC;

    if (ext_sum.re != 17'sh08000) begin
      $display("[FAIL] ext_sum calculation incorrect!");
      $finish;
    end

    $display("Package Sanity Test: >>> PASSED <<<");
    $finish;
  end

endmodule
