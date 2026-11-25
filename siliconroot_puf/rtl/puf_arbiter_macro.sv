///////////////////////////////////////////////////////
// Module : puf_arbiter_macro
// Author   : najamdesktop\najam
// Description: Functional twin of the 64-stage arbiter PUF delay circuit of
//              Suh and Devadas, DAC 2007, section 2.2 and figure 1.
//
//              PHYSICAL BOUNDARY. The circuit this module models is analogue.
//              Sixty-four stages of two cross-coupled MUXes form two delay
//              paths of equal layout length; a rising edge is launched into
//              both, they race, and an arbiter latch at the end latches
//              whichever arrives first. The output is 1 when the signal at
//              the latch data input is faster. None of that can be expressed
//              in RTL, so this module is the twin the rest of the IP is
//              verified against; in silicon the twin is replaced by the
//              analogue macro and the interface stays the same.
//
//              THE MODEL. Every stage i contains a MUX in the top line and a
//              MUX in the bottom line. The pair is a switching box: when
//              X[i] is zero the two signals pass straight through, when
//              X[i] is one they are exchanged. Let T_i and B_i be the delays
//              of the top and the bottom MUX of stage i and let p_i be the
//              parity of the swaps in the stages before i:
//
//                  delay(top signal)   = sum_i (p_i ? B_i : T_i)
//                  delay(bottom signal) = sum_i (p_i ? T_i : B_i)
//                  delay(top) - delay(bottom) = sum_i (p_i ? -d_i : d_i)
//
//              with d_i = T_i - B_i the skew of stage i. The arbiter reports
//              1 when the top path is faster, that is when the accumulator
//              is negative. The accumulator is a signed sum whose signs
//              follow the prefix parity of X, which is what makes the
//              response a strongly non-linear function of the challenge.
//
//              THE DEVICE VARIATION. d_i is split into a design-common part
//              and a device-specific part. The design-common part models the
//              inherent skew of the arbiter latch and of the auto-routed
//              wires, the same for every instance of the design; the paper
//              notes that removing those skews would raise the inter-chip
//              variation from the measured 23 % towards the ideal 50 %. The
//              device-specific part models the manufacturing variation that
//              makes every chip unique, and it is derived from dev_id_i.
//
//              An environment code perturbs every stage slightly, which models
//              the temperature and supply sensitivity of the delay chain.
//
//              The constants were calibrated with an independent model so
//              that the twin reproduces the published figures: 23 % inter-chip
//              and 0.7 % intra-chip bit variation.
///////////////////////////////////////////////////////
`default_nettype none

module puf_arbiter_macro #(
  parameter int ARB_STAGES = 64  // number of MUX stages in the delay chain
) (
  input  logic         clk_i    , // clock, rising edge
  input  logic         rst_ni  , // asynchronous reset, active low
  input  logic [31:0]  dev_id_i, // device identifier, selects this device's variation
  input  logic [3:0]   env_i   , // environment code, 0 = nominal
  input  logic         start_i , // 1-cycle pulse: start evaluating x_i
  input  logic [63:0]  x_i     , // challenge vector X that configures the delay paths
  output logic         busy_o  , // the chain is being walked
  output logic         y_o     , // arbiter verdict, 1 when the top path is faster
  output logic         done_o    // 1-cycle completion pulse, y_o valid
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
    if (ARB_STAGES != 64) begin : g_chk_arb_stages
      initial
        $fatal(1, "puf_arbiter_macro: ARB_STAGES=%0d unsupported, the twin models the 64-stage arbiter PUF of section 2.3 of the paper", ARB_STAGES);
    end
  endgenerate

  // -------------------------------------
  // Constants (Q16 fixed point)
  // -------------------------------------
  // The stage skew is a 20 bit signed Q16 quantity: the design common part,
  // the device specific part and the environmental part are added, and their
  // sum has to fit without wrapping.  1.05 + 1.0 + 0.048 = 2.098 needs 20 bits
  // of signed range, an 18 bit register would wrap.
  localparam logic signed [19:0] C_SKEW_Q = 20'sd68813;  // 1.050, design common skew
  localparam logic signed [19:0] PERT_Q   = 20'sd3146;   // 0.048, environment perturbation
  localparam int               SK_W     = 20;           // width of one stage skew
  localparam int               ACC_W    = 26;           // accumulator width in bits
  localparam int               STG_W    = 6;            // stage index width

  // -------------------------------------
  // State
  // -------------------------------------
  typedef enum logic [1:0] {
    S_IDLE = 2'd0, // waiting for start_i
    S_WALK = 2'd1, // walking the delay chain, one stage per clock
    S_DONE = 2'd2  // presenting the verdict
  } state_e;

  state_e           state_q;
  logic [63:0]      x_q;      // the challenge vector being evaluated
  logic [STG_W-1:0] stg_q;    // stage index, 0 .. ARB_STAGES-1
  logic             par_q;    // parity of the swaps in the stages before stg_q
  logic signed [ACC_W-1:0] acc_q; // signed sum of the stage skews
  logic             y_q;      // the arbiter verdict
  logic [31:0]      dev_id_q;
  logic [3:0]       env_q;

  // -------------------------------------
  // The skew of the stage currently being walked
  //
  // The block is written as continuous assignments rather than as an
  // always_comb process: the constant bit selects would then sit inside an
  // always block, where Icarus reports a degraded sensitivity, and a
  // continuous assignment needs no sensitivity list at all.
  // -------------------------------------
  logic [31:0]           h_rand_c;
  logic [31:0]           h_pert_c;
  logic signed [SK_W-1:0] u_rand_c;  // device specific part, Q16 in [-1,1)
  logic signed [SK_W-1:0] u_pert_c;  // environment part, Q16 in [-1,1)
  logic signed [2*SK_W-1:0] mul_pert_c;
  logic signed [2*SK_W-1:0] shr_pert_c;
  logic signed [SK_W-1:0] sk_pert_c;
  logic signed [SK_W-1:0] sk_c;      // the skew of this stage
  logic signed [ACC_W-1:0] sk_ext_c;

  assign h_rand_c = puf_pkg::puf_hash32(dev_id_q, 32'h0000_4000 + {26'd0, stg_q});
  assign u_rand_c = $signed({3'b0, h_rand_c[31:16], 1'b0}) - 20'sd65536;

  // The environment part is zero in the nominal environment, so that the
  // stage skew is the design common skew plus the device specific part.
  assign h_pert_c = (env_q == 4'd0) ? 32'd0
                  : puf_pkg::puf_hash32(dev_id_q,
                               32'h0000_6000 + {26'd0, stg_q}
                               + (32'h0000_0100 * {28'd0, env_q}));
  assign u_pert_c = (env_q == 4'd0) ? 20'sd0
                  : ($signed({3'b0, h_pert_c[31:16], 1'b0}) - 20'sd65536);

  assign mul_pert_c = u_pert_c * PERT_Q;
  assign shr_pert_c = mul_pert_c >>> 16;
  assign sk_pert_c = shr_pert_c[SK_W-1:0];

  assign sk_c     = C_SKEW_Q + u_rand_c + sk_pert_c;
  assign sk_ext_c = {{(ACC_W-SK_W){sk_c[SK_W-1]}}, sk_c};

  // -------------------------------------
  // Main sequencer
  // -------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q  <= S_IDLE;
      x_q      <= 64'd0;
      stg_q    <= '0;
      par_q    <= 1'b0;
      acc_q    <= '0;
      y_q      <= 1'b0;
      dev_id_q <= 32'd0;
      env_q    <= 4'd0;
      done_o   <= 1'b0;
      busy_o   <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        S_IDLE: begin
          busy_o <= 1'b0;
          if (start_i) begin
            x_q      <= x_i;
            dev_id_q <= dev_id_i;
            env_q    <= env_i;
            stg_q    <= '0;
            par_q    <= 1'b0;
            acc_q    <= '0;
            busy_o   <= 1'b1;
            state_q  <= S_WALK;
          end
        end

        S_WALK: begin
          // The signal that ends up on the top line carries the top MUX delay
          // of a stage while the parity before that stage is even and the
          // bottom MUX delay while it is odd.
          if (par_q) acc_q <= acc_q - sk_ext_c;
          else       acc_q <= acc_q + sk_ext_c;
          par_q <= par_q ^ x_q[stg_q];
          if (stg_q == 6'd63) begin
            state_q <= S_DONE;
          end else begin
            stg_q <= stg_q + 6'd1;
          end
        end

        S_DONE: begin
          y_q     <= (acc_q < 0);
          done_o  <= 1'b1;
          busy_o  <= 1'b0;
          state_q <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  assign y_o = y_q;

endmodule : puf_arbiter_macro
`default_nettype wire
