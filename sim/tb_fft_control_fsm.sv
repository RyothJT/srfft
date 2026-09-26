// ============================================================================
// File:        tb_fft_control_fsm.sv
// Description: Self-checking unit testbench for fft_control_fsm.sv
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module tb_fft_control_fsm;

  localparam int FFT_SZ = 16;
  localparam int CLK_PER = 10;

  logic clk, rst_n;
  logic valid_in, ready_in;
  logic valid_out, ready_out;
  logic sdf_mode, stage_active;

  fft_control_fsm #(
      .FFT_SIZE(FFT_SZ)
  ) dut (
      .clk             (clk),
      .rst_n           (rst_n),
      .valid_in        (valid_in),
      .ready_in(ready_in),
      .valid_out       (valid_out),
      .ready_out  (ready_out),
      .sdf_mode        (sdf_mode),
      .stage_active    (stage_active)
  );

`ifndef DUMP_FILE
  `define DUMP_FILE ""
`endif

  initial begin
    if (`DUMP_FILE != "") begin
      $dumpfile(`DUMP_FILE);
      $dumpvars(0, tb_fft_control_fsm);
    end
  end

  initial begin
    clk = 0;
    forever #(CLK_PER / 2) clk = ~clk;
  end

  int i;
  initial begin
    valid_in         = 1'b0;
    ready_in = 1'b1;
    rst_n            = 1'b0;

    #(CLK_PER * 5);
    rst_n = 1'b1;
    #(CLK_PER * 2);

    $display("--- Starting FFT Control FSM Test (Continuous Stream) ---");
    @(posedge clk);
    valid_in = 1'b1;

    // Stream 8 samples normally
    for (i = 0; i < 8; i = i + 1) begin
      @(posedge clk);
    end

    // Test Segment: Apply Backpressure (ready_in = 0)
    $display("--- Testing Backpressure (ready_in = 0) at time %0t ---", $time);
    ready_in = 1'b0;
    #(CLK_PER * 3);

    if (ready_out !== 1'b0) begin
      $error("[MISMATCH] ready_out should be 0 when ready_in is 0!");
    end

    // Release Backpressure
    $display("--- Releasing Backpressure at time %0t ---", $time);
    ready_in = 1'b1;

    if (ready_out !== 1'b1) begin
      $error("[MISMATCH] ready_out should be 1 when ready_in is 1!");
    end

    // Stream remaining samples to complete the frame
    for (i = 0; i < FFT_SZ; i = i + 1) begin
      @(posedge clk);
    end

    valid_in = 1'b0;
    #(CLK_PER * 5);

    $display("===========================================");
    $display(" FFT Control FSM Simulation Completed");
    $display("===========================================");
    $finish;
  end

endmodule
