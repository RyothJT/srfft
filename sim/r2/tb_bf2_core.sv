// ============================================================================
// File:        tb_bf2_core.sv
// Description: Self-checking testbench for Radix-2 SDF Butterfly Core (bf2_core)
//              Designed for Icarus Verilog compatibility and simple waveform debugging.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module tb_bf2_core;

  localparam int N_FFT = 32;
  localparam int STAGE = 0;
  localparam int DATA_WIDTH = fft_pkg::DATA_WIDTH;
  localparam int CLK_PER = 10;
  localparam real SCALE_VAL = 32768.0;
  localparam int FIFO_DEPTH = 128;
  localparam int HALF_DELAY = N_FFT >> (STAGE + 1);

  logic   clk;
  logic   rst_n;

  // DUT Interface Signals
  logic   in_valid;
  cmplx_t in_data;
  logic   out_valid;
  cmplx_t out_data;

  // Instantiate DUT
  bf2_core #(
      .N_FFT(N_FFT),
      .STAGE(STAGE),
      .DATA_WIDTH(DATA_WIDTH)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (in_valid),
      .in_data  (in_data),
      .out_valid(out_valid),
      .out_data (out_data)
  );

  // VCD Waveform Dumping
`ifndef DUMP_FILE
  `define DUMP_FILE "tb_bf2_core.vcd"
`endif

  initial begin
    if (`DUMP_FILE != "") begin
      $dumpfile(`DUMP_FILE);
      $dumpvars(0, tb_bf2_core);
    end
  end

  // Clock Generator
  initial begin
    clk = 0;
    forever #(CLK_PER / 2) clk = ~clk;
  end

  // Storage for expected outputs (flat arrays for Icarus compatibility)
  logic signed [DATA_WIDTH-1:0] exp_re[0:FIFO_DEPTH-1];
  logic signed [DATA_WIDTH-1:0] exp_im[0:FIFO_DEPTH-1];

  int wr_ptr = 0;
  int rd_ptr = 0;
  int fifo_count = 0;
  int error_count = 0;
  int test_count = 0;

  // Frame buffer to store stimulus for reference calculation
  real f_re[0:N_FFT-1];
  real f_im[0:N_FFT-1];

  // Helper conversion functions
  function automatic real to_real(input logic signed [DATA_WIDTH-1:0] val);
    return $itor(val) / SCALE_VAL;
  endfunction

  function automatic real clamp_r(input real val);
    if (val > (32767.0 / SCALE_VAL)) return (32767.0 / SCALE_VAL);
    if (val < -1.0) return -1.0;
    return val;
  endfunction

  // Drive a single sample into DUT
  task automatic send_sample(input real re_val, input real im_val);
    real re_q, im_q;
    begin
      re_q = $itor($rtoi(re_val * SCALE_VAL)) / SCALE_VAL;
      im_q = $itor($rtoi(im_val * SCALE_VAL)) / SCALE_VAL;

      @(posedge clk);
      in_valid   <= 1'b1;
      in_data.re <= $rtoi(re_q * SCALE_VAL);
      in_data.im <= $rtoi(im_q * SCALE_VAL);
    end
  endtask

  // Push an expected response sample into checking queue
  task automatic push_expected(input real re_val, input real im_val);
    real re_q, im_q;
    begin
      re_q = $itor($rtoi(re_val * SCALE_VAL)) / SCALE_VAL;
      im_q = $itor($rtoi(im_val * SCALE_VAL)) / SCALE_VAL;

      exp_re[wr_ptr] = $rtoi(clamp_r(re_q) * SCALE_VAL);
      exp_im[wr_ptr] = $rtoi(clamp_r(im_q) * SCALE_VAL);

      wr_ptr = (wr_ptr + 1) % FIFO_DEPTH;
      fifo_count = fifo_count + 1;
    end
  endtask

  // Compute reference results directly from module-level f_re and f_im buffers
  task automatic process_frame_reference;
    int i, k;
    real TWO_PI = 6.283185307179586;
    real diff_r, diff_i;
    real twid_r, twid_i;
    real rot_r, rot_i;
    real angle;

    // 1. First HALF_DELAY outputs: Rotated differences (A - B) * W
    for (i = 0; i < HALF_DELAY; i = i + 1) begin
      k = (i & (HALF_DELAY - 1)) * (1 << STAGE);
      angle = -TWO_PI * real'(k) / real'(N_FFT);
      twid_r = $cos(angle);
      twid_i = $sin(angle);

      diff_r = clamp_r(f_re[i] - f_re[i+HALF_DELAY]);
      diff_i = clamp_r(f_im[i] - f_im[i+HALF_DELAY]);

      rot_r = (diff_r * twid_r) - (diff_i * twid_i);
      rot_i = (diff_r * twid_i) + (diff_i * twid_r);

      push_expected(rot_r, rot_i);
    end

    // 2. Second HALF_DELAY outputs: Sums (A + B)
    for (i = 0; i < HALF_DELAY; i = i + 1) begin
      push_expected(f_re[i] + f_re[i+HALF_DELAY], f_im[i] + f_im[i+HALF_DELAY]);
    end
  endtask

  // Self-Checking Output Monitor
  initial begin
    logic signed [DATA_WIDTH-1:0] exp_r, exp_i;
    int err_r, err_i;

    forever
    @(posedge clk) begin
      if (rst_n && out_valid) begin
        if (fifo_count == 0) begin
          $display("[TB FAIL] [%0t ns] Unexpected out_valid high!", $time);
          error_count = error_count + 1;
        end else begin
          exp_r = exp_re[rd_ptr];
          exp_i = exp_im[rd_ptr];

          rd_ptr = (rd_ptr + 1) % FIFO_DEPTH;
          fifo_count = fifo_count - 1;

          err_r = out_data.re - exp_r;
          err_i = out_data.im - exp_i;
          if (err_r < 0) err_r = -err_r;
          if (err_i < 0) err_i = -err_i;

          // Multiplier fixed-point rounding tolerance <= 2 LSBs
          if (err_r > 2 || err_i > 2) begin
            $display("[MISMATCH] Sample %0d at %0t ns:", test_count, $time);
            $display("  Expected: Re=%0d (%.4f), Im=%0d (%.4f)", exp_r, to_real(exp_r), exp_i,
                     to_real(exp_i));
            $display("  Got     : Re=%0d (%.4f), Im=%0d (%.4f)", out_data.re, to_real(out_data.re),
                     out_data.im, to_real(out_data.im));
            $display("  Error   : ReErr=%0d LSBs, ImErr=%0d LSBs", err_r, err_i);
            error_count = error_count + 1;
          end

          test_count = test_count + 1;
        end
      end
    end
  end

  // Waveform-friendly stimulus generation
  int idx;

  initial begin
    in_valid = 1'b0;
    in_data  = '0;
    rst_n    = 1'b0;

    $display("\n==================================================");
    $display("   STARTING BF2_CORE (RADIX-2 SDF) UNIT TESTBENCH");
    $display("==================================================");

    #(CLK_PER * 5);
    rst_n = 1'b1;
    #(CLK_PER * 2);

    // ------------------------------------------------------------------------
    // TEST 1: DC Constant Input (Flatlines on waveform)
    // ------------------------------------------------------------------------
    $display("[TEST 1] Streaming DC Constant Frame (0.5 + 0.0j)...");
    for (idx = 0; idx < N_FFT; idx = idx + 1) begin
      f_re[idx] = 0.5;
      f_im[idx] = 0.0;
    end

    process_frame_reference();

    for (idx = 0; idx < N_FFT; idx = idx + 1) begin
      send_sample(f_re[idx], f_im[idx]);
    end
    @(posedge clk);
    in_valid <= 1'b0;

    #(CLK_PER * 10);

    // ------------------------------------------------------------------------
    // TEST 2: Impulse Test (0.75 at Index 0, 0 everywhere else)
    // ------------------------------------------------------------------------
    $display("[TEST 2] Streaming Impulse Frame (0.75 + 0.0j at Index 0)...");
    for (idx = 0; idx < N_FFT; idx = idx + 1) begin
      f_re[idx] = (idx == 0) ? 0.75 : 0.0;
      f_im[idx] = 0.0;
    end

    process_frame_reference();

    for (idx = 0; idx < N_FFT; idx = idx + 1) begin
      send_sample(f_re[idx], f_im[idx]);
    end
    @(posedge clk);
    in_valid <= 1'b0;

    // ------------------------------------------------------------------------
    // TEST 3: Alternating DC Steps (Easy visual edge detection)
    // ------------------------------------------------------------------------
    $display("[TEST 3] Streaming Step Frame (0.25 for first half, -0.25 for second)...");
    for (idx = 0; idx < N_FFT; idx = idx + 1) begin
      f_re[idx] = (idx < HALF_DELAY) ? 0.25 : -0.25;
      f_im[idx] = 0.0;
    end

    process_frame_reference();

    for (idx = 0; idx < N_FFT; idx = idx + 1) begin
      send_sample(f_re[idx], f_im[idx]);
    end
    @(posedge clk);
    in_valid <= 1'b0;

    // ------------------------------------------------------------------------
    // Wait for all queued outputs to be verified
    // ------------------------------------------------------------------------
    wait (fifo_count == 0);
    #(CLK_PER * 10);

    $display("\n==================================================");
    $display(" TEST RESULTS SUMMARY");
    $display("   Total Samples Checked : %0d", test_count);
    $display("   Total Errors Found    : %0d", error_count);
    if (error_count == 0 && test_count > 0) begin
      $display("   STATUS: >>> TEST PASSED <<<");
    end else begin
      $display("   STATUS: >>> TEST FAILED <<<");
    end
    $display("==================================================\n");

    $finish;
  end

endmodule
