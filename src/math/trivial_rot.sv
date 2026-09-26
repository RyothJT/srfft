// ============================================================================
// File:        trivial_rot.sv
// Description: Trivial and semi-trivial complex rotator.
//              Handles twiddle rotations by:
//                - Trivial:     x 1, x -1, x j, x -j  (0 multipliers)
//                - Octant (45): x sqrt(2)/2 * (+-1 +- j) (2 constant mults)
// ============================================================================

`timescale 1ns / 1ps

module trivial_rot #(
    parameter int WIDTH     = 16,    // Data bit width
    parameter int FRAC_BITS = 15,    // Fractional bits (e.g., Q1.15)
    parameter bit SATURATE  = 1'b1,  // 1: Clamp on overflow
    parameter int PIPELINE  = 1      // 0: Combinational, 1: 1-cycle latency
) (
    input logic clk,
    input logic rst_n,

    // Control
    input  logic valid_in,
    output logic valid_out,

    // Rotation Mode:
    //   3'd0: x  1                             ( 0 deg)
    //   3'd1: x -1                             (180 deg)
    //   3'd2: x  j                             (+90 deg)
    //   3'd3: x -j                             (-90 deg)
    //   3'd4: x sqrt(2)/2 * ( 1 - j) = W_N^1   (-45 deg / 315 deg)
    //   3'd5: x sqrt(2)/2 * (-1 - j) = W_N^3   (-135 deg / 225 deg)
    //   3'd6: x sqrt(2)/2 * (-1 + j) = W_N^5   (135 deg)
    //   3'd7: x sqrt(2)/2 * ( 1 + j) = W_N^7   ( 45 deg)
    input logic [2:0] rot_mode,

    // Complex input
    input logic signed [WIDTH-1:0] d_in_re,
    input logic signed [WIDTH-1:0] d_in_im,

    // Complex rotated output
    output logic signed [WIDTH-1:0] d_out_re,
    output logic signed [WIDTH-1:0] d_out_im
);

  // Constant C = 1/sqrt(2) in fixed-point
  // round(0.7071067811865475 * 2^15) = 23170 (16'h5A82)
  localparam logic signed [WIDTH-1:0] C_OCT = (WIDTH)'($rtoi(
      0.7071067811865475 * (1 << FRAC_BITS) + 0.5
  ));
  localparam logic signed [WIDTH-1:0] MAX_POS = {1'b0, {(WIDTH - 1) {1'b1}}};
  localparam logic signed [WIDTH-1:0] MAX_NEG = {1'b1, {(WIDTH - 1) {1'b0}}};

  // ------------------------------------------------------------------------
  // Negation with saturation (handles -(-32768) -> +32767)
  // ------------------------------------------------------------------------
  function automatic logic signed [WIDTH-1:0] safe_neg(input logic signed [WIDTH-1:0] val);
    if (SATURATE && (val == MAX_NEG)) begin
      return MAX_POS;
    end else begin
      return -val;
    end
  endfunction

  // ------------------------------------------------------------------------
  // Semi-Trivial (45 deg) Pre-adders and Constant Multiplier
  // ------------------------------------------------------------------------
  // Sums: a_re + a_im and a_re - a_im (1 extra bit to prevent intermediate overflow)
  logic signed [WIDTH:0] sum_add, sum_sub;
  always_comb begin
    sum_add = (WIDTH + 1)'(d_in_re) + (WIDTH + 1)'(d_in_im);
    sum_sub = (WIDTH + 1)'(d_in_re) - (WIDTH + 1)'(d_in_im);
  end

  // Pre-multiplier muxing based on octant mode
  logic signed [WIDTH:0] oct_term_re, oct_term_im;
  always_comb begin
    case (rot_mode)
      3'd4: begin  // ( 1 - j) -> Re: +sum_add, Im: -sum_sub
        oct_term_re = sum_add;
        oct_term_im = -sum_sub;
      end
      3'd5: begin  // (-1 - j) -> Re: -sum_sub, Im: -sum_add
        oct_term_re = -sum_sub;
        oct_term_im = -sum_add;
      end
      3'd6: begin  // (-1 + j) -> Re: -sum_add, Im: +sum_sub
        oct_term_re = -sum_add;
        oct_term_im = sum_sub;
      end
      3'd7: begin  // ( 1 + j) -> Re: +sum_sub, Im: +sum_add
        oct_term_re = sum_sub;
        oct_term_im = sum_add;
      end
      default: begin
        oct_term_re = '0;
        oct_term_im = '0;
      end
    endcase
  end

  // Constant scaling: term * (1/sqrt(2))
  localparam int PROD_WIDTH = (WIDTH + 1) + WIDTH;
  logic signed [PROD_WIDTH-1:0] prod_re, prod_im;

  always_comb begin
    prod_re = oct_term_re * C_OCT;
    prod_im = oct_term_im * C_OCT;
  end

  // Rounding and Saturation function for constant multiplication
  function automatic logic signed [WIDTH-1:0] round_and_clamp(
      input logic signed [PROD_WIDTH-1:0] prod);
    logic signed [PROD_WIDTH:0] rounded;
    logic signed [PROD_WIDTH-FRAC_BITS:0] shifted;
    begin
      rounded = (PROD_WIDTH + 1)'(prod) + ((PROD_WIDTH + 1)'(1) << (FRAC_BITS - 1));
      shifted = rounded >>> FRAC_BITS;
      if (SATURATE) begin
        if (shifted > (PROD_WIDTH - FRAC_BITS + 1)'(MAX_POS)) return MAX_POS;
        else if (shifted < (PROD_WIDTH - FRAC_BITS + 1)'(MAX_NEG)) return MAX_NEG;
        else return shifted[WIDTH-1:0];
      end else begin
        return shifted[WIDTH-1:0];
      end
    end
  endfunction

  // ------------------------------------------------------------------------
  // Output Selection (Trivial vs. Octant)
  // ------------------------------------------------------------------------
  logic signed [WIDTH-1:0] comb_out_re, comb_out_im;

  always_comb begin
    case (rot_mode)
      // Trivial Rotations (Mux + Inversion only)
      3'd0: begin  // x 1
        comb_out_re = d_in_re;
        comb_out_im = d_in_im;
      end
      3'd1: begin  // x -1
        comb_out_re = safe_neg(d_in_re);
        comb_out_im = safe_neg(d_in_im);
      end
      3'd2: begin  // x j: (re + j*im)*j = -im + j*re
        comb_out_re = safe_neg(d_in_im);
        comb_out_im = d_in_re;
      end
      3'd3: begin  // x -j: (re + j*im)*(-j) = im - j*re
        comb_out_re = d_in_im;
        comb_out_im = safe_neg(d_in_re);
      end

      // Semi-Trivial Octant Rotations (x C)
      3'd4, 3'd5, 3'd6, 3'd7: begin
        comb_out_re = round_and_clamp(prod_re);
        comb_out_im = round_and_clamp(prod_im);
      end

      default: begin
        comb_out_re = d_in_re;
        comb_out_im = d_in_im;
      end
    endcase
  end

  // ------------------------------------------------------------------------
  // Optional Output Pipeline Stage
  // ------------------------------------------------------------------------
  generate
    if (PIPELINE > 0) begin : gen_pipelined
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          valid_out <= 1'b0;
          d_out_re  <= '0;
          d_out_im  <= '0;
        end else begin
          valid_out <= valid_in;
          d_out_re  <= comb_out_re;
          d_out_im  <= comb_out_im;
        end
      end
    end else begin : gen_combinational
      always_comb begin
        valid_out = valid_in;
        d_out_re  = comb_out_re;
        d_out_im  = comb_out_im;
      end
    end
  endgenerate

endmodule
