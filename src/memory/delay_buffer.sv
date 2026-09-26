// ============================================================================
// File:        delay_buffer.sv
// Description: Parameterized exact-cycle shift register delay line with diagnostics.
// ============================================================================

`timescale 1ns / 1ps

module delay_buffer #(
    parameter int DEPTH      = 16,
    parameter int DATA_WIDTH = 32
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  enable,
    input  logic [DATA_WIDTH-1:0] din,
    output logic [DATA_WIDTH-1:0] dout
);

  generate
    if (DEPTH <= 0) begin : gen_zero
      assign dout = din;
    end else begin : gen_pipe
      logic [DATA_WIDTH-1:0] pipe[0:DEPTH-1];
      int i;

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          for (i = 0; i < DEPTH; i = i + 1) begin
            pipe[i] <= '0;
          end
        end else begin
          if (enable) begin
            for (i = DEPTH - 1; i > 0; i = i - 1) begin
              pipe[i] <= pipe[i-1];
            end
            pipe[0] <= din;
          end
        end
      end

      assign dout = pipe[DEPTH-1];
    end
  endgenerate
endmodule
