// ============================================================================
// File:        r22_twiddle_stage.sv
// Module:      r22_twiddle_stage
// Description: Radix-2^2 SDF Inter-Stage Twiddle Factor Multiplication Unit
//              with Twiddle ROM Lookahead Optimization
//
// Architecture & Theory of Operation:
//   In a Radix-2^2 Single-path Delay Feedback (R22SDF) FFT, full complex twiddle
//   multiplications only occur at the end of each Radix-2^2 stage pair (after
//   Butterfly II), rather than after every butterfly.
//
//   For a current sub-FFT size N, the stream is divided into 4 quarters
//   (blocks of size N/4) tracked by counter `cnt_tw`:
//     - Block 0 (2'b00): Twiddle factor is W_N^0 = 1  --> Multiplication BYPASS
//     - Block 1 (2'b01): Twiddle factor is W_N^(2k)   --> ROM Addr = 2 * k
//     - Block 2 (2'b10): Twiddle factor is W_N^(k)    --> ROM Addr = k
//     - Block 3 (2'b11): Twiddle factor is W_N^(3k)   --> ROM Addr = 3 * k
//     where k = cnt_tw[log2(N)-3 : 0] runs from 0 to (N/4 - 1).
//
// Key Features:
//   1. ROM Lookahead Addressing:
//      - The ROM address is computed for the *next* incoming sample
//        (`cnt_tw_next`). Because synchronous ROM read has a 1-clock latency,
//        the required twiddle factor arrives in the exact cycle that `in_data`
//        arrives, saving 1 full clock cycle of pipeline latency.
//   2. Trivial Multiplication Bypass:
//      - Multiplications by W_N^0 = 1 (Block 0 or k = 0) are dynamically bypassed
//        to eliminate arithmetic rounding error and reduce dynamic switching power.
//   3. Pipeline Matching:
//      - Multiplier latency: CMULT_DELAY cycles.
//      - Total non-bypassed stage latency = CMULT_DELAY cycles (reduced from 1+CMULT_DELAY).
//      - Bypassed samples pass through a matching shift register (`bypass_pipe`)
//        to guarantee uniform stream throughput and latency.
//   4. Last-Stage Optimization:
//      - When IS_LAST_STAGE = 1 (N = 4), all twiddles reduce to unity, so the
//        entire multiplier and ROM are omitted at elaboration (zero latency).
//
// Parameters:
//   - N             : Current sub-FFT size of this stage pair (power of 4)
//   - DATA_WIDTH    : Bit width of real and imaginary data components
//   - IS_LAST_STAGE : Set to 1 if this is the final 4-point stage (bypasses logic)
//   - CMULT_DELAY   : Latency cycles of the complex multiplier core (`cmult`)
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module r22_twiddle_stage #(
    parameter int N = 16,
    parameter int DATA_WIDTH = 16,
    parameter bit IS_LAST_STAGE = 0,
    parameter int CMULT_DELAY = fft_pkg::CMULT_DELAY
) (
    input  logic            clk,
    input  logic            rst_n,
    input  logic            in_valid,
    input  fft_pkg::cmplx_t in_data,
    output logic            out_valid,
    output fft_pkg::cmplx_t out_data
);
  generate
    if (IS_LAST_STAGE) begin : gen_last_stage
      assign out_valid = in_valid;
      assign out_data  = in_data;
    end else begin : gen_twiddle_stage
      // ----------------------------------------------------------------------
      // Sample Tracking & ROM Lookahead Index Calculation
      // ----------------------------------------------------------------------
      logic [$clog2(N)-1:0] cnt_tw;
      logic [$clog2(N)-1:0] cnt_tw_next;

      // Lookahead index: If in_valid is asserted, sample index advances for next cycle;
      // otherwise, it holds to ensure ROM continues requesting twiddle for expected sample.
      assign cnt_tw_next = in_valid ? (cnt_tw + 1'b1) : cnt_tw;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          cnt_tw <= '0;
        end else begin
          cnt_tw <= cnt_tw_next;
        end
      end

      // ----------------------------------------------------------------------
      // Current Sample: Bypass Control
      // ----------------------------------------------------------------------
      logic [1:0] block;
      logic [$clog2(N)-3:0] k_idx;
      logic bypass_mult;

      assign block       = cnt_tw[$clog2(N)-1 : $clog2(N)-2];
      assign k_idx       = cnt_tw[$clog2(N)-3 : 0];
      assign bypass_mult = (block == 2'b00) || (k_idx == '0);

      // ----------------------------------------------------------------------
      // Next Sample: Lookahead ROM Address Generation
      // ----------------------------------------------------------------------
      logic [1:0] next_block;
      logic [$clog2(N)-3:0] next_k_idx;
      logic [$clog2(N)-1:0] rom_addr;

      assign next_block = cnt_tw_next[$clog2(N)-1 : $clog2(N)-2];
      assign next_k_idx = cnt_tw_next[$clog2(N)-3 : 0];

      always_comb begin
        if ((next_block == 2'b00) || (next_k_idx == '0)) begin
          rom_addr = '0;
        end else begin
          case (next_block)
            2'b01:   rom_addr = 2 * next_k_idx;
            2'b10:   rom_addr = next_k_idx;
            2'b11:   rom_addr = 3 * next_k_idx;
            default: rom_addr = '0;
          endcase
        end
      end

      // ----------------------------------------------------------------------
      // Synchronous Twiddle Factor ROM (1-cycle read latency)
      // ----------------------------------------------------------------------
      fft_pkg::cmplx_t twiddle_w;

      twiddle_rom #(
          .FFT_SIZE (N),
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

      // ----------------------------------------------------------------------
      // Complex Multiplier Core (CMULT_DELAY latency)
      // twiddle_w and in_data arrive aligned in the same cycle.
      // ----------------------------------------------------------------------
      fft_pkg::cmplx_t mult_out;
      logic cmult_vld;

      cmult #(
          .WIDTH    (DATA_WIDTH),
          .FRAC_BITS(fft_pkg::FRAC_BITS),
          .SATURATE (1'b1)
      ) u_cmult (
          .clk      (clk),
          .rst_n    (rst_n),
          .valid_in (in_valid && !bypass_mult),
          .valid_out(cmult_vld),
          .a_re     (in_data.re),
          .a_im     (in_data.im),
          .b_re     (twiddle_w.re),
          .b_im     (twiddle_w.im),
          .p_re     (mult_out.re),
          .p_im     (mult_out.im)
      );

      // ----------------------------------------------------------------------
      // Bypass & Valid Pipeline Matching (CMULT_DELAY cycles)
      // ----------------------------------------------------------------------
      fft_pkg::cmplx_t bypass_pipe[0:CMULT_DELAY-1];
      logic            bypass_flag_pipe[0:CMULT_DELAY-1];
      logic            vld_pipe_mult[0:CMULT_DELAY-1];

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          for (int i = 0; i < CMULT_DELAY; i++) begin
            bypass_pipe[i]      <= '0;
            bypass_flag_pipe[i] <= 1'b0;
            vld_pipe_mult[i]    <= 1'b0;
          end
        end else begin
          bypass_pipe[0]      <= in_data;
          bypass_flag_pipe[0] <= bypass_mult;
          vld_pipe_mult[0]    <= in_valid;

          for (int i = 1; i < CMULT_DELAY; i++) begin
            bypass_pipe[i]      <= bypass_pipe[i-1];
            bypass_flag_pipe[i] <= bypass_flag_pipe[i-1];
            vld_pipe_mult[i]    <= vld_pipe_mult[i-1];
          end
        end
      end

      assign out_valid = vld_pipe_mult[CMULT_DELAY-1];
      assign out_data  = bypass_flag_pipe[CMULT_DELAY-1] ? bypass_pipe[CMULT_DELAY-1] : mult_out;
    end
  endgenerate
endmodule
