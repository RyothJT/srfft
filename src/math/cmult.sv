// ============================================================================
// File:        cmult.sv
// Description: Fully pipelined fixed-point complex multiplier (A * B).
//              Latency: 3 clock cycles.
// ============================================================================

`timescale 1ns / 1ps

module cmult #(
    parameter int WIDTH     = 16,   // Total bit width
    parameter int FRAC_BITS = 15,   // Number of fractional bits (e.g., Q1.15)
    parameter bit SATURATE  = 1'b1  // 1: Enable overflow saturation, 0: Truncate
) (
    input logic clk,
    input logic rst_n, // Active-low synchronous reset

    // Control
    input  logic valid_in,
    output logic valid_out,

    // Operands: A = a_re + j*a_im, B = b_re + j*b_im
    input logic signed [WIDTH-1:0] a_re,
    input logic signed [WIDTH-1:0] a_im,
    input logic signed [WIDTH-1:0] b_re,
    input logic signed [WIDTH-1:0] b_im,

    // Product: P = p_re + j*p_im
    output logic signed [WIDTH-1:0] p_re,
    output logic signed [WIDTH-1:0] p_im
);

  localparam int PROD_WIDTH = 2 * WIDTH;
  localparam logic signed [WIDTH-1:0] MAX_POS = {1'b0, {(WIDTH - 1) {1'b1}}};
  localparam logic signed [WIDTH-1:0] MAX_NEG = {1'b1, {(WIDTH - 1) {1'b0}}};

  // ------------------------------------------------------------------------
  // Pipeline Stage 1: Input Registration
  // ------------------------------------------------------------------------
  logic signed [WIDTH-1:0] a_re_r, a_im_r;
  logic signed [WIDTH-1:0] b_re_r, b_im_r;
  logic vld_pipe_1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      a_re_r     <= '0;
      a_im_r     <= '0;
      b_re_r     <= '0;
      b_im_r     <= '0;
      vld_pipe_1 <= 1'b0;
    end else begin
      a_re_r     <= a_re;
      a_im_r     <= a_im;
      b_re_r     <= b_re;
      b_im_r     <= b_im;
      vld_pipe_1 <= valid_in;
    end
  end

  // ------------------------------------------------------------------------
  // Pipeline Stage 2: 4 Multiplications (dsp-inferable)
  // ------------------------------------------------------------------------
  logic signed [PROD_WIDTH-1:0] m_rr, m_ii, m_ri, m_ir;
  logic vld_pipe_2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_rr       <= '0;
      m_ii       <= '0;
      m_ri       <= '0;
      m_ir       <= '0;
      vld_pipe_2 <= 1'b0;
    end else begin
      m_rr       <= a_re_r * b_re_r;
      m_ii       <= a_im_r * b_im_r;
      m_ri       <= a_re_r * b_im_r;
      m_ir       <= a_im_r * b_re_r;
      vld_pipe_2 <= vld_pipe_1;
    end
  end

  // ------------------------------------------------------------------------
  // Pipeline Stage 3: Add/Subtract, Rounding, and Saturation
  // ------------------------------------------------------------------------
  logic signed [PROD_WIDTH:0] sum_re, sum_im;  // 1 bit extra for add/sub
  logic signed [PROD_WIDTH:0] rnd_re, rnd_im;

  // Subtraction and Addition
  always_comb begin
    sum_re = (PROD_WIDTH + 1)'(m_rr) - (PROD_WIDTH + 1)'(m_ii);
    sum_im = (PROD_WIDTH + 1)'(m_ri) + (PROD_WIDTH + 1)'(m_ir);

    // Add rounding offset: 2^(FRAC_BITS - 1)
    if (FRAC_BITS > 0) begin
      rnd_re = sum_re + ((PROD_WIDTH + 1)'(1) << (FRAC_BITS - 1));
      rnd_im = sum_im + ((PROD_WIDTH + 1)'(1) << (FRAC_BITS - 1));
    end else begin
      rnd_re = sum_re;
      rnd_im = sum_im;
    end
  end

  // Saturation and Output Register
  function automatic logic signed [WIDTH-1:0] saturate_and_slice(
      input logic signed [PROD_WIDTH:0] val);
    logic signed [PROD_WIDTH - FRAC_BITS:0] shifted;
    shifted = val >>> FRAC_BITS;

    if (SATURATE) begin
      if (shifted > (PROD_WIDTH - FRAC_BITS + 1)'(MAX_POS)) begin
        return MAX_POS;
      end else if (shifted < (PROD_WIDTH - FRAC_BITS + 1)'(MAX_NEG)) begin
        return MAX_NEG;
      end else begin
        return shifted[WIDTH-1:0];
      end
    end else begin
      return shifted[WIDTH-1:0];
    end
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      p_re      <= '0;
      p_im      <= '0;
      valid_out <= 1'b0;
    end else begin
      p_re      <= saturate_and_slice(rnd_re);
      p_im      <= saturate_and_slice(rnd_im);
      valid_out <= vld_pipe_2;
    end
  end

endmodule
