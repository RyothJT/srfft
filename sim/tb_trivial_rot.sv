// ============================================================================
// File:        tb_trivial_rot.sv
// Description: Self-checking unit testbench for trivial_rot.sv
// ============================================================================

`timescale 1ns / 1ps

module tb_trivial_rot;

  localparam int WIDTH = 16;
  localparam int FRAC_BITS = 15;
  localparam int CLK_PER = 10;
  localparam real SCALE = 32768.0;
  localparam int FIFO_DEPTH = 64;

  logic       clk;
  logic       rst_n;
  logic       valid_in;
  logic       valid_out;
  logic [2:0] rot_mode;
  logic signed [WIDTH-1:0] d_in_re, d_in_im;
  logic signed [WIDTH-1:0] d_out_re, d_out_im;

  // Instantiate DUT
  trivial_rot #(
      .WIDTH    (WIDTH),
      .FRAC_BITS(FRAC_BITS),
      .SATURATE (1'b1),
      .PIPELINE (1)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (valid_in),
      .valid_out(valid_out),
      .rot_mode (rot_mode),
      .d_in_re  (d_in_re),
      .d_in_im  (d_in_im),
      .d_out_re (d_out_re),
      .d_out_im (d_out_im)
  );

  // Waveform dumping for Surfer / Icarus
`ifdef DUMP_FILE
  initial begin
    $dumpfile(`DUMP_FILE);
    $dumpvars(0, tb_trivial_rot);
  end
`endif

  // Clock generator
  initial begin
    clk = 0;
    forever #(CLK_PER / 2) clk = ~clk;
  end

  // Circular FIFO for expected values
  real exp_re_fifo     [0:FIFO_DEPTH-1];
  real exp_im_fifo     [0:FIFO_DEPTH-1];
  int  wr_ptr = 0;
  int  rd_ptr = 0;
  int  fifo_count = 0;
  int  error_count = 0;
  int  test_count = 0;

  function automatic real to_real(input logic signed [WIDTH-1:0] val);
    return $itor(val) / SCALE;
  endfunction

  // Task to calculate theoretical ideal rotation
  task automatic drive_sample(input real ar, input real ai, input logic [2:0] mode);
    real target_re, target_im;
    real c_val;
    begin
      c_val = 0.7071067811865475;  // 1/sqrt(2)

      case (mode)
        3'd0: begin
          target_re = ar;
          target_im = ai;
        end
        3'd1: begin
          target_re = -ar;
          target_im = -ai;
        end
        3'd2: begin
          target_re = -ai;
          target_im = ar;
        end
        3'd3: begin
          target_re = ai;
          target_im = -ar;
        end
        3'd4: begin
          target_re = c_val * (ar + ai);
          target_im = c_val * (ai - ar);
        end  // 1 - j
        3'd5: begin
          target_re = c_val * (-ar + ai);
          target_im = c_val * (-ai - ar);
        end  // -1 - j
        3'd6: begin
          target_re = c_val * (-ar - ai);
          target_im = c_val * (ar - ai);
        end  // -1 + j
        3'd7: begin
          target_re = c_val * (ar - ai);
          target_im = c_val * (ar + ai);
        end  // 1 + j
      endcase

      // Clamp saturation limits
      if (target_re > (32767.0 / SCALE)) target_re = 32767.0 / SCALE;
      if (target_re < -1.0) target_re = -1.0;
      if (target_im > (32767.0 / SCALE)) target_im = 32767.0 / SCALE;
      if (target_im < -1.0) target_im = -1.0;

      @(posedge clk);
      valid_in <= 1'b1;
      rot_mode <= mode;
      d_in_re  <= $rtoi(ar * SCALE);
      d_in_im  <= $rtoi(ai * SCALE);

      exp_re_fifo[wr_ptr] = target_re;
      exp_im_fifo[wr_ptr] = target_im;
      wr_ptr = (wr_ptr + 1) % FIFO_DEPTH;
      fifo_count = fifo_count + 1;
    end
  endtask

  // Monitor & Checker
  initial begin
    real actual_re, actual_im;
    real expected_re, expected_im;
    real diff_re, diff_im;

    forever
    @(posedge clk) begin
      if (rst_n && valid_out) begin
        if (fifo_count == 0) begin
          $display("[TB ERROR] Unexpected valid_out at %0t", $time);
          error_count = error_count + 1;
        end else begin
          expected_re = exp_re_fifo[rd_ptr];
          expected_im = exp_im_fifo[rd_ptr];
          rd_ptr = (rd_ptr + 1) % FIFO_DEPTH;
          fifo_count = fifo_count - 1;

          actual_re = to_real(d_out_re);
          actual_im = to_real(d_out_im);

          diff_re = (actual_re > expected_re) ? (actual_re - expected_re) : (expected_re - actual_re);
          diff_im = (actual_im > expected_im) ? (actual_im - expected_im) : (expected_im - actual_im);

          // Threshold: 1.5 LSBs of rounding tolerance
          if (diff_re > (1.5 / SCALE) || diff_im > (1.5 / SCALE)) begin
            $display("[MISMATCH] Test %0d (Mode %0d): Expected (%f, %f), Got (%f, %f)", test_count,
                     rot_mode, expected_re, expected_im, actual_re, actual_im);
            error_count = error_count + 1;
          end
          test_count = test_count + 1;
        end
      end
    end
  end

  // Stimulus
  int m, i;
  initial begin
    valid_in = 1'b0;
    rot_mode = '0;
    d_in_re  = '0;
    d_in_im  = '0;
    rst_n    = 1'b0;

    #(CLK_PER * 5);
    rst_n = 1'b1;
    #(CLK_PER * 2);

    $display("--- Testing All 8 Rotation Modes with Known Values ---");
    for (m = 0; m < 8; m = m + 1) begin
      drive_sample(0.6, -0.4, m[2:0]);
    end

    @(posedge clk);
    valid_in <= 1'b0;
    #(CLK_PER * 3);

    $display("--- Starting Random Stress Tests (1000 vectors) ---");
    for (i = 0; i < 1000; i = i + 1) begin
      real r_ar, r_ai;
      logic [2:0] r_mode;
      r_ar   = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      r_ai   = $itor($urandom_range(0, 65535) - 32768) / 32768.0;
      r_mode = $urandom_range(0, 7);
      drive_sample(r_ar, r_ai, r_mode);
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
