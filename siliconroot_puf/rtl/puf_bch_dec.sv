///////////////////////////////////////////////////////
// Module : puf_bch_dec
// Author   : najamdesktop\najam
// Description: Berlekamp-Massey / Chien decoder for the BCH(127,64,21)
//              helper-data construction of Suh and Devadas, DAC 2007,
//              section 5.
//
//              The input is the difference between the syndrome stored at
//              enrolment and the syndrome of a fresh measurement. Because the
//              generator polynomial g(x) has alpha^1..alpha^20 among its roots,
//              the difference is the syndrome of the error pattern that
//              separates the two measurements:
//
//                d(x) = w'(x) + w(x)          (the bit-flipped positions)
//                d mod g = s' + s             (what is stored and differenced)
//                d(alpha^j) = (d mod g)(alpha^j)   for j = 1..20
//
//              so the twenty syndromes S_1..S_20 computed from the 63-bit
//              difference are exactly the syndromes of the error pattern.
//
//              The decode runs in four passes:
//
//                1. syndrome pass - the 63-bit difference is clocked through
//                   nine parallel seven-bit remainder LFSRs, one per
//                   cyclotomic class. Class c divides by the minimal
//                   polynomial m_c, which divides g, so the remainder it leaves
//                   is the class remainder of d.
//
//                2. conversion pass - each seven-bit class remainder is turned
//                   into the field element it stands for by XOR-ing the
//                   constant weights alpha^(r*i), and the class members are
//                   reached by repeated squaring. Twenty syndromes come out.
//
//                3. Berlekamp-Massey - twenty iterations produce the error
//                   locator polynomial sigma(x) = prod (1 + X_l x) and its
//                   degree L.
//
//                4. Chien search - 127 cycles walk sigma round the circle,
//                   testing sigma(alpha^-j) for j = 0..126. A zero test means
//                   the error at polynomial position j is bit p of the message.
//
//              A final verification pass recomputes the syndromes from the
//              error vector that came out of the Chien search and compares them
//              with the syndromes that went in. If they differ the decode
//              failed and the word is passed through uncorrected, so a
//              mis-correction can never be mistaken for a good one.
//
//              339 clocks from start to done.
///////////////////////////////////////////////////////
`default_nettype none

module puf_bch_dec (
  input  logic         clk_i    , // clock, rising edge
  input  logic         rst_ni  , // asynchronous reset, active low
  input  logic         start_i , // 1-cycle pulse: start decoding diff_i against word_i
  input  logic [62:0]  diff_i  , // syndrome difference s' + s, 63 bits
  input  logic [126:0] word_i  , // the noisy 127-bit measurement to correct
  output logic [126:0] word_o  , // corrected measurement
  output logic [6:0]   err_cnt_o, // number of bit flips corrected
  output logic         fail_o  , // 1 when the error pattern could not be corrected
  output logic         done_o    // 1-cycle completion pulse
);

  // The package is referenced with explicit scope resolution rather than with a
  // wildcard import. A wildcard `import puf_pkg::*;` inside a module body is
  // legal SystemVerilog, but the synthesis flow used for this block cannot
  // elaborate it, while the scoped form `puf_pkg::name` resolves identically in
  // the simulator and in the synthesiser.

  // -------------------------------------
  // Constants
  // -------------------------------------
  localparam int NC       = puf_pkg::NUM_CLASS;   // nine cyclotomic classes
  localparam int SYN_W    = 7;           // bits per syndrome
  localparam int LOC_W    = 7;           // bits per locator coefficient
  localparam int NSYN     = puf_pkg::NUM_SYN;     // twenty syndromes
  localparam int NLOC     = puf_pkg::MAX_LOC + 1; // twenty-one locator coefficients, index 0 unused
  localparam int CL_W     = 7;           // bits per class remainder
  localparam logic [4:0]  TOL_L     = puf_pkg::BCH_T;  // correction radius against the locator degree
  localparam logic [6:0]  TOL_C     = puf_pkg::BCH_T;  // correction radius against the error count

  // -------------------------------------
  // Decoder state
  // -------------------------------------
  typedef enum logic [3:0] {
    S_IDLE  = 4'd0,  // waiting for start_i
    S_SYND  = 4'd1,  // clocking the difference through the nine class LFSRs
    S_CONV  = 4'd2,  // converting class remainders into the twenty syndromes
    S_BM    = 4'd3,  // Berlekamp-Massey, twenty iterations
    S_CHIEN = 4'd4,  // Chien search, 127 positions
    S_VCHK  = 4'd5,  // clocking the error vector through the class LFSRs again
    S_VCMP  = 4'd6,  // comparing the recomputed syndromes with the originals
    S_DONE  = 4'd7   // presenting the result
  } state_e;

  state_e       state_q;
  logic [62:0]  diff_q;    // the difference held for the whole decode
  logic [126:0] word_q;    // the measurement held for the whole decode
  logic [62:0]  cls_q;     // nine class remainders, entry c at bits c*7 +: 7
  logic [139:0] syn_q;     // twenty syndromes, S_j at bits (j-1)*7 +: 7
  logic [146:0] bm_c_q;    // Berlekamp-Massey locator polynomial C
  logic [146:0] bm_b_q;    // Berlekamp-Massey auxiliary polynomial B
  logic [4:0]   bm_l_q;    // locator degree L
  logic [5:0]   bm_m_q;    // shift counter m
  logic [6:0]   bm_dq_q;   // last non-zero discrepancy b
  logic [4:0]   bm_r_q;    // iteration counter r, 1..20
  logic [146:0] chien_z_q; // Chien registers Z_i, entry i at bits i*7 +: 7
  logic [126:0] err_q;     // error positions found by the Chien search
  logic [6:0]   err_cnt_q; // number of error positions found
  logic [6:0]   bit_q;     // bit index inside the current shifting pass
  logic [126:0] word_o_q;  // result register
  logic [6:0]   err_cnt_o_q;
  logic         fail_q;

  // -------------------------------------
  // Class remainder LFSRs: nine of them, one per cyclotomic class
  //
  // The combinational blocks of this module are written as functions that are
  // called from continuous assignments rather than as always_comb processes.
  // The constant bit selects of the index arithmetic would then sit inside an
  // always block, where Icarus reports a degraded sensitivity, and a
  // continuous assignment needs no sensitivity list at all.
  // -------------------------------------
  logic          shf_bit_c;   // the bit entering the LFSRs this cycle
  logic [5:0]    bit_lo_c;    // the low six bits of the bit counter
  logic [62:0]   cls_next_c;

  assign bit_lo_c  = bit_q[5:0];
  assign shf_bit_c = (state_q == S_SYND) ? diff_q[62 - bit_lo_c]
                     : (state_q == S_VCHK) ? err_q[126 - bit_q]
                     : 1'b0;

  // One step of one class remainder register.
  function automatic logic [6:0] cls_step(input logic [6:0] cur,
                                           input logic       shf,
                                           input logic [3:0] cls);
    logic [6:0] shifted;
    begin
      shifted = {cur[5:0], shf};
      if (cur[6]) cls_step = shifted ^ puf_pkg::class_mlow(cls);
      else        cls_step = shifted;
    end
  endfunction

  // One step of all nine class remainder registers.
  function automatic logic [62:0] cls_update(input logic [62:0] cur,
                                              input logic       shf);
    logic [62:0] nxt;
    begin
      nxt = cur;
      for (int c = 0; c < NC; c++) begin
        nxt[c*CL_W +: CL_W] = cls_step(cur[c*CL_W +: CL_W], shf, c[3:0]);
      end
      cls_update = nxt;
    end
  endfunction

  assign cls_next_c = cls_update(cls_q, shf_bit_c);

  // -------------------------------------
  // Class remainder -> field element -> squaring chain -> the twenty syndromes
  // -------------------------------------
  // The chain holds five entries for each of the nine classes: the class
  // element itself and its first four squares.  Nine times five times seven
  // bits is three hundred and fifteen bits.
  logic [9*5*7-1:0] chain_c;   // nine classes x five squaring steps x seven bits
  logic [139:0] syn_next_c;

  // The field element one class remainder stands for.
  function automatic logic [6:0] cls_elem(input logic [62:0] cls,
                                          input logic [3:0] c);
    logic [6:0] v;
    begin
      v = 7'd0;
      for (int i = 0; i < 7; i++) begin
        if (cls[c*CL_W + i]) v = v ^ puf_pkg::alpha_conv(c, i[2:0]);
      end
      cls_elem = v;
    end
  endfunction

  // The squaring chain of all nine classes.
  function automatic logic [9*5*7-1:0] cls_chain(input logic [62:0] cls);
    logic [9*5*7-1:0] ch;
    logic [6:0]   v;
    begin
      ch = '0;
      for (int c = 0; c < NC; c++) begin
        v = cls_elem(cls, c[3:0]);
        ch[(c*5 + 0)*SYN_W +: SYN_W] = v;
        for (int k = 1; k <= 4; k++) begin
          ch[(c*5 + k)*SYN_W +: SYN_W] = puf_pkg::gf_sqr(ch[(c*5 + k - 1)*SYN_W +: SYN_W]);
        end
      end
      cls_chain = ch;
    end
  endfunction

  // The twenty syndromes, picked out of the squaring chain.
  function automatic logic [139:0] syn_pick(input logic [9*5*7-1:0] ch);
    logic [139:0] s;
    begin
      s = 140'd0;
      for (int j = 1; j <= NSYN; j++) begin
        s[(j-1)*SYN_W +: SYN_W] =
          ch[(puf_pkg::syn_class(j[4:0])*5 + puf_pkg::syn_sq(j[4:0]))*SYN_W +: SYN_W];
      end
      syn_pick = s;
    end
  endfunction

  assign chain_c    = cls_chain(cls_q);
  assign syn_next_c = syn_pick(chain_c);

  // -------------------------------------
  // Berlekamp-Massey combinational block
  // -------------------------------------
  logic [6:0]   disc_c;     // discrepancy d_r
  logic [6:0]   coef_c;     // d_r / b
  logic [146:0] c_corr_c;   // C + (d_r/b) x^m B
  logic         upd_c;      // 1 when the update branch fires, 2L < r
  logic [146:0] c_next_c;
  logic [146:0] b_next_c;
  logic [4:0]   l_next_c;
  logic [5:0]   m_next_c;
  logic [6:0]   dq_next_c;
  logic         bm_step_c;  // 1 while the Berlekamp-Massey pass is running

  // Everything one Berlekamp-Massey iteration produces.
  typedef struct packed {
    logic [6:0]   disc;
    logic [6:0]   coef;
    logic [146:0] c_corr;
    logic         upd;
    logic [146:0] c_next;
    logic [146:0] b_next;
    logic [4:0]   l_next;
    logic [5:0]   m_next;
    logic [6:0]   dq_next;
  } bm_res_e;

  function automatic bm_res_e bm_iterate(input logic [4:0]   rr,
                                          input logic [139:0] syn,
                                          input logic [146:0] cpoly,
                                          input logic [146:0] bpoly,
                                          input logic [4:0]   ldeg,
                                          input logic [5:0]   msh,
                                          input logic [6:0]   dq);
    bm_res_e      res;
    logic [6:0]   d;
    logic [6:0]   cf;
    logic [146:0] cc;
    logic         up;
    begin
      d = syn[(rr - 5'd1)*SYN_W +: SYN_W];
      for (int i = 1; i <= puf_pkg::MAX_LOC; i++) begin
        if ((i[4:0] <= ldeg) && (rr > i[4:0])) begin
          d = d ^ puf_pkg::gf_mul(cpoly[i*LOC_W +: LOC_W],
                         syn[(rr - i[4:0] - 5'd1)*SYN_W +: SYN_W]);
        end
      end
      cf = puf_pkg::gf_mul(d, puf_pkg::gf_inv(dq));

      cc = cpoly;
      for (int i = 0; i <= puf_pkg::MAX_LOC; i++) begin
        if ((bpoly[i*LOC_W +: LOC_W] != 7'd0) && ((i + int'(msh)) <= puf_pkg::MAX_LOC)) begin
          cc[(i + int'(msh))*LOC_W +: LOC_W] ^=
            puf_pkg::gf_mul(cf, bpoly[i*LOC_W +: LOC_W]);
        end
      end

      up = (2 * int'(ldeg) < int'(rr));

      res.disc    = d;
      res.coef    = cf;
      res.c_corr  = cc;
      res.upd     = up;
      res.c_next  = cc;
      res.b_next  = bpoly;
      res.l_next  = ldeg;
      res.m_next  = msh;
      res.dq_next = dq;
      if (d == 7'd0) begin
        res.m_next = msh + 6'd1;
      end else begin
        if (up) begin
          res.b_next  = cpoly;
          res.l_next  = rr - ldeg;
          res.dq_next = d;
          res.m_next  = 6'd1;
        end else begin
          res.m_next  = msh + 6'd1;
        end
      end
      bm_iterate = res;
    end
  endfunction

  bm_res_e bm_res_c;

  assign bm_res_c = bm_iterate(bm_r_q, syn_q, bm_c_q, bm_b_q,
                               bm_l_q, bm_m_q, bm_dq_q);
  assign disc_c    = bm_res_c.disc;
  assign coef_c    = bm_res_c.coef;
  assign c_corr_c  = bm_res_c.c_corr;
  assign upd_c     = bm_res_c.upd;
  assign c_next_c  = bm_res_c.c_next;
  assign b_next_c  = bm_res_c.b_next;
  assign l_next_c  = bm_res_c.l_next;
  assign m_next_c  = bm_res_c.m_next;
  assign dq_next_c = bm_res_c.dq_next;
  assign bm_step_c = (state_q == S_BM);

  // -------------------------------------
  // Chien search combinational block
  // -------------------------------------
  logic [6:0]   chien_t_c;   // sigma(alpha^-j)
  logic [146:0] chien_z_next_c;

  // The sum of the locator coefficients: zero at an error position.
  //
  // The locator polynomial is sigma(x) = 1 + C_1 x + C_2 x^2 + ... and the
  // constant term is one, so the sum starts at one.  The Chien registers hold
  // C_i times (alpha^-i)^j, and sigma(alpha^-j) is zero exactly when that sum
  // vanishes.
  function automatic logic [6:0] chien_sum(input logic [146:0] z);
    logic [6:0] t;
    begin
      t = 7'd1;
      for (int i = 1; i <= puf_pkg::MAX_LOC; i++) begin
        t = t ^ z[i*LOC_W +: LOC_W];
      end
      chien_sum = t;
    end
  endfunction

  // One step of the Chien registers.
  function automatic logic [146:0] chien_step(input logic [146:0] z);
    logic [146:0] nxt;
    begin
      nxt = z;
      for (int i = 1; i <= puf_pkg::MAX_LOC; i++) begin
        nxt[i*LOC_W +: LOC_W] =
          puf_pkg::gf_mulc(z[i*LOC_W +: LOC_W], puf_pkg::chien_mul(i[4:0]));
      end
      chien_step = nxt;
    end
  endfunction

  assign chien_t_c      = chien_sum(chien_z_q);
  assign chien_z_next_c = chien_step(chien_z_q);

  // -------------------------------------
  // Syndrome comparison for the verification pass
  // -------------------------------------
  logic        vchk_ok_c;

  always_comb begin
    vchk_ok_c = 1'b1;
    for (int j = 1; j <= NSYN; j++) begin
      if (syn_next_c[(j-1)*SYN_W +: SYN_W] != syn_q[(j-1)*SYN_W +: SYN_W]) begin
        vchk_ok_c = 1'b0;
      end
    end
  end

  // -------------------------------------
  // Main sequencer
  // -------------------------------------
  logic [126:0] err_next_c;
  logic [6:0]   err_cnt_next_c;
  logic         chien_hit_c;

  always_comb begin
    err_next_c     = err_q;
    err_cnt_next_c = err_cnt_q;
    chien_hit_c    = (chien_t_c == 7'd0);
    if (chien_hit_c) begin
      // The Chien position j is the polynomial position of the error, which is
      // the same as the bit index in the 127-bit word.
      err_next_c[bit_q] = 1'b1;
      err_cnt_next_c = err_cnt_q + 7'd1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= S_IDLE;
      diff_q    <= 63'd0;
      word_q    <= 127'd0;
      cls_q     <= 63'd0;
      syn_q     <= 140'd0;
      bm_c_q    <= 147'd1;
      bm_b_q    <= 147'd1;
      bm_l_q    <= 5'd0;
      bm_m_q    <= 6'd1;
      bm_dq_q   <= 7'd1;
      bm_r_q    <= 5'd1;
      chien_z_q <= 147'd0;
      err_q     <= 127'd0;
      err_cnt_q <= 7'd0;
      bit_q     <= 7'd0;
      word_o_q  <= 127'd0;
      err_cnt_o_q <= 7'd0;
      fail_q    <= 1'b0;
      done_o    <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        S_IDLE: begin
          if (start_i) begin
            diff_q  <= diff_i;
            word_q  <= word_i;
            cls_q   <= 63'd0;
            err_q   <= 127'd0;
            err_cnt_q <= 7'd0;
            bit_q   <= 7'd0;
            fail_q  <= 1'b0;
            state_q <= S_SYND;
          end
        end

        S_SYND: begin
          cls_q <= cls_next_c;
          if (bit_q == 7'd62) begin
            state_q <= S_CONV;
          end else begin
            bit_q <= bit_q + 7'd1;
          end
        end

        S_CONV: begin
          syn_q  <= syn_next_c;
          // The locator polynomial and its auxiliary polynomial both start
          // with the constant term one, which is coefficient zero.
          bm_c_q <= 147'd1;
          bm_b_q <= 147'd1;
          bm_l_q <= 5'd0;
          bm_m_q <= 6'd1;
          bm_dq_q<= 7'd1;
          bm_r_q <= 5'd1;
          state_q<= S_BM;
        end

        S_BM: begin
          bm_c_q  <= c_next_c;
          bm_b_q  <= b_next_c;
          bm_l_q  <= l_next_c;
          bm_m_q  <= m_next_c;
          bm_dq_q <= dq_next_c;
          if (bm_r_q == 5'd20) begin
            // Seed the Chien registers with the locator coefficients and start
            // the search at position zero.
            for (int i = 1; i <= puf_pkg::MAX_LOC; i++) begin
              chien_z_q[i*LOC_W +: LOC_W] <= c_next_c[i*LOC_W +: LOC_W];
            end
            bit_q   <= 7'd0;
            state_q <= S_CHIEN;
          end else begin
            bm_r_q <= bm_r_q + 5'd1;
          end
        end

        S_CHIEN: begin
          chien_z_q <= chien_z_next_c;
          err_q     <= err_next_c;
          err_cnt_q <= err_cnt_next_c;
          if (bit_q == 7'd126) begin
            cls_q  <= 63'd0;
            bit_q  <= 7'd0;
            state_q <= S_VCHK;
          end else begin
            bit_q <= bit_q + 7'd1;
          end
        end

        S_VCHK: begin
          cls_q <= cls_next_c;
          if (bit_q == 7'd126) begin
            state_q <= S_VCMP;
          end else begin
            bit_q <= bit_q + 7'd1;
          end
        end

        S_VCMP: begin
          word_o_q    <= word_q ^ err_q;
          err_cnt_o_q <= err_cnt_q;
          // The decode is trusted only when the locator degree is inside the
          // code's correction radius and the recomputed syndromes agree with
          // the ones that went in.
          fail_q      <= (~vchk_ok_c) | (bm_l_q > TOL_L) | (err_cnt_q > TOL_C);
          state_q     <= S_DONE;
        end

        S_DONE: begin
          done_o      <= 1'b1;
          word_o      <= word_o_q;
          err_cnt_o   <= err_cnt_o_q;
          fail_o      <= fail_q;
          state_q     <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

`ifdef RTL_SIM
  // -------------------------------------
  // Simulation-only checks: the Berlekamp-Massey correction must never write
  // outside the locator array, and the Chien search must never report more
  // errors than the code can correct without flagging the decode.
  // -------------------------------------
  // The checker is a plain event block rather than an always_ff: a system task
  // inside a clocked process is not synthesisable and every tool warns about it.
  always @(posedge clk_i) begin
    if (rst_ni && bm_step_c) begin
      for (int i = 0; i <= puf_pkg::MAX_LOC; i++) begin
        if ((bm_b_q[i*LOC_W +: LOC_W] != 7'd0) && ((i + int'(bm_m_q)) > puf_pkg::MAX_LOC)) begin
          $error("puf_bch_dec: locator correction index %0d exceeds MAX_LOC", i + int'(bm_m_q));
        end
      end
    end
  end
`endif

endmodule : puf_bch_dec
`default_nettype wire
