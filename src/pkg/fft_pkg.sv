// ============================================================================
// File:        fft_pkg.sv
// Description: Global types, enumerations, constants, and helper functions
//              for the Pipelined Single-Path Delay Feedback (SDF) Split-Radix FFT.
// Reference:   IEEE Document 7451270
// ============================================================================

`timescale 1ns / 1ps

package fft_pkg;

  // ========================================================================
  // 1. Global Datapath Parameters
  // ========================================================================
  localparam int DATA_WIDTH = 16;  // Total bit-width per real/imag slice
  localparam int FRAC_BITS = 15;  // Q1.15 fixed-point format

  // Two's complement saturation limits for Q1.15
  localparam logic signed [DATA_WIDTH-1:0] MAX_POS = {1'b0, {(DATA_WIDTH - 1) {1'b1}}};  // +32767
  localparam logic signed [DATA_WIDTH-1:0] MAX_NEG = {1'b1, {(DATA_WIDTH - 1) {1'b0}}};  // -32768

  // Twiddle constant for 45-degree octant rotations: round(1/sqrt(2) * 2^15)
  localparam logic signed [DATA_WIDTH-1:0] C_SQRT2_OVER_2 = 16'sh5A82;  // 23170

  // ========================================================================
  // 2. Packed Complex Data Types (Icarus & Synthesis Compatible)
  // ========================================================================
  typedef struct packed {
    logic signed [DATA_WIDTH-1:0] re;
    logic signed [DATA_WIDTH-1:0] im;
  } cmplx_t;

  // Extended precision for intermediate butterfly operations (WIDTH + 1)
  typedef struct packed {
    logic signed [DATA_WIDTH:0] re;
    logic signed [DATA_WIDTH:0] im;
  } cmplx_ext_t;

  // Double precision for multiplier outputs (2 * WIDTH)
  typedef struct packed {
    logic signed [(2*DATA_WIDTH)-1:0] re;
    logic signed [(2*DATA_WIDTH)-1:0] im;
  } cmplx_prod_t;

  // ========================================================================
  // 3. Enumerations
  // ========================================================================

  // Trivial Rotator Modes (aligned with trivial_rot.sv)
  typedef enum logic [2:0] {
    ROT_1    = 3'd0,  // x  1                             (bypass / 0 deg)
    ROT_NEG1 = 3'd1,  // x -1                             (180 deg)
    ROT_J    = 3'd2,  // x  j                             (+90 deg)
    ROT_NEGJ = 3'd3,  // x -j                             (-90 deg)
    ROT_W1   = 3'd4,  // x sqrt(2)/2 * ( 1 - j) = W_N^1   (-45 deg / 315 deg)
    ROT_W3   = 3'd5,  // x sqrt(2)/2 * (-1 - j) = W_N^3   (-135 deg / 225 deg)
    ROT_W5   = 3'd6,  // x sqrt(2)/2 * (-1 + j) = W_N^5   (135 deg)
    ROT_W7   = 3'd7   // x sqrt(2)/2 * ( 1 + j) = W_N^7   ( 45 deg)
  } rot_mode_t;

  // Single-Path Delay Feedback (SDF) Commutator States
  typedef enum logic {
    SDF_LOAD = 1'b0,  // Commutator routes input to FIFO buffer
    SDF_CALC = 1'b1   // Commutator reads FIFO & computes butterfly with input
  } sdf_state_t;

  // Butterfly Type in the Split-Radix decomposition
  typedef enum logic [1:0] {
    BF_RADIX2  = 2'd0,  // Pure Radix-2 butterfly (even sub-band)
    BF_RADIX4  = 2'd1,  // Pure Radix-4 butterfly (odd sub-bands)
    BF_SPLIT_L = 2'd2   // Combined asymmetric Split-Radix L-shaped butterfly
  } bf_type_t;

  // ========================================================================
  // 4. Mathematical & Saturation Helper Functions
  // ========================================================================

  // Fixed-point saturation function for (DATA_WIDTH + 1) -> DATA_WIDTH
  function automatic logic signed [DATA_WIDTH-1:0] saturate_ext(
      input logic signed [DATA_WIDTH:0] val);
    begin
      if (val > (DATA_WIDTH + 1)'(MAX_POS)) return MAX_POS;
      else if (val < (DATA_WIDTH + 1)'(MAX_NEG)) return MAX_NEG;
      else return val[DATA_WIDTH-1:0];
    end
  endfunction

  // Symmetric round-to-nearest and shift by 1 (divide by 2)
  function automatic logic signed [DATA_WIDTH-1:0] scale_round_div2(
      input logic signed [DATA_WIDTH:0] val);
    logic signed [DATA_WIDTH:0] shifted;
    begin
      shifted = (val + 1'b1) >>> 1;
      return shifted[DATA_WIDTH-1:0];
    end
  endfunction

  // Generic bit-reversal function for reordering output stages
  function automatic logic [9:0] bit_reverse_1024(input logic [9:0] in_idx);
    int k;
    begin
      for (k = 0; k < 10; k = k + 1) begin
        bit_reverse_1024[k] = in_idx[9-k];
      end
    end
  endfunction

endpackage
