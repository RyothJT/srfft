// ============================================================================
// File:        bf2_core.sv
// Description: Fixed Radix-2 Single-Path Delay Feedback (SDF) Butterfly Core
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module bf2_core #(
    parameter int N_FFT      = 32,
    parameter int STAGE      = 0,
    parameter int DATA_WIDTH = fft_pkg::DATA_WIDTH
) (
    input  logic            clk,
    input  logic            rst_n,
    input  logic            in_valid,
    input  fft_pkg::cmplx_t in_data,
    output logic            out_valid,
    output fft_pkg::cmplx_t out_data
);

  localparam int STAGES     = $clog2(N_FFT);
  localparam int SHIFT_BIT  = STAGES - 1 - STAGE;
  localparam int DELAY      = N_FFT >> (STAGE + 1);
  localparam int TOTAL_PIPE = 1 + CMULT_DELAY; // 1 cycle ROM read + 3 cycles cmult = 4

  // ----------------------------------------------------------------
  // Stage Sample Counter & Commutator Control
  // ----------------------------------------------------------------
  logic [STAGES-1:0] stg_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stg_cnt <= '0;
    end else if (in_valid) begin
      stg_cnt <= stg_cnt + 1'b1;
    end
  end

  logic s_calc;
  assign s_calc = (stg_cnt >> SHIFT_BIT) & 1'b1;

  // ----------------------------------------------------------------
  // Single-Path Delay Feedback Buffer
  // ----------------------------------------------------------------
  cmplx_t delay_in, delay_out;
  cmplx_t bf_a, bf_b;
  cmplx_t sum_out, diff_out;

  delay_buffer #(
      .DEPTH(DELAY),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(in_valid),
      .din   (delay_in),
      .dout  (delay_out)
  );

  always @* begin
    if (!s_calc) begin
      bf_a     = '0;
      bf_b     = '0;
      delay_in = in_data;
    end else begin
      bf_a     = delay_out;
      bf_b     = in_data;
      delay_in = diff_out;
    end
  end

  cadd_sub #(
      .WIDTH     (DATA_WIDTH),
      .SCALE_BY_2(1'b0),
      .SATURATE  (1'b1),
      .PIPELINE  (0)
  ) u_addsub (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (in_valid),
      .valid_out(),
      .sub      (1'b0),
      .a_re     (bf_a.re),
      .a_im     (bf_a.im),
      .b_re     (bf_b.re),
      .b_im     (bf_b.im),
      .sum_re   (sum_out.re),
      .sum_im   (sum_out.im),
      .diff_re  (diff_out.re),
      .diff_im  (diff_out.im),
      .res_re   (),
      .res_im   ()
  );

  // ----------------------------------------------------------------
  // Twiddle Generation with Synchronous ROM (1 Cycle Latency)
  // ----------------------------------------------------------------
  logic [$clog2(N_FFT)-1:0] rom_addr;
  cmplx_t twiddle_w;

  // Twiddle address corresponds to k * 2^STAGE during draining (!s_calc)
  always_comb begin
    rom_addr = (stg_cnt & (DELAY - 1)) * (1 << STAGE);
  end

  twiddle_rom #(
      .FFT_SIZE (N_FFT),
      .WIDTH    (DATA_WIDTH),
      .FRAC_BITS(fft_pkg::FRAC_BITS)
  ) u_twiddle_rom (
      .clk  (clk),
      .rst_n(rst_n),
      .addr1(rom_addr),
      .addr2('0),
      .w1   (twiddle_w),
      .w3   ()
  );

  // ----------------------------------------------------------------
  // Match 1-cycle ROM latency on data and control paths
  // ----------------------------------------------------------------
  cmplx_t delay_out_d1;
  cmplx_t sum_out_d1;
  logic   s_calc_d1;
  logic   vld_d1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      delay_out_d1 <= '0;
      sum_out_d1   <= '0;
      s_calc_d1    <= 1'b0;
      vld_d1       <= 1'b0;
    end else begin
      delay_out_d1 <= delay_out;
      sum_out_d1   <= sum_out;
      s_calc_d1    <= s_calc;
      vld_d1       <= in_valid;
    end
  end

  // ----------------------------------------------------------------
  // Complex Multiplier (Latency = CMULT_DELAY = 3)
  // ----------------------------------------------------------------
  cmplx_t twid_mult_out;
  logic   mult_valid;

  // Last stage of FFT has twiddle = 1.0 (bypass multiplication)
  localparam bit IS_TERMINAL_STAGE = (STAGE == STAGES - 1);

  generate
    if (IS_TERMINAL_STAGE) begin : gen_terminal_bypass
      delay_buffer #(
          .DEPTH(CMULT_DELAY),
          .DATA_WIDTH(2 * DATA_WIDTH)
      ) u_bypass_mult (
          .clk   (clk),
          .rst_n (rst_n),
          .enable(1'b1),
          .din   (delay_out_d1),
          .dout  (twid_mult_out)
      );
    end else begin : gen_mult
      cmult #(
          .WIDTH    (DATA_WIDTH),
          .FRAC_BITS(fft_pkg::FRAC_BITS),
          .SATURATE (1'b1)
      ) u_twiddle_mult (
          .clk      (clk),
          .rst_n    (rst_n),
          .valid_in (vld_d1),
          .valid_out(mult_valid),
          .a_re     (delay_out_d1.re),
          .a_im     (delay_out_d1.im),
          .b_re     (twiddle_w.re),
          .b_im     (twiddle_w.im),
          .p_re     (twid_mult_out.re),
          .p_im     (twid_mult_out.im)
      );
    end
  endgenerate

  // ----------------------------------------------------------------
  // Delay Sum Path and Control to Match Multiplier (3 Cycles)
  // ----------------------------------------------------------------
  cmplx_t sum_out_delayed;
  logic   s_calc_delayed;

  delay_buffer #(
      .DEPTH(CMULT_DELAY),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_sum_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1'b1),
      .din   (sum_out_d1),
      .dout  (sum_out_delayed)
  );

  delay_buffer #(
      .DEPTH(CMULT_DELAY),
      .DATA_WIDTH(1)
  ) u_scalc_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1'b1),
      .din   (s_calc_d1),
      .dout  (s_calc_delayed)
  );

  // Synchronous Output Mux: Sum emerges first (s_calc_delayed=1), Difference second (s_calc_delayed=0)
  always @* begin
    if (!s_calc_delayed) begin
      out_data = twid_mult_out;
    end else begin
      out_data = sum_out_delayed;
    end
  end

  // Propagate Valid Delay: exactly DELAY + TOTAL_PIPE cycles
  delay_buffer #(
      .DEPTH(DELAY + TOTAL_PIPE),
      .DATA_WIDTH(1)
  ) u_stg_valid_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(in_valid),
      .din   (in_valid),
      .dout  (out_valid)
  );

endmodule
