// ============================================================================
// File:        tb_r2_fft_top.sv
// Description: Fully Parameterized Self-Checking Testbench for r2_fft_top
// ============================================================================

`timescale 1ns / 1ps

import fft_pkg::*;

module tb_r2_fft_top;
  localparam int CLK_PERIOD = 10;
  localparam int N_FFT = 64;  // Scalable FFT point size
  localparam int DATA_WIDTH = fft_pkg::DATA_WIDTH;
  localparam int SINE_CYCLES = N_FFT / 4;  // k = 4 for N=16
  localparam real TWO_PI = 6.283185307179586;
  localparam int TOLERANCE = 5;

  logic   clk;
  logic   rst_n;
  logic   s_axis_tvalid;
  cmplx_t s_axis_tdata;
  logic   m_axis_tvalid;
  cmplx_t m_axis_tdata;

  // Flattened signals for waveform dump
  logic [DATA_WIDTH-1:0] s_tdata_re, s_tdata_im;
  logic [DATA_WIDTH-1:0] m_tdata_re, m_tdata_im;

  assign s_tdata_re = s_axis_tdata.re;
  assign s_tdata_im = s_axis_tdata.im;
  assign m_tdata_re = m_axis_tdata.re;
  assign m_tdata_im = m_axis_tdata.im;

  initial begin
    $dumpfile("sim/gen/vcd/current.vcd");
    $dumpvars(0, tb_r2_fft_top);
  end

  r2_fft_top #(
      .N_FFT     (N_FFT),
      .DATA_WIDTH(DATA_WIDTH)
  ) uut (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (s_axis_tvalid),
      .in_data  (s_axis_tdata),
      .out_valid(m_axis_tvalid),
      .out_data (m_axis_tdata)
  );

  initial begin
    clk = 0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  int pass_count = 0;
  int fail_count = 0;
  int sample_idx = 0;

  localparam logic signed [DATA_WIDTH-1:0] IMPULSE_MAG = 16'sd1000;
  localparam logic signed [DATA_WIDTH-1:0] DC_MAG = 16'sd100;
  localparam logic signed [DATA_WIDTH-1:0] SINE_MAG = 16'sd100;

  function automatic logic signed [DATA_WIDTH-1:0] get_sine_sample(int sample_num);
    real angle = (TWO_PI * real'(SINE_CYCLES) * real'(sample_num)) / real'(N_FFT);
    return $rtoi(real'(SINE_MAG) * $sin(angle));
  endfunction

  function automatic logic signed [DATA_WIDTH-1:0] get_cosine_sample(int sample_num);
    real angle = (TWO_PI * real'(SINE_CYCLES) * real'(sample_num)) / real'(N_FFT);
    return $rtoi(real'(SINE_MAG) * $cos(angle));
  endfunction

  // Stimulus Driver
  initial begin
    rst_n         = 1'b0;
    s_axis_tvalid = 1'b0;
    s_axis_tdata  = '0;
    #(CLK_PERIOD * 5);
    rst_n = 1'b1;
    #(CLK_PERIOD * 2);

    $display("==================================================");
    $display(" Starting Testbench for N = %0d", N_FFT);
    $display("==================================================");

    // SECTION 1: IMPULSE TEST (10 Frames)
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= (i == 0) ? IMPULSE_MAG : 16'sd0;
        s_axis_tdata.im <= 16'sd0;
      end
    end

    // SECTION 2: DC TEST (10 Frames - Continuous Stream)
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= DC_MAG;
        s_axis_tdata.im <= 16'sd0;
      end
    end

    // SECTION 3: SINE WAVE TEST (10 Frames - Continuous Stream)
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= get_sine_sample(i);
        s_axis_tdata.im <= 16'sd0;
      end
    end

    // SECTION 4: COSINE WAVE TEST (10 Frames - Continuous Stream)
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= get_cosine_sample(i);
        s_axis_tdata.im <= 16'sd0;
      end
    end

    // Flush pipeline with 3 frames of idle zeros
    for (int i = 0; i < N_FFT * 3; i++) begin
      @(posedge clk);
      s_axis_tvalid   <= 1'b1;
      s_axis_tdata.re <= '0;
      s_axis_tdata.im <= '0;
    end

    @(posedge clk);
    s_axis_tvalid <= 1'b0;
    s_axis_tdata  <= '0;

    #(CLK_PERIOD * N_FFT * 4);

    $display("--------------------------------------------------");
    $display(" Testbench Finished!");
    $display(" Total Passed Samples: %0d", pass_count);
    $display(" Total Failed Samples: %0d", fail_count);
    $display("--------------------------------------------------");

    if (fail_count == 0 && pass_count > 0) $display(">>> SUCCESS: ALL TESTS PASSED! <<<");
    else $display(">>> FAILURE: FFT TEST FAILED! <<<");

    $finish;
  end

  // ==========================================================================
  // Output Verification Monitor (Zero-Offset Direct Indexing)
  // ==========================================================================
  always @(posedge clk) begin
    if (m_axis_tvalid && (sample_idx < 40 * N_FFT)) begin
      int bin_idx;
      cmplx_t expected;
      int err_re, err_im;

      bin_idx  = sample_idx % N_FFT;
      expected = '0;

      if (sample_idx < 10 * N_FFT) begin
        // SECTION 1: Impulse Response (10 Frames: samples 0..159)
        expected.re = IMPULSE_MAG;
        expected.im = 16'sd0;

      end else if (sample_idx < 20 * N_FFT) begin
        // SECTION 2: DC Input Response (10 Frames: samples 160..319)
        if (bin_idx == 0) expected.re = DC_MAG * N_FFT;

      end else if (sample_idx < 30 * N_FFT) begin
        // SECTION 3: Sine Wave Response (10 Frames: samples 320..479)
        if (bin_idx == SINE_CYCLES) expected.im = -$rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);
        else if (bin_idx == (N_FFT - SINE_CYCLES))
          expected.im = $rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);

      end else if (sample_idx < 40 * N_FFT) begin
        // SECTION 4: Cosine Wave Response (10 Frames: samples 480..639)
        if (bin_idx == SINE_CYCLES || bin_idx == (N_FFT - SINE_CYCLES))
          expected.re = $rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);
      end

      // Compute error distance with fixed-point tolerance
      err_re = (m_axis_tdata.re > expected.re) ? (m_axis_tdata.re - expected.re) : (expected.re - m_axis_tdata.re);
      err_im = (m_axis_tdata.im > expected.im) ? (m_axis_tdata.im - expected.im) : (expected.im - m_axis_tdata.im);

      if (err_re <= TOLERANCE && err_im <= TOLERANCE) begin
        pass_count++;
      end else begin
        $error(
            "[TB ERROR] Mismatch at Sample %0d (Bin %0d)! Expected Re=%0d, Im=%0d | Got Re=%0d, Im=%0d",
            sample_idx, bin_idx, expected.re, expected.im, m_axis_tdata.re, m_axis_tdata.im);
        fail_count++;
      end

      sample_idx++;
    end
  end

endmodule
