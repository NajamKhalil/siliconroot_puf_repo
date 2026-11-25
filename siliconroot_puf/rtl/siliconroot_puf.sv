///////////////////////////////////////////////////////
// Module : siliconroot_puf
// Author   : najamdesktop\najam
// Description: Top level of SiliconRoot-PUF, a PUF based device authentication
//              and secret key generation IP following Suh and Devadas, DAC 2007.
//
//              The block has two PUF engines and the machinery that the two
//              applications of the paper need.
//
//              THE ARBITER PUF (section 2) produces a response to a 64-bit
//              challenge. The challenge seeds a pseudo-random generator and
//              the delay circuit is evaluated once per generated vector, so
//              one challenge gives one 64-bit response.
//
//              THE RO PUF (section 3) produces a 127-bit response with a
//              1-out-of-4 mask (section 3.2) and a challenge that rotates the
//              oscillator pair space (section 3.3).
//
//              AUTHENTICATION (section 4) is the comparison of a fresh
//              response against a recorded one with a tolerance of ten
//              differing bits.
//
//              KEY GENERATION (section 5) is the syndrome based helper data
//              of the BCH(127,64,21) code followed by the SHA-256 of the
//              corrected response.
//
//              The command interface is a single request style port: the host
//              presents a command and its argument, the block runs to
//              completion and raises done_o. The block never blocks; the
//              slowest command, the initialisation of the RO PUF, takes
//              about 1300 clocks.
//
//              The dev_id_i port and the two macro twins are the physical
//              boundary of this design. In silicon the analogue ring
//              oscillator array and the analogue arbiter delay chain replace
//              puf_ro_macro and puf_arbiter_macro, and dev_id_i disappears
//              with them; nothing above the twin boundary changes.
//
`default_nettype none

module siliconroot_puf #(
  parameter int RESP_BITS = 127, // RO PUF response bits
  parameter int ARB_BITS  = 64,  // arbiter PUF response bits
  parameter int K_MASK    = 4,   // candidate pairs per bit, the 1-out-of-k mask
  parameter int N_PAIRS   = 512, // oscillator pairs in the array
  parameter int CHAL_W    = 9,   // challenge width, the rotation of the pair space
  parameter int CNT_W     = 16,  // counter width of the oscillator macro
  parameter int WIN_LEN   = 1024,// measurement window length in counter clocks
  parameter int TOL_BITS  = 10,  // differing bits that still authenticate
  localparam int CAND_W   = (K_MASK <= 1) ? 1 : $clog2(K_MASK), // mask index width
  localparam int MASK_W   = RESP_BITS * CAND_W                 // mask width in bits
) (
  input  logic         clk_i      , // clock, rising edge
  input  logic         rst_ni    , // asynchronous reset, active low
  input  logic [31:0]  dev_id_i  , // device identifier, physical boundary
  input  logic [3:0]   env_i     , // environment code, 0 = nominal
  input  logic         cmd_valid_i, // command is presented
  output logic         cmd_ready_o, // the block accepts a new command
  input  logic [3:0]   cmd_i     , // the command
  input  logic [63:0]  arg_i     , // the command argument
  output logic         done_o    , // 1-cycle completion pulse
  output logic         err_o     , // 1 when the command failed
  output logic [3:0]   status_o  , // 0 = ok, 1 = decode failed, 2 = bad command
  output logic [255:0] key_o     , // the last derived secret key
  output logic [RESP_BITS-1:0] resp_o , // the last RO PUF response
  output logic [ARB_BITS-1:0]  arb_o  , // the last arbiter PUF response
  output logic [62:0]  synd_o    , // the last syndrome, the public helper data
  output logic [MASK_W-1:0] mask_o, // the 1-out-of-k mask
  output logic         auth_ok_o  , // the last authentication verdict
  output logic [7:0]   auth_dist_o  // the distance of the last authentication
);

  // -------------------------------------
  // Commands
  // -------------------------------------
  localparam logic [3:0] CMD_NOP        = 4'd0; // do nothing
  localparam logic [3:0] CMD_ARB_RESP   = 4'd1; // evaluate the arbiter PUF
  localparam logic [3:0] CMD_ARB_AUTH   = 4'd2; // evaluate and authenticate
  localparam logic [3:0] CMD_RO_ENROLL  = 4'd3; // derive the mask and the helper data
  localparam logic [3:0] CMD_RO_REGEN   = 4'd4; // re-generate the key
  localparam logic [3:0] CMD_RO_AUTH    = 4'd5; // evaluate and authenticate
  localparam logic [3:0] CMD_ARB_REF_ST = 4'd6; // record the arbiter response
  localparam logic [3:0] CMD_RO_REF_ST  = 4'd7; // record the RO response

  // -------------------------------------
  // Elaboration checks
  // -------------------------------------
  generate
    if (RESP_BITS != 127) begin : g_chk_resp_bits
      initial
        $fatal(1, "siliconroot_puf: RESP_BITS=%0d, the BCH(127,64,21) code of the paper needs 127 bits", RESP_BITS);
    end
    if (ARB_BITS > 64) begin : g_chk_arb_bits
      initial
        $fatal(1, "siliconroot_puf: ARB_BITS=%0d, the arbiter challenge vector is 64 bits wide", ARB_BITS);
    end
    if (TOL_BITS >= RESP_BITS) begin : g_chk_tol
      initial
        $fatal(1, "siliconroot_puf: TOL_BITS=%0d accepts every possible response", TOL_BITS);
    end
  endgenerate

  // -------------------------------------
  // State
  // -------------------------------------
  typedef enum logic [3:0] {
    S_IDLE      = 4'd0, // waiting for a command
    S_ARB_START = 4'd1, // launching the arbiter PUF
    S_ARB_WAIT  = 4'd2, // waiting for the arbiter PUF
    S_ARB_CMP   = 4'd3, // comparing the arbiter response
    S_RO_START  = 4'd4, // launching the RO PUF
    S_RO_WAIT   = 4'd5, // waiting for the RO PUF
    S_RO_CMP    = 4'd6, // comparing the RO response
    S_KEY_START = 4'd7, // launching the key generation
    S_KEY_WAIT  = 4'd8, // waiting for the key generation
    S_FIN       = 4'd9  // presenting the result
  } state_e;

  state_e                state_q;
  logic [3:0]            cmd_q;
  logic [63:0]           arg_q;
  logic [CHAL_W-1:0]     enrol_chal_q; // the enrolment challenge of the RO PUF
  logic [MASK_W-1:0]     mask_q;       // the 1-out-of-k mask
  logic [62:0]           synd_q;       // the public helper data
  logic [RESP_BITS-1:0]  ro_ref_q;     // the recorded RO response
  logic [ARB_BITS-1:0]   arb_ref_q;    // the recorded arbiter response
  logic [RESP_BITS-1:0]  ro_resp_q;    // the fresh RO response
  logic [ARB_BITS-1:0]   arb_resp_q;   // the fresh arbiter response
  logic [CHAL_W-1:0]     ro_chal_q;    // the challenge of the current run
  logic                  ro_derive_q;  // 1 = derive the mask, 0 = apply it
  logic                  key_regen_q;  // 1 = re-generation, 0 = initialisation

  // -------------------------------------
  // The arbiter PUF
  // -------------------------------------
  logic                 arb_start_c;
  logic                 arb_done_c;
  logic [ARB_BITS-1:0]  arb_res_c;

  puf_arbiter_puf #(
    .ARB_BITS (ARB_BITS)
  ) u_arb (
    .clk_i    (clk_i      ),
    .rst_ni   (rst_ni     ),
    .dev_id_i (dev_id_i   ),
    .env_i    (env_i      ),
    .start_i  (arb_start_c),
    .seed_i   (arg_q      ),
    .resp_o   (arb_res_c  ),
    .done_o   (arb_done_c )
  );

  // -------------------------------------
  // The RO PUF
  // -------------------------------------
  logic                 ro_start_c;
  logic                 ro_done_c;
  logic [RESP_BITS-1:0] ro_res_c;
  logic [MASK_W-1:0]    ro_mask_c;

  puf_ro_sensor #(
    .N_BITS  (RESP_BITS),
    .K_MASK  (K_MASK),
    .N_PAIRS (N_PAIRS),
    .CHAL_W  (CHAL_W),
    .CNT_W   (CNT_W),
    .WIN_LEN (WIN_LEN)
  ) u_ro (
    .clk_i    (clk_i      ),
    .rst_ni   (rst_ni     ),
    .dev_id_i (dev_id_i   ),
    .env_i    (env_i      ),
    .start_i  (ro_start_c ),
    .chal_i   (ro_chal_q  ),
    .derive_i (ro_derive_q),
    .mask_i   (mask_q     ),
    .mask_o   (ro_mask_c  ),
    .resp_o   (ro_res_c   ),
    .done_o   (ro_done_c  )
  );

  // -------------------------------------
  // The key generation
  // -------------------------------------
  logic         key_start_c;
  logic         key_done_c;
  logic [255:0] key_c;
  logic [62:0]  key_synd_c;
  logic [6:0]   key_err_c;
  logic         key_fail_c;

  puf_key_gen #(
    .RESP_BITS (RESP_BITS)
  ) u_key (
    .clk_i    (clk_i      ),
    .rst_ni   (rst_ni     ),
    .start_i  (key_start_c),
    .regen_i  (key_regen_q),
    .resp_i   (ro_resp_q  ),
    .synd_i   (synd_q     ),
    .synd_o   (key_synd_c ),
    .key_o    (key_c      ),
    .err_o    (key_err_c  ),
    .fail_o   (key_fail_c ),
    .done_o   (key_done_c )
  );

  // -------------------------------------
  // The comparators. The two instances never run at the same time, but they
  // have separate handshake nets so that neither of them drives a signal the
  // other one also drives.
  // -------------------------------------
  logic         arb_cmp_start_c;
  logic         arb_cmp_done_c;
  logic         arb_cmp_ok_c;
  logic [7:0]   arb_cmp_dist_c;

  puf_auth #(
    .RESP_BITS (ARB_BITS),
    .TOL_BITS  (TOL_BITS)
  ) u_cmp_arb (
    .clk_i   (clk_i         ),
    .rst_ni  (rst_ni        ),
    .start_i (arb_cmp_start_c),
    .ref_i   (arb_ref_q     ),
    .resp_i  (arb_resp_q    ),
    .diff_o  (              ),
    .dist_o  (arb_cmp_dist_c),
    .ok_o    (arb_cmp_ok_c  ),
    .done_o  (arb_cmp_done_c)
  );

  logic         ro_cmp_start_c;
  logic         ro_cmp_done_c;
  logic         ro_cmp_ok_c;
  logic [7:0]   ro_cmp_dist_c;

  puf_auth #(
    .RESP_BITS (RESP_BITS),
    .TOL_BITS  (TOL_BITS)
  ) u_cmp_ro (
    .clk_i   (clk_i        ),
    .rst_ni  (rst_ni       ),
    .start_i (ro_cmp_start_c),
    .ref_i   (ro_ref_q     ),
    .resp_i  (ro_resp_q    ),
    .diff_o  (             ),
    .dist_o  (ro_cmp_dist_c),
    .ok_o    (ro_cmp_ok_c  ),
    .done_o  (ro_cmp_done_c)
  );

  // -------------------------------------
  // Control
  // -------------------------------------
  always_comb begin
    arb_start_c    = (state_q == S_ARB_START);
    ro_start_c     = (state_q == S_RO_START);
    key_start_c    = (state_q == S_KEY_START);
    arb_cmp_start_c = (state_q == S_ARB_CMP);
    ro_cmp_start_c  = (state_q == S_RO_CMP);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= S_IDLE;
      cmd_q        <= 4'd0;
      arg_q        <= 64'd0;
      enrol_chal_q <= '0;
      mask_q       <= '0;
      synd_q       <= '0;
      ro_ref_q     <= '0;
      arb_ref_q    <= '0;
      ro_resp_q    <= '0;
      arb_resp_q   <= '0;
      ro_chal_q    <= '0;
      ro_derive_q  <= 1'b0;
      key_regen_q  <= 1'b0;
      cmd_ready_o  <= 1'b1;
      done_o       <= 1'b0;
      err_o        <= 1'b0;
      status_o     <= 4'd0;
      key_o        <= 256'd0;
      synd_o       <= 63'd0;
      auth_ok_o    <= 1'b0;
      auth_dist_o  <= 8'd0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        S_IDLE: begin
          cmd_ready_o <= 1'b1;
          if (cmd_valid_i) begin
            cmd_ready_o <= 1'b0;
            cmd_q       <= cmd_i;
            arg_q       <= arg_i;
            err_o       <= 1'b0;
            status_o    <= 4'd0;
            case (cmd_i)
              CMD_ARB_RESP, CMD_ARB_AUTH: begin
                state_q <= S_ARB_START;
              end
              CMD_RO_ENROLL: begin
                ro_derive_q <= 1'b1;
                ro_chal_q   <= arg_i[CHAL_W-1:0];
                key_regen_q <= 1'b0;
                state_q     <= S_RO_START;
              end
              CMD_RO_REGEN: begin
                ro_derive_q <= 1'b0;
                ro_chal_q   <= enrol_chal_q;
                key_regen_q <= 1'b1;
                state_q     <= S_RO_START;
              end
              CMD_RO_AUTH: begin
                ro_derive_q <= 1'b0;
                ro_chal_q   <= arg_i[CHAL_W-1:0];
                state_q     <= S_RO_START;
              end
              CMD_ARB_REF_ST: begin
                arb_ref_q <= arb_o;
                state_q   <= S_FIN;
              end
              CMD_RO_REF_ST: begin
                ro_ref_q <= resp_o;
                state_q  <= S_FIN;
              end
              CMD_NOP: begin
                state_q <= S_FIN;
              end
              default: begin
                err_o    <= 1'b1;
                status_o <= 4'd2;
                state_q  <= S_FIN;
              end
            endcase
          end
        end

        S_ARB_START: begin
          state_q <= S_ARB_WAIT;
        end

        S_ARB_WAIT: begin
          if (arb_done_c) begin
            arb_resp_q <= arb_res_c;
            if (cmd_q == CMD_ARB_AUTH) begin
              state_q <= S_ARB_CMP;
            end else begin
              state_q <= S_FIN;
            end
          end
        end

        S_ARB_CMP: begin
          if (arb_cmp_done_c) begin
            auth_ok_o   <= arb_cmp_ok_c;
            auth_dist_o <= arb_cmp_dist_c;
            state_q     <= S_FIN;
          end
        end

        S_RO_START: begin
          state_q <= S_RO_WAIT;
        end

        S_RO_WAIT: begin
          if (ro_done_c) begin
            ro_resp_q <= ro_res_c;
            if (cmd_q == CMD_RO_AUTH) begin
              state_q <= S_RO_CMP;
            end else begin
              state_q <= S_KEY_START;
            end
          end
        end

        S_RO_CMP: begin
          if (ro_cmp_done_c) begin
            auth_ok_o   <= ro_cmp_ok_c;
            auth_dist_o <= ro_cmp_dist_c;
            state_q     <= S_FIN;
          end
        end

        S_KEY_START: begin
          state_q <= S_KEY_WAIT;
        end

        S_KEY_WAIT: begin
          if (key_done_c) begin
            key_o  <= key_c;
            synd_o <= key_synd_c;
            if (key_fail_c) begin
              err_o    <= 1'b1;
              status_o <= 4'd1;
            end
            if (cmd_q == CMD_RO_ENROLL) begin
              // The mask, the challenge and the helper data are kept for the
              // re-generation run.
              mask_q       <= ro_mask_c;
              enrol_chal_q <= ro_chal_q;
              synd_q       <= key_synd_c;
            end
            state_q <= S_FIN;
          end
        end

        S_FIN: begin
          done_o      <= 1'b1;
          cmd_ready_o <= 1'b1;
          state_q     <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  // The last results are visible on the outputs as well as through the
  // handshake, so the host can read them without a second transaction.
  always_comb begin
    resp_o = ro_resp_q;
    arb_o  = arb_resp_q;
    mask_o = mask_q;
  end

endmodule : siliconroot_puf
`default_nettype wire
