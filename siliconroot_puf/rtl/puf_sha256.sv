///////////////////////////////////////////////////////
// Module : puf_sha256
// Author   : najamdesktop\najam
// Description: FIPS 180-4 SHA-256 for the PUF secret key derivation of Suh
//              and Devadas, DAC 2007, section 5.
//
//              "For cryptographic operations that use a randomly selected
//              number as a key, the output of the error correcting code (ECC)
//              can be simply hashed down to a desired length and used as a
//              cryptographic key."
//
//              The block that is hashed is built by puf_key_gen and is always
//              the same shape: the 127 corrected response bits, the SHA-256
//              padding, and the message length.  Because the message is
//              shorter than one block, this core handles exactly one block
//              and never has to pad a second one.
//
//              The message schedule is the standard rolling sixteen word
//              window: the word that is about to be used is overwritten with
//              the word that is computed, so sixteen registers are enough
//              instead of the sixty four a flat schedule would need.
//
//                  W[t] = sigma1(W[t-2]) + W[t-7] + sigma0(W[t-15]) + W[t-16]
//
//              The two sigma functions of the schedule are NOT the two sigma
//              functions of the round.  FIPS 180-4 defines four of them:
//
//                  sigma0(x) = ROTR7  ^ ROTR18 ^ SHR3
//                  sigma1(x) = ROTR17 ^ ROTR19 ^ SHR10
//                  Sigma0(x) = ROTR2  ^ ROTR13 ^ ROTR22
//                  Sigma1(x) = ROTR6  ^ ROTR11 ^ ROTR25
//
//              The lower case pair builds the schedule, the upper case pair
//              is used by the round function.  Using the round pair in the
//              schedule still produces a well behaved avalanche, which is
//              exactly why the mistake survives a visual review; only the
//              known answer vectors expose it.
//
//              One round per clock, 64 rounds, so 65 clocks from start to
//              done.
//
`default_nettype none

module puf_sha256 (
  input  logic         clk_i   , // clock, rising edge
  input  logic         rst_ni , // asynchronous reset, active low
  input  logic         start_i, // 1-cycle pulse: hash block_i
  input  logic [511:0] block_i, // the single 512-bit message block
  output logic [255:0] digest_o, // the 256-bit digest
  output logic         done_o    // 1-cycle completion pulse, digest_o valid
);

  // The package is referenced with explicit scope resolution rather than with a
  // wildcard import. A wildcard `import puf_pkg::*;` inside a module body is
  // legal SystemVerilog, but the synthesis flow used for this block cannot
  // elaborate it, while the scoped form `puf_pkg::name` resolves identically in
  // the simulator and in the synthesiser.

  // -------------------------------------
  // Elaboration checks
  // -------------------------------------
  generate
    if (64 != 2 * 32) begin : g_chk_noop
      initial
        $fatal(1, "puf_sha256: internal constant check failed");
    end
  endgenerate

  // -------------------------------------
  // Round functions
  // -------------------------------------
  function automatic logic [31:0] sha_rotr(input logic [31:0] x, input logic [5:0] n);
    sha_rotr = (x >> n) | (x << ((32 - n) & 6'h3F));
  endfunction

  // The big sigma pair: the round function.
  function automatic logic [31:0] sha_sig0(input logic [31:0] x);
    sha_sig0 = sha_rotr(x, 6'd2) ^ sha_rotr(x, 6'd13) ^ sha_rotr(x, 6'd22);
  endfunction

  function automatic logic [31:0] sha_sig1(input logic [31:0] x);
    sha_sig1 = sha_rotr(x, 6'd6) ^ sha_rotr(x, 6'd11) ^ sha_rotr(x, 6'd25);
  endfunction

  // The small sigma pair: the message schedule.  These are not the same
  // functions as the round pair above.
  function automatic logic [31:0] sha_ssig0(input logic [31:0] x);
    sha_ssig0 = sha_rotr(x, 6'd7) ^ sha_rotr(x, 6'd18) ^ (x >> 3);
  endfunction

  function automatic logic [31:0] sha_ssig1(input logic [31:0] x);
    sha_ssig1 = sha_rotr(x, 6'd17) ^ sha_rotr(x, 6'd19) ^ (x >> 10);
  endfunction

  function automatic logic [31:0] sha_ch(input logic [31:0] e, input logic [31:0] f, input logic [31:0] g);
    sha_ch = (e & f) ^ (~e & g);
  endfunction

  function automatic logic [31:0] sha_maj(input logic [31:0] a, input logic [31:0] b, input logic [31:0] c);
    sha_maj = (a & b) ^ (a & c) ^ (b & c);
  endfunction

  // -------------------------------------
  // State
  // -------------------------------------
  typedef enum logic [1:0] {
    S_IDLE = 2'd0, // waiting for start_i
    S_RUN  = 2'd1, // one round per clock
    S_FIN  = 2'd2  // presenting the digest
  } state_e;

  state_e        state_q;
  logic [5:0]    t_q;      // round counter, 0..63
  logic [511:0]  w_q;      // the sixteen word message schedule window
  logic [31:0]   a_q;
  logic [31:0]   b_q;
  logic [31:0]   c_q;
  logic [31:0]   d_q;
  logic [31:0]   e_q;
  logic [31:0]   f_q;
  logic [31:0]   g_q;
  logic [31:0]   h_q;

  // -------------------------------------
  // The message schedule
  //
  // The block is written as continuous assignments rather than as an
  // always_comb process: the constant bit selects would then sit inside an
  // always block, where Icarus reports a degraded sensitivity, and a
  // continuous assignment needs no sensitivity list at all.
  // -------------------------------------
  logic [3:0]    widx_c;   // the slot of W that this round uses
  logic [3:0]    i_m2_c;   // slot of W[t-2]
  logic [3:0]    i_m7_c;   // slot of W[t-7]
  logic [3:0]    i_m15_c;  // slot of W[t-15]
  logic [31:0]   wt_c;     // W[t]
  logic [511:0]  w_next_c;

  // One word of the rolling schedule window.
  function automatic logic [31:0] sched_word(input logic [511:0] w,
                                              input logic [3:0]   slot);
    sched_word = w[{slot, 5'd0} +: 32];
  endfunction

  // The word this round uses. Before the sixteenth round the word is simply
  // the one that is already in the slot; from the sixteenth round on it is
  // built from the four words the recurrence names.
  function automatic logic [31:0] sched_next(input logic [511:0] w,
                                              input logic [3:0]   slot,
                                              input logic [5:0]   t);
    logic [31:0] wm2;
    logic [31:0] wm7;
    logic [31:0] wm15;
    begin
      wm2  = sched_word(w, slot - 4'd2);
      wm7  = sched_word(w, slot - 4'd7);
      wm15 = sched_word(w, slot - 4'd15);
      if (t >= 6'd16) sched_next = sha_ssig1(wm2) + wm7 + sha_ssig0(wm15)
                                  + sched_word(w, slot);
      else            sched_next = sched_word(w, slot);
    end
  endfunction

  // The schedule window after this round. The slot of W[t] still holds
  // W[t-16] at this point, so the new value is written back into that slot.
  function automatic logic [511:0] sched_update(input logic [511:0] w,
                                                 input logic [3:0]   slot,
                                                 input logic [5:0]   t,
                                                 input logic [31:0]  wt);
    logic [511:0] n;
    begin
      n = w;
      if (t >= 6'd16) n[{slot, 5'd0} +: 32] = wt;
      sched_update = n;
    end
  endfunction

  assign widx_c  = t_q[3:0];
  assign i_m2_c  = t_q[3:0] - 4'd2;
  assign i_m7_c  = t_q[3:0] - 4'd7;
  assign i_m15_c = t_q[3:0] - 4'd15;
  assign wt_c    = sched_next(w_q, widx_c, t_q);
  assign w_next_c = sched_update(w_q, widx_c, t_q, wt_c);

  // -------------------------------------
  // The round
  // -------------------------------------
  logic [31:0] t1_c;
  logic [31:0] t2_c;

  always_comb begin
    t1_c = h_q
         + sha_sig1(e_q)
         + sha_ch(e_q, f_q, g_q)
         + puf_pkg::sha256_k(t_q[5:0])
         + wt_c;
    t2_c = sha_sig0(a_q) + sha_maj(a_q, b_q, c_q);
  end

  // -------------------------------------
  // Main sequencer
  // -------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q  <= S_IDLE;
      t_q      <= 6'd0;
      w_q      <= 512'd0;
      a_q      <= 32'd0;
      b_q      <= 32'd0;
      c_q      <= 32'd0;
      d_q      <= 32'd0;
      e_q      <= 32'd0;
      f_q      <= 32'd0;
      g_q      <= 32'd0;
      h_q      <= 32'd0;
      digest_o <= 256'd0;
      done_o   <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        S_IDLE: begin
          if (start_i) begin
            // The block is big endian: the first word of the message is the
            // most significant word of the block.
            for (int k = 0; k < 16; k++) begin
              w_q[k*32 +: 32] = block_i[511 - 32*k -: 32];
            end
            a_q <= puf_pkg::sha256_h0(3'd0);
            b_q <= puf_pkg::sha256_h0(3'd1);
            c_q <= puf_pkg::sha256_h0(3'd2);
            d_q <= puf_pkg::sha256_h0(3'd3);
            e_q <= puf_pkg::sha256_h0(3'd4);
            f_q <= puf_pkg::sha256_h0(3'd5);
            g_q <= puf_pkg::sha256_h0(3'd6);
            h_q <= puf_pkg::sha256_h0(3'd7);
            t_q     <= 6'd0;
            state_q <= S_RUN;
          end
        end

        S_RUN: begin
          a_q <= t1_c + t2_c;
          b_q <= a_q;
          c_q <= b_q;
          d_q <= c_q;
          e_q <= d_q + t1_c;
          f_q <= e_q;
          g_q <= f_q;
          h_q <= g_q;
          w_q <= w_next_c;
          t_q <= t_q + 6'd1;
          if (t_q == 6'd63) begin
            state_q <= S_FIN;
          end
        end

        S_FIN: begin
          // The digest is the sum of the working variables and the initial
          // hash values, word by word.
          digest_o <= {a_q + puf_pkg::sha256_h0(3'd0), b_q + puf_pkg::sha256_h0(3'd1),
                       c_q + puf_pkg::sha256_h0(3'd2), d_q + puf_pkg::sha256_h0(3'd3),
                       e_q + puf_pkg::sha256_h0(3'd4), f_q + puf_pkg::sha256_h0(3'd5),
                       g_q + puf_pkg::sha256_h0(3'd6), h_q + puf_pkg::sha256_h0(3'd7)};
          done_o   <= 1'b1;
          state_q  <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule : puf_sha256
`default_nettype wire
