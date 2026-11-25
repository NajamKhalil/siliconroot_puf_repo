# siliconroot_puf_repo

[![Regression](https://github.com/NajamKhalil/siliconroot_puf_repo/actions/workflows/regression.yml/badge.svg)](https://github.com/NajamKhalil/siliconroot_puf_repo/actions/workflows/regression.yml)

SiliconRoot-PUF is a SystemVerilog core for device authentication and secret-key generation. It combines arbiter and ring-oscillator PUFs, masking, Hamming comparison, BCH(127,64,21) correction, and SHA-256 key derivation. The single command interface supports enrollment, regeneration, authentication, and reference storage, plus verification flows.

## Regression testing

The project has a repeatable, open-source regression suite driven by Python 3, Icarus Verilog and Yosys:

```bash
python3 tools/regression.py --root . --work build/regression
```

It checks KAT reproducibility, lint, simulation, formal-property compilation, synthesis, mutation testing and dashboard generation. The same command runs in GitHub Actions on every push and pull request; see `tools/README.md` and `.github/workflows/regression.yml`.

Detailed results are recorded in `siliconroot_puf/docs/siliconroot_puf_verification.md`.
