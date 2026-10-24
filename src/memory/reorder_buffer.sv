// ============================================================================
// File:        reorder_buffer.sv
// Description: Bit-reversal / output reorder memory buffer for FFT (Radix-2/4).
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module reorder_buffer #(
    parameter int FFT_SIZE   = 1024,
    parameter int DATA_WIDTH = fft_pkg::DATA_WIDTH,
    parameter int RADIX      = 2
) (
    input logic clk,
    input logic rst_n,

    // Write Interface (Streaming from FFT Pipeline)
    input logic   wr_valid,
    input cmplx_t wr_data,

    // Read Interface (Sequential Output)
    input  logic   rd_ready,
    output logic   rd_valid,
    output cmplx_t rd_data
);

  localparam int ADDR_W = $clog2(FFT_SIZE);
  localparam int WORD_BIT = $bits(cmplx_t);  // Usually 32 bits (16 Real + 16 Imag)

  // Bank tracking state
  logic              wr_bank;
  logic              rd_bank;
  logic [ADDR_W-1:0] wr_ptr;
  logic [ADDR_W-1:0] rd_ptr;

  logic              bank_0_ready;
  logic              bank_1_ready;

  // Reorder index calculation function supporting Radix-2 or Radix-4
  function automatic [ADDR_W-1:0] reorder_addr(input [ADDR_W-1:0] in_idx);
    int k, i;
    begin
      reorder_addr = '0;
      if (RADIX == 4) begin
        for (i = 0; i < ADDR_W; i = i + 2) begin
          reorder_addr[i +: 2] = in_idx[ADDR_W - 2 - i +: 2];
        end
      end else begin
        for (k = 0; k < ADDR_W; k = k + 1) begin
          reorder_addr[ADDR_W - 1 - k] = in_idx[k];
        end
      end
    end
  endfunction

  // Write control logic
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr       <= '0;
      wr_bank      <= 1'b0;
      bank_0_ready <= 1'b0;
      bank_1_ready <= 1'b0;
    end else begin
      // Clear ready flag when the reader finishes reading that bank
      if (rd_ready && (rd_ptr == FFT_SIZE - 1)) begin
        if (rd_bank == 1'b0) bank_0_ready <= 1'b0;
        else bank_1_ready <= 1'b0;
      end

      if (wr_valid) begin
        if (wr_ptr == FFT_SIZE - 1) begin
          wr_ptr  <= '0;
          wr_bank <= ~wr_bank;
          if (wr_bank == 1'b0) bank_0_ready <= 1'b1;
          else bank_1_ready <= 1'b1;
        end else begin
          wr_ptr <= wr_ptr + 1'b1;
        end
      end
    end
  end

  // Read Port controls
  logic [ADDR_W-1:0] rd_addr_mapped;
  assign rd_addr_mapped = reorder_addr(rd_ptr);

  cmplx_t mem_0_dout;
  cmplx_t mem_1_dout;

  // ------------------------------------------------------------------------
  // Memory Array Implementation Switch
  // ------------------------------------------------------------------------
`ifdef SYNTHESIS
  // Bank 0 SRAM
  sram_dummy #(
      .ADDR_WIDTH(ADDR_W),
      .DATA_WIDTH(WORD_BIT)
  ) u_sram_bank_0 (
      .CLK  (clk),
      .WEN  (~(wr_valid && (wr_bank == 1'b0))),
      .WADDR(wr_ptr),
      .D    (wr_data),
      .REN  (1'b0),
      .RADDR(rd_addr_mapped),
      .Q    (mem_0_dout)
  );

  // Bank 1 SRAM
  sram_dummy #(
      .ADDR_WIDTH(ADDR_W),
      .DATA_WIDTH(WORD_BIT)
  ) u_sram_bank_1 (
      .CLK  (clk),
      .WEN  (~(wr_valid && (wr_bank == 1'b1))),
      .WADDR(wr_ptr),
      .D    (wr_data),
      .REN  (1'b0),
      .RADDR(rd_addr_mapped),
      .Q    (mem_1_dout)
  );

`else
  // Simulation / FPGA Mode: Behavioral 2D Array
  (* ram_style = "block" *)cmplx_t mem_0[0:FFT_SIZE-1];
  (* ram_style = "block" *)cmplx_t mem_1[0:FFT_SIZE-1];

  always_ff @(posedge clk) begin
    if (wr_valid) begin
      if (wr_bank == 1'b0) mem_0[wr_ptr] <= wr_data;
      else mem_1[wr_ptr] <= wr_data;
    end
  end

  always_ff @(posedge clk) begin
    mem_0_dout <= mem_0[rd_addr_mapped];
    mem_1_dout <= mem_1[rd_addr_mapped];
  end
`endif

  // ------------------------------------------------------------------------
  // Pipeline control signals
  // ------------------------------------------------------------------------
  logic rd_bank_d1;
  logic rd_valid_d1;
  logic current_bank_ready;

  assign current_bank_ready = (rd_bank == 1'b0) ? bank_0_ready : bank_1_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_ptr      <= '0;
      rd_bank     <= 1'b0;
      rd_bank_d1  <= 1'b0;
      rd_valid_d1 <= 1'b0;
    end else begin
      rd_valid_d1 <= 1'b0;
      rd_bank_d1  <= rd_bank;

      if (current_bank_ready && rd_ready) begin
        rd_valid_d1 <= 1'b1;

        if (rd_ptr == FFT_SIZE - 1) begin
          rd_ptr  <= '0;
          rd_bank <= ~rd_bank;
        end else begin
          rd_ptr <= rd_ptr + 1'b1;
        end
      end
    end
  end

  // Output multiplexer outside of memory blocks
  assign rd_valid = rd_valid_d1;
  assign rd_data  = (rd_bank_d1 == 1'b0) ? mem_0_dout : mem_1_dout;

endmodule
