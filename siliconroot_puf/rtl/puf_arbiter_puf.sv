///////////////////////////////////////////////////////
// Module : puf_arbiter_puf
// Author   : najamdesktop\najam
// Description: The arbiter PUF of Suh and Devadas, DAC 2007, section 2.2,
//              turned into a multi-bit response.
//
//              "There are two ways to construct a k-bit response from the
//              1-bit output of this PUF delay circuit. First, one circuit can
//              be used k times with different inputs. A challenge is used as
//              a seed for a pseudo-random number generator (such as a linear
//              feedback shift register). Then, the PUF delay circuit is
//              evaluated k times, using k different bit vectors from the
//              pseudo-random number generator serving as the input X to
//              configure the delay paths."
//
//              This module implements exactly that: the challenge seeds the
//              generator in puf_prng, the generator produces k different
//              64-bit challenge vectors, and the delay circuit is evaluated
//              once per vector.
//
//              The response is built least significant bit first: response
//              bit zero is the verdict of the first evaluation, so the
//              response of a challenge is a function of the challenge alone
//              and is reproducible on the same chip.
//
//              One evaluation takes 65 clocks, so a 64-bit response takes
//              about 4200 clocks.
//
`default_nettype none

module puf_arbiter_puf #(
  parameter int ARB_BITS = 64 // response bits, the k of the paper
) (
  input  logic         clk_i    , // clock, rising edge
  input  logic         rst_ni  , // asynchronous reset, active low
  input  logic [31:0]  dev_id_i, // device identifier, selects this device's variation
  input  logic [3:0]   env_i   , // environment code, 0 = nominal
  input  logic         start_i , // 1-cycle pulse: evaluate the response
  input  logic [63:0]  seed_i  , // challenge, the seed of the generator
  output logic [ARB_BITS-1:0] resp_o, // the response to the challenge
  output logic         done_o      // 1-cycle completion pulse, resp_o valid
);

  // -------------------------------------
  // Constants
  // -------------------------------------
  localparam int IDX_W = $clog2(ARB_BITS);

  // -------------------------------------
  // Elaboration checks
  // -------------------------------------
  generate
    if (ARB_BITS < 1) begin : g_chk_arb_bits
      initial
        $fatal(1, "puf_arbiter_puf: ARB_BITS=%0d must be at least one", ARB_BITS);
    end
  endgenerate

  // -------------------------------------
  // State
  // -------------------------------------
  typedef enum logic [2:0] {
    S_IDLE = 3'd0, // waiting for start_i
    S_LOAD = 3'd1, // seeding the generator
    S_EVAL = 3'd2, // launching one delay circuit evaluation
    S_WAIT = 3'd3, // waiting for the verdict
    S_FIN  = 3'd4  // presenting the response
  } state_e;

  state_e                    state_q;
  logic [IDX_W-1:0]          idx_q;    // response bit being produced
  logic [ARB_BITS-1:0]       resp_q;
  logic [63:0]               seed_q;

  // -------------------------------------
  // The pseudo-random generator
  // -------------------------------------
  logic [63:0] prng_state_c;
  logic        prng_load_c;
  logic        prng_step_c;

  puf_prng u_prng (
    .clk_i    (clk_i      ),
    .rst_ni   (rst_ni     ),
    .load_i   (prng_load_c),
    .seed_vi  (seed_q     ),
    .step_i   (prng_step_c),
    .state_o  (prng_state_c)
  );

  // -------------------------------------
  // The delay circuit
  // -------------------------------------
  logic        arb_start_c;
  logic        arb_busy_c;
  logic        arb_done_c;
  logic        arb_y_c;

  puf_arbiter_macro u_arb (
    .clk_i    (clk_i    ),
    .rst_ni   (rst_ni   ),
    .dev_id_i (dev_id_i ),
    .env_i    (env_i    ),
    .start_i  (arb_start_c),
    .x_i      (prng_state_c),
    .busy_o   (arb_busy_c),
    .y_o      (arb_y_c   ),
    .done_o   (arb_done_c)
  );

  // -------------------------------------
  // Control
  // -------------------------------------
  always_comb begin
    prng_load_c = (state_q == S_LOAD);
    prng_step_c = (state_q == S_WAIT) && arb_done_c && (idx_q != IDX_W'(ARB_BITS - 1));
    arb_start_c = (state_q == S_EVAL);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      idx_q   <= '0;
      resp_q  <= '0;
      seed_q  <= 64'd0;
      done_o  <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        S_IDLE: begin
          if (start_i) begin
            seed_q <= seed_i;
            idx_q  <= '0;
            resp_q <= '0;
            state_q <= S_LOAD;
          end
        end

        S_LOAD: begin
          // The generator is loaded this cycle, the first challenge vector
          // is available in the next one.
          state_q <= S_EVAL;
        end

        S_EVAL: begin
          state_q <= S_WAIT;
        end

        S_WAIT: begin
          if (arb_done_c) begin
            resp_q[idx_q] <= arb_y_c;
            if (idx_q == IDX_W'(ARB_BITS - 1)) begin
              state_q <= S_FIN;
            end else begin
              idx_q   <= idx_q + 1'b1;
              state_q <= S_EVAL;
            end
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

endmodule : puf_arbiter_puf
`default_nettype wire
