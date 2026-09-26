// ============================================================================
// File:        cadd_sub.sv
// Description: Pipelined/combinational complex adder/subtractor.
//              Computes Sum (A + B) and Diff (A - B) simultaneously, with
//              an optional multiplexed output (res = sub ? A - B : A + B).
// ============================================================================

`timescale 1ns / 1ps

module cadd_sub #(
    parameter int WIDTH      = 16,    // Data bit width
    parameter bit SCALE_BY_2 = 1'b0,  // 1: Divide by 2 (shift right 1 with rounding)
    parameter bit SATURATE   = 1'b1,  // 1: Clamp on overflow, 0: Wrap
    parameter int PIPELINE   = 1      // 0: Combinational, 1: 1 clock cycle latency
) (
    input logic clk,
    input logic rst_n, // Active-low synchronous reset

    // Control
    input  logic valid_in,
    output logic valid_out,
    input  logic sub,        // 0: res = A + B, 1: res = A - B

    // Operands: A = a_re + j*a_im, B = b_re + j*b_im
    input logic signed [WIDTH-1:0] a_re,
    input logic signed [WIDTH-1:0] a_im,
    input logic signed [WIDTH-1:0] b_re,
    input logic signed [WIDTH-1:0] b_im,

    // Dual outputs (Sum and Difference for FFT butterflies)
    output logic signed [WIDTH-1:0] sum_re,
    output logic signed [WIDTH-1:0] sum_im,
    output logic signed [WIDTH-1:0] diff_re,
    output logic signed [WIDTH-1:0] diff_im,

    // Selectable output (controlled by 'sub')
    output logic signed [WIDTH-1:0] res_re,
    output logic signed [WIDTH-1:0] res_im
);

  localparam logic signed [WIDTH-1:0] MAX_POS = {1'b0, {(WIDTH - 1) {1'b1}}};
  localparam logic signed [WIDTH-1:0] MAX_NEG = {1'b1, {(WIDTH - 1) {1'b0}}};

  // ------------------------------------------------------------------------
  // Intermediate Full-Precision Arithmetic (WIDTH + 1 bits)
  // ------------------------------------------------------------------------
  logic signed [WIDTH:0] full_sum_re, full_sum_im;
  logic signed [WIDTH:0] full_diff_re, full_diff_im;

  always_comb begin
    full_sum_re  = (WIDTH + 1)'(a_re) + (WIDTH + 1)'(b_re);
    full_sum_im  = (WIDTH + 1)'(a_im) + (WIDTH + 1)'(b_im);
    full_diff_re = (WIDTH + 1)'(a_re) - (WIDTH + 1)'(b_re);
    full_diff_im = (WIDTH + 1)'(a_im) - (WIDTH + 1)'(b_im);
  end

  // ------------------------------------------------------------------------
  // Scaling, Rounding, and Saturation Function
  // ------------------------------------------------------------------------
  function automatic logic signed [WIDTH-1:0] process_val(input logic signed [WIDTH:0] val);
    logic signed [WIDTH:0] scaled;
    begin
      if (SCALE_BY_2) begin
        // Symmetric round to nearest: (val + 1) >>> 1
        scaled = (val + 1'b1) >>> 1;
        return scaled[WIDTH-1:0];
      end else if (SATURATE) begin
        if (val > (WIDTH + 1)'(MAX_POS)) begin
          return MAX_POS;
        end else if (val < (WIDTH + 1)'(MAX_NEG)) begin
          return MAX_NEG;
        end else begin
          return val[WIDTH-1:0];
        end
      end else begin
        return val[WIDTH-1:0];
      end
    end
  endfunction

  // Processed combinational results
  logic signed [WIDTH-1:0] comb_sum_re, comb_sum_im;
  logic signed [WIDTH-1:0] comb_diff_re, comb_diff_im;
  logic signed [WIDTH-1:0] comb_res_re, comb_res_im;

  always_comb begin
    comb_sum_re  = process_val(full_sum_re);
    comb_sum_im  = process_val(full_sum_im);
    comb_diff_re = process_val(full_diff_re);
    comb_diff_im = process_val(full_diff_im);
    comb_res_re  = sub ? comb_diff_re : comb_sum_re;
    comb_res_im  = sub ? comb_diff_im : comb_sum_im;
  end

  // ------------------------------------------------------------------------
  // Output Registers or Pass-through
  // ------------------------------------------------------------------------
  generate
    if (PIPELINE > 0) begin : gen_pipelined
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          valid_out <= 1'b0;
          sum_re    <= '0;
          sum_im    <= '0;
          diff_re   <= '0;
          diff_im   <= '0;
          res_re    <= '0;
          res_im    <= '0;
        end else begin
          valid_out <= valid_in;
          sum_re    <= comb_sum_re;
          sum_im    <= comb_sum_im;
          diff_re   <= comb_diff_re;
          diff_im   <= comb_diff_im;
          res_re    <= comb_res_re;
          res_im    <= comb_res_im;
        end
      end
    end else begin : gen_combinational
      always_comb begin
        valid_out = valid_in;
        sum_re    = comb_sum_re;
        sum_im    = comb_sum_im;
        diff_re   = comb_diff_re;
        diff_im   = comb_diff_im;
        res_re    = comb_res_re;
        res_im    = comb_res_im;
      end
    end
  endgenerate

endmodule
