// ============================================================================
// File:        twiddle_addr_gen.sv
// Description: Stage-dependent twiddle factor address generator for SDF FFT.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module twiddle_addr_gen #(
    parameter int FFT_SIZE = 1024
) (
    input logic clk,
    input logic rst_n,

    // Control & Handshake
    input logic                        enable,    // Advance address counter
    input logic                        clear,     // Reset k_cnt for new frame/stage
    input logic [$clog2(FFT_SIZE)-1:0] stage_sel, // Current pipeline stage index

    // Twiddle ROM Addresses (Port 1 for W^k, Port 2 for W^3k)
    output logic [$clog2(FFT_SIZE)-1:0] addr1,
    output logic [$clog2(FFT_SIZE)-1:0] addr2
);

  localparam int ADDR_W = $clog2(FFT_SIZE);
  logic [ADDR_W-1:0] k_cnt;

  // Address counter logic advancing during CALC mode
  always_ff @(posedge clk) begin
    if (!rst_n || clear) begin
      k_cnt <= '0;
    end else if (enable) begin
      k_cnt <= k_cnt + (1'b1 << stage_sel);
    end
  end

  // Port 1 address: W^k
  assign addr1 = k_cnt % FFT_SIZE;

  // Port 2 address: W^3k
  assign addr2 = (3 * k_cnt) % FFT_SIZE;

endmodule
