// ============================================================================
// File:        tb_sr_fft_top.sv
// Description: Multi-frame testbench running an initial DC sanity test (Frame 0)
//              followed by a single low-frequency tone test (Frame 1).
//              Uses delay periods (#CLK_PERIOD) for driving stimuli to prevent
//              testbench-DUT race conditions.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module tb_sr_fft_top;

  localparam int TEST_FFT_SIZE = 1024 * 1;
  localparam int TEST_DATA_WIDTH = DATA_WIDTH;
  localparam time CLK_PERIOD = 10ns;
  localparam real REAL_PI = 3.14159265358979323846;

  // Set to 1'b1 for bit-reversed output order, 1'b0 for natural order
  localparam bit EXPECT_BIT_REVERSED_OUTPUT = 1'b0;

  logic clk;
  logic rst_n;

  // AXI-Stream Input Interface
  logic s_axis_tvalid;
  logic s_axis_tready;
  cmplx_t s_axis_tdata;
  logic s_axis_tlast;

  // AXI-Stream Output Interface
  logic m_axis_tvalid;
  logic m_axis_tready;
  cmplx_t m_axis_tdata;
  logic m_axis_tlast;

  // Buffers
  real buf_re[0:TEST_FFT_SIZE-1];
  real buf_im[0:TEST_FFT_SIZE-1];

  // Reference Queues
  logic signed [TEST_DATA_WIDTH-1:0] ref_re_q[$];
  logic signed [TEST_DATA_WIDTH-1:0] ref_im_q[$];

  int match_count = 0;
  int error_count = 0;
  int total_samples_checked = 0;

  // Device Under Test
  sr_fft_top #(
      .FFT_SIZE(TEST_FFT_SIZE)
  ) dut (
      .clk          (clk),
      .rst_n        (rst_n),
      .s_axis_tvalid(s_axis_tvalid),
      .s_axis_tready(s_axis_tready),
      .s_axis_tdata (s_axis_tdata),
      .s_axis_tlast (s_axis_tlast),
      .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready),
      .m_axis_tdata (m_axis_tdata),
      .m_axis_tlast (m_axis_tlast)
  );

  // Bit-reversal helper function for 1024-point FFT
  function automatic int bit_rev_1024(input int in_idx);
    logic [9:0] orig;
    logic [9:0] rev;
    int b;
    orig = in_idx[9:0];
    for (b = 0; b < 10; b = b + 1) begin
      rev[b] = orig[9-b];
    end
    return int'(rev);
  endfunction

  // Rounding helper function (nearest integer)
  function automatic logic signed [TEST_DATA_WIDTH-1:0] round_real(input real val);
    real rounded_val;
    if (val >= 0.0) begin
      rounded_val = $floor(val + 0.5);
    end else begin
      rounded_val = $ceil(val - 0.5);
    end
    return logic signed [TEST_DATA_WIDTH-1:0]'(int'(rounded_val));
  endfunction

  // Clock Generation
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  // Golden Reference DFT Generator
  task automatic compute_and_queue_golden(input string test_name, input int frame_num,
                                          input real scale_factor, input bit bit_reverse_output);
    int k, n, out_idx;
    real sum_re, sum_im;
    real angle;
    real final_re, final_im;
    logic signed [TEST_DATA_WIDTH-1:0] rounded_re, rounded_im;

    logic signed [TEST_DATA_WIDTH-1:0] frame_ref_re[0:TEST_FFT_SIZE-1];
    logic signed [TEST_DATA_WIDTH-1:0] frame_ref_im[0:TEST_FFT_SIZE-1];

    $display("\n==================================================");
    $display(" Frame %0d Golden Generation: %s", frame_num, test_name);
    $display("==================================================");

    for (k = 0; k < TEST_FFT_SIZE; k = k + 1) begin
      sum_re = 0.0;
      sum_im = 0.0;

      for (n = 0; n < TEST_FFT_SIZE; n = n + 1) begin
        angle  = (2.0 * REAL_PI * real'(k) * real'(n)) / real'(TEST_FFT_SIZE);
        sum_re = sum_re + (buf_re[n] * $cos(angle) + buf_im[n] * $sin(angle));
        sum_im = sum_im - (buf_re[n] * $sin(angle) - buf_im[n] * $cos(angle));
      end

      final_re = sum_re * scale_factor;
      final_im = sum_im * scale_factor;

      // Threshold small floating-point integration noise (|val| < 0.5) to zero
      rounded_re = ($abs(final_re) >= 0.5) ? round_real(final_re) : '0;
      rounded_im = ($abs(final_im) >= 0.5) ? round_real(final_im) : '0;

      out_idx = bit_reverse_output ? bit_rev_1024(k) : k;

      frame_ref_re[out_idx] = rounded_re;
      frame_ref_im[out_idx] = rounded_im;
    end

    // Push frame values into global reference queues
    for (k = 0; k < TEST_FFT_SIZE; k = k + 1) begin
      if (frame_ref_re[k] != 0 || frame_ref_im[k] != 0) begin
        $display("[GOLDEN PEAK] Frame[%0d] | Queue Pos[%0d] | Expected: re = %0d, im = %0d",
                 frame_num, k, frame_ref_re[k], frame_ref_im[k]);
      end
      ref_re_q.push_back(frame_ref_re[k]);
      ref_im_q.push_back(frame_ref_im[k]);
    end
  endtask

  // AXI-Stream Frame Driver Task using period-based delays (#CLK_PERIOD)
  task automatic send_frame(input int frame_idx);
    int sample_idx;
    $display("--- [Frame %0d] Driving Frame to DUT ---", frame_idx);

    for (sample_idx = 0; sample_idx < TEST_FFT_SIZE; sample_idx = sample_idx + 1) begin
      while (!s_axis_tready) #CLK_PERIOD;

      s_axis_tvalid   <= 1'b1;
      s_axis_tdata.re <= round_real(buf_re[sample_idx]);
      s_axis_tdata.im <= round_real(buf_im[sample_idx]);
      s_axis_tlast    <= (sample_idx == TEST_FFT_SIZE - 1) ? 1'b1 : 1'b0;

      #CLK_PERIOD;
    end

    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
  endtask

  // Frame-Synchronized Scoreboard Process using period-based polling
  initial begin
    logic signed [TEST_DATA_WIDTH-1:0] got_re, got_im;
    logic signed [TEST_DATA_WIDTH-1:0] exp_re, exp_im;
    int current_frame;
    int frame_sample_cnt;

    m_axis_tready    = 1'b1;
    current_frame    = 0;
    frame_sample_cnt = 0;

    forever begin
      #CLK_PERIOD;
      if (m_axis_tvalid && m_axis_tready) begin
        got_re = m_axis_tdata.re;
        got_im = m_axis_tdata.im;

        if (ref_re_q.size() > 0) begin
          exp_re = ref_re_q.pop_front();
          exp_im = ref_im_q.pop_front();

          if ((got_re == exp_re) && (got_im == exp_im)) begin
            match_count = match_count + 1;
            if (got_re != 0 || got_im != 0) begin
              $display("[FFT MATCH] Frame %0d, Sample %0d | Value: (re=%0d, im=%0d)",
                       current_frame, frame_sample_cnt, got_re, got_im);
            end
          end else begin
            error_count = error_count + 1;
            $display(
                "[FFT MISMATCH] Frame %0d, Sample %0d | Exp: (re=%0d, im=%0d) | Got: (re=%0d, im=%0d)",
                current_frame, frame_sample_cnt, exp_re, exp_im, got_re, got_im);
          end

          total_samples_checked = total_samples_checked + 1;
          frame_sample_cnt      = frame_sample_cnt + 1;

          if (m_axis_tlast || (frame_sample_cnt == TEST_FFT_SIZE)) begin
            current_frame    = current_frame + 1;
            frame_sample_cnt = 0;
          end
        end else begin
          $display("[ERROR] Received unexpected output from DUT with empty golden queue!");
        end
      end
    end
  end

  // Test Sequence Controller
  initial begin
    int  i;
    int  target_bin;
    real scale_1N;
    real phase_angle;
    real calc_angle;
    real amplitude;

    s_axis_tvalid = 1'b0;
    s_axis_tdata = '0;
    s_axis_tlast = 1'b0;

    rst_n = 1'b0;
    #(CLK_PERIOD * 5);
    rst_n = 1'b1;
    #(CLK_PERIOD * 5);

    scale_1N  = 1.0 / real'(TEST_FFT_SIZE);
    amplitude = 2048.0;

    // ========================================================================
    // Frame 0: Initial DC Sanity Test (Spike expected at Bin 0)
    // ========================================================================
    $display("==================================================");
    $display(" Starting Frame 0: Initial DC Sanity Test         ");
    $display(" Expected Peak: Bin 0                             ");
    $display("==================================================");

    for (i = 0; i < TEST_FFT_SIZE; i = i + 1) begin
      buf_re[i] = amplitude;
      buf_im[i] = 0.0;
    end

    compute_and_queue_golden("DC Sanity Test (Bin 0)", 0, scale_1N, EXPECT_BIT_REVERSED_OUTPUT);
    repeat (2) begin
      send_frame(0);
    end

    // ========================================================================
    // Frame 0.5: Impulse
    // ========================================================================
    $display("==================================================");
    $display(" Starting Frame 0.5: Impulse                      ");
    $display(" Expected Peak: Bin 0                             ");
    $display("==================================================");

    buf_re[0] = amplitude * 8;
    buf_im[0] = 0.0;
    for (i = 1; i < TEST_FFT_SIZE; i = i + 1) begin
      buf_re[i] = 0.0;
      buf_im[i] = 0.0;
    end

    compute_and_queue_golden("DC Sanity Test (Bin 0)", 0, scale_1N, EXPECT_BIT_REVERSED_OUTPUT);
    repeat (2) begin
      send_frame(0);
    end

    // ========================================================================
    // Frame 1: Low-Frequency Tone Test (Spike expected at Bin 4)
    // ========================================================================
    target_bin  = 4;
    phase_angle = 0.0;

    $display("==================================================");
    $display(" Starting Frame 1: Single Low-Frequency Tone Test ");
    $display(" Target Bin: %0d | Phase: %0f rad                ", target_bin, phase_angle);
    $display("==================================================");

    for (i = 0; i < TEST_FFT_SIZE; i = i + 1) begin
      calc_angle = 2.0 * (2.0 * REAL_PI * real'(target_bin) * real'(i)) / real'(TEST_FFT_SIZE) + phase_angle;
      buf_re[i] = amplitude * $cos(calc_angle);
      buf_im[i] = amplitude * $sin(calc_angle);
    end

    compute_and_queue_golden($sformatf("Bin %0d Single Tone Test", target_bin), 1, scale_1N,
                             EXPECT_BIT_REVERSED_OUTPUT);
    repeat (3) begin
      send_frame(1);
    end

    // Wait until all golden samples are processed by the scoreboard
    while (ref_re_q.size() > 0) #CLK_PERIOD;
    #(CLK_PERIOD * 100);

    $display("\n==================================================");
    $display(" FFT Verification Complete");
    $display(" Total Samples Checked : %0d", total_samples_checked);
    $display(" Matches               : %0d", match_count);
    $display(" Errors                : %0d", error_count);
    if (error_count == 0 && total_samples_checked == 2 * TEST_FFT_SIZE) begin
      $display(" STATUS                 : >>> TEST PASSED <<<");
    end else begin
      $display(" STATUS                 : >>> TEST FAILED <<<");
    end
    $display("==================================================");

    $finish;
  end

  logic [DATA_WIDTH-1:0] s_tdata_re, s_tdata_im;
  logic [DATA_WIDTH-1:0] m_tdata_re, m_tdata_im;

  assign s_tdata_re = s_axis_tdata.re;
  assign s_tdata_im = s_axis_tdata.im;
  assign m_tdata_re = m_axis_tdata.re;
  assign m_tdata_im = m_axis_tdata.im;

  initial begin
    $dumpfile("sim/gen/vcd/current.vcd");
    $dumpvars(0, tb_sr_fft_top);
    $dumpvars(0, s_tdata_re);
    $dumpvars(0, s_tdata_im);
    $dumpvars(0, m_tdata_re);
    $dumpvars(0, m_tdata_im);
  end

endmodule
