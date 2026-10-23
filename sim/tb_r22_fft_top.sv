// ============================================================================
// File:        tb_r22_fft_top.sv
// Description: Self-Checking Testbench for r22_fft_top (Icarus Verilog Compatible)
//              Supports N_FFT up to 1024, testing:
//              1. Impulse Response
//              2. DC Response
//              3. Sine Wave Response
//              4. Cosine Wave Response
//              5. Random Complex Vectors (Direct Mathematical Golden DFT Key)
// ============================================================================

`timescale 1ns / 1ps

module tb_r22_fft_top;

  import fft_pkg::*;

  localparam int CLK_PERIOD          = 10;
  localparam int N_FFT               = 16;  // Scalable: 16, 64, 256, 1024
  localparam int DATA_WIDTH          = fft_pkg::DATA_WIDTH;
  localparam int SINE_CYCLES         = N_FFT / 16;  // k = 1
  localparam real TWO_PI             = 6.283185307179586;
  localparam int USE_REORDER_BUFFER  = fft_pkg::USE_REORDER_BUFFER;

  // Acceptable fixed-point quantization tolerance (in LSB counts)
  localparam int TOLERANCE           = 6;

  // Scaled amplitudes to prevent 16-bit integer overflow at large N_FFT
  localparam logic signed [DATA_WIDTH-1:0] IMPULSE_MAG = 16'sd1000;
  localparam logic signed [DATA_WIDTH-1:0] DC_MAG      = 16'sd100;
  localparam logic signed [DATA_WIDTH-1:0] SINE_MAG    = 16'sd100;

  // Dynamically scale random stimulus to avoid accumulator overflow
  localparam int RAND_MAG = (N_FFT <= 16) ? 60 : ((N_FFT <= 64) ? 30 : ((N_FFT <= 256) ? 15 : 8));

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
    $dumpvars(0, tb_r22_fft_top);
  end

  r22_fft_top #(
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

  // ==========================================================================
  // Helper Functions & Golden DFT Reference Model
  // ==========================================================================
  function automatic int bit_reverse(int val, int bits);
    int res = 0;
    for (int b = 0; b < bits; b++) begin
      res = (res << 1) | ((val >> b) & 1);
    end
    return res;
  endfunction

  function automatic logic signed [DATA_WIDTH-1:0] get_sine_sample(int n);
    real angle = (TWO_PI * real'(SINE_CYCLES) * real'(n)) / real'(N_FFT);
    return $rtoi(real'(SINE_MAG) * $sin(angle));
  endfunction

  function automatic logic signed [DATA_WIDTH-1:0] get_cosine_sample(int n);
    real angle = (TWO_PI * real'(SINE_CYCLES) * real'(n)) / real'(N_FFT);
    return $rtoi(real'(SINE_MAG) * $cos(angle));
  endfunction

  // Primitive 2D arrays to avoid iverilog multi-dimensional struct indexing bug
  logic signed [DATA_WIDTH-1:0] rand_inputs_re   [0:9][0:N_FFT-1];
  logic signed [DATA_WIDTH-1:0] rand_inputs_im   [0:9][0:N_FFT-1];
  logic signed [DATA_WIDTH-1:0] rand_expected_re [0:9][0:N_FFT-1];
  logic signed [DATA_WIDTH-1:0] rand_expected_im [0:9][0:N_FFT-1];

  // Direct double-precision mathematical DFT task
  task automatic compute_golden_dft(input int f_idx);
    for (int k = 0; k < N_FFT; k++) begin
      real sum_re = 0.0;
      real sum_im = 0.0;
      for (int n = 0; n < N_FFT; n++) begin
        real angle = (TWO_PI * real'(k) * real'(n)) / real'(N_FFT);
        real cos_val = $cos(angle);
        real sin_val = $sin(angle);
        real x_re = real'($signed(rand_inputs_re[f_idx][n]));
        real x_im = real'($signed(rand_inputs_im[f_idx][n]));

        // (x_re + j*x_im) * (cos - j*sin) = (x_re*cos + x_im*sin) + j*(-x_re*sin + x_im*cos)
        sum_re += (x_re * cos_val + x_im * sin_val);
        sum_im += (-x_re * sin_val + x_im * cos_val);
      end
      rand_expected_re[f_idx][k] = $rtoi(sum_re);
      rand_expected_im[f_idx][k] = $rtoi(sum_im);
    end
  endtask

  // ==========================================================================
  // Stimulus Driver
  // ==========================================================================
  initial begin
    int r_re;
    int r_im;

    rst_n         = 1'b0;
    s_axis_tvalid = 1'b0;
    s_axis_tdata  = '0;

    // Generate 10 unique random complex frames and pre-compute their golden keys
    for (int f = 0; f < 10; f++) begin
      for (int i = 0; i < N_FFT; i++) begin
        r_re = ($random % (2 * RAND_MAG + 1)) - RAND_MAG;
        r_im = ($random % (2 * RAND_MAG + 1)) - RAND_MAG;
        rand_inputs_re[f][i] = r_re[DATA_WIDTH-1:0];
        rand_inputs_im[f][i] = r_im[DATA_WIDTH-1:0];
      end
      compute_golden_dft(f);
    end

    #(CLK_PERIOD * 5);
    rst_n = 1'b1;
    #(CLK_PERIOD * 2);

    $display("==================================================");
    $display(" Testing R22SDF FFT: N = %0d", N_FFT);
    $display("==================================================");

    // Section 1: Impulse Test (10 Frames)
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= (i == 0) ? IMPULSE_MAG : 16'sd0;
        s_axis_tdata.im <= 16'sd0;
      end
    end

    // Section 2: DC Test (10 Frames)
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= DC_MAG;
        s_axis_tdata.im <= 16'sd0;
      end
    end

    // Section 3: Sine Wave Test (10 Frames)
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= get_sine_sample(i);
        s_axis_tdata.im <= 16'sd0;
      end
    end

    // Section 4: Cosine Wave Test (10 Frames)
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= get_cosine_sample(i);
        s_axis_tdata.im <= 16'sd0;
      end
    end

    // Section 5: Random Input Test (10 Frames) - Strict Bin Ordering Check
    for (int frame = 0; frame < 10; frame++) begin
      for (int i = 0; i < N_FFT; i++) begin
        @(posedge clk);
        s_axis_tvalid   <= 1'b1;
        s_axis_tdata.re <= rand_inputs_re[frame][i];
        s_axis_tdata.im <= rand_inputs_im[frame][i];
      end
    end

    // Flush pipeline with 2 frames of idle zeros so the final frame clears cleanly
    for (int i = 0; i < N_FFT * 2; i++) begin
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
    $display(" Total Passed: %0d | Total Failed: %0d", pass_count, fail_count);
    $display("--------------------------------------------------");

    if (fail_count == 0 && pass_count > 0)
      $display(">>> SUCCESS: R22SDF FFT PASSED ALL TESTS (INCLUDING RANDOM ORDERING)! <<<");
    else
      $display(">>> FAILURE: TEST MISMATCH DETECTED! <<<");

    $finish;
  end

  // ==========================================================================
  // Output Monitor & Assertion Checker
  // ==========================================================================
  always @(posedge clk) begin
    if (m_axis_tvalid && (sample_idx < 50 * N_FFT)) begin
      int out_idx, natural_bin, frame_idx;
      cmplx_t expected;
      int err_re, err_im;

      out_idx = sample_idx % N_FFT;

      if (!USE_REORDER_BUFFER) begin
        natural_bin = bit_reverse(out_idx, $clog2(N_FFT));
      end else begin
        natural_bin = out_idx;
      end

      expected = '0;

      if (sample_idx < 10 * N_FFT) begin
        // Section 1: Impulse response
        expected.re = IMPULSE_MAG;
        expected.im = 16'sd0;

      end else if (sample_idx < 20 * N_FFT) begin
        // Section 2: DC response
        if (natural_bin == 0) expected.re = DC_MAG * N_FFT;

      end else if (sample_idx < 30 * N_FFT) begin
        // Section 3: Sine response
        if (natural_bin == SINE_CYCLES)
          expected.im = -$rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);
        else if (natural_bin == (N_FFT - SINE_CYCLES))
          expected.im =  $rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);

      end else if (sample_idx < 40 * N_FFT) begin
        // Section 4: Cosine response
        if (natural_bin == SINE_CYCLES || natural_bin == (N_FFT - SINE_CYCLES))
          expected.re = $rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);

      end else if (sample_idx < 50 * N_FFT) begin
        // Section 5: Random complex response (Golden mathematical key)
        frame_idx = (sample_idx / N_FFT) - 40;
        expected.re = rand_expected_re[frame_idx][natural_bin];
        expected.im = rand_expected_im[frame_idx][natural_bin];
      end

      // Compute absolute error distance
      err_re = (m_axis_tdata.re > expected.re) ? (m_axis_tdata.re - expected.re) : (expected.re - m_axis_tdata.re);
      err_im = (m_axis_tdata.im > expected.im) ? (m_axis_tdata.im - expected.im) : (expected.im - m_axis_tdata.im);

      if (err_re <= TOLERANCE && err_im <= TOLERANCE) begin
        pass_count++;
      end else begin
        $error("[TB ERROR] Mismatch at Sample %0d (Bin %0d)! Expected Re=%0d, Im=%0d | Got Re=%0d, Im=%0d",
               sample_idx, natural_bin, expected.re, expected.im, m_axis_tdata.re, m_axis_tdata.im);
        fail_count++;
      end

      sample_idx++;
    end
  end

endmodule
