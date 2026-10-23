// ============================================================================
// File:        tb_r22_fft_top.sv
// Description: Self-Checking Testbench for r22_fft_top
//              Supports N_FFT up to 1024, testing Impulse, DC, Sine, and Cosine.
// ============================================================================

`timescale 1ns / 1ps

module tb_r22_fft_top;

  import fft_pkg::*;

  localparam int CLK_PERIOD = 10;
  localparam int N_FFT = 16;  // Scalable to 16, 64, 256, 1024
  localparam int DATA_WIDTH = fft_pkg::DATA_WIDTH;
  localparam int SINE_CYCLES = N_FFT / 16;
  localparam real TWO_PI = 6.283185307179586;

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

  localparam logic signed [DATA_WIDTH-1:0] IMPULSE_MAG = 16'sd1000;
  localparam logic signed [DATA_WIDTH-1:0] DC_MAG = 16'sd100;
  localparam logic signed [DATA_WIDTH-1:0] SINE_MAG = 16'sd100;

  // Bit-reversal function for DIF output reordering
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

  initial begin
    rst_n         = 1'b0;
    s_axis_tvalid = 1'b0;
    s_axis_tdata  = '0;
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

    @(posedge clk);
    s_axis_tvalid <= 1'b0;
    s_axis_tdata  <= '0;

    #(CLK_PERIOD * N_FFT * 4);

    $display("--------------------------------------------------");
    $display(" Testbench Finished!");
    $display(" Total Passed: %0d | Total Failed: %0d", pass_count, fail_count);
    $display("--------------------------------------------------");

    if (fail_count == 0 && pass_count > 0)
      $display(">>> SUCCESS: R22SDF FFT PASSED ALL TESTS! <<<");
    else $display(">>> FAILURE: TEST MISMATCH DETECTED! <<<");

    $finish;
  end

  // Output Monitor (Maps bit-reversed outputs to natural frequency bins)
  always @(posedge clk) begin
    if (m_axis_tvalid) begin
      int out_idx, natural_bin;
      cmplx_t expected;

      out_idx     = sample_idx % N_FFT;
      natural_bin = bit_reverse(out_idx, $clog2(N_FFT));
      expected    = '0;

      if (sample_idx < 10 * N_FFT) begin
        // Impulse response: flat across all bins
        expected.re = IMPULSE_MAG;
        expected.im = 16'sd0;

      end else if (sample_idx < 20 * N_FFT) begin
        // DC response: concentrated in bin 0
        if (natural_bin == 0) expected.re = DC_MAG * N_FFT;

      end else if (sample_idx < 30 * N_FFT) begin
        // Sine response: peaks at +k and -k bins
        if (natural_bin == SINE_CYCLES)
          expected.im = -$rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);
        else if (natural_bin == (N_FFT - SINE_CYCLES))
          expected.im = $rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);

      end else if (sample_idx < 40 * N_FFT) begin
        // Cosine response: peaks at +k and -k bins
        if (natural_bin == SINE_CYCLES || natural_bin == (N_FFT - SINE_CYCLES))
          expected.re = $rtoi((real'(SINE_MAG) * real'(N_FFT)) / 2.0);
      end

      if (m_axis_tdata.re == expected.re && m_axis_tdata.im == expected.im) begin
        pass_count++;
      end else begin
        $error(
            "[TB ERROR] Mismatch at Sample %0d (Bin %0d)! Expected Re=%0d, Im=%0d | Got Re=%0d, Im=%0d",
            sample_idx, natural_bin, expected.re, expected.im, m_axis_tdata.re, m_axis_tdata.im);
        fail_count++;
      end

      sample_idx++;
    end
  end

endmodule
