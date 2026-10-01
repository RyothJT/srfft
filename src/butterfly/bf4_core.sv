// ============================================================================
// File:        bf4_core.sv
// Description: Radix-4 Single-Path Delay Feedback (R4SDF) Butterfly Core
//              - Correct local frame masking for 4x frequency acceleration per stage
//              - Synchronized delay strides (D1, D2, D3)
//              - Pipeline-aligned multiplier and direct sum paths
//              - Support for Baseline and ROM-based twiddle generation
// ============================================================================

`timescale 1ns / 1ps

module bf4_core #(
    parameter int N_FFT           = 64,                   // Total FFT size (power of 4)
    parameter int STAGE           = 0,                    // Stage index (0 to STAGES_R4-1)
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

  localparam int STAGES_R4 = $clog2(N_FFT) / 2;
  localparam int DELAY = N_FFT >> (2 * (STAGE + 1));  // Stride D = N / 4^(STAGE+1)
  localparam int STAGE_FRAME = 4 * DELAY;  // Local sub-transform frame size
  localparam int SHIFT_BIT = $clog2(DELAY);  // Local stride bit offset
  localparam real TWO_PI = 6.283185307179586;

  // ----------------------------------------------------------------
  // Stage Local Sample Counter
  // Resets per local STAGE_FRAME to enforce frequency acceleration
  // ----------------------------------------------------------------
  logic [$clog2(N_FFT)-1:0] stg_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stg_cnt <= '0;
    end else if (in_valid) begin
      stg_cnt <= stg_cnt + 1'b1;
    end
  end

  // Commutator control state (00, 01, 10, or 11) relative to local DELAY
  logic [1:0] state;
  assign state = (stg_cnt >> SHIFT_BIT) & 2'b11;

  // ----------------------------------------------------------------
  // Single-Path Delay Feedback Buffers (3 Strides of DELAY)
  // ----------------------------------------------------------------
  cmplx_t d1_in, d1_out;
  cmplx_t d2_in, d2_out;
  cmplx_t d3_in, d3_out;

  delay_buffer #(
      .DEPTH(DELAY),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_delay1 (
      .clk(clk),
      .rst_n(rst_n),
      .enable(in_valid),
      .din(d1_in),
      .dout(d1_out)
  );

  delay_buffer #(
      .DEPTH(DELAY),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_delay2 (
      .clk(clk),
      .rst_n(rst_n),
      .enable(in_valid),
      .din(d2_in),
      .dout(d2_out)
  );

  delay_buffer #(
      .DEPTH(DELAY),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_delay3 (
      .clk(clk),
      .rst_n(rst_n),
      .enable(in_valid),
      .din(d3_in),
      .dout(d3_out)
  );

  // ----------------------------------------------------------------
  // Butterfly Input Wiring & Radix-4 Math Combiner
  // ----------------------------------------------------------------
  cmplx_t bf_a, bf_b, bf_c, bf_d;
  cmplx_t sum_0, sum_1, sum_2, sum_3;

  always_comb begin
    bf_a = d3_out;  // Oldest sample (delayed by 3*D)
    bf_b = d2_out;  // Delayed by 2*D
    bf_c = d1_out;  // Delayed by 1*D
    bf_d = in_data;  // Current input sample (0 delay)

    // S0 = A + B + C + D
    sum_0.re = (bf_a.re + bf_c.re) + (bf_b.re + bf_d.re);
    sum_0.im = (bf_a.im + bf_c.im) + (bf_b.im + bf_d.im);

    // S1 = (A - C) - j*(B - D)
    sum_1.re = (bf_a.re - bf_c.re) + (bf_b.im - bf_d.im);
    sum_1.im = (bf_a.im - bf_c.im) - (bf_b.re - bf_d.re);

    // S2 = (A + C) - (B + D)
    sum_2.re = (bf_a.re + bf_c.re) - (bf_b.re + bf_d.re);
    sum_2.im = (bf_a.im + bf_c.im) - (bf_b.im + bf_d.im);

    // S3 = (A - C) + j*(B - D)
    sum_3.re = (bf_a.re - bf_c.re) - (bf_b.im - bf_d.im);
    sum_3.im = (bf_a.im - bf_c.im) + (bf_b.re - bf_d.re);
  end

  // ----------------------------------------------------------------
  // SDF Commutator Input Routing Logic
  // ----------------------------------------------------------------
  always_comb begin
    case (state)
      // States 00, 01, 10: Shift incoming samples into delay line
      2'b00, 2'b01, 2'b10: begin
        d1_in = in_data;
        d2_in = d1_out;
        d3_in = d2_out;
      end

      // State 11: Active Butterfly Calculation - Feed unrotated difference outputs into delay lines
      2'b11: begin
        d1_in = sum_1;
        d2_in = sum_2;
        d3_in = sum_3;
      end
    endcase
  end

  // ----------------------------------------------------------------
  // Method 1: Dynamic Twiddle Factor Generator (Baseline)
  // Scaled relative to local stage frame indices
  // ----------------------------------------------------------------
  cmplx_t twiddle_baseline;

  always_comb begin
    int k, sub_idx;
    real angle;

    case (state)
      2'b10:   sub_idx = 1;  // S1 exiting D3 during state 10
      2'b01:   sub_idx = 2;  // S2 exiting D3 during state 01
      2'b00:   sub_idx = 3;  // S3 exiting D3 during state 00
      default: sub_idx = 0;
    endcase

    // k index cycles over the stage-local frame duration (DELAY)
    k = (stg_cnt & (DELAY - 1)) * sub_idx * (1 << (2 * STAGE));
    angle = -TWO_PI * real'(k) / real'(N_FFT);

    twiddle_baseline.re = $rtoi($cos(angle) * 32767.0);
    twiddle_baseline.im = $rtoi($sin(angle) * 32767.0);
  end

  // ----------------------------------------------------------------
  // Method 2: ROM-Based Twiddle Factor Generation (R4 Lookahead)
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

  // Mux ROM output based on active state sub-index (W^1k, W^2k, W^3k)
  cmplx_t twiddle_rom_selected;

  always_comb begin
    case (state)
      2'b10:   twiddle_rom_selected = twiddle_rom_w1;  // W^1k
      2'b01:   twiddle_rom_selected = twiddle_rom_w1;  // W^2k calculated by lookahead stride
      2'b00:   twiddle_rom_selected = twiddle_rom_w3;  // W^3k
      default: twiddle_rom_selected = twiddle_rom_w1;
    endcase
  end

  // ----------------------------------------------------------------
  // Twiddle Selection Multiplexer
  // ----------------------------------------------------------------
  cmplx_t twiddle;
  wire signed [15:0] diff_re;
  wire signed [15:0] diff_im;
  reg signed [31:0] diff_re_sum;
  reg signed [31:0] diff_im_sum;

  assign diff_re = twiddle_rom_selected.re - twiddle_baseline.re;
  assign diff_im = twiddle_rom_selected.im - twiddle_baseline.im;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      diff_re_sum <= 0;
      diff_im_sum <= 0;
    end else begin
      diff_re_sum <= diff_re_sum + diff_re;
      diff_im_sum <= diff_im_sum + diff_im;
    end
  end

  always_comb begin
    if (USE_ROM_TWIDDLE) begin
      twiddle = twiddle_rom_selected;
    end else begin
      twiddle = twiddle_baseline;
    end
  end

  // ----------------------------------------------------------------
  // Complex Multiplier on Delayed Feedback Path (3 Cycles Latency)
  // Multiplies difference path samples exiting d3_out
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
      .a_re     (d3_out.re),
      .a_im     (d3_out.im),
      .b_re     (twiddle.re),
      .b_im     (twiddle.im),
      .p_re     (twid_mult_out.re),
      .p_im     (twid_mult_out.im)
  );

  // ----------------------------------------------------------------
  // Delay Unrotated Sum Path (sum_0) and Control Signals by 3 Cycles
  // ----------------------------------------------------------------
  cmplx_t sum_0_delayed;
  logic [1:0] state_delayed;

  delay_buffer #(
      .DEPTH(3),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_sum_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1'b1),
      .din   (sum_0),
      .dout  (sum_0_delayed)
  );

  delay_buffer #(
      .DEPTH(3),
      .DATA_WIDTH(2)
  ) u_state_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1'b1),
      .din   (state),
      .dout  (state_delayed)
  );

  // ----------------------------------------------------------------
  // Stage Synchronous Output Mux (Pipeline Aligned)
  // state_delayed = 11 -> Output unrotated sum_0_delayed
  // state_delayed = 00, 01, 10 -> Output rotated feedback outputs (twid_mult_out)
  // ----------------------------------------------------------------
  always_comb begin
    if (state_delayed == 2'b11) begin
      out_data = sum_0_delayed;
    end else begin
      out_data = twid_mult_out;
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
