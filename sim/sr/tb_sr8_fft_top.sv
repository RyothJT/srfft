// ============================================================================
// File:        tb_sr8_fft_top.sv
// Description: Self-Checking Testbench for sr8_fft_top (8-Point Split-Radix FFT)
//              - Robust cycle-based timeout to eliminate timescale issues
//              - Fully synchronous driver and watchdog thread
// Compatible with Icarus Verilog (iverilog -g2012)
// ============================================================================

`timescale 1ns / 1ps

module tb_sr8_fft_top;

  import fft_pkg::*;

  localparam int CLK_PERIOD = 10;
  localparam int N_FFT = 8;  // Fixed to 8 points for SR8 top-level
  localparam int DATA_WIDTH = fft_pkg::DATA_WIDTH;

  // Number of sine/cosine cycles per FFT frame
  localparam int SINE_CYCLES = 2;
  localparam real TWO_PI = 6.283185307179586;

  // Hard Absolute Timeout Limit in clock cycles (e.g., 5,000 cycles = 50,000 ns)
  localparam int MAX_SIM_CYCLES = 5000;

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
    $dumpvars(0, tb_sr8_fft_top);
  end

  // Unit Under Test
  sr8_fft_top #(
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

  // Driver state control
  int frame_cnt = 0;
  int point_cnt = 0;
  int cycle_cnt = 0;
  logic driver_active = 0;
  logic test_complete = 0;

  // Scaled signal amplitudes
  localparam logic signed [DATA_WIDTH-1:0] IMPULSE_MAG = 16'sd1000;
  localparam logic signed [DATA_WIDTH-1:0] SINE_MAG = 16'sd100;

  // Helper Function: Compute Discrete Sine Wave Sample
  function automatic logic signed [DATA_WIDTH-1:0] get_sine_sample(int sample_num);
    real angle;
    angle = (TWO_PI * SINE_CYCLES * sample_num) / N_FFT;
    return $rtoi(SINE_MAG * $sin(angle));
  endfunction

  // --------------------------------------------------------------------------
  // 1. HARD CYCLE-BASED WATCHDOG TIMEOUT
  // Guaranteed termination regardless of simulator delay queues or timescale
  // --------------------------------------------------------------------------
  always @(posedge clk) begin
    if (cycle_cnt >= MAX_SIM_CYCLES) begin
      $display("\n--------------------------------------------------");
      $display(">>> ERROR: HARD ABSOLUTE TIMEOUT EXPIRED (%0d Clock Cycles) <<<", MAX_SIM_CYCLES);
      $display(" Diagnostics at failure:");
      $display("   - Total Cycles Run:       %0d", cycle_cnt);
      $display("   - Driver Frame Counter:   %0d / 20", frame_cnt);
      $display("   - Driver Point Counter:   %0d / %0d", point_cnt, N_FFT);
      $display("   - Driver Active State:    %0b", driver_active);
      $display("   - Stimulus Complete:      %0b", test_complete);
      $display("   - Received Output Count:  %0d", sample_idx);
      $display("--------------------------------------------------\n");
      $finish;
    end
  end

  // --------------------------------------------------------------------------
  // 2. Master Test Sequence Controller
  // --------------------------------------------------------------------------
  initial begin
    rst_n         = 1'b0;
    s_axis_tvalid = 1'b0;
    s_axis_tdata  = '0;

    #(CLK_PERIOD * 5);
    rst_n = 1'b1;
    #(CLK_PERIOD * 2);

    $display("[TB DIAGNOSTIC] Reset released at time %0t ns.", $time);
    driver_active = 1'b1;

    // Wait until driver signals all stimulus frames have been generated
    while (!test_complete) begin
      #(CLK_PERIOD);
    end

    $display("[TB DIAGNOSTIC] Stimulus generated at time %0t ns. Waiting for outputs...", $time);

    // Wait until all 160 expected output samples are collected or watchdog hits
    while (sample_idx < 20 * N_FFT) begin
      #(CLK_PERIOD);
    end

    $display("\n--------------------------------------------------");
    $display(" Testbench Finished Successfully!");
    $display(" Total Passed Samples: %0d", pass_count);
    $display(" Total Failed Samples: %0d", fail_count);
    $display(" Total Captured Output Samples: %0d", sample_idx);
    $display("--------------------------------------------------");

    if (fail_count == 0 && pass_count > 0) begin
      $display(">>> SUCCESS: ALL TESTS PASSED! <<<");
    end else begin
      $display(">>> FAILURE: FFT TEST FAILED! <<<");
    end

    $finish;
  end

  // --------------------------------------------------------------------------
  // 3. Fully Synchronous Stimulus Driver & Heartbeat Monitor
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      frame_cnt     <= 0;
      point_cnt     <= 0;
      cycle_cnt     <= 0;
      s_axis_tvalid <= 1'b0;
      s_axis_tdata  <= '0;
      test_complete <= 1'b0;
    end else begin
      cycle_cnt <= cycle_cnt + 1;

      // Diagnostic Heartbeat Log every 200 cycles
      if (cycle_cnt > 0 && (cycle_cnt % 200 == 0)) begin
        $display("[TB HEARTBEAT] Time %0t ns | Cycle %0d | Frames Driven: %0d | Outputs Received: %0d | in_valid: %0b | out_valid: %0b",
                 $time, cycle_cnt, frame_cnt, sample_idx, s_axis_tvalid, m_axis_tvalid);
      end

      if (driver_active && !test_complete) begin
        s_axis_tvalid <= 1'b1;

        if (frame_cnt < 10) begin
          // SECTION 1: Impulse Test (10 Frames)
          s_axis_tdata.re <= (point_cnt == 0) ? IMPULSE_MAG : 16'sd0;
          s_axis_tdata.im <= 16'sd0;

        end else if (frame_cnt < 20) begin
          // SECTION 2: Sine Wave Test (10 Frames)
          s_axis_tdata.re <= get_sine_sample(point_cnt);
          s_axis_tdata.im <= 16'sd0;

        end else begin
          // End of Stimulus
          s_axis_tvalid <= 1'b0;
          s_axis_tdata  <= '0;
          test_complete <= 1'b1;
        end

        // Advance sample and frame pointers synchronously
        if (point_cnt == N_FFT - 1) begin
          point_cnt <= 0;
          frame_cnt <= frame_cnt + 1;
        end else begin
          point_cnt <= point_cnt + 1;
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // 4. Dynamic Output Verification Monitor & Pipeline Trace
  // --------------------------------------------------------------------------
  always @(posedge clk) begin
    if (m_axis_tvalid) begin
      int bin_idx;
      cmplx_t expected;

      bin_idx  = sample_idx % N_FFT;
      expected = '0;

      // Expected Value Calculations
      if (sample_idx < 10 * N_FFT) begin
        // SECTION 1: Impulse Response
        expected.re = IMPULSE_MAG;
        expected.im = 16'sd0;

      end else if (sample_idx < 20 * N_FFT) begin
        // SECTION 2: Sine Wave Response
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
      end

      // Assertion Check
      if (m_axis_tdata.re == expected.re && m_axis_tdata.im == expected.im) begin
        pass_count++;
      end else begin
        $error(
            "[TB ERROR] Mismatch at Sample %0d (Bin %0d)! Expected Re=%0d, Im=%0d. Got Re=%0d, Im=%0d",
            sample_idx, bin_idx, expected.re, expected.im, m_axis_tdata.re, m_axis_tdata.im);
        fail_count++;
      end

      $display("[TB OUTPUT] Time %0t ns | Sample %0d | Bin %0d | Re: %0d, Im: %0d", $time, sample_idx, bin_idx,
               m_axis_tdata.re, m_axis_tdata.im);

      sample_idx++;
    end
  end

endmodule
