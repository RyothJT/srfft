// ============================================================================
// File:        cmult_da.sv
// Description: Parallel Distributed Arithmetic (DA) Complex Multiplier.
//              Fully pipelined replacement for cmult with identical interface.
// ============================================================================

`timescale 1ns / 1ps

module cmult_pda #(
    parameter int WIDTH     = 16,
    parameter int FRAC_BITS = 15,
    parameter bit SATURATE  = 1'b1
) (
    input  logic clk,
    input  logic rst_n,

    input  logic valid_in,
    output logic valid_out,

    input  logic signed [WIDTH-1:0] a_re,
    input  logic signed [WIDTH-1:0] a_im,
    input  logic signed [WIDTH-1:0] b_re,
    input  logic signed [WIDTH-1:0] b_im,

    output logic signed [WIDTH-1:0] p_re,
    output logic signed [WIDTH-1:0] p_im
);

  localparam int PROD_WIDTH = 2 * WIDTH;
  localparam logic signed [WIDTH-1:0] MAX_POS = {1'b0, {(WIDTH - 1) {1'b1}}};
  localparam logic signed [WIDTH-1:0] MAX_NEG = {1'b1, {(WIDTH - 1) {1'b0}}};

  // ------------------------------------------------------------------------
  // Pipeline Stage 1: Partial Product Generation (DA Lookup Table equivalent)
  // ------------------------------------------------------------------------
  logic signed [PROD_WIDTH-1:0] pp_re[WIDTH];
  logic signed [PROD_WIDTH-1:0] pp_im[WIDTH];
  logic vld_pipe_1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vld_pipe_1 <= 1'b0;
      for (int i = 0; i < WIDTH; i++) begin
        pp_re[i] <= '0;
        pp_im[i] <= '0;
      end
    end else begin
      vld_pipe_1 <= valid_in;

      // Unroll bit-level partial products: A_bit * B shifted by bit-position
      for (int i = 0; i < WIDTH; i++) begin
        if (i == WIDTH - 1) begin
          // Sign bit (2's complement subtraction: -2^(WIDTH-1))
          pp_re[i] <= a_re[i] ? -$signed(PROD_WIDTH'(b_re << i)) : '0;
          pp_im[i] <= a_im[i] ? -$signed(PROD_WIDTH'(b_im << i)) : '0;
        end else begin
          // Magnitude bits (+2^i)
          pp_re[i] <= a_re[i] ? $signed(PROD_WIDTH'(b_re << i)) : '0;
          pp_im[i] <= a_im[i] ? $signed(PROD_WIDTH'(b_im << i)) : '0;
        end
      end
    end
  end

  // ------------------------------------------------------------------------
  // Pipeline Stage 2: Parallel Adder Reduction Tree
  // ------------------------------------------------------------------------
  logic signed [PROD_WIDTH-1:0] accum_re, accum_im;
  logic vld_pipe_2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      accum_re   <= '0;
      accum_im   <= '0;
      vld_pipe_2 <= 1'b0;
    end else begin
      logic signed [PROD_WIDTH-1:0] sum_re_temp;
      logic signed [PROD_WIDTH-1:0] sum_im_temp;

      sum_re_temp = '0;
      sum_im_temp = '0;

      for (int i = 0; i < WIDTH; i++) begin
        sum_re_temp = sum_re_temp + pp_re[i];
        sum_im_temp = sum_im_temp + pp_im[i];
      end

      accum_re   <= sum_re_temp;
      accum_im   <= sum_im_temp;
      vld_pipe_2 <= vld_pipe_1;
    end
  end

  // ------------------------------------------------------------------------
  // Pipeline Stage 3: Rounding, Saturation, and Output Formatting
  // ------------------------------------------------------------------------
  function automatic logic signed [WIDTH-1:0] saturate_and_slice(
      input logic signed [PROD_WIDTH-1:0] val);
    logic signed [PROD_WIDTH-1:0] rounded;
    logic signed [PROD_WIDTH - FRAC_BITS:0] shifted;
    begin
      rounded = val + $signed(PROD_WIDTH'(1 << (FRAC_BITS - 1)));
      shifted = rounded >>> FRAC_BITS;

      if (SATURATE) begin
        if (shifted > $signed(MAX_POS)) begin
          saturate_and_slice = MAX_POS;
        end else if (shifted < $signed(MAX_NEG)) begin
          saturate_and_slice = MAX_NEG;
        end else begin
          saturate_and_slice = shifted[WIDTH-1:0];
        end
      end else begin
        saturate_and_slice = shifted[WIDTH-1:0];
      end
    end
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      p_re      <= '0;
      p_im      <= '0;
      valid_out <= 1'b0;
    end else begin
      p_re      <= saturate_and_slice(accum_re);
      p_im      <= saturate_and_slice(accum_im);
      valid_out <= vld_pipe_2;
    end
  end

endmodule
