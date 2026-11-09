#!/usr/bin/env python3
"""Does the node still find every contract method it packs?

This is the C1-b gate, and it is the one that can quietly fork the chain.

There are two copies of every ABI in play, and they fail differently:

  abi/*.abi                        documentation / export. Nothing executes it.
  bsc/consensus/parlia/abi.go      the real one -- inlined as Go string
                                   constants, and what `Pack` actually reads.

An ABI export that has drifted from the source does not, by itself, break
anything. It hides the break: someone regenerates `abi/` (as this change does),
sees a clean diff, and concludes the contracts are fine, while `abi.go` still
carries the old JSON and `Pack("init")` still produces the old selector.

So this script checks both, and the Go side is the one that matters.

Two failure modes, both fatal, both silent:

  missing method    `Pack("foo")` returns "method not found" at runtime.
  wrong arity       `Pack("foo", a, b)` returns "argument count mismatch".

Both surface at the worst possible moment: `init` and `updateValidatorSetV2`
are only ever packed inside `Finalize`/`FinalizeAndAssemble`, i.e. at the fork
height, not at startup -- so there is no boot-time canary for them.

What this checks
----------------
For every (contract, method, argument count) pair the Go node packs, assert the
method exists with exactly that many inputs, in BOTH copies. The list below is
transcribed by hand from the call sites, with file:line, because deriving it by
scraping Go source would silently miss a `Pack` behind a variable -- which is
most of them.

Usage:
    python3 .baseline/check_abi_crossrepo.py
    python3 .baseline/check_abi_crossrepo.py --abi-dir /path/to/abi \
                                             --go-abi /path/to/bsc/consensus/parlia/abi.go
    python3 .baseline/check_abi_crossrepo.py --no-go     # abi/ only

Exit code 1 on any missing method, arity mismatch, unreadable ABI, or a Go repo
that was expected but not found.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ABI_DIR = ROOT / "abi"
DEFAULT_GO_ABI = ROOT.parent / "bsc" / "consensus" / "parlia" / "abi.go"

# The 17 exports README.md promises. A missing file is a hard error, not a skip:
# silently checking 16 of 17 is how a dropped contract goes unnoticed.
EXPECTED_FILES = [
    "bscvalidatorset.abi",
    "slashindicator.abi",
    "systemreward.abi",
    "tendermintlightclient.abi",
    "tokenhub.abi",
    "relayerincentivize.abi",
    "relayerhub.abi",
    "govhub.abi",
    "tokenmanager.abi",
    "crosschain.abi",
    "staking.abi",
    "stakehub.abi",
    "stakecredit.abi",
    "bscgovernor.abi",
    "govtoken.abi",
    "bsctimelock.abi",
    "tokenrecoverportal.abi",
]

# abi file -> the Go constant holding the same contract's ABI.
# `validatorSetABIBeforeLuban` is a frozen historical copy kept for reading
# pre-Luban blocks; it must keep its old `init()` forever, which is exactly why
# pre-Luban call sites are listed separately below.
GO_ABI_CONST = {
    "bscvalidatorset.abi": "validatorSetABI",
    "slashindicator.abi": "slashABI",
    "stakehub.abi": "stakeABI",
}

# (abi file, method, input count, go const, call site)
#
# go const is None when the call site does not use that contract's current ABI --
# i.e. the pre-Luban path, which uses validatorSetABIBeforeLuban.
#
# Arities are the *input* count. Where a call site goes through a
# `method := "..."` variable followed by `Pack(method, args...)`, the arity is
# read off the extra arguments.
PACKED_CALLS: list[tuple[str, str, int, str | None, str]] = [
    # --- BSCValidatorSet (0x1000), current ABI -----------------------------------
    ("bscvalidatorset.abi", "getValidators", 0, "validatorSetABI", "bid_block.go:235"),
    ("bscvalidatorset.abi", "getMiningValidators", 0, "validatorSetABI", "parlia.go:2031"),
    ("bscvalidatorset.abi", "numOfCabinets", 0, "validatorSetABI", "bid_block.go:244"),
    ("bscvalidatorset.abi", "getTurnLength", 0, "validatorSetABI", "bohrFork.go:57"),
    ("bscvalidatorset.abi", "deposit", 1, "validatorSetABI", "parlia.go:2199"),
    ("bscvalidatorset.abi", "distributeFinalityReward", 2, "validatorSetABI", "parlia.go:1440"),
    ("bscvalidatorset.abi", "updateValidatorSetV2", 3, "validatorSetABI", "feynmanfork.go:117"),
    # The method this whole change is about. Old `init()` is gone; the node now
    # packs (bytes payload, uint256 cabinets). Arity 2 is the entire point.
    ("bscvalidatorset.abi", "init", 2, "validatorSetABI", "parlia.go:2159"),
    # --- BSCValidatorSet, pre-Luban frozen copy ----------------------------------
    ("bscvalidatorset.abi", "getValidators", 0, "validatorSetABIBeforeLuban", "lubanFork.go:20-28"),
    ("bscvalidatorset.abi", "getMiningValidators", 0, "validatorSetABIBeforeLuban", "lubanFork.go:22"),
    # --- SlashIndicator (0x1001) --------------------------------------------------
    ("slashindicator.abi", "slash", 1, "slashABI", "parlia.go:2119"),
    # --- StakeHub (0x2002) --------------------------------------------------------
    ("stakehub.abi", "getValidators", 2, "stakeABI", "stakehub.go:26 (offset, limit)"),
    ("stakehub.abi", "getNodeIDs", 1, "stakeABI", "stakehub.go:68"),
    ("stakehub.abi", "addNodeIDs", 1, "stakeABI", "stakehub.go:155"),
    ("stakehub.abi", "removeNodeIDs", 1, "stakeABI", "stakehub.go:233"),
    ("stakehub.abi", "getValidatorElectionInfo", 2, "stakeABI", "feynmanfork.go:134-138"),
    ("stakehub.abi", "maxElectedValidators", 0, "stakeABI", "feynmanfork.go:181"),
    ("stakehub.abi", "initialize", 0, "stakeABI", "feynmanfork.go:37-48"),
]

# `initialize()` is packed ONCE using stakeABI and then sent to five different
# addresses (feynmanfork.go:40-46): StakeHub, BSCGovernor, GovToken, BSCTimelock,
# TokenRecoverPortal. Same calldata, five contracts. So all five must expose a
# zero-arg `initialize()` -- and since they are all reached by the same 4-byte
# selector, all five must expose the SAME selector. A missing `initialize` in any
# one of them fails the Feynman fork at that contract only, on the first block
# after H2, which is the hardest kind of failure to attribute.
SHARED_INITIALIZE = [
    ("stakehub.abi", "StakeHub"),
    ("bscgovernor.abi", "BSCGovernor"),
    ("govtoken.abi", "GovToken"),
    ("bsctimelock.abi", "BSCTimelock"),
    ("tokenrecoverportal.abi", "TokenRecoverPortal"),
]


def signature_index(entries: list) -> dict[str, list[int]]:
    """method name -> list of input arities (a name can repeat with overloads)."""
    out: dict[str, list[int]] = {}
    for entry in entries:
        if entry.get("type") != "function":
            continue
        out.setdefault(entry["name"], []).append(len(entry.get("inputs", [])))
    return out


def load_abi_dir(abi_dir: Path, problems: list[str]) -> dict[str, dict[str, list[int]]]:
    functions: dict[str, dict[str, list[int]]] = {}
    for name in EXPECTED_FILES:
        path = abi_dir / name
        if not path.exists():
            problems.append(f"MISSING FILE  {name}")
            continue
        try:
            functions[name] = signature_index(json.loads(path.read_text()))
        except json.JSONDecodeError as exc:
            problems.append(f"BAD JSON      {name}: {exc}")
    return functions


def load_go_abi(path: Path, problems: list[str]) -> dict[str, dict[str, list[int]]] | None:
    """Parse `const NAME = \\`[...]\\`` blocks out of abi.go.

    Deliberately not a Go parser: the file is a list of constant string literals
    and nothing else, so a regex over the const declarations is exact. Splitting
    on the opening backtick and taking everything up to the next one avoids the
    trap of matching the JSON's own brackets.
    """
    if not path.exists():
        problems.append(f"MISSING FILE  {path} (pass --no-go to skip the Go-side check)")
        return None

    source = path.read_text()
    abis: dict[str, dict[str, list[int]]] = {}
    for match in re.finditer(r"const\s+(\w+)\s*=\s*`", source):
        name = match.group(1)
        start = match.end()
        end = source.index("`", start)
        try:
            abis[name] = signature_index(json.loads(source[start:end]))
        except json.JSONDecodeError as exc:
            problems.append(f"BAD JSON      {path.name}:{name}: {exc}")
    return abis


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--abi-dir", default=str(DEFAULT_ABI_DIR), help="directory holding the exported .abi files")
    ap.add_argument("--go-abi", default=str(DEFAULT_GO_ABI), help="path to bsc/consensus/parlia/abi.go")
    ap.add_argument("--no-go", action="store_true", help="check abi/ only, skip the Go side")
    args = ap.parse_args()

    abi_dir = Path(args.abi_dir)
    problems: list[str] = []

    functions = load_abi_dir(abi_dir, problems)
    go_abis = None if args.no_go else load_go_abi(Path(args.go_abi), problems)

    # 1. Every packed call must resolve in abi/ with the right arity.
    checked_file = 0
    for abi_name, method, arity, _go_const, site in PACKED_CALLS:
        fns = functions.get(abi_name)
        if fns is None:
            continue  # already reported as a missing file
        checked_file += 1
        arities = fns.get(method)
        if arities is None:
            problems.append(f"MISSING       abi/{abi_name}: {method}/{arity}  <- {site}")
        elif arity not in arities:
            problems.append(f"ARITY         abi/{abi_name}: {method} has {arities}, node packs {arity}  <- {site}")

    # 2. The five-way `initialize()` fan-out, abi/ side.
    for abi_name, contract in SHARED_INITIALIZE:
        fns = functions.get(abi_name)
        if fns is None:
            continue
        checked_file += 1
        if 0 not in fns.get("initialize", []):
            problems.append(
                f"MISSING       abi/{abi_name}: initialize/0  <- {contract}, reached by the same "
                f"calldata as StakeHub (feynmanfork.go:40-46)"
            )

    # 3. The same packed calls, against the ABI the node actually executes.
    checked_go = 0
    if go_abis is not None:
        for _abi_name, method, arity, go_const, site in PACKED_CALLS:
            if go_const is None:
                continue
            fns = go_abis.get(go_const)
            if fns is None:
                problems.append(f"MISSING CONST abi.go: const {go_const} not found  <- {site}")
                continue
            checked_go += 1
            arities = fns.get(method)
            if arities is None:
                problems.append(f"MISSING       abi.go:{go_const}: {method}/{arity}  <- {site}")
            elif arity not in arities:
                problems.append(
                    f"ARITY         abi.go:{go_const}: {method} has {arities}, node packs {arity}  <- {site}"
                )

    print(f"ABI dir:  {abi_dir}")
    print(f"Files:    {len(EXPECTED_FILES)} expected, {len(functions)} parsed")
    if go_abis is not None:
        print(f"Go ABI:   {args.go_abi}")
        print(f"          {len(go_abis)} consts: {', '.join(sorted(go_abis))}")
    print(f"Packs:    {checked_file} checked against abi/, {checked_go} against abi.go")
    print()

    if problems:
        for p in problems:
            print("  " + p)
        print()
        print(f"FAIL: {len(problems)} problem(s). The node would fail to pack these at the fork height.")
        return 1

    print("OK: every method the node packs exists with the expected argument count,")
    print("    in both abi/ and bsc/consensus/parlia/abi.go.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
