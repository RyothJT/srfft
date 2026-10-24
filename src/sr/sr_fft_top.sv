// ============================================================================
// File:        sr_fft_top.sv
// Description: Parameterized Split-Radix (R2/R4 Hybrid) SDF Pipelined 
//              FFT Processor Top Module (16-Point Configuration)
// ============================================================================

`timescale 1ns / 1ps

module sr_fft_top #(
    parameter int N_FFT           = 16,                   // 16-point configuration
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
  // 1. Stage 0: Split-Radix SDF Stage (N = 16)
  // ----------------------------------------------------------------
  logic   stg16_valid;
  cmplx_t stg16_data;

  split_radix_sdf_stage #(
      .N         (16),
      .DATA_WIDTH(DATA_WIDTH)
  ) u_stage0_N16 (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (in_valid),
      .in_data  (in_data),
      .out_valid(stg16_valid),
      .out_data (stg16_data)
  );

  // ----------------------------------------------------------------
  // 2. Stage 0 Demux Counter (16-sample frame)
  // Cycles 0..7  -> Upper / Even Branch (s) -> Feeds N=8 Stage
  // Cycles 8..15 -> Lower / Odd Branches (u, v) -> Feeds Odd BF4 Core
  // ----------------------------------------------------------------
  logic [3:0] cnt16;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt16 <= '0;
    end else if (stg16_valid) begin
      cnt16 <= cnt16 + 1'b1;
    end
  end

  logic   stg8_in_valid;
  cmplx_t stg8_in_data;
  assign stg8_in_valid = stg16_valid && (cnt16 < 8);
  assign stg8_in_data  = stg16_data;

  logic   odd_stg16_valid;
  cmplx_t odd_stg16_data;
  assign odd_stg16_valid = stg16_valid && (cnt16 >= 8);
  assign odd_stg16_data  = stg16_data;

  // ----------------------------------------------------------------
  // 3. Stage 1: Split-Radix SDF Stage (N = 8, Even Branch)
  // ----------------------------------------------------------------
  logic   stg8_valid;
  cmplx_t stg8_data;

  split_radix_sdf_stage #(
      .N         (8),
      .DATA_WIDTH(DATA_WIDTH)
  ) u_stage1_N8 (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (stg8_in_valid),
      .in_data  (stg8_in_data),
      .out_valid(stg8_valid),
      .out_data (stg8_data)
  );

  // ----------------------------------------------------------------
  // 4. Even Path Terminal Cores (BF4 & BF2 for N=8 Sub-transform)
  // ----------------------------------------------------------------
  logic [2:0] cnt8;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt8 <= '0;
    end else if (stg8_valid) begin
      cnt8 <= cnt8 + 1'b1;
    end
  end

  logic bf4_even_enable, bf2_enable;
  assign bf4_even_enable = stg8_valid && (cnt8 < 4);   // Cycles 0..3 of N=8 frame
  assign bf2_enable      = stg8_valid && (cnt8 >= 4);  // Cycles 4..7 of N=8 frame

  logic   bf4_even_valid;
  cmplx_t bf4_even_data;

  bf4_core #(
      .N_FFT          (4),
      .STAGE          (0),
      .DATA_WIDTH     (DATA_WIDTH)
  ) u_term_bf4_even (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (bf4_even_enable),
      .in_data  (stg8_data),
      .out_valid(bf4_even_valid),
      .out_data (bf4_even_data)
  );

  logic   bf2_valid;
  cmplx_t bf2_data;

  bf2_core #(
      .N_FFT          (2),
      .STAGE          (0),
      .DATA_WIDTH     (DATA_WIDTH)
  ) u_term_bf2 (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (bf2_enable),
      .in_data  (stg8_data),
      .out_valid(bf2_valid),
      .out_data (bf2_data)
  );

  // ----------------------------------------------------------------
  // 5. Odd Path Delay Alignment Line
  // Latency of u_stage1_N8 is N + PIPE_LAT = 8 + 4 = 12 cycles.
  // Delaying odd stream by 12 cycles places it immediately behind the Even path.
  // ----------------------------------------------------------------
  logic   odd_delayed_valid;
  cmplx_t odd_delayed_data;

  delay_buffer #(
      .DEPTH(12),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_odd_data_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1'b1),
      .din   (odd_stg16_data),
      .dout  (odd_delayed_data)
  );

  delay_buffer #(
      .DEPTH(12),
      .DATA_WIDTH(1)
  ) u_odd_valid_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1'b1),
      .din   (odd_stg16_valid),
      .dout  (odd_delayed_valid)
  );

  // ----------------------------------------------------------------
  // 6. Odd Path Terminal Core (Processes u[0..3] and v[0..3])
  // ----------------------------------------------------------------
  logic   bf4_odd_valid;
  cmplx_t bf4_odd_data;

  bf4_core #(
      .N_FFT          (4),
      .STAGE          (0),
      .DATA_WIDTH     (DATA_WIDTH),
      .USE_ROM_TWIDDLE(USE_ROM_TWIDDLE)
  ) u_term_bf4_odd (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (odd_delayed_valid),
      .in_data  (odd_delayed_data),
      .out_valid(bf4_odd_valid),
      .out_data (bf4_odd_data)
  );

  // ----------------------------------------------------------------
  // 7. Terminal Stage Output MUX (Serial 16-Sample Stream)
  // - Cycles 0..3:  bf4_even (Even path, Part 1)
  // - Cycles 4..7:  bf2      (Even path, Part 2)
  // - Cycles 8..11: bf4_odd  (Odd branch u)
  // - Cycles 12..15: bf4_odd (Odd branch v)
  // ----------------------------------------------------------------
  logic   term_valid;
  cmplx_t term_data;

  always_comb begin
    if (bf4_even_valid) begin
      term_valid = bf4_even_valid;
      term_data  = bf4_even_data;
    end else if (bf2_valid) begin
      term_valid = bf2_valid;
      term_data  = bf2_data;
    end else if (bf4_odd_valid) begin
      term_valid = bf4_odd_valid;
      term_data  = bf4_odd_data;
    end else begin
      term_valid = 1'b0;
      term_data  = '0;
    end
  end

  assign out_valid = term_valid;
  assign out_data  = term_data;

endmodule
