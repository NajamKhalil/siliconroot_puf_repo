///////////////////////////////////////////////////////
// Module : puf_ro_macro
// Author   : najamdesktop\najam
// Description: Functional twin of the ring oscillator array that forms the RO
//              PUF of Suh and Devadas, DAC 2007, section 3.
//
//              PHYSICAL BOUNDARY. Figure 2 of the paper is a ring oscillator
//              array with a MUX, two counters and a comparator. The
//              oscillators are analogue and their frequencies differ from
//              chip to chip; the MUX selects a pair, the two counters count
//              the edges of the two oscillators during a fixed window, and
//              the comparator turns "which one counted more" into one bit.
//              This module is the twin of the array and of the counters; the
//              MUX and the comparator live in puf_ro_sensor.
//
//              THE MODEL. Every oscillator has a frequency
//
//                  f_i = f_nom * (1 + SPREAD * u_i + BIAS * b_i)
//                                  * (1 + w(env)) * (1 + d_i(env))
//
//              u_i is the device specific part of the manufacturing
//              variation and is what makes every chip unique. b_i is a
//              design-common layout bias, the same for every instance of the
//              design; it is the reason the measured inter-chip variation is
//              46 % rather than the ideal 50 %. w(env) is the common mode
//              frequency shift of the environment, which cancels in a pair
//              comparison because both oscillators of a pair move together.
//              d_i(env) is the differential part of the environmental drift;
//              it is what makes a pair of oscillators with almost the same
//              frequency flip its comparison bit while a pair with widely
//              separated frequencies does not. The 1-out-of-k mask of section
//              3.2 exists precisely to always pick a well separated pair.
//
//              The constants were calibrated with an independent model so
//              that the twin reproduces the published figures: 46.15 %
//              inter-chip and 0.48 % intra-chip bit variation.
//
//              A window is opened with win_start_i and the pair counts are
//              read out one pair per clock with rd_en_i and sel_i.
///////////////////////////////////////////////////////
`default_nettype none

module puf_ro_macro #(
  parameter int N_RO   = 1024, // ring oscillators in the array
  parameter int CNT_W  = 16,   // counter width in bits
  parameter int SEL_W  = 9     // pair selector width, one pair is two oscillators
) (
  input  logic         clk_i      , // clock, rising edge
  input  logic         rst_ni    , // asynchronous reset, active low
  input  logic [31:0]  dev_id_i  , // device identifier, selects this device's variation
  input  logic [3:0]   env_i     , // environment code, 0 = nominal
  input  logic         win_start_i, // 1-cycle pulse: open a measurement window
  input  logic [15:0]  win_len_i , // length of the measurement window
  output logic         win_done_o, // the window is open, the counts are final
  input  logic         rd_en_i   , // read request for the pair named by sel_i
  input  logic [SEL_W-1:0] sel_i , // index of the oscillator pair to read
  output logic [2*CNT_W-1:0] cnt_o, // the two oscillator counts of the pair
  output logic         rd_done_o   // the counts are valid
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
    if (N_RO != 1024) begin : g_chk_n_ro
      initial
        $fatal(1, "puf_ro_macro: N_RO=%0d unsupported, the twin models the 1024 ring oscillator array of section 6 of the paper", N_RO);
    end
  endgenerate

  // -------------------------------------
  // Constants (Q16 fixed point)
  // -------------------------------------
  localparam logic signed [31:0] SPREAD_Q = 32'sd36864;  // 0.5625, device spread
  localparam logic signed [31:0] BIAS_Q   = 32'sd16384;  // 0.2500, design common bias
  localparam logic signed [31:0] DIFF_Q   = 32'sd459;    // 0.0070, differential drift
  localparam logic signed [31:0] ONE_Q    = 32'sd65536;  // 1.0 in Q16

  // -------------------------------------
  // State
  // -------------------------------------
  logic [31:0] dev_id_q;
  logic [3:0]  env_q;
  logic [15:0] win_q;
  logic        win_open_q;

  // -------------------------------------
  // The environment code selects the common mode drift
  // -------------------------------------
  logic signed [31:0] w_env_c;

  always_comb begin
    case (env_q)
      4'd0   : w_env_c = 32'sd0;      // nominal
      4'd1   : w_env_c = 32'sd19661;  // 0.30, 20 C -> 120 C
      4'd2   : w_env_c = 32'sd6554;   // 0.10, small change
      4'd3   : w_env_c = 32'sd29491;  // 0.45, extreme
      default: w_env_c = 32'sd0;
    endcase
  end

  // -------------------------------------
  // The frequency of one oscillator, and its count in the window
  //
  // The block is written as continuous assignments rather than as an
  // always_comb process: the constant bit selects would then sit inside an
  // always block, where Icarus reports a degraded sensitivity, and a
  // continuous assignment needs no sensitivity list at all.
  //
  // Every product gets its own 64 bit net so that the Q16 truncation of each
  // one is a select of a single product and not a multiplexed temporary.
  // -------------------------------------
  logic [31:0]        idx_a_c;
  logic [31:0]        idx_b_c;
  logic [31:0]        h_u_a_c;
  logic [31:0]        h_u_b_c;
  logic [31:0]        h_b_a_c;
  logic [31:0]        h_b_b_c;
  logic [31:0]        h_d_a_c;
  logic [31:0]        h_d_b_c;
  logic signed [31:0] u_a_c;
  logic signed [31:0] u_b_c;
  logic signed [31:0] bb_a_c;
  logic signed [31:0] bb_b_c;
  logic signed [31:0] d_a_c;
  logic signed [31:0] d_b_c;
  logic signed [63:0] p_u_a_c;
  logic signed [63:0] p_u_b_c;
  logic signed [63:0] p_bb_a_c;
  logic signed [63:0] p_bb_b_c;
  logic signed [63:0] p_d_a_c;
  logic signed [63:0] p_d_b_c;
  logic signed [63:0] p_fa_c;
  logic signed [63:0] p_fb_c;
  logic signed [63:0] p_f2a_c;
  logic signed [63:0] p_f2b_c;
  logic signed [63:0] p_ca_c;
  logic signed [63:0] p_cb_c;
  logic signed [31:0] term_u_a_c;
  logic signed [31:0] term_u_b_c;
  logic signed [31:0] term_bb_a_c;
  logic signed [31:0] term_bb_b_c;
  logic signed [31:0] term_d_a_c;
  logic signed [31:0] term_d_b_c;
  logic signed [31:0] freq_a_c;
  logic signed [31:0] freq_b_c;
  logic signed [31:0] freq2_a_c;
  logic signed [31:0] freq2_b_c;
  logic signed [31:0] freq3_a_c;
  logic signed [31:0] freq3_b_c;
  logic signed [31:0] cnt_a_c;
  logic signed [31:0] cnt_b_c;

  assign idx_a_c = {22'd0, sel_i, 1'b0};
  assign idx_b_c = {22'd0, sel_i, 1'b0} + 32'd1;

  assign h_u_a_c = puf_pkg::puf_hash32(dev_id_q, 32'h0000_1000 + 32'd2 * idx_a_c);
  assign h_u_b_c = puf_pkg::puf_hash32(dev_id_q, 32'h0000_1000 + 32'd2 * idx_b_c);
  assign u_a_c   = $signed({1'b0, h_u_a_c[31:16], 1'b0}) - 32'sd65536;
  assign u_b_c   = $signed({1'b0, h_u_b_c[31:16], 1'b0}) - 32'sd65536;

  assign h_b_a_c = puf_pkg::puf_hash32(32'hC0FF_EE00, 32'h0000_2000 + idx_a_c);
  assign h_b_b_c = puf_pkg::puf_hash32(32'hC0FF_EE00, 32'h0000_2000 + idx_b_c);
  assign bb_a_c  = $signed({1'b0, h_b_a_c[31:16], 1'b0}) - 32'sd65536;
  assign bb_b_c  = $signed({1'b0, h_b_b_c[31:16], 1'b0}) - 32'sd65536;

  // The differential part of the environmental drift is zero in the nominal
  // environment.
  assign h_d_a_c = (env_q == 4'd0) ? 32'd0
                  : puf_pkg::puf_hash32(dev_id_q, 32'h0000_3000 + idx_a_c
                               + (32'h0000_0100 * {28'd0, env_q}));
  assign h_d_b_c = (env_q == 4'd0) ? 32'd0
                  : puf_pkg::puf_hash32(dev_id_q, 32'h0000_3000 + idx_b_c
                               + (32'h0000_0100 * {28'd0, env_q}));
  assign d_a_c   = (env_q == 4'd0) ? 32'sd0
                  : ($signed({1'b0, h_d_a_c[31:16], 1'b0}) - 32'sd65536);
  assign d_b_c   = (env_q == 4'd0) ? 32'sd0
                  : ($signed({1'b0, h_d_b_c[31:16], 1'b0}) - 32'sd65536);

  assign p_u_a_c  = u_a_c   * SPREAD_Q;
  assign p_u_b_c  = u_b_c   * SPREAD_Q;
  assign p_bb_a_c = bb_a_c  * BIAS_Q;
  assign p_bb_b_c = bb_b_c  * BIAS_Q;
  assign p_d_a_c  = d_a_c   * DIFF_Q;
  assign p_d_b_c  = d_b_c   * DIFF_Q;

  assign term_u_a_c  = p_u_a_c[47:16];
  assign term_u_b_c  = p_u_b_c[47:16];
  assign term_bb_a_c = p_bb_a_c[47:16];
  assign term_bb_b_c = p_bb_b_c[47:16];
  assign term_d_a_c  = p_d_a_c[47:16];
  assign term_d_b_c  = p_d_b_c[47:16];

  assign freq_a_c = ONE_Q + term_u_a_c + term_bb_a_c;
  assign freq_b_c = ONE_Q + term_u_b_c + term_bb_b_c;

  assign p_fa_c = freq_a_c * (ONE_Q + w_env_c);
  assign p_fb_c = freq_b_c * (ONE_Q + w_env_c);
  assign freq2_a_c = p_fa_c[47:16];
  assign freq2_b_c = p_fb_c[47:16];

  assign p_f2a_c = freq2_a_c * (ONE_Q + term_d_a_c);
  assign p_f2b_c = freq2_b_c * (ONE_Q + term_d_b_c);
  assign freq3_a_c = p_f2a_c[47:16];
  assign freq3_b_c = p_f2b_c[47:16];

  assign p_ca_c = freq3_a_c * $signed({16'd0, win_q});
  assign p_cb_c = freq3_b_c * $signed({16'd0, win_q});
  assign cnt_a_c = p_ca_c[47:16];
  assign cnt_b_c = p_cb_c[47:16];

  // -------------------------------------
  // Main sequencer
  // -------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dev_id_q  <= 32'd0;
      env_q     <= 4'd0;
      win_q     <= 16'd0;
      win_open_q <= 1'b0;
      win_done_o <= 1'b0;
      cnt_o     <= '0;
      rd_done_o <= 1'b0;
    end else begin
      win_done_o <= 1'b0;
      rd_done_o <= 1'b0;
      if (win_start_i) begin
        dev_id_q   <= dev_id_i;
        env_q      <= env_i;
        win_q      <= win_len_i;
        win_open_q <= 1'b1;
        win_done_o <= 1'b1;
      end
      if (rd_en_i && win_open_q) begin
        cnt_o[CNT_W-1:0]     <= cnt_a_c[CNT_W-1:0];
        cnt_o[2*CNT_W-1:CNT_W] <= cnt_b_c[CNT_W-1:0];
        rd_done_o <= 1'b1;
      end
    end
  end

endmodule : puf_ro_macro
`default_nettype wire
