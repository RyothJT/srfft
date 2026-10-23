`timescale 1ns / 1ps
import fft_pkg::*;

// ============================================================================
// File: sram_dummy.sv
// Description: Dummy SRAM for logic synthesis without memory compiler .lib
// ============================================================================
(* black_box *)
module sram_dummy #(
    parameter int ADDR_WIDTH = 10,
    parameter int DATA_WIDTH = 32
) (
    input  logic                  CLK,
    input  logic                  WEN,
    input  logic [ADDR_WIDTH-1:0] WADDR,
    input  logic [DATA_WIDTH-1:0] D,
    input  logic                  REN,
    input  logic [ADDR_WIDTH-1:0] RADDR,
    output logic [DATA_WIDTH-1:0] Q
);
endmodule
