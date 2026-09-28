// ============================================================================
// File:        bfsr_core.sv
// Description: Split-Radix Single-Path Delay Feedback (SDF) Butterfly Core
//              - Corrected SDF commutator alignment and delay line depths
//              - Continuous data flow without empty output slots
//              - Golden ROM / Baseline twiddle selection retained
// ============================================================================

`timescale 1ns / 1ps

module bfsr_core #(
    parameter int N_FFT           = 64,                   // Total FFT size
    parameter int STAGE           = 0,                    // Stage index
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

  localparam int DELAY = N_FFT >> (2 * (STAGE + 1));  // Stride D = N / 4^(STAGE+1)
  localparam int SHIFT_BIT = $clog2(DELAY);
  localparam real TWO_PI = 6.283185307179586;

  // ----------------------------------------------------------------
  // Stage Local Sample Counter
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
  // Single-Path Delay Feedback Buffers (Cascaded 1*DELAY Units)
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
  // Split-Radix Intermediate Butterfly Logic
  // A = d3_out (x0), B = d2_out (x1), C = d1_out (x2), D = in_data (x3)
  // ----------------------------------------------------------------
  cmplx_t bf_a, bf_b, bf_c, bf_d;
  cmplx_t sum_0, sum_1, sum_2, sum_3;

  always_comb begin
    bf_a = d3_out;  // Oldest sample (delayed by 3*D)
    bf_b = d2_out;  // Delayed by 2*D
    bf_c = d1_out;  // Delayed by 1*D
    bf_d = in_data;  // Current input sample

    // y0 = (A + C) + (B + D)  [Direct sum - emitted immediately in state 11]
    sum_0.re = (bf_a.re + bf_c.re) + (bf_b.re + bf_d.re);
    sum_0.im = (bf_a.im + bf_c.im) + (bf_b.im + bf_d.im);

    // y1 = (A + C) - (B + D)  [Bypasses twiddle multiplication]
    sum_2.re = (bf_a.re + bf_c.re) - (bf_b.re + bf_d.re);
    sum_2.im = (bf_a.im + bf_c.im) - (bf_b.im + bf_d.im);

    // z1 = (A - C) - j*(B - D) [To be rotated by W_N^k]
    sum_1.re = (bf_a.re - bf_c.re) + (bf_b.im - bf_d.im);
    sum_1.im = (bf_a.im - bf_c.im) - (bf_b.re - bf_d.re);

    // z3 = (A - C) + j*(B - D) [To be rotated by W_N^(3k)]
    sum_3.re = (bf_a.re - bf_c.re) - (bf_b.im - bf_d.im);
    sum_3.im = (bf_a.im - bf_c.im) + (bf_b.re - bf_d.re);
  end

  // ----------------------------------------------------------------
  // SDF Commutator Routing Logic
  // ----------------------------------------------------------------
  always_comb begin
    case (state)
      // States 00, 01, 10: Shift inputs through cascaded DELAY stages
      2'b00, 2'b01, 2'b10: begin
        d1_in = in_data;
        d2_in = d1_out;
        d3_in = d2_out;
      end

      // State 11: Active Butterfly Calculation
      // Load z3 into d3, y1 into d2, z1 into d1
      2'b11: begin
        d1_in = sum_1;  // z1 branch
        d2_in = sum_2;  // y1 branch
        d3_in = sum_3;  // z3 branch
      end
    endcase
  end

  // ----------------------------------------------------------------
  // Active Path Operand Selection
  // ----------------------------------------------------------------
  cmplx_t mult_operand_a;

  always_comb begin
    case (state)
      2'b00:   mult_operand_a = d1_out;  // z1 pops out after 1*D delay
      2'b01:   mult_operand_a = d2_out;  // y1 pops out after 2*D delay
      2'b10:   mult_operand_a = d3_out;  // z3 pops out after 3*D delay
      default: mult_operand_a = '0;
    endcase
  end

  // ----------------------------------------------------------------
  // Method 1: Dynamic Split-Radix Twiddle Factor Generator (Baseline)
  // ----------------------------------------------------------------
  cmplx_t twiddle_baseline;

  // always_comb begin
  //   int k, sub_idx;
  //   real angle;

  //   case (state)
  //     2'b00:   sub_idx = 1;  // W_N^k for z1 branch
  //     2'b01:   sub_idx = 0;  // Unity twiddle for y1 (bypass)
  //     2'b10:   sub_idx = 3;  // W_N^(3k) for z3 branch
  //     default: sub_idx = 0;
  //   endcase

  //   k = (stg_cnt & (DELAY - 1)) * sub_idx * (1 << (2 * STAGE));
  //   angle = -TWO_PI * real'(k) / real'(N_FFT);

  //   twiddle_baseline.re = $rtoi($cos(angle) * real'((1 << (DATA_WIDTH - 1)) - 1));
  //   twiddle_baseline.im = $rtoi($sin(angle) * real'((1 << (DATA_WIDTH - 1)) - 1));
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

  // Mux ROM output based on active state sub-index
  cmplx_t twiddle_rom_selected;

  always_comb begin
    case (state)
      2'b00: twiddle_rom_selected = twiddle_rom_w1;  // W^1k for z1 branch
      2'b10: twiddle_rom_selected = twiddle_rom_w3;  // W^3k for z3 branch
      default: begin  // States 01 and 11 (y1 bypass & sum_0 direct emit)
        twiddle_rom_selected.re = (1 << (DATA_WIDTH - 1)) - 1;  // Unity real (+1 in Q0.15)
        twiddle_rom_selected.im = '0;  // Unity imag (0)
      end
    endcase
  end

  // ----------------------------------------------------------------
  // Twiddle Selection Multiplexer
  // ----------------------------------------------------------------
  cmplx_t twiddle;
  wire [DATA_WIDTH-1:0] diff_re;
  wire [DATA_WIDTH-1:0] diff_im;

  assign diff_re = twiddle_rom_selected.re - twiddle_baseline.re;
  assign diff_im = twiddle_rom_selected.im - twiddle_baseline.im;

  always_comb begin
    if (USE_ROM_TWIDDLE) begin
      twiddle = twiddle_rom_selected;
    end else begin
      twiddle = twiddle_baseline;
    end
  end

  // ----------------------------------------------------------------
  // Complex Multiplier on Delayed Feedback Path (3 Cycles Latency)
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
      .a_re     (mult_operand_a.re),
      .a_im     (mult_operand_a.im),
      .b_re     (twiddle.re),
      .b_im     (twiddle.im),
      .p_re     (twid_mult_out.re),
      .p_im     (twid_mult_out.im)
  );

  // ----------------------------------------------------------------
  // Pipeline Delay Alignments (3 Cycles Latency)
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
  // ----------------------------------------------------------------
  always_comb begin
    if (state_delayed == 2'b11) begin
      out_data = sum_0_delayed;
    end else begin
      out_data = twid_mult_out;
    end
  end

  // ----------------------------------------------------------------
  // Valid Signal Propagation
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
