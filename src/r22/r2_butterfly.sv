// ============================================================================
// File:        r2_butterfly.sv
// Description: Fully Parameterized Linear Radix-2^2 / Radix-2 SDF Pipelined FFT
//              Acts as the last stage for a radix-22 setup in case of odd FFT
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module r2_butterfly #(
    parameter int DATA_WIDTH = fft_pkg::DATA_WIDTH
) (
    input  logic            clk,
    input  logic            rst_n,
    input  logic            in_valid,
    input  fft_pkg::cmplx_t in_data,
    output logic            out_valid,
    output fft_pkg::cmplx_t out_data
);

  logic sel;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sel <= 1'b0;
    end else if (in_valid) begin
      sel <= ~sel;
    end
  end

  fft_pkg::cmplx_t fifo_in, fifo_out;

  always @* begin
    if (!sel) begin
      fifo_in  = in_data;
      out_data = fifo_out;
    end else begin
      fifo_in.re  = fifo_out.re - in_data.re;
      fifo_in.im  = fifo_out.im - in_data.im;

      out_data.re = fifo_out.re + in_data.re;
      out_data.im = fifo_out.im + in_data.im;
    end
  end

  delay_buffer #(
      .DEPTH(1),
      .DATA_WIDTH(2 * DATA_WIDTH)
  ) u_delay (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(in_valid),
      .din   (fifo_in),
      .dout  (fifo_out)
  );

  // Exactly 1 cycle delay matches the 1-sample FIFO latency
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
    end else begin
      out_valid <= in_valid;
    end
  end

endmodule
