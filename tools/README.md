# Regression tools

`regression.py` is the repeatable, open-source regression gate for SiliconRoot-PUF.
It uses only Python 3, Icarus Verilog (`iverilog`/`vvp`) and Yosys
(`yowasp-yosys` or `yosys`). No ModelSim, commercial licence or network access
is needed.

## Run everything

```bash
python3 tools/regression.py --root . --work build/regression
```

The command exits 0 only when every stage passes. Raw logs and a machine-readable
`regression_summary.json` are written under the `--work` directory. If `--work`
is omitted, a temporary directory is used and removed on exit (use `--keep`
to retain it).

## Stages

| Stage | What it proves |
|---|---|
| `kat` | `calibrate_models.py kat` reproduces the committed known-answer vectors byte for byte. |
| `lint` | Both Icarus `-Wall -g2012` file lists compile cleanly. |
| `sim` | The self-checking testbench passes with zero mismatches and zero handshake violations. |
| `fpv` | All three `INCLUDE_FPV` property modules compile under Icarus. |
| `synth` | Yosys elaborates the hierarchy, reports zero problems, infers no latches and writes a netlist containing the top module. |
| `mutation` | All 29 one-line RTL faults are detected by the testbench. |
| `monitor` | The RTL dashboard is generated as an informational artifact. |

Run a subset while debugging:

```bash
python3 tools/regression.py --only kat,lint,sim
```

## Tool discovery

The suite looks for `iverilog`, `vvp`, `yowasp-yosys` and `yosys` on `PATH`.
Overrides are available through `IVERILOG`, `VVP` and `YOSYS`, for example:

```bash
YOSYS=yosys python3 tools/regression.py --root . --work build/regression
```

On Windows the script also checks the usual `C:\iverilog\bin` Icarus location
and the Python `Scripts` directory next to the interpreter for `yowasp-yosys`.

## CI

`.github/workflows/regression.yml` runs the full suite on every push and pull
request using Ubuntu's open-source `iverilog` and `yosys` packages, then uploads
the work directory as the `regression-report` artifact.
