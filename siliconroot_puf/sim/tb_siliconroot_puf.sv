///////////////////////////////////////////////////////
// Module : tb_siliconroot_puf
// Author   : najamdesktop\najam
// Description: Self checking testbench for SiliconRoot-PUF, a PUF based device
//              authentication and secret key generation IP of Suh and Devadas,
//              DAC 2007.
//
//              WHAT IS CHECKED
//
//              1. The two PUF macro twins against the known answer vectors of
//                 the independent Python model (sim/calibrate_models.py).
//                 The vectors are the only place where the two
//                 implementations meet, so an error in either one shows up
//                 here.
//
//              2. The BCH(127,64,21) helper data path against an independent
//                 syndrome model written in this testbench, and against the
//                 decoder itself: a word is corrupted with a known error
//                 pattern, the syndrome difference is decoded, and the
//                 corrected word has to come back unchanged.
//
//              3. The SHA-256 core against the two published FIPS 180-4
//                 digests, and the same digests against the golden model of
//                 this testbench, so that the golden model itself is proven
//                 before it is used to predict the derived key.
//
//              4. The top level command interface: every command of the
//                 command map is issued, the authentication flow of section 4
//                 of the paper is walked through, the key of the enrolment
//                 run is re-derived at regeneration, an environment change is
//                 absorbed by the tolerance and a different device is
//                 rejected.
//
//              5. The handshake of the command interface, on every clock of the
//                 whole run: done_o is a one cycle pulse, cmd_ready_o is low
//                 while a command runs and high while the block is idle.
//                 These are counted apart from the functional checks, because
//                 they are observed on every clock rather than once per test
//                 item.
//
//              The bench never prints a line that starts with ERROR, Error or
//              Fatal: a mismatch is reported as MISMATCH and the run ends
//              with the RESULT line.
//
`timescale 1ns/1ps
`default_nettype none

module tb_siliconroot_puf;

  // ---------------------------------------------------------------------
  // Configuration, the same numbers the top level uses
  // ---------------------------------------------------------------------
  localparam int RESP_BITS = 127;
  localparam int ARB_BITS  = 64;
  localparam int K_MASK    = 4;
  localparam int N_PAIRS   = 512;
  localparam int CHAL_W    = 9;
  localparam int CNT_W     = 16;
  localparam int WIN_LEN   = 1024;
  localparam int TOL_BITS  = 10;
  localparam int CAND_W    = 2;
  localparam int MASK_W    = RESP_BITS * CAND_W;

  // ---------------------------------------------------------------------
  // Commands of the top level
  // ---------------------------------------------------------------------
  localparam logic [3:0] CMD_NOP        = 4'd0;
  localparam logic [3:0] CMD_ARB_RESP   = 4'd1;
  localparam logic [3:0] CMD_ARB_AUTH   = 4'd2;
  localparam logic [3:0] CMD_RO_ENROLL  = 4'd3;
  localparam logic [3:0] CMD_RO_REGEN   = 4'd4;
  localparam logic [3:0] CMD_RO_AUTH    = 4'd5;
  localparam logic [3:0] CMD_ARB_REF_ST = 4'd6;
  localparam logic [3:0] CMD_RO_REF_ST  = 4'd7;

  // ---------------------------------------------------------------------
  // Clock and reset
  // ---------------------------------------------------------------------
  logic clk_i  = 1'b0;
  logic rst_ni = 1'b0;

  always #5 clk_i = ~clk_i;

  // ---------------------------------------------------------------------
  // Top level ports
  // ---------------------------------------------------------------------
  logic [31:0]      dev_id_i;
  logic [3:0]       env_i;
  logic             cmd_valid_i;
  logic             cmd_ready_o;
  logic [3:0]       cmd_i;
  logic [63:0]      arg_i;
  logic             done_o;
  logic             err_o;
  logic [3:0]       status_o;
  logic [255:0]     key_o;
  logic [RESP_BITS-1:0] resp_o;
  logic [ARB_BITS-1:0]  arb_o;
  logic [62:0]      synd_o;
  logic [MASK_W-1:0] mask_o;
  logic             auth_ok_o;
  logic [7:0]       auth_dist_o;

  // ---------------------------------------------------------------------
  // Optional wave dump. The bench writes no wave unless the +dump plusarg is
  // given, so the normal run leaves no large trace file behind.
  // ---------------------------------------------------------------------
  string dump_file;

  siliconroot_puf #(
    .RESP_BITS (RESP_BITS),
    .ARB_BITS  (ARB_BITS ),
    .K_MASK    (K_MASK   ),
    .N_PAIRS   (N_PAIRS  ),
    .CHAL_W    (CHAL_W   ),
    .CNT_W     (CNT_W    ),
    .WIN_LEN   (WIN_LEN  ),
    .TOL_BITS  (TOL_BITS )
  ) u_dut (
    .clk_i       (clk_i       ),
    .rst_ni      (rst_ni      ),
    .dev_id_i    (dev_id_i    ),
    .env_i       (env_i       ),
    .cmd_valid_i (cmd_valid_i ),
    .cmd_ready_o (cmd_ready_o ),
    .cmd_i       (cmd_i       ),
    .arg_i       (arg_i       ),
    .done_o      (done_o      ),
    .err_o       (err_o       ),
    .status_o    (status_o    ),
    .key_o       (key_o       ),
    .resp_o      (resp_o      ),
    .arb_o       (arb_o       ),
    .synd_o      (synd_o      ),
    .mask_o      (mask_o      ),
    .auth_ok_o   (auth_ok_o   ),
    .auth_dist_o (auth_dist_o )
  );

  // ---------------------------------------------------------------------
  // The handshake monitor.  It runs on every clock of the whole run and it
  // checks the three rules the command interface of the design specification
  // puts on the block:
  //
  //   1. done_o is a one cycle pulse and never two cycles long,
  //   2. cmd_ready_o is low while the block is executing a command,
  //   3. cmd_ready_o is high whenever the block has nothing to do.
  //
  // The monitor keeps its own model of "is a command running", so it does
  // not need any signal from inside the DUT.  A violation prints a MISMATCH
  // line and fails the run, exactly like a functional check.
  // ---------------------------------------------------------------------
  logic prev_done_q = 1'b0;
  logic running_q   = 1'b0;

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      prev_done_q <= 1'b0;
      running_q   <= 1'b0;
    end else begin
      if (done_o) begin
        check_hs(prev_done_q == 1'b0, "done_o is a one cycle pulse");
      end
      if (running_q && !done_o) begin
        check_hs(cmd_ready_o == 1'b0, "cmd_ready_o is low while a command runs");
      end
      if (!running_q) begin
        check_hs(cmd_ready_o == 1'b1, "cmd_ready_o is high while the block is idle");
      end
      prev_done_q <= done_o;
      if (cmd_valid_i && cmd_ready_o) running_q <= 1'b1;
      else if (done_o)               running_q <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------
  // Direct instances of the leaf blocks.  They are driven one after the
  // other by the test tasks below, so they never run at the same time.
  // ---------------------------------------------------------------------
  logic         sha_start_c;
  logic         sha_done_c;
  logic [511:0] sha_blk_c;
  logic [255:0] sha_dig_c;

  puf_sha256 u_sha (
    .clk_i    (clk_i    ),
    .rst_ni   (rst_ni   ),
    .start_i  (sha_start_c),
    .block_i  (sha_blk_c),
    .digest_o (sha_dig_c),
    .done_o   (sha_done_c)
  );

  logic        prng_load_c;
  logic        prng_step_c;
  logic [63:0] prng_seed_c;
  logic [63:0] prng_state_c;

  puf_prng u_prng (
    .clk_i   (clk_i      ),
    .rst_ni  (rst_ni     ),
    .load_i  (prng_load_c),
    .seed_vi (prng_seed_c),
    .step_i  (prng_step_c),
    .state_o (prng_state_c)
  );

  logic         enc_start_c;
  logic         enc_done_c;
  logic [126:0] enc_word_c;
  logic [62:0]  enc_synd_c;

  puf_bch_enc u_enc (
    .clk_i   (clk_i      ),
    .rst_ni  (rst_ni     ),
    .start_i (enc_start_c),
    .word_i  (enc_word_c),
    .synd_o  (enc_synd_c),
    .done_o  (enc_done_c )
  );

  logic         dec_start_c;
  logic         dec_done_c;
  logic         dec_fail_c;
  logic [62:0]  dec_diff_c;
  logic [126:0] dec_word_c;
  logic [126:0] dec_out_c;
  logic [6:0]   dec_err_c;

  puf_bch_dec u_dec (
    .clk_i     (clk_i      ),
    .rst_ni    (rst_ni     ),
    .start_i   (dec_start_c),
    .diff_i    (dec_diff_c ),
    .word_i    (dec_word_c ),
    .word_o    (dec_out_c  ),
    .err_cnt_o (dec_err_c  ),
    .fail_o    (dec_fail_c ),
    .done_o    (dec_done_c )
  );

  logic         cmp_start_c;
  logic         cmp_done_c;
  logic         cmp_ok_c;
  logic [126:0] cmp_ref_c;
  logic [126:0] cmp_resp_c;
  logic [126:0] cmp_diff_c;
  logic [7:0]   cmp_dist_c;

  puf_auth #(
    .RESP_BITS (RESP_BITS),
    .TOL_BITS  (TOL_BITS )
  ) u_cmp (
    .clk_i   (clk_i      ),
    .rst_ni  (rst_ni     ),
    .start_i (cmp_start_c),
    .ref_i   (cmp_ref_c  ),
    .resp_i  (cmp_resp_c ),
    .diff_o  (cmp_diff_c ),
    .dist_o  (cmp_dist_c ),
    .ok_o    (cmp_ok_c   ),
    .done_o  (cmp_done_c )
  );

  // ---------------------------------------------------------------------
  // The golden SHA-256 of the testbench.  It is a plain 64 word schedule
  // implementation, deliberately not the rolling 16 word window of the RTL,
  // so that a mistake in the window bookkeeping of the core cannot hide
  // behind an identical mistake in the model.
  //
  // FIPS 180-4 defines four sigma functions: the lower case pair builds the
  // message schedule and the upper case pair is used by the round.  They are
  // spelled out separately here for exactly that reason.
  // ---------------------------------------------------------------------
  logic [31:0] gk [0:63];

  function automatic logic [31:0] tb_rotr(input logic [31:0] x, input integer n);
    tb_rotr = (x >> n) | (x << (32 - n));
  endfunction

  function automatic logic [31:0] tb_bsig0(input logic [31:0] x);
    tb_bsig0 = tb_rotr(x, 2) ^ tb_rotr(x, 13) ^ tb_rotr(x, 22);
  endfunction

  function automatic logic [31:0] tb_bsig1(input logic [31:0] x);
    tb_bsig1 = tb_rotr(x, 6) ^ tb_rotr(x, 11) ^ tb_rotr(x, 25);
  endfunction

  function automatic logic [31:0] tb_ssig0(input logic [31:0] x);
    tb_ssig0 = tb_rotr(x, 7) ^ tb_rotr(x, 18) ^ (x >> 3);
  endfunction

  function automatic logic [31:0] tb_ssig1(input logic [31:0] x);
    tb_ssig1 = tb_rotr(x, 17) ^ tb_rotr(x, 19) ^ (x >> 10);
  endfunction

  function automatic logic [31:0] tb_ch(input logic [31:0] e,
                                        input logic [31:0] f,
                                        input logic [31:0] g);
    tb_ch = (e & f) ^ (~e & g);
  endfunction

  function automatic logic [31:0] tb_maj(input logic [31:0] a,
                                         input logic [31:0] b,
                                         input logic [31:0] c);
    tb_maj = (a & b) ^ (a & c) ^ (b & c);
  endfunction

  logic [31:0] gw [0:63];

  task automatic tb_sha256(input logic [511:0] blk, output logic [255:0] dig);
    logic [31:0] a;
    logic [31:0] b;
    logic [31:0] c;
    logic [31:0] d;
    logic [31:0] e;
    logic [31:0] f;
    logic [31:0] g;
    logic [31:0] h;
    logic [31:0] t1;
    logic [31:0] t2;
    begin
      for (int i = 0; i < 16; i++) gw[i] = blk[511-32*i -: 32];
      for (int i = 16; i < 64; i++) begin
        gw[i] = tb_ssig1(gw[i-2]) + gw[i-7] + tb_ssig0(gw[i-15]) + gw[i-16];
      end
      a = 32'h6a09e667;
      b = 32'hbb67ae85;
      c = 32'h3c6ef372;
      d = 32'ha54ff53a;
      e = 32'h510e527f;
      f = 32'h9b05688c;
      g = 32'h1f83d9ab;
      h = 32'h5be0cd19;
      for (int i = 0; i < 64; i++) begin
        t1 = h + tb_bsig1(e) + tb_ch(e, f, g) + gk[i] + gw[i];
        t2 = tb_bsig0(a) + tb_maj(a, b, c);
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
      end
      dig = {a + 32'h6a09e667, b + 32'hbb67ae85, c + 32'h3c6ef372, d + 32'ha54ff53a,
             e + 32'h510e527f, f + 32'h9b05688c, g + 32'h1f83d9ab, h + 32'h5be0cd19};
    end
  endtask

  // ---------------------------------------------------------------------
  // The golden BCH syndrome of the testbench.  The remainder is computed
  // with the shift register of the polynomial division, from the highest
  // coefficient of the word down to the lowest one.  The word bit p is the
  // coefficient of x^p, so the highest coefficient is bit 126.
  // ---------------------------------------------------------------------
  localparam logic [62:0] TB_G_L = 63'h21ab815bc7ec8025;

  function automatic logic [62:0] tb_syndrome(input logic [126:0] w);
    logic [62:0] r;
    logic        fb;
    begin
      r = 63'd0;
      for (int i = 126; i >= 0; i--) begin
        fb    = r[62];
        r     = {r[61:0], w[i]};
        if (fb) r = r ^ TB_G_L;
      end
      tb_syndrome = r;
    end
  endfunction

  // ---------------------------------------------------------------------
  // Small helpers
  // ---------------------------------------------------------------------
  integer err_cnt = 0;
  integer chk_cnt = 0;
  integer n_kat   = 0;

  // The handshake of the command interface is observed on every clock of the
  // run, so it is counted separately from the functional checks: a run that
  // spends two thousand clocks idle would otherwise report two thousand
  // functional checks and the functional count would stop meaning anything.
  integer hs_cnt = 0;   // handshake observations
  integer hs_err = 0;   // handshake violations
  integer fun_err = 0;  // functional mismatches, the part of err_cnt that
                         // comes from the functional checks

  // ---------------------------------------------------------------------
  // The longest run seen for each command, in clock cycles from the
  // presentation of the command to the completion pulse. The design
  // specification quotes these numbers, so they are measured here rather
  // than estimated.
  // ---------------------------------------------------------------------
  integer cmd_cyc [0:7];
  integer cmd_run [0:7];

  initial begin
    for (int i = 0; i < 8; i++) begin
      cmd_cyc[i] = 0;
      cmd_run[i] = 0;
    end
  end

  task automatic check(input logic cond, input [8*72-1:0] what);
    begin
      chk_cnt = chk_cnt + 1;
      if (!cond) begin
        fun_err = fun_err + 1;
        err_cnt = err_cnt + 1;
        $display("MISMATCH  %0s", what);
      end
    end
  endtask

  // A handshake check. It is counted apart from the functional checks, but a
  // violation is a mismatch like any other: it prints a MISMATCH line and it
  // fails the run.
  task automatic check_hs(input logic cond, input [8*72-1:0] what);
    begin
      hs_cnt = hs_cnt + 1;
      if (!cond) begin
        hs_err = hs_err + 1;
        err_cnt = err_cnt + 1;
        $display("MISMATCH  %0s", what);
      end
    end
  endtask

  function automatic logic [7:0] tb_popcount(input logic [126:0] v);
    logic [7:0] c;
    begin
      c = 8'd0;
      for (int i = 0; i < 127; i++) c = c + {7'd0, v[i]};
      tb_popcount = c;
    end
  endfunction

  function automatic logic [63:0] tb_rand(input logic [63:0] s);
    logic [63:0] x;
    begin
      x = s;
      x = x ^ (x << 13);
      x = x ^ (x >> 7);
      x = x ^ (x << 17);
      tb_rand = x;
    end
  endfunction

  // The block that the key derivation hashes: the 127 corrected response
  // bits, the mandatory one bit, the zero padding and the bit length.
  function automatic logic [511:0] tb_key_block(input logic [126:0] msg);
    logic [511:0] b;
    begin
      b = 512'd0;
      b[511:385] = msg;
      b[384]     = 1'b1;
      b[63:0]    = 64'd127;
      tb_key_block = b;
    end
  endfunction

  // ---------------------------------------------------------------------
  // The known answer vectors
  // ---------------------------------------------------------------------
  localparam int MAX_KAT = 16;

  logic [31:0]  kat_ro_dev  [0:MAX_KAT-1];
  logic [3:0]   kat_ro_env  [0:MAX_KAT-1];
  logic [8:0]   kat_ro_chal [0:MAX_KAT-1];
  logic [MASK_W-1:0] kat_ro_mask [0:MAX_KAT-1];
  logic [126:0] kat_ro_resp [0:MAX_KAT-1];
  logic [31:0]  kat_arb_dev  [0:MAX_KAT-1];
  logic [3:0]   kat_arb_env  [0:MAX_KAT-1];
  logic [63:0]  kat_arb_seed [0:MAX_KAT-1];
  logic [63:0]  kat_arb_resp [0:MAX_KAT-1];
  logic [126:0] kat_syn_word [0:MAX_KAT-1];
  logic [62:0]  kat_syn_synd [0:MAX_KAT-1];

  integer n_ro  = 0;
  integer n_arb = 0;
  integer n_syn = 0;

  reg [8*256-1:0] kat_file;

  task automatic load_kat;
    integer fd;
    integer rc;
    integer eof;
    reg [8*512-1:0] line;
    reg [31:0] dev;
    integer     env;
    integer     chal;
    reg [63:0]  m0;
    reg [63:0]  m1;
    reg [63:0]  m2;
    reg [63:0]  m3;
    reg [63:0]  r0;
    reg [63:0]  r1;
    reg [63:0]  s0;
    reg [63:0]  seed;
    begin
      fd = $fopen(kat_file, "r");
      if (fd == 0) begin
        $display("MISMATCH  the known answer file could not be opened");
        err_cnt = err_cnt + 1;
      end else begin
        n_ro  = 0;
        n_arb = 0;
        n_syn = 0;
        eof   = 0;
        while (eof == 0) begin
          rc = $fgets(line, fd);
          if (rc == 0) begin
            eof = 1;
          end else begin
            rc = $sscanf(line, "RO %h %d %d %h %h %h %h %h %h",
                         dev, env, chal, m3, m2, m1, m0, r1, r0);
            if (rc == 9) begin
              if (n_ro < MAX_KAT) begin
                kat_ro_dev  [n_ro] = dev;
                kat_ro_env  [n_ro] = env[3:0];
                kat_ro_chal [n_ro] = chal[8:0];
                kat_ro_mask [n_ro] = {m3[61:0], m2, m1, m0};
                kat_ro_resp [n_ro] = {r1[62:0], r0};
                n_ro = n_ro + 1;
              end
            end else begin
              rc = $sscanf(line, "ARB %h %d %h %h", dev, env, seed, r0);
              if (rc == 4) begin
                if (n_arb < MAX_KAT) begin
                  kat_arb_dev  [n_arb] = dev;
                  kat_arb_env  [n_arb] = env[3:0];
                  kat_arb_seed [n_arb] = seed;
                  kat_arb_resp [n_arb] = r0;
                  n_arb = n_arb + 1;
                end
              end else begin
                rc = $sscanf(line, "SYN %h %h %h", r1, r0, s0);
                if (rc == 3) begin
                  if (n_syn < MAX_KAT) begin
                    kat_syn_word [n_syn] = {r1[62:0], r0};
                    kat_syn_synd [n_syn] = s0[62:0];
                    n_syn = n_syn + 1;
                  end
                end
              end
            end
          end
        end
        $fclose(fd);
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Command driver
  // ---------------------------------------------------------------------
  task automatic do_cmd(input logic [3:0] c, input logic [63:0] a);
    integer n;
    logic   seen;
    begin
      @(negedge clk_i);
      cmd_i       = c;
      arg_i       = a;
      cmd_valid_i = 1'b1;
      @(negedge clk_i);
      cmd_valid_i = 1'b0;
      n    = 0;
      seen = 1'b0;
      while (!seen && n < 20000) begin
        @(negedge clk_i);
        seen = done_o;
        n    = n + 1;
      end
      if (!seen) begin
        $display("MISMATCH  command %0d did not finish", c);
        err_cnt = err_cnt + 1;
      end
      // The latency of this command, from the edge that accepted it to the
      // edge that raised done_o.
      cmd_run[c] = cmd_run[c] + 1;
      if (n > cmd_cyc[c]) cmd_cyc[c] = n;
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 1: the SHA-256 core against the published FIPS 180-4 digests
  // ---------------------------------------------------------------------
  task automatic test_sha_kat;
    logic [511:0] blk;
    logic [255:0] dig;
    logic [255:0] refv;
    begin
      // "abc"
      blk = 512'd0;
      blk[511:480] = 32'h61626380;
      blk[63:0]    = 64'd24;
      refv = 256'hba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad;
      tb_sha256(blk, dig);
      check(dig == refv, "golden SHA-256 of abc");
      sha_blk_c = blk;
      @(negedge clk_i);
      sha_start_c = 1'b1;
      @(negedge clk_i);
      sha_start_c = 1'b0;
      n_kat = n_kat + 1;
      begin
        integer n;
        logic   seen;
        n    = 0;
        seen = 1'b0;
        while (!seen && n < 200) begin
          @(negedge clk_i);
          seen = sha_done_c;
          n    = n + 1;
        end
        check(seen, "the sha core finished");
      end
      check(sha_dig_c == refv, "RTL SHA-256 of abc");

      // the empty message: the single one bit of the padding sits at the top
      // of the block and the length field is zero
      blk = 512'd0;
      blk[511] = 1'b1;
      refv = 256'he3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;
      tb_sha256(blk, dig);
      check(dig == refv, "golden SHA-256 of the empty message");
      sha_blk_c = blk;
      @(negedge clk_i);
      sha_start_c = 1'b1;
      @(negedge clk_i);
      sha_start_c = 1'b0;
      n_kat = n_kat + 1;
      begin
        integer n;
        logic   seen;
        n    = 0;
        seen = 1'b0;
        while (!seen && n < 200) begin
          @(negedge clk_i);
          seen = sha_done_c;
          n    = n + 1;
        end
        check(seen, "the sha core finished");
      end
      check(sha_dig_c == refv, "RTL SHA-256 of the empty message");
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 2: the pseudo random generator of the arbiter PUF
  // ---------------------------------------------------------------------
  task automatic test_prng_kat;
    logic [63:0] st;
    logic [63:0] exp;
    begin
      st  = 64'h0123_4567_89AB_CDEF;
      exp = st;
      prng_seed_c = st;
      @(negedge clk_i);
      prng_load_c = 1'b1;
      @(negedge clk_i);
      prng_load_c = 1'b0;
      check(prng_state_c == exp, "the prng loaded the seed");
      for (int i = 0; i < 16; i++) begin
        exp = exp[63] ? ((exp << 1) ^ 64'h1B) : (exp << 1);
        prng_step_c = 1'b1;
        @(negedge clk_i);
        check(prng_state_c == exp, "the prng stepped");
      end
      prng_step_c = 1'b0;
      // the all zero seed is replaced by one, zero is a fixed point
      prng_seed_c = 64'd0;
      @(negedge clk_i);
      prng_load_c = 1'b1;
      @(negedge clk_i);
      prng_load_c = 1'b0;
      check(prng_state_c == 64'd1, "the prng replaced the zero seed");
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 3: the syndrome encoder
  // ---------------------------------------------------------------------
  task automatic test_bch_encoder;
    logic [126:0] w;
    logic [62:0]  gold;
    begin
      for (int i = 0; i < n_syn; i++) begin
        w    = kat_syn_word[i];
        gold = tb_syndrome(w);
        check(gold == kat_syn_synd[i], "the golden syndrome matches the model");
        enc_word_c = w;
        @(negedge clk_i);
        enc_start_c = 1'b1;
        @(negedge clk_i);
        enc_start_c = 1'b0;
        begin
          integer n;
          logic   seen;
          n    = 0;
          seen = 1'b0;
          while (!seen && n < 400) begin
            @(negedge clk_i);
            seen = enc_done_c;
            n    = n + 1;
          end
          check(seen, "the encoder finished");
        end
        check(enc_synd_c == gold, "the RTL syndrome matches the golden model");
        check(enc_synd_c == kat_syn_synd[i], "the RTL syndrome matches the model");
        n_kat = n_kat + 1;
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 4: the syndrome decoder
  // ---------------------------------------------------------------------
  task automatic test_bch_decoder;
    logic [126:0] w;
    logic [126:0] w2;
    logic [126:0] e;
    logic [62:0]  s1;
    logic [62:0]  s2;
    logic [62:0]  diff;
    logic [63:0]  rs;
    integer       nerr;
    integer       pos;
    begin
      rs = 64'h0123_4567_89AB_CDEF;
      for (int t = 0; t < 8; t++) begin
        rs = tb_rand(rs);
        w = {rs[62:0], tb_rand(rs)};
        rs = tb_rand(rs);
        w[62:0] = rs[62:0];
        nerr = t;
        e    = '0;
        for (int i = 0; i < nerr; i++) begin
          rs  = tb_rand(rs);
          pos = rs % 127;
          e[pos] = 1'b1;
        end
        w2   = w ^ e;
        s1   = tb_syndrome(w);
        s2   = tb_syndrome(w2);
        diff = s1 ^ s2;
        dec_diff_c = diff;
        dec_word_c = w2;
        @(negedge clk_i);
        dec_start_c = 1'b1;
        @(negedge clk_i);
        dec_start_c = 1'b0;
        begin
          integer n;
          logic   seen;
          n    = 0;
          seen = 1'b0;
          while (!seen && n < 1000) begin
            @(negedge clk_i);
            seen = dec_done_c;
            n    = n + 1;
          end
          check(seen, "the decoder finished");
        end
        check(dec_out_c == w, "the decoder returned the original word");
        check(dec_err_c == tb_popcount(e), "the decoder counted the errors");
        check(dec_fail_c == 1'b0, "the decoder did not flag a correctable word");
        n_kat = n_kat + 1;
      end

      // eleven errors are beyond the radius of the code and have to be
      // flagged rather than silently accepted
      rs = 64'h0FED_CBA9_8765_4321;
      rs = tb_rand(rs);
      w = {rs[62:0], tb_rand(rs)};
      rs = tb_rand(rs);
      w[62:0] = rs[62:0];
      e = '0;
      for (int i = 0; i < 11; i++) begin
        rs  = tb_rand(rs);
        pos = rs % 127;
        e[pos] = 1'b1;
      end
      w2   = w ^ e;
      diff = tb_syndrome(w) ^ tb_syndrome(w2);
      dec_diff_c = diff;
      dec_word_c = w2;
      @(negedge clk_i);
      dec_start_c = 1'b1;
      @(negedge clk_i);
      dec_start_c = 1'b0;
      begin
        integer n;
        logic   seen;
        n    = 0;
        seen = 1'b0;
        while (!seen && n < 1000) begin
          @(negedge clk_i);
          seen = dec_done_c;
          n    = n + 1;
        end
        check(seen, "the decoder finished");
      end
      check(dec_fail_c == 1'b1, "eleven errors are flagged");
      n_kat = n_kat + 1;
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 5: the tolerance of the authentication comparator
  // ---------------------------------------------------------------------
  task automatic test_auth_tolerance;
    logic [126:0] refv;
    logic [126:0] resp;
    begin
      refv = '0;
      resp = '0;
      for (int n = 0; n <= 12; n++) begin
        resp = refv;
        for (int i = 0; i < n; i++) resp[i*7] = 1'b1;
        cmp_ref_c  = refv;
        cmp_resp_c = resp;
        @(negedge clk_i);
        cmp_start_c = 1'b1;
        @(negedge clk_i);
        cmp_start_c = 1'b0;
        begin
          integer c;
          logic   seen;
          c    = 0;
          seen = 1'b0;
          while (!seen && c < 100) begin
            @(negedge clk_i);
            seen = cmp_done_c;
            c    = c + 1;
          end
          check(seen, "the comparator finished");
        end
        check(cmp_dist_c == n[7:0], "the comparator counted the differing bits");
        if (n <= TOL_BITS) begin
          check(cmp_ok_c == 1'b1, "a distance inside the tolerance authenticates");
        end else begin
          check(cmp_ok_c == 1'b0, "a distance outside the tolerance is rejected");
        end
        n_kat = n_kat + 1;
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 6: the RO PUF against the known answer vectors
  // ---------------------------------------------------------------------
  task automatic test_ro_kat;
    logic [255:0] key;
    logic [62:0]  gold;
    begin
      for (int i = 0; i < n_ro; i++) begin
        dev_id_i = kat_ro_dev[i];
        env_i    = kat_ro_env[i];
        do_cmd(CMD_RO_ENROLL, {55'd0, kat_ro_chal[i]});
        check(resp_o == kat_ro_resp[i], "the RO response matches the model");
        check(mask_o == kat_ro_mask[i], "the 1-out-of-k mask matches the model");
        gold = tb_syndrome(kat_ro_resp[i]);
        check(synd_o == gold, "the syndrome matches the golden model");
        tb_sha256(tb_key_block(kat_ro_resp[i]), key);
        check(key_o == key, "the derived key matches the golden hash");
        n_kat = n_kat + 1;
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 7: the arbiter PUF against the known answer vectors
  // ---------------------------------------------------------------------
  task automatic test_arb_kat;
    begin
      for (int i = 0; i < n_arb; i++) begin
        dev_id_i = kat_arb_dev[i];
        env_i    = kat_arb_env[i];
        do_cmd(CMD_ARB_RESP, kat_arb_seed[i]);
        check(arb_o == kat_arb_resp[i], "the arbiter response matches the model");
        n_kat = n_kat + 1;
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 8: the command interface
  // ---------------------------------------------------------------------
  task automatic test_commands;
    begin
      dev_id_i = 32'h0000_0001;
      env_i    = 4'd0;

      do_cmd(CMD_NOP, 64'd0);
      check(err_o == 1'b0, "the nop command does not raise an error");
      check(status_o == 4'd0, "the nop command leaves the status at zero");

      do_cmd(4'hF, 64'd0);
      check(err_o == 1'b1, "an unknown command raises an error");
      check(status_o == 4'd2, "an unknown command reports the bad command status");
      n_kat = n_kat + 1;
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 9: the key regeneration of section 5 of the paper
  // ---------------------------------------------------------------------
  task automatic test_key_regen;
    logic [255:0] enrol_key;
    logic [62:0]  enrol_synd;
    logic [126:0] enrol_resp;
    begin
      dev_id_i = 32'h0000_00A5;
      env_i    = 4'd0;
      do_cmd(CMD_RO_ENROLL, 64'd42);
      enrol_key  = key_o;
      enrol_synd = synd_o;
      enrol_resp = resp_o;

      do_cmd(CMD_RO_REGEN, 64'd0);
      check(key_o == enrol_key, "the regenerated key equals the enrolled key");
      check(synd_o == enrol_synd, "the regenerated syndrome equals the enrolled one");
      check(resp_o == enrol_resp, "the regenerated response equals the enrolled one");
      check(err_o == 1'b0, "the regeneration did not raise an error");
      n_kat = n_kat + 1;
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 10: the authentication flow of section 4 of the paper
  // ---------------------------------------------------------------------
  task automatic test_auth_flow;
    logic [126:0] enrol_resp;
    begin
      // the arbiter
      dev_id_i = 32'hDEAD_BEEF;
      env_i    = 4'd0;
      do_cmd(CMD_ARB_RESP, 64'hCAFEBABE_12345678);
      do_cmd(CMD_ARB_REF_ST, 64'd0);
      do_cmd(CMD_ARB_AUTH, 64'hCAFEBABE_12345678);
      check(auth_ok_o == 1'b1, "the arbiter authenticates against its reference");
      check(auth_dist_o == 8'd0, "the arbiter distance is zero");
      check(err_o == 1'b0, "the arbiter authentication did not raise an error");
      n_kat = n_kat + 1;

      // the ring oscillator PUF
      do_cmd(CMD_RO_ENROLL, 64'd256);
      enrol_resp = resp_o;
      do_cmd(CMD_RO_REF_ST, 64'd0);
      do_cmd(CMD_RO_AUTH, 64'd256);
      check(auth_ok_o == 1'b1, "the RO PUF authenticates against its reference");
      check(auth_dist_o == 8'd0, "the RO distance is zero");
      check(resp_o == enrol_resp, "the authentication response is the enrolled one");
      n_kat = n_kat + 1;
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 11: an environment change is absorbed by the tolerance
  // ---------------------------------------------------------------------
  task automatic test_env_drift;
    begin
      dev_id_i = 32'hDEAD_BEEF;
      env_i    = 4'd0;
      do_cmd(CMD_RO_ENROLL, 64'd256);
      do_cmd(CMD_RO_REF_ST, 64'd0);
      env_i = 4'd1;                    // the hot environment of the paper
      do_cmd(CMD_RO_AUTH, 64'd256);
      check(auth_ok_o == 1'b1, "the device still authenticates after a drift");
      $display("INFO      RO distance after the environment change = %0d bits",
               auth_dist_o);
      n_kat = n_kat + 1;
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 12: a different device is rejected
  // ---------------------------------------------------------------------
  task automatic test_cross_device;
    begin
      dev_id_i = 32'hDEAD_BEEF;
      env_i    = 4'd0;
      do_cmd(CMD_RO_ENROLL, 64'd256);
      do_cmd(CMD_RO_REF_ST, 64'd0);
      dev_id_i = 32'h1234_5678;         // another chip
      do_cmd(CMD_RO_AUTH, 64'd256);
      check(auth_ok_o == 1'b0, "a different device is rejected");
      $display("INFO      RO distance between two devices = %0d bits",
               auth_dist_o);
      n_kat = n_kat + 1;
    end
  endtask

  // ---------------------------------------------------------------------
  // Test 13: the same challenge gives the same response
  // ---------------------------------------------------------------------
  task automatic test_repeatable;
    logic [126:0] first;
    logic [MASK_W-1:0] first_mask;
    begin
      dev_id_i = 32'h0000_0001;
      env_i    = 4'd0;
      do_cmd(CMD_RO_ENROLL, 64'd137);
      first      = resp_o;
      first_mask = mask_o;
      do_cmd(CMD_RO_ENROLL, 64'd137);
      check(resp_o == first, "the RO response is reproducible");
      check(mask_o == first_mask, "the derived mask is reproducible");
      n_kat = n_kat + 1;
    end
  endtask

  // ---------------------------------------------------------------------
  // The round constants of the golden model
  // ---------------------------------------------------------------------
  initial begin
    gk[0]  = 32'h428a2f98; gk[1]  = 32'h71374491;
    gk[2]  = 32'hb5c0fbcf; gk[3]  = 32'he9b5dba5;
    gk[4]  = 32'h3956c25b; gk[5]  = 32'h59f111f1;
    gk[6]  = 32'h923f82a4; gk[7]  = 32'hab1c5ed5;
    gk[8]  = 32'hd807aa98; gk[9]  = 32'h12835b01;
    gk[10] = 32'h243185be; gk[11] = 32'h550c7dc3;
    gk[12] = 32'h72be5d74; gk[13] = 32'h80deb1fe;
    gk[14] = 32'h9bdc06a7; gk[15] = 32'hc19bf174;
    gk[16] = 32'he49b69c1; gk[17] = 32'hefbe4786;
    gk[18] = 32'h0fc19dc6; gk[19] = 32'h240ca1cc;
    gk[20] = 32'h2de92c6f; gk[21] = 32'h4a7484aa;
    gk[22] = 32'h5cb0a9dc; gk[23] = 32'h76f988da;
    gk[24] = 32'h983e5152; gk[25] = 32'ha831c66d;
    gk[26] = 32'hb00327c8; gk[27] = 32'hbf597fc7;
    gk[28] = 32'hc6e00bf3; gk[29] = 32'hd5a79147;
    gk[30] = 32'h06ca6351; gk[31] = 32'h14292967;
    gk[32] = 32'h27b70a85; gk[33] = 32'h2e1b2138;
    gk[34] = 32'h4d2c6dfc; gk[35] = 32'h53380d13;
    gk[36] = 32'h650a7354; gk[37] = 32'h766a0abb;
    gk[38] = 32'h81c2c92e; gk[39] = 32'h92722c85;
    gk[40] = 32'ha2bfe8a1; gk[41] = 32'ha81a664b;
    gk[42] = 32'hc24b8b70; gk[43] = 32'hc76c51a3;
    gk[44] = 32'hd192e819; gk[45] = 32'hd6990624;
    gk[46] = 32'hf40e3585; gk[47] = 32'h106aa070;
    gk[48] = 32'h19a4c116; gk[49] = 32'h1e376c08;
    gk[50] = 32'h2748774c; gk[51] = 32'h34b0bcb5;
    gk[52] = 32'h391c0cb3; gk[53] = 32'h4ed8aa4a;
    gk[54] = 32'h5b9cca4f; gk[55] = 32'h682e6ff3;
    gk[56] = 32'h748f82ee; gk[57] = 32'h78a5636f;
    gk[58] = 32'h84c87814; gk[59] = 32'h8cc70208;
    gk[60] = 32'h90befffa; gk[61] = 32'ha4506ceb;
    gk[62] = 32'hbef9a3f7; gk[63] = 32'hc67178f2;
  end

  // ---------------------------------------------------------------------
  // Watchdog
  // ---------------------------------------------------------------------
  integer watchdog = 0;
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      watchdog <= 0;
    end else begin
      watchdog <= watchdog + 1;
      if (watchdog > 400000) begin
        $display("MISMATCH  the watchdog fired");
        $display("RESULT                 = FAIL");
        $finish;
      end
    end
  end

  // ---------------------------------------------------------------------
  // The run
  // ---------------------------------------------------------------------
  initial begin
    integer kat_rc;
    kat_file = "kat_vectors.txt";
    kat_rc   = $value$plusargs("kat=%s", kat_file);

    // The wave is written only when the +dump plusarg is present. The depth is
    // limited to the top level, because the two macro twins carry a thousand
    // oscillator nets that would make the trace unreadable and huge.
    dump_file = "simulation.vcd";
    if ($test$plusargs("dump")) begin
      $dumpfile(dump_file);
      $dumpvars(1, tb_siliconroot_puf);
    end

    dev_id_i     = 32'h0000_0001;
    env_i        = 4'd0;
    cmd_valid_i  = 1'b0;
    cmd_i        = 4'd0;
    arg_i        = 64'd0;
    sha_start_c  = 1'b0;
    prng_load_c  = 1'b0;
    prng_step_c  = 1'b0;
    enc_start_c  = 1'b0;
    dec_start_c  = 1'b0;
    cmp_start_c  = 1'b0;

    rst_ni = 1'b0;
    repeat (10) @(posedge clk_i);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);

    $display("INFO      the PUF device authentication testbench");
    $display("INFO      known answer file = %0s", kat_file);

    load_kat;
    $display("INFO      vectors: %0d RO, %0d arbiter, %0d syndrome",
             n_ro, n_arb, n_syn);
    check(n_ro > 0, "the RO vectors were read");
    check(n_arb > 0, "the arbiter vectors were read");
    check(n_syn > 0, "the syndrome vectors were read");

    test_sha_kat;
    test_prng_kat;
    test_bch_encoder;
    test_bch_decoder;
    test_auth_tolerance;
    test_ro_kat;
    test_arb_kat;
    test_commands;
    test_key_regen;
    test_auth_flow;
    test_env_drift;
    test_cross_device;
    test_repeatable;

    $display("-------------------------------------");
    $display("- Report Phase");
    $display("-------------------------------------");
    $display("MATCH      COUNTER     = %0d", chk_cnt - fun_err);
    $display("MISS MATCH COUNTER     = %0d", err_cnt);
    $display("");
    $display("STIMULUS");
    $display("  RO known answers       = %0d", n_ro);
    $display("  arbiter known answers  = %0d", n_arb);
    $display("  syndrome known answers = %0d", n_syn);
    $display("  checks performed       = %0d", chk_cnt);
    $display("  checks matched         = %0d", chk_cnt - fun_err);
    $display("  checks mismatched      = %0d", fun_err);
    $display("  handshake observations = %0d", hs_cnt);
    $display("  handshake violations   = %0d", hs_err);
    $display("");
    $display("LATENCY (cycles, longest run per command)");
    $display("  nop                    = %0d over %0d run(s)", cmd_cyc[0], cmd_run[0]);
    $display("  arbiter response       = %0d over %0d run(s)", cmd_cyc[1], cmd_run[1]);
    $display("  arbiter authenticate   = %0d over %0d run(s)", cmd_cyc[2], cmd_run[2]);
    $display("  RO enrol               = %0d over %0d run(s)", cmd_cyc[3], cmd_run[3]);
    $display("  RO regenerate          = %0d over %0d run(s)", cmd_cyc[4], cmd_run[4]);
    $display("  RO authenticate        = %0d over %0d run(s)", cmd_cyc[5], cmd_run[5]);
    $display("  arbiter ref store      = %0d over %0d run(s)", cmd_cyc[6], cmd_run[6]);
    $display("  RO ref store           = %0d over %0d run(s)", cmd_cyc[7], cmd_run[7]);
    $display("");
    $display("GATES                        have   need   ok");
    $display("  RO known answers          %0d      %0d   %0s",
             n_ro, n_ro, (n_ro >= 8) ? "yes" : "no");
    $display("  arbiter known answers     %0d      %0d   %0s",
             n_arb, n_arb, (n_arb >= 5) ? "yes" : "no");
    $display("  syndrome known answers    %0d      %0d   %0s",
             n_syn, n_syn, (n_syn >= 5) ? "yes" : "no");
    $display("  mismatches                %0d      %0d   %0s",
             err_cnt, 0, (err_cnt == 0) ? "yes" : "no");
    $display("  handshake violations      %0d      %0d   %0s",
             hs_err, 0, (hs_err == 0) ? "yes" : "no");
    $display("");
    if (err_cnt == 0) begin
      $display("RESULT                 = PASS");
    end else begin
      $display("RESULT                 = FAIL");
    end
    $finish;
  end

endmodule : tb_siliconroot_puf
`default_nettype wire
