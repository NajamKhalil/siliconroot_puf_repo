///////////////////////////////////////////////////////
// Module : puf_auth
// Author   : najamdesktop\najam
// Description: Tolerance comparison for the challenge-response authentication
//              of Suh and Devadas, DAC 2007, section 4.
//
//              "If the response matches (i.e., is close enough to) the
//              previously recorded one, the IC is authentic." The paper
//              quantifies "close enough" as ten differing bits out of 128,
//              and derives from that a false positive rate of about
//              2.1e-21 and a false negative rate below 5e-11.
//
//              This module is the comparator that turns two responses into a
//              distance and a verdict. The distance is the Hamming weight of
//              the XOR of the two responses; the verdict is the comparison
//              of that distance against the tolerance.
//
//              The paper keeps the recorded challenge-response pairs in a
//              database held by the trusted party, not on the chip. This
//              module implements the comparison so that the IP can offer an
//              on-chip self check as well; the trusted-party variant uses
//              the same distance and the same tolerance, it just keeps the
//              reference on the other side of the wire.
//
//              The distance is counted in groups of eight bits, which keeps
//              the adder tree shallow instead of building a one hundred bit
//              long carry chain.
//
`default_nettype none

module puf_auth #(
  parameter int RESP_BITS = 127, // response length in bits
  parameter int TOL_BITS  = 10   // differing bits that are still accepted
) (
  input  logic                 clk_i   , // clock, rising edge
  input  logic                 rst_ni , // asynchronous reset, active low
  input  logic                 start_i, // 1-cycle pulse: compare resp_i against ref_i
  input  logic [RESP_BITS-1:0] ref_i  , // the recorded response
  input  logic [RESP_BITS-1:0] resp_i , // the fresh response
  output logic [RESP_BITS-1:0] diff_o , // the bits that differ
  output logic [7:0]           dist_o , // the number of bits that differ
  output logic                 ok_o   , // 1 when dist_o is inside the tolerance
  output logic                 done_o    // 1-cycle completion pulse
);

  // -------------------------------------
  // Constants
  // -------------------------------------
  localparam int      NGRP  = (RESP_BITS + 7) / 8;   // eight bit groups
  localparam logic [7:0] TOL_V = TOL_BITS;

  // -------------------------------------
  // Elaboration checks
  // -------------------------------------
  generate
    if (RESP_BITS < 1) begin : g_chk_resp_bits
      initial
        $fatal(1, "puf_auth: RESP_BITS=%0d must be at least one", RESP_BITS);
    end
    if (TOL_BITS >= RESP_BITS) begin : g_chk_tol
      initial
        $fatal(1, "puf_auth: TOL_BITS=%0d accepts every possible response of %0d bits", TOL_BITS, RESP_BITS);
    end
  endgenerate

  // -------------------------------------
  // The differing bits
  // -------------------------------------
  logic [NGRP*8-1:0] ext_c;
  logic [RESP_BITS-1:0] diff_c;

  always_comb begin
    diff_c = resp_i ^ ref_i;
    ext_c  = '0;
    ext_c[RESP_BITS-1:0] = diff_c;
  end

  // Population count of one eight bit group.
  function automatic logic [3:0] pop8(input logic [7:0] v);
    logic [3:0] c;
    int b;
    begin
      c = 4'd0;
      for (b = 0; b < 8; b++) c = c + {3'd0, v[b]};
      pop8 = c;
    end
  endfunction

  // -------------------------------------
  // The distance
  // -------------------------------------
  logic [7:0] dist_c;

  always_comb begin
    dist_c = 8'd0;
    for (int g = 0; g < NGRP; g++) begin
      dist_c = dist_c + {4'd0, pop8(ext_c[g*8 +: 8])};
    end
  end

  // -------------------------------------
  // State
  // -------------------------------------
  typedef enum logic [1:0] {
    S_IDLE = 2'd0, // waiting for start_i
    S_FIN  = 2'd1  // presenting the verdict
  } state_e;

  state_e state_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      diff_o  <= '0;
      dist_o  <= 8'd0;
      ok_o    <= 1'b0;
      done_o  <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        S_IDLE: begin
          if (start_i) begin
            state_q <= S_FIN;
          end
        end

        S_FIN: begin
          diff_o <= diff_c;
          dist_o <= dist_c;
          ok_o   <= (dist_c <= TOL_V);
          done_o <= 1'b1;
          state_q <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule : puf_auth
`default_nettype wire
