// ============================================================================
// File:        r22_stage_pair.sv
// Description: Radix-2^2 Single-path Delay Feedback (R22SDF) Stage Pair
//              Combines Butterfly I, Butterfly II (-j logic), and Twiddle Cmult
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module r22_stage_pair #(
    parameter int N             = 16,
    parameter int DATA_WIDTH    = fft_pkg::DATA_WIDTH,
    parameter bit IS_LAST_STAGE = (N == 4)              // N=4 stage has all twiddles = 1
) (
    input logic clk,
    input logic rst_n,

    input logic            in_valid,
    input fft_pkg::cmplx_t in_data,

    output logic            out_valid,
    output fft_pkg::cmplx_t out_data
);

  localparam int D1 = N / 2;
  localparam int D2 = (N >= 4) ? (N / 4) : 1;

  // ================================================================
  // 1. Butterfly I: Delay D1 = N/2
  // ================================================================
  logic [$clog2(N)-1:0] cnt1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt1 <= '0;
    end else if (in_valid) begin
      cnt1 <= cnt1 + 1'b1;
    end
  end

  logic bf1_sel;
  assign bf1_sel = cnt1[$clog2(N)-1];  // 0: Fill buffer, 1: Butterfly computation

  cmplx_t bf1_fifo_in, bf1_fifo_out;
  cmplx_t bf1_out;

  always_comb begin
    if (!bf1_sel) begin
      bf1_fifo_in = in_data;
      bf1_out     = bf1_fifo_out;
    end else begin
      bf1_fifo_in.re = bf1_fifo_out.re - in_data.re;
      bf1_fifo_in.im = bf1_fifo_out.im - in_data.im;

      bf1_out.re     = bf1_fifo_out.re + in_data.re;
      bf1_out.im     = bf1_fifo_out.im + in_data.im;
    end
  end

  delay_buffer #(
      .DEPTH(D1),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_bf1_fifo (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(in_valid),
      .din   (bf1_fifo_in),
      .dout  (bf1_fifo_out)
  );

  // Valid pipeline for BF1 (latency D1)
  logic [D1-1:0] vld_pipe1;
  generate
    if (D1 > 1) begin : gen_vld_pipe1_multi
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          vld_pipe1 <= '0;
        end else begin
          vld_pipe1 <= {vld_pipe1[D1-2:0], in_valid};
        end
      end
    end else begin : gen_vld_pipe1_single
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          vld_pipe1 <= '0;
        end else begin
          vld_pipe1 <= in_valid;
        end
      end
    end
  endgenerate

  logic bf1_valid;
  assign bf1_valid = vld_pipe1[D1-1];

  // ================================================================
  // 2. Butterfly II: Delay D2 = N/4 with Trivial -j Logic
  // ================================================================
  logic [$clog2(N)-1:0] cnt2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt2 <= '0;
    end else if (bf1_valid) begin
      cnt2 <= cnt2 + 1'b1;
    end
  end

  logic bf2_sel, bf2_mul_neg_j;
  assign bf2_sel       = cnt2[$clog2(N)-2];
  assign bf2_mul_neg_j = (cnt2[$clog2(N)-1:$clog2(N)-2] == 2'b11);

  // Apply trivial -j rotation: (re + j*im) * (-j) = im - j*re
  cmplx_t bf2_in_rot;
  always_comb begin
    if (bf2_mul_neg_j) begin
      bf2_in_rot.re = bf1_out.im;
      bf2_in_rot.im = -bf1_out.re;
    end else begin
      bf2_in_rot = bf1_out;
    end
  end

  cmplx_t bf2_fifo_in, bf2_fifo_out;
  cmplx_t bf2_out;

  always_comb begin
    if (!bf2_sel) begin
      bf2_fifo_in = bf2_in_rot;
      bf2_out     = bf2_fifo_out;
    end else begin
      bf2_fifo_in.re = bf2_fifo_out.re - bf2_in_rot.re;
      bf2_fifo_in.im = bf2_fifo_out.im - bf2_in_rot.im;

      bf2_out.re     = bf2_fifo_out.re + bf2_in_rot.re;
      bf2_out.im     = bf2_fifo_out.im + bf2_in_rot.im;
    end
  end

  delay_buffer #(
      .DEPTH(D2),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_bf2_fifo (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(bf1_valid),
      .din   (bf2_fifo_in),
      .dout  (bf2_fifo_out)
  );

  // Valid pipeline for BF2 (latency D2)
  logic [D2-1:0] vld_pipe2;
  generate
    if (D2 > 1) begin : gen_vld_pipe2_multi
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          vld_pipe2 <= '0;
        end else begin
          vld_pipe2 <= {vld_pipe2[D2-2:0], bf1_valid};
        end
      end
    end else begin : gen_vld_pipe2_single
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          vld_pipe2 <= '0;
        end else begin
          vld_pipe2 <= bf1_valid;
        end
      end
    end
  endgenerate

  logic bf2_valid;
  assign bf2_valid = vld_pipe2[D2-1];

  // ================================================================
  // 3. Twiddle Multiplication (W_N^k)
  // ================================================================
  generate
    if (IS_LAST_STAGE) begin : gen_last_stage
      // N=4 terminal stage: twiddles are all 1.0 (no cmult needed)
      assign out_valid = bf2_valid;
      assign out_data  = bf2_out;

    end else begin : gen_twiddle_stage
      localparam int CMULT_DELAY = 3;  // 3 cycles latency for cmult

      logic [$clog2(N)-1:0] cnt_tw;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          cnt_tw <= '0;
        end else if (bf2_valid) begin
          cnt_tw <= cnt_tw + 1'b1;
        end
      end

      // Twiddle address calculation
      logic [1:0] block;
      logic [$clog2(N)-3:0] k_idx;
      assign block = cnt_tw[$clog2(N)-1:$clog2(N)-2];
      assign k_idx = cnt_tw[$clog2(N)-3:0];

      logic [$clog2(N)-1:0] rom_addr;
      logic bypass_mult;

      always_comb begin
        // Whenever k_idx == 0, W_N^0 = 1.0 for ALL blocks -> bypass multiplier!
        if ((block == 2'b00) || (k_idx == '0)) begin
          rom_addr    = '0;
          bypass_mult = 1'b1;
        end else begin
          bypass_mult = 1'b0;
          case (block)
            2'b01:   rom_addr = 2 * k_idx;  // W_N^(2k)
            2'b10:   rom_addr = k_idx;  // W_N^k
            2'b11:   rom_addr = 3 * k_idx;  // W_N^(3k)
            default: rom_addr = '0;
          endcase
        end
      end

      cmplx_t twiddle_w;
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

      // Register input to align with 1-cycle ROM latency
      cmplx_t bf2_out_d1;
      logic bf2_vld_d1, bypass_d1;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          bf2_out_d1 <= '0;
          bf2_vld_d1 <= 1'b0;
          bypass_d1  <= 1'b0;
        end else begin
          bf2_out_d1 <= bf2_out;
          bf2_vld_d1 <= bf2_valid;
          bypass_d1  <= bypass_mult;
        end
      end

      // Pipelined complex multiplier (3 cycles latency from bf2_out_d1)
      cmplx_t mult_out;
      logic   cmult_vld;

      cmult #(
          .WIDTH    (DATA_WIDTH),
          .FRAC_BITS(fft_pkg::FRAC_BITS),
          .SATURATE (1'b1)
      ) u_cmult (
          .clk      (clk),
          .rst_n    (rst_n),
          .valid_in (bf2_vld_d1 && !bypass_d1),
          .valid_out(cmult_vld),
          .a_re     (bf2_out_d1.re),
          .a_im     (bf2_out_d1.im),
          .b_re     (twiddle_w.re),
          .b_im     (twiddle_w.im),
          .p_re     (mult_out.re),
          .p_im     (mult_out.im)
      );

      // 3-cycle delay alignment line for bypassed data (matches 3-cycle cmult)
      cmplx_t bypass_pipe[0:CMULT_DELAY-1];
      logic bypass_flag_pipe[0:CMULT_DELAY-1];

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          for (int i = 0; i < CMULT_DELAY; i++) begin
            bypass_pipe[i]      <= '0;
            bypass_flag_pipe[i] <= 1'b0;
          end
        end else begin
          bypass_pipe[0]      <= bf2_out_d1;
          bypass_flag_pipe[0] <= bypass_d1;
          for (int i = 1; i < CMULT_DELAY; i++) begin
            bypass_pipe[i]      <= bypass_pipe[i-1];
            bypass_flag_pipe[i] <= bypass_flag_pipe[i-1];
          end
        end
      end

      // 3-cycle valid tracker (matches 3-cycle cmult)
      logic [CMULT_DELAY-1:0] vld_pipe_mult;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          vld_pipe_mult <= '0;
        end else begin
          vld_pipe_mult <= {vld_pipe_mult[CMULT_DELAY-2:0], bf2_vld_d1};
        end
      end

      assign out_valid = vld_pipe_mult[CMULT_DELAY-1];
      assign out_data  = bypass_flag_pipe[CMULT_DELAY-1] ? bypass_pipe[CMULT_DELAY-1] : mult_out;
    end
  endgenerate

endmodule
