`timescale 1ns / 1ps
import fft_pkg::*;

module split_radix_sdf_stage #(
    parameter int N          = 16,                  // Stage frame size
    parameter int DATA_WIDTH = fft_pkg::DATA_WIDTH
) (
    input logic clk,
    input logic rst_n,

    // Stream interface
    input logic            in_valid,
    input fft_pkg::cmplx_t in_data,

    output logic            out_valid,
    output fft_pkg::cmplx_t out_data
);

  // ----------------------------------------------------------------
  // Control & Strides
  // ----------------------------------------------------------------
  localparam int D = N / 4;   // Quarter-frame stride
  localparam int D2 = 2 * D;  // Half-frame stride
  localparam int D3 = 3 * D;  // Three-quarter stride
  localparam int K_MOD = (N >= 4) ? (N / 4) : 1;
  localparam int PIPE_LAT = 4; // 1 cycle ROM + 3 cycles cmult

  logic [$clog2(N)-1:0] cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt <= '0;
    end else if (in_valid) begin
      cnt <= cnt + 1'b1;
    end
  end

  // Active only during Quadrant 3 when all 4 samples are present
  logic is_quad3;
  assign is_quad3 = (cnt >= D3);

  // ----------------------------------------------------------------
  // 1. Parallel Alignment Delay Buffers (3D, 2D, 1D)
  // ----------------------------------------------------------------
  cmplx_t x0_sync, x1_sync, x2_sync;

  // x0 arrived at t=0 -> delayed by 3D to meet t=3D
  delay_buffer #(
      .DEPTH(D3),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_delay_x0 (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(in_valid),
      .din   (in_data),
      .dout  (x0_sync)
  );

  // x1 arrived at t=D -> delayed by 2D to meet t=3D
  delay_buffer #(
      .DEPTH(D2),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_delay_x1 (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(in_valid),
      .din   (in_data),
      .dout  (x1_sync)
  );

  // x2 arrived at t=2D -> delayed by 1D to meet t=3D
  delay_buffer #(
      .DEPTH(D),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_delay_x2 (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(in_valid),
      .din   (in_data),
      .dout  (x2_sync)
  );

  // ----------------------------------------------------------------
  // 2. ROM Twiddle Lookup
  // ----------------------------------------------------------------
  logic [$clog2(N)-1:0] addr1, addr2;
  cmplx_t twiddle_w1, twiddle_w3;

  always_comb begin
    int k;
    k = int'(cnt) % K_MOD;
    addr1 = k;
    addr2 = 3 * k;
  end

  twiddle_rom #(
      .FFT_SIZE (N),
      .WIDTH    (DATA_WIDTH),
      .FRAC_BITS(fft_pkg::FRAC_BITS)
  ) u_twiddle_rom (
      .clk  (clk),
      .rst_n(rst_n),
      .addr1(addr1),
      .addr2(addr2),
      .w1   (twiddle_w1),
      .w3   (twiddle_w3)
  );

  // ----------------------------------------------------------------
  // 3. DIF Butterfly Kernel Computation (Before Twiddles)
  // Matches Python:
  //   s[n], d[n] = radix2(x[n], x[n+N/2])
  //   s[n+N/4], d[n+N/4] = radix2(x[n+N/4], x[n+3N/4])
  //   p[n], q[n] = radix2(d[n], d[n+N/4], w=-1j)
  // ----------------------------------------------------------------
  cmplx_t t0_comb, z1_comb;
  cmplx_t p_comb, q_comb;
  logic signed [DATA_WIDTH-1:0] d0_re, d0_im;
  logic signed [DATA_WIDTH-1:0] d1_re, d1_im;

  always_comb begin
    // Upper Branch (Even Path sub-sums):
    // t0 = s[n]       = x0 + x2
    // z1 = s[n + N/4] = x1 + x3
    t0_comb.re = x0_sync.re + x2_sync.re;
    t0_comb.im = x0_sync.im + x2_sync.im;

    z1_comb.re = x1_sync.re + in_data.re;
    z1_comb.im = x1_sync.im + in_data.im;

    // Span-N/2 Subtractions:
    // d0 = x0 - x2
    // d1 = x1 - x3
    d0_re = x0_sync.re - x2_sync.re;
    d0_im = x0_sync.im - x2_sync.im;

    d1_re = x1_sync.re - in_data.re;
    d1_im = x1_sync.im - in_data.im;

    // Cross butterflies with w = -j:
    // p = d0 + (-j)*d1 = (d0_re + d1_im) + j*(d0_im - d1_re)
    p_comb.re = d0_re + d1_im;
    p_comb.im = d0_im - d1_re;

    // q = d0 - (-j)*d1 = (d0_re - d1_im) + j*(d0_im + d1_re)
    q_comb.re = d0_re - d1_im;
    q_comb.im = d0_im + d1_re;
  end

  // Register butterfly outputs to align with ROM latency (1 cycle)
  cmplx_t p_reg, q_reg;
  logic mult_valid_d1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_reg         <= '0;
      q_reg         <= '0;
      mult_valid_d1 <= 1'b0;
    end else begin
      p_reg         <= is_quad3 ? p_comb : '0;
      q_reg         <= is_quad3 ? q_comb : '0;
      mult_valid_d1 <= in_valid && is_quad3;
    end
  end

  // ----------------------------------------------------------------
  // 4. Pipelined Complex Multipliers (3 cycles latency)
  // Computes:
  //   u = p * W_N^k       (Odd Path A)
  //   v = q * W_N^(3k)    (Odd Path B)
  // ----------------------------------------------------------------
  cmplx_t u1, u3;
  logic cmult1_vld, cmult3_vld;

  cmult #(
      .WIDTH    (DATA_WIDTH),
      .FRAC_BITS(fft_pkg::FRAC_BITS),
      .SATURATE (1'b1)
  ) u_cmult_1 (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (mult_valid_d1),
      .valid_out(cmult1_vld),
      .a_re     (p_reg.re),
      .a_im     (p_reg.im),
      .b_re     (twiddle_w1.re),
      .b_im     (twiddle_w1.im),
      .p_re     (u1.re),
      .p_im     (u1.im)
  );

  cmult #(
      .WIDTH    (DATA_WIDTH),
      .FRAC_BITS(fft_pkg::FRAC_BITS),
      .SATURATE (1'b1)
  ) u_cmult_3 (
      .clk      (clk),
      .rst_n    (rst_n),
      .valid_in (mult_valid_d1),
      .valid_out(cmult3_vld),
      .a_re     (q_reg.re),
      .a_im     (q_reg.im),
      .b_re     (twiddle_w3.re),
      .b_im     (twiddle_w3.im),
      .p_re     (u3.re),
      .p_im     (u3.im)
  );

  // ----------------------------------------------------------------
  // 5. Latency Matching Pipeline Registers (4 Cycles for t0, z1)
  // ----------------------------------------------------------------
  cmplx_t t0_pipe[0:PIPE_LAT-1];
  cmplx_t z1_pipe[0:PIPE_LAT-1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < PIPE_LAT; i++) begin
        t0_pipe[i] <= '0;
        z1_pipe[i] <= '0;
      end
    end else begin
      t0_pipe[0] <= is_quad3 ? t0_comb : '0;
      z1_pipe[0] <= is_quad3 ? z1_comb : '0;
      for (int i = 1; i < PIPE_LAT; i++) begin
        t0_pipe[i] <= t0_pipe[i-1];
        z1_pipe[i] <= z1_pipe[i-1];
      end
    end
  end

  cmplx_t t0, z1, y1, y3;
  assign t0 = t0_pipe[PIPE_LAT-1];
  assign z1 = z1_pipe[PIPE_LAT-1];
  assign y1 = u1; // Twiddled p (Odd branch A)
  assign y3 = u3; // Twiddled q (Odd branch B)

  // ----------------------------------------------------------------
  // 6. Output Serialization & Commutator: [t0, z1, y1, y3]
  // ----------------------------------------------------------------
  cmplx_t t0_buf, z1_buf, y1_buf, y3_buf;

  // Stagger outputs across the 4 quadrants:
  // Quad 0: t0 (Even Path Part 1) -> Delay D
  delay_buffer #(
      .DEPTH(D),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_buf_t0 (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1),
      .din   (t0),
      .dout  (t0_buf)
  );

  // Quad 1: z1 (Even Path Part 2) -> Delay 2D
  delay_buffer #(
      .DEPTH(D2),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_buf_z1 (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1),
      .din   (z1),
      .dout  (z1_buf)
  );

  // Quad 2: y1 (Odd Path A) -> Delay 3D
  delay_buffer #(
      .DEPTH(D3),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_buf_y1 (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1),
      .din   (y1),
      .dout  (y1_buf)
  );

  // Quad 3: y3 (Odd Path B) -> Delay 4D (N)
  delay_buffer #(
      .DEPTH(N),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_buf_y3 (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(1),
      .din   (y3),
      .dout  (y3_buf)
  );

  // Delayed Quadrant Selector
  logic [1:0] out_quad_pipe[0:N + PIPE_LAT - 1];
  logic [1:0] current_in_quad;
  assign current_in_quad = cnt[$clog2(N)-1 : $clog2(N)-2];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < N + PIPE_LAT; i++) begin
        out_quad_pipe[i] <= '0;
      end
    end else begin
      out_quad_pipe[0] <= current_in_quad;
      for (int i = 1; i < N + PIPE_LAT; i++) begin
        out_quad_pipe[i] <= out_quad_pipe[i-1];
      end
    end
  end

  logic [1:0] out_quad;
  assign out_quad = out_quad_pipe[N+PIPE_LAT-1];

  // Serialized stream matching sr_fft_top's expectations:
  // Quad 0: t0 (Upper/Even path part 1: s[0..D-1])
  // Quad 1: z1 (Upper/Even path part 2: s[D..2D-1])
  // Quad 2: y1 (Lower Odd path 1:       u[0..D-1])
  // Quad 3: y3 (Lower Odd path 2:       v[0..D-1])
  always_comb begin
    case (out_quad)
      2'b00:   out_data = t0_buf;
      2'b01:   out_data = z1_buf;
      2'b10:   out_data = y1_buf;
      2'b11:   out_data = y3_buf;
      default: out_data = '0;
    endcase
  end

  // Output valid shift register tracking pipeline latency (N + PIPE_LAT)
  logic [N + PIPE_LAT - 1:0] vld_pipe;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vld_pipe <= '0;
    end else begin
      vld_pipe <= {vld_pipe[N+PIPE_LAT-2:0], in_valid};
    end
  end

  assign out_valid = vld_pipe[N+PIPE_LAT-1];

endmodule
