///////////////////////////////////////////////////////
// Module : puf_pkg
// Author   : najamdesktop\najam
// Description: Shared constants and functions for the PUF-based device
//              authentication IP.
//
//              Three groups of content live here.
//
//              1. GF(2^7) arithmetic, the field the BCH(127,64,21) code lives in.
//                 The field is GF(2)[x]/(x^7 + x^3 + 1); alpha = x is a primitive
//                 element of order 127. gf_mul is the carry-less product reduced
//                 by the field polynomial, gf_sqr is the same thing specialised to
//                 the squaring map, gf_inv is a^-1 = a^126 built from the six
//                 successive squares a^2, a^4, ... a^64, and gf_mulc multiplies by
//                 a constant so the synthesiser can fold the operand down to a
//                 XOR network.
//
//              2. BCH(127,64,21) helper tables. The narrow-sense primitive BCH
//                 code has generator polynomial
//                   g(x) = m_1 m_3 m_5 m_7 m_9 m_11 m_13 m_15 m_19
//                        = 0xa1ab815bc7ec8025
//                 of degree 63, so k = 127 - 63 = 64 and the consecutive run of
//                 roots alpha^1..alpha^20 gives a minimum distance of 21, i.e.
//                 ten correctable errors. The nine factors m_r are the minimal
//                 polynomials of the cyclotomic-class representatives
//                 r in {1,3,5,7,9,11,13,15,19}; class_mlow holds the low seven
//                 bits of each (the x^7 term is implicit), alpha_conv holds
//                 alpha^(r*i) which turns a seven-bit class remainder into a
//                 field element, syn_class and syn_sq say which class and how
//                 many squarings each of the twenty syndromes S_1..S_20 needs,
//                 and chien_mul holds alpha^(-i) for the Chien search.
//
//              3. FIPS 180-4 SHA-256 round and initial-state constants.
//
//              Every table here was produced by an independent Python model of
//              the same algebra and cross-checked against it; the values are
//              not transcribed from a publication by hand.
///////////////////////////////////////////////////////
`default_nettype none

package puf_pkg;

  // ---------------------------------------------------------------------
  // GF(2^7) field definition
  // ---------------------------------------------------------------------
  localparam logic [7:0] GF_POLY    = 8'h89;   // x^7 + x^3 + 1, the reduction polynomial
  localparam logic [6:0] GF_ZERO    = 7'h00;
  localparam logic [6:0] GF_ONE     = 7'h01;

  // ---------------------------------------------------------------------
  // BCH(127,64,21) code parameters
  // ---------------------------------------------------------------------
  localparam int BCH_N      = 127;  // codeword length
  localparam int BCH_K      = 64;   // message length, 127 - 63
  localparam int BCH_B      = 63;   // syndrome length, n - k
  localparam int BCH_T      = 10;   // correctable errors, (d_min - 1) / 2
  localparam int BCH_DMIN   = 21;   // minimum distance
  localparam int NUM_CLASS  = 9;    // cyclotomic classes touched by alpha^1..alpha^20
  localparam int NUM_SYN    = 20;   // syndromes S_1..S_20
  localparam int MAX_LOC    = 20;   // upper bound on the Berlekamp-Massey locator degree

  localparam logic [63:0] BCH_G    = 64'ha1ab815bc7ec8025;  // g(x), degree 63
  localparam logic [62:0] BCH_GL   = 63'h21ab815bc7ec8025;  // g(x) without its x^63 term

  // ---------------------------------------------------------------------
  // GF(2^7) primitives
  // ---------------------------------------------------------------------

  // Carry-less product of a and b reduced by x^7 + x^3 + 1.
  //
  // Two style rules are baked into the code below, both of them learned the
  // hard way from the synthesis log:
  //
  //   1. The accumulation uses a conditional expression rather than a
  //      conditional assignment. A conditional assignment (`if (b[i]) p = ...`)
  //      leaves the target unassigned on the other branch, and a synthesis tool
  //      then has to infer a latch for it, which is both a style failure and a
  //      functional hazard: a latch holds its power-up value, not the zero the
  //      accumulator starts from. The conditional expression assigns the
  //      target on every path and keeps the function purely combinational.
  //
  //   2. The two reduction loops are written out by hand instead of using a
  //      `for` statement. When a function that contains a loop is inlined
  //      into a caller that is itself inlined into a larger process, the
  //      synthesis tool loses the loop counter's initialisation and infers a
  //      latch for it. That happened here: 205 latches on the loop index of
  //      this function. Unrolling removes the loop counter entirely, so the
  //      function is a straight line of assignments that every tool reads the
  //      same way.
  //
  // The unrolled form is bit for bit what the loops computed: the partial
  // products are accumulated from the least significant bit upwards, and the
  // reduction folds bit 13 down to bit 7 by XORing in x^7 + x^3 + 1 shifted
  // into place.
  function automatic logic [6:0] gf_mul(input logic [6:0] a, input logic [6:0] b);
    logic [13:0] p;
    logic [13:0] t;
    begin
      p = 14'd0;
      t = {7'd0, a} << 0;  p = b[0] ? (p ^ t) : p;
      t = {7'd0, a} << 1;  p = b[1] ? (p ^ t) : p;
      t = {7'd0, a} << 2;  p = b[2] ? (p ^ t) : p;
      t = {7'd0, a} << 3;  p = b[3] ? (p ^ t) : p;
      t = {7'd0, a} << 4;  p = b[4] ? (p ^ t) : p;
      t = {7'd0, a} << 5;  p = b[5] ? (p ^ t) : p;
      t = {7'd0, a} << 6;  p = b[6] ? (p ^ t) : p;
      t = 14'h089 << 6;    p = p[13] ? (p ^ t) : p;
      t = 14'h089 << 5;    p = p[12] ? (p ^ t) : p;
      t = 14'h089 << 4;    p = p[11] ? (p ^ t) : p;
      t = 14'h089 << 3;    p = p[10] ? (p ^ t) : p;
      t = 14'h089 << 2;    p = p[9]  ? (p ^ t) : p;
      t = 14'h089 << 1;    p = p[8]  ? (p ^ t) : p;
      t = 14'h089 << 0;    p = p[7]  ? (p ^ t) : p;
      gf_mul = p[6:0];
    end
  endfunction

  // Squaring map written out bit by bit: (sum a_i x^i)^2 = sum a_i x^(2i) and
  // x^7 = x^3 + 1 folds the overflow back in. Verified against gf_mul over all
  // 128 field elements.
  function automatic logic [6:0] gf_sqr(input logic [6:0] a);
    logic [6:0] r;
    begin
      r[0] = a[0];
      r[1] = a[4] ^ a[6];
      r[2] = a[1];
      r[3] = a[5];
      r[4] = a[2] ^ a[4] ^ a[6];
      r[5] = a[6];
      r[6] = a[3] ^ a[5];
      gf_sqr = r;
    end
  endfunction

  // Multiplicative inverse, a^-1 = a^126 = a^2 * a^4 * a^8 * a^16 * a^32 * a^64.
  // The argument must be non-zero; the zero input returns zero.
  function automatic logic [6:0] gf_inv(input logic [6:0] a);
    logic [6:0] b;
    logic [6:0] r;
    begin
      b = gf_sqr(a);
      r = GF_ONE;
      for (int i = 0; i < 6; i++) begin
        r = gf_mul(r, b);
        b = gf_sqr(b);
      end
      gf_inv = r;
    end
  endfunction

  // Multiply by a constant. Written as a plain product so that synthesis can
  // fold the constant operand into a fixed XOR network.
  function automatic logic [6:0] gf_mulc(input logic [6:0] a, input logic [6:0] k);
    gf_mulc = gf_mul(a, k);
  endfunction

  // ---------------------------------------------------------------------
  // Cyclotomic class tables
  // ---------------------------------------------------------------------

  // Low seven bits of the minimal polynomial m_r(x) of alpha^r, for the nine
  // class representatives r in {1,3,5,7,9,11,13,15,19}. The x^7 term of each
  // minimal polynomial is implicit in the seven-bit remainder LFSR.
  function automatic logic [6:0] class_mlow(input logic [3:0] cls);
    case (cls)
      4'd0: class_mlow = 7'h09;   // m_1(x)  = x^7 + x^3 + 1
      4'd1: class_mlow = 7'h0f;   // m_3(x)  = x^7 + x^3 + x^2 + x + 1
      4'd2: class_mlow = 7'h1d;   // m_5(x)  = x^7 + x^4 + x^3 + x^2 + 1
      4'd3: class_mlow = 7'h77;   // m_7(x)  = x^7 + x^6 + x^5 + x^4 + x^2 + x + 1
      4'd4: class_mlow = 7'h3f;   // m_9(x)  = x^7 + x^5 + x^4 + x^3 + x^2 + x + 1
      4'd5: class_mlow = 7'h55;   // m_11(x) = x^7 + x^6 + x^4 + x^2 + 1
      4'd6: class_mlow = 7'h03;   // m_13(x) = x^7 + x + 1
      4'd7: class_mlow = 7'h6f;   // m_15(x) = x^7 + x^6 + x^5 + x^4 + x^3 + x^2 + x
      4'd8: class_mlow = 7'h4b;   // m_19(x) = x^7 + x^6 + x^4 + x^3 + x + 1
      default: class_mlow = 7'h00;
    endcase
  endfunction

  // alpha^(r*i) for the class representative r and remainder bit i. Multiplying
  // the seven-bit class remainder by these weights turns the remainder
  // polynomial into the field element it stands for.
  function automatic logic [6:0] alpha_conv(input logic [3:0] cls, input logic [2:0] idx);
    case (cls)
      4'd0: case (idx)
        3'd0: alpha_conv = 7'h01; 3'd1: alpha_conv = 7'h02; 3'd2: alpha_conv = 7'h04;
        3'd3: alpha_conv = 7'h08; 3'd4: alpha_conv = 7'h10; 3'd5: alpha_conv = 7'h20;
        3'd6: alpha_conv = 7'h40;
        default: alpha_conv = 7'h00;
      endcase
      4'd1: case (idx)
        3'd0: alpha_conv = 7'h01; 3'd1: alpha_conv = 7'h08; 3'd2: alpha_conv = 7'h40;
        3'd3: alpha_conv = 7'h24; 3'd4: alpha_conv = 7'h32; 3'd5: alpha_conv = 7'h0b;
        3'd6: alpha_conv = 7'h58;
        default: alpha_conv = 7'h00;
      endcase
      4'd2: case (idx)
        3'd0: alpha_conv = 7'h01; 3'd1: alpha_conv = 7'h20; 3'd2: alpha_conv = 7'h48;
        3'd3: alpha_conv = 7'h0b; 3'd4: alpha_conv = 7'h72; 3'd5: alpha_conv = 7'h35;
        3'd6: alpha_conv = 7'h45;
        default: alpha_conv = 7'h00;
      endcase
      4'd3: case (idx)
        3'd0: alpha_conv = 7'h01; 3'd1: alpha_conv = 7'h09; 3'd2: alpha_conv = 7'h41;
        3'd3: alpha_conv = 7'h6d; 3'd4: alpha_conv = 7'h33; 3'd5: alpha_conv = 7'h30;
        3'd6: alpha_conv = 7'h2b;
        default: alpha_conv = 7'h00;
      endcase
      4'd4: case (idx)
        3'd0: alpha_conv = 7'h01; 3'd1: alpha_conv = 7'h24; 3'd2: alpha_conv = 7'h58;
        3'd3: alpha_conv = 7'h5d; 3'd4: alpha_conv = 7'h60; 3'd5: alpha_conv = 7'h4a;
        3'd6: alpha_conv = 7'h71;
        default: alpha_conv = 7'h00;
      endcase
      4'd5: case (idx)
        3'd0: alpha_conv = 7'h01; 3'd1: alpha_conv = 7'h19; 3'd2: alpha_conv = 7'h53;
        3'd3: alpha_conv = 7'h0c; 3'd4: alpha_conv = 7'h25; 3'd5: alpha_conv = 7'h6b;
        3'd6: alpha_conv = 7'h50;
        default: alpha_conv = 7'h00;
      endcase
      4'd6: case (idx)
        3'd0: alpha_conv = 7'h01; 3'd1: alpha_conv = 7'h64; 3'd2: alpha_conv = 7'h6a;
        3'd3: alpha_conv = 7'h36; 3'd4: alpha_conv = 7'h3e; 3'd5: alpha_conv = 7'h28;
        3'd6: alpha_conv = 7'h4e;
        default: alpha_conv = 7'h00;
      endcase
      4'd7: case (idx)
        3'd0: alpha_conv = 7'h01; 3'd1: alpha_conv = 7'h0b; 3'd2: alpha_conv = 7'h45;
        3'd3: alpha_conv = 7'h4a; 3'd4: alpha_conv = 7'h23; 3'd5: alpha_conv = 7'h6f;
        3'd6: alpha_conv = 7'h76;
        default: alpha_conv = 7'h00;
      endcase
      4'd8: case (idx)
        3'd0: alpha_conv = 7'h01; 3'd1: alpha_conv = 7'h39; 3'd2: alpha_conv = 7'h1b;
        3'd3: alpha_conv = 7'h37; 3'd4: alpha_conv = 7'h57; 3'd5: alpha_conv = 7'h3c;
        3'd6: alpha_conv = 7'h4f;
        default: alpha_conv = 7'h00;
      endcase
      default: alpha_conv = 7'h00;
    endcase
  endfunction

  // Which cyclotomic class the exponent j belongs to. alpha^j is a conjugate of
  // alpha^r, and alpha^j = (alpha^r)^(2^k) for the squaring count k.
  function automatic logic [3:0] syn_class(input logic [4:0] j);
    case (j)
      5'd1, 5'd2, 5'd4, 5'd8, 5'd16 : syn_class = 4'd0;   // class of alpha^1
      5'd3, 5'd6, 5'd12              : syn_class = 4'd1;   // class of alpha^3
      5'd5, 5'd10, 5'd20             : syn_class = 4'd2;   // class of alpha^5
      5'd7, 5'd14                    : syn_class = 4'd3;   // class of alpha^7
      5'd9, 5'd17, 5'd18             : syn_class = 4'd4;   // class of alpha^9
      5'd11                          : syn_class = 4'd5;   // class of alpha^11
      5'd13                          : syn_class = 4'd6;   // class of alpha^13
      5'd15                          : syn_class = 4'd7;   // class of alpha^15
      5'd19                          : syn_class = 4'd8;   // class of alpha^19
      default: syn_class = 4'd0;
    endcase
  endfunction

  // How many times the class field element has to be squared to become
  // alpha^j.
  function automatic logic [2:0] syn_sq(input logic [4:0] j);
    case (j)
      5'd1  : syn_sq = 3'd0;
      5'd2  : syn_sq = 3'd1;
      5'd4  : syn_sq = 3'd2;
      5'd8  : syn_sq = 3'd3;
      5'd16 : syn_sq = 3'd4;
      5'd3  : syn_sq = 3'd0;
      5'd6  : syn_sq = 3'd1;
      5'd12 : syn_sq = 3'd2;
      5'd5  : syn_sq = 3'd0;
      5'd10 : syn_sq = 3'd1;
      5'd20 : syn_sq = 3'd2;
      5'd7  : syn_sq = 3'd0;
      5'd14 : syn_sq = 3'd1;
      5'd9  : syn_sq = 3'd0;
      5'd18 : syn_sq = 3'd1;
      5'd17 : syn_sq = 3'd4;
      5'd11 : syn_sq = 3'd0;
      5'd13 : syn_sq = 3'd0;
      5'd15 : syn_sq = 3'd0;
      5'd19 : syn_sq = 3'd0;
      default: syn_sq = 3'd0;
    endcase
  endfunction

  // alpha^(-i) for i = 1..20, the constant multipliers the Chien search uses to
  // walk the locator coefficients round the circle.
  function automatic logic [6:0] chien_mul(input logic [4:0] idx);
    case (idx)
      5'd1 : chien_mul = 7'h44;   // alpha^(-1)
      5'd2 : chien_mul = 7'h22;   // alpha^(-2)
      5'd3 : chien_mul = 7'h11;   // alpha^(-3)
      5'd4 : chien_mul = 7'h4c;   // alpha^(-4)
      5'd5 : chien_mul = 7'h26;   // alpha^(-5)
      5'd6 : chien_mul = 7'h13;   // alpha^(-6)
      5'd7 : chien_mul = 7'h4d;   // alpha^(-7)
      5'd8 : chien_mul = 7'h62;   // alpha^(-8)
      5'd9 : chien_mul = 7'h31;   // alpha^(-9)
      5'd10: chien_mul = 7'h5c;   // alpha^(-10)
      5'd11: chien_mul = 7'h2e;   // alpha^(-11)
      5'd12: chien_mul = 7'h17;   // alpha^(-12)
      5'd13: chien_mul = 7'h4f;   // alpha^(-13)
      5'd14: chien_mul = 7'h63;   // alpha^(-14)
      5'd15: chien_mul = 7'h75;   // alpha^(-15)
      5'd16: chien_mul = 7'h7e;   // alpha^(-16)
      5'd17: chien_mul = 7'h3f;   // alpha^(-17)
      5'd18: chien_mul = 7'h5b;   // alpha^(-18)
      5'd19: chien_mul = 7'h69;   // alpha^(-19)
      5'd20: chien_mul = 7'h70;   // alpha^(-20)
      default: chien_mul = 7'h01;
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // Device variation hash
  // ---------------------------------------------------------------------

  // 32-bit avalanche hash used by the two PUF macro twins to turn a device
  // identifier and an index into the pseudo-random physical variation of one
  // ring oscillator or one arbiter delay stage. The same function is used by
  // the calibration model, so the constants quoted in the design
  // specification are reproducible.
  function automatic logic [31:0] puf_hash32(input logic [31:0] a, input logic [31:0] b);
    logic [31:0] h;
    begin
      h = a ^ (b * 32'h9E37_79B9);
      h = (h ^ (h >> 16)) * 32'h85EB_CA6B;
      h = (h ^ (h >> 13)) * 32'hC2B2_AE35;
      puf_hash32 = h ^ (h >> 16);
    end
  endfunction

  // ---------------------------------------------------------------------
  // FIPS 180-4 SHA-256 constants
  // ---------------------------------------------------------------------
  function automatic logic [31:0] sha256_k(input logic [5:0] t);
    case (t)
      6'd0 : sha256_k = 32'h428a2f98;  6'd1 : sha256_k = 32'h71374491;
      6'd2 : sha256_k = 32'hb5c0fbcf;  6'd3 : sha256_k = 32'he9b5dba5;
      6'd4 : sha256_k = 32'h3956c25b;  6'd5 : sha256_k = 32'h59f111f1;
      6'd6 : sha256_k = 32'h923f82a4;  6'd7 : sha256_k = 32'hab1c5ed5;
      6'd8 : sha256_k = 32'hd807aa98;  6'd9 : sha256_k = 32'h12835b01;
      6'd10: sha256_k = 32'h243185be;  6'd11: sha256_k = 32'h550c7dc3;
      6'd12: sha256_k = 32'h72be5d74;  6'd13: sha256_k = 32'h80deb1fe;
      6'd14: sha256_k = 32'h9bdc06a7;  6'd15: sha256_k = 32'hc19bf174;
      6'd16: sha256_k = 32'he49b69c1;  6'd17: sha256_k = 32'hefbe4786;
      6'd18: sha256_k = 32'h0fc19dc6;  6'd19: sha256_k = 32'h240ca1cc;
      6'd20: sha256_k = 32'h2de92c6f;  6'd21: sha256_k = 32'h4a7484aa;
      6'd22: sha256_k = 32'h5cb0a9dc;  6'd23: sha256_k = 32'h76f988da;
      6'd24: sha256_k = 32'h983e5152;  6'd25: sha256_k = 32'ha831c66d;
      6'd26: sha256_k = 32'hb00327c8;  6'd27: sha256_k = 32'hbf597fc7;
      6'd28: sha256_k = 32'hc6e00bf3;  6'd29: sha256_k = 32'hd5a79147;
      6'd30: sha256_k = 32'h06ca6351;  6'd31: sha256_k = 32'h14292967;
      6'd32: sha256_k = 32'h27b70a85;  6'd33: sha256_k = 32'h2e1b2138;
      6'd34: sha256_k = 32'h4d2c6dfc;  6'd35: sha256_k = 32'h53380d13;
      6'd36: sha256_k = 32'h650a7354;  6'd37: sha256_k = 32'h766a0abb;
      6'd38: sha256_k = 32'h81c2c92e;  6'd39: sha256_k = 32'h92722c85;
      6'd40: sha256_k = 32'ha2bfe8a1;  6'd41: sha256_k = 32'ha81a664b;
      6'd42: sha256_k = 32'hc24b8b70;  6'd43: sha256_k = 32'hc76c51a3;
      6'd44: sha256_k = 32'hd192e819;  6'd45: sha256_k = 32'hd6990624;
      6'd46: sha256_k = 32'hf40e3585;  6'd47: sha256_k = 32'h106aa070;
      6'd48: sha256_k = 32'h19a4c116;  6'd49: sha256_k = 32'h1e376c08;
      6'd50: sha256_k = 32'h2748774c;  6'd51: sha256_k = 32'h34b0bcb5;
      6'd52: sha256_k = 32'h391c0cb3;  6'd53: sha256_k = 32'h4ed8aa4a;
      6'd54: sha256_k = 32'h5b9cca4f;  6'd55: sha256_k = 32'h682e6ff3;
      6'd56: sha256_k = 32'h748f82ee;  6'd57: sha256_k = 32'h78a5636f;
      6'd58: sha256_k = 32'h84c87814;  6'd59: sha256_k = 32'h8cc70208;
      6'd60: sha256_k = 32'h90befffa;  6'd61: sha256_k = 32'ha4506ceb;
      6'd62: sha256_k = 32'hbef9a3f7;  6'd63: sha256_k = 32'hc67178f2;
      default: sha256_k = 32'h00000000;
    endcase
  endfunction

  function automatic logic [31:0] sha256_h0(input logic [2:0] i);
    case (i)
      3'd0: sha256_h0 = 32'h6a09e667;
      3'd1: sha256_h0 = 32'hbb67ae85;
      3'd2: sha256_h0 = 32'h3c6ef372;
      3'd3: sha256_h0 = 32'ha54ff53a;
      3'd4: sha256_h0 = 32'h510e527f;
      3'd5: sha256_h0 = 32'h9b05688c;
      3'd6: sha256_h0 = 32'h1f83d9ab;
      3'd7: sha256_h0 = 32'h5be0cd19;
      default: sha256_h0 = 32'h00000000;
    endcase
  endfunction

endpackage : puf_pkg

`default_nettype wire
