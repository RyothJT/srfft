// ============================================================================
// File:        tb_cmult.sv
// Description: Icarus Verilog-friendly self-checking unit testbench for cmult.sv
// ============================================================================

`timescale 1ns / 1ps

module tb_cmult;

  localparam int WIDTH = 16;
  localparam int FRAC_BITS = 15;
  localparam int CLK_PER = 10;  // 100 MHz
  localparam real SCALE = 32768.0;  // 2^15
  localparam int FIFO_DEPTH = 64;

  logic clk;
  logic rst_n;
  logic valid_in;
  logic valid_out;
  logic signed [WIDTH-1:0] a_re, a_im;
  logic signed [WIDTH-1:0] b_re, b_im;
  logic signed [WIDTH-1:0] p_re, p_im;

  // Instantiate DUT
  cmult #(
      .WIDTH    (WIDTH),
      .FRAC_BITS(FRAC_BITS),
      .SATURATE (1'b1)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (valid_in),
      .valid_out(valid_out),
      .a_re     (a_re),
      .a_im     (a_im),
      .b_re     (b_re),
      .b_im     (b_im),
      .p_re     (p_re),
      .p_im     (p_im)
  );

  // Waveform dumping for Surfer / Icarus
`ifdef DUMP_FILE
  initial begin
    $dumpfile(`DUMP_FILE);
    $dumpvars(0, tb_cmult);
  end
`endif

  // Clock generator
  initial begin
    clk = 0;
    forever #(CLK_PER / 2) clk = ~clk;
  end

  // Verification Scoreboard using flat circular arrays (Icarus compatible)
  real exp_re_fifo[0:FIFO_DEPTH-1];
  real exp_im_fifo[0:FIFO_DEPTH-1];
  int wr_ptr = 0;
  int rd_ptr = 0;
  int fifo_count = 0;

  int error_count = 0;
  int test_count = 0;

  // Convert integer fixed-point to real
  function automatic real to_real(input logic signed [WIDTH-1:0] val);
    return $itor(val) / SCALE;
  endfunction

  // Task to push expected values into circular FIFO
  task automatic push_expected(input real re_val, input real im_val);
    begin
      exp_re_fifo[wr_ptr] = re_val;
      exp_im_fifo[wr_ptr] = im_val;
      wr_ptr = (wr_ptr + 1) % FIFO_DEPTH;
      fifo_count = fifo_count + 1;
    end
  endtask

  // Task to drive stimulus and calculate expected outputs
  task automatic drive_sample(input real ar, input real ai, input real br, input real bi);
    real target_re, target_im;
    begin
      @(posedge clk);
      valid_in <= 1'b1;
      a_re     <= $rtoi(ar * SCALE);
      a_im     <= $rtoi(ai * SCALE);
      b_re     <= $rtoi(br * SCALE);
      b_im     <= $rtoi(bi * SCALE);

      // Floating-point ideal calculation
      target_re = (ar * br) - (ai * bi);
      target_im = (ar * bi) + (ai * br);

      // Clamping to match saturation limits [-1.0, +0.999969]
      if (target_re > (32767.0 / SCALE)) target_re = 32767.0 / SCALE;
      if (target_re < -1.0) target_re = -1.0;

      if (target_im > (32767.0 / SCALE)) target_im = 32767.0 / SCALE;
      if (target_im < -1.0) target_im = -1.0;

      push_expected(target_re, target_im);
    end
  endtask

  // Output monitor & checker process
  initial begin
    real actual_re, actual_im;
    real expected_re, expected_im;
    real diff_re, diff_im;

    forever
    @(posedge clk) begin
      if (rst_n && valid_out) begin
        if (fifo_count == 0) begin
          $display("[TB ERROR] Received unexpected valid_out at time %0t!", $time);
          error_count = error_count + 1;
        end else begin
          expected_re = exp_re_fifo[rd_ptr];
          expected_im = exp_im_fifo[rd_ptr];
          rd_ptr = (rd_ptr + 1) % FIFO_DEPTH;
          fifo_count = fifo_count - 1;

          actual_re = to_real(p_re);
          actual_im = to_real(p_im);

          diff_re = (actual_re > expected_re) ? (actual_re - expected_re) : (expected_re - actual_re);
          diff_im = (actual_im > expected_im) ? (actual_im - expected_im) : (expected_im - actual_im);

          // Allow up to 1.5 LSBs of tolerance due to fixed-point rounding
          if (diff_re > (1.5 / SCALE) || diff_im > (1.5 / SCALE)) begin
            $display("[MISMATCH] Sample %0d: Expected (%f, %f), Got (%f, %f)", test_count,
                     expected_re, expected_im, actual_re, actual_im);
            error_count = error_count + 1;
          end
          test_count = test_count + 1;
        end
      end
    end
  end

  // Stimulus process
  int i;
  initial begin
    valid_in = 1'b0;
    a_re     = '0;
    a_im     = '0;
    b_re     = '0;
    b_im     = '0;
    rst_n    = 1'b0;

    // Apply Reset
    #(CLK_PER * 5);
    rst_n = 1'b1;
    #(CLK_PER * 2);

    $display("--- Starting Corner Case Tests ---");
    drive_sample(0.0, 0.0, 0.5, -0.5);
    drive_sample(0.75, -0.25, 0.9999, 0.0);
    drive_sample(0.5, 0.3, 0.0, 0.9999);
    drive_sample(-1.0, 0.0, -1.0, 0.0);  // Saturation test: -1 * -1

    @(posedge clk);
    valid_in <= 1'b0;
    #(CLK_PER * 5);  // Allow pipeline to drain

    $display("--- Starting Random Stress Tests (1000 vectors) ---");
    for (i = 0; i < 1000; i = i + 1) begin
      real r_ar, r_ai, r_br, r_bi;
      r_ar = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      r_ai = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      r_br = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      r_bi = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      drive_sample(r_ar, r_ai, r_br, r_bi);
    end

    @(posedge clk);
    valid_in <= 1'b0;

    // Wait until all outputs are received and checked
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
