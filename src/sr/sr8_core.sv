// ============================================================================
// File:        sr8_core.sv
// Description: Fixed Streaming 8-Point Split-Radix Core
// ============================================================================

`timescale 1ns / 1ps

module sr8_core #(
    parameter int DATA_WIDTH      = fft_pkg::DATA_WIDTH,
    parameter bit USE_ROM_TWIDDLE = 1'b0,
    parameter bit DEBUG           = 1'b1
) (
    input  logic           clk,
    input  logic           rst_n,

    // Streaming Data Input Interface
    input  logic           in_valid,
    input  fft_pkg::cmplx_t in_data,

    // Streaming Data Output Interface
    output logic           out_valid,
    output fft_pkg::cmplx_t out_data
);

  import fft_pkg::*;

  // ------------------------------------------------------------------
  // 1. Frame Counter & Shift Register
  // ------------------------------------------------------------------
  logic [2:0] in_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_cnt <= 3'd0;
    end else if (in_valid) begin
      in_cnt <= (in_cnt == 3'd7) ? 3'd0 : in_cnt + 1'b1;
    end
  end

  cmplx_t sr_delay [0:3];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) begin
        sr_delay[i] <= '0;
      end
    end else if (in_valid && (in_cnt < 3'd4)) begin
      sr_delay[0] <= in_data;
      for (int i = 1; i < 4; i++) begin
        sr_delay[i] <= sr_delay[i-1];
      end
    end
  end

  // ------------------------------------------------------------------
  // 2. Butterfly Computation (n = 4, 5, 6, 7)
  // ------------------------------------------------------------------
  cmplx_t x_0, x_N2;
  cmplx_t sum_r2, diff_r2;

  assign x_0  = sr_delay[3 - in_cnt[1:0]];
  assign x_N2 = in_data;

  assign sum_r2.re  = x_0.re + x_N2.re;
  assign sum_r2.im  = x_0.im + x_N2.im;
  assign diff_r2.re = x_0.re - x_N2.re;
  assign diff_r2.im = x_0.im - x_N2.im;

  // Split-Radix -j Rotation
  cmplx_t diff_r2_rot;
  assign diff_r2_rot.re =  diff_r2.im;
  assign diff_r2_rot.im = -diff_r2.re;

  // ------------------------------------------------------------------
  // 3. Sub-Core Stream Routing
  // ------------------------------------------------------------------
  logic   even_in_valid;
  cmplx_t even_in_data;

  logic   odd0_in_valid;
  cmplx_t odd0_in_data;

  logic   odd1_in_valid;
  cmplx_t odd1_in_data;

  always_comb begin
    even_in_valid = 1'b0;
    even_in_data  = '0;
    odd0_in_valid = 1'b0;
    odd0_in_data  = '0;
    odd1_in_valid = 1'b0;
    odd1_in_data  = '0;

    if (in_valid && (in_cnt >= 3'd4)) begin
      even_in_valid = 1'b1;
      even_in_data  = sum_r2;

      if (in_cnt == 3'd4 || in_cnt == 3'd6) begin
        odd0_in_valid = 1'b1;
        odd0_in_data  = diff_r2;
      end

      if (in_cnt == 3'd5 || in_cnt == 3'd7) begin
        odd1_in_valid = 1'b1;
        odd1_in_data  = diff_r2_rot;
      end
    end
  end

  // ------------------------------------------------------------------
  // 4. Sub-Core Instantiations
  // ------------------------------------------------------------------
  logic   even_out_valid;
  cmplx_t even_out_data;

  logic   odd0_out_valid;
  cmplx_t odd0_out_data;

  logic   odd1_out_valid;
  cmplx_t odd1_out_data;

  bf2_core #(
      .N_FFT(4),
      .STAGE(0),
      .DATA_WIDTH(DATA_WIDTH),
      .USE_ROM_TWIDDLE(USE_ROM_TWIDDLE)
  ) u_even_r2_subcore (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (even_in_valid),
      .in_data  (even_in_data),
      .out_valid(even_out_valid),
      .out_data (even_out_data)
  );

  bf2_core #(
      .N_FFT(2),
      .STAGE(0),
      .DATA_WIDTH(DATA_WIDTH),
      .USE_ROM_TWIDDLE(USE_ROM_TWIDDLE)
  ) u_odd0_r2_subcore (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (odd0_in_valid),
      .in_data  (odd0_in_data),
      .out_valid(odd0_out_valid),
      .out_data (odd0_out_data)
  );

  bf2_core #(
      .N_FFT(2),
      .STAGE(0),
      .DATA_WIDTH(DATA_WIDTH),
      .USE_ROM_TWIDDLE(USE_ROM_TWIDDLE)
  ) u_odd1_r2_subcore (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (odd1_in_valid),
      .in_data  (odd1_in_data),
      .out_valid(odd1_out_valid),
      .out_data (odd1_out_data)
  );

  // ------------------------------------------------------------------
  // 5. Output Multiplexer
  // ------------------------------------------------------------------
  always_comb begin
    out_valid = even_out_valid | odd0_out_valid | odd1_out_valid;
    out_data  = '0;

    if (even_out_valid) begin
      out_data = even_out_data;
    end else if (odd0_out_valid) begin
      out_data = odd0_out_data;
    end else if (odd1_out_valid) begin
      out_data = odd1_out_data;
    end
  end

endmodule
