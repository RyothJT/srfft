// ============================================================================
// File:        r22_stage_pair.sv
// Description: Radix-2^2 Single-path Delay Feedback (R22SDF) Stage Pair
//              Top-level structural wrapper
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module r22_stage_pair #(
    parameter int N             = 16,
    parameter int DATA_WIDTH    = fft_pkg::DATA_WIDTH,
    parameter bit IS_LAST_STAGE = (N == 4)
) (
    input logic clk,
    input logic rst_n,

    input  logic          in_valid,
    input  fft_pkg::cmplx_t in_data,

    output logic          out_valid,
    output fft_pkg::cmplx_t out_data
);

    logic          bf1_valid;
    fft_pkg::cmplx_t bf1_out;

    logic          bf2_valid;
    fft_pkg::cmplx_t bf2_out;

    // 1. Butterfly I Stage (Delay D1 = N/2)
    r22_butterfly1 #(
        .N(N),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_bf1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .in_data   (in_data),
        .out_valid (bf1_valid),
        .out_data  (bf1_out)
    );

    // 2. Butterfly II Stage (Delay D2 = N/4 with Trivial -j Logic)
    r22_butterfly2 #(
        .N(N),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_bf2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (bf1_valid),
        .in_data   (bf1_out),
        .out_valid (bf2_valid),
        .out_data  (bf2_out)
    );

    // 3. Twiddle Multiplication Stage
    r22_twiddle_stage #(
        .N(N),
        .DATA_WIDTH(DATA_WIDTH),
        .IS_LAST_STAGE(IS_LAST_STAGE)
    ) u_twiddle (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (bf2_valid),
        .in_data   (bf2_out),
        .out_valid (out_valid),
        .out_data  (out_data)
    );

endmodule


