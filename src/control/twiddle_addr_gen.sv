// ============================================================================
// File:        twiddle_addr_gen.sv
// Description: Radix-4 SDF Twiddle Factor Address Generator with Lookahead.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module twiddle_addr_gen #(
    parameter int FFT_SIZE = 64,
    parameter int STAGE    = 0
) (
    input logic clk,
    input logic rst_n,

    input logic enable,
    input logic clear,

    output logic [$clog2(FFT_SIZE)-1:0] addr1,
    output logic [$clog2(FFT_SIZE)-1:0] addr2
);

  localparam int STAGES_R4 = $clog2(FFT_SIZE) / 2;
  localparam int DELAY = FFT_SIZE >> (2 * (STAGE + 1));
  localparam int SHIFT_BIT = $clog2(DELAY);

  logic [$clog2(FFT_SIZE)-1:0] stg_cnt;
  logic [$clog2(FFT_SIZE)-1:0] lookahead_cnt;
  logic [1:0] state_lookahead;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || clear) begin
      stg_cnt <= '0;
    end else if (enable) begin
      stg_cnt <= stg_cnt + 1'b1;
    end
  end

  // 1-cycle lookahead
  assign lookahead_cnt   = stg_cnt + (enable ? 1'd1 : 2'd0);
  assign state_lookahead = (lookahead_cnt >> SHIFT_BIT) & 2'b11;

  int sub_idx;
  always_comb begin
    case (state_lookahead)
      2'b10:   sub_idx = 1;  // W^1k
      2'b01:   sub_idx = 2;  // W^2k
      2'b00:   sub_idx = 3;  // W^3k
      default: sub_idx = 0;
    endcase
  end

  logic [$clog2(FFT_SIZE)-1:0] k_base;
  assign k_base = ((lookahead_cnt & (DELAY - 1)) << (2 * STAGE)) & (FFT_SIZE - 1);

  assign addr1  = (k_base * sub_idx) & (FFT_SIZE - 1);
  assign addr2  = (k_base * 3) & (FFT_SIZE - 1);

endmodule
