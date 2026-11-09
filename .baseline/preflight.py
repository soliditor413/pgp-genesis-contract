#!/usr/bin/env python3
"""Run every gate that stands between this repo and a forked chain.

Five checks, each one of which has already caught something real:

  1. build            forge build compiles at all
  2. bytecode         the 17 deployedBytecode blobs still match the pinned baseline
  3. abi-freshness    abi/*.abi still matches what the source compiles to
  4. abi-crossrepo    every method the node packs exists, in abi/ AND in abi.go
  5. pgp-fixture      the Go encoder and the Solidity decoder agree byte for byte

Checks 2 and 5 compare bytes, and that is the whole point: the 17 contracts'
runtime code and the 6-validator RLP payload both feed block state from the fork
height onwards. One byte different is a different chain.

Number 2 against which baseline matters. `C0-baseline.json` is the state before
C1-a/C1-b touched BSCValidatorSet, so it will always report that contract as
changed. `C1ab-baseline.json` is the state after, and is the right comparison
for every change since. Defaults to C1ab; override with --baseline.

Non-interactive by design: no prompts, no writes, exit 1 on the first failing
gate (after running all of them, so one run tells you everything that is wrong).
Nothing here modifies a file.

Usage:
    python3 .baseline/preflight.py
    python3 .baseline/preflight.py --baseline C0-baseline.json
    python3 .baseline/preflight.py --skip build       # when you just built
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE_DIR = Path(__file__).resolve().parent


def run(label: str, cmd: list[str], cwd: Path, env: dict[str, str] | None = None) -> tuple[bool, str]:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)
    output = (proc.stdout + proc.stderr).strip()
    return proc.returncode == 0, output


def tail(text: str, n: int = 6) -> str:
    lines = [ln for ln in text.splitlines() if ln.strip()]
    return "\n".join("      " + ln for ln in lines[-n:])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument(
        "--baseline", default="C1ab-baseline.json", help="bytecode baseline to compare against (default: C1ab)"
    )
    ap.add_argument(
        "--skip",
        action="append",
        default=[],
        choices=["build", "bytecode", "abi-freshness", "abi-crossrepo", "pgp-fixture"],
        help="skip a gate (repeatable). Skipped gates are reported as SKIP, never as PASS",
    )
    args = ap.parse_args()

    # forge build must not drag test/ into the compilation -- see export-abis.py.
    build_env = dict(os.environ)
    build_env["FOUNDRY_TEST"] = "/nonexistent-test"
    build_env["FOUNDRY_SCRIPT"] = "/nonexistent-script"

    gates: list[tuple[str, list[str], Path, dict[str, str] | None]] = [
        ("build", ["forge", "build"], ROOT, build_env),
        ("bytecode", [sys.executable, str(BASELINE_DIR / "check_c0.py"), "--baseline", args.baseline], ROOT, None),
        ("abi-freshness", [sys.executable, "scripts/export-abis.py", "--check"], ROOT, None),
        ("abi-crossrepo", [sys.executable, str(BASELINE_DIR / "check_abi_crossrepo.py")], ROOT, None),
        ("pgp-fixture", [sys.executable, str(BASELINE_DIR / "check_pgp_fixture.py")], ROOT, None),
    ]

    results: list[tuple[str, str, str]] = []
    failed = False

    for label, cmd, cwd, env in gates:
        if label in args.skip:
            results.append((label, "SKIP", "skipped by --skip"))
            continue
        ok, output = run(label, cmd, cwd, env)
        results.append((label, "PASS" if ok else "FAIL", output))
        if not ok:
            failed = True

    print()
    for label, status, output in results:
        print(f"  [{status:<4}] {label}")
        if status == "FAIL":
            print(tail(output))
        elif status == "SKIP":
            print("      " + output)
    print()

    if failed:
        print("PREFLIGHT FAILED: fix the gates above before regenerating genesis or exporting bytecode.")
        return 1

    skipped = [label for label, status, _ in results if status == "SKIP"]
    if skipped:
        print(f"PREFLIGHT PASSED, but {len(skipped)} gate(s) were skipped ({', '.join(skipped)}).")
        print("A skipped gate is not a passing gate.")
    else:
        print("PREFLIGHT PASSED: all 5 gates green.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
