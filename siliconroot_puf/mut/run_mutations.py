#!/usr/bin/env python3
"""
Mutation campaign for SiliconRoot-PUF, the PUF-based device authentication IP.

    python run_mutations.py [--work <dir>] [--out <file>]

A testbench that has never failed proves nothing.  This script injects one
deliberate bug at a time into a copy of the delivered RTL, re-runs the whole
testbench against the mutant, and records whether the bench caught it.

The mutations are one-line replacements.  Each entry is

    (id, file, description, the text that is replaced, the text it becomes)

The copy is made into a scratch directory - the delivered RTL is never
modified.  Every mutant is run against the delivered testbench and the
delivered known-answer vectors, so the result describes the code that ships.

The scratch directory is left behind on purpose: it is the evidence, and the
report quotes the first failing line out of each run.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BLOCK = os.path.dirname(HERE)
DEFAULT_WORK = os.path.join(os.environ.get("TEMP", "."), "siliconroot_mut")
DEFAULT_OUT = os.path.join(HERE, "mutation_results.json")

# ---------------------------------------------------------------------------
# The mutants
# ---------------------------------------------------------------------------
MUTANTS = [
    ("M01", "puf_pkg.sv",
     "gf_mul reduces with x^7+x^3+x+1 instead of x^7+x^3+1",
     "      t = 14'h089 << 6;    p = p[13] ? (p ^ t) : p;",
     "      t = 14'h08B << 6;    p = p[13] ? (p ^ t) : p;"),

    ("M02", "puf_pkg.sv",
     "gf_sqr drops the a[6] term of the squared bit 1",
     "      r[1] = a[4] ^ a[6];",
     "      r[1] = a[4];"),

    ("M03", "puf_pkg.sv",
     "the minimal polynomial of cyclotomic class 0 is corrupted",
     "      4'd0: class_mlow = 7'h09;   // m_1(x)  = x^7 + x^3 + 1",
     "      4'd0: class_mlow = 7'h0B;   // m_1(x)  = x^7 + x^3 + 1"),

    ("M04", "puf_pkg.sv",
     "the Chien search multiplier alpha^-1 is wrong",
     "      5'd1 : chien_mul = 7'h44;   // alpha^(-1)",
     "      5'd1 : chien_mul = 7'h45;   // alpha^(-1)"),

    ("M05", "puf_pkg.sv",
     "the first SHA-256 round constant is corrupted",
     "      6'd0 : sha256_k = 32'h428a2f98;  6'd1 : sha256_k = 32'h71374491;",
     "      6'd0 : sha256_k = 32'h428a2f99;  6'd1 : sha256_k = 32'h71374491;"),

    ("M06", "puf_pkg.sv",
     "the first SHA-256 initial hash value is corrupted",
     "      3'd0: sha256_h0 = 32'h6a09e667;",
     "      3'd0: sha256_h0 = 32'h6a09e668;"),

    ("M07", "puf_sha256.sv",
     "the schedule sigma0 shifts by 2 instead of 3",
     "    sha_ssig0 = sha_rotr(x, 6'd7) ^ sha_rotr(x, 6'd18) ^ (x >> 3);",
     "    sha_ssig0 = sha_rotr(x, 6'd7) ^ sha_rotr(x, 6'd18) ^ (x >> 2);"),

    ("M08", "puf_sha256.sv",
     "the round Sigma1 rotates by 24 instead of 25",
     "    sha_sig1 = sha_rotr(x, 6'd6) ^ sha_rotr(x, 6'd11) ^ sha_rotr(x, 6'd25);",
     "    sha_sig1 = sha_rotr(x, 6'd6) ^ sha_rotr(x, 6'd11) ^ sha_rotr(x, 6'd24);"),

    ("M09", "puf_sha256.sv",
     "the message block is loaded little endian instead of big endian",
     "              w_q[k*32 +: 32] = block_i[511 - 32*k -: 32];",
     "              w_q[k*32 +: 32] = block_i[32*k +: 32];"),

    ("M10", "puf_sha256.sv",
     "the hash stops after 62 rounds instead of 64",
     "          if (t_q == 6'd63) begin",
     "          if (t_q == 6'd62) begin"),

    ("M11", "puf_bch_enc.sv",
     "the syndrome is computed from the word least significant bit first",
     "  assign bit_in_c   = word_i[126 - bit_q];",
     "  assign bit_in_c   = word_i[bit_q];"),

    ("M12", "puf_bch_enc.sv",
     "the long division feedback constant is corrupted by one bit",
     "  assign rem_next_c = fb_c ? (rem_shift_c ^ puf_pkg::BCH_GL) : rem_shift_c;",
     "  assign rem_next_c = fb_c ? (rem_shift_c ^ (puf_pkg::BCH_GL ^ 63'd1)) : rem_shift_c;"),

    ("M13", "puf_bch_dec.sv",
     "the decoder no longer fails when the verification pass disagrees",
     "          fail_q      <= (~vchk_ok_c) | (bm_l_q > TOL_L) | (err_cnt_q > TOL_C);",
     "          fail_q      <= (bm_l_q > TOL_L) | (err_cnt_q > TOL_C);"),

    ("M14", "puf_bch_dec.sv",
     "the Chien search records no error positions",
     "      err_next_c[bit_q] = 1'b1;",
     "      err_next_c[bit_q] = 1'b0;"),

    ("M15", "puf_auth.sv",
     "the tolerance is exclusive instead of inclusive",
     "          ok_o   <= (dist_c <= TOL_V);",
     "          ok_o   <= (dist_c < TOL_V);"),

    ("M16", "puf_auth.sv",
     "the differing bits are computed with AND instead of XOR",
     "    diff_c = resp_i ^ ref_i;",
     "    diff_c = resp_i & ref_i;"),

    ("M17", "puf_prng.sv",
     "the LFSR feedback polynomial is x^4+x^3+x^2+1 instead of x^4+x^3+x+1",
     "  localparam logic [63:0] LFSR_POLY = 64'h0000_0000_0000_001B; // x^4 + x^3 + x + 1",
     "  localparam logic [63:0] LFSR_POLY = 64'h0000_0000_0000_001D; // x^4 + x^3 + x + 1"),

    ("M18", "puf_prng.sv",
     "the all zero seed is no longer replaced by one",
     "        state_q <= (seed_vi == 64'd0) ? 64'd1 : seed_vi;",
     "        state_q <= seed_vi;"),

    ("M19", "puf_ro_sensor.sv",
     "the 1-out-of-k mask picks the narrowest candidate instead of the widest",
     "      if (cand_dist_q[k*CNT_W +: CNT_W] > best_d_c) begin",
     "      if (cand_dist_q[k*CNT_W +: CNT_W] < best_d_c) begin"),

    ("M20", "puf_ro_sensor.sv",
     "the challenge rotation is off by one pair",
     "  assign pair_base_c = (32'(bit_q) * 32'(K_MASK)) + 32'(cand_q);",
     "  assign pair_base_c = (32'(bit_q) * 32'(K_MASK)) + 32'(cand_q) + 32'd1;"),

    ("M21", "puf_key_gen.sv",
     "the SHA-256 padding loses its mandatory one bit",
     "    blk_c[PAD_BIT]    = 1'b1;",
     "    blk_c[PAD_BIT]    = 1'b0;"),

    ("M22", "puf_key_gen.sv",
     "the hashed message length field is off by one",
     "    blk_c[63:0]       = 64'(RESP_BITS);",
     "    blk_c[63:0]       = 64'(RESP_BITS) + 64'd1;"),

    ("M23", "siliconroot_puf.sv",
     "the authentication challenge is ignored and the rotation is zero",
     "              CMD_RO_AUTH: begin\n"
     "                ro_derive_q <= 1'b0;\n"
     "                ro_chal_q   <= arg_i[CHAL_W-1:0];",
     "              CMD_RO_AUTH: begin\n"
     "                ro_derive_q <= 1'b0;\n"
     "                ro_chal_q   <= '0;"),

    ("M24", "siliconroot_puf.sv",
     "an unknown command reports the decode-failed status instead of the bad "
     "command status",
     "                status_o <= 4'd2;",
     "                status_o <= 4'd1;"),

    ("M25", "puf_pkg.sv",
     "the live reduction step of gf_mul folds with the wrong polynomial",
     "      t = 14'h089 << 5;    p = p[12] ? (p ^ t) : p;",
     "      t = 14'h08B << 5;    p = p[12] ? (p ^ t) : p;"),

    ("M26", "puf_arbiter_macro.sv",
     "the prefix parity of the delay chain never toggles",
     "          par_q <= par_q ^ x_q[stg_q];",
     "          par_q <= par_q;"),

    ("M27", "siliconroot_puf.sv",
     "the block never asserts cmd_ready_o while it is idle",
     "        S_IDLE: begin\n"
     "          cmd_ready_o <= 1'b1;\n"
     "          if (cmd_valid_i) begin",
     "        S_IDLE: begin\n"
     "          cmd_ready_o <= 1'b0;\n"
     "          if (cmd_valid_i) begin"),

    ("M28", "puf_arbiter_macro.sv",
     "the arbiter verdict is inverted",
     "          y_q     <= (acc_q < 0);",
     "          y_q     <= (acc_q > 0);"),

    ("M29", "puf_key_gen.sv",
     "the stored syndrome is not differenced out of the fresh one",
     "              diff_q <= enc_synd_c ^ synd_i;",
     "              diff_q <= enc_synd_c;"),
]

RE_MISMATCH = re.compile(r"^MISMATCH\s+(.*)$", re.M)
RE_RESULT = re.compile(r"^RESULT\s*=\s*(\w+)", re.M)
RE_MM = re.compile(r"^MISS MATCH COUNTER\s*=\s*(\d+)", re.M)
RE_FIN = re.compile(r"\$finish called at (\d+)", re.M)


def run(cmd, cwd):
    """Run a command and return (rc, combined output)."""
    p = subprocess.run(cmd, cwd=cwd, shell=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def prepare(work):
    """A pristine copy of the RTL and of the testbench."""
    base = os.path.join(work, "base")
    if os.path.isdir(base):
        shutil.rmtree(base)
    os.makedirs(base)
    shutil.copytree(os.path.join(BLOCK, "rtl"), os.path.join(base, "rtl"))
    os.makedirs(os.path.join(base, "sim"))
    for f in ("tb_siliconroot_puf.sv", "kat_vectors.txt", "f_list.f"):
        shutil.copy2(os.path.join(BLOCK, "sim", f), os.path.join(base, "sim", f))
    return base


def apply_mutant(base, m):
    """Copy the pristine tree and patch one file. Returns the run directory."""
    mid, rtl_file, _desc, old, new = m
    run_dir = os.path.join(os.path.dirname(base), "run_" + mid)
    if os.path.isdir(run_dir):
        shutil.rmtree(run_dir)
    shutil.copytree(base, run_dir)
    path = os.path.join(run_dir, "rtl", rtl_file)
    # The anchors are written with plain newlines; the sources on this host
    # carry CRLF, so the file is normalised for the search and put back the
    # way it was found.
    with open(path, "rb") as f:
        text = f.read().decode("utf-8")
    crlf = "\r\n" in text
    norm = text.replace("\r\n", "\n")
    if norm.count(old) != 1:
        raise RuntimeError("%s: the anchor text is not unique (%d hits)"
                           % (mid, norm.count(old)))
    norm = norm.replace(old, new)
    if crlf:
        norm = norm.replace("\n", "\r\n")
    with open(path, "wb") as f:
        f.write(norm.encode("utf-8"))
    return run_dir


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=DEFAULT_WORK)
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    work = os.path.abspath(args.work)
    if os.path.isdir(work):
        shutil.rmtree(work)
    os.makedirs(work)

    base = prepare(work)
    results = []
    t0 = time.time()

    for m in MUTANTS:
        mid = m[0]
        try:
            run_dir = apply_mutant(base, m)
        except RuntimeError as e:
            results.append({"id": mid, "desc": m[2], "file": m[1],
                            "status": "BROKEN", "detail": str(e)})
            print("%s  BROKEN  %s" % (mid, e))
            continue

        sim = os.path.join(run_dir, "sim")
        rc, out = run("iverilog -s tb_siliconroot_puf -g2012 -f f_list.f "
                      "-o my_sim_exe tb_siliconroot_puf.sv", sim)
        if rc != 0:
            results.append({"id": mid, "desc": m[2], "file": m[1],
                            "status": "BUILD", "detail": out.strip()[-400:]})
            print("%s  BUILD FAILED" % mid)
            continue

        rc, out = run("vvp my_sim_exe", sim)
        mism = RE_MISMATCH.findall(out)
        res = RE_RESULT.findall(out)
        mm = RE_MM.findall(out)
        fin = RE_FIN.findall(out)
        verdict = res[-1] if res else "NO-VERDICT"
        nmm = int(mm[-1]) if mm else -1
        status = "KILLED" if verdict == "FAIL" else "SURVIVED"
        detail = mism[0].strip() if mism else ""
        results.append({
            "id": mid, "desc": m[2], "file": m[1], "status": status,
            "first_failure": detail, "verdict": verdict,
            "mismatches": nmm, "finish_ps": int(fin[-1]) if fin else 0,
        })
        print("%s  %-8s  %s" % (mid, status, detail[:96]))

    wall = time.time() - t0
    killed = sum(1 for r in results if r["status"] == "KILLED")
    summary = {"mutants": len(results), "killed": killed,
               "survived": len(results) - killed, "wall_seconds": round(wall, 1),
               "results": results}
    with open(args.out, "w", newline="") as f:
        json.dump(summary, f, indent=2)
    print("\n%d mutants, %d killed, %d survived, %.1f s"
          % (summary["mutants"], killed, summary["survived"], wall))
    return 0


if __name__ == "__main__":
    sys.exit(main())
