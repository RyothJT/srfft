// ============================================================================
// File:        tb_twiddle_rom.sv
// Description: Unit testbench with deep diagnostics for twiddle_rom.sv
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module tb_twiddle_rom;

  localparam int FFT_SIZE = 64;
  localparam int CLK_PER = 10;
  localparam real SCALE_VAL = 32768.0;

  logic clk, rst_n;
  logic [$clog2(FFT_SIZE)-1:0] addr1, addr2;
  cmplx_t w1, w3;

  twiddle_rom #(
      .FFT_SIZE (FFT_SIZE),
      .WIDTH    (DATA_WIDTH),
      .FRAC_BITS(FRAC_BITS)
  ) dut (
      .clk  (clk),
      .rst_n(rst_n),
      .addr1(addr1),
      .addr2(addr2),
      .w1   (w1),
      .w3   (w3)
  );

`ifndef DUMP_FILE
  `define DUMP_FILE ""
`endif

  initial begin
    if (`DUMP_FILE != "") begin
      $dumpfile(`DUMP_FILE);
      $dumpvars(0, tb_twiddle_rom);
    end
  end

  initial begin
    clk = 0;
    forever #(CLK_PER / 2) clk = ~clk;
  end

  int error_count = 0;
  int test_count = 0;
  int k;

  initial begin
    addr1 = '0;
    addr2 = '0;
    rst_n = 1'b0;

    #(CLK_PER * 5);
    rst_n = 1'b1;
    #(CLK_PER * 2);

    $display("--- Verifying Twiddle ROM across all %0d indices ---", FFT_SIZE);

    for (k = 0; k < FFT_SIZE; k = k + 1) begin
      real angle1, angle3;
      real exp_w1_re, exp_w1_im;
      real exp_w3_re, exp_w3_im;
      real got_w1_re, got_w1_im;
      real got_w3_re, got_w3_im;

      // Apply address on clock edge
      @(posedge clk);
      addr1 = k;
      addr2 = (3 * k) % FFT_SIZE;

      // Wait for registered output
      @(posedge clk);
      #1;

      angle1 = (2.0 * 3.141592653589793 * real'(k)) / real'(FFT_SIZE);
      angle3 = (2.0 * 3.141592653589793 * real'((3 * k) % FFT_SIZE)) / real'(FFT_SIZE);

      exp_w1_re = $cos(angle1);
      exp_w1_im = -$sin(angle1);
      exp_w3_re = $cos(angle3);
      exp_w3_im = -$sin(angle3);

      got_w1_re = real'(w1.re) / SCALE_VAL;
      got_w1_im = real'(w1.im) / SCALE_VAL;
      got_w3_re = real'(w3.re) / SCALE_VAL;
      got_w3_im = real'(w3.im) / SCALE_VAL;

      if ((got_w1_re - exp_w1_re > 0.0005) || (exp_w1_re - got_w1_re > 0.0005) ||
                (got_w1_im - exp_w1_im > 0.0005) || (exp_w1_im - got_w1_im > 0.0005) ||
                (got_w3_re - exp_w3_re > 0.0005) || (exp_w3_re - got_w3_re > 0.0005) ||
                (got_w3_im - exp_w3_im > 0.0005) || (exp_w3_im - got_w3_im > 0.0005)) begin

        $display("-------------------------------------------------------------");
        $display("[DIAGNOSTIC] MISMATCH at k=%0d (addr1=%0d, addr2=%0d)", k, addr1, addr2);
        $display("  W1 Expected: Real=%f, Imag=%f", exp_w1_re, exp_w1_im);
        $display("  W1 Got     : Real=%f, Imag=%f (Hex: re=%h, im=%h)", got_w1_re, got_w1_im,
                 w1.re, w1.im);
        $display("  W3 Expected: Real=%f, Imag=%f", exp_w3_re, exp_w3_im);
        $display("  W3 Got     : Real=%f, Imag=%f (Hex: re=%h, im=%h)", got_w3_re, got_w3_im,
                 w3.re, w3.im);
        $display("-------------------------------------------------------------");

        error_count = error_count + 1;
      end
      test_count = test_count + 1;
    end

    $display("===========================================");
    $display(" Tests Completed   : %0d", test_count);
    $display(" Errors Encountered: %0d", error_count);
    if (error_count == 0) begin
      $display(" STATUS: >>> TEST PASSED <<<");
    end else begin
      $display(" STATUS: >>> TEST FAILED <<<");
    end
    $display("===========================================");
    $finish;
  end

endmodule
