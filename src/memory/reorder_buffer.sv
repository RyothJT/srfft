// ============================================================================
// File:        reorder_buffer.sv
// Description: Bit-reversal / output reorder memory buffer for FFT.
//              Robust ping-pong bank architecture with frame-ready handshaking.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module reorder_buffer #(
    parameter int FFT_SIZE   = 4096,       // FFT point size
    parameter int DATA_WIDTH = DATA_WIDTH  // Complex data width
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

  // Ping-Pong Memories
  cmplx_t              mem_0        [0:FFT_SIZE-1];
  cmplx_t              mem_1        [0:FFT_SIZE-1];

  // Bank tracking state
  logic                wr_bank;
  logic                rd_bank;
  logic   [ADDR_W-1:0] wr_ptr;
  logic   [ADDR_W-1:0] rd_ptr;

  // Bank ready flags (1 = bank has completed writing and is ready to be read)
  logic                bank_0_ready;
  logic                bank_1_ready;

  // Bit-reversal calculation function
  function automatic [ADDR_W-1:0] bit_reverse(input [ADDR_W-1:0] in_idx);
    int k;
    begin
      bit_reverse = '0;
      for (k = 0; k < ADDR_W; k = k + 1) begin
        bit_reverse[ADDR_W-1-k] = in_idx[k];
      end
    end
  endfunction

  // ------------------------------------------------------------------------
  // Write Control
  // ------------------------------------------------------------------------
  always_ff @(posedge clk) begin
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
        if (wr_bank == 1'b0) mem_0[wr_ptr] <= wr_data;
        else mem_1[wr_ptr] <= wr_data;

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

  // ------------------------------------------------------------------------
  // Read Control (Reads out data in bit-reversed order -> sequential output)
  // ------------------------------------------------------------------------
  logic [ADDR_W-1:0] rd_addr_mapped;
  assign rd_addr_mapped = bit_reverse(rd_ptr);

  logic current_bank_ready;
  assign current_bank_ready = (rd_bank == 1'b0) ? bank_0_ready : bank_1_ready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_ptr   <= '0;
      rd_bank  <= 1'b0;
      rd_valid <= 1'b0;
      rd_data  <= '0;
    end else begin
      rd_valid <= 1'b0;

      // If current bank is ready, stream out continuously every clock cycle
      if (current_bank_ready && rd_ready) begin
        rd_valid <= 1'b1;
        if (rd_bank == 1'b0) rd_data <= mem_0[rd_addr_mapped];
        else rd_data <= mem_1[rd_addr_mapped];

        if (rd_ptr == FFT_SIZE - 1) begin
          rd_ptr  <= '0;
          rd_bank <= ~rd_bank;  // Switch ping-pong bank immediately
        end else begin
          rd_ptr <= rd_ptr + 1'b1;
        end
      end
    end
  end

endmodule
