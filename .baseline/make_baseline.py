#!/usr/bin/env python3
"""生成 / 刷新一份编译基线，并盖上「何时、基于哪个工作树状态」的戳。

为什么需要盖戳
--------------
这个仓在本项目的会话期间被**并发编辑**过（IDE / 另一个 agent / 人手改），实测到
`contracts/System.sol` 在两次基线之间被改成了 B.2.2 的 `uint32 bscChainID = 860621`，
导致 11 份继承 System.sol 的合约字节码同时变化。没有戳的基线无法回答
「这 11 份变化是有人动了源码，还是编译器漂移」——而这两者的处置完全不同。

所以每份基线都记录：
  created_at     生成时刻
  git_head       当时的 HEAD
  dirty_sources  contracts/ 下所有 .sol 的 (path, mtime, sha256)
check_c0.py 会拿当前 mtime/sha256 与基线比对，先报「源码被动过」，再报字节码差异。

用法
----
    FOUNDRY_TEST=/nonexistent-test FOUNDRY_SCRIPT=/nonexistent-script forge build
    python3 .baseline/make_baseline.py --name C1ab-baseline.json --note "..."
"""
import argparse
import datetime
import glob
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACTS = [
    "BSCValidatorSet", "SlashIndicator", "SystemReward", "GovHub", "StakeHub", "StakeCredit",
    "BSCGovernor", "GovToken", "BSCTimelock", "TokenHub", "TendermintLightClient",
    "RelayerIncentivize", "RelayerHub", "TokenManager", "CrossChain", "Staking",
    "TokenRecoverPortal",
]


def sha256_file(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True, help="基线文件名，如 C1ab-baseline.json")
    ap.add_argument("--note", default="")
    args = ap.parse_args()

    rec = {
        "note": args.note,
        "created_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "forge": subprocess.run(["forge", "--version"], capture_output=True, text=True)
        .stdout.strip().splitlines()[0],
        "build_cmd": "FOUNDRY_TEST=/nonexistent-test FOUNDRY_SCRIPT=/nonexistent-script forge build",
        "git_head": subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True
        ).stdout.strip(),
        "compiler_matrix": {},
        "artifacts": {},
        "dirty_sources": {},
    }

    root = os.path.dirname(HERE)
    for path in sorted(glob.glob(os.path.join(root, "contracts", "**", "*.sol"), recursive=True)):
        rel = os.path.relpath(path, root)
        rec["dirty_sources"][rel] = {
            "mtime": datetime.datetime.fromtimestamp(os.path.getmtime(path))
            .astimezone()
            .isoformat(timespec="seconds"),
            "sha256": sha256_file(path),
        }

    for n in CONTRACTS:
        p = os.path.join(root, "out", f"{n}.sol", f"{n}.json")
        if not os.path.exists(p):
            sys.exit(f"缺少产物 {p}（先跑 forge build）")
        with open(p) as f:
            j = json.load(f)
        md = j.get("metadata", {})
        solc = md.get("compiler", {}).get("version", "?")
        evm = md.get("settings", {}).get("evmVersion", "?")
        rec["compiler_matrix"].setdefault(f"solc {solc} / evm {evm}", []).append(n)
        h = j["deployedBytecode"]["object"]
        h = h[2:] if h.startswith("0x") else h
        raw = bytes.fromhex(h) if h else b""
        rec["artifacts"][n] = {
            "solc": solc,
            "evm": evm,
            "bytes": len(raw),
            "sha256": hashlib.sha256(raw).hexdigest(),
        }

    rec["total_bytes"] = sum(v["bytes"] for v in rec["artifacts"].values())

    out_path = os.path.join(HERE, args.name)
    with open(out_path, "w") as f:
        json.dump(rec, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"已写入 {out_path}")
    print(f"  created_at : {rec['created_at']}")
    print(f"  git_head   : {rec['git_head'][:12]}")
    print(f"  contracts  : {len(rec['dirty_sources'])} 份 .sol 已盖戳")
    print(f"  total_bytes: {rec['total_bytes']}")
    for k, v in rec["compiler_matrix"].items():
        print(f"  {k} -> {len(v)} 份")
    return 0


if __name__ == "__main__":
    sys.exit(main())
