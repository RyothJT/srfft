// ============================================================================
// File:        tb_delay_buffer.sv
// Description: Testbench for the parameterized delay_buffer module.
// ============================================================================

`timescale 1ns / 1ps

module tb_delay_buffer;

  // --------------------------------------------------------------------------
  // Parameters & Interface Signals
  // --------------------------------------------------------------------------
  localparam int TEST_DEPTH = 5;
  localparam int TEST_DATA_WIDTH = 16;
  localparam time CLK_PERIOD = 10ns;

  logic                       clk;
  logic                       rst_n;
  logic                       enable;
  logic [TEST_DATA_WIDTH-1:0] din;
  logic [TEST_DATA_WIDTH-1:0] dout;

  // --------------------------------------------------------------------------
  // DUT Instantiation
  // --------------------------------------------------------------------------
  delay_buffer #(
      .DEPTH     (TEST_DEPTH),
      .DATA_WIDTH(TEST_DATA_WIDTH)
  ) dut (
      .clk   (clk),
      .rst_n (rst_n),
      .enable(enable),
      .din   (din),
      .dout  (dout)
  );

  // --------------------------------------------------------------------------
  // Clock Generation
  // --------------------------------------------------------------------------
  initial begin
    clk = 0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  // --------------------------------------------------------------------------
  // Testbench Scoreboard & Verification Loop
  // --------------------------------------------------------------------------
  logic [TEST_DATA_WIDTH-1:0] ref_queue[$];

  // Initialize reference pipeline with zeros to mirror reset behavior
  task automatic reset_scoreboard();
    ref_queue.delete();
    for (int i = 0; i < TEST_DEPTH; i++) begin
      ref_queue.push_back('0);
    end
  endtask

  // Monitor output and compare against the reference queue on rising clock edges
  always @(posedge clk) begin
    if (!rst_n) begin
      reset_scoreboard();
    end else if (enable) begin
      logic [TEST_DATA_WIDTH-1:0] expected_data;

      // Sample expected data from the head of the queue
      expected_data = ref_queue.pop_front();

      // Check output match
      if (dout !== expected_data) begin
        $display("[MISMATCH] At time %0t: Expected %0h, Got %0h", $time, expected_data, dout);
      end

      // Push current input into the queue to track the shift register pipeline
      ref_queue.push_back(din);
    end
  end

  // --------------------------------------------------------------------------
  // Main Stimulus Sequence
  // --------------------------------------------------------------------------
  initial begin
    $display("--- Starting Delay Buffer Test (Depth = %0d) ---", TEST_DEPTH);

    // Setup signals
    rst_n  = 1'b0;
    enable = 1'b0;
    din    = '0;

    // Apply Active-Low Reset
    #(CLK_PERIOD * 2);
    rst_n = 1'b1;
    #(CLK_PERIOD);

    // Continuous Enable & Streaming Data
    enable = 1'b1;
    for (int i = 1; i <= 50; i++) begin
      #(CLK_PERIOD);
      din = i[TEST_DATA_WIDTH-1:0];
    end

    $finish;
  end

`ifndef DUMP_FILE
  `define DUMP_FILE ""
`endif

  initial begin
    if (`DUMP_FILE != "") begin
      $dumpfile(`DUMP_FILE);
      $dumpvars(0, tb_delay_buffer);
      $dumpvars(0, tb_delay_buffer.dut.gen_pipe.pipe[0]);
    end
  end

endmodule
