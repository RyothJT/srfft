`timescale 1ns / 1ps

module split_radix_l_cell #(
    parameter int WIDTH = 16
)(
    input  logic signed [WIDTH-1:0] x0_re, x0_im,
    input  logic signed [WIDTH-1:0] x1_re, x1_im, // Input after twiddle W^k1 applied
    input  logic signed [WIDTH-1:0] x2_re, x2_im,
    input  logic signed [WIDTH-1:0] x3_re, x3_im, // Input after twiddle W^k3 applied

    output logic signed [WIDTH-1:0] y0_re, y0_im,
    output logic signed [WIDTH-1:0] y1_re, y1_im,
    output logic signed [WIDTH-1:0] y2_re, y2_im,
    output logic signed [WIDTH-1:0] y3_re, y3_im
);

    // Intermediate variables
    logic signed [WIDTH-1:0] z1_re, z1_im; // x1 + x3
    logic signed [WIDTH-1:0] z2_re, z2_im; // -j*(x1 - x3) = (x1_im - x3_im) - j*(x1_re - x3_re)
    logic signed [WIDTH-1:0] t0_re, t0_im; // x0 + x2
    logic signed [WIDTH-1:0] t2_re, t2_im; // x0 - x2

    always_comb begin
        // Radix-2 portion on even indices (x0, x2)
        t0_re = x0_re + x2_re;
        t0_im = x0_im + x2_im;
        t2_re = x0_re - x2_re;
        t2_im = x0_im - x2_im;

        // Sum of pre-rotated odd indices (x1, x3)
        z1_re = x1_re + x3_re;
        z1_im = x1_im + x3_im;

        // Multiply (x1 - x3) by -j -> (im, -re) for standard forward FFT (e^{-j*2*pi/N})
        z2_re =  (x1_im - x3_im);
        z2_im = -(x1_re - x3_re);

        // Final combine output stage
        y0_re = t0_re + z1_re;
        y0_im = t0_im + z1_im;

        y1_re = t2_re + z2_re;
        y1_im = t2_im + z2_im; // x0_im - x2_im - x1_re + x3_re

        y2_re = t0_re - z1_re;
        y2_im = t0_im - z1_im;

        y3_re = t2_re - z2_re;
        y3_im = t2_im - z2_im;
    end

endmodule
