// ============================================================================
// File:        r2_fft_top.sv
// Description: Parameterized Radix-2 SDF Pipelined FFT Processor
//              Integrated with Stage Twiddle Multipliers (cmult)
// ============================================================================

`timescale 1ns / 1ps

module r2_fft_top #(
    parameter int N_FFT = 512, // FFT point size (power of 2)
    parameter int DATA_WIDTH = fft_pkg::DATA_WIDTH,
    parameter bit USE_REORDER_BUFFER = fft_pkg::USE_REORDER_BUFFER
) (
    input logic clk,
    input logic rst_n,

    // Streaming Data Interface
    input logic            in_valid,
    input fft_pkg::cmplx_t in_data,

    output logic            out_valid,
    output fft_pkg::cmplx_t out_data
);

  import fft_pkg::*;

  localparam int STAGES = $clog2(N_FFT);
  localparam int NUM_BOUNDS = STAGES + 1;

  logic [(NUM_BOUNDS * 2 * DATA_WIDTH)-1 : 0] stage_data_flat;
  logic [                   NUM_BOUNDS-1 : 0] stage_valid_flat;

  // Connect top-level input to internal pipeline tracking
  assign stage_valid_flat[0] = in_valid;

  genvar s;
  generate
    for (s = 0; s < STAGES; s = s + 1) begin : gen_stages
      // ----------------------------------------------------------------
      // Input Data Selection
      // ----------------------------------------------------------------
      cmplx_t stg_in_data;
      logic   stg_in_valid;

      if (s == 0) begin : g_in0
        assign stg_in_data  = in_data;
        assign stg_in_valid = in_valid;
      end else begin : g_in_next
        assign stg_in_data  = stage_data_flat[s*(2*DATA_WIDTH)-1-:(2*DATA_WIDTH)];
        assign stg_in_valid = stage_valid_flat[s];
      end

      cmplx_t stg_out_data;

      // ----------------------------------------------------------------
      // Radix-2 Butterfly Core Instance
      // ----------------------------------------------------------------
      bf2_core #(
          .N_FFT(N_FFT),
          .STAGE(s),
          .DATA_WIDTH(DATA_WIDTH)
      ) u_bf2_core (
          .clk      (clk),
          .rst_n    (rst_n),
          .in_valid (stg_in_valid),
          .in_data  (stg_in_data),
          .out_valid(stage_valid_flat[s+1]),
          .out_data (stg_out_data)
      );

      assign stage_data_flat[(s+1)*(2*DATA_WIDTH)-1-:(2*DATA_WIDTH)] = stg_out_data;
    end
  endgenerate

  // ------------------------------------------------------------------------
  // Direct Pipeline Connection to Reorder Buffer
  // ------------------------------------------------------------------------
  logic   final_valid;
  cmplx_t final_data;

  // Use the true cycle-accurate valid signal from the final butterfly stage
  assign final_valid = stage_valid_flat[STAGES];
  assign final_data  = stage_data_flat[STAGES*(2*DATA_WIDTH)-1-:(2*DATA_WIDTH)];


  generate
    if (USE_REORDER_BUFFER) begin
      // Bit-Reversal Reorder Buffer Instance
      reorder_buffer #(
          .FFT_SIZE  (N_FFT),
          .DATA_WIDTH(DATA_WIDTH)
      ) u_reorder_buffer (
          .clk     (clk),
          .rst_n   (rst_n),
          .wr_valid(final_valid),
          .wr_data (final_data),
          .rd_ready(1'b1),
          .rd_valid(out_valid),
          .rd_data (out_data)
      );
    end else begin
      assign out_valid = final_valid;
      assign out_data  = final_data;
    end

  endgenerate

endmodule
