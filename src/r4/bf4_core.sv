// ============================================================================
// File:        bf4_core.sv
// Description: Radix-4 Single-Path Delay Feedback (R4SDF) Butterfly Core
//              - Correct local frame masking for 4x frequency acceleration per stage
//              - Synchronized delay strides (D1, D2, D3)
//              - Pipeline-aligned multiplier and direct sum paths
//              - Support for Baseline and ROM-based twiddle generation
//              - Optimized Last-Stage bypass (omits ROM, multiplier, and pipe delays)
// ============================================================================

`timescale 1ns / 1ps

module bf4_core #(
    parameter int N_FFT           = 64,                                 // Total FFT size (power of 4)
    parameter int STAGE           = 0,                                  // Stage index (0 to STAGES_R4-1)
    parameter int DATA_WIDTH      = fft_pkg::DATA_WIDTH,
    parameter bit USE_ROM_TWIDDLE = 1'b1,                               // 0: Baseline real dynamic, 1: ROM-based
    parameter bit IS_LAST_STAGE   = (STAGE == ($clog2(N_FFT) / 2 - 1))  // 1 if final stage (DELAY == 1)
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

  localparam int STAGES_R4  = $clog2(N_FFT) / 2;
  localparam int DELAY      = N_FFT >> (2 * (STAGE + 1));  // Stride D = N / 4^(STAGE+1)
  localparam int STAGE_FRAME = 4 * DELAY;  // Local sub-transform frame size
  localparam int SHIFT_BIT  = $clog2(DELAY);  // Local stride bit offset
  localparam real TWO_PI    = 6.283185307179586;
  localparam int TOTAL_PIPE = CMULT_DELAY; // 3 cycles cmult pipeline latency

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

  always @* begin
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
  always @* begin
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
  // Structural Generation: Last Stage vs. Intermediate Stage
  // ----------------------------------------------------------------
  generate
    if (IS_LAST_STAGE) begin : gen_last_stage
      // ----------------------------------------------------------------
      // Last Stage: All twiddle factors W_4^0 = 1.
      // Omit Twiddle ROM, Complex Multiplier, and Pipeline Delays.
      // ----------------------------------------------------------------
      assign out_data = (state == 2'b11) ? sum_0 : d3_out;

      delay_buffer #(
          .DEPTH(3 * DELAY),
          .DATA_WIDTH(1)
      ) u_stg_valid_delay (
          .clk   (clk),
          .rst_n (rst_n),
          .enable(in_valid),
          .din   (in_valid),
          .dout  (out_valid)
      );

    end else begin : gen_intermediate_stage
      // ----------------------------------------------------------------
      // Intermediate Stages: Lookahead ROM + Complex Multiplier + Pipeline
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
      cmplx_t twiddle;

      always @* begin
        case (state)
          2'b10:   twiddle = twiddle_rom_w1;  // W^1k
          2'b01:   twiddle = twiddle_rom_w1;  // W^2k calculated by lookahead stride
          2'b00:   twiddle = twiddle_rom_w3;  // W^3k
          default: twiddle = twiddle_rom_w1;
        endcase
      end

      // Complex Multiplier on Delayed Feedback Path (3 Cycles Latency)
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

      // Delay Unrotated Sum Path (sum_0) and Control Signals by TOTAL_PIPE Cycles
      cmplx_t sum_0_delayed;
      logic [1:0] state_delayed;

      delay_buffer #(
          .DEPTH(TOTAL_PIPE),
          .DATA_WIDTH(2 * DATA_WIDTH)
      ) u_sum_delay (
          .clk   (clk),
          .rst_n (rst_n),
          .enable(1'b1),
          .din   (sum_0),
          .dout  (sum_0_delayed)
      );

      delay_buffer #(
          .DEPTH(TOTAL_PIPE),
          .DATA_WIDTH(2)
      ) u_state_delay (
          .clk   (clk),
          .rst_n (rst_n),
          .enable(1'b1),
          .din   (state),
          .dout  (state_delayed)
      );

      // Stage Synchronous Output Mux (Pipeline Aligned)
      assign out_data = (state_delayed == 2'b11) ? sum_0_delayed : twid_mult_out;

      // Propagate Valid Signal Delayed by (3 * DELAY + TOTAL_PIPE) Cycles
      delay_buffer #(
          .DEPTH(3 * DELAY + TOTAL_PIPE),
          .DATA_WIDTH(1)
      ) u_stg_valid_delay (
          .clk   (clk),
          .rst_n (rst_n),
          .enable(in_valid),
          .din   (in_valid),
          .dout  (out_valid)
      );
    end
  endgenerate

endmodule
