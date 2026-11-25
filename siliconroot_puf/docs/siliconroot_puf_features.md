# SiliconRoot-PUF - Feature Checklist

| | |
|---|---|
| Project | SiliconRoot-PUF |
| Basis | `siliconroot_puf_design_spec.md` sections 2 to 13 |
| Note | N/A marks work that is deliberately outside this RTL deliverable |

## 1. Scope

This checklist separates features implemented in the delivered RTL from items that belong to a future silicon integration. Every implemented item has executable evidence in `siliconroot_puf_verification.md`.

## 2. Implemented features

| ID | Feature | Status | Evidence |
|---|---|---|---|
| F01 | 64-bit arbiter PUF response from a seeded LFSR | DONE | TC-04, TC-09 |
| F02 | 127-bit ring-oscillator PUF response | DONE | TC-08 |
| F03 | 1-out-of-4 mask selection with challenge rotation | DONE | TC-08 |
| F04 | Hamming-distance authentication with configurable tolerance | DONE | TC-07, TC-12 |
| F05 | BCH(127,64,21) syndrome generation and correction | DONE | TC-05, TC-06 |
| F06 | SHA-256 derivation of a 256-bit key | DONE | TC-03, TC-11 |
| F07 | Single request-style command interface with eight commands | DONE | TC-10 |
| F08 | Valid/ready handshake, one-cycle done pulse and status reporting | DONE | TC-15 |
| F09 | Self-checking testbench with golden models and known answers | DONE | TC-01 to TC-14 |
| F10 | Clean lint in both `RTL_SIM` configurations | DONE | TC-16 |
| F11 | Clean synthesis of the full hierarchy | DONE | TC-17 |
| F12 | Mutation campaign with complete fault detection | DONE | TC-18 |
| F13 | Fabricated analog PUF macros and device-specific silicon data | N/A | future silicon integration |
