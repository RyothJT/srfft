// ============================================================================
// File:        tb_cadd_sub.sv
// Description: Self-checking unit testbench for cadd_sub.sv
// ============================================================================

`timescale 1ns / 1ps

module tb_cadd_sub;

  localparam int WIDTH = 16;
  localparam int CLK_PER = 10;
  localparam int FIFO_DEPTH = 64;

  localparam int MAX_POS = (1 << (WIDTH - 1)) - 1;  // +32767
  localparam int MAX_NEG = -(1 << (WIDTH - 1));  // -32768

  logic clk;
  logic rst_n;
  logic valid_in;
  logic valid_out;
  logic sub;
  logic signed [WIDTH-1:0] a_re, a_im;
  logic signed [WIDTH-1:0] b_re, b_im;
  logic signed [WIDTH-1:0] sum_re, sum_im;
  logic signed [WIDTH-1:0] diff_re, diff_im;
  logic signed [WIDTH-1:0] res_re, res_im;

  // Instantiate DUT (PIPELINE=1, SATURATE=1, SCALE_BY_2=0)
  cadd_sub #(
      .WIDTH     (WIDTH),
      .SCALE_BY_2(1'b0),
      .SATURATE  (1'b1),
      .PIPELINE  (1)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (valid_in),
      .valid_out(valid_out),
      .sub      (sub),
      .a_re     (a_re),
      .a_im     (a_im),
      .b_re     (b_re),
      .b_im     (b_im),
      .sum_re   (sum_re),
      .sum_im   (sum_im),
      .diff_re  (diff_re),
      .diff_im  (diff_im),
      .res_re   (res_re),
      .res_im   (res_im)
  );

  // Waveform dumping for Surfer / Icarus
`ifdef DUMP_FILE
  initial begin
    $dumpfile(`DUMP_FILE);
    $dumpvars(0, tb_cadd_sub);
  end
`endif

  // Clock generator
  initial begin
    clk = 0;
    forever #(CLK_PER / 2) clk = ~clk;
  end

  // Flat circular FIFO queues for expected outputs
  int exp_sum_re_fifo [0:FIFO_DEPTH-1];
  int exp_sum_im_fifo [0:FIFO_DEPTH-1];
  int exp_diff_re_fifo[0:FIFO_DEPTH-1];
  int exp_diff_im_fifo[0:FIFO_DEPTH-1];
  int exp_res_re_fifo [0:FIFO_DEPTH-1];
  int exp_res_im_fifo [0:FIFO_DEPTH-1];

  int wr_ptr = 0;
  int rd_ptr = 0;
  int fifo_count = 0;
  int error_count = 0;
  int test_count = 0;

  function automatic int clamp(input int val);
    begin
      if (val > MAX_POS) return MAX_POS;
      if (val < MAX_NEG) return MAX_NEG;
      return val;
    end
  endfunction

  task automatic drive_sample(input int ar, input int ai, input int br, input int bi,
                              input logic sub_val);
    int exp_s_re, exp_s_im;
    int exp_d_re, exp_d_im;
    begin
      @(posedge clk);
      valid_in <= 1'b1;
      sub      <= sub_val;
      a_re     <= ar[WIDTH-1:0];
      a_im     <= ai[WIDTH-1:0];
      b_re     <= br[WIDTH-1:0];
      b_im     <= bi[WIDTH-1:0];

      exp_s_re = clamp(ar + br);
      exp_s_im = clamp(ai + bi);
      exp_d_re = clamp(ar - br);
      exp_d_im = clamp(ai - bi);

      exp_sum_re_fifo[wr_ptr] = exp_s_re;
      exp_sum_im_fifo[wr_ptr] = exp_s_im;
      exp_diff_re_fifo[wr_ptr] = exp_d_re;
      exp_diff_im_fifo[wr_ptr] = exp_d_im;
      exp_res_re_fifo[wr_ptr] = sub_val ? exp_d_re : exp_s_re;
      exp_res_im_fifo[wr_ptr] = sub_val ? exp_d_im : exp_s_im;

      wr_ptr = (wr_ptr + 1) % FIFO_DEPTH;
      fifo_count = fifo_count + 1;
    end
  endtask

  // Checker process
  initial begin
    int exp_s_re, exp_s_im, exp_d_re, exp_d_im, exp_r_re, exp_r_im;
    forever
    @(posedge clk) begin
      if (rst_n && valid_out) begin
        if (fifo_count == 0) begin
          $display("[TB ERROR] Unexpected valid_out at time %0t!", $time);
          error_count = error_count + 1;
        end else begin
          exp_s_re = exp_sum_re_fifo[rd_ptr];
          exp_s_im = exp_sum_im_fifo[rd_ptr];
          exp_d_re = exp_diff_re_fifo[rd_ptr];
          exp_d_im = exp_diff_im_fifo[rd_ptr];
          exp_r_re = exp_res_re_fifo[rd_ptr];
          exp_r_im = exp_res_im_fifo[rd_ptr];

          rd_ptr = (rd_ptr + 1) % FIFO_DEPTH;
          fifo_count = fifo_count - 1;

          if ($signed(sum_re) != exp_s_re || $signed(sum_im) != exp_s_im) begin
            $display("[MISMATCH SUM] Test %0d: Expected (%0d, %0d), Got (%0d, %0d)", test_count,
                     exp_s_re, exp_s_im, $signed(sum_re), $signed(sum_im));
            error_count = error_count + 1;
          end

          if ($signed(diff_re) != exp_d_re || $signed(diff_im) != exp_d_im) begin
            $display("[MISMATCH DIFF] Test %0d: Expected (%0d, %0d), Got (%0d, %0d)", test_count,
                     exp_d_re, exp_d_im, $signed(diff_re), $signed(diff_im));
            error_count = error_count + 1;
          end

          if ($signed(res_re) != exp_r_re || $signed(res_im) != exp_r_im) begin
            $display("[MISMATCH RES] Test %0d: Expected (%0d, %0d), Got (%0d, %0d)", test_count,
                     exp_r_re, exp_r_im, $signed(res_re), $signed(res_im));
            error_count = error_count + 1;
          end

          test_count = test_count + 1;
        end
      end
    end
  end

  // Stimulus
  int i;
  initial begin
    valid_in = 1'b0;
    sub      = 1'b0;
    a_re     = '0;
    a_im     = '0;
    b_re     = '0;
    b_im     = '0;
    rst_n    = 1'b0;

    #(CLK_PER * 5);
    rst_n = 1'b1;
    #(CLK_PER * 2);

    $display("--- Starting Directed & Saturation Tests ---");
    // Test 1: Simple Addition & Subtraction
    drive_sample(100, 200, 50, 75, 1'b0);
    // Test 2: Muxed Subtraction
    drive_sample(100, 200, 50, 75, 1'b1);
    // Test 3: Positive Saturation (+30000 + 10000 -> clamps to +32767)
    drive_sample(30000, 30000, 10000, 10000, 1'b0);
    // Test 4: Negative Saturation (-30000 - 10000 -> clamps to -32768)
    drive_sample(-30000, -30000, 10000, 10000, 1'b1);

    @(posedge clk);
    valid_in <= 1'b0;
    #(CLK_PER * 3);

    $display("--- Starting Random Stress Tests (1000 vectors) ---");
    for (i = 0; i < 1000; i = i + 1) begin
      int   r_ar = $urandom_range(0, 65535) - 32768;
      int   r_ai = $urandom_range(0, 65535) - 32768;
      int   r_br = $urandom_range(0, 65535) - 32768;
      int   r_bi = $urandom_range(0, 65535) - 32768;
      logic r_sub = $urandom_range(0, 1);
      drive_sample(r_ar, r_ai, r_br, r_bi, r_sub);
    end

    @(posedge clk);
    valid_in <= 1'b0;

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
