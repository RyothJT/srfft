// ============================================================================
// File:        tb_bfsr_core.sv
// Description: Simple unit testbench for streaming SDF bfsr_core.sv
//              Uses fixed cycle bounds to ensure complete test termination.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module tb_bfsr_core;

  localparam int N_FFT = 64;
  localparam int STAGE = 0;
  localparam int WIDTH = fft_pkg::DATA_WIDTH;
  localparam int CLK_PER = 10;
  localparam real SCALE_VAL = 32768.0;

  localparam int DELAY = N_FFT >> (2 * (STAGE + 1));
  localparam int STAGE_FRAME = 4 * DELAY;

  logic clk, rst_n;
  logic in_valid, out_valid;
  cmplx_t in_data, out_data;

  // Instantiate DUT
  bfsr_core #(
      .N_FFT     (N_FFT),
      .STAGE     (STAGE),
      .DATA_WIDTH(WIDTH)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (in_valid),
      .in_data  (in_data),
      .out_valid(out_valid),
      .out_data (out_data)
  );

  // Dumpfile definition
`ifndef DUMP_FILE
  `define DUMP_FILE ""
`endif

  initial begin
    if (`DUMP_FILE != "") begin
      $dumpfile(`DUMP_FILE);
      $dumpvars(0, tb_bfsr_core);
    end
  end

  // Clock generator
  initial begin
    clk = 0;
    forever #(CLK_PER / 2) clk = ~clk;
  end

  int sample_out_count = 0;

  // Monitor output cycles without blocking wait queues
  always_ff @(posedge clk) begin
    if (rst_n && out_valid) begin
      sample_out_count <= sample_out_count + 1;
      $display("Time %0t | Out Sample %0d: Re = %d, Im = %d", $time, sample_out_count, out_data.re,
               out_data.im);
    end
  end

  // Simple direct driver task
  task automatic drive_sample(input real rx, input real ix);
    begin
      @(posedge clk);
      in_valid   <= 1'b1;
      in_data.re <= $rtoi(rx * SCALE_VAL);
      in_data.im <= $rtoi(ix * SCALE_VAL);
    end
  endtask

  // Main fixed-duration test procedure
  initial begin
    int i;
    in_valid = 1'b0;
    in_data  = '0;
    rst_n    = 1'b0;

    #(CLK_PER * 5);
    rst_n = 1'b1;
    #(CLK_PER * 2);

    $display("--- Streaming Inputs into DUT ---");
    // Feed exactly 2 full frames of data
    for (i = 0; i < 2 * STAGE_FRAME; i++) begin
      drive_sample(0.2, 0.1);
    end

    // Stop driving valid inputs
    @(posedge clk);
    in_valid <= 1'b0;
    in_data  <= '0;

    $display("--- Flushing Pipeline ---");
    // Run for 100 fixed clock cycles to allow output stream completion
    repeat (100) @(posedge clk);

    $display("===========================================");
    $display(" Total Output Samples Captured: %0d", sample_out_count);
    $display(" Simulation finished successfully.");
    $display("===========================================");
    $finish;
  end

endmodule
