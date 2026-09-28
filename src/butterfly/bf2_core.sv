// ============================================================================
// File:        bf2_core.sv
// Description: Radix-2 Single-Path Delay Feedback (SDF) Butterfly Core
//              Includes Delay Buffer, Commutator Muxing, Complex Adder/Subtractor,
//              Twiddle Multiplication, and Delay Pipeline Alignment.
// ============================================================================

`timescale 1ns / 1ps

module bf2_core #(
    parameter int N_FFT           = 32,                   // Full FFT point size
    parameter int STAGE           = 0,                    // Stage index (0 to STAGES-1)
    parameter int DATA_WIDTH      = fft_pkg::DATA_WIDTH,
    parameter bit USE_ROM_TWIDDLE = 1'b1                  // 0: Baseline real dynamic, 1: ROM-based
) (
    input logic clk,
    input logic rst_n,
    // Input Interface
    input logic            in_valid,
    input fft_pkg::cmplx_t in_data,

    // Output Interface
    output logic            out_valid,
    output fft_pkg::cmplx_t out_data
);

  import fft_pkg::*;

  localparam int STAGES = $clog2(N_FFT);
  localparam int DELAY = N_FFT >> (STAGE + 1);
  localparam int SHIFT_BIT = STAGES - 1 - STAGE;
  localparam real TWO_PI = 6.283185307179586;

  // ----------------------------------------------------------------
  // Stage Local Sample Counter (Pipeline-Aligned)
  // ----------------------------------------------------------------
  logic [STAGES-1:0] stg_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stg_cnt <= '0;
    end else if (in_valid) begin
      stg_cnt <= stg_cnt + 1'b1;
    end
  end

  cmplx_t delay_in, delay_out;
  cmplx_t bf_a, bf_b;
  cmplx_t sum_out, diff_out;
  logic s_calc, s_calc_delayed;

  // Stage commutator control bit: toggles every DELAY cycles
  assign s_calc = (stg_cnt >> SHIFT_BIT) & 1'b1;

  // ----------------------------------------------------------------
  // Single-Path Delay Feedback Buffer
  // ----------------------------------------------------------------
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

  // SDF Commutator Multiplexer Logic
  always_comb begin
    if (!s_calc) begin
      bf_a     = '0;
      bf_b     = '0;
      delay_in = in_data;
    end else begin
      bf_a     = delay_out;
      bf_b     = in_data;
      delay_in = diff_out;  // Immediate un-rotated difference feedback
    end
  end

  // Butterfly Complex Adder/Subtractor
  cadd_sub #(
      .WIDTH(DATA_WIDTH),
      .SCALE_BY_2(1'b0),
      .SATURATE(1'b1),
      .PIPELINE(0)
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
  // Method 1: Baseline Dynamic Twiddle Factor Calculation (Preserved)
  // W_N^k = e^(-j*2*pi*k/N) where k = (stg_cnt % DELAY) * 2^STAGE
  // ----------------------------------------------------------------
  cmplx_t twiddle_baseline;

  // always_comb begin
  //   int  k;
  //   real angle;

  //   k = (stg_cnt & (DELAY - 1)) * (1 << STAGE);
  //   angle = -TWO_PI * real'(k) / real'(N_FFT);

  //   twiddle_baseline.re = $rtoi($cos(angle) * 32767.0);
  //   twiddle_baseline.im = $rtoi($sin(angle) * 32767.0);
  // end

  // ----------------------------------------------------------------
  // Method 2: ROM-Based Twiddle Factor Generation
  // ----------------------------------------------------------------
  logic [$clog2(N_FFT)-1:0] rom_addr1, rom_addr2;
  cmplx_t twiddle_rom_w1, twiddle_rom_w3;

  twiddle_addr_gen #(
      .FFT_SIZE(N_FFT),
      .STAGE   (STAGE)
  ) u_twiddle_addr_gen (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(in_valid),
      .clear (1'b0),
      .addr1 (rom_addr1),
      .addr2 (rom_addr2)
  );

  twiddle_rom #(
      .FFT_SIZE (N_FFT),
      .WIDTH    (DATA_WIDTH),
      .FRAC_BITS(fft_pkg::FRAC_BITS)
  ) u_twiddle_rom (
      .clk  (clk),
      .rst_n(rst_n),
      .addr1(rom_addr1),
      .addr2(rom_addr2),
      .w1   (twiddle_rom_w1),
      .w3   (twiddle_rom_w3)
  );

  // ----------------------------------------------------------------
  // Twiddle Selection Multiplexer
  // ----------------------------------------------------------------
  cmplx_t twiddle;

  always_comb begin
    if (USE_ROM_TWIDDLE) begin
      twiddle = twiddle_rom_w1;
    end else begin
      twiddle = twiddle_baseline;
    end
  end

  // ----------------------------------------------------------------
  // Complex Multiplier on Delayed Stored Difference Path (3 Cycles)
  // ----------------------------------------------------------------
  cmplx_t twid_mult_out;
  logic   mult_valid;

  cmult #(
      .WIDTH(DATA_WIDTH),
      .FRAC_BITS(DATA_WIDTH - 1),
      .SATURATE(1'b1)
  ) u_twiddle_mult (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (in_valid),
      .valid_out(mult_valid),
      .a_re     (delay_out.re),
      .a_im     (delay_out.im),
      .b_re     (twiddle.re),
      .b_im     (twiddle.im),
      .p_re     (twid_mult_out.re),
      .p_im     (twid_mult_out.im)
  );

  // ----------------------------------------------------------------
  // Delay Control Signal and Sum Path by 3 Clock Cycles
  // ----------------------------------------------------------------
  cmplx_t sum_out_delayed;

  delay_buffer #(
      .DEPTH(3),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_sum_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1'b1),
      .din   (sum_out),
      .dout  (sum_out_delayed)
  );

  delay_buffer #(
      .DEPTH(3),
      .DATA_WIDTH(1)
  ) u_scalc_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1'b1),
      .din   (s_calc),
      .dout  (s_calc_delayed)
  );

  // ----------------------------------------------------------------
  // Stage Synchronous Output Mux
  // s_calc_delayed = 0 -> Output rotated stored difference (twid_mult_out)
  // s_calc_delayed = 1 -> Output unrotated sum path (sum_out_delayed)
  // ----------------------------------------------------------------
  always_comb begin
    if (!s_calc_delayed) begin
      out_data = twid_mult_out;
    end else begin
      out_data = sum_out_delayed;
    end
  end

  // ----------------------------------------------------------------
  // Propagate Valid Signal Delayed by 3 Clock Cycles
  // ----------------------------------------------------------------
  delay_buffer #(
      .DEPTH(3),
      .DATA_WIDTH(1)
  ) u_stg_valid_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1'b1),
      .din   (in_valid),
      .dout  (out_valid)
  );

endmodule
