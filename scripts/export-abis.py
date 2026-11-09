#!/usr/bin/env python3
"""Regenerate the 17 built-in system-contract ABI files under abi/.

Why this exists rather than a shell loop
----------------------------------------
`forge inspect` has three sharp edges, all of them paid for once already (see
the design doc, B.5.4):

  1. Without FOUNDRY_TEST/FOUNDRY_SCRIPT redirected, `forge inspect` compiles
     the whole tree including test/, which imports forge-std. If forge-std is
     not installed locally the command fails for a reason that has nothing to
     do with the ABI.
  2. A bare contract name can match several declarations (the same name often
     exists in contracts/ and in contracts/interface/), so the fully-qualified
     `path:Name` form is mandatory.
  3. Without --json the output is a human-readable table, not JSON.

The output format is also pinned: 2-space indent, which is what `--json`
already produces, so a regeneration only ever yields a *semantic* diff and
never a whitespace diff.

What this does NOT do
---------------------
It does not check that the node still finds the methods it packs. That check
lives in .baseline/check_abi_crossrepo.py, because it is the one that can
actually break the chain, and it must run against the freshly written files.

Usage:
    python3 scripts/export-abis.py            # write abi/*.abi
    python3 scripts/export-abis.py --check    # exit 1 if any file is stale
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ABI_DIR = ROOT / "abi"

# contract name -> source path, exactly as README.md documents it.
# Order matches abi/README.md so the two stay easy to diff by eye.
CONTRACTS: list[tuple[str, str]] = [
    ("BSCValidatorSet", "contracts/BSCValidatorSet.sol"),
    ("SlashIndicator", "contracts/SlashIndicator.sol"),
    ("SystemReward", "contracts/SystemReward.sol"),
    ("TendermintLightClient", "contracts/deprecated/TendermintLightClient.sol"),
    ("TokenHub", "contracts/TokenHub.sol"),
    ("RelayerIncentivize", "contracts/deprecated/RelayerIncentivize.sol"),
    ("RelayerHub", "contracts/deprecated/RelayerHub.sol"),
    ("GovHub", "contracts/GovHub.sol"),
    ("TokenManager", "contracts/deprecated/TokenManager.sol"),
    ("CrossChain", "contracts/deprecated/CrossChain.sol"),
    ("Staking", "contracts/deprecated/Staking.sol"),
    ("StakeHub", "contracts/StakeHub.sol"),
    ("StakeCredit", "contracts/StakeCredit.sol"),
    ("BSCGovernor", "contracts/BSCGovernor.sol"),
    ("GovToken", "contracts/GovToken.sol"),
    ("BSCTimelock", "contracts/BSCTimelock.sol"),
    ("TokenRecoverPortal", "contracts/TokenRecoverPortal.sol"),
]


def abi_filename(contract: str) -> str:
    """abi/bscvalidatorset.abi -- lowercase, no underscores, per abi/README.md."""
    return contract.lower() + ".abi"


def inspect_abi(contract: str, source: str) -> list:
    env = dict(os.environ)
    # Sharp edge 1: keep the test/ and script/ trees out of this compilation.
    env["FOUNDRY_TEST"] = "/nonexistent-test"
    env["FOUNDRY_SCRIPT"] = "/nonexistent-script"

    # Sharp edge 2 and 3: fully-qualified name and --json.
    cmd = ["forge", "inspect", f"{source}:{contract}", "abi", "--json"]
    proc = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(
            f"forge inspect failed for {contract}\n"
            f"  command: {' '.join(cmd)}\n"
            f"  stderr: {proc.stderr.strip()[:2000]}"
        )
    try:
        parsed = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"forge inspect produced non-JSON for {contract}: {exc}")
    if not isinstance(parsed, list):
        raise SystemExit(f"forge inspect produced {type(parsed).__name__} for {contract}, not a list")
    return parsed


def render(abi: list) -> str:
    """Serialize the way `--json` does: 2-space indent, trailing newline."""
    return json.dumps(abi, indent=2) + "\n"


def canonical(abi: list) -> list[str]:
    """Entry set, order-insensitive, keys sorted.

    Why `--check` compares this instead of raw bytes.

    ABI entry order carries no meaning -- every consumer indexes by name and
    signature -- and solc/forge do not promise to preserve declaration order
    across versions. Comparing bytes makes the check red for a reordering that
    changes nothing, which teaches people to ignore it, which is worse than not
    having the check.

    Measured, not hypothetical: on the very first regeneration, `stakehub.abi`
    came out with 24 lines moved and was canonically identical to what was
    committed. Sixteen of seventeen files had real semantic diffs; that one was
    pure churn. Byte comparison would have called it a change.

    The writer still emits forge's native order, so the file stays a direct
    artifact with no post-processing step of its own to drift.
    """
    return sorted(json.dumps(entry, sort_keys=True) for entry in abi)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="do not write; exit 1 if any abi/*.abi is stale")
    args = ap.parse_args()

    # Not mkdir(exist_ok=True): some sandboxed Python shims raise EEXIST anyway.
    if not ABI_DIR.is_dir():
        ABI_DIR.mkdir(parents=True)

    stale: list[str] = []
    rows: list[tuple[str, str, int, int]] = []

    for contract, source in CONTRACTS:
        abi = inspect_abi(contract, source)
        text = render(abi)
        path = ABI_DIR / abi_filename(contract)

        old_count = 0
        old_canonical: list[str] | None = None
        if path.exists():
            try:
                old_abi = json.loads(path.read_text())
                old_count = len(old_abi)
                old_canonical = canonical(old_abi)
            except json.JSONDecodeError:
                old_count = -1
        new_count = len(abi)

        changed = old_canonical != canonical(abi)
        if changed:
            stale.append(contract)
            if not args.check:
                path.write_text(text)
        rows.append((contract, abi_filename(contract), old_count, new_count))

    flag = "Would rewrite" if args.check else "Rewrote"
    print(f"{'contract':<24} {'file':<26} {'old':>4} {'new':>4}  state")
    print("-" * 74)
    for contract, name, old, new in rows:
        state = "stale" if contract in stale else "up to date"
        delta = f" ({new - old:+d})" if old and old != new else ""
        print(f"{contract:<24} {name:<26} {old:>4} {new:>4}  {state}{delta}")
    print("-" * 74)
    print(f"{len(rows)} contracts, {len(stale)} stale")

    if args.check:
        if stale:
            print(f"\n{flag} nothing (--check is read-only). Run without --check to regenerate:")
            print("  python3 scripts/export-abis.py")
            return 1
        return 0

    print(f"\n{flag} {len(stale)} of {len(rows)} files under abi/")
    if stale:
        print("Next: python3 .baseline/check_abi_crossrepo.py   # does the node still find what it packs?")
    return 0


if __name__ == "__main__":
    sys.exit(main())
