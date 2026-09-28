// ============================================================================
// File:        r4_fft_top.sv
// Description: Parameterized Radix-4 SDF Pipelined FFT Processor Top Module
// ============================================================================

`timescale 1ns / 1ps

module r4_fft_top #(
    parameter int N_FFT      = 1024,                   // FFT point size (power of 4: 16, 64, 256...)
    parameter int DATA_WIDTH = fft_pkg::DATA_WIDTH,
    parameter int PIPELINE   = 1
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

  localparam int STAGES_R4 = $clog2(N_FFT) / 2;  // Log4(N_FFT) stages
  localparam int STG_LATENCY = PIPELINE + 3;
  localparam int NUM_BOUNDS = STAGES_R4 + 1;

  logic [(NUM_BOUNDS * 2 * DATA_WIDTH)-1 : 0] stage_data_flat;
  logic [                   NUM_BOUNDS-1 : 0] stage_valid_flat;

  assign stage_valid_flat[0] = in_valid;

  genvar s;
  generate
    for (s = 0; s < STAGES_R4; s = s + 1) begin : gen_r4_stages
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

      // Radix-4 Butterfly Instance
      bf4_core #(
          .N_FFT(N_FFT),
          .STAGE(s),
          .DATA_WIDTH(DATA_WIDTH)
      ) u_bf4_core (
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
  // Pipeline Alignment & Reorder Buffer Integration
  // ------------------------------------------------------------------------
  logic   pipe_valid;
  cmplx_t pipe_data;
  logic   delayed_valid;

  delay_buffer #(
      .DEPTH((N_FFT - 1) + (STG_LATENCY * STAGES_R4)),
      .DATA_WIDTH(1)
  ) u_valid_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1'b1),
      .din   (in_valid),
      .dout  (delayed_valid)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pipe_valid <= 1'b0;
      pipe_data  <= '0;
    end else begin
      pipe_valid <= delayed_valid;
      pipe_data  <= stage_data_flat[STAGES_R4*(2*DATA_WIDTH)-1-:(2*DATA_WIDTH)];
    end
  end

  reorder_buffer #(
      .FFT_SIZE  (N_FFT),
      .DATA_WIDTH(DATA_WIDTH)
  ) u_reorder_buffer (
      .clk     (clk),
      .rst_n   (rst_n),
      .wr_valid(pipe_valid),
      .wr_data (pipe_data),
      .rd_ready(1'b1),
      .rd_valid(out_valid),
      .rd_data (out_data)
  );

endmodule
