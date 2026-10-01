// ============================================================================
// File:        sr_fft_top.sv
// Description: Parameterized Split-Radix (R2/R4 Hybrid) SDF Pipelined 
//              FFT Processor Top Module (8-Point Configuration)
// ============================================================================

`timescale 1ns / 1ps

module sr_fft_top #(
    parameter int N_FFT           = 8,                    // Fixed for 8-point configuration
    parameter int DATA_WIDTH      = fft_pkg::DATA_WIDTH,
    parameter bit USE_ROM_TWIDDLE = 1'b1
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

  // ----------------------------------------------------------------
  // Inter-Stage Pipelined Connections
  // ----------------------------------------------------------------
  // Stage 0 (N=8 Split-Radix) -> Terminal Stage (BF4 & BF2 Cores)
  logic   stg0_valid;
  cmplx_t stg0_data;

  // Terminal Cores Output Connections
  logic bf4_valid, bf2_valid;
  cmplx_t bf4_data, bf2_data;

  // Selected Terminal Output -> Top Module Output
  logic   term_valid;
  cmplx_t term_data;

  // ----------------------------------------------------------------
  // Stage 0: Split-Radix SDF Stage (N = 8)
  // ----------------------------------------------------------------
  split_radix_sdf_stage #(
      .N         (8),
      .DATA_WIDTH(DATA_WIDTH)
  ) u_stage0_N8 (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (in_valid),
      .in_data  (in_data),
      .out_valid(stg0_valid),
      .out_data (stg0_data)
  );

  // ----------------------------------------------------------------
  // Terminal Stage Counter (Tracks cycle within 8-sample frame)
  // ----------------------------------------------------------------
  logic [2:0] term_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      term_cnt <= '0;
    end else if (stg0_valid) begin
      term_cnt <= term_cnt + 1'b1;
    end
  end

  // Enable flags for terminal cores based on 8-sample frame window
  logic bf4_enable, bf2_enable;
  assign bf4_enable = stg0_valid && (term_cnt < 4);  // Cycles 0..3 (N/2 Even Path)
  assign bf2_enable = stg0_valid && (term_cnt >= 4);  // Cycles 4..7 (N/4 Odd Paths)

  // ----------------------------------------------------------------
  // Terminal Core 1: Radix-4 Butterfly Core (N_FFT=4 Terminal)
  // ----------------------------------------------------------------
  bf4_core #(
      .N_FFT          (4),
      .STAGE          (0),
      .DATA_WIDTH     (DATA_WIDTH),
      .USE_ROM_TWIDDLE(USE_ROM_TWIDDLE)
  ) u_term_bf4 (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (bf4_enable),
      .in_data  (stg0_data),
      .out_valid(bf4_valid),
      .out_data (bf4_data)
  );

  // ----------------------------------------------------------------
  // Terminal Core 2: Radix-2 Butterfly Core (N_FFT=2 Terminal)
  // ----------------------------------------------------------------
  bf2_core #(
      .N_FFT          (2),
      .STAGE          (0),
      .DATA_WIDTH     (DATA_WIDTH),
      .USE_ROM_TWIDDLE(USE_ROM_TWIDDLE)
  ) u_term_bf2 (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (bf2_enable),
      .in_data  (stg0_data),
      .out_valid(bf2_valid),
      .out_data (bf2_data)
  );

  // ----------------------------------------------------------------
  // Terminal Stage Output MUX
  // Cycles 0..3  -> Route BF4 output
  // Cycles 4..7  -> Route delayed BF2 output
  // ----------------------------------------------------------------
  logic [2:0] out_term_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_term_cnt <= 6;
    end else begin
      out_term_cnt <= out_term_cnt + 1'b1;
    end
  end

  always_comb begin
    if (out_term_cnt < 4) begin
      term_valid = bf4_valid;
      term_data  = bf4_data;
    end else begin
      term_valid = bf2_valid;
      term_data  = bf2_data;
    end
  end

  assign out_valid = term_valid;
  assign out_data  = term_data;

  // ----------------------------------------------------------------
  // Output Reordering Buffer (Split-Radix Bit-Reversal)
  // ----------------------------------------------------------------
  // split_radix_reorder_buffer #(
  //     .N_FFT     (N_FFT),
  //     .DATA_WIDTH(DATA_WIDTH)
  // ) u_reorder_buffer (
  //     .clk      (clk),
  //     .rst_n    (rst_n),
  //     .in_valid (term_valid),
  //     .in_data  (term_data),
  //     .out_valid(out_valid),
  //     .out_data (out_data)
  // );

endmodule
