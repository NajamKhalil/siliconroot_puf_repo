///////////////////////////////////////////////////////
// Module : puf_ro_sensor
// Author   : najamdesktop\najam
// Description: Ring oscillator PUF front end of Suh and Devadas, DAC 2007,
//              sections 3.1, 3.2 and 3.3.
//
//              It owns the oscillator array macro, the MUX that picks an
//              oscillator pair, the comparator that turns a pair comparison
//              into a bit, the 1-out-of-k reliability mask of section 3.2 and
//              the challenge rotation of section 3.3.
//
//              THE 1-OUT-OF-K MASK. "This sequence now needs to be k times
//              longer than the desired number of bits to be generated. Then,
//              for each k ring oscillator pairs, we choose the pair that has
//              maximum distance. The bit vector indicating these selections
//              is saved so that the same pairs can be used to re-generate the
//              output." The distance of a pair is the distance of the two
//              oscillator frequencies, which the counters see as the distance
//              of the two counts. Four candidate pairs are offered per
//              output bit and the widest one is taken; the two bit index of
//              the winner is the mask.
//
//              THE CHALLENGE. Section 3.3 asks for exponentially many
//              challenge-response pairs out of an oscillator array that
//              natively produces only a few bits. The challenge here is a
//              rotation of the pair space: the candidate pair of output bit i
//              and rank k is the pair
//
//                  p(i, k) = (i * k_mask + k + challenge) mod n_pairs
//
//              Because k_mask times the bit index plus the rank covers the
//              pair space without repetition, the rotation is a bijection for
//              every challenge value, so the four candidates of one bit are
//              always four different pairs. A 512 pair array therefore offers
//              512 challenge-response pairs, a reduced but real instance of
//              the challenge space the paper describes.
//
//              The mask is stored against the enrolment challenge and is
//              replayed with it when the key is regenerated, which is what
//              makes the regenerated response reproducible. A challenge used
//              for authentication may be any value: the same mask indices are
//              then applied to the rotated pairs.
//
//              One pair is read every two clocks, so a derivation of 127 bits
//              from 508 candidate pairs takes about 1150 clocks and an
//              application with a stored mask takes about 260.
//
`default_nettype none

module puf_ro_sensor #(
  parameter int N_BITS  = 127, // PUF response bits
  parameter int K_MASK  = 4,   // candidate pairs per bit, the 1-out-of-k mask
  parameter int N_PAIRS = 512, // oscillator pairs in the array
  parameter int CHAL_W  = 9,   // challenge width, the rotation of the pair space
  parameter int CNT_W   = 16,  // counter width of the oscillator macro
  parameter int WIN_LEN = 1024 // measurement window length in counter clocks
) (
  input  logic         clk_i    , // clock, rising edge
  input  logic         rst_ni  , // asynchronous reset, active low
  input  logic [31:0]  dev_id_i, // device identifier, selects this device's variation
  input  logic [3:0]   env_i   , // environment code, 0 = nominal
  input  logic         start_i , // 1-cycle pulse: measure the PUF
  input  logic [CHAL_W-1:0] chal_i, // challenge, the rotation of the pair space
  input  logic         derive_i, // 1 = derive the mask, 0 = apply mask_i
  input  logic [MASK_W-1:0] mask_i, // mask to apply
  output logic [MASK_W-1:0] mask_o, // the mask that produced the response
  output logic [N_BITS-1:0] resp_o, // the PUF response
  output logic         done_o    // 1-cycle completion pulse
);

  // -------------------------------------
  // Derived widths
  // -------------------------------------
  // The mask entry of one output bit is the index of the winning candidate,
  // so it is log2(K_MASK) bits wide and not K_MASK bits wide.
  localparam int CAND_W  = (K_MASK <= 1) ? 1 : $clog2(K_MASK);
  localparam int MASK_W  = N_BITS * CAND_W;
  localparam int PAIR_W  = $clog2(N_PAIRS);
  localparam int BIT_W   = $clog2(N_BITS);

  // -------------------------------------
  // Elaboration checks
  // -------------------------------------
  generate
    if ((N_PAIRS & (N_PAIRS - 1)) != 0) begin : g_chk_n_pairs
      initial
        $fatal(1, "puf_ro_sensor: N_PAIRS=%0d must be a power of two so that the challenge rotation is a plain mask", N_PAIRS);
    end
    if ((N_BITS * K_MASK) > N_PAIRS) begin : g_chk_capacity
      initial
        $fatal(1, "puf_ro_sensor: N_BITS=%0d times K_MASK=%0d exceeds the %0d available oscillator pairs", N_BITS, K_MASK, N_PAIRS);
    end
    if ((1 << CAND_W) < K_MASK) begin : g_chk_cand_w
      initial
        $fatal(1, "puf_ro_sensor: CAND_W=%0d cannot hold the %0d candidate ranks", CAND_W, K_MASK);
    end
    if (N_BITS > (1 << BIT_W)) begin : g_chk_bit_w
      initial
        $fatal(1, "puf_ro_sensor: BIT_W=%0d cannot hold the %0d output bits", BIT_W, N_BITS);
    end
  endgenerate

  // -------------------------------------
  // Constants
  // -------------------------------------
  localparam logic [CAND_W-1:0]  LAST_CAND = K_MASK - 1;
  localparam logic [BIT_W-1:0]   LAST_BIT  = N_BITS - 1;
  localparam logic [15:0]        WIN_LEN_V = WIN_LEN;

  // -------------------------------------
  // State
  // -------------------------------------
  typedef enum logic [2:0] {
    S_IDLE = 3'd0, // waiting for start_i
    S_WIN  = 3'd1, // opening the measurement window
    S_CAP  = 3'd2, // requesting the counts of the candidate pair
    S_RDY  = 3'd3, // waiting for the counts
    S_DEC  = 3'd4, // choosing the mask entry and storing the response bit
    S_FIN  = 3'd5  // presenting the result
  } state_e;

  state_e                   state_q;
  logic [CHAL_W-1:0]        chal_q;
  logic                     derive_q;
  logic [BIT_W-1:0]         bit_q;        // output bit being produced
  logic [CAND_W-1:0]        cand_q;       // candidate rank being read
  logic [K_MASK-1:0]        cand_bit_q;   // the comparison bit of each candidate
  logic [K_MASK*CNT_W-1:0]  cand_dist_q;  // the distance of each candidate
  logic [MASK_W-1:0]        mask_q;
  logic [N_BITS-1:0]        resp_q;

  // -------------------------------------
  // The pair that is being read
  //
  // The block is written as continuous assignments rather than as an
  // always_comb process: the constant bit selects would then sit inside an
  // always block, where Icarus reports a degraded sensitivity, and a
  // continuous assignment needs no sensitivity list at all.
  // -------------------------------------
  logic [31:0] pair_base_c;
  logic [31:0] pair_sum_c;
  logic [PAIR_W-1:0] pair_sel_c;

  assign pair_base_c = (32'(bit_q) * 32'(K_MASK)) + 32'(cand_q);
  assign pair_sum_c  = pair_base_c + 32'(chal_q);
  assign pair_sel_c  = pair_sum_c[PAIR_W-1:0];

  // -------------------------------------
  // The counts of the pair that came back
  // -------------------------------------
  logic [2*CNT_W-1:0] cnt_i;
  logic               rd_done_i;
  logic               win_done_i;
  logic [CNT_W-1:0]   cnt_a_c;
  logic [CNT_W-1:0]   cnt_b_c;
  logic [CNT_W-1:0]   dist_c;
  logic               bit_c;

  assign cnt_a_c = cnt_i[CNT_W-1:0];
  assign cnt_b_c = cnt_i[2*CNT_W-1:CNT_W];
  assign dist_c  = (cnt_a_c >= cnt_b_c) ? (cnt_a_c - cnt_b_c) : (cnt_b_c - cnt_a_c);
  assign bit_c   = (cnt_a_c > cnt_b_c);

  // -------------------------------------
  // The widest candidate of this bit
  // -------------------------------------
  logic [CAND_W-1:0] best_k_c;
  logic [CNT_W-1:0]  best_d_c;
  logic              best_b_c;

  always_comb begin
    best_k_c = '0;
    best_d_c = {CNT_W{1'b0}};
    best_b_c = 1'b0;
    for (int k = 0; k < K_MASK; k++) begin
      if (cand_dist_q[k*CNT_W +: CNT_W] > best_d_c) begin
        best_d_c = cand_dist_q[k*CNT_W +: CNT_W];
        best_k_c = CAND_W'(k);
        best_b_c = cand_bit_q[k];
      end
    end
  end

  // -------------------------------------
  // The rank the mask asks for on the next bit.
  //
  // The read is guarded so that it is only performed while there is a next
  // bit: an unguarded read of the entry past the last one would be an
  // out-of-range part select.
  // -------------------------------------
  logic [BIT_W:0]      bit_next_c;
  logic [31:0]         mask_base_c;
  logic [CAND_W-1:0]   mask_next_c;

  always_comb begin
    bit_next_c  = {1'b0, bit_q} + 1'b1;
    mask_base_c = 32'd0;
    mask_next_c = '0;
    if (bit_q != LAST_BIT) begin
      mask_base_c = bit_next_c * CAND_W;
      mask_next_c = mask_q[mask_base_c +: CAND_W];
    end
  end

  // The rank the mask asks for on the very first bit.  The derivation path
  // starts at rank zero and lets the widest candidate win, the application
  // path has to start at the rank the mask recorded for the first bit.
  logic [CAND_W-1:0] mask_first_c;

  assign mask_first_c = mask_i[CAND_W-1:0];

  // -------------------------------------
  // Macro interface
  // -------------------------------------
  logic win_start_c;
  logic rd_en_c;

  always_comb begin
    win_start_c = (state_q == S_WIN);
    rd_en_c     = (state_q == S_CAP);
  end

  puf_ro_macro #(
    .N_RO  (2 * N_PAIRS),
    .CNT_W (CNT_W),
    .SEL_W (PAIR_W)
  ) u_macro (
    .clk_i       (clk_i       ),
    .rst_ni      (rst_ni      ),
    .dev_id_i    (dev_id_i    ),
    .env_i       (env_i       ),
    .win_start_i (win_start_c ),
    .win_len_i   (WIN_LEN_V   ),
    .win_done_o  (win_done_i  ),
    .rd_en_i     (rd_en_c     ),
    .sel_i       (pair_sel_c  ),
    .cnt_o       (cnt_i       ),
    .rd_done_o   (rd_done_i   )
  );

  // -------------------------------------
  // Main sequencer
  // -------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= S_IDLE;
      chal_q      <= '0;
      derive_q    <= 1'b0;
      bit_q       <= '0;
      cand_q      <= '0;
      cand_bit_q  <= '0;
      cand_dist_q <= '0;
      mask_q      <= '0;
      resp_q      <= '0;
      done_o      <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        S_IDLE: begin
          if (start_i) begin
            chal_q   <= chal_i;
            derive_q <= derive_i;
            bit_q    <= '0;
            cand_bit_q  <= '0;
            cand_dist_q <= '0;
            mask_q   <= mask_i;
            resp_q   <= '0;
            // The first candidate is rank zero when the mask is derived and
            // the rank the mask recorded when it is applied.
            if (derive_i) begin
              cand_q <= '0;
            end else begin
              cand_q <= mask_first_c;
            end
            state_q  <= S_WIN;
          end
        end

        S_WIN: begin
          if (win_done_i) begin
            state_q <= S_CAP;
          end
        end

        S_CAP: begin
          // The macro registers the counts of the selected pair, they are
          // taken one clock later.
          state_q <= S_RDY;
        end

        S_RDY: begin
          if (rd_done_i) begin
            cand_bit_q[cand_q]                   <= bit_c;
            cand_dist_q[cand_q*CNT_W +: CNT_W]   <= dist_c;
            if (derive_q) begin
              if (cand_q == LAST_CAND) begin
                state_q <= S_DEC;
              end else begin
                cand_q  <= cand_q + 1'b1;
                state_q <= S_CAP;
              end
            end else begin
              resp_q[bit_q] <= bit_c;
              if (bit_q == LAST_BIT) begin
                state_q <= S_FIN;
              end else begin
                bit_q  <= bit_q + 1'b1;
                cand_q <= mask_next_c;
                state_q <= S_CAP;
              end
            end
          end
        end

        S_DEC: begin
          // The widest of the k candidates wins, the index of the winner is
          // the mask entry of this bit.
          mask_q[bit_q*CAND_W +: CAND_W] <= best_k_c;
          resp_q[bit_q]                 <= best_b_c;
          if (bit_q == LAST_BIT) begin
            state_q <= S_FIN;
          end else begin
            bit_q       <= bit_q + 1'b1;
            cand_q      <= '0;
            cand_bit_q  <= '0;
            cand_dist_q <= '0;
            state_q     <= S_CAP;
          end
        end

        S_FIN: begin
          resp_o <= resp_q;
          done_o <= 1'b1;
          state_q <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  // The mask is passed through unchanged when it is applied rather than
  // derived, so the caller always sees the mask that produced the response.
  assign mask_o = mask_q;

endmodule : puf_ro_sensor
`default_nettype wire
