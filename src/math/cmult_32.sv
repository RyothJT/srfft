// ============================================================================
// File:        cmult_32.sv
// Description: Fully pipelined fixed-point complex multiplier (A * B) using
//              3-2 compressors (Carry-Save Adders) for low-latency reduction
//              and rounding in Stage 3. Compatible with Icarus Verilog.
//              Latency: 3 clock cycles.
// ============================================================================

`timescale 1ns / 1ps

module cmult_32 #(
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
  localparam int COMP_WIDTH = PROD_WIDTH + 1; // 1 extra bit for sign expansion/overflow
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
  // 3-2 Compressor Task (Combinational Task with Output Ports)
  // ------------------------------------------------------------------------
  task automatic compress32 (
      input  logic [COMP_WIDTH-1:0] in0,
      input  logic [COMP_WIDTH-1:0] in1,
      input  logic [COMP_WIDTH-1:0] in2,
      output logic [COMP_WIDTH-1:0] sum,
      output logic [COMP_WIDTH-1:0] carry
  );
    begin
      sum   = in0 ^ in1 ^ in2;
      carry = ((in0 & in1) | (in1 & in2) | (in0 & in2)) << 1;
    end
  endtask

  // ------------------------------------------------------------------------
  // Pipeline Stage 3: 3-2 Compression, Addition, and Saturation
  // ------------------------------------------------------------------------
  logic signed [COMP_WIDTH-1:0] rnd_re, rnd_im;

  always_comb begin
    logic [COMP_WIDTH-1:0] op_m_rr, op_m_ii, op_m_ri, op_m_ir, rnd_const;
    logic [COMP_WIDTH-1:0] sum_re_vec, carry_re_vec;
    logic [COMP_WIDTH-1:0] sum_im_vec, carry_im_vec;

    // Sign extend products
    op_m_rr = COMP_WIDTH'(m_rr);
    op_m_ri = COMP_WIDTH'(m_ri);
    op_m_ir = COMP_WIDTH'(m_ir);

    // Rounding offset: 2^(FRAC_BITS - 1)
    rnd_const = (FRAC_BITS > 0) ? (COMP_WIDTH'(1) << (FRAC_BITS - 1)) : '0;

    // ----------------------------------------------------------------------
    // Real Part: m_rr - m_ii + rnd_const
    // Using 2's complement: -m_ii = (~m_ii) + 1
    // 3-2 Compressor compresses: m_rr, ~m_ii, and (rnd_const + 1)
    // ----------------------------------------------------------------------
    op_m_ii = COMP_WIDTH'(~m_ii); // Bitwise NOT for 2's complement subtraction

    compress32(
        op_m_rr,
        op_m_ii,
        rnd_const + 1'b1, // Incorporate +1 LSB for 2's complement with rounding
        sum_re_vec,
        carry_re_vec
    );

    // Final Carry-Propagate Addition for Real Part
    rnd_re = $signed(sum_re_vec + carry_re_vec);

    // ----------------------------------------------------------------------
    // Imaginary Part: m_ri + m_ir + rnd_const
    // 3-2 Compressor compresses: m_ri, m_ir, and rnd_const
    // ----------------------------------------------------------------------
    compress32(
        op_m_ri,
        op_m_ir,
        rnd_const,
        sum_im_vec,
        carry_im_vec
    );

    // Final Carry-Propagate Addition for Imaginary Part
    rnd_im = $signed(sum_im_vec + carry_im_vec);
  end

  // Saturation and Output Register
  function automatic logic signed [WIDTH-1:0] saturate_and_slice(
      input logic signed [COMP_WIDTH-1:0] val);
    logic signed [COMP_WIDTH - FRAC_BITS:0] shifted;
    begin
      shifted = val >>> FRAC_BITS;

      if (SATURATE) begin
        if (shifted > (COMP_WIDTH - FRAC_BITS + 1)'(MAX_POS)) begin
          saturate_and_slice = MAX_POS;
        end else if (shifted < (COMP_WIDTH - FRAC_BITS + 1)'(MAX_NEG)) begin
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
      p_re      <= saturate_and_slice(rnd_re);
      p_im      <= saturate_and_slice(rnd_im);
      valid_out <= vld_pipe_2;
    end
  end

endmodule
