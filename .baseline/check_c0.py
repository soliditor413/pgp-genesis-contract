#!/usr/bin/env python3
"""C0 编译基线比对器。

用途：任何改动（C2 删除、C3 导出、参数调整）之后重跑 forge build，再用本脚本比对
      out/ 里 17 份合约的 deployedBytecode 与 C0 基线是否逐字节一致。

判据：17 份 sha256 全部相等 -> exit 0；任意一份不等 -> exit 1 并指出是哪几份。

      「C2 删完产物逐字节不变」这条验收就是靠它证明的：它同时证明了删掉的确实是孤儿。

用法：
    FOUNDRY_TEST=/nonexistent-test FOUNDRY_SCRIPT=/nonexistent-script forge build
    python3 .baseline/check_c0.py
    python3 .baseline/check_c0.py --allow BSCValidatorSet   # C1 有意改动时放行指定合约
"""
import argparse
import hashlib
import json
import os
import sys

BASELINE_DIR = os.path.dirname(os.path.abspath(__file__))
OUT = "out"


def deployed_bytes(contract: str) -> bytes:
    path = os.path.join(OUT, f"{contract}.sol", f"{contract}.json")
    if not os.path.exists(path):
        raise SystemExit(f"缺少产物：{path}（先跑 forge build）")
    with open(path) as f:
        obj = json.load(f)["deployedBytecode"]["object"]
    h = obj[2:] if obj.startswith("0x") else obj
    return bytes.fromhex(h) if h else b""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--baseline",
        default="C0-baseline.json",
        help="基线文件名（相对 .baseline/）。C0=改合约前，C1a=init 参数化之后",
    )
    ap.add_argument(
        "--allow",
        action="append",
        default=[],
        metavar="CONTRACT",
        help="本次有意改动的合约名（可重复），放行其 sha256 变化但仍打印 diff",
    )
    args = ap.parse_args()

    baseline_path = os.path.join(BASELINE_DIR, args.baseline)
    if not os.path.exists(baseline_path):
        raise SystemExit(f"找不到基线：{baseline_path}")
    with open(baseline_path) as f:
        base = json.load(f)

    # 先报「源码被动过」，再报字节码差异 —— 顺序很重要：
    # 源码变更和编译器漂移都表现为字节码变化，但处置完全不同（前者要评审、后者要钉工具链）。
    src_changed = []
    for rel, want in (base.get("dirty_sources") or {}).items():
        cur = os.path.join(os.path.dirname(BASELINE_DIR), rel)
        if not os.path.exists(cur):
            src_changed.append(f"{rel} (已删除)")
            continue
        got = hashlib.sha256(open(cur, "rb").read()).hexdigest()
        if got != want["sha256"]:
            src_changed.append(rel)
    if src_changed:
        print(f"SOURCE DRIFT 相对基线 {args.baseline}（{base.get('created_at','?')}）：")
        for s in src_changed[:12]:
            print(f"    {s}")
        if len(src_changed) > 12:
            print(f"    … 另有 {len(src_changed) - 12} 份")
        print("    => 这些源码被改过。字节码差异由源码变更引起，不是编译器漂移。\n")

    same, changed, allowed = [], [], []
    for name, want in base["artifacts"].items():
        try:
            raw = deployed_bytes(name)
        except SystemExit as e:
            print(f"MISSING  {name}: {e}")
            changed.append(name)
            continue
        got = hashlib.sha256(raw).hexdigest()
        if got == want["sha256"]:
            same.append(name)
        elif name in args.allow:
            allowed.append((name, want["sha256"], got, want["bytes"], len(raw)))
        else:
            changed.append(name)
            print(
                f"CHANGED  {name:24} bytes {want['bytes']} -> {len(raw)}   "
                f"{want['sha256'][:16]} -> {got[:16]}"
            )

    for name, old, new, ob, nb in allowed:
        print(f"ALLOWED  {name:24} bytes {ob} -> {nb}   {old[:16]} -> {new[:16]}")

    print(
        f"\n基线 {len(base['artifacts'])} 份：不变 {len(same)}、"
        f"放行 {len(allowed)}、意外变化 {len(changed)}"
    )
    if changed:
        print("意外变化：" + ", ".join(changed))
        print("=> 这些字节会被写进 H 块状态，任何变化都会让链分叉。要么改回来，要么按 C5 走签核。")
        return 1
    print("=> 逐字节一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
