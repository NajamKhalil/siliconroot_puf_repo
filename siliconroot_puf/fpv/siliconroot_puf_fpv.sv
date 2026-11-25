///////////////////////////////////////////////////////
// File    : siliconroot_puf_fpv.sv
// Author   : najamdesktop\najam
// Description: The formal properties of SiliconRoot-PUF, a PUF based device
//              authentication and secret key generation IP.
//
//              These properties are NOT part of the delivered gates. They are
//              compiled only when `INCLUDE_FPV is defined, and they are
//              attached to the design by an explicit instantiation, never by
//              a `bind.
//
//              WHY EXPLICIT INSTANTIATION AND NOT `bind
//
//              The reference corpus attaches its assertion module by
//              instantiating it from the RTL under `ifdef INCLUDE_FPV.
//              That is also what this file is written for. A `bind would be
//              tidier, because it would leave the RTL alone, but no tool on
//              the host that can actually run these properties understands
//              it: Icarus Verilog 12 rejects the keyword outright, yosys
//              parses it and then silently ignores it, and sv2v 0.0.13
//              fails to parse it. An attachment mechanism that no available
//              tool honours is an attachment mechanism that is never
//              exercised, so the properties are attached the way the
//              reference corpus does it.
//
//              WHY IMMEDIATE ASSERTIONS AND NOT `assert property
//
//              The reference corpus writes its properties as concurrent
//              assertions with a clocking block and a generic property
//              wrapper. That syntax needs a full SVA engine. The tools
//              that are installed here cannot elaborate it:
//
//                Icarus Verilog 12 supports only the bare boolean form
//                  `assert property (a == b)', and needs the
//                  -gsupported-assertions switch to accept even that. It
//                  has no named property declarations, no |-> or |=>, no
//                  ## delays, no $past and no bind.
//                yosys 0.69 in formal mode accepts a bare boolean
//                  assertion, but not a clocking event, not |->, not |=> and
//                  not ##.
//
//              So the rules are written here as immediate assertions inside
//              clocked always blocks, with the one cycle delay spelled out
//              by an explicit past register. That form is ordinary
//              SystemVerilog, and it is the one form that all three of the
//              installed tools understand:
//
//                Icarus Verilog executes it during simulation, so the
//                  rules are checked against the running design.
//                yosys turns it into a $assert cell, which is the form a
//                  proof script would consume. No proof script is shipped;
//                  this file is compiled and checked in simulation only.
//                Verible parses it, so the file is known to be
//                  syntactically well formed.
//
//              The past register of a property is the value the signal had
//              one clock earlier, so
//
//                  a |=> b        is written as   b || !$past(a)
//
//              and
//
//                  a |-> b        is written as   !a || b
//
//              Every property is named in the comment immediately above it;
//              Icarus reports the source line, so the name is still easy to
//              find when an assertion fails.
//
//              NOTHING HERE IS PROVEN AS SHIPPED. There is no proof harness
//              or .ys script in fpv/, and these modules are not instantiated
//              by the delivered RTL. Compile with +define+INCLUDE_FPV to
//              check them for syntax and to attach them in a separate proof
//              harness. Until then the sequencer and decoder rules are
//              checked dynamically by tb_siliconroot_puf.sv, and formal
//              coverage is recorded as not done in the verification report.
// `default_nettype none

`ifdef INCLUDE_FPV

// ---------------------------------------------------------------------------
// The command sequencer of the top level
// ---------------------------------------------------------------------------
module puf_top_props (
  input logic        clk_i          ,
  input logic        rst_ni         ,
  input logic        cmd_valid_i    ,
  input logic        cmd_ready_o    ,
  input logic [3:0]  cmd_i          ,
  input logic [63:0] arg_i          ,
  input logic        done_o         ,
  input logic        err_o          ,
  input logic [3:0]  state_q        , // the state of the sequencer
  input logic [3:0]  cmd_q          , // the captured command
  input logic [63:0] arg_q          , // the captured argument
  input logic        arb_start_c    , // the five start strobes
  input logic        ro_start_c     ,
  input logic        key_start_c    ,
  input logic        arb_cmp_start_c,
  input logic        ro_cmp_start_c
);

  // The states of the sequencer, the same encoding as the top level.
  localparam logic [3:0] S_IDLE      = 4'd0;
  localparam logic [3:0] S_ARB_START = 4'd1;
  localparam logic [3:0] S_ARB_WAIT  = 4'd2;
  localparam logic [3:0] S_ARB_CMP   = 4'd3;
  localparam logic [3:0] S_RO_START  = 4'd4;
  localparam logic [3:0] S_RO_WAIT   = 4'd5;
  localparam logic [3:0] S_RO_CMP    = 4'd6;
  localparam logic [3:0] S_KEY_START = 4'd7;
  localparam logic [3:0] S_KEY_WAIT  = 4'd8;
  localparam logic [3:0] S_FIN       = 4'd9;

  // -----------------------------------------------------------------------
  // The past registers. Each one holds the value its signal had one clock
  // earlier, which is what the one cycle delay of a property is written
  // with.
  // -----------------------------------------------------------------------
  logic        cmd_valid_i_d;
  logic        cmd_ready_o_d;
  logic [3:0]  cmd_i_d;
  logic [63:0] arg_i_d;
  logic        done_o_d;
  logic [3:0]  state_q_d;
  logic        arb_start_c_d;
  logic        ro_start_c_d;
  logic        key_start_c_d;
  logic        arb_cmp_start_c_d;
  logic        ro_cmp_start_c_d;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cmd_valid_i_d    <= 1'b0;
      cmd_ready_o_d    <= 1'b0;
      cmd_i_d          <= 4'd0;
      arg_i_d          <= 64'd0;
      done_o_d         <= 1'b0;
      state_q_d        <= 4'd0;
      arb_start_c_d    <= 1'b0;
      ro_start_c_d     <= 1'b0;
      key_start_c_d    <= 1'b0;
      arb_cmp_start_c_d<= 1'b0;
      ro_cmp_start_c_d <= 1'b0;
    end else begin
      cmd_valid_i_d    <= cmd_valid_i;
      cmd_ready_o_d    <= cmd_ready_o;
      cmd_i_d          <= cmd_i;
      arg_i_d          <= arg_i;
      done_o_d         <= done_o;
      state_q_d        <= state_q;
      arb_start_c_d    <= arb_start_c;
      ro_start_c_d     <= ro_start_c;
      key_start_c_d    <= key_start_c;
      arb_cmp_start_c_d<= arb_cmp_start_c;
      ro_cmp_start_c_d <= ro_cmp_start_c;
    end
  end

  // -----------------------------------------------------------------------
  // A command that has been accepted has not been finished yet. The flag is
  // raised by the handshake and lowered when the sequencer is idle again, so
  // it says "a command is running" without looking at the state machine.
  // -----------------------------------------------------------------------
  logic seen_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      seen_q <= 1'b0;
    end else if (cmd_valid_i && cmd_ready_o) begin
      seen_q <= 1'b1;
    end else if (state_q == S_IDLE) begin
      seen_q <= 1'b0;
    end
  end

  // -----------------------------------------------------------------------
  // a_cmd_held: a command is captured whole.
  //
  // Whatever was presented when the handshake completed is what the
  // sequencer captured, one clock later.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && cmd_valid_i_d && cmd_ready_o_d) begin
      assert (cmd_q == cmd_i_d && arg_q == arg_i_d);
    end
  end

  // -----------------------------------------------------------------------
  // a_cmd_stable: the command and its argument may not change while the
  // handshake is still open.
  //
  // This one is a requirement on the master, not a rule of the design. It is
  // kept here because it is the rule a host driver has to obey, and because
  // the handshake monitor of the testbench checks the same thing from the
  // other side. A formal run has to assume it rather than assert it.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && cmd_valid_i_d && !cmd_ready_o_d) begin
      assert (cmd_i == cmd_i_d && arg_i == arg_i_d);
    end
  end

  // -----------------------------------------------------------------------
  // a_done_pulse: the completion pulse is one clock long.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && done_o_d) begin
      assert (!done_o);
    end
  end

  // -----------------------------------------------------------------------
  // a_done_from_fin: the pulse comes out of the state that presents the
  // result.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && done_o) begin
      assert (state_q_d == S_FIN);
    end
  end

  // -----------------------------------------------------------------------
  // a_fin_is_short: the sequencer never sits in the presenting state for
  // longer than one clock, so it always comes back to the idle state.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && state_q_d == S_FIN) begin
      assert (state_q == S_IDLE);
    end
  end

  // -----------------------------------------------------------------------
  // a_ready_only_when_idle: the block is not ready while it is busy.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && state_q_d != S_IDLE && state_q_d != S_FIN) begin
      assert (!cmd_ready_o);
    end
  end

  // -----------------------------------------------------------------------
  // a_cmd_required: the sequencer only leaves the idle state after a
  // command has been accepted.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && state_q != S_IDLE) begin
      assert (seen_q);
    end
  end

  // -----------------------------------------------------------------------
  // a_err_cleared: a new command clears the error flag of the previous one.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && cmd_valid_i_d && cmd_ready_o_d) begin
      assert (!err_o);
    end
  end

  // -----------------------------------------------------------------------
  // The five start strobes. A strobe that stayed high for two clocks would
  // start an engine twice, so each of them is checked to be a one clock
  // pulse, and the five are checked to be exclusive with each other.
  // -----------------------------------------------------------------------
  logic [2:0] start_cnt_c;

  always_comb begin
    start_cnt_c = {2'd0, arb_start_c} + {2'd0, ro_start_c}
                + {2'd0, key_start_c} + {2'd0, arb_cmp_start_c}
                + {2'd0, ro_cmp_start_c};
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (start_cnt_c <= 3'd1);
    end
    if (rst_ni && arb_start_c_d) begin
      assert (!arb_start_c);
    end
    if (rst_ni && ro_start_c_d) begin
      assert (!ro_start_c);
    end
    if (rst_ni && key_start_c_d) begin
      assert (!key_start_c);
    end
    if (rst_ni && arb_cmp_start_c_d) begin
      assert (!arb_cmp_start_c);
    end
    if (rst_ni && ro_cmp_start_c_d) begin
      assert (!ro_cmp_start_c);
    end
  end

endmodule : puf_top_props


// ---------------------------------------------------------------------------
// The authentication comparator
// ---------------------------------------------------------------------------
module puf_auth_props #(
  parameter int RESP_BITS = 127,
  parameter int TOL_BITS  = 10
) (
  input logic       clk_i   ,
  input logic       rst_ni  ,
  input logic       start_i ,
  input logic [7:0] dist_o  ,
  input logic       ok_o    ,
  input logic       done_o
);

  // The same eight bit comparison the RTL makes.
  localparam logic [7:0] RESP_V = RESP_BITS;
  localparam logic [7:0] TOL_V  = TOL_BITS;

  logic       done_o_d;
  logic       ok_o_d;
  logic [7:0] dist_o_d;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      done_o_d <= 1'b0;
      ok_o_d   <= 1'b0;
      dist_o_d <= 8'd0;
    end else begin
      done_o_d <= done_o;
      ok_o_d   <= ok_o;
      dist_o_d <= dist_o;
    end
  end

  // -----------------------------------------------------------------------
  // a_dist_bound: the reported distance never exceeds the length of the
  // response. A distance larger than the number of bits that were compared
  // would mean the counter added something that was not a bit.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && done_o) begin
      assert (dist_o <= RESP_V);
    end
  end

  // -----------------------------------------------------------------------
  // a_ok_follows_dist: the verdict follows the distance and the tolerance,
  // nothing else.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && done_o) begin
      assert (ok_o == (dist_o <= TOL_V));
    end
  end

  // -----------------------------------------------------------------------
  // a_verdict_held: the verdict does not change between the pulse and the
  // next command.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && done_o_d) begin
      assert (ok_o == ok_o_d && dist_o == dist_o_d);
    end
  end

  // -----------------------------------------------------------------------
  // a_done_pulse: the completion pulse is one clock long.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && done_o_d) begin
      assert (!done_o);
    end
  end

endmodule : puf_auth_props


// ---------------------------------------------------------------------------
// The equivalence of the distance and the population count of the differing
// bits.
//
// This one is attached only where the differing bits are visible, which is
// the proof harness of the comparator. It is the strongest statement in
// this file: it says that the adder tree of the comparator and an
// independent count of the differing bits agree, bit for bit.
// ---------------------------------------------------------------------------
module puf_auth_equiv_props #(
  parameter int RESP_BITS = 127
) (
  input logic                clk_i  ,
  input logic                rst_ni ,
  input logic                done_i ,
  input logic [RESP_BITS-1:0] diff_i ,
  input logic [7:0]          dist_i
);

  function automatic logic [7:0] pc_wide(input logic [RESP_BITS-1:0] v);
    logic [7:0] c;
    int b;
    begin
      c = 8'd0;
      for (b = 0; b < RESP_BITS; b = b + 1) c = c + {7'd0, v[b]};
      pc_wide = c;
    end
  endfunction

  always_ff @(posedge clk_i) begin
    if (rst_ni && done_i) begin
      assert (dist_i == pc_wide(diff_i));
    end
  end

endmodule : puf_auth_equiv_props


// ---------------------------------------------------------------------------
// The BCH decoder
// ---------------------------------------------------------------------------
module puf_bch_dec_props #(
  parameter logic [4:0] TOL_L = 5'd10, // the radius against the locator degree
  parameter logic [6:0] TOL_C = 7'd10  // the radius against the error count
) (
  input logic       clk_i     ,
  input logic       rst_ni    ,
  input logic       done_o    ,
  input logic       fail_o    ,
  input logic [3:0] state_q   ,
  input logic [4:0] bm_l_q    , // the locator degree
  input logic [6:0] err_cnt_q , // the number of error positions
  input logic       vchk_ok_c , // the recomputed syndromes agree
  input logic       fail_q      // the registered failure flag
);

  // The state that decides whether the decode is trusted.
  localparam logic [3:0] S_VCMP = 4'd6;
  localparam logic [3:0] S_DONE = 4'd7;

  logic       vchk_ok_c_d;
  logic [4:0] bm_l_q_d;
  logic [6:0] err_cnt_q_d;
  logic       fail_q_d;
  logic [3:0] state_q_d;
  logic       done_o_d;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      vchk_ok_c_d <= 1'b1;
      bm_l_q_d    <= 5'd0;
      err_cnt_q_d <= 7'd0;
      fail_q_d    <= 1'b0;
      state_q_d   <= 4'd0;
      done_o_d    <= 1'b0;
    end else begin
      vchk_ok_c_d <= vchk_ok_c;
      bm_l_q_d    <= bm_l_q;
      err_cnt_q_d <= err_cnt_q;
      fail_q_d    <= fail_q;
      state_q_d   <= state_q;
      done_o_d    <= done_o;
    end
  end

  // -----------------------------------------------------------------------
  // a_fail_on_overflow: the decoder refuses a decode it cannot trust.
  //
  // The rule the RTL implements is
  //
  //     fail = !vchk_ok | (L > TOL_L) | (error_count > TOL_C)
  //
  // and the property says exactly that, recomputed from the same three
  // signals. A decoder that silently accepted a mis-corrected word would
  // hand a wrong key to the caller, so this is the property that carries
  // the most weight in this file.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && state_q_d == S_VCMP) begin
      assert (fail_q == ((!vchk_ok_c_d)
                                             || (bm_l_q_d > TOL_L)
                                             || (err_cnt_q_d > TOL_C)));
    end
  end

  // -----------------------------------------------------------------------
  // a_fail_o_follows_q: the flag that reaches the caller is the registered
  // one.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && state_q_d == S_DONE) begin
      assert (fail_o == fail_q_d);
    end
  end

  // -----------------------------------------------------------------------
  // a_correction_bounded: a decode that succeeded corrected at most the
  // radius of the code.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && state_q_d == S_DONE && !fail_q_d) begin
      assert (err_cnt_q <= TOL_C);
    end
  end

  // -----------------------------------------------------------------------
  // a_done_pulse: the completion pulse is one clock long.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && done_o_d) begin
      assert (!done_o);
    end
  end

endmodule : puf_bch_dec_props

`endif // INCLUDE_FPV

`default_nettype wire
