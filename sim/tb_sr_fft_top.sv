// ============================================================================
// File:        tb_sr_fft_top.sv
// Description: Fully Parameterized Self-Checking Testbench for sr_fft_top
//              Scales dynamically to any N_FFT power of 2.
// Compatible with Icarus Verilog (iverilog -g2012)
// ============================================================================

`timescale 1ns / 1ps

module tb_sr_fft_top;

  import fft_pkg::*;

  localparam int CLK_PERIOD = 10;
  localparam int N_FFT = 64;  // Scalable FFT point size
  localparam int DATA_WIDTH = fft_pkg::DATA_WIDTH;

  // Number of sine cycles per FFT frame
  localparam int SINE_CYCLES = 4;
  localparam real TWO_PI = 6.283185307179586;

  // Testbench Control Signals
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

  // VCD Dump Section
  initial begin
    $dumpfile("sim/gen/vcd/current.vcd");
    $dumpvars(0, tb_sr_fft_top);
  end

  // Unit Under Test: Split-Radix FFT Top Module
  sr_fft_top #(
      .N_FFT(N_FFT),
      .DATA_WIDTH(DATA_WIDTH)
  ) uut (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (s_axis_tvalid),
      .in_data  (s_axis_tdata),
      .out_valid(m_axis_tvalid),
      .out_data (m_axis_tdata)
  );

  // Clock Generator
  initial begin
    clk = 0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  int pass_count = 0;
  int fail_count = 0;
  int sample_idx = 0;

  // Scaled signal amplitudes to prevent 16-bit integer overflow at large N_FFT
  localparam logic signed [DATA_WIDTH-1:0] IMPULSE_MAG = 16'sd1000;
  localparam logic signed [DATA_WIDTH-1:0] DC_MAG = 16'sd100;
  localparam logic signed [DATA_WIDTH-1:0] SINE_MAG = 16'sd100;

  // Helper Function: Compute Discrete Sine Wave Sample
  function automatic logic signed [DATA_WIDTH-1:0] get_sine_sample(int sample_num);
    real angle;
    angle = (TWO_PI * SINE_CYCLES * sample_num) / N_FFT;
    return $rtoi(SINE_MAG * $sin(angle));
  endfunction

  // Helper Function: Compute Discrete Cosine Wave Sample
  function automatic logic signed [DATA_WIDTH-1:0] get_cosine_sample(int sample_num);
    real angle;
    angle = (TWO_PI * SINE_CYCLES * sample_num) / N_FFT + (TWO_PI / 4.0);
    return $rtoi(SINE_MAG * $sin(angle));
  endfunction

  // Stimulus Driver
  initial begin
    rst_n         = 1'b0;
    s_axis_tvalid = 1'b0;
    s_axis_tdata  = '0;
    #(CLK_PERIOD * 5);
    rst_n = 1'b1;
    #(CLK_PERIOD * 2);

    // ========================================================================
    // SECTION 1: IMPULSE TEST (10 Frames)
    // ========================================================================
    $display("--------------------------------------------------");
    $display(" Starting Section 1: %0d-Point Impulse Test (10 Frames)", N_FFT);
    $display("--------------------------------------------------");
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= (i == 0) ? IMPULSE_MAG : 16'sd0;
        s_axis_tdata.im <= 16'sd0;
      end
    end

    // ========================================================================
    // SECTION 2: DC TEST (10 Frames)
    // ========================================================================
    $display("--------------------------------------------------");
    $display(" Starting Section 2: %0d-Point DC Input Test (10 Frames)", N_FFT);
    $display("--------------------------------------------------");
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= DC_MAG;
        s_axis_tdata.im <= 16'sd0;
      end
    end

    // ========================================================================
    // SECTION 3: SINE WAVE TEST (10 Frames)
    // ========================================================================
    $display("--------------------------------------------------");
    $display(" Starting Section 3: %0d-Point Sine Wave Test (10 Frames)", N_FFT);
    $display("--------------------------------------------------");
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= get_sine_sample(i);
        s_axis_tdata.im <= 16'sd0;
      end
    end

    // ========================================================================
    // SECTION 4: COSINE WAVE TEST (10 Frames)
    // ========================================================================
    $display("--------------------------------------------------");
    $display(" Starting Section 4: %0d-Point Cosine Wave Test (10 Frames)", N_FFT);
    $display("--------------------------------------------------");
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= get_cosine_sample(i);
        s_axis_tdata.im <= 16'sd0;
      end
    end

    @(posedge clk);
    s_axis_tvalid <= 1'b0;
    s_axis_tdata  <= '0;

    // Drain pipeline
    #(CLK_PERIOD * N_FFT * 3);

    $display("--------------------------------------------------");
    $display(" Testbench Finished!");
    $display(" Total Passed Samples: %0d", pass_count);
    $display(" Total Failed Samples: %0d", fail_count);
    $display("--------------------------------------------------");

    if (fail_count == 0 && pass_count > 0) begin
      $display(">>> SUCCESS: ALL TESTS PASSED! <<<");
    end else begin
      $display(">>> FAILURE: SPLIT-RADIX FFT TEST FAILED! <<<");
    end

    $finish;
  end

  // ==========================================================================
  // Dynamic Output Verification Monitor
  // ==========================================================================
  always @(posedge clk) begin
    if (m_axis_tvalid) begin
      int bin_idx;
      cmplx_t expected;

      bin_idx  = sample_idx % N_FFT;
      expected = '0;

      // ----------------------------------------------------------------------
      // Parameterized Expected Value Calculations
      // ----------------------------------------------------------------------
      if (sample_idx < 10 * N_FFT) begin
        // SECTION 1: Impulse Response (Flat output across all bins)
        expected.re = IMPULSE_MAG;
        expected.im = 16'sd0;

      end else if (sample_idx < 20 * N_FFT) begin
        // SECTION 2: DC Input Response (Energy concentrated in Bin 0)
        if (bin_idx == 0) begin
          expected.re = DC_MAG * N_FFT;
          expected.im = 16'sd0;
        end else begin
          expected.re = 16'sd0;
          expected.im = 16'sd0;
        end

      end else if (sample_idx < 30 * N_FFT) begin
        // SECTION 3: Parameterized Sine Wave Response
        if (bin_idx == SINE_CYCLES) begin
          expected.re = 16'sd0;
          expected.im = -$rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);
        end else if (bin_idx == (N_FFT - SINE_CYCLES)) begin
          expected.re = 16'sd0;
          expected.im = $rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);
        end else begin
          expected.re = 16'sd0;
          expected.im = 16'sd0;
        end

      end else if (sample_idx < 40 * N_FFT) begin
        // SECTION 4: Parameterized Cosine Wave Response
        if (bin_idx == SINE_CYCLES || bin_idx == (N_FFT - SINE_CYCLES)) begin
          expected.re = $rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);
          expected.im = 16'sd0;
        end else begin
          expected.re = 16'sd0;
          expected.im = 16'sd0;
        end
      end

      // ----------------------------------------------------------------------
      // Assertion Check
      // ----------------------------------------------------------------------
      if (m_axis_tdata.re == expected.re && m_axis_tdata.im == expected.im) begin
        pass_count++;
      end else begin
        $error(
            "[TB ERROR] Mismatch at Sample %0d (Bin %0d)! Expected Re=%0d, Im=%0d. Got Re=%0d, Im=%0d",
            sample_idx, bin_idx, expected.re, expected.im, m_axis_tdata.re, m_axis_tdata.im);
        fail_count++;
      end

      $display("[TB Output] Sample %0d | Bin %0d | Re: %0d, Im: %0d", sample_idx, bin_idx,
               m_axis_tdata.re, m_axis_tdata.im);

      sample_idx++;
    end
  end

endmodule
