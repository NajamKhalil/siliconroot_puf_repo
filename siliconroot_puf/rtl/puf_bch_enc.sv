///////////////////////////////////////////////////////
// Module : puf_bch_enc
// Author   : najamdesktop\najam
// Description: Syndrome encoder for the BCH(127,64,21) helper-data construction
//              of Suh and Devadas, "Physical Unclonable Functions for Device
//              Authentication and Secret Key Generation", DAC 2007, section 5.
//
//              The PUF response is a 127-bit word that is NOT a codeword of the
//              BCH code - it is a physical measurement and it is noisy. What is
//              stored at enrolment is its remainder modulo the generator
//              polynomial g(x), the 63-bit syndrome. At regeneration the same
//              remainder is computed from the fresh measurement and the two are
//              differenced; the difference is the syndrome of the error pattern
//              that separates the two measurements, which is what the decoder
//              in puf_bch_dec needs.
//
//              The remainder is computed by the classical long division of the
//              message polynomial by g(x) with a 63-bit shift register: the
//              message bit that leaves the top of the register selects whether
//              the low 63 bits of g(x) are XORed back in. Bit p of word_i is the
//              coefficient of x^p, and the register is fed most significant
//              coefficient first, so the first bit presented (bit 126) is the
//              coefficient of x^126.
//
//              One bit per clock, 127 clocks from start to done.
///////////////////////////////////////////////////////
`default_nettype none

module puf_bch_enc (
  input  logic         clk_i     , // clock, rising edge
  input  logic         rst_ni   , // asynchronous reset, active low
  input  logic         start_i  , // 1-cycle pulse: start encoding word_i
  input  logic [126:0] word_i   , // 127-bit PUF response, bit p is the coefficient of x^p
  output logic [62:0]  synd_o   , // 63-bit syndrome, the public helper data
  output logic         done_o     // 1-cycle completion pulse, synd_o valid
);

  // The package is referenced with explicit scope resolution rather than with a
  // wildcard import. A wildcard `import puf_pkg::*;` inside a module body is
  // legal SystemVerilog, but the synthesis flow used for this block cannot
  // elaborate it, while the scoped form `puf_pkg::name` resolves identically in
  // the simulator and in the synthesiser.

  // -------------------------------------
  // Encoder state
  // -------------------------------------
  typedef enum logic [1:0] {
    S_IDLE = 2'd0, // waiting for start_i
    S_RUN  = 2'd1  // shifting the 127 message bits through the remainder register
  } state_e;

  state_e        state_q;
  logic [62:0]   rem_q;   // remainder register, holds w(x) mod g(x)
  logic [6:0]    bit_q;   // index of the message bit being shifted in

  // -------------------------------------
  // Remainder update: r <- r*x + b, then reduce by g(x) if the x^63 term
  // overflowed the register.
  //
  // The block is written as continuous assignments rather than as an
  // always_comb process: the constant bit selects would then sit inside an
  // always block, where Icarus reports a degraded sensitivity, and a
  // continuous assignment needs no sensitivity list at all.
  // -------------------------------------
  logic          bit_in_c;
  logic          fb_c;
  logic [62:0]   rem_shift_c;
  logic [62:0]   rem_next_c;

  assign bit_in_c   = word_i[126 - bit_q];
  assign fb_c       = rem_q[62];
  assign rem_shift_c = {rem_q[61:0], bit_in_c};
  assign rem_next_c = fb_c ? (rem_shift_c ^ puf_pkg::BCH_GL) : rem_shift_c;

  // -------------------------------------
  // Main sequencer
  // -------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      rem_q   <= 63'd0;
      bit_q   <= 7'd0;
      synd_o  <= 63'd0;
      done_o  <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        S_IDLE: begin
          if (start_i) begin
            rem_q  <= 63'd0;
            bit_q  <= 7'd0;
            state_q <= S_RUN;
          end
        end
        S_RUN: begin
          rem_q <= rem_next_c;
          if (bit_q == 7'd126) begin
            synd_o  <= rem_next_c;
            done_o  <= 1'b1;
            state_q <= S_IDLE;
          end else begin
            bit_q <= bit_q + 7'd1;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule : puf_bch_enc
`default_nettype wire
