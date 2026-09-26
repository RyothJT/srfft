// ============================================================================
// File:        tb_bf4_core.sv
// Description: Self-checking unit testbench for bf4_core.sv
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module tb_bf4_core;

  localparam int WIDTH = DATA_WIDTH;
  localparam int FRAC_BITS = FRAC_BITS;
  localparam int CLK_PER = 10;
  localparam real SCALE_VAL = 32768.0;
  localparam int FIFO_DEPTH = 64;

  logic clk, rst_n;
  logic valid_in, valid_out;
  cmplx_t x0, x1, x2, x3;
  cmplx_t w1, w2, w3;
  cmplx_t y0, y1, y2, y3;

  // Instantiate DUT (Unscaled mode)
  bf4_core #(
      .WIDTH    (WIDTH),
      .FRAC_BITS(FRAC_BITS),
      .SCALE    (1'b0),
      .SATURATE (1'b1)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (valid_in),
      .valid_out(valid_out),
      .x0       (x0),
      .x1       (x1),
      .x2       (x2),
      .x3       (x3),
      .w1       (w1),
      .w2       (w2),
      .w3       (w3),
      .y0       (y0),
      .y1       (y1),
      .y2       (y2),
      .y3       (y3)
  );

  // Safe fallback for Verible / linters
`ifndef DUMP_FILE
  `define DUMP_FILE ""
`endif

  initial begin
    if (`DUMP_FILE != "") begin
      $dumpfile(`DUMP_FILE);
      $dumpvars(0, tb_bf4_core);
    end
  end

  // Clock generator
  initial begin
    clk = 0;
    forever #(CLK_PER / 2) clk = ~clk;
  end

  // Circular FIFO for expected outputs
  real exp_y0_re[0:FIFO_DEPTH-1], exp_y0_im[0:FIFO_DEPTH-1];
  real exp_y1_re[0:FIFO_DEPTH-1], exp_y1_im[0:FIFO_DEPTH-1];
  real exp_y2_re[0:FIFO_DEPTH-1], exp_y2_im[0:FIFO_DEPTH-1];
  real exp_y3_re[0:FIFO_DEPTH-1], exp_y3_im[0:FIFO_DEPTH-1];

  int wr_ptr = 0;
  int rd_ptr = 0;
  int fifo_count = 0;
  int error_count = 0;
  int test_count = 0;

  function automatic real to_real(input logic signed [WIDTH-1:0] val);
    return $itor(val) / SCALE_VAL;
  endfunction

  function automatic real clamp_r(input real val);
    if (val > (32767.0 / SCALE_VAL)) return (32767.0 / SCALE_VAL);
    if (val < -1.0) return -1.0;
    return val;
  endfunction

  // Task to drive stimulus and calculate expected outputs
  task automatic drive_sample(input real rx0, input real ix0, input real rx1, input real ix1,
                              input real rx2, input real ix2, input real rx3, input real ix3,
                              input real rw1, input real iw1, input real rw2, input real iw2,
                              input real rw3, input real iw3);
    real x0r_q, x0i_q, x1r_q, x1i_q, x2r_q, x2i_q, x3r_q, x3i_q;
    real w1r_q, w1i_q, w2r_q, w2i_q, w3r_q, w3i_q;
    real a_r, a_i, b_r, b_i, c_r, c_i, d_r, d_i;
    real z0_r, z0_i, z2_r, z2_i;
    real t1_r, t1_i, t3_r, t3_i;
    begin
      // Quantize inputs to exact Q1.15 grid
      x0r_q = $itor($rtoi(rx0 * SCALE_VAL)) / SCALE_VAL;
      x0i_q = $itor($rtoi(ix0 * SCALE_VAL)) / SCALE_VAL;
      x1r_q = $itor($rtoi(rx1 * SCALE_VAL)) / SCALE_VAL;
      x1i_q = $itor($rtoi(ix1 * SCALE_VAL)) / SCALE_VAL;
      x2r_q = $itor($rtoi(rx2 * SCALE_VAL)) / SCALE_VAL;
      x2i_q = $itor($rtoi(ix2 * SCALE_VAL)) / SCALE_VAL;
      x3r_q = $itor($rtoi(rx3 * SCALE_VAL)) / SCALE_VAL;
      x3i_q = $itor($rtoi(ix3 * SCALE_VAL)) / SCALE_VAL;

      w1r_q = $itor($rtoi(rw1 * SCALE_VAL)) / SCALE_VAL;
      w1i_q = $itor($rtoi(iw1 * SCALE_VAL)) / SCALE_VAL;
      w2r_q = $itor($rtoi(rw2 * SCALE_VAL)) / SCALE_VAL;
      w2i_q = $itor($rtoi(iw2 * SCALE_VAL)) / SCALE_VAL;
      w3r_q = $itor($rtoi(rw3 * SCALE_VAL)) / SCALE_VAL;
      w3i_q = $itor($rtoi(iw3 * SCALE_VAL)) / SCALE_VAL;

      @(posedge clk);
      valid_in <= 1'b1;

      x0.re <= $rtoi(x0r_q * SCALE_VAL);
      x0.im <= $rtoi(x0i_q * SCALE_VAL);
      x1.re <= $rtoi(x1r_q * SCALE_VAL);
      x1.im <= $rtoi(x1i_q * SCALE_VAL);
      x2.re <= $rtoi(x2r_q * SCALE_VAL);
      x2.im <= $rtoi(x2i_q * SCALE_VAL);
      x3.re <= $rtoi(x3r_q * SCALE_VAL);
      x3.im <= $rtoi(x3i_q * SCALE_VAL);

      w1.re <= $rtoi(w1r_q * SCALE_VAL);
      w1.im <= $rtoi(w1i_q * SCALE_VAL);
      w2.re <= $rtoi(w2r_q * SCALE_VAL);
      w2.im <= $rtoi(w2i_q * SCALE_VAL);
      w3.re <= $rtoi(w3r_q * SCALE_VAL);
      w3.im <= $rtoi(w3i_q * SCALE_VAL);

      // Stage 1
      a_r = clamp_r(x0r_q + x2r_q);
      a_i = clamp_r(x0i_q + x2i_q);
      b_r = clamp_r(x0r_q - x2r_q);
      b_i = clamp_r(x0i_q - x2i_q);
      c_r = clamp_r(x1r_q + x3r_q);
      c_i = clamp_r(x1i_q + x3i_q);
      d_r = clamp_r(x1r_q - x3r_q);
      d_i = clamp_r(x1i_q - x3i_q);

      // Stage 2
      z0_r = clamp_r(a_r + c_r);
      z0_i = clamp_r(a_i + c_i);
      z2_r = clamp_r(a_r - c_r);
      z2_i = clamp_r(a_i - c_i);
      t1_r = clamp_r(b_r + d_i);
      t1_i = clamp_r(b_i - d_r);
      t3_r = clamp_r(b_r - d_i);
      t3_i = clamp_r(b_i + d_r);

      // Stage 3
      exp_y0_re[wr_ptr] = z0_r;
      exp_y0_im[wr_ptr] = z0_i;

      exp_y1_re[wr_ptr] = clamp_r((t1_r * w1r_q) - (t1_i * w1i_q));
      exp_y1_im[wr_ptr] = clamp_r((t1_r * w1i_q) + (t1_i * w1r_q));

      exp_y2_re[wr_ptr] = clamp_r((z2_r * w2r_q) - (z2_i * w2i_q));
      exp_y2_im[wr_ptr] = clamp_r((z2_r * w2i_q) + (z2_i * w2r_q));

      exp_y3_re[wr_ptr] = clamp_r((t3_r * w3r_q) - (t3_i * w3i_q));
      exp_y3_im[wr_ptr] = clamp_r((t3_r * w3i_q) + (t3_i * w3r_q));

      wr_ptr = (wr_ptr + 1) % FIFO_DEPTH;
      fifo_count = fifo_count + 1;
    end
  endtask

  // Output Checker Process
  initial begin
    real y0_r, y0_i, y1_r, y1_i, y2_r, y2_i, y3_r, y3_i;
    real e0_r, e0_i, e1_r, e1_i, e2_r, e2_i, e3_r, e3_i;
    real err0_re, err0_im, err1_re, err1_im;
    real err2_re, err2_im, err3_re, err3_im;

    forever
    @(posedge clk) begin
      if (rst_n && valid_out) begin
        if (fifo_count == 0) begin
          $display("[TB ERROR] Unexpected valid_out!");
          error_count = error_count + 1;
        end else begin
          e0_r = exp_y0_re[rd_ptr];
          e0_i = exp_y0_im[rd_ptr];
          e1_r = exp_y1_re[rd_ptr];
          e1_i = exp_y1_im[rd_ptr];
          e2_r = exp_y2_re[rd_ptr];
          e2_i = exp_y2_im[rd_ptr];
          e3_r = exp_y3_re[rd_ptr];
          e3_i = exp_y3_im[rd_ptr];

          rd_ptr = (rd_ptr + 1) % FIFO_DEPTH;
          fifo_count = fifo_count - 1;

          y0_r = to_real(y0.re);
          y0_i = to_real(y0.im);
          y1_r = to_real(y1.re);
          y1_i = to_real(y1.im);
          y2_r = to_real(y2.re);
          y2_i = to_real(y2.im);
          y3_r = to_real(y3.re);
          y3_i = to_real(y3.im);

          err0_re = (y0_r > e0_r ? y0_r - e0_r : e0_r - y0_r) * SCALE_VAL;
          err0_im = (y0_i > e0_i ? y0_i - e0_i : e0_i - y0_i) * SCALE_VAL;
          err1_re = (y1_r > e1_r ? y1_r - e1_r : e1_r - y1_r) * SCALE_VAL;
          err1_im = (y1_i > e1_i ? y1_i - e1_i : e1_i - y1_i) * SCALE_VAL;
          err2_re = (y2_r > e2_r ? y2_r - e2_r : e2_r - y2_r) * SCALE_VAL;
          err2_im = (y2_i > e2_i ? y2_i - e2_i : e2_i - y2_i) * SCALE_VAL;
          err3_re = (y3_r > e3_r ? y3_r - e3_r : e3_r - y3_r) * SCALE_VAL;
          err3_im = (y3_i > e3_i ? y3_i - e3_i : e3_i - y3_i) * SCALE_VAL;

          // Threshold: y0 is exact (0.01); others have <= 1.2 LSB multiplier rounding
          if (err0_re > 0.01 || err0_im > 0.01 ||
                        err1_re > 1.2  || err1_im > 1.2  ||
                        err2_re > 1.2  || err2_im > 1.2  ||
                        err3_re > 1.2  || err3_im > 1.2) begin
            $display({"[MISMATCH] Sample %0d at time %0t:\n",
                      "  y0: Exp=(%f, %f) Got=(%f, %f) | Err=(%.2f, %.2f) LSBs\n",
                      "  y1: Exp=(%f, %f) Got=(%f, %f) | Err=(%.2f, %.2f) LSBs\n",
                      "  y2: Exp=(%f, %f) Got=(%f, %f) | Err=(%.2f, %.2f) LSBs\n",
                      "  y3: Exp=(%f, %f) Got=(%f, %f) | Err=(%.2f, %.2f) LSBs"}, test_count,
                       $time, e0_r, e0_i, y0_r, y0_i, err0_re, err0_im, e1_r, e1_i, y1_r, y1_i,
                       err1_re, err1_im, e2_r, e2_i, y2_r, y2_i, err2_re, err2_im, e3_r, e3_i,
                       y3_r, y3_i, err3_re, err3_im);
            error_count = error_count + 1;
          end
          test_count = test_count + 1;
        end
      end
    end
  end

  // Stimulus Generation
  int i;
  initial begin
    valid_in = 1'b0;
    x0 = '0;
    x1 = '0;
    x2 = '0;
    x3 = '0;
    w1 = '0;
    w2 = '0;
    w3 = '0;
    rst_n = 1'b0;

    #(CLK_PER * 5);
    rst_n = 1'b1;
    #(CLK_PER * 2);

    $display("--- Starting Directed Tests ---");
    // Test 1: Identity rotation (all twiddles = 1.0)
    drive_sample(0.2, 0.0, 0.2, 0.0, 0.2, 0.0, 0.2, 0.0, 0.9999, 0.0, 0.9999, 0.0, 0.9999, 0.0);

    // Test 2: Orthogonal rotations
    drive_sample(0.3, -0.1, 0.1, 0.2, -0.2, 0.0, 0.0, -0.3, 0.7071, -0.7071, 0.0, -0.9999, -0.7071,
                 -0.7071);

    @(posedge clk);
    valid_in <= 1'b0;
    #(CLK_PER * 6);

    $display("--- Starting Random Stress Tests (1000 vectors) ---");
    for (i = 0; i < 1000; i = i + 1) begin
      real rx0, ix0, rx1, ix1, rx2, ix2, rx3, ix3;
      real rw1, iw1, rw2, iw2, rw3, iw3;
      rx0 = $itor($urandom_range(0, 16383) - 8192) / 32768.0;
      ix0 = $itor($urandom_range(0, 16383) - 8192) / 32768.0;
      rx1 = $itor($urandom_range(0, 16383) - 8192) / 32768.0;
      ix1 = $itor($urandom_range(0, 16383) - 8192) / 32768.0;
      rx2 = $itor($urandom_range(0, 16383) - 8192) / 32768.0;
      ix2 = $itor($urandom_range(0, 16383) - 8192) / 32768.0;
      rx3 = $itor($urandom_range(0, 16383) - 8192) / 32768.0;
      ix3 = $itor($urandom_range(0, 16383) - 8192) / 32768.0;

      rw1 = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      iw1 = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      rw2 = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      iw2 = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      rw3 = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      iw3 = $itor($urandom_range(0, 65535) - 32768) / 32768.0;

      drive_sample(rx0, ix0, rx1, ix1, rx2, ix2, rx3, ix3, rw1, iw1, rw2, iw2, rw3, iw3);
    end

    @(posedge clk);
    valid_in <= 1'b0;

    wait (fifo_count == 0);
    #(CLK_PER * 6);

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
