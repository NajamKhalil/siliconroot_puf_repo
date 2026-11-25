# SiliconRoot-PUF - Verification Report

| | |
|---|---|
| Project | SiliconRoot-PUF |
| Scope | Results of the cases in `siliconroot_puf_testplan.md` |
| Toolchain | Icarus Verilog 12.0, yowasp-yosys 0.71, Python 3.12 |
| Status | Executable checks pass; gaps are listed in section 7 |

## 1. Summary

The delivered design was compiled, simulated, linted, synthesised and mutation-tested from a clean checkout of `main`. The self-checking testbench performed 176 checks with 0 functional mismatches and 0 handshake violations over 54501 handshake observations. Both lint configurations exited with 0 errors. Synthesis elaborated the full hierarchy and `yosys check` reported 0 problems with no latches inferred. The mutation campaign killed all 29 injected faults. Regenerating `kat_vectors.txt` from `calibrate_models.py` reproduced the committed file byte for byte.

## 2. Simulation results

| ID | Result | Evidence | Status |
|---|---|---|---|
| TC-01 | 8 RO, 5 arbiter and 5 syndrome vectors loaded | `sim/sim.log` | PASS |
| TC-02 | all 128 x 128 field products agree | `sim/sim.log` | PASS |
| TC-03 | golden and RTL SHA-256 digests agree | `sim/sim.log` | PASS |
| TC-04 | PRNG steps and zero-seed replacement agree | `sim/sim.log` | PASS |
| TC-05 | encoder syndromes agree for all vectors | `sim/sim.log` | PASS |
| TC-06 | correctable words decode; eleven errors are flagged | `sim/sim.log` | PASS |
| TC-07 | tolerance boundary verdicts agree | `sim/sim.log` | PASS |
| TC-08 | RO response, mask, syndrome and key agree | `sim/sim.log` | PASS |
| TC-09 | arbiter responses agree | `sim/sim.log` | PASS |
| TC-10 | legal and illegal commands set the expected status | `sim/sim.log` | PASS |
| TC-11 | regenerated key, response and syndrome match enrolment | `sim/sim.log` | PASS |
| TC-12 | arbiter and RO authentication both succeed | `sim/sim.log` | PASS |
| TC-13 | drifted device accepts; foreign device rejects | `sim/sim.log` | PASS |
| TC-14 | repeated RO measurement is stable | `sim/sim.log` | PASS |
| TC-15 | 54501 observations, 0 handshake violations | `sim/sim.log` | PASS |
| TC-16 | both lint configurations exited 0 | `lint/lint.log`, `lint/lint_no_rtl_sim.log` | PASS |
| TC-17 | hierarchy check reported 0 problems | `synth/synth.log` | PASS |
| TC-18 | all 29 injected faults were detected | `mut/mutation_results.json` | PASS |
| TC-19 | all seven regression stages passed from a clean copy | `regression_summary.json` | PASS |

Measured longest command latencies are 1 cycle for control operations and reference stores, 4293 cycles for an arbiter response, 4296 cycles for arbiter authentication, 1348 cycles for RO enrolment, 801 cycles for RO regeneration and 263 cycles for RO authentication.

## 3. Lint results

`iverilog -Wall -g2012 -f lint/f_list.f` and the same command with `lint/f_list_no_def.f` both exited 0. The transcripts record `0 errors`. No warning was reported by either configuration during the audit run.

## 4. Synthesis results

`yowasp-yosys -s synth/synth.ys -l synth/synth.log` exited 0. The twelve RTL sources were read in dependency order, `hierarchy -top siliconroot_puf -check` selected a single top, `check` reported `Found and reported 0 problems.`, and the `PROC_DLATCH` pass inferred no latches. The generated netlist declares `module siliconroot_puf` and is written to `synth/siliconroot_puf_netlist.v`.

## 5. Mutation results

`mut/run_mutations.py` was run with Icarus Verilog on `PATH`. All 29 mutants were killed in 152.9 seconds: 29 killed, 0 survived. The earlier single survivor came from an unreachable reduction of bit 13 in a 7-bit by 7-bit carry-less product, so that mutant was replaced with a reachable bit-11 fold. An exhaustive `gf_mul` comparison was added to the testbench and now catches both corrupted-fold mutants.

## 6. Formal properties

`fpv/siliconroot_puf_fpv.sv` compiles under Icarus 12.0 with `+define+INCLUDE_FPV` for all three property modules: `puf_top_props`, `puf_auth_props` and `puf_bch_dec_props`. Icarus emits synthesis-only warnings for the implicit `$error` calls behind immediate assertions; these do not affect simulation. The properties are not instantiated by the delivered RTL and no proof harness or `.sby` file is shipped, so no formal proof is claimed.

## 7. Repeatable regression suite

The executable checks above are collected in `tools/regression.py`, a
standard-library-only Python runner that uses Icarus Verilog and Yosys. It
copies the tree into a disposable work directory, runs the seven stages
(`kat`, `lint`, `sim`, `fpv`, `synth`, `mutation`, `monitor`), writes raw logs
plus `regression_summary.json`, and exits non-zero if any gate fails:

```bash
python3 tools/regression.py --root . --work build/regression
```

`.github/workflows/regression.yml` runs that command on every push and pull
request using Ubuntu's open-source `iverilog` and `yosys` packages and uploads
the work directory as the `regression-report` artifact. The local full run
passed all seven stages in 177.6 s: synthesis took 60.3 s and the mutation
campaign 112.2 s.

## 8. Limitations

These are declared scope limits, not executable failures. The two PUF macros are calibrated functional twins, not silicon measurements. The RO challenge space is 512 rotations rather than the paper's exponential subset space. References are held on chip and the mask uses `k = 4`. CDC is inapplicable because the block has one clock and one asynchronous reset; the review is recorded in `cdc/cdc.rpt`. No place-and-route, static timing analysis, gate-level simulation or Fmax figure exists. Formal properties were written and syntax-checked but not proven. Physical attacks and side-channel resistance were not evaluated.
