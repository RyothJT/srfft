// ============================================================================
// File:        r22_butterfly1.sv
// Description: Processes the first stage of a radix-22 butterfly
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module r22_butterfly1 #(
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
    localparam int D1 = N / 2;

    logic [$clog2(N)-1:0] cnt1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt1 <= '0;
        end else if (in_valid) begin
            cnt1 <= cnt1 + 1'b1;
        end
    end

    logic bf1_sel;
    assign bf1_sel = cnt1[$clog2(N)-1];

    fft_pkg::cmplx_t bf1_fifo_in, bf1_fifo_out;

    // always_comb causes warnings in iverilog
    always @* begin
        if (!bf1_sel) begin
            bf1_fifo_in = in_data;
            out_data    = bf1_fifo_out;
        end else begin
            bf1_fifo_in.re = bf1_fifo_out.re - in_data.re;
            bf1_fifo_in.im = bf1_fifo_out.im - in_data.im;

            out_data.re    = bf1_fifo_out.re + in_data.re;
            out_data.im    = bf1_fifo_out.im + in_data.im;
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

    assign out_valid = vld_pipe1[D1-1];
endmodule
