// ============================================================================
// File:        sr_fft_top.sv
// Description: Parameterized Split-Radix (R2/R4 Hybrid) SDF Pipelined 
//              FFT Processor Top Module
// ============================================================================

`timescale 1ns / 1ps

module sr_fft_top #(
    parameter int N_FFT = 1024,  // FFT point size (Power of 2: 32, 64, 128, 256...)
    parameter int DATA_WIDTH = fft_pkg::DATA_WIDTH,
    parameter int PIPELINE = 1
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

  // Split-Radix decomposes N into Radix-2 for the first stage (if log2(N) is odd)
  // followed by paired Radix-4 stages, or hybrid R2/R4 stages.
  localparam int LOG2_N = $clog2(N_FFT);
  localparam int IS_ODD_R2 = LOG2_N % 2;  // 1 if requiring initial Radix-2 stage
  localparam int NUM_R4_STG = LOG2_N / 2;  // Number of equivalent Radix-4 stages
  localparam int NUM_STAGES = NUM_R4_STG + IS_ODD_R2;

  localparam int STG_LATENCY = PIPELINE + 3;
  localparam int NUM_BOUNDS = NUM_STAGES + 1;

  logic [(NUM_BOUNDS * 2 * DATA_WIDTH)-1 : 0] stage_data_flat;
  logic [                   NUM_BOUNDS-1 : 0] stage_valid_flat;

  assign stage_valid_flat[0] = in_valid;
  assign stage_data_flat[(2*DATA_WIDTH)-1-:(2*DATA_WIDTH)] = in_data;

  // ------------------------------------------------------------------------
  // Split-Radix Pipelined Stage Generation
  // ------------------------------------------------------------------------
  genvar s;
  generate
    for (s = 0; s < NUM_STAGES; s = s + 1) begin : gen_sr_stages
      cmplx_t stg_in_data;
      logic   stg_in_valid;

      assign stg_in_data  = stage_data_flat[s*(2*DATA_WIDTH)+:(2*DATA_WIDTH)];
      assign stg_in_valid = stage_valid_flat[s];

      cmplx_t stg_out_data;
      logic   stg_out_valid;

      // Stage 0 is Radix-2 if log2(N_FFT) is odd (e.g., N=32, 128, 512)
      if ((s == 0) && IS_ODD_R2) begin : g_r2_stage
        bfsr_core #(
            .N_FFT(N_FFT),
            .STAGE(0),
            .DATA_WIDTH(DATA_WIDTH)
        ) u_r2_first_stage (
            .clk      (clk),
            .rst_n    (rst_n),
            .in_valid (stg_in_valid),
            .in_data  (stg_in_data),
            .out_valid(stg_out_valid),
            .out_data (stg_out_data)
        );
      end else begin : g_r4_or_sr_stage
        // Subsequent stages process Radix-4 / Split-Radix butterfly operations
        localparam int R4_STAGE_IDX = IS_ODD_R2 ? (s - 1) : s;

        bfsr_core #(
            .N_FFT(N_FFT >> (IS_ODD_R2 ? 1 : 0)),
            .STAGE(R4_STAGE_IDX),
            .DATA_WIDTH(DATA_WIDTH)
        ) u_sr_stage (
            .clk      (clk),
            .rst_n    (rst_n),
            .in_valid (stg_in_valid),
            .in_data  (stg_in_data),
            .out_valid(stg_out_valid),
            .out_data (stg_out_data)
        );
      end

      assign stage_valid_flat[s+1] = stg_out_valid;
      assign stage_data_flat[(s+1)*(2*DATA_WIDTH)+:(2*DATA_WIDTH)] = stg_out_data;
    end
  endgenerate

  // ------------------------------------------------------------------------
  // Pipeline Alignment & Reorder Buffer Integration
  // ------------------------------------------------------------------------
  logic   pipe_valid;
  cmplx_t pipe_data;
  logic   delayed_valid;

  // Total latency pipeline depth adjusted for Split-Radix delay stages
  localparam int TOTAL_LATENCY = (N_FFT - 1) + (STG_LATENCY * NUM_STAGES);

  delay_buffer #(
      .DEPTH(TOTAL_LATENCY),
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
      pipe_data  <= stage_data_flat[NUM_STAGES*(2*DATA_WIDTH)+:(2*DATA_WIDTH)];
    end
  end

  // Reorder buffer handles bit-reversal mapping for Split-Radix output indexing
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
