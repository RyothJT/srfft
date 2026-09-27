// ============================================================================
// File:        r2_fft_top.sv
// Description: Pipelined Radix-2 Single-Path Delay Feedback (SDF) FFT Top.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module r2_fft_top #(
    parameter int FFT_SIZE   = 1024,
    parameter int DATA_WIDTH = DATA_WIDTH
) (
    input logic clk,
    input logic rst_n,

    // Input Sink Interface
    input  logic   s_axis_tvalid,
    output logic   s_axis_tready,
    input  cmplx_t s_axis_tdata,
    input  logic   s_axis_tlast,

    // Output Source Interface
    output logic   m_axis_tvalid,
    input  logic   m_axis_tready,
    output cmplx_t m_axis_tdata,
    output logic   m_axis_tlast
);

  localparam int NUM_STAGES = $clog2(FFT_SIZE);

  // Stage Handshake & Pipeline Buses
  logic   [      NUM_STAGES-1:0] sdf_mode;
  logic   [      NUM_STAGES-1:0] stage_active;

  logic   [        NUM_STAGES:0] stage_valid;
  cmplx_t                        stage_data     [NUM_STAGES+1];

  // Output Reorder Framing
  logic                          wr_frame_start;
  logic   [$clog2(FFT_SIZE)-1:0] sample_cnt;

  assign s_axis_tready  = 1'b1;
  assign stage_valid[0] = s_axis_tvalid && s_axis_tready;
  assign stage_data[0]  = s_axis_tdata;

  // --------------------------------------------------------------------------
  // Stage Control FSMs
  // --------------------------------------------------------------------------
  genvar s;
  generate
    for (s = 0; s < NUM_STAGES; s++) begin : gen_control_fsms
      fft_control_fsm #(
          .FFT_SIZE(FFT_SIZE >> s)
      ) u_control_fsm (
          .clk         (clk),
          .rst_n       (rst_n),
          .valid_in    (stage_valid[s]),
          .ready_in    (1'b1),
          .valid_out   (),
          .ready_out   (),
          .sdf_mode    (sdf_mode[s]),
          .stage_active(stage_active[s])
      );
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Pipelined Radix-2 SDF Stages
  // --------------------------------------------------------------------------
  generate
    for (s = 0; s < NUM_STAGES; s++) begin : gen_sdf_stages
      localparam int STAGE_DELAY = 1 << (NUM_STAGES - 1 - s);

      // Extract local stage mode bit to prevent Icarus always_comb bit-select issue
      logic current_sdf_mode;
      assign current_sdf_mode = sdf_mode[s];

      cmplx_t delay_in, delay_out;
      cmplx_t bf_in_a, bf_in_b;
      cmplx_t bf_out_0, bf_out_1;
      cmplx_t twiddle_w;

      logic [$clog2(FFT_SIZE)-1:0] tw_addr1, tw_addr2;
      cmplx_t w1, w3;

      if (s < NUM_STAGES - 1) begin : gen_twiddle
        twiddle_addr_gen #(
            .FFT_SIZE(FFT_SIZE)
        ) u_tw_addr_gen (
            .clk      (clk),
            .rst_n    (rst_n),
            .enable   (stage_valid[s] && (current_sdf_mode == fft_pkg::SDF_CALC)),
            .clear    (!stage_active[s]),
            .stage_sel(s[$clog2(FFT_SIZE)-1:0]),
            .addr1    (tw_addr1),
            .addr2    (tw_addr2)
        );

        twiddle_rom #(
            .FFT_SIZE (FFT_SIZE),
            .WIDTH    (DATA_WIDTH),
            .FRAC_BITS(FRAC_BITS)
        ) u_twiddle_rom (
            .clk  (clk),
            .rst_n(rst_n),
            .addr1(tw_addr1),
            .addr2(tw_addr2),
            .w1   (w1),
            .w3   (w3)
        );

        assign twiddle_w = w1;
      end else begin : gen_no_twiddle
        assign twiddle_w = '0;
      end

      // SDF FIFO Buffer
      delay_buffer #(
          .DEPTH     (STAGE_DELAY),
          .DATA_WIDTH($bits(cmplx_t))
      ) u_delay_buffer (
          .clk   (clk),
          .rst_n (rst_n),
          .enable(stage_valid[s] || stage_active[s]),
          .din   (delay_in),
          .dout  (delay_out)
      );

      // Continuous Commutator Mux Routing
      assign delay_in = (current_sdf_mode == fft_pkg::SDF_LOAD) ? stage_data[s] : bf_out_1;
      assign bf_in_a  = delay_out;
      assign bf_in_b  = stage_data[s];

      // Radix-2 DIF Butterfly Core
      bf2_core #(
          .WIDTH      (DATA_WIDTH),
          .FRAC_BITS  (FRAC_BITS),
          .SCALE      (1'b1),
          .SATURATE   (1'b1),
          .HAS_TWIDDLE(s < NUM_STAGES - 1 ? 1'b1 : 1'b0)
      ) u_bf2_core (
          .clk      (clk),
          .rst_n    (rst_n),
          .valid_in (stage_valid[s] && (current_sdf_mode == fft_pkg::SDF_CALC)),
          .valid_out(stage_valid[s+1]),
          .a        (bf_in_a),
          .b        (bf_in_b),
          .w        (twiddle_w),
          .y0       (bf_out_0),
          .y1       (bf_out_1)
      );

      assign stage_data[s+1] = (current_sdf_mode == fft_pkg::SDF_CALC) ? bf_out_0 : delay_out;
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Bit-Reversal Reorder Buffer Integration
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sample_cnt     <= '0;
      wr_frame_start <= 1'b0;
    end else begin
      wr_frame_start <= 1'b0;
      if (stage_valid[NUM_STAGES]) begin
        if (sample_cnt == '0) begin
          wr_frame_start <= 1'b1;
        end
        if (sample_cnt == FFT_SIZE - 1) begin
          sample_cnt <= '0;
        end else begin
          sample_cnt <= sample_cnt + 1'b1;
        end
      end
    end
  end

  reorder_buffer #(
      .FFT_SIZE  (FFT_SIZE),
      .DATA_WIDTH(DATA_WIDTH)
  ) u_reorder_buffer (
      .clk           (clk),
      .rst_n         (rst_n),
      .wr_frame_start(wr_frame_start),
      .wr_valid      (stage_valid[NUM_STAGES]),
      .wr_data       (stage_data[NUM_STAGES]),
      .rd_ready      (m_axis_tready),
      .rd_valid      (m_axis_tvalid),
      .rd_data       (m_axis_tdata)
  );

  logic [$clog2(FFT_SIZE)-1:0] out_sample_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_sample_cnt <= '0;
    end else if (m_axis_tvalid && m_axis_tready) begin
      if (out_sample_cnt == FFT_SIZE - 1) begin
        out_sample_cnt <= '0;
      end else begin
        out_sample_cnt <= out_sample_cnt + 1'b1;
      end
    end
  end

  assign m_axis_tlast = m_axis_tvalid && (out_sample_cnt == FFT_SIZE - 1);

endmodule
