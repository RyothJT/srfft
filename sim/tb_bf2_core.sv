// ============================================================================
// File:        tb_bf2_core.sv
// Description: Self-checking unit testbench for bf2_core.sv
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module tb_bf2_core;

  localparam int WIDTH = DATA_WIDTH;
  localparam int FRAC_BITS = FRAC_BITS;
  localparam int CLK_PER = 10;
  localparam real SCALE_VAL = 32768.0;
  localparam int FIFO_DEPTH = 64;

  logic clk, rst_n;
  logic valid_in, valid_out;
  cmplx_t a, b, w;
  cmplx_t y0, y1;

  // Instantiate DUT (Standard stage with Twiddle enabled)
  bf2_core #(
      .WIDTH      (WIDTH),
      .FRAC_BITS  (FRAC_BITS),
      .SCALE      (1'b0),
      .SATURATE   (1'b1),
      .HAS_TWIDDLE(1'b1)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (valid_in),
      .valid_out(valid_out),
      .a        (a),
      .b        (b),
      .w        (w),
      .y0       (y0),
      .y1       (y1)
  );

  // Safe fallback for Verible / linters
`ifndef DUMP_FILE
  `define DUMP_FILE ""
`endif

  initial begin
    if (`DUMP_FILE != "") begin
      $dumpfile(`DUMP_FILE);
      $dumpvars(0, tb_bf2_core);
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

  // Task to drive stimulus and calculate bit-accurate expected outputs
  task automatic drive_sample(input real ar, input real ai, input real br, input real bi,
                              input real wr, input real wi);
    real ar_q, ai_q, br_q, bi_q, wr_q, wi_q;
    real d_r, d_i;
    begin
      // Quantize inputs to exact Q1.15 grid to test true math accuracy
      ar_q = $itor($rtoi(ar * SCALE_VAL)) / SCALE_VAL;
      ai_q = $itor($rtoi(ai * SCALE_VAL)) / SCALE_VAL;
      br_q = $itor($rtoi(br * SCALE_VAL)) / SCALE_VAL;
      bi_q = $itor($rtoi(bi * SCALE_VAL)) / SCALE_VAL;
      wr_q = $itor($rtoi(wr * SCALE_VAL)) / SCALE_VAL;
      wi_q = $itor($rtoi(wi * SCALE_VAL)) / SCALE_VAL;

      @(posedge clk);
      valid_in <= 1'b1;

      a.re <= $rtoi(ar_q * SCALE_VAL);
      a.im <= $rtoi(ai_q * SCALE_VAL);
      b.re <= $rtoi(br_q * SCALE_VAL);
      b.im <= $rtoi(bi_q * SCALE_VAL);
      w.re <= $rtoi(wr_q * SCALE_VAL);
      w.im <= $rtoi(wi_q * SCALE_VAL);

      // y0 = a + b
      exp_y0_re[wr_ptr] = clamp_r(ar_q + br_q);
      exp_y0_im[wr_ptr] = clamp_r(ai_q + bi_q);

      // y1 = (a - b) * w
      d_r = clamp_r(ar_q - br_q);
      d_i = clamp_r(ai_q - bi_q);
      exp_y1_re[wr_ptr] = clamp_r((d_r * wr_q) - (d_i * wi_q));
      exp_y1_im[wr_ptr] = clamp_r((d_r * wi_q) + (d_i * wr_q));

      wr_ptr = (wr_ptr + 1) % FIFO_DEPTH;
      fifo_count = fifo_count + 1;
    end
  endtask

  // Output Checker Process
  initial begin
    real y0_r, y0_i, y1_r, y1_i;
    real e0_r, e0_i, e1_r, e1_i;
    real err0_re, err0_im, err1_re, err1_im;

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

          rd_ptr = (rd_ptr + 1) % FIFO_DEPTH;
          fifo_count = fifo_count - 1;

          y0_r = to_real(y0.re);
          y0_i = to_real(y0.im);
          y1_r = to_real(y1.re);
          y1_i = to_real(y1.im);

          err0_re = (y0_r > e0_r ? y0_r - e0_r : e0_r - y0_r) * SCALE_VAL;
          err0_im = (y0_i > e0_i ? y0_i - e0_i : e0_i - y0_i) * SCALE_VAL;
          err1_re = (y1_r > e1_r ? y1_r - e1_r : e1_r - y1_r) * SCALE_VAL;
          err1_im = (y1_i > e1_i ? y1_i - e1_i : e1_i - y1_i) * SCALE_VAL;

          // y0 is exact addition (0 LSB error); y1 has <= 1.0 LSB multiplier rounding error
          if (err0_re > 0.01 || err0_im > 0.01 || err1_re > 1.2 || err1_im > 1.2) begin
            $display({"[MISMATCH] Sample %0d at time %0t:\n",
                      "  y0: Exp=(%f, %f) Got=(%f, %f) | Err=(%.2f, %.2f) LSBs\n",
                      "  y1: Exp=(%f, %f) Got=(%f, %f) | Err=(%.2f, %.2f) LSBs"}, test_count,
                       $time, e0_r, e0_i, y0_r, y0_i, err0_re, err0_im, e1_r, e1_i, y1_r, y1_i,
                       err1_re, err1_im);
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
    a = '0;
    b = '0;
    w = '0;
    rst_n = 1'b0;

    #(CLK_PER * 5);
    rst_n = 1'b1;
    #(CLK_PER * 2);

    $display("--- Starting Directed Tests ---");
    // Test 1: Identity rotation (w = 1.0)
    drive_sample(0.25, 0.1, 0.15, -0.05, 0.9999, 0.0);
    // Test 2: -j rotation
    drive_sample(0.3, -0.2, -0.1, 0.4, 0.0, -0.9999);
    // Test 3: 45 degree rotation
    drive_sample(0.5, 0.0, 0.0, 0.5, 0.7071, -0.7071);

    @(posedge clk);
    valid_in <= 1'b0;
    #(CLK_PER * 5);

    $display("--- Starting Random Stress Tests (1000 vectors) ---");
    for (i = 0; i < 1000; i = i + 1) begin
      real ar, ai, br, bi, wr, wi;
      ar = $itor($urandom_range(0, 32767) - 16384) / 32768.0;
      ai = $itor($urandom_range(0, 32767) - 16384) / 32768.0;
      br = $itor($urandom_range(0, 32767) - 16384) / 32768.0;
      bi = $itor($urandom_range(0, 32767) - 16384) / 32768.0;
      wr = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      wi = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      drive_sample(ar, ai, br, bi, wr, wi);
    end

    @(posedge clk);
    valid_in <= 1'b0;

    wait (fifo_count == 0);
    #(CLK_PER * 5);

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
