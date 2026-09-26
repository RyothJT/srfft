// ============================================================================
// File:        fft_control_fsm.sv
// Description: SDF pipeline control FSM and stage tracker for Split-Radix FFT.
//              Manages load/calc modes, commutator switching, and valid streams.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module fft_control_fsm #(
    parameter int FFT_SIZE = 64  // Default FFT point size
) (
    input logic clk,
    input logic rst_n,

    // Stream Handshake
    input  logic valid_in,
    input  logic ready_in,
    output logic valid_out,
    output logic ready_out,

    // Stage-specific control outputs
    output logic   sdf_mode,     // 0: SDF_LOAD (store to delay), 1: SDF_CALC (butterfly)
    output logic   stage_active  // High when actively processing a frame
);

  localparam int STAGE_COUNT = $clog2(FFT_SIZE);
  localparam int COUNTER_BITS = $clog2(FFT_SIZE);

  // Sample counter within the current FFT frame
  logic [COUNTER_BITS-1:0] sample_cnt;
  logic                    processing;

  // Out ready: accept data when in is ready
  assign ready_out = ready_in;

  // Stage active flag
  assign stage_active = processing;

  // SDF Mode generation:
  // In SDF pipelines, the first half of the frame loads the delay buffer (SDF_LOAD = 0),
  // and the second half computes the butterfly (SDF_CALC = 1).
  // The threshold splits at FFT_SIZE / 2 for the primary stage.
  assign sdf_mode       = sample_cnt[COUNTER_BITS-1]; // MSB acts as load/calc toggle for power-of-2 stages

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sample_cnt <= '0;
      processing <= 1'b0;
      valid_out  <= 1'b0;
    end else begin
      if (valid_in && ready_out) begin
        processing <= 1'b1;
        valid_out  <= 1'b1;
        sample_cnt <= sample_cnt + 1'b1;
      end else if (!valid_in) begin
        // Hold or clear when idle
        valid_out <= 1'b0;
      end
    end
  end

endmodule
