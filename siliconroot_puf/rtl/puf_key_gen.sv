///////////////////////////////////////////////////////
// Module : puf_key_gen
// Author   : najamdesktop\najam
// Description: Secret key generation of Suh and Devadas, DAC 2007, section 5.
//
//              Figure 5 of the paper is the flow this module implements.
//
//                  INITIALISATION            RE-GENERATION
//                  PUF  ->  response  ---+   PUF  ->  response  ---+
//                                        |                        |
//                                        v                        v
//                                     syndrome               syndrome
//                                     (public)               (public)
//                                                                  |
//                                                                  v
//                                                      ECC decoding -> key
//
//              The syndrome of a measurement is its remainder modulo the
//              generator polynomial of the BCH(127,64,21) code. It is public
//              helper data: it reveals at most 63 bits about the response.
//
//              At initialisation the syndrome of the fresh measurement is
//              computed and handed back as helper data, and the key is the
//              SHA-256 of the measurement itself.
//
//              At re-generation the syndrome of the fresh measurement is
//              computed again and differenced with the stored syndrome. The
//              difference is the syndrome of the bit flip pattern that
//              separates the two measurements, and puf_bch_dec turns it back
//              into the bit positions that flipped. The corrected
//              measurement is the measurement of the initialisation run, so
//              the SHA-256 of it is the same key.
//
//              "For cryptographic operations that use a randomly selected
//              number as a key, the output of the error correcting code (ECC)
//              can be simply hashed down to a desired length and used as a
//              cryptographic key."
//
//              The hash input is the corrected 127-bit response. The SHA-256
//              padding is built here rather than inside the hash core, so
//              the core only ever sees one fully prepared block:
//
//                  bit 511 .. 385   the 127 response bits
//                  bit 384          the mandatory one bit
//                  bit 383 .. 64    320 zero bits
//                  bit 63  .. 0     the message length in bits, 127
//
//              127 + 1 + 320 + 64 = 512, so the message plus its padding is
//              exactly one block and no second block is ever hashed.
//
`default_nettype none

module puf_key_gen #(
  parameter int RESP_BITS = 127 // response length, fixed by the BCH code
) (
  input  logic         clk_i    , // clock, rising edge
  input  logic         rst_ni  , // asynchronous reset, active low
  input  logic         start_i , // 1-cycle pulse: start the key derivation
  input  logic         regen_i , // 0 = initialisation, 1 = re-generation
  input  logic [126:0] resp_i  , // the fresh PUF measurement
  input  logic [62:0]  synd_i  , // the syndrome stored at initialisation
  output logic [62:0]  synd_o  , // the syndrome of the fresh measurement
  output logic [255:0] key_o   , // the derived secret key
  output logic [6:0]   err_o   , // bit flips the decoder corrected
  output logic         fail_o  , // 1 when the decode could not be trusted
  output logic         done_o    // 1-cycle completion pulse
);

  // -------------------------------------
  // Constants
  // -------------------------------------
  localparam int MSG_LO   = 512 - RESP_BITS;  // lowest bit of the message
  localparam int PAD_BIT  = MSG_LO - 1;        // the mandatory one bit

  // -------------------------------------
  // Elaboration checks
  // -------------------------------------
  generate
    if (RESP_BITS != 127) begin : g_chk_resp_bits
      initial
        $fatal(1, "puf_key_gen: RESP_BITS=%0d, the BCH(127,64,21) code of the paper needs 127 bits", RESP_BITS);
    end
    if (PAD_BIT < 64) begin : g_chk_pad
      initial
        $fatal(1, "puf_key_gen: a %0d bit message leaves no room for the padding and the length field", RESP_BITS);
    end
  endgenerate

  // -------------------------------------
  // State
  // -------------------------------------
  typedef enum logic [2:0] {
    S_IDLE = 3'd0, // waiting for start_i
    S_ENC  = 3'd1, // encoding the syndrome of the fresh measurement
    S_DEC  = 3'd2, // decoding the difference against the stored syndrome
    S_HASH = 3'd3, // hashing the corrected measurement
    S_FIN  = 3'd4  // presenting the key
  } state_e;

  state_e        state_q;
  logic          regen_q;
  logic [126:0]  resp_q;       // the measurement held for the whole run
  logic [126:0]  corrected_q;  // the measurement after the decoder
  logic [62:0]   synd_q;       // the syndrome of the fresh measurement
  logic [62:0]   diff_q;       // the syndrome difference

  // -------------------------------------
  // The syndrome encoder
  // -------------------------------------
  logic         enc_start_c;
  logic         enc_done_c;
  logic [62:0]  enc_synd_c;

  puf_bch_enc u_enc (
    .clk_i    (clk_i      ),
    .rst_ni   (rst_ni     ),
    .start_i  (enc_start_c),
    .word_i   (resp_q     ),
    .synd_o   (enc_synd_c ),
    .done_o   (enc_done_c )
  );

  // -------------------------------------
  // The syndrome decoder
  // -------------------------------------
  logic         dec_start_c;
  logic         dec_done_c;
  logic [126:0] dec_word_c;
  logic [6:0]   dec_err_c;
  logic         dec_fail_c;

  puf_bch_dec u_dec (
    .clk_i    (clk_i      ),
    .rst_ni   (rst_ni     ),
    .start_i  (dec_start_c),
    .diff_i   (diff_q     ),
    .word_i   (resp_q     ),
    .word_o   (dec_word_c ),
    .err_cnt_o(dec_err_c  ),
    .fail_o   (dec_fail_c ),
    .done_o   (dec_done_c )
  );

  // -------------------------------------
  // The hash
  // -------------------------------------
  logic         sha_start_c;
  logic         sha_done_c;
  logic [255:0] sha_digest_c;
  logic [511:0] blk_c;

  puf_sha256 u_sha (
    .clk_i    (clk_i      ),
    .rst_ni   (rst_ni     ),
    .start_i  (sha_start_c),
    .block_i  (blk_c      ),
    .digest_o (sha_digest_c),
    .done_o   (sha_done_c )
  );

  // -------------------------------------
  // The block that is hashed
  // -------------------------------------
  logic [126:0] msg_c;

  always_comb begin
    msg_c = regen_q ? corrected_q : resp_q;
    blk_c = 512'd0;
    blk_c[511:MSG_LO] = msg_c;
    blk_c[PAD_BIT]    = 1'b1;
    blk_c[63:0]       = 64'(RESP_BITS);
  end

  // -------------------------------------
  // Control
  // -------------------------------------
  always_comb begin
    enc_start_c = (state_q == S_ENC);
    dec_start_c = (state_q == S_DEC);
    sha_start_c = (state_q == S_HASH);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= S_IDLE;
      regen_q    <= 1'b0;
      resp_q     <= 127'd0;
      corrected_q<= 127'd0;
      synd_q     <= 63'd0;
      diff_q     <= 63'd0;
      synd_o     <= 63'd0;
      key_o      <= 256'd0;
      err_o      <= 7'd0;
      fail_o     <= 1'b0;
      done_o     <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        S_IDLE: begin
          if (start_i) begin
            regen_q <= regen_i;
            resp_q  <= resp_i;
            state_q <= S_ENC;
          end
        end

        S_ENC: begin
          if (enc_done_c) begin
            synd_q <= enc_synd_c;
            synd_o <= enc_synd_c;
            if (regen_q) begin
              diff_q <= enc_synd_c ^ synd_i;
              state_q <= S_DEC;
            end else begin
              state_q <= S_HASH;
            end
          end
        end

        S_DEC: begin
          if (dec_done_c) begin
            corrected_q <= dec_word_c;
            err_o       <= dec_err_c;
            fail_o      <= dec_fail_c;
            state_q     <= S_HASH;
          end
        end

        S_HASH: begin
          if (sha_done_c) begin
            key_o   <= sha_digest_c;
            state_q <= S_FIN;
          end
        end

        S_FIN: begin
          done_o <= 1'b1;
          state_q <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule : puf_key_gen
`default_nettype wire
