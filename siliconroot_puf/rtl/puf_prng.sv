///////////////////////////////////////////////////////
// Module : puf_prng
// Author   : najamdesktop\najam
// Description: 64-bit Galois LFSR pseudo-random number generator, polynomial
//              x^64 + x^4 + x^3 + x + 1.
//
//              The arbiter PUF of Suh and Devadas, DAC 2007, section 2.2, is
//              turned into a k-bit response by evaluating the one-bit delay
//              circuit k times with different challenge vectors: "A challenge
//              is used as a seed for a pseudo-random number generator (such
//              as a linear feedback shift register). Then, the PUF delay
//              circuit is evaluated k times, using k different bit vectors
//              from the pseudo-random number generator serving as the input X
//              to configure the delay paths."
//
//              This module is that generator. It is a maximal-length Galois
//              LFSR: the state register shifts left, the bit that leaves the
//              top is fed back into the four low taps, and the seed may never
//              be the all-zero state because zero is a fixed point of the
//              shift register. A zero seed is therefore replaced by one.
//
//              The recurrence is
//                  L <- (L << 1) ^ (0x1B if L[63] else 0)
//              with the 0x1B mask covering taps x^4, x^3, x^1 and x^0. The
//              period is 2^64 - 1, so the 64 consecutive states the arbiter
//              PUF consumes for one response are always distinct.
//
//              The state register is the output. Holding step_i high advances
//              the generator once per clock, which is how the arbiter PUF
//              consumes one challenge vector per clock.
///////////////////////////////////////////////////////
`default_nettype none

module puf_prng (
  input  logic        clk_i    , // clock, rising edge
  input  logic        rst_ni  , // asynchronous reset, active low
  input  logic        load_i  , // 1-cycle pulse: load seed_vi into the register
  input  logic [63:0] seed_vi , // seed value, the all-zero seed is replaced by one
  input  logic        step_i  , // advance one step, one step per clock while high
  output logic [63:0] state_o    // current generator state
);

  // -------------------------------------
  // Constants
  // -------------------------------------
  localparam logic [63:0] LFSR_POLY = 64'h0000_0000_0000_001B; // x^4 + x^3 + x + 1

  // -------------------------------------
  // State
  // -------------------------------------
  logic [63:0] state_q;

  // -------------------------------------
  // Next state
  // -------------------------------------
  // The bit selects are written as continuous assignments so that they live
  // outside an always_* process.  Icarus reports a degraded sensitivity for a
  // constant select inside an always block, and a continuous assignment does
  // not need a sensitivity list at all.
  // -------------------------------------
  logic [63:0] state_shift_c;
  logic [63:0] state_next_c;
  logic        fb_c;

  assign fb_c          = state_q[63];
  assign state_shift_c = {state_q[62:0], 1'b0};
  assign state_next_c  = fb_c ? (state_shift_c ^ LFSR_POLY) : state_shift_c;

  // -------------------------------------
  // Main sequencer
  // -------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= 64'h0000_0000_0000_0001;
    end else begin
      if (load_i) begin
        // The all-zero state is a fixed point of a Galois LFSR, so it is
        // replaced by one. The generator then still visits 2^64 - 1 states.
        state_q <= (seed_vi == 64'd0) ? 64'd1 : seed_vi;
      end else if (step_i) begin
        state_q <= state_next_c;
      end
    end
  end

  assign state_o = state_q;

endmodule : puf_prng
`default_nettype wire
