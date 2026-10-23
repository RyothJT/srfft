// ============================================================================
// File:        r22_butterfly2.sv
// Description: Processes the second stage of a radix-22 butterfly
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module r22_butterfly2 #(
    parameter int N          = 16,
    parameter int DATA_WIDTH = 16
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  fft_pkg::cmplx_t in_data,
    output logic          out_valid,
    output fft_pkg::cmplx_t out_data
);
    localparam int D2 = (N >= 4) ? (N / 4) : 1;

    logic [$clog2(N)-1:0] cnt2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt2 <= '0;
        end else if (in_valid) begin
            cnt2 <= cnt2 + 1'b1;
        end
    end

    logic bf2_sel, bf2_mul_neg_j;
    assign bf2_sel       = cnt2[$clog2(N)-2];
    assign bf2_mul_neg_j = (cnt2[$clog2(N)-1:$clog2(N)-2] == 2'b11);

    fft_pkg::cmplx_t bf2_in_rot;
    // always_comb causes warnings in iverilog
    always @* begin
        if (bf2_mul_neg_j) begin
            bf2_in_rot.re = in_data.im;
            bf2_in_rot.im = -in_data.re;
        end else begin
            bf2_in_rot = in_data;
        end
    end

    fft_pkg::cmplx_t bf2_fifo_in, bf2_fifo_out;

    always @* begin
        if (!bf2_sel) begin
            bf2_fifo_in = bf2_in_rot;
            out_data    = bf2_fifo_out;
        end else begin
            bf2_fifo_in.re = bf2_fifo_out.re - bf2_in_rot.re;
            bf2_fifo_in.im = bf2_fifo_out.im - bf2_in_rot.im;

            out_data.re    = bf2_fifo_out.re + bf2_in_rot.re;
            out_data.im    = bf2_fifo_out.im + bf2_in_rot.im;
        end
    end

    delay_buffer #(
        .DEPTH(D2),
        .DATA_WIDTH(2 * DATA_WIDTH)
    ) u_bf2_fifo (
        .clk   (clk),
        .rst_n (rst_n),
        .enable(in_valid),
        .din   (bf2_fifo_in),
        .dout  (bf2_fifo_out)
    );

    logic [D2-1:0] vld_pipe2;
    generate
        if (D2 > 1) begin : gen_vld_pipe2_multi
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    vld_pipe2 <= '0;
                end else begin
                    vld_pipe2 <= {vld_pipe2[D2-2:0], in_valid};
                end
            end
        end else begin : gen_vld_pipe2_single
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    vld_pipe2 <= '0;
                end else begin
                    vld_pipe2 <= in_valid;
                end
            end
        end
    endgenerate

    assign out_valid = vld_pipe2[D2-1];
endmodule
