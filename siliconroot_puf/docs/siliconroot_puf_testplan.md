# SiliconRoot-PUF - Test Plan

| | |
|---|---|
| Project | SiliconRoot-PUF |
| Scope | RTL self-check, lint, synthesis, mutation and property compilation |
| Owner | Najam Khalil |
| Evidence | `sim/sim.log`, `lint/lint.log`, `synth/synth.log`, `mut/mutation_results.json` |

## 1. Objective

The test plan answers one question: does the delivered RTL match the model, the interface contract and the datapath contracts that the design specification claims? Every case below is executed by `sim/tb_siliconroot_puf.sv` or by a documented tool flow. Results go into `siliconroot_puf_verification.md`; this document records intent only.

## 2. Stimulus model

Three independent stimulus sources are used. Known-answer vectors come from `sim/calibrate_models.py` and are read from `sim/kat_vectors.txt`, so the Python twin and the RTL meet only at those vectors. Direct leaf-block tasks drive SHA-256, PRNG, BCH and the comparator one at a time. End-to-end tasks drive the single command port and observe `done_o`, `err_o` and `status_o` over the request-style handshake.

## 3. Cases

| ID | Objective | Stimulus | Gate | Status |
|---|---|---|---|---|
| TC-01 | Known-answer vectors load correctly | 8 RO, 5 arbiter, 5 syndrome records | record counts | DONE |
| TC-02 | The field product is exact | all 128 x 128 operand pairs | exhaustive model comparison | DONE |
| TC-03 | SHA-256 matches FIPS 180-4 golden digests | `abc` and empty-message blocks | golden digest comparison | DONE |
| TC-04 | PRNG advances and rejects a zero seed | loaded seeds, stepped states | model state comparison | DONE |
| TC-05 | BCH encoder produces the model syndrome | 5 syndrome words | encoder versus model | DONE |
| TC-06 | BCH decoder corrects and refuses | correctable and eleven-error patterns | output, error count, fail flag | DONE |
| TC-07 | Authentication tolerance is inclusive | distances at, inside and outside tolerance | verdict comparison | DONE |
| TC-08 | RO response, mask, syndrome and key are repeatable | 8 RO KAT cases | vector and derived-key comparison | DONE |
| TC-09 | Arbiter response matches the model | 5 arbiter KAT cases | vector comparison | DONE |
| TC-10 | Command decode and status are correct | legal and illegal commands | port observation | DONE |
| TC-11 | Enrolment and regeneration recover the key | enrol, then regenerate | key, response and syndrome equality | DONE |
| TC-12 | End-to-end authentication succeeds | arbiter and RO reference flows | verdict and distance | DONE |
| TC-13 | Environment drift and device mismatch are handled | drifted and foreign device IDs | accept and reject verdicts | DONE |
| TC-14 | Repeated measurements are stable | repeated RO measurement | response and mask equality | DONE |
| TC-15 | The handshake never violates its contract | every clock of every test | three-rule monitor | DONE |
| TC-16 | Lint is clean with and without `RTL_SIM` | both file lists | `iverilog -Wall -g2012` | DONE |
| TC-17 | The design elaborates and checks cleanly | twelve RTL sources in dependency order | `yosys check` | DONE |
| TC-18 | The testbench detects injected faults | 29 one-line RTL mutants | mutation campaign | DONE |

## 4. Exit criteria

A case passes only when its check prints no `MISMATCH` line and the run ends with `RESULT = PASS`. A tool gate passes only when the command exits zero and its report contains the expected success line. A mutant is killed only when the run reports `RESULT = FAIL`; a survivor is recorded as an open coverage item rather than silently dropped.
