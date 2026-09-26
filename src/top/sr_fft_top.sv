// ============================================================================
// File:        sr_fft_top.sv
// Description: Top-level wrapper for the Single-Path Delay Feedback (SDF) 
//              Split-Radix FFT processor with fully chained multi-stage pipeline.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module sr_fft_top #(
    parameter int FFT_SIZE = 1024,  // FFT point size
    parameter int DATA_WIDTH = fft_pkg::DATA_WIDTH
    // parameter int DATA_WIDTH = DATA_WIDTH  // Complex data width
) (
    input logic clk,
    input logic rst_n,

    // Input Sink Interface (AXI4-Stream Slave with TLAST framing)
    input  logic   s_axis_tvalid,
    output logic   s_axis_tready,
    input  cmplx_t s_axis_tdata,
    input  logic   s_axis_tlast,

    // Output Source Interface (AXI4-Stream Master with TLAST framing)
    output logic   m_axis_tvalid,
    input  logic   m_axis_tready,
    output cmplx_t m_axis_tdata,
    output logic   m_axis_tlast
);

  // localparam int STAGE_COUNT = $clog2(FFT_SIZE);
  localparam int STAGE_COUNT = $clog2(FFT_SIZE);

  // Internal Control Signals from FSM
  logic fsm_sdf_mode;
  logic fsm_stage_active;
  logic fsm_valid_out;
  logic fsm_ready_out;

  fft_control_fsm #(
      .FFT_SIZE(FFT_SIZE)
  ) u_control_fsm (
      .clk         (clk),
      .rst_n       (rst_n),
      .valid_in    (s_axis_tvalid),
      .ready_in    (m_axis_tready),
      .valid_out   (fsm_valid_out),
      .ready_out   (fsm_ready_out),
      .sdf_mode    (fsm_sdf_mode),
      .stage_active(fsm_stage_active)
  );

  assign s_axis_tready = fsm_ready_out;

  // Multi-Stage Pipeline Interconnect Arrays
  logic   stage_vld [0:STAGE_COUNT];
  cmplx_t stage_data[0:STAGE_COUNT];

  assign stage_vld[0]  = s_axis_tvalid && s_axis_tready;
  assign stage_data[0] = s_axis_tdata;

  // Generate loop chaining all M SDF stages
  genvar s;
  generate
    for (s = 0; s < STAGE_COUNT; s = s + 1) begin : gen_sdf_stages
      localparam int STAGE_DELAY = FFT_SIZE >> (s + 1);

      logic [$clog2(FFT_SIZE)-1:0] tw_addr1, tw_addr2;
      cmplx_t tw_w1, tw_w3;
      logic   stage_out_vld;
      cmplx_t stage_out_data;

      // Twiddle Address Generator per stage
      twiddle_addr_gen #(
          .FFT_SIZE(FFT_SIZE)
      ) u_twiddle_addr (
          .clk      (clk),
          .rst_n    (rst_n),
          .enable   (stage_vld[s]),
          .clear    (!fsm_stage_active),
          .stage_sel(s[$clog2(FFT_SIZE)-1:0]),
          .addr1    (tw_addr1),
          .addr2    (tw_addr2)
      );

      // Twiddle ROM per stage
      twiddle_rom #(
          .FFT_SIZE (FFT_SIZE),
          .WIDTH    (DATA_WIDTH),
          .FRAC_BITS(FRAC_BITS)
      ) u_twiddle_rom (
          .clk  (clk),
          .rst_n(rst_n),
          .addr1(tw_addr1),
          .addr2(tw_addr2),
          .w1   (tw_w1),
          .w3   (tw_w3)
      );

      // SDF Stage Instance (Delay + Butterfly + Feedback)
      sdf_stage #(
          .STAGE_DEPTH(STAGE_DELAY > 0 ? STAGE_DELAY : 1),
          .HAS_TWIDDLE(s == STAGE_COUNT - 1 ? 1'b0 : 1'b1),
          .SCALE((s < 4) ? 1'b0 : 1'b1)
      ) u_sdf_stage (
          .clk      (clk),
          .rst_n    (rst_n),
          .valid_in (stage_vld[s]),
          .data_in  (stage_data[s]),
          .sdf_mode (fsm_sdf_mode),
          .tw_w     (tw_w1),
          .valid_out(stage_out_vld),
          .data_out (stage_out_data)
      );

      // Connect stage output to next stage input
      assign stage_vld[s+1]  = stage_out_vld;
      assign stage_data[s+1] = stage_out_data;
    end
  endgenerate

  // ------------------------------------------------------------------------
  // Reorder Buffer Integration
  // ------------------------------------------------------------------------
  logic   reorder_wr_valid;
  cmplx_t reorder_wr_data;

  assign reorder_wr_valid = stage_vld[STAGE_COUNT];
  assign reorder_wr_data  = stage_data[STAGE_COUNT];

  logic   reorder_rd_valid;
  cmplx_t reorder_rd_data;

  reorder_buffer #(
      .FFT_SIZE  (FFT_SIZE),
      .DATA_WIDTH(DATA_WIDTH)
  ) u_reorder_buffer (
      .clk     (clk),
      .rst_n   (rst_n),
      .wr_valid(reorder_wr_valid),
      .wr_data (reorder_wr_data),
      .rd_ready(m_axis_tready),
      .rd_valid(reorder_rd_valid),
      .rd_data (reorder_rd_data)
  );

  // Drive Master AXI4-Stream outputs
  assign m_axis_tvalid = reorder_rd_valid;
  assign m_axis_tdata  = reorder_rd_data;

  // Generate m_axis_tlast coincident with the final sample (FFT_SIZE - 1) of a frame
  localparam int ADDR_W = $clog2(FFT_SIZE);
  logic [ADDR_W-1:0] out_cnt;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_cnt      <= '0;
      m_axis_tlast <= 1'b0;
    end else begin
      m_axis_tlast <= 1'b0;
      if (m_axis_tvalid && m_axis_tready) begin
        if (out_cnt == FFT_SIZE - 1) begin
          out_cnt      <= '0;
          m_axis_tlast <= 1'b1;
        end else begin
          out_cnt <= out_cnt + 1'b1;
        end
      end
    end
  end

endmodule
