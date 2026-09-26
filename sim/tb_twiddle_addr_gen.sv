// ============================================================================
// File:        tb_twiddle_addr_gen.sv
// Description: Race-free, self-checking testbench for twiddle_addr_gen.
// ============================================================================

`timescale 1ns / 1ps
import fft_pkg::*;

module tb_twiddle_addr_gen;

  // --------------------------------------------------------------------------
  // Parameters & Interface Signals
  // --------------------------------------------------------------------------
  localparam int TEST_FFT_SIZE = 1024;
  localparam int ADDR_WIDTH = $clog2(TEST_FFT_SIZE);
  localparam time CLK_PERIOD = 10ns;

  logic                  clk;
  logic                  rst_n;
  logic                  enable;
  logic                  clear;
  logic [ADDR_WIDTH-1:0] stage_sel;
  logic [ADDR_WIDTH-1:0] addr1;
  logic [ADDR_WIDTH-1:0] addr2;

  // --------------------------------------------------------------------------
  // DUT Instantiation
  // --------------------------------------------------------------------------
  twiddle_addr_gen #(
      .FFT_SIZE(TEST_FFT_SIZE)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .enable   (enable),
      .clear    (clear),
      .stage_sel(stage_sel),
      .addr1    (addr1),
      .addr2    (addr2)
  );

  // --------------------------------------------------------------------------
  // Clock Generation
  // --------------------------------------------------------------------------
  initial begin
    clk = 0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  // --------------------------------------------------------------------------
  // Self-Checking Monitor & Verification Loop
  // --------------------------------------------------------------------------
  int error_count = 0;
  int match_count = 0;

  // Expected reference values calculated in testbench space
  logic [ADDR_WIDTH-1:0] exp_k_cnt;
  logic [ADDR_WIDTH-1:0] exp_addr1;
  logic [ADDR_WIDTH-1:0] exp_addr2;

  // Standard SystemVerilog function returning a struct containing both generated addresses
  typedef struct packed {
    logic [ADDR_WIDTH-1:0] a1;
    logic [ADDR_WIDTH-1:0] a2;
  } addr_pair_t;

  function automatic addr_pair_t get_expected_addrs(input logic [ADDR_WIDTH-1:0] k,
                                                    input logic [ADDR_WIDTH-1:0] stg);
    addr_pair_t res;
    res.a1 = (k << stg) % TEST_FFT_SIZE;
    res.a2 = (3 * (k << stg)) % TEST_FFT_SIZE;
    return res;
  endfunction

  // Track expected counter state and verify DUT outputs on clock edges
  always @(posedge clk) begin
    if (!rst_n) begin
      exp_k_cnt <= '0;
    end else if (clear) begin
      exp_k_cnt <= '0;
    end else if (enable) begin
      addr_pair_t exp;

      // Call function returning struct
      exp = get_expected_addrs(exp_k_cnt, stage_sel);

      if (addr1 !== exp.a1 || addr2 !== exp.a2) begin
        $display(
            "[MISMATCH] At time %0t: stage=%0d, k_cnt=%0d | Expected: addr1=%0d, addr2=%0d | Got: addr1=%0d, addr2=%0d",
            $time, stage_sel, exp_k_cnt, exp.a1, exp.a2, addr1, addr2);
        error_count++;
      end else begin
        match_count++;
      end

      exp_k_cnt <= exp_k_cnt + 1'b1;
    end
  end

  // --------------------------------------------------------------------------
  // Main Stimulus Sequence
  // --------------------------------------------------------------------------
  initial begin
    $display("--- Starting Twiddle Address Generator Test (FFT_SIZE = %0d) ---", TEST_FFT_SIZE);

    // Initial signal setup
    rst_n     = 1'b0;
    enable    = 1'b0;
    clear     = 1'b0;
    stage_sel = '0;

    // Apply Active-Low Reset
    #(CLK_PERIOD * 2);
    rst_n = 1'b1;
    #(CLK_PERIOD);

    // ------------------------------------------------------------------------
    // Test 1: Sequential Stage Execution
    // ------------------------------------------------------------------------
    for (int stg = 0; stg < 4; stg++) begin
      @(posedge clk);
      #1ns;
      clear     = 1'b1;
      stage_sel = stg[ADDR_WIDTH-1:0];

      @(posedge clk);
      #1ns;
      clear  = 1'b0;
      enable = 1'b1;

      // Run address generator through 16 steps per stage
      repeat (16) begin
        @(posedge clk);
        #1ns;
      end

      enable = 1'b0;
    end

    // ------------------------------------------------------------------------
    // Test 2: Handshake Interruption & Hold Verification (Enable Low)
    // ------------------------------------------------------------------------
    @(posedge clk);
    #1ns;
    clear     = 1'b1;
    stage_sel = ADDR_WIDTH'(2);

    @(posedge clk);
    #1ns;
    clear  = 1'b0;
    enable = 1'b1;

    repeat (5) @(posedge clk);

    // Pause advancing (enable = 0)
    #1ns;
    enable = 1'b0;
    repeat (4) @(posedge clk);

    // Resume advancing
    #1ns;
    enable = 1'b1;
    repeat (5) @(posedge clk);

    @(posedge clk);
    #1ns;
    enable = 1'b0;

    // ------------------------------------------------------------------------
    // Final Summary
    // ------------------------------------------------------------------------
    $display("==================================================");
    $display(" Simulation Complete");
    $display(" Matches: %0d | Errors: %0d", match_count, error_count);
    if (error_count == 0) begin
      $display(" STATUS : >>> TEST PASSED <<<");
    end else begin
      $display(" STATUS : >>> TEST FAILED <<<");
    end
    $display("==================================================");

    $finish;
  end

endmodule
