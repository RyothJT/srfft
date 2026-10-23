// ============================================================================
// File:        r22_twiddle_stage.sv
// Module:      r22_twiddle_stage
// Description: Radix-2^2 SDF Inter-Stage Twiddle Factor Multiplication Unit
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
//   1. Trivial Multiplication Bypass:
//      - Multiplications by W_N^0 = 1 (Block 0 or k = 0) are dynamically bypassed
//        to eliminate arithmetic rounding error and reduce dynamic switching power.
//   2. Pipeline Matching:
//      - ROM read latency: 1 clock cycle (matched by `in_data_d1`).
//      - Multiplier latency: CMULT_DELAY cycles.
//      - Total non-bypassed stage latency = 1 + CMULT_DELAY cycles.
//      - Bypassed samples pass through a matching shift register (`bypass_pipe`)
//        to guarantee uniform stream throughput and latency.
//   3. Last-Stage Optimization:
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
      logic [$clog2(N)-1:0] cnt_tw;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          cnt_tw <= '0;
        end else if (in_valid) begin
          cnt_tw <= cnt_tw + 1'b1;
        end
      end

      logic [1:0] block;
      logic [$clog2(N)-3:0] k_idx;
      assign block = cnt_tw[$clog2(N)-1:$clog2(N)-2];
      assign k_idx = cnt_tw[$clog2(N)-3:0];

      logic [$clog2(N)-1:0] rom_addr;
      logic bypass_mult;

      always_comb begin
        if ((block == 2'b00) || (k_idx == '0)) begin
          rom_addr    = '0;
          bypass_mult = 1'b1;
        end else begin
          bypass_mult = 1'b0;
          case (block)
            2'b01:   rom_addr = 2 * k_idx;
            2'b10:   rom_addr = k_idx;
            2'b11:   rom_addr = 3 * k_idx;
            default: rom_addr = '0;
          endcase
        end
      end

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

      fft_pkg::cmplx_t in_data_d1;
      logic in_vld_d1, bypass_d1;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          in_data_d1 <= '0;
          in_vld_d1  <= 1'b0;
          bypass_d1  <= 1'b0;
        end else begin
          in_data_d1 <= in_data;
          in_vld_d1  <= in_valid;
          bypass_d1  <= bypass_mult;
        end
      end

      fft_pkg::cmplx_t mult_out;
      logic cmult_vld;

      cmult #(
          .WIDTH    (DATA_WIDTH),
          .FRAC_BITS(fft_pkg::FRAC_BITS),
          .SATURATE (1'b1)
      ) u_cmult (
          .clk      (clk),
          .rst_n    (rst_n),
          .valid_in (in_vld_d1 && !bypass_d1),
          .valid_out(cmult_vld),
          .a_re     (in_data_d1.re),
          .a_im     (in_data_d1.im),
          .b_re     (twiddle_w.re),
          .b_im     (twiddle_w.im),
          .p_re     (mult_out.re),
          .p_im     (mult_out.im)
      );

      fft_pkg::cmplx_t bypass_pipe[0:CMULT_DELAY-1];
      logic bypass_flag_pipe[0:CMULT_DELAY-1];

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          for (int i = 0; i < CMULT_DELAY; i++) begin
            bypass_pipe[i]      <= '0;
            bypass_flag_pipe[i] <= 1'b0;
          end
        end else begin
          bypass_pipe[0]      <= in_data_d1;
          bypass_flag_pipe[0] <= bypass_d1;
          for (int i = 1; i < CMULT_DELAY; i++) begin
            bypass_pipe[i]      <= bypass_pipe[i-1];
            bypass_flag_pipe[i] <= bypass_flag_pipe[i-1];
          end
        end
      end

      logic [CMULT_DELAY-1:0] vld_pipe_mult;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          vld_pipe_mult <= '0;
        end else begin
          vld_pipe_mult <= {vld_pipe_mult[CMULT_DELAY-2:0], in_vld_d1};
        end
      end

      assign out_valid = vld_pipe_mult[CMULT_DELAY-1];
      assign out_data  = bypass_flag_pipe[CMULT_DELAY-1] ? bypass_pipe[CMULT_DELAY-1] : mult_out;
    end
  endgenerate
endmodule
