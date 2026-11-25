#!/usr/bin/env python3
"""Repeatable open-source regression suite for SiliconRoot-PUF.

The suite runs every check the project claims, from a disposable copy of the
tree, using only Python 3, Icarus Verilog and Yosys:

    python3 tools/regression.py --root . --work build/regression

Stages:

    kat       regenerate kat_vectors.txt and compare it byte for byte
    lint      compile both Icarus -Wall file lists
    sim       run the self-checking testbench and check its report
    fpv       compile all three INCLUDE_FPV property modules
    synth     run the Yosys flow and check the netlist/check report
    mutation  run all 29 mutants and require every one to be killed
    monitor   generate the RTL dashboard as an informational artifact

Every stage writes its raw output under <work>/logs. A zero exit means every
selected stage passed. Nothing in the delivered tree is modified.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

STAGES = ("kat", "lint", "sim", "fpv", "synth", "mutation", "monitor")

RE_RESULT = re.compile(r"^RESULT\s*=\s*(\w+)", re.M)
RE_MISS = re.compile(r"^MISS MATCH COUNTER\s*=\s*(\d+)", re.M)
RE_CHECK = re.compile(r"^\s*checks performed\s*=\s*(\d+)", re.M)
RE_BAD = re.compile(r"^\s*checks mismatched\s*=\s*(\d+)", re.M)
RE_OBS = re.compile(r"^\s*handshake observations\s*=\s*(\d+)", re.M)
RE_HSERR = re.compile(r"^\s*handshake violations\s*=\s*(\d+)", re.M)
RE_ERROR = re.compile(r"(?im)(?:^|\s)error:", re.M)
RE_LATCH = re.compile(r"(?m)^\s*Latch inferred\b", re.M)
RE_GATES = re.compile(r"(\d+)/(\d+) gates")


class RegressionError(Exception):
    """A stage produced a result that does not meet its gate."""


class Context:
    def __init__(self, root, work, env, tools, python):
        self.root = root
        self.block_src = root / "siliconroot_puf"
        self.work = work
        self.block = work / "block"
        self.env = env
        self.tools = tools
        self.python = python


def write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tail(text, n=10):
    lines = [ln for ln in (text or "").strip().splitlines() if ln.strip()]
    return "\n".join(lines[-n:]) or "(no output)"


def last(pattern, text, default=None):
    found = pattern.findall(text)
    return found[-1] if found else default


def find_tool(name, env_name, extras=()):
    override = os.environ.get(env_name)
    if override:
        p = Path(override)
        if p.is_file():
            return p.resolve()
        found = shutil.which(override)
        if found:
            return Path(found).resolve()
    found = shutil.which(name)
    if found:
        return Path(found).resolve()
    for extra in extras:
        p = Path(extra)
        if p.is_file():
            return p.resolve()
    return None


def discover_tools():
    scripts = Path(sys.executable).resolve().parent / "Scripts"
    iverilog = find_tool("iverilog", "IVERILOG",
                         (r"C:\iverilog\bin\iverilog.exe",))
    vvp = find_tool("vvp", "VVP", (r"C:\iverilog\bin\vvp.exe",))
    yosys = find_tool("yowasp-yosys", "YOSYS",
                      (scripts / "yowasp-yosys.exe", scripts / "yowasp-yosys")) \
        or find_tool("yosys", "YOSYS")
    return {"iverilog": iverilog, "vvp": vvp, "yosys": yosys}


def build_env(tools):
    env = os.environ.copy()
    dirs = []
    for tool in tools.values():
        if tool:
            d = str(tool.parent)
            if d not in dirs:
                dirs.append(d)
    if dirs:
        env["PATH"] = os.pathsep.join(dirs + [env.get("PATH", "")])
    return env


def run(cmd, cwd, env, log=None, check=True):
    printable = " ".join(str(c) for c in cmd)
    p = subprocess.run([str(c) for c in cmd], cwd=str(cwd), env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, errors="replace")
    out = p.stdout or ""
    if log:
        write_text(log, out)
    if check and p.returncode != 0:
        raise RegressionError("%s exited %d\n%s"
                              % (printable, p.returncode, tail(out)))
    return p.returncode, out


def prepare_block(ctx):
    dst = ctx.block
    if dst.exists():
        shutil.rmtree(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(
        ctx.block_src, dst,
        ignore=shutil.ignore_patterns(
            "*.log", "*.vcd", "*.exe", "a.out", "my_sim_exe",
            "__pycache__", "*.pyc", "siliconroot_puf_netlist.v",
            "mutation_results.json", "rtl_dashboard.html"))
    for name in ("logs", "lint", "sim", "fpv", "synth", "mutation", "monitor"):
        (ctx.work / name).mkdir(parents=True, exist_ok=True)


def stage_kat(c):
    sim = c.block / "sim"
    run([c.python, "calibrate_models.py", "kat"], sim, c.env,
        c.work / "logs" / "kat.log")
    generated = sim / "kat_vectors.txt"
    expected = c.block_src / "sim" / "kat_vectors.txt"
    if not generated.is_file():
        raise RegressionError("calibrate_models.py did not write kat_vectors.txt")
    a, b = generated.read_bytes(), expected.read_bytes()
    if a != b:
        raise RegressionError("generated KAT differs from the committed vectors")
    return ("kat_vectors.txt byte-identical (%d bytes, sha256 %s)"
            % (len(b), sha256(expected)[:12]))


def stage_lint(c):
    lint = c.block / "lint"
    for label, flist in (("rtl_sim", "f_list.f"),
                         ("no_define", "f_list_no_def.f")):
        outexe = c.work / "lint" / (label + ".vexe")
        _, out = run([c.tools["iverilog"], "-Wall", "-g2012",
                      "-f", flist, "-o", outexe],
                     lint, c.env, c.work / "logs" / ("lint_" + label + ".log"))
        if RE_ERROR.search(out):
            raise RegressionError("%s reported an error" % flist)
    return "2 configurations, 0 errors"


def stage_sim(c):
    sim = c.block / "sim"
    exe = c.work / "sim" / "tb.vexe"
    run([c.tools["iverilog"], "-s", "tb_siliconroot_puf", "-g2012",
         "-f", "f_list.f", "-o", exe, "tb_siliconroot_puf.sv"],
        sim, c.env, c.work / "logs" / "sim_compile.log")
    _, out = run([c.tools["vvp"], exe, "+kat=kat_vectors.txt"],
                 sim, c.env, c.work / "logs" / "sim.log")

    result = last(RE_RESULT, out)
    miss = last(RE_MISS, out)
    checks = last(RE_CHECK, out)
    bad = last(RE_BAD, out)
    obs = last(RE_OBS, out)
    hserr = last(RE_HSERR, out)
    if result != "PASS":
        raise RegressionError("testbench verdict is %r" % result)
    if None in (miss, checks, bad, obs, hserr):
        raise RegressionError("testbench report is incomplete")
    if int(miss) != 0 or int(bad) != 0 or int(hserr) != 0:
        raise RegressionError("testbench reported a mismatch or handshake fault")
    if int(checks) < 176 or int(obs) <= 0:
        raise RegressionError("testbench coverage shrank: %s checks, %s observations"
                              % (checks, obs))
    return ("%s checks, 0 mismatches, %s handshake observations"
            % (checks, obs))


def stage_fpv(c):
    props = c.block / "fpv" / "siliconroot_puf_fpv.sv"
    for top in ("puf_top_props", "puf_auth_props", "puf_bch_dec_props"):
        exe = c.work / "fpv" / (top + ".vexe")
        run([c.tools["iverilog"], "-g2012", "-D", "INCLUDE_FPV",
             "-s", top, "-o", exe, props],
            c.block, c.env, c.work / "logs" / ("fpv_" + top + ".log"))
    return "3 property modules compiled with INCLUDE_FPV"


def stage_synth(c):
    run([c.tools["yosys"], "-s", "synth/synth.ys",
         "-l", "synth/regression_synth.log"],
        c.block, c.env, c.work / "logs" / "synth_stdout.log")
    log = c.block / "synth" / "regression_synth.log"
    if not log.is_file():
        raise RegressionError("Yosys did not write its log")
    text = log.read_text(encoding="utf-8", errors="replace")
    if "Found and reported 0 problems." not in text:
        raise RegressionError("Yosys check did not report 0 problems")
    if RE_LATCH.search(text):
        raise RegressionError("Yosys inferred a latch")
    netlist = c.block / "synth" / "siliconroot_puf_netlist.v"
    if not netlist.is_file() or netlist.stat().st_size == 0:
        raise RegressionError("netlist was not written")
    if "module siliconroot_puf" not in netlist.read_text(
            encoding="utf-8", errors="replace"):
        raise RegressionError("netlist does not contain the siliconroot_puf top")
    return "check clean, no latches, top module present"


def stage_mutation(c):
    out = c.work / "mutation" / "mutation_results.json"
    run([c.python, c.block / "mut" / "run_mutations.py",
         "--work", c.work / "mutation", "--out", out],
        c.block / "mut", c.env, c.work / "logs" / "mutation.log")
    data = json.loads(out.read_text(encoding="utf-8"))
    total = int(data.get("mutants", 0))
    killed = int(data.get("killed", 0))
    survivors = [r["id"] for r in data.get("results", [])
                 if r.get("status") != "KILLED"]
    if total < 29 or killed != total or survivors:
        raise RegressionError("mutation gate failed: %d/%d killed, survivors=%s"
                              % (killed, total, ",".join(survivors) or "none"))
    return ("%d/%d mutants killed in %.1f s"
            % (killed, total, float(data.get("wall_seconds", 0.0))))


def stage_monitor(c):
    html = c.work / "monitor" / "rtl_dashboard.html"
    run([c.python, c.root / "monitor" / "rtl_monitor.py",
         "--once", "--root", c.root, "--out", html],
        c.root / "monitor", c.env, c.work / "logs" / "monitor.log")
    if not html.is_file():
        raise RegressionError("monitor did not write its dashboard")
    match = RE_GATES.search(html.read_text(encoding="utf-8", errors="replace"))
    detail = "dashboard generated"
    if match:
        detail += " (%s/%s gates green)" % (match.group(1), match.group(2))
    return detail


STAGE_FNS = {
    "kat": stage_kat,
    "lint": stage_lint,
    "sim": stage_sim,
    "fpv": stage_fpv,
    "synth": stage_synth,
    "mutation": stage_mutation,
    "monitor": stage_monitor,
}


def version_line(cmd, env, cwd):
    try:
        _, out = run(cmd, cwd, env, check=False)
        return " ".join(out.splitlines()[0].split()) if out.strip() else "unknown"
    except Exception:
        return "unknown"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".", help="repository root (default: .)")
    ap.add_argument("--work", default=None,
                    help="scratch/artifact directory (default: temporary)")
    ap.add_argument("--only", default=None,
                    help="comma-separated stages, e.g. kat,lint,sim")
    ap.add_argument("--keep", action="store_true",
                    help="keep the temporary work directory")
    args = ap.parse_args(argv)

    if args.only:
        stages = [s.strip() for s in args.only.split(",") if s.strip()]
        bad = [s for s in stages if s not in STAGES]
        if bad:
            ap.error("unknown stage(s): " + ", ".join(bad))
    else:
        stages = list(STAGES)

    root = Path(args.root).resolve()
    if not (root / "siliconroot_puf" / "rtl").is_dir():
        ap.error("not a SiliconRoot-PUF repository: %s" % root)

    created_temp = args.work is None
    work = Path(args.work).resolve() if args.work else \
        Path(tempfile.mkdtemp(prefix="siliconroot_regression_"))
    tools = discover_tools()
    env = build_env(tools)
    ctx = Context(root, work, env, tools, sys.executable)

    needed = set(stages)
    missing = []
    if needed & {"lint", "sim", "fpv", "mutation"} and not tools["iverilog"]:
        missing.append("iverilog (set IVERILOG=...)")
    if "sim" in needed or "mutation" in needed:
        if not tools["vvp"]:
            missing.append("vvp (set VVP=...)")
    if "synth" in needed and not tools["yosys"]:
        missing.append("yowasp-yosys or yosys (set YOSYS=...)")
    if missing:
        print("Missing required open-source tools: " + ", ".join(missing),
              file=sys.stderr)
        return 2

    versions = {
        "python": sys.version.split()[0],
        "iverilog": version_line([tools["iverilog"], "-V"], env, root)
        if tools["iverilog"] else "not installed",
        "yosys": version_line([tools["yosys"], "-V"], env, root)
        if tools["yosys"] else "not installed",
    }

    print("SiliconRoot-PUF regression suite")
    print("root: %s" % root)
    print("work: %s" % work)
    print("tools: Python %s | %s | %s"
          % (versions["python"], versions["iverilog"], versions["yosys"]))
    print("-" * 72)

    prepare_block(ctx)
    results = []
    started = time.time()
    for name in stages:
        t0 = time.time()
        try:
            detail = STAGE_FNS[name](ctx)
            status = "PASS"
        except Exception as e:  # one failed stage must not hide the others
            status = "FAIL"
            detail = str(e)
        elapsed = time.time() - t0
        results.append({"stage": name, "status": status,
                        "detail": detail, "seconds": round(elapsed, 1)})
        print("[%s] %-9s %s (%.1fs)" % (status, name, detail, elapsed))

    ok = all(r["status"] == "PASS" for r in results)
    summary = {
        "project": "SiliconRoot-PUF",
        "result": "PASS" if ok else "FAIL",
        "root": str(root),
        "work": str(work),
        "versions": versions,
        "tool_paths": {k: str(v) if v else None for k, v in tools.items()},
        "seconds": round(time.time() - started, 1),
        "stages": results,
    }
    write_text(work / "regression_summary.json",
               json.dumps(summary, indent=2) + "\n")
    print("-" * 72)
    print("RESULT = %s (%d/%d stages passed, %.1fs)"
          % (summary["result"], sum(1 for r in results if r["status"] == "PASS"),
             len(results), summary["seconds"]))
    if created_temp and not args.keep:
        shutil.rmtree(work, ignore_errors=True)
        print("temporary work directory removed (use --keep to retain it)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
