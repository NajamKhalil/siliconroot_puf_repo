#!/usr/bin/env python3
"""Calibration and known-answer generator for the PUF macro twins.

This script is the Python twin of the two functional twins in the RTL:

    puf_ro_macro.sv        the 1024 ring oscillator array
    puf_arbiter_macro.sv   the 64 stage arbiter delay chain

The arithmetic below is the INTEGER arithmetic of the RTL, not a floating
point approximation of it: every multiply is a 64-bit signed product whose
bits [47:16] are taken, which is a floor division by 2^16.  A model that used
floats would report slightly different percentages and would no longer be a
model of the thing that is actually simulated.

The script has three jobs.

  1. Measure the inter-chip and intra-chip variation of the twins and check
     them against the figures published by Suh and Devadas, DAC 2007:

         RO PUF   inter-chip  46.15 %   (n = 128, p = 0.4615)
         RO PUF   intra-chip   0.48 %   (0.6 bits out of 128, 20->120 C)
         Arbiter  inter-chip  23 %
         Arbiter  intra-chip   0.7 %

  2. Sweep the free constants of both twins and print the table the constants
     in the RTL were taken from.

  3. Emit the known answer vectors that the SystemVerilog testbench checks
     the RTL against.  Those vectors are produced by THIS model and are the
     only place where the two implementations meet, so an error in either
     one shows up as a testbench failure.

Usage:
    python3 calibrate_models.py sweep          # the constant sweep table
    python3 calibrate_models.py measure        # the variation measurement
    python3 calibrate_models.py kat            # write kat_vectors.txt
"""
import os
import random
import sys

MASK32 = 0xFFFFFFFF
MASK64 = 0xFFFFFFFFFFFFFFFF
MASK63 = (1 << 63) - 1

HERE = os.path.dirname(os.path.abspath(__file__))


# --------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------
def hash32(a, b):
    """The 32-bit avalanche hash shared by both twins and by puf_pkg.puf_hash32."""
    h = (a ^ ((b * 0x9E3779B9) & MASK32)) & MASK32
    h = ((h ^ (h >> 16)) * 0x85EBCA6B) & MASK32
    h = ((h ^ (h >> 13)) * 0xC2B2AE35) & MASK32
    return (h ^ (h >> 16)) & MASK32


def q16_signed(a):
    """The 18-bit signed Q16 value the twins derive from the top half of a hash."""
    return ((a >> 16) * 2) - 65536


def qmul(a, b):
    """64-bit signed product, bits [47:16] taken: a floor division by 2^16."""
    return (a * b) >> 16


# --------------------------------------------------------------------------
# RO twin - mirrors puf_ro_macro.sv
# --------------------------------------------------------------------------
N_RO = 1024
N_PAIRS = N_RO // 2
N_BITS = 127
K_MASK = 4
WIN_LEN = 1024
CNT_W = 16

# Free constants of the twin.  These are the values the sweep selects.
SPREAD_Q = 36864      # 0.5625  device specific frequency spread
BIAS_Q = 16384        # 0.2500  design common layout bias
DIFF_Q = 459          # 0.0070  differential environmental drift
W_COMMON_Q = {0: 0, 1: 19661, 2: 6554, 3: 29491}


def ro_count(dev, idx, env):
    """The count of one ring oscillator over the measurement window."""
    u = q16_signed(hash32(dev, 0x1000 + 2 * idx))
    b = q16_signed(hash32(0xC0FFEE00, 0x2000 + idx))
    w = W_COMMON_Q.get(env, 0)
    d = 0
    if env:
        d = q16_signed(hash32(dev, 0x3000 + idx + 0x100 * env))
    f = 65536 + qmul(u, SPREAD_Q) + qmul(b, BIAS_Q)
    f = qmul(f, 65536 + w)
    f = qmul(f, 65536 + qmul(d, DIFF_Q))
    c = qmul(f, WIN_LEN)
    return c & 0xFFFF


def ro_response(dev, env, chal):
    """The 127-bit response and the 1-out-of-4 mask that produced it."""
    bits = []
    mask = []
    for i in range(N_BITS):
        best_d, best_k, best_b = -1, 0, 0
        for k in range(K_MASK):
            p = (i * K_MASK + k + chal) % N_PAIRS
            ca = ro_count(dev, 2 * p, env)
            cb = ro_count(dev, 2 * p + 1, env)
            d = abs(ca - cb)
            b = 1 if ca > cb else 0
            if d > best_d:
                best_d, best_k, best_b = d, k, b
        bits.append(best_b)
        mask.append(best_k)
    return bits, mask


def ro_diff_bits(dev_a, dev_b, chal):
    a, _ = ro_response(dev_a, 0, chal)
    b, _ = ro_response(dev_b, 0, chal)
    return sum(1 for x, y in zip(a, b) if x != y)


def ro_intra_bits(dev, chal, env_a, env_b):
    a, _ = ro_response(dev, env_a, chal)
    b, _ = ro_response(dev, env_b, chal)
    return sum(1 for x, y in zip(a, b) if x != y)


# --------------------------------------------------------------------------
# Arbiter twin - mirrors puf_arbiter_macro.sv
# --------------------------------------------------------------------------
ARB_STAGES = 64
ARB_BITS = 64

C_SKEW_Q = 68813      # 1.050  design common stage skew
PERT_Q = 3146         # 0.048  environmental perturbation of one stage


def arb_skew(dev, env, i):
    sk = C_SKEW_Q + q16_signed(hash32(dev, 0x4000 + i))
    if env:
        sk += qmul(q16_signed(hash32(dev, 0x6000 + i + 0x100 * env)), PERT_Q)
    return sk


def arb_eval(skews, x):
    """Walk the delay chain the way the twin walks it."""
    par = 0
    acc = 0
    for i in range(ARB_STAGES):
        acc += (-skews[i] if par else skews[i])
        par ^= (x >> i) & 1
    return acc


def arb_bits(dev, env, seed, k=ARB_BITS):
    st = seed if seed else 1
    sk = [arb_skew(dev, env, i) for i in range(ARB_STAGES)]
    out = []
    for _ in range(k):
        out.append(1 if arb_eval(sk, st) < 0 else 0)
        fb = (st >> 63) & 1
        st = ((st << 1) & MASK64) ^ (0x1B if fb else 0)
    return out


def arb_diff_bits(dev_a, dev_b, seed):
    a = arb_bits(dev_a, 0, seed)
    b = arb_bits(dev_b, 0, seed)
    return sum(1 for x, y in zip(a, b) if x != y)


def arb_intra_bits(dev, seed, env_a, env_b):
    a = arb_bits(dev, env_a, seed)
    b = arb_bits(dev, env_b, seed)
    return sum(1 for x, y in zip(a, b) if x != y)


# --------------------------------------------------------------------------
# Measurement
# --------------------------------------------------------------------------
def measure_ro(trials=40, chal=0):
    random.seed(20240607)
    inter = 0
    intra = 0
    for _ in range(trials):
        da = random.getrandbits(32)
        db = random.getrandbits(32)
        inter += ro_diff_bits(da, db, chal)
        intra += ro_intra_bits(da, chal, 0, 1)
    n = trials * N_BITS
    return 100.0 * inter / n, 100.0 * intra / n


def measure_arb(trials=120):
    random.seed(20240607)
    inter = 0
    intra = 0
    for _ in range(trials):
        da = random.getrandbits(32)
        db = random.getrandbits(32)
        seed = random.getrandbits(64) | 1
        inter += arb_diff_bits(da, db, seed)
        intra += arb_intra_bits(da, seed, 0, 1)
    n = trials * ARB_BITS
    return 100.0 * inter / n, 100.0 * intra / n


def cmd_measure():
    print("=" * 74)
    print("PUF macro twin variation, measured with the twin's own integer arithmetic")
    print("=" * 74)
    i, n = measure_ro()
    print("RO PUF     inter-chip %6.2f %%   target 46.15 %%   %s"
          % (i, "ok" if abs(i - 46.15) < 2.0 else "OFF TARGET"))
    print("RO PUF     intra-chip %6.3f %%   target  0.48 %%   %s"
          % (n, "ok" if abs(n - 0.48) < 0.30 else "OFF TARGET"))
    i, n = measure_arb()
    print("Arbiter    inter-chip %6.2f %%   target 23.00 %%   %s"
          % (i, "ok" if abs(i - 23.0) < 2.0 else "OFF TARGET"))
    print("Arbiter    intra-chip %6.3f %%   target  0.70 %%   %s"
          % (n, "ok" if abs(n - 0.70) < 0.30 else "OFF TARGET"))
    print()


def cmd_sweep():
    global SPREAD_Q, BIAS_Q, DIFF_Q, C_SKEW_Q, PERT_Q
    print("=" * 74)
    print("RO twin sweep: SPREAD_Q BIAS_Q DIFF_Q -> inter % / intra %")
    print("=" * 74)
    print(" SPREAD    BIAS    DIFF     inter%    intra%")
    base_spread, base_bias, base_diff = SPREAD_Q, BIAS_Q, DIFF_Q
    for spread in (16384, 32768, 49152):
        for bias in (6554, 13107, 19661):
            for diff in (66, 131, 197, 394, 787):
                SPREAD_Q, BIAS_Q, DIFF_Q = spread, bias, diff
                i, n = measure_ro(trials=12)
                print("  %5.3f  %5.3f  %6.4f   %6.2f   %7.3f"
                      % (spread / 65536.0, bias / 65536.0, diff / 65536.0, i, n))
    SPREAD_Q, BIAS_Q, DIFF_Q = base_spread, base_bias, base_diff

    print()
    print("=" * 74)
    print("Arbiter twin sweep: C_SKEW_Q PERT_Q -> inter % / intra %")
    print("=" * 74)
    print(" C_SKEW    PERT     inter%    intra%")
    base_skew, base_pert = C_SKEW_Q, PERT_Q
    for skew in (0, 16384, 32768, 49152, 62259, 65536):
        for pert in (0, 328, 1311, 3146, 6554):
            C_SKEW_Q, PERT_Q = skew, pert
            i, n = measure_arb(trials=60)
            print("  %5.3f  %6.4f   %6.2f   %7.3f"
                  % (skew / 65536.0, pert / 65536.0, i, n))
    C_SKEW_Q, PERT_Q = base_skew, base_pert


# --------------------------------------------------------------------------
# Known answer vectors
# --------------------------------------------------------------------------
# BIT ORDER.  The word that carries a response is little endian with respect
# to the OUTPUT BIT INDEX: bit i of the word is the i-th generated bit, the
# same way the RTL numbers them (resp_q[bit_q]).  The mask entry of output bit
# i is the two bit field at bits 2*i+1 : 2*i of the mask word.
#
# The words are written in chunks of at most sixteen hex digits because that
# is the widest field the SystemVerilog $sscanf of the testbench reads
# without losing the top bits.
BCH_G = 0xA1AB815BC7EC8025
BCH_GL = BCH_G & MASK63


def bits_to_word(bits):
    """Bit i of the word is bit i of the list (little endian in the index)."""
    w = 0
    for i, b in enumerate(bits):
        w |= (b & 1) << i
    return w


def mask_to_word(ranks):
    """The mask entry of output bit i is the two bit field at bits 2*i+1 : 2*i."""
    w = 0
    for i, r in enumerate(ranks):
        w |= (r & 3) << (2 * i)
    return w


def bch_syndrome(word):
    """w(x) mod g(x), the 63-bit remainder, most significant bit first."""
    r = 0
    for i in range(126, -1, -1):
        fb = (r >> 62) & 1
        r = ((r << 1) | ((word >> i) & 1)) & MASK63
        if fb:
            r ^= BCH_GL
    return r


def chunk(value, width):
    """Split a word into hex chunks of at most 64 bits, high chunk first."""
    n = (width + 63) // 64
    out = []
    for i in range(n - 1, -1, -1):
        out.append("%016x" % ((value >> (64 * i)) & 0xFFFFFFFFFFFFFFFF))
    return out


def kat_lines():
    """The vectors the SystemVerilog testbench checks the RTL against."""
    out = []
    out.append("# PUF device authentication - known answer vectors")
    out.append("# Generated by calibrate_models.py.  Do not edit by hand.")
    out.append("#")
    out.append("# RO  <dev_id> <env> <challenge> <mask3> <mask2> <mask1> <mask0>"
               " <resp1> <resp0>")
    out.append("#     the mask word is split into four 64-bit chunks, the")
    out.append("#     response word into two, the chunks run from the top down.")
    out.append("# ARB <dev_id> <env> <seed> <resp1> <resp0>")
    out.append("# SYN <word1> <word0> <syndrome>")
    out.append("#     the BCH(127,64,21) syndrome of a 127-bit word.")
    out.append("")
    ro_cases = [
        (0x0000_0001, 0, 0),
        (0x0000_0001, 1, 0),
        (0x0000_0001, 0, 137),
        (0x0000_0001, 3, 511),
        (0x0000_00A5, 0, 42),
        (0xDEAD_BEEF, 0, 256),
        (0xDEAD_BEEF, 2, 99),
        (0x1234_5678, 0, 7),
    ]
    for dev, env, chal in ro_cases:
        bits, mask = ro_response(dev, env, chal)
        mask_word = mask_to_word(mask)
        resp_word = bits_to_word(bits)
        mc = chunk(mask_word, 254)
        rc = chunk(resp_word, 127)
        out.append("RO %08x %d %d %s %s" %
                   (dev, env, chal, " ".join(mc), " ".join(rc)))
    out.append("")
    arb_cases = [
        (0x0000_0001, 0, 0x0000_0000_0000_0001),
        (0x0000_0001, 0, 0x1234_5678_9ABC_DEF0),
        (0x0000_0001, 1, 0x0000_0000_0000_0001),
        (0xDEAD_BEEF, 0, 0xCAFEBABE_12345678),
        (0xDEAD_BEEF, 3, 0x0F0F0F0F_F0F0F0F0),
    ]
    for dev, env, seed in arb_cases:
        bits = arb_bits(dev, env, seed)
        rc = chunk(bits_to_word(bits), 64)
        out.append("ARB %08x %d %016x %s" % (dev, env, seed, " ".join(rc)))
    out.append("")
    syn_words = [
        0,
        (1 << 126),
        (1 << 126) | 1,
        0x0123_4567_89AB_CDEF_FEDC_BA98_7654_3210_0FED_CBA9_8765_4321 & ((1 << 127) - 1),
        0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF & ((1 << 127) - 1),
    ]
    for w in syn_words:
        wc = chunk(w, 127)
        sc = "%016x" % (bch_syndrome(w) & MASK63)
        out.append("SYN %s %s" % (" ".join(wc), sc))
    return out


def cmd_kat():
    path = os.path.join(HERE, "kat_vectors.txt")
    with open(path, "w") as f:
        f.write("\n".join(kat_lines()) + "\n")
    print("wrote %s" % path)


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "measure"
    if what == "sweep":
        cmd_sweep()
    elif what == "measure":
        cmd_measure()
    elif what == "kat":
        cmd_kat()
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
