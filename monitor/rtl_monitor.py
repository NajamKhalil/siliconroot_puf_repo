#!/usr/bin/env python3
"""
RTL quality-gate monitor - zero-server edition.

Scans a tree of RTL blocks, evaluates the PART 3 quality gates for each one,
and writes a self-contained HTML dashboard with the data baked in. The page
refreshes itself, so no web server and no network are involved: open the
generated file directly with file://.

    python3 rtl_monitor.py --watch            # regenerate every 2s
    python3 rtl_monitor.py --once             # generate once and exit
    python3 rtl_monitor.py --root <dir>       # point at a different tree

A block is any directory containing an `rtl/` subdirectory.

The page shows three levels of detail. A project header with one progress bar
for the whole build and a strip of counters. A matrix with one row and one
progress bar per block. And, under each block, a details drawer listing every
gate's evidence file and every file the flow has generated, with the gates
that currently verify it.

Gate evaluation is deliberately conservative: a gate is only GREEN when a
report exists, says it passed, AND is newer than every RTL source file in the
block. A report older than the RTL is reported STALE, because a green tick
taken from a run that predates the current code is worse than no tick at all.
Progress counts green gates only. FAIL, STALE, WARN and never-run all score
zero, so the bar can never read higher than the evidence justifies.
"""
import argparse
import html
import json
import os
import re
import sys
import time
from datetime import datetime

# --------------------------------------------------------------------------
# Where each gate looks for evidence. Adjust these to match your own flow -
# they are the only part of this script that is project-specific.
# --------------------------------------------------------------------------
GATES = {
    "SIM": {
        "globs": ["sim/sim.log", "vcsmx/sim.log", "sim/transcript",
                  "sim/*.log", "vcsmx/*.log"],
        "pass": [r"^RESULT\s*=\s*PASS\b"],
        "fail": [r"^RESULT\s*=\s*FAIL\b", r"COMPILE FAILED",
                 r"^(ERROR|Error|Fatal|UVM_ERROR|UVM_FATAL)"],
        "warn": [r"^RESULT\s*=\s*INCOMPLETE\b"],
    },
    "LINT": {
        "globs": ["lint/*.log", "lint/*.rpt", "synth/lint*.log", "synth/lint*.rpt"],
        "pass": [r"(?i)\b0\s+error", r"(?i)lint\s*:\s*clean"],
        "fail": [r"(?i)inferred\s+latch", r"(?i)combinational\s+loop",
                 r"(?i)multiple\s+driver", r"(?i)width\s+mismatch",
                 r"(?i)^\s*Error"],
        "warn": [r"(?i)^\s*Warning"],
    },
    "SYNTH": {
        "globs": ["synth/*.log", "synth/*.rpt", "synth/**/*.rpt"],
        # Customised to the attached tool (evidence contract, part 9): the
        # third pattern is yosys `check`'s own success line, which is what
        # `yowasp-yosys -s synth/synth.ys -l synth/synth.log` prints for a
        # clean design ("Found and reported 0 problems.").
        "pass": [r"(?i)0\s+errors?\b", r"(?i)synthesis\s+(was\s+)?successful",
                 r"(?i)found\s+and\s+reported\s+0\s+problems"],
        "fail": [r"(?i)inferred\s+latch", r"(?i)combinational\s+loop",
                 r"(?i)black\s*box", r"(?i)^\s*Error"],
        "warn": [r"(?i)^\s*(Critical\s+)?Warning"],
    },
    "CDC": {
        "globs": ["cdc/*.rpt", "cdc/*.log", "synth/cdc*.rpt", "fpv/cdc*.rpt"],
        "pass": [r"(?i)0\s+violations?", r"(?i)cdc\s*:\s*clean"],
        "fail": [r"(?i)unsynchron", r"(?i)\bviolation", r"(?i)missing\s+synchronizer"],
        "warn": [r"(?i)\bcaution\b", r"(?i)\bwaive"],
    },
    "TIMING": {
        "globs": ["synth/*timing*.rpt", "synth/*sta*.rpt", "synth/*.sta.rpt",
                  "sta/*.rpt", "synth/*.log"],
        "pass": [],      # decided numerically below, not by keyword
        "fail": [],
        "warn": [],
    },
}

# Numeric extraction for the timing gate.
# The filler between the keyword and the number must not swallow a leading
# minus sign, or negative slack silently reads as positive.
RE_WNS = re.compile(
    r"(?i)\b(?:WNS|worst\s+(?:negative\s+)?slack)\b[^\d\n-]{0,20}(-?\d+\.?\d*)")
RE_TNS = re.compile(
    r"(?i)\b(?:TNS|total\s+negative\s+slack)\b[^\d\n-]{0,20}(-?\d+\.?\d*)")
RE_FMAX = re.compile(r"(?i)\b(?:restricted\s+)?fmax\b[^\d\n-]{0,20}(\d+\.?\d*)")

RTL_EXT = (".sv", ".svh", ".v", ".vh")
TEXT_EXT = RTL_EXT + (".f", ".sh", ".tcl", ".do", ".py", ".md", ".txt",
                      ".log", ".rpt", ".csv", ".json", ".xml", ".cfg")
SKIP_DIRS = ("__pycache__", ".git", "csrc", "simv.daidir", ".svn")
SKIP_FILES = ("ucli.key", "vc_hdrs.h", "novas.conf", "novas.rc", ".vcs_lock")

# --------------------------------------------------------------------------
# AI SPEND LEDGER. The monitor never calls a billing API and never touches the
# network. It reads an append-only JSONL file that whoever ran the model
# wrote - one JSON object per line, every field except "ts" optional:
#
#   {"ts":"2026-09-22T03:40:00","task":"tlp_fifos review","block":"tlp_fifos",
#    "model":"some-model-v2","in":18432,"out":2310,"cost":0.42}
#
# "in"/"out" are prompt/completion tokens, "cost" is real money if the tool
# reported it. Append with --log-usage rather than editing the file by hand.
# --------------------------------------------------------------------------
USAGE_GLOBS = ("monitor/usage.jsonl", "usage.jsonl", "../monitor/usage.jsonl")

# Fallback price list, USD per MILLION tokens, used ONLY for records that
# carry tokens but no "cost". EDIT THIS to match what you are actually
# billed. Leaving a model out is the safe choice: its tokens are still
# counted and the run is reported as unpriced. A wrong rate here is worse
# than no rate, because a derived number reads on the page as a measured one.
RATES = {
    # "model-name": (usd_per_mtok_in, usd_per_mtok_out),
}

# --------------------------------------------------------------------------
# The three-document model of PART 7. All three must exist for DOCS to go
# green, and each must be newer than the RTL it describes.
# --------------------------------------------------------------------------
DOC_SPECS = (
    ("design spec",         ("docs/*design_spec*.md", "docs/*design-spec*.md",
                             "docs/*_spec.md")),
    ("test plan",           ("docs/*testplan*.md", "docs/*test_plan*.md")),
    ("verification report", ("docs/*verification*.md", "docs/*verif*.md")),
)
PLAN_GLOBS = ("docs/*testplan*.md", "docs/*test_plan*.md")
REPORT_GLOBS = ("docs/*verification*.md", "docs/*verif*.md")
FEATURE_GLOBS = ("docs/*feature*.md", "docs/*requirement*.md",
                 "FEATURES.md", "REQUIREMENTS.md")

# The working agreement (PART 0 SECTION B step 3) reports every item as one of
# DONE / PARTIAL / MISSING / BLOCKED / NOT RUN. KILLED and SURVIVED are the
# mutation-campaign equivalents from PART 5 and PART 7.
STATUS_WORDS = (
    ("DONE", "ok"), ("PASS", "ok"), ("PASSED", "ok"), ("KILLED", "ok"),
    ("COMPLETE", "ok"), ("COMPLETED", "ok"), ("VERIFIED", "ok"),
    ("CLOSED", "ok"),
    ("PARTIAL", "warn"), ("WIP", "warn"), ("IN PROGRESS", "warn"),
    ("DEFERRED", "warn"),
    ("FAIL", "bad"), ("FAILED", "bad"), ("MISSING", "bad"),
    ("BLOCKED", "bad"), ("SURVIVED", "bad"), ("BROKEN", "bad"),
    ("NOT RUN", "none"), ("NOT STARTED", "none"), ("TODO", "none"),
    ("PLANNED", "none"), ("PENDING", "none"), ("SKIPPED", "none"),
)
# Items marked this way are dropped from the denominator rather than counted
# against it - a waived item is not outstanding work.
STATUS_EXCLUDE = ("N/A", "NA", "WAIVED", "NOT APPLICABLE", "-")

RE_ITEM_ID = re.compile(r"^([A-Z]{1,3}[-_]?\d{1,3}[a-z]?)\b")
RE_TABLE_SEP = re.compile(r"^:?-{2,}:?$")
RE_H2_NUM = re.compile(r"^##\s+(\d+)")

# Status vocabulary
OK, BAD, WARN, STALE, NONE = "ok", "bad", "warn", "stale", "none"
ORDER = {BAD: 0, STALE: 1, WARN: 2, NONE: 3, OK: 4}

# The two structural columns come first, then the five tool gates, then the
# three deliverable gates. Only the tool gates can verify a source file - RTL
# and TB merely say the file is there, and DOCS/FEAT/TESTS describe the work
# rather than exercise it.
EVIDENCE = ("SIM", "LINT", "SYNTH", "CDC", "TIMING")
PAPER = ("DOCS", "FEAT", "TESTS")
COLS = ("RTL", "TB") + EVIDENCE + PAPER
MAX_FILES = 60          # inventory rows per block before truncating
MAX_ITEMS = 40          # feature / test-case rows per block before truncating


def expand(base, pattern):
    """Tiny glob supporting * and **, returning existing files."""
    import glob
    return [p for p in glob.glob(os.path.join(base, pattern), recursive=True)
            if os.path.isfile(p)]


def newest(paths):
    best, bt = None, -1
    for p in paths:
        try:
            t = os.path.getmtime(p)
        except OSError:
            continue
        if t > bt:
            best, bt = p, t
    return best, bt


def rtl_sources(block):
    out = []
    for sub in ("rtl",):
        d = os.path.join(block, sub)
        if not os.path.isdir(d):
            continue
        for dp, _dn, fns in os.walk(d):
            for fn in fns:
                if fn.endswith(RTL_EXT):
                    p = os.path.join(dp, fn)
                    if os.path.getsize(p) > 0:
                        out.append(p)
    return out


def scan_text(path, limit=4_000_000):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read(limit)
    except OSError:
        return ""


def line_count(path, size):
    if size == 0 or size > 4_000_000 or not path.endswith(TEXT_EXT):
        return None
    n = 0
    try:
        with open(path, "rb") as fh:
            for _ in fh:
                n += 1
    except OSError:
        return None
    return n


def human_size(n):
    if n < 1024:
        return f"{n} B"
    if n < 1024 * 1024:
        return f"{n / 1024:.1f} K"
    return f"{n / 1048576:.1f} M"


def human_age(mtime, now):
    if not mtime:
        return "-"
    d = max(0.0, now - mtime)
    if d < 90:
        return f"{d:.0f}s ago"
    if d < 5400:
        return f"{d / 60:.0f}m ago"
    if d < 172800:
        return f"{d / 3600:.1f}h ago"
    return f"{d / 86400:.1f}d ago"


def find_lines(patterns, lines, skip=()):
    """Count matching lines and keep the first one as quotable evidence.

    `skip` holds line numbers already claimed by the gate's pass patterns. A
    line that says the gate passed is never also counted as a failure line,
    or `0 violations` would trip the `violation` failure keyword.
    """
    n, first, hit = 0, "", set()
    for pat in patterns:
        rx = re.compile(pat)
        for i, ln in enumerate(lines):
            if i not in skip and rx.search(ln):
                n += 1
                hit.add(i)
                if not first:
                    first = ln.strip()[:160]
    return n, first, hit


def unmark(cell):
    """Strip emphasis markers off a table cell.

    Underscores are left alone on purpose: `num_vld` and `always_ff` are
    identifiers, and a table of RTL checks is full of them.
    """
    return re.sub(r"[`*]", "", cell).replace("\\|", "|").strip()


def md_cells(line):
    """Split a table row, honouring the `\\|` escape used inside cells."""
    return [c.strip() for c in re.split(r"(?<!\\)\|", line[1:-1])]


def cell_status(cell):
    """A status only counts when the whole cell IS the status word.

    Requiring the cell to be nothing but the word is what keeps prose out of
    the tally: a requirement whose text happens to mention `RESULT = PASS`
    must not be read as a passing requirement.
    """
    t = unmark(cell).upper()
    t = re.sub(r"\s*[({\[].*$", "", t).strip().rstrip(".")
    if t in STATUS_EXCLUDE:
        return "skip"
    for word, status in STATUS_WORDS:
        if t == word:
            return status
    return None


def md_items(text, src):
    """Table rows carrying an item ID in the first cell: R1, C4, TC-12, M3."""
    out, head = [], ""
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("#"):
            head = s.lstrip("#").strip()
            continue
        if len(s) < 3 or not (s.startswith("|") and s.endswith("|")):
            continue
        cells = md_cells(s)
        if all(RE_TABLE_SEP.match(c) or not c for c in cells):
            continue
        m = RE_ITEM_ID.match(unmark(cells[0]))
        if not m:
            continue
        status = None
        for c in cells[1:]:
            status = cell_status(c)
            if status:
                break
        out.append({"id": m.group(1), "head": head, "src": src,
                    "text": unmark(cells[1])[:130] if len(cells) > 1 else "",
                    "status": status})
    return out


def text_statuses(text, ids):
    """Statuses stated in prose or in a fenced block rather than in a table.

    A mutation campaign prints `KILLED   M1 - ...`, which is a result even
    though it is not a table. Only IDs already named by the plan are looked
    for, and only when the line names exactly one of them, so a line that
    discusses two test cases at once is left alone rather than guessed at.
    """
    out = {}
    if not ids:
        return out
    rx_id = {i: re.compile(r"\b" + re.escape(i) + r"\b") for i in ids}
    rx_st = [(re.compile(r"\b" + w.replace(" ", r"\s+") + r"\b"), s)
             for w, s in STATUS_WORDS]
    for ln in text.splitlines():
        s = ln.strip()
        if not s or s.startswith("|"):
            continue
        hit = [i for i, rx in rx_id.items() if rx.search(s)]
        if len(hit) != 1:
            continue
        for rx, status in rx_st:
            if rx.search(s):
                out.setdefault(hit[0], status)
                break
    return out


def tally(items):
    """Count an item list by status. Unknown and excluded are kept apart."""
    c = {s: 0 for s in ORDER}
    unknown = skipped = 0
    for it in items:
        st = it["status"]
        if st == "skip":
            skipped += 1
        elif st is None:
            unknown += 1
        else:
            c[st] += 1
    counted = len(items) - skipped
    return c, unknown, skipped, counted


def roll_up(counts, unknown, counted, empty_detail):
    """Turn an item tally into one gate status, worst-first."""
    if not counted:
        return NONE, empty_detail
    if counts[BAD]:
        return BAD, f"{counts[BAD]} of {counted} not done"
    if counts[WARN]:
        return WARN, f"{counts[WARN]} of {counted} partial"
    if unknown:
        return WARN, f"{unknown} of {counted} with no status recorded"
    if counts[NONE]:
        return NONE, f"{counts[NONE]} of {counted} not started"
    return OK, f"all {counted} done"


def doc_structure(text):
    """The PART 7 shape rules, checked cheaply. Returns (notes, n_sections)."""
    notes, lines = [], text.splitlines()
    if not lines or not lines[0].startswith("# "):
        notes.append("no H1 on line 1")
    elif " - " not in lines[0]:
        notes.append("H1 is not '# <Name> - <Document Type>'")
    if len(lines) > 1 and lines[1].strip():
        notes.append("line 2 is not blank")
    if len(lines) > 2 and not lines[2].lstrip().startswith("|"):
        notes.append("no masthead table on line 3")
    nums = [int(m.group(1)) for m in
            (RE_H2_NUM.match(l) for l in lines) if m]
    if not nums:
        notes.append("no numbered H2 sections")
    else:
        if nums[0] != 1:
            notes.append(f"first H2 is {nums[0]}., not 1.")
        for a, b in zip(nums, nums[1:]):
            if b < a or b > a + 1:
                notes.append(f"H2 numbering jumps {a}. to {b}.")
                break
    if any(l.startswith("#### ") for l in lines):
        notes.append("H4 or deeper (PART 7 stops at H3)")
    return notes, len(nums)


def eval_docs(block, rtl_mtime):
    """The three-document model: present, well-formed and newer than the RTL."""
    docs, newest_p, newest_t, stale, malformed = [], None, -1, [], []
    seen = set()
    for kind, globs in DOC_SPECS:
        paths = [p for p in sorted(set(sum((expand(block, g) for g in globs), [])))
                 if p not in seen]
        path, mtime = newest([p for p in paths if os.path.getsize(p) > 0])
        entry = {"kind": kind, "rel": None, "lines": None, "mtime": None,
                 "size": 0, "sections": 0, "notes": [], "state": "missing",
                 "scls": NONE}
        if path:
            seen.add(path)
            text = scan_text(path)
            notes, nsec = doc_structure(text)
            entry.update(rel=os.path.relpath(path, block), mtime=mtime,
                         size=os.path.getsize(path),
                         lines=len(text.splitlines()), sections=nsec,
                         notes=notes)
            if notes:
                malformed.append(kind)
                entry.update(state="; ".join(notes), scls=WARN)
            elif rtl_mtime and mtime < rtl_mtime:
                stale.append(kind)
                age = (rtl_mtime - mtime) / 60.0
                entry.update(state=f"RTL changed {age:.0f} min later",
                             scls=STALE)
            else:
                entry.update(state=f"{nsec} numbered section(s)", scls=OK)
            if mtime > newest_t:
                newest_p, newest_t = path, mtime
        docs.append(entry)

    present = [d for d in docs if d["rel"]]
    missing = [d["kind"] for d in docs if not d["rel"]]
    res = {"docs": docs, "n_ok": sum(1 for d in docs if d["scls"] == OK),
           "n_total": len(DOC_SPECS),
           "path": newest_p, "mtime": newest_t if newest_p else None,
           "rel": os.path.relpath(newest_p, block) if newest_p else None,
           "size": os.path.getsize(newest_p) if newest_p else 0,
           "quote": "", "globs": [g for _k, gs in DOC_SPECS for g in gs],
           "ncand": len(present)}
    if not present:
        res.update(status=NONE, detail="no documents")
    elif missing:
        res.update(status=WARN,
                   detail=f"{len(present)}/{len(docs)} present, no "
                          + ", ".join(missing))
    elif stale:
        res.update(status=STALE, detail="older than the RTL: " + ", ".join(stale))
    elif malformed:
        res.update(status=WARN, detail="shape: " + ", ".join(malformed))
    else:
        res.update(status=OK, detail=f"all {len(docs)} present and current")
    return res


def eval_features(block, root):
    """Feature / requirement checklist with a status recorded per item."""
    srcs = sorted(set(sum((expand(block, g) for g in FEATURE_GLOBS), [])))
    scope, base = "block", block
    if not srcs:
        srcs = sorted(set(sum((expand(root, g) for g in
                               ("FEATURES.md", "REQUIREMENTS.md")), [])))
        scope, base = "project", root

    items, path, mtime = [], None, -1
    for p in srcs:
        items += md_items(scan_text(p), os.path.relpath(p, base))
        t = os.path.getmtime(p)
        if t > mtime:
            path, mtime = p, t

    counts, unknown, skipped, counted = tally(items)
    status, detail = roll_up(counts, unknown, counted, "no feature list")
    if items and scope == "project":
        detail += " (project-level list)"
    return {"status": status, "detail": detail, "items": items, "scope": scope,
            "counts": counts, "unknown": unknown, "skipped": skipped,
            "counted": counted, "done": counts[OK],
            "path": path, "mtime": mtime if path else None,
            "rel": os.path.relpath(path, base) if path else None,
            "size": os.path.getsize(path) if path else 0, "quote": "",
            "globs": list(FEATURE_GLOBS), "ncand": len(srcs)}


def eval_tests(block, rtl_mtime):
    """Test cases named by the test plan, with the status the report gives."""
    plans = sorted(set(sum((expand(block, g) for g in PLAN_GLOBS), [])))
    reports = sorted(set(sum((expand(block, g) for g in REPORT_GLOBS), [])))

    planned = []
    for p in plans:
        planned += md_items(scan_text(p), os.path.relpath(p, block))
    # a plan lists each case once; later mentions do not add cases
    seen, cases = set(), []
    for it in planned:
        if it["id"] not in seen:
            seen.add(it["id"])
            cases.append(dict(it, status=None, evidence=""))

    rep_path, rep_mtime, extra = None, -1, []
    for p in reports:
        text = scan_text(p)
        rel = os.path.relpath(p, block)
        t = os.path.getmtime(p)
        if t > rep_mtime:
            rep_path, rep_mtime = p, t
        by_id = {}
        for it in md_items(text, rel):
            if it["status"]:
                by_id.setdefault(it["id"], (it["status"], it["text"]))
        for c in cases:
            if c["status"] is None and c["id"] in by_id:
                c["status"], c["evidence"] = by_id[c["id"]][0], rel
        for iid, (st, txt) in by_id.items():
            if iid not in seen:
                extra.append({"id": iid, "text": txt, "status": st, "src": rel})
        for iid, st in text_statuses(text, seen).items():
            for c in cases:
                if c["id"] == iid and c["status"] is None:
                    c["status"], c["evidence"] = st, rel

    counts, unknown, skipped, counted = tally(cases)
    empty = "no test plan" if not plans else "test plan lists no cases"
    status, detail = roll_up(counts, unknown, counted, empty)
    if counted and not reports:
        status, detail = NONE, f"{counted} case(s) planned, no results reported"
    elif status == OK and rep_mtime > 0:
        plan_mtime = max([os.path.getmtime(p) for p in plans] or [0])
        if rtl_mtime and rep_mtime < rtl_mtime:
            age = (rtl_mtime - rep_mtime) / 60.0
            status, detail = STALE, detail + f" - RTL changed {age:.0f} min later"
        elif rep_mtime < plan_mtime:
            status, detail = STALE, detail + " - test plan changed afterwards"

    return {"status": status, "detail": detail, "cases": cases, "extra": extra,
            "counts": counts, "unknown": unknown, "skipped": skipped,
            "counted": counted, "passed": counts[OK], "n_plans": len(plans),
            "path": rep_path, "mtime": rep_mtime if rep_path else None,
            "rel": os.path.relpath(rep_path, block) if rep_path else None,
            "size": os.path.getsize(rep_path) if rep_path else 0, "quote": "",
            "globs": list(PLAN_GLOBS) + list(REPORT_GLOBS),
            "ncand": len(plans) + len(reports)}


def eval_gate(block, name, spec, rtl_mtime):
    files = sorted(set(sum((expand(block, g) for g in spec["globs"]), [])))
    path, mtime = newest(files)
    res = {"globs": list(spec["globs"]), "ncand": len(files), "quote": "",
           "path": None, "rel": None, "mtime": None, "size": 0,
           "wns": None, "tns": None, "fmax": None}
    if not path:
        res.update(status=NONE, detail="no report")
        return res

    text = scan_text(path)
    lines = text.splitlines()
    rel = os.path.relpath(path, block)

    if name == "TIMING":
        wns = tns = fmax = None
        for rx, key in ((RE_WNS, "wns"), (RE_TNS, "tns"), (RE_FMAX, "fmax")):
            m = rx.search(text)
            if m:
                val = float(m.group(1))
                if key == "wns":
                    wns = val
                elif key == "tns":
                    tns = val
                else:
                    fmax = val
        if wns is None and fmax is None:
            res.update(status=NONE, detail=f"{rel}: no WNS/Fmax found")
        else:
            bits = []
            if wns is not None:
                bits.append(f"WNS {wns:+.3f}ns")
            if tns is not None:
                bits.append(f"TNS {tns:+.3f}ns")
            if fmax is not None:
                bits.append(f"Fmax {fmax:.1f}MHz")
            bad = (wns is not None and wns < 0) or (tns is not None and tns < 0)
            res.update(status=BAD if bad else OK, detail=", ".join(bits),
                       quote=", ".join(bits))
        res.update(wns=wns, tns=tns, fmax=fmax)
    else:
        np_, qp, passed = find_lines(spec["pass"], lines)
        nf, qf, _ = find_lines(spec["fail"], lines, passed)
        nw, qw, _ = find_lines(spec["warn"], lines, passed)
        if nf:
            res.update(status=BAD, detail=f"{rel}: {nf} failure line(s)", quote=qf)
        elif np_:
            res.update(status=OK, quote=qp,
                       detail=f"{rel}" + (f", {nw} warning(s)" if nw else ""))
        elif nw:
            res.update(status=WARN, quote=qw,
                       detail=f"{rel}: {nw} warning(s), no pass line")
        else:
            res.update(status=WARN, detail=f"{rel}: no verdict found")

    # staleness beats a green tick
    if res["status"] == OK and rtl_mtime and mtime < rtl_mtime:
        age = (rtl_mtime - mtime) / 60.0
        res.update(status=STALE,
                   detail=res["detail"] + f" - RTL changed {age:.0f} min later")

    try:
        size = os.path.getsize(path)
    except OSError:
        size = 0
    res.update(path=path, rel=rel, mtime=mtime, size=size)
    return res


def classify(rel, ext, owner):
    """What kind of artifact a file is, for the inventory table."""
    if rel in owner:
        return f"{owner[rel]} report"
    top, fn = rel.split(os.sep)[0], os.path.basename(rel)
    if fn == "placeholder":
        return "skeleton placeholder"
    if fn == "simv" or fn.endswith(".simv"):
        return "sim executable"
    if ext in (".vpd", ".fsdb", ".vcd", ".shm", ".wlf"):
        return "waveform"
    if top == "rtl" and ext in RTL_EXT:
        return "RTL source"
    if top in ("sim", "vcsmx", "tb") and ext in (".sv", ".v"):
        return "testbench"
    if top == "fpv" and ext in (".sv", ".v", ".sva"):
        return "formal property"
    if ext == ".f":
        return "file list"
    if ext in (".sh", ".tcl", ".do", ".py"):
        return "run script"
    if top == "docs":
        return "document"
    if ext in (".log", ".rpt"):
        return "log"
    return "other"


def inventory(block, gates, now):
    """Every file the flow has produced in this block, and what verifies it."""
    owner = {}
    for g in EVIDENCE:
        if gates[g]["rel"]:
            owner[gates[g]["rel"]] = g
    papers = doc_owners(gates)

    rows, total, covered, coverable = [], 0, 0, 0
    for dp, dn, fns in os.walk(block):
        dn[:] = sorted(d for d in dn if d not in SKIP_DIRS and not d.startswith("."))
        for fn in sorted(fns):
            if fn.startswith(".") or fn in SKIP_FILES:
                continue
            p = os.path.join(dp, fn)
            try:
                size = os.path.getsize(p)
                mtime = os.path.getmtime(p)
            except OSError:
                continue
            rel = os.path.relpath(p, block)
            ext = os.path.splitext(fn)[1].lower()
            kind = papers.get(rel) or classify(rel, ext, owner)
            total += 1

            if rel in papers:
                d = next((x for x in gates["DOCS"]["docs"] if x["rel"] == rel),
                         None)
                if d:
                    state, scls = d["state"], d["scls"]
                else:
                    g = gates["FEAT"]
                    state, scls = g["detail"], g["status"]
            elif rel in owner:
                g = owner[rel]
                state, scls = f"feeds {g}", gates[g]["status"]
            elif size == 0:
                state = ("empty placeholder" if fn == "placeholder"
                         else "empty - nothing written yet")
                scls = NONE
            elif kind in ("RTL source", "testbench", "formal property"):
                coverable += 1
                by = [g for g in EVIDENCE
                      if gates[g]["status"] == OK and gates[g]["mtime"]
                      and gates[g]["mtime"] > mtime]
                if by:
                    covered += 1
                    state, scls = "verified by " + ", ".join(by), OK
                else:
                    stale_by = [g for g in EVIDENCE
                                if gates[g]["status"] in (OK, STALE)
                                and gates[g]["mtime"]
                                and gates[g]["mtime"] <= mtime]
                    if stale_by:
                        state = "edited after " + ", ".join(stale_by)
                        scls = STALE
                    else:
                        state, scls = "not verified", NONE
            else:
                state, scls = "-", NONE

            rows.append({"rel": rel, "kind": kind, "size": size, "mtime": mtime,
                         "lines": line_count(p, size), "state": state,
                         "scls": scls, "age": human_age(mtime, now)})

    rows.sort(key=lambda r: (r["kind"], r["rel"]))
    return {"rows": rows, "total": total, "covered": covered,
            "coverable": coverable, "reports": len(owner)}


def eval_block(block, root, now):
    name = os.path.basename(block)
    srcs = rtl_sources(block)
    _, rtl_mtime = newest(srcs) if srcs else (None, 0)

    tbs = [p for p in expand(block, "sim/*.sv") if os.path.getsize(p) > 0]
    gates = {g: eval_gate(block, g, spec, rtl_mtime) for g, spec in GATES.items()}
    gates["DOCS"] = eval_docs(block, rtl_mtime)
    gates["FEAT"] = eval_features(block, root)
    gates["TESTS"] = eval_tests(block, rtl_mtime)

    if not srcs:
        rtl = {"status": BAD, "detail": "no RTL (empty or missing)"}
    else:
        rtl = {"status": OK, "detail": f"{len(srcs)} file(s)"}
    tb = ({"status": OK, "detail": f"{len(tbs)} file(s)"} if tbs
          else {"status": NONE, "detail": "no testbench"})
    for stub in (rtl, tb):
        stub.update(path=None, rel=None, mtime=None, size=0, quote="",
                    globs=[], ncand=0)

    allg = {"RTL": rtl, "TB": tb, **gates}
    worst = min((v["status"] for v in allg.values()), key=lambda s: ORDER[s])
    counts = {s: 0 for s in ORDER}
    for c in COLS:
        counts[allg[c]["status"]] += 1
    green = counts[OK]

    return {
        "name": name,
        "path": block,
        "gates": allg,
        "worst": worst,
        "rtl_mtime": rtl_mtime,
        "n_src": len(srcs),
        "counts": counts,
        "green": green,
        "pct": 100.0 * green / len(COLS),
        "inv": inventory(block, allg, now),
    }


def doc_owners(gates):
    """Map docs/<file> -> the document role it fills, for the inventory."""
    out = {d["rel"]: d["kind"] for d in gates["DOCS"]["docs"] if d["rel"]}
    feat = gates["FEAT"]
    if feat["rel"] and feat["scope"] == "block":
        out.setdefault(feat["rel"], "feature list")
    return out


def discover(root):
    out = []
    for dp, dn, _fn in os.walk(root):
        if "rtl" in dn:
            out.append(dp)
            dn[:] = [d for d in dn if d not in ("rtl", "sim", "synth", "fpv",
                                                "docs", "vcsmx", "lint", "cdc", "sta")]
    return sorted(out)



# --------------------------------------------------------------------------
# The spend ledger. Kept deliberately separate from the gates: spend is a
# COUNTER, never a gate. A block is not worse engineering because it cost
# more, so nothing here can move the progress bar or colour a gate.
# --------------------------------------------------------------------------
def usage_paths(root, here, explicit=None):
    """Every place a ledger might sit, nearest first.

    An explicit --usage path wins outright: if you named a file, a fallback
    to some other ledger would report numbers you did not ask for.
    """
    if explicit:
        return [os.path.abspath(explicit)]
    seen, out = set(), []
    for base in (here, root):
        for g in USAGE_GLOBS:
            q = os.path.abspath(os.path.join(base, g))
            if q not in seen:
                seen.add(q)
                out.append(q)
    return out


def read_usage(root, here, explicit=None):
    """Parse the first ledger found. Never raises - a bad line is counted."""
    recs, bad, src = [], 0, None
    for q in usage_paths(root, here, explicit):
        if not os.path.isfile(q):
            continue
        src = q
        try:
            with open(q, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    try:
                        o = json.loads(line)
                    except ValueError:
                        bad += 1
                        continue
                    if isinstance(o, dict):
                        recs.append(o)
                    else:
                        bad += 1
        except OSError:
            continue
        break
    return recs, bad, src


def priced(rec):
    """(cost, how) for one record: reported, derived, or unpriced."""
    c = rec.get("cost", rec.get("cost_usd"))
    if isinstance(c, (int, float)) and not isinstance(c, bool):
        return float(c), "reported"
    rate = RATES.get(str(rec.get("model", "")))
    if rate:
        ti = float(rec.get("in", rec.get("tokens_in", 0)) or 0)
        to = float(rec.get("out", rec.get("tokens_out", 0)) or 0)
        return (ti * rate[0] + to * rate[1]) / 1e6, "derived"
    return 0.0, "unpriced"


def usage_summary(root, here, explicit=None):
    """Aggregate the ledger into what the page and the digest report."""
    recs, bad, src = read_usage(root, here, explicit)
    u = {"src": src, "bad": bad, "n": len(recs), "tin": 0, "tout": 0,
         "cost": 0.0, "reported": 0, "derived": 0, "unpriced": 0,
         "models": {}, "runs": [], "first": "", "last": ""}
    for r in recs:
        ti = int(r.get("in", r.get("tokens_in", 0)) or 0)
        to = int(r.get("out", r.get("tokens_out", 0)) or 0)
        c, how = priced(r)
        u["tin"] += ti
        u["tout"] += to
        u["cost"] += c
        u[how] += 1
        m = str(r.get("model") or "unrecorded")
        d = u["models"].setdefault(
            m, {"n": 0, "tok": 0, "cost": 0.0, "unpriced": 0})
        d["n"] += 1
        d["tok"] += ti + to
        d["cost"] += c
        if how == "unpriced":
            d["unpriced"] += 1
        ts = str(r.get("ts") or "")
        if ts:
            u["first"] = min(u["first"] or ts, ts)
            u["last"] = max(u["last"], ts)
        u["runs"].append({"ts": ts, "task": str(r.get("task")
                                                or r.get("note") or ""),
                          "block": str(r.get("block") or ""), "model": m,
                          "tok": ti + to, "cost": c, "how": how})
    u["tok"] = u["tin"] + u["tout"]
    u["runs"].sort(key=lambda x: x["ts"], reverse=True)
    return u


def log_usage(path, fields):
    """Append one record, creating the file and its directory if needed."""
    d = os.path.dirname(os.path.abspath(path))
    if d and not os.path.isdir(d):
        os.makedirs(d)
    rec = {"ts": datetime.now().replace(microsecond=0).isoformat()}
    rec.update({k: v for k, v in fields.items() if v is not None})
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, sort_keys=True) + "\n")
    return rec


def human_tok(n):
    """18432 -> 18.4k. Token counts are read at a glance, not audited."""
    n = float(n)
    for lim, suf in ((1e9, "B"), (1e6, "M"), (1e3, "k")):
        if n >= lim:
            return "%.1f%s" % (n / lim, suf)
    return str(int(n))


def money(v):
    return "${:,.2f}".format(v)


# --------------------------------------------------------------------------
CSS = """
:root{--bg:#0f1319;--panel:#161b23;--card:#1a202a;--line:#242c38;--txt:#dbe3ee;
--dim:#8794a6;--ok:#2e9e5b;--bad:#d7413e;--warn:#c98a1b;--stale:#7a6cc4;
--none:#3a4454}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--txt);
font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
header{position:sticky;top:0;background:var(--panel);border-bottom:1px solid var(--line);
padding:14px 20px;display:flex;gap:22px;align-items:baseline;flex-wrap:wrap;z-index:9}
h1{font-size:16px;margin:0;letter-spacing:.06em}
h2{font-size:11px;letter-spacing:.14em;color:var(--dim);margin:26px 0 10px;
font-weight:600}
.meta{color:var(--dim);font-size:12px}
.tally{display:flex;gap:8px;margin-left:auto;flex-wrap:wrap}
.pill{padding:3px 10px;border-radius:99px;font-size:12px;border:1px solid var(--line)}
.pill b{font-weight:600}
main{padding:18px 20px 60px}

/* ---- project progress ---- */
.hero{display:flex;gap:26px;align-items:center;background:var(--panel);
border:1px solid var(--line);border-radius:10px;padding:20px 22px}
.hero.done{border-color:var(--ok)}
.ring{--pct:0;flex:none;width:128px;height:128px;border-radius:50%;
background:conic-gradient(var(--ok) calc(var(--pct)*1%),var(--none) 0);
display:grid;place-items:center;position:relative}
.ring::after{content:"";position:absolute;width:102px;height:102px;
border-radius:50%;background:var(--panel)}
.ring div{position:relative;text-align:center;line-height:1.25}
.ring b{font-size:27px;font-weight:700;letter-spacing:-.02em}
.ring span{display:block;font-size:10px;letter-spacing:.12em;color:var(--dim)}
.herobody{flex:1;min-width:280px}
.herotop{display:flex;justify-content:space-between;align-items:baseline;
gap:14px;flex-wrap:wrap;margin-bottom:8px}
.herotop b{font-size:13px;letter-spacing:.06em}
.banner{color:var(--ok);font-weight:700;letter-spacing:.08em;font-size:12px}
.sub{color:var(--dim);font-size:12px;margin-top:9px}

/* ---- bars ---- */
.sbar{display:flex;height:9px;background:var(--none);border-radius:99px;
overflow:hidden}
.sbar.big{height:16px;border-radius:6px}
.sbar.thin{height:6px}
.sbar i{display:block;height:100%;flex:0 0 auto}
.s-ok{background:var(--ok)}.s-bad{background:var(--bad)}
.s-warn{background:var(--warn)}.s-stale{background:var(--stale)}
.s-none{background:var(--none)}

/* ---- counter cards ---- */
.cards{display:grid;gap:12px;margin-top:14px;
grid-template-columns:repeat(auto-fit,minmax(168px,1fr))}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;
padding:12px 14px}
.card .k{font-size:10px;letter-spacing:.12em;color:var(--dim)}
.card .v{font-size:22px;font-weight:700;margin:3px 0 7px}
.card .v s{text-decoration:none;font-size:13px;color:var(--dim);font-weight:400}

/* ---- per-gate coverage ---- */
.cov{display:grid;gap:8px 16px;grid-template-columns:repeat(auto-fit,minmax(250px,1fr))}
.covrow{display:flex;align-items:center;gap:10px;font-size:12px}
.covrow .g{width:58px;color:var(--dim);letter-spacing:.08em}
.covrow .sbar{flex:1}
.covrow .n{width:82px;text-align:right;color:var(--dim)}

/* ---- matrix ---- */
table{border-collapse:collapse;width:100%}
th{text-align:left;font-weight:600;color:var(--dim);font-size:11px;
letter-spacing:.09em;padding:8px 10px;border-bottom:1px solid var(--line)}
td{padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top}
tr:hover td{background:#1a212b}
.blk{font-weight:600}
.blk a{color:inherit;text-decoration:none;border-bottom:1px dotted var(--dim)}
.chip{display:inline-block;min-width:62px;text-align:center;padding:2px 8px;
border-radius:4px;font-size:11px;letter-spacing:.05em;color:#080c11;font-weight:700}
.c-ok{background:var(--ok)}.c-bad{background:var(--bad);color:#fff}
.c-warn{background:var(--warn)}.c-stale{background:var(--stale);color:#fff}
.c-none{background:var(--none);color:#9fb0c6}
.d{color:var(--dim);font-size:11.5px;display:block;margin-top:3px;word-break:break-word}
.prog{min-width:132px}
.prog .n{font-size:11px;color:var(--dim);display:block;margin-top:4px}

/* ---- detail drawers ---- */
details.bd{background:var(--card);border:1px solid var(--line);border-radius:8px;
margin-bottom:8px}
details.bd[open]{border-color:#32405a}
details.bd>summary{list-style:none;cursor:pointer;display:flex;gap:12px;
align-items:center;padding:11px 14px;flex-wrap:wrap}
details.bd>summary::-webkit-details-marker{display:none}
details.bd>summary:hover{background:#1e2531;border-radius:8px}
.tw{color:var(--dim);transition:transform .12s;display:inline-block;width:10px}
details.bd[open]>summary .tw{transform:rotate(90deg)}
.nm{font-weight:600;min-width:150px}
.mg{display:inline-block;padding:1px 5px;border-radius:3px;font-size:9.5px;
letter-spacing:.04em;color:#080c11;font-weight:700;margin-right:3px}
.pct{font-weight:700;min-width:44px;text-align:right}
summary .sbar{width:150px;flex:none}
.hint{color:var(--dim);font-size:11px;margin-left:auto}
details.bd[open]>summary .cta{display:none}
.body{padding:4px 14px 16px;border-top:1px solid var(--line)}
.body h4{font-size:10px;letter-spacing:.14em;color:var(--dim);
margin:16px 0 6px;font-weight:600}
table.inv{font-size:11.5px}
table.inv th{padding:5px 8px;font-size:10px}
table.inv td{padding:5px 8px;border-bottom:1px solid #1f2733}
table.inv .mono{color:var(--txt)}
table.inv .q{color:var(--dim);font-style:normal}
.tag{display:inline-block;padding:1px 6px;border-radius:3px;font-size:10px;
font-weight:700;color:#080c11}
.num{text-align:right;color:var(--dim);white-space:nowrap}
/* ---- spend ---- */
.spend{display:grid;gap:8px 16px;grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}
.sprow{display:flex;align-items:baseline;gap:10px;font-size:12px}
.sprow .g{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sprow .n{color:var(--dim);white-space:nowrap}
.sprow .n b{color:var(--txt);font-weight:600}
.unpriced{color:var(--warn)}
.nodata{color:var(--dim);font-size:12px;line-height:1.85;background:var(--card);
border:1px dashed var(--line);border-radius:8px;padding:12px 14px}
.nodata code{color:var(--txt)}

.legend{margin-top:22px;color:var(--dim);font-size:12px;line-height:1.9}
.legend .chip{margin-right:8px}
"""

JS = """
// The page rewrites itself every few seconds. Keep the scroll position and
// which drawers are open, or the refresh would close everything you opened.
(function(){
  var K='rtlmon.ui', st={y:0,open:{}};
  try{ st=JSON.parse(sessionStorage.getItem(K))||st; }catch(e){}
  function save(){ try{ sessionStorage.setItem(K,JSON.stringify(st)); }catch(e){} }
  var ds=document.querySelectorAll('details[data-k]');
  for(var i=0;i<ds.length;i++){(function(d){
    if(st.open[d.getAttribute('data-k')]) d.open=true;
    d.addEventListener('toggle',function(){
      st.open[d.getAttribute('data-k')]=d.open; save();
    });
  })(ds[i]);}
  var h=location.hash.slice(1);
  if(h){ var t=document.getElementById(h);
    if(t&&t.tagName==='DETAILS'){ t.open=true; st.open[t.getAttribute('data-k')]=true; save(); } }
  window.addEventListener('load',function(){
    if(!location.hash) window.scrollTo(0,st.y||0);
  });
  window.addEventListener('scroll',function(){ st.y=window.scrollY; save(); },
    {passive:true});
})();
"""


def chip(status, label=None):
    text = label or {OK: "PASS", BAD: "FAIL", WARN: "WARN",
                     STALE: "STALE", NONE: "-"}[status]
    return f'<span class="chip c-{status}">{text}</span>'


def sbar(counts, total, cls=""):
    """Stacked bar: one segment per status, green first."""
    if not total:
        return f'<div class="sbar {cls}"></div>'
    segs = "".join(
        f'<i class="s-{s}" style="width:{100.0 * counts.get(s, 0) / total:.3f}%"></i>'
        for s in (OK, BAD, STALE, WARN, NONE) if counts.get(s))
    return f'<div class="sbar {cls}">{segs}</div>'


def gate_table(b):
    rows = []
    for c in COLS:
        g = b["gates"][c]
        if g["rel"]:
            ev = f'<span class="mono">{html.escape(g["rel"])}</span>'
            if g["ncand"] > 1:
                ev += f'<span class="d">+{g["ncand"] - 1} other candidate file(s)</span>'
            size, age = human_size(g["size"]), g.get("age", "")
        elif c in EVIDENCE or c in PAPER:
            ev = ('<span class="q">nothing found - looked in '
                  + html.escape(", ".join(g["globs"])) + "</span>")
            size, age = "-", "-"
        else:
            ev = '<span class="q">structural check, no report file</span>'
            size, age = "-", "-"
        says = g["quote"] or g["detail"]
        rows.append(
            f'<tr><td>{c}</td><td>{chip(g["status"])}</td><td>{ev}</td>'
            f'<td class="num">{size}</td><td class="num">{age}</td>'
            f'<td class="q">{html.escape(says)}</td></tr>')
    return ('<table class="inv"><thead><tr><th>GATE</th><th>STATUS</th>'
            '<th>EVIDENCE FILE</th><th>SIZE</th><th>WRITTEN</th>'
            '<th>WHAT IT SAYS</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table>")


def doc_table(b):
    g = b["gates"]["DOCS"]
    rows = []
    for d in g["docs"]:
        if d["rel"]:
            name = f'<span class="mono">{html.escape(d["rel"])}</span>'
            lines, size = str(d["lines"]), human_size(d["size"])
            age = human_age(d["mtime"], time.time())
        else:
            name = '<span class="q">not written</span>'
            lines = size = age = "-"
        rows.append(
            f'<tr><td>{html.escape(d["kind"])}</td><td>{name}</td>'
            f'<td class="num">{lines}</td><td class="num">{size}</td>'
            f'<td class="num">{age}</td>'
            f'<td><span class="tag c-{d["scls"]}">'
            f'{html.escape(d["state"])}</span></td></tr>')
    return ('<table class="inv"><thead><tr><th>DOCUMENT</th><th>FILE</th>'
            '<th>LINES</th><th>SIZE</th><th>WRITTEN</th><th>STATE</th>'
            '</tr></thead><tbody>' + "".join(rows) + "</tbody></table>")


def item_table(items, cols, extra=(), empty="nothing recorded"):
    """Shared renderer for the feature list and the test-case list."""
    rows = []
    for it in list(items)[:MAX_ITEMS]:
        st = it["status"]
        if st == "skip":
            cls, label = NONE, "n/a"
        elif st is None:
            cls, label = WARN, "no status"
        else:
            cls, label = st, {OK: "DONE", BAD: "NOT DONE", WARN: "PARTIAL",
                              STALE: "STALE", NONE: "NOT RUN"}[st]
        src = it.get("evidence") or it["src"]
        rows.append(
            f'<tr><td class="mono">{html.escape(it["id"])}</td>'
            f'<td class="q">{html.escape(it["text"])}</td>'
            f'<td class="q">{html.escape(it.get("head", ""))}</td>'
            f'<td><span class="tag c-{cls}">{label}</span></td>'
            f'<td class="q">{html.escape(src)}</td></tr>')
    for it in extra:
        rows.append(
            f'<tr><td class="mono">{html.escape(it["id"])}</td>'
            f'<td class="q">{html.escape(it["text"])}</td>'
            f'<td class="q">not in the plan</td>'
            f'<td><span class="tag c-{WARN}">UNPLANNED</span></td>'
            f'<td class="q">{html.escape(it["src"])}</td></tr>')
    if len(items) > MAX_ITEMS:
        rows.append(f'<tr><td colspan="5" class="q">... and '
                    f'{len(items) - MAX_ITEMS} more</td></tr>')
    if not rows:
        rows = [f'<tr><td colspan="5" class="q">{html.escape(empty)}</td></tr>']
    head = "".join(f"<th>{c}</th>" for c in cols)
    return (f'<table class="inv"><thead><tr>{head}</tr></thead><tbody>'
            + "".join(rows) + "</tbody></table>")


def file_table(b):
    inv = b["inv"]
    rows = []
    for r in inv["rows"][:MAX_FILES]:
        lines = "-" if r["lines"] is None else str(r["lines"])
        rows.append(
            f'<tr><td class="mono">{html.escape(r["rel"])}</td>'
            f'<td class="q">{html.escape(r["kind"])}</td>'
            f'<td class="num">{lines}</td>'
            f'<td class="num">{human_size(r["size"])}</td>'
            f'<td class="num">{r["age"]}</td>'
            f'<td><span class="tag c-{r["scls"]}">{html.escape(r["state"])}</span></td></tr>')
    more = ""
    if len(inv["rows"]) > MAX_FILES:
        more = (f'<tr><td colspan="6" class="q">... and '
                f'{len(inv["rows"]) - MAX_FILES} more file(s)</td></tr>')
    if not rows:
        rows = ['<tr><td colspan="6" class="q">no files yet</td></tr>']
    return ('<table class="inv"><thead><tr><th>FILE</th><th>KIND</th>'
            '<th>LINES</th><th>SIZE</th><th>MODIFIED</th>'
            '<th>VERIFIED BY</th></tr></thead><tbody>'
            + "".join(rows) + more + "</tbody></table>")


def block_card(b):
    inv = b["inv"]
    doc, feat, test = (b["gates"][g] for g in PAPER)
    mg = "".join(f'<span class="mg c-{b["gates"][c]["status"]}" '
                 f'title="{c} {b["gates"][c]["status"]}">{c}</span>' for c in COLS)
    cov = (f'{inv["covered"]}/{inv["coverable"]}' if inv["coverable"]
           else "0/0")
    if feat["counted"]:
        feathead = f"{feat['done']} OF {feat['counted']} DONE"
        if feat["unknown"]:
            feathead += f", {feat['unknown']} WITH NO STATUS RECORDED"
        if feat["skipped"]:
            feathead += f", {feat['skipped']} WAIVED"
        if feat["scope"] == "project":
            feathead += " (PROJECT-LEVEL LIST)"
    else:
        feathead = "NONE LISTED"
    if test["counted"]:
        testhead = f"{test['passed']} OF {test['counted']} PASSING"
        if test["extra"]:
            testhead += f", {len(test['extra'])} REPORTED BUT NOT PLANNED"
    else:
        testhead = "NONE PLANNED"
    return f"""<details class="bd" id="b-{html.escape(b['name'])}" data-k="{html.escape(b['name'])}">
  <summary>
    <span class="tw">&#9654;</span>
    <span class="nm">{html.escape(b['name'])}</span>
    {chip(b['worst'])}
    <span>{mg}</span>
    {sbar(b['counts'], len(COLS))}
    <span class="pct">{b['pct']:.0f}%</span>
    <span class="hint">{b['green']}/{len(COLS)} gates &middot; {inv['total']} files
      &middot; {cov} verified <span class="cta">&middot; click for further details</span></span>
  </summary>
  <div class="body">
    <h4>GATE EVIDENCE - WHERE EVERY VERDICT CAME FROM</h4>
    {gate_table(b)}
    <h4>DOCUMENTATION - {doc['n_ok']} OF {doc['n_total']} DOCUMENTS
      PRESENT AND CURRENT</h4>
    {doc_table(b)}
    <h4>FEATURES - {feathead}</h4>
    {item_table(feat['items'],
                ("ID", "FEATURE", "GROUP", "STATUS", "SOURCE"),
                empty="no feature or requirement list found - see PART 9 "
                      "section 5b for where to put one")}
    <h4>TEST CASES - {testhead}</h4>
    {item_table(test['cases'],
                ("ID", "WHAT IT PROVES", "PLAN SECTION", "STATUS", "RESULT FROM"),
                extra=test['extra'],
                empty="no test plan found - see PART 9 section 5b")}
    <h4>FILES GENERATED AND VERIFIED - {inv['total']} FILE(S),
      {inv['reports']} TOOL REPORT(S), {cov} SOURCE FILE(S) COVERED BY GREEN EVIDENCE</h4>
    {file_table(b)}
  </div>
</details>"""


def render(blocks, root, refresh, usage, ledgers=()):
    now = time.time()
    tally = {s: 0 for s in ORDER}
    for b in blocks:
        tally[b["worst"]] += 1

    ngates = len(COLS) * len(blocks)
    tot = {s: 0 for s in ORDER}
    for b in blocks:
        for s in ORDER:
            tot[s] += b["counts"][s]
    green = tot[OK]
    pct = (100.0 * green / ngates) if ngates else 0.0
    done_blocks = tally[OK]
    covered = sum(b["inv"]["covered"] for b in blocks)
    coverable = sum(b["inv"]["coverable"] for b in blocks)
    reports = sum(b["inv"]["reports"] for b in blocks)
    nfiles = sum(b["inv"]["total"] for b in blocks)

    docs_ok = sum(b["gates"]["DOCS"]["n_ok"] for b in blocks)
    docs_all = sum(b["gates"]["DOCS"]["n_total"] for b in blocks)
    feat_ok = sum(b["gates"]["FEAT"]["done"] for b in blocks)
    feat_all = sum(b["gates"]["FEAT"]["counted"] for b in blocks)
    feat_unk = sum(b["gates"]["FEAT"]["unknown"] for b in blocks)
    test_ok = sum(b["gates"]["TESTS"]["passed"] for b in blocks)
    test_all = sum(b["gates"]["TESTS"]["counted"] for b in blocks)

    ordered = sorted(blocks, key=lambda x: (ORDER[x["worst"]], x["name"]))

    rows = []
    for b in ordered:
        tds = [f'<td class="blk"><a href="#b-{html.escape(b["name"])}">'
               f'{html.escape(b["name"])}</a></td>',
               f'<td>{chip(b["worst"])}</td>',
               f'<td class="prog">{sbar(b["counts"], len(COLS))}'
               f'<span class="n">{b["green"]}/{len(COLS)} gates &middot; '
               f'{b["pct"]:.0f}%</span></td>']
        for c in COLS:
            g = b["gates"][c]
            tds.append(f'<td>{chip(g["status"])}'
                       f'<span class="d">{html.escape(g["detail"])}</span></td>')
        rows.append("<tr>" + "".join(tds) + "</tr>")

    covrows = []
    for c in COLS:
        cc = {s: 0 for s in ORDER}
        for b in blocks:
            cc[b["gates"][c]["status"]] += 1
        covrows.append(
            f'<div class="covrow"><span class="g">{c}</span>'
            f'{sbar(cc, len(blocks), "thin")}'
            f'<span class="n">{cc[OK]}/{len(blocks)} green</span></div>')

    head = "".join(f"<th>{c}</th>" for c in COLS)
    pills = "".join(
        f'<span class="pill" style="border-color:var(--{s})">'
        f'{lbl} <b>{tally[s]}</b></span>'
        for s, lbl in ((OK, "pass"), (BAD, "fail"), (STALE, "stale"),
                       (WARN, "warn"), (NONE, "no data")))

    complete = ngates and green == ngates
    banner = ('<span class="banner">&#10003; ALL GATES GREEN - BUILD COMPLETE</span>'
              if complete else
              f'<span class="meta">{ngates - green} gate(s) still to close</span>')

    def card(k, v, sub, counts=None, total=0):
        bar = sbar(counts, total, "thin") if counts else ""
        return (f'<div class="card"><div class="k">{k}</div>'
                f'<div class="v">{v} <s>{sub}</s></div>{bar}</div>')

    cards = "".join((
        card("BLOCKS COMPLETE", f"{done_blocks}<s>/{len(blocks)}</s>", "all gates green",
             {OK: done_blocks, NONE: len(blocks) - done_blocks}, len(blocks)),
        card("GATES GREEN", f"{green}<s>/{ngates}</s>", "across every block",
             tot, ngates),
        card("FEATURES DONE", f"{feat_ok}<s>/{feat_all}</s>",
             (f"{feat_unk} with no status" if feat_unk
              else "implemented and evidenced"),
             {OK: feat_ok, NONE: feat_all - feat_ok}, feat_all),
        card("TEST CASES PASSING", f"{test_ok}<s>/{test_all}</s>",
             "planned cases with a result",
             {OK: test_ok, NONE: test_all - test_ok}, test_all),
        card("DOCUMENTS CURRENT", f"{docs_ok}<s>/{docs_all}</s>",
             "spec, test plan, report",
             {OK: docs_ok, NONE: docs_all - docs_ok}, docs_all),
        card("SOURCE FILES VERIFIED", f"{covered}<s>/{coverable}</s>",
             "covered by green evidence",
             {OK: covered, NONE: coverable - covered}, coverable),
        card("TOOL REPORTS READ", str(reports), f"of {nfiles} files on disk"),
        card("FAILING GATES", str(tot[BAD]), "red - fix these first"),
        card("STALE / NEVER RUN", f"{tot[STALE]}<s> / {tot[NONE]}</s>",
             "evidence missing or out of date"),
        card("CREDITS SPENT",
             money(usage["cost"]) if usage["reported"] or usage["derived"]
             else "&mdash;",
             (f'{usage["unpriced"]} of {usage["n"]} run(s) unpriced'
              if usage["unpriced"] else
              (f'over {usage["n"]} recorded run(s)' if usage["n"]
               else "nothing logged yet"))),
        card("TOKENS USED",
             human_tok(usage["tok"]) if usage["n"] else "&mdash;",
             (f'{human_tok(usage["tin"])} in / {human_tok(usage["tout"])} out'
              if usage["n"] else "no ledger found")),
    ))


    if usage["n"]:
        sprows = []
        for m, d in sorted(usage["models"].items(),
                           key=lambda kv: (-kv[1]["cost"], -kv[1]["tok"])):
            cost = (f'<span class="unpriced">{d["unpriced"]} unpriced</span>'
                    if d["unpriced"] == d["n"] else f'<b>{money(d["cost"])}</b>')
            sprows.append(
                f'<div class="sprow"><span class="g">{html.escape(m)}</span>'
                f'<span class="n">{d["n"]} run(s) &middot; '
                f'{human_tok(d["tok"])} tok &middot; {cost}</span></div>')
        recent = "".join(
            f'<div class="sprow"><span class="g">'
            f'{html.escape(r["ts"][:16] or "no timestamp")} '
            f'{html.escape(r["task"] or r["block"] or r["model"])}</span>'
            f'<span class="n">{human_tok(r["tok"])} tok &middot; '
            + (f'<span class="unpriced">unpriced</span>' if r["how"] == "unpriced"
               else f'<b>{money(r["cost"])}</b>') + '</span></div>'
            for r in usage["runs"][:8])
        warn = ""
        if usage["unpriced"]:
            warn = (f'<div class="sub"><span class="unpriced">'
                    f'{usage["unpriced"]} run(s) carry tokens but no price</span> - '
                    f'the total above is the floor, not the bill. Add the model '
                    f'to RATES, or log a "cost" field.</div>')
        if usage["derived"]:
            warn += (f'<div class="sub">{usage["derived"]} run(s) priced from '
                     f'the local RATES table rather than a reported charge.</div>')
        if usage["bad"]:
            warn += (f'<div class="sub"><span class="unpriced">'
                     f'{usage["bad"]} unparseable line(s)</span> in '
                     f'{html.escape(usage["src"] or "the ledger")}.</div>')
        spend = f"""
  <h2>AI SPEND - RECORDED, NOT ESTIMATED</h2>
  <div class="sub">{usage["n"]} run(s) logged
    {html.escape(("from " + usage["first"][:16]) if usage["first"] else "")}
    {html.escape(("to " + usage["last"][:16]) if usage["last"] else "")} &middot;
    ledger {html.escape(usage["src"] or "?")}</div>
  {warn}
  <div class="spend" style="margin-top:12px">{"".join(sprows)}</div>
  <h2>MOST RECENT RUNS</h2>
  <div class="spend">{recent}</div>"""
    else:
        spend = """
  <h2>AI SPEND</h2>
  <div class="nodata">
    No ledger found, so nothing is claimed. This is deliberately blank rather
    than zero - zero would read as "this project was free", and unrecorded is
    not free.<br>
    Record a run with:<br>
    <code>python3 rtl_monitor.py --log-usage --model NAME --tok-in 18432
    --tok-out 2310 --cost 0.42 --task "what it was for"</code><br>
    Searched: <code>""" + html.escape(", ".join(ledgers[:3]) or "-") + """</code>
  </div>"""

    return f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="{refresh}">
<title>RTL quality gates - {pct:.0f}% complete</title>
<style>{CSS}</style>
</head><body>
<header>
  <h1>RTL QUALITY GATES</h1>
  <span class="meta">{html.escape(root)}</span>
  <span class="meta">updated {datetime.now().strftime('%H:%M:%S')} &middot;
    refresh {refresh}s &middot; {len(blocks)} blocks</span>
  <span class="tally">{pills}</span>
</header>
<main>
  <section class="hero{' done' if complete else ''}">
    <div class="ring" style="--pct:{pct:.1f}">
      <div><b>{pct:.0f}%</b><span>COMPLETE</span></div>
    </div>
    <div class="herobody">
      <div class="herotop">
        <b>PROJECT PROGRESS</b>
        {banner}
      </div>
      {sbar(tot, ngates, "big")}
      <div class="sub">
        {green} of {ngates} gates green &middot;
        {tot[BAD]} failing &middot; {tot[STALE]} stale &middot;
        {tot[WARN]} unclear &middot; {tot[NONE]} never run.
        Only green counts towards the bar.
      </div>
      <div class="sub">
        {done_blocks} of {len(blocks)} blocks are green end to end -
        that, and only that, is done.
      </div>
      <div class="sub">
        Deliverables: {feat_ok}/{feat_all} features done &middot;
        {test_ok}/{test_all} planned test cases passing &middot;
        {docs_ok}/{docs_all} documents present and current.
      </div>
    </div>
  </section>

  <div class="cards">{cards}</div>

  <h2>GATE COVERAGE ACROSS ALL BLOCKS</h2>
  <div class="cov">{''.join(covrows)}</div>

  <h2>BLOCK MATRIX</h2>
  <table>
    <thead><tr><th>BLOCK</th><th>OVERALL</th><th>PROGRESS</th>{head}</tr></thead>
    <tbody>{''.join(rows)}</tbody>
  </table>

  {spend}

  <h2>FURTHER DETAILS - EVIDENCE AND FILES PER BLOCK</h2>
  {''.join(block_card(b) for b in ordered)}

  <div class="legend">
    {chip(OK)} report exists, says it passed, and is newer than the RTL<br>
    {chip(BAD)} report says it failed, or timing shows negative slack<br>
    {chip(STALE)} it passed, but the RTL changed afterwards - rerun before believing it<br>
    {chip(WARN)} report exists but gives no clear verdict, or warnings only<br>
    {chip(NONE)} no report found - the gate has never been run<br>
    <br>
    AI spend is a counter, never a gate: it is reported beside the gates and
    is deliberately kept out of the progress maths, because a block is not
    worse engineering for having cost more.<br>
    <br>
    Progress is the fraction of gates that are green, counted over every block.
    A gate that is failing, stale, unclear or never run contributes nothing, so
    the bar reaches 100% only when every block is green end to end.<br>
    Gates come from PART 3 of the methodology file. A block is done only when
    every gate is green: no negative slack, no inferred latches, no
    unsynchronised crossings, a self-checking bench reporting PASS.
  </div>
</main>
<script>{JS}</script>
</body></html>
"""


def spend_line(usage):
    """One line of the digest. Says 'not recorded' rather than implying free."""
    if not usage["n"]:
        return "SPEND     not recorded - no usage ledger found"
    bits = [f'{human_tok(usage["tok"])} tokens', f'{usage["n"]} run(s)']
    if usage["reported"] or usage["derived"]:
        bits.insert(0, money(usage["cost"])
                    + ("+" if usage["unpriced"] else ""))
    if usage["unpriced"]:
        bits.append(f'{usage["unpriced"]} unpriced')
    if usage["bad"]:
        bits.append(f'{usage["bad"]} bad line(s)')
    return "SPEND     " + "  ".join(bits)


def status_text(blocks, root, usage):
    """A whole-project status digest in about a dozen lines of plain text.

    The HTML page is for a human and runs to hundreds of kilobytes. Anything
    automated - a shell prompt, a git hook, an agent checking where the build
    stands - should read this instead. Same data, ~1% of the bytes, and no
    reason to ever put the generated page in front of a language model.
    """
    lab = {OK: "PASS", BAD: "FAIL", WARN: "WARN", STALE: "STALE", NONE: "-"}
    tot = {s: 0 for s in ORDER}
    for b in blocks:
        for s in ORDER:
            tot[s] += b["counts"][s]
    green = tot[OK]
    ngates = len(COLS) * len(blocks)
    pct = (100.0 * green / ngates) if ngates else 0.0
    done = sum(1 for b in blocks if b["worst"] == OK)

    def gsum(gate, key):
        return sum(b["gates"][gate][key] for b in blocks)

    w = max([len(b["name"]) for b in blocks] + [7])
    out = [f"RTL QUALITY GATES  root={root}  {len(blocks)} blocks  "
           f"{datetime.now():%H:%M:%S}",
           f"PROGRESS  {pct:.0f}%  {green}/{ngates} gates green  "
           f"{done}/{len(blocks)} blocks complete",
           f"PENDING   {tot[BAD]} failing  {tot[STALE]} stale  "
           f"{tot[WARN]} unclear  {tot[NONE]} never run",
           f"ITEMS     features {gsum('FEAT', 'done')}/"
           f"{gsum('FEAT', 'counted')} done  "
           f"tests {gsum('TESTS', 'passed')}/{gsum('TESTS', 'counted')} "
           f"passing  docs {gsum('DOCS', 'n_ok')}/{gsum('DOCS', 'n_total')} "
           f"current",
           spend_line(usage),
           "",
           "BLOCK".ljust(w) + "  OVERALL  PROG   "
           + " ".join(c.ljust(6) for c in COLS)]

    ordered = sorted(blocks, key=lambda x: (ORDER[x["worst"]], x["name"]))
    for b in ordered:
        prog = f'{b["green"]}/{len(COLS)}'
        out.append((b["name"].ljust(w) + f'  {lab[b["worst"]]:<7}  '
                    + prog.ljust(6)
                    + " ".join(lab[b["gates"][c]["status"]].ljust(6)
                               for c in COLS)).rstrip())

    bad = [(b["name"], c, b["gates"][c]["detail"]) for b in ordered
           for c in COLS if b["gates"][c]["status"] in (BAD, STALE)]
    if bad:
        out += ["", "NEEDS WORK"]
        out += [f"  {n.ljust(w)}  {c}: {d}" for n, c, d in bad[:25]]
        if len(bad) > 25:
            out.append(f"  ... and {len(bad) - 25} more")
    return "\n".join(out)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_root = os.path.abspath(os.path.join(
        here, "..", "RTL", "Reference_Codes_for_coding_style_RTL",
        "RTLBasicBlockCoding"))
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=default_root, help="tree of RTL blocks")
    ap.add_argument("--out", default=os.path.join(here, "rtl_dashboard.html"))
    ap.add_argument("--refresh", type=int, default=2, help="page refresh seconds")
    ap.add_argument("--interval", type=float, default=2.0, help="rescan seconds")
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--status", action="store_true",
                    help="print a short text digest and exit, writing no HTML")
    ap.add_argument("--usage", default=None,
                    help="ledger path (default: monitor/usage.jsonl beside this script)")
    ap.add_argument("--log-usage", action="store_true",
                    help="append one spend record to the ledger and exit")
    ap.add_argument("--model", help="model name, for --log-usage")
    ap.add_argument("--tok-in", dest="tin", type=int, help="prompt tokens")
    ap.add_argument("--tok-out", dest="tout", type=int, help="completion tokens")
    ap.add_argument("--cost", type=float, help="USD actually charged, if known")
    ap.add_argument("--task", help="what the run was for")
    ap.add_argument("--block", help="block the run was against, if one")
    a = ap.parse_args()

    ledger = a.usage or os.path.join(here, "usage.jsonl")

    if a.log_usage:
        rec = log_usage(ledger, {"model": a.model, "in": a.tin, "out": a.tout,
                                 "cost": a.cost, "task": a.task,
                                 "block": a.block})
        print(f"logged to {ledger}: {json.dumps(rec, sort_keys=True)}")
        return

    if not os.path.isdir(a.root):
        sys.exit(f"root not found: {a.root}")

    if a.status:
        now = time.time()
        blocks = [eval_block(b, a.root, now) for b in discover(a.root)]
        print(status_text(blocks, a.root,
                          usage_summary(a.root, here, a.usage)))
        return

    def build():
        now = time.time()
        blocks = [eval_block(b, a.root, now) for b in discover(a.root)]
        for b in blocks:
            for c in COLS:
                b["gates"][c]["age"] = human_age(b["gates"][c]["mtime"], now)
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(render(blocks, a.root, a.refresh,
                            usage_summary(a.root, here, a.usage),
                            usage_paths(a.root, here, a.usage)))
        return blocks

    def progress(blocks):
        green = sum(b["green"] for b in blocks)
        total = len(COLS) * len(blocks)
        return green, total, (100.0 * green / total if total else 0.0)

    if a.once or not a.watch:
        blocks = build()
        g, t, p = progress(blocks)
        print(f"wrote {a.out}  ({len(blocks)} blocks, {g}/{t} gates green, {p:.0f}%)")
        if not a.watch:
            return

    print(f"watching {a.root}\nwriting  {a.out}\nopen it with file:// - Ctrl-C to stop")
    try:
        while True:
            blocks = build()
            n_ok = sum(1 for b in blocks if b["worst"] == OK)
            g, t, p = progress(blocks)
            print(f"\r{datetime.now():%H:%M:%S}  {len(blocks)} blocks, "
                  f"{n_ok} fully green, {g}/{t} gates, {p:.0f}% complete ",
                  end="", flush=True)
            time.sleep(a.interval)
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
