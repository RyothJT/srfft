// ============================================================================
// File:        tb_reorder_buffer.sv
// Description: Self-checking testbench for reorder_buffer (Icarus compatible).
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module tb_reorder_buffer;

  // --------------------------------------------------------------------------
  // Parameters & Interface Signals
  // --------------------------------------------------------------------------
  localparam int TEST_FFT_SIZE = 1024;
  localparam int TEST_DATA_WIDTH = DATA_WIDTH;
  localparam time CLK_PERIOD = 10ns;

  logic   clk;
  logic   rst_n;

  // Write Interface
  logic   wr_valid;
  cmplx_t wr_data;

  // Read Interface
  logic   rd_ready;
  logic   rd_valid;
  cmplx_t rd_data;

  // --------------------------------------------------------------------------
  // DUT Instantiation
  // --------------------------------------------------------------------------
  reorder_buffer #(
      .FFT_SIZE  (TEST_FFT_SIZE),
      .DATA_WIDTH(TEST_DATA_WIDTH)
  ) dut (
      .clk     (clk),
      .rst_n   (rst_n),
      .wr_valid(wr_valid),
      .wr_data (wr_data),
      .rd_ready(rd_ready),
      .rd_valid(rd_valid),
      .rd_data (rd_data)
  );

  // --------------------------------------------------------------------------
  // Clock Generation
  // --------------------------------------------------------------------------
  initial begin
    clk = 0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  // --------------------------------------------------------------------------
  // Verification & Scoreboard Tracking
  // --------------------------------------------------------------------------
  int error_count = 0;
  int match_count = 0;

  // Flat scalar arrays for Icarus elaboration stability
  logic signed [DATA_WIDTH-1:0] ref_re[0:8191];
  logic signed [DATA_WIDTH-1:0] ref_im[0:8191];
  int wr_ptr = 0;
  int rd_ptr = 0;

  // Monitor output and check against expected sequential data
  always @(posedge clk) begin
    if (!rst_n) begin
      rd_ptr <= 0;
    end else begin
      if (rd_valid && rd_ready) begin
        if (rd_ptr < wr_ptr) begin
          logic signed [DATA_WIDTH-1:0] exp_re;
          logic signed [DATA_WIDTH-1:0] exp_im;

          exp_re = ref_re[rd_ptr];
          exp_im = ref_im[rd_ptr];

          if (rd_data.re !== exp_re || rd_data.im !== exp_im) begin
            $display(
                "[MISMATCH] At time %0t | Read Ptr: %0d | Expected: (re=%0d, im=%0d) | Got: (re=%0d, im=%0d)",
                $time, rd_ptr, exp_re, exp_im, rd_data.re, rd_data.im);
            error_count++;
          end else begin
            match_count++;
          end

          rd_ptr <= rd_ptr + 1;
        end else begin
          $display(
              "[UNEXPECTED READ] At time %0t | Read valid asserted with empty reference memory",
              $time);
          error_count++;
        end
      end
    end
  end

  task automatic drive_bit_reversed_frame(input int frame_id);
    logic [9:0] bit_rev_addr;
    int i;
    int seq_val;
    int rev_val;
    cmplx_t stimulus_val;

    // Populate golden reference sequentially
    for (i = 0; i < TEST_FFT_SIZE; i = i + 1) begin
      seq_val = (frame_id * 1000) + i;
      ref_re[wr_ptr] = seq_val;
      ref_im[wr_ptr] = -seq_val;
      wr_ptr = wr_ptr + 1;
    end

    // Stream frame into DUT in bit-reversed order
    for (i = 0; i < TEST_FFT_SIZE; i = i + 1) begin
      bit_rev_addr = bit_reverse_1024(i[9:0]);
      rev_val = (frame_id * 1000) + int'(bit_rev_addr);

      // Direct assignment auto-truncates integer expressions cleanly in SystemVerilog
      stimulus_val.re = rev_val;
      stimulus_val.im = -rev_val;

      @(posedge clk);
      #1ns;
      wr_valid = 1'b1;
      wr_data  = stimulus_val;
    end

    @(posedge clk);
    #1ns;
    wr_valid = 1'b0;
  endtask

  // --------------------------------------------------------------------------
  // Main Stimulus Sequence
  // --------------------------------------------------------------------------
  initial begin
    $display("--- Starting Reorder Buffer Test (FFT_SIZE = %0d) ---", TEST_FFT_SIZE);

    // Initial signals
    rst_n    = 1'b0;
    wr_valid = 1'b0;
    wr_data  = '0;
    rd_ready = 1'b1;

    // Apply Active-Low Reset
    #(CLK_PERIOD * 2);
    rst_n = 1'b1;
    #(CLK_PERIOD);

    // ------------------------------------------------------------------------
    // Test 1: Single Frame Reordering
    // ------------------------------------------------------------------------
    $display("--- Test 1: Streaming Single Bit-Reversed Frame ---");
    drive_bit_reversed_frame(1);

    // Wait for frame readout to complete
    wait (rd_ptr == wr_ptr);
    #(CLK_PERIOD * 10);

    // ------------------------------------------------------------------------
    // Test 2: Back-to-Back Ping-Pong Processing
    // ------------------------------------------------------------------------
    $display("--- Test 2: Back-to-Back Continuous Frames ---");
    fork
      begin
        drive_bit_reversed_frame(2);
        drive_bit_reversed_frame(3);
      end
    join

    wait (rd_ptr == wr_ptr);
    #(CLK_PERIOD * 10);

    // ------------------------------------------------------------------------
    // Test 3: Read Backpressure / Stall (rd_ready Toggling)
    // ------------------------------------------------------------------------
    $display("--- Test 3: Ping-Pong Read Backpressure ---");
    fork
      begin
        drive_bit_reversed_frame(4);
      end
      begin
        while (rd_ptr < wr_ptr) begin
          @(posedge clk);
          #1ns;
          rd_ready = ($urandom_range(0, 1) == 1);
        end
        @(posedge clk);
        #1ns;
        rd_ready = 1'b1;
      end
    join

    wait (rd_ptr == wr_ptr);
    #(CLK_PERIOD * 10);

    // ------------------------------------------------------------------------
    // Final Summary
    // ------------------------------------------------------------------------
    $display("==================================================");
    $display(" Simulation Complete");
    $display(" Matches: %0d | Errors: %0d", match_count, error_count);
    if (error_count == 0) begin
      $display(" STATUS : >>> TEST PASSED <<<");
    end else begin
      $display(" STATUS : >>> TEST FAILED <<<");
    end
    $display("==================================================");

    $finish;
  end

endmodule
