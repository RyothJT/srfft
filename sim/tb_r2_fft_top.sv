// ============================================================================
// File:        tb_r2_fft_top.sv
// Description: Testbench for r2_fft_top applying a discrete impulse signal.
//              For x[n] = [1, 0, 0, ...], the FFT output X[k] = 1 for all k.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module tb_r2_fft_top;

  // --------------------------------------------------------------------------
  // Parameters & Constants
  // --------------------------------------------------------------------------
  localparam int FFT_SIZE   = 1024;
  localparam int DATA_WIDTH = 16;
  localparam time CLK_PERIOD = 10ns; // 100 MHz clock

  // Q1.15 representation of 1.0 (scaled down due to stage scaling in FFT)
  // Since each stage divides by 2 across log2(N) stages, total gain = 1/N.
  // An impulse of amplitude 1.0 (0x7FFF ~ 1.0) scaled by 1/1024 yields 0x0020.
  localparam logic signed [DATA_WIDTH-1:0] IMPULSE_VAL = 16'sh7FFF; // ~1.0 in Q1.15

  // --------------------------------------------------------------------------
  // Signals
  // --------------------------------------------------------------------------
  logic   clk;
  logic   rst_n;

  // AXI4-Stream Slave Interface (Inputs to FFT)
  logic   s_axis_tvalid;
  logic   s_axis_tready;
  cmplx_t s_axis_tdata;
  logic   s_axis_tlast;

  // AXI4-Stream Master Interface (Outputs from FFT)
  logic   m_axis_tvalid;
  logic   m_axis_tready;
  cmplx_t m_axis_tdata;
  logic   m_axis_tlast;

  // Verification bookkeeping
  int     out_sample_cnt = 0;
  int     error_cnt      = 0;

  // --------------------------------------------------------------------------
  // Clock & Reset Generation
  // --------------------------------------------------------------------------
  initial begin
    clk = 0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    #(CLK_PERIOD * 5);
    rst_n = 1'b1;
  end

  // --------------------------------------------------------------------------
  // Device Under Test (DUT)
  // --------------------------------------------------------------------------
  r2_fft_top #(
      .FFT_SIZE  (FFT_SIZE),
      .DATA_WIDTH(DATA_WIDTH)
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

  // --------------------------------------------------------------------------
  // Stimulus Generation Task: Send Impulse Frame
  // --------------------------------------------------------------------------
  task automatic send_impulse_frame();
    $display("[%0t ns] Starting input impulse frame injection...", $time);
    
    for (int n = 0; n < FFT_SIZE; n++) begin
      s_axis_tvalid <= 1'b1;
      s_axis_tlast  <= (n == FFT_SIZE - 1) ? 1'b1 : 1'b0;
      
      if (n == 0) begin
        // Impulse at sample 0: Real = +1.0 (Q1.15), Imag = 0
        s_axis_tdata.re <= IMPULSE_VAL;
        s_axis_tdata.im <= 16'sh0000;
      end else begin
        // Zero for all subsequent samples: x[n] = 0
        s_axis_tdata.re <= 16'sh0000;
        s_axis_tdata.im <= 16'sh0000;
      end

      // Wait for slave readiness before advancing
      do begin
        @(posedge clk);
      end while (!s_axis_tready);
    end

    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
    s_axis_tdata  <= '0;
    $display("[%0t ns] Completed input impulse frame injection.", $time);
  endtask

  // --------------------------------------------------------------------------
  // Main Environment Control
  // --------------------------------------------------------------------------
  initial begin
    // Initialize signals
    s_axis_tvalid = 1'b0;
    s_axis_tlast  = 1'b0;
    s_axis_tdata  = '0;
    m_axis_tready = 1'b1; // Always ready to receive output

    // Wait for reset release
    @(posedge rst_n);
    @(posedge clk);

    // Send the impulse signal frame
    send_impulse_frame();

    // Timeout guard in case outputs are not generated
    fork
      begin
        wait (m_axis_tlast && m_axis_tvalid && m_axis_tready);
        @(posedge clk);
        $display("--------------------------------------------------");
        if (error_cnt == 0) begin
          $display("TEST PASSED: Impulse response verified successfully across all %0d bins.", FFT_SIZE);
        end else begin
          $display("TEST FAILED: Detected %0d mismatches in output frame.", error_cnt);
        end
        $display("--------------------------------------------------");
        $finish;
      end
      begin
        #(CLK_PERIOD * FFT_SIZE * 10);
        $display("ERROR: Simulation timed out waiting for FFT output frame.");
        $finish;
      end
    join_any
  end

  // --------------------------------------------------------------------------
  // Output Verification Monitor
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && m_axis_tvalid && m_axis_tready) begin
      // Expected scaled DC value for each bin after 10 stages of 1/2 scaling
      // 0x7FFF (32767) >> 10 = 31 (0x001F)
      logic signed [DATA_WIDTH-1:0] expected_re = IMPULSE_VAL >>> $clog2(FFT_SIZE);

      // Check Real component magnitude (allow small fixed-point truncation tolerance of ±1 LSB)
      if ((m_axis_tdata.re < expected_re - 1) || (m_axis_tdata.re > expected_re + 1)) begin
        $display("[%0t ns] MISMATCH at bin %0d: Expected Re ~ %0d, Got Re = %0d",
                 $time, out_sample_cnt, expected_re, m_axis_tdata.re);
        error_cnt++;
      end

      // Check Imaginary component magnitude (should be 0)
      if ((m_axis_tdata.im < -1) || (m_axis_tdata.im > 1)) begin
        $display("[%0t ns] MISMATCH at bin %0d: Expected Im ~ 0, Got Im = %0d",
                 $time, out_sample_cnt, m_axis_tdata.im);
        error_cnt++;
      end

      // Verify TLAST assertion alignment
      if (out_sample_cnt == FFT_SIZE - 1) begin
        if (!m_axis_tlast) begin
          $display("[%0t ns] ERROR: TLAST was expected at sample %0d but not asserted.",
                   $time, out_sample_cnt);
          error_cnt++;
        end
        out_sample_cnt <= 0;
      end else begin
        if (m_axis_tlast) begin
          $display("[%0t ns] ERROR: TLAST prematurely asserted at sample %0d.",
                   $time, out_sample_cnt);
          error_cnt++;
        end
        out_sample_cnt <= out_sample_cnt + 1;
      end
    end
  end

endmodule
