#!/usr/bin/env python3
"""C1-d 跨仓一致性：Go 编码器产出的 golden fixture 必须与合约仓读到的那份逐字节相同。

为什么需要这个脚本
------------------
golden fixture 同时存在于两个 git 仓：

    bsc/consensus/parlia/testdata/pgp_validators_N.hex      <- 由 Go 侧 -update-golden 写入
    bsc-genesis-contract/test/fixtures/pgp_validators_N.hex <- 由 test/PGPValidatorInit.t.sol 读取

两仓可以独立 clone，所以不能靠跨仓相对路径共享一份文件——那条相对路径在单独 clone
任一仓时会直接断掉。代价就是两份副本可能漂移：

    Go 编码器改了 -> 只跑了 `-update-golden` -> 只更新了 bsc 仓那一份
    -> Solidity 测试继续在验证「旧字节」并通过 -> 真正的链路早就断了，测试却是绿的

这是最难自查的一类失败：两个测试都绿，链路是断的。本脚本用逐字节比对把这条缝钉死。

当前覆盖两份 fixture：

    pgp_validators_6.hex    6 席 devnet，403 B，哈希已写入设计文档
    pgp_validators_21.hex   21 席（主网规模，地址为合成值），1393 B，用来证明没有硬编码席位

用法
----
    python3 .baseline/check_pgp_fixture.py

退出码 0 = 全部一致；1 = 漂移或缺失。适合直接放进 CI。

依赖
----
只依赖标准库。keccak256 优先用 `cast keccak`，其次用 `node + ethers`，两者都没有就跳过
哈希校验（仍然做逐字节比对并明确打印「哈希未校验」，不静默降级）。
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACT_REPO = os.path.dirname(HERE)
WORKSPACE = os.path.dirname(CONTRACT_REPO)

GO_DIR = os.path.join(WORKSPACE, "bsc", "consensus", "parlia", "testdata")
SOL_DIR = os.path.join(CONTRACT_REPO, "test", "fixtures")

# 设计文档 C1-c 记录的 6 席 payload 哈希，由 scripts/gen-pgp-genesis-config.py 独立产生。
# 21 席的地址是合成值，没有「独立实现」可对账，所以只校验长度与结构。
PINNED_HASH_6 = "0xe18ed4d5bd8063537f924de9a7700ec2343d4c5c48de231bc704d15aed46ce03"

# name -> (字节数, 席位, 必须匹配的哈希或 None)
FIXTURES = {
    "pgp_validators_6.hex": (403, 6, PINNED_HASH_6),
    "pgp_validators_21.hex": (1393, 21, None),
}


def load(path: str) -> bytes:
    """读入 fixture，去掉 0x 前缀、空白与换行，返回原始字节。"""
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    text = text.strip()
    if text[:2].lower() == "0x":
        text = text[2:]
    text = "".join(text.split())
    try:
        return bytes.fromhex(text)
    except ValueError as e:
        raise SystemExit(f"FAIL {path}: 不是合法 hex ({e})")


def keccak256(blob: bytes):
    """算 keccak256。优先 cast，其次 node+ethers，都不行返回 None。"""
    arg = "0x" + blob.hex()

    cast = shutil.which("cast")
    if cast:
        try:
            out = subprocess.run([cast, "keccak", arg], capture_output=True, text=True, timeout=30)
            if out.returncode == 0:
                return out.stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            pass

    node = shutil.which("node")
    if node:
        script = 'const {ethers}=require("ethers");process.stdout.write(ethers.keccak256(process.argv[1]));'
        try:
            out = subprocess.run(
                [node, "-e", script, arg],
                capture_output=True,
                text=True,
                timeout=30,
                cwd=CONTRACT_REPO,  # node_modules/ethers 在这里
            )
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            pass

    return None


def check_one(name: str, expect_bytes: int, seats: int, pinned_hash):
    """返回 True 表示这一份通过。任何一项不过都打印原因并返回 False。"""
    go_path = os.path.join(GO_DIR, name)
    sol_path = os.path.join(SOL_DIR, name)

    print(f"\n== {name} ==")
    for path in (go_path, sol_path):
        if not os.path.exists(path):
            print(f"FAIL 缺失: {path}")
            return False

    go_blob = load(go_path)
    sol_blob = load(sol_path)
    print(f"  Go  : {len(go_blob):>5} B")
    print(f"  Sol : {len(sol_blob):>5} B")

    # 1) 两份副本逐字节一致 —— 这是本脚本存在的理由
    if go_blob != sol_blob:
        print("  FAIL 两份 fixture 不一致——链路已断：")
        for i, (a, b) in enumerate(zip(go_blob, sol_blob)):
            if a != b:
                print(f"       首个差异在偏移 {i}: go=0x{a:02x} sol=0x{b:02x}")
                break
        else:
            print(f"       前缀相同，长度不同（go={len(go_blob)} sol={len(sol_blob)}）")
        print("       修复：在 bsc 仓跑 `go test ./consensus/parlia/ -run Golden -update-golden`，")
        print("             然后把 testdata/*.hex 原样复制到 bsc-genesis-contract/test/fixtures/")
        return False
    print("  OK   两份 fixture 逐字节一致")

    # 2) 长度
    if len(go_blob) != expect_bytes:
        print(f"  FAIL 长度 {len(go_blob)} B，期望 {expect_bytes} B（{seats} 席）")
        return False
    print(f"  OK   长度 {expect_bytes} B（{seats} 席）")

    # 3) 结构：外层列表头 + packageType，以及席位数字节宽度
    #    6 席：f9 01 90 80（外层 body 400 B）
    #    21 席：f9 05 6e 80（外层 body 1390 B）
    if go_blob[0] != 0xF9:
        print(f"  FAIL 外层列表前缀 0x{go_blob[0]:02x}，期望 0xf9（长格式）")
        return False
    body_len = int.from_bytes(go_blob[1:3], "big")
    if body_len != len(go_blob) - 3:
        print(f"  FAIL 外层声明 body {body_len} B，实际 {len(go_blob) - 3} B")
        return False
    if go_blob[3] != 0x80:
        print(f"  FAIL packageType 编成了 0x{go_blob[3]:02x}，必须是 0x80（RLP 空串）")
        return False
    # 每席 66 B（f8 40 + 64 B 元组），内层列表头 3 B，packageType 1 B，合计外层 body
    expect_body = 1 + 3 + seats * 66
    if body_len != expect_body:
        print(f"  FAIL 外层 body {body_len} B，期望 1 + 3 + {seats}*66 = {expect_body} B")
        return False
    print(f"  OK   结构 f9 {go_blob[1]:02x} {go_blob[2]:02x} 80，{seats} 席 × 66 B")

    # 4) 哈希（仅对有人工独立实现可对账的 fixture）
    digest = keccak256(go_blob)
    if digest is None:
        if pinned_hash:
            print("  WARN 找不到 cast 或 node+ethers，跳过了 keccak256 校验（逐字节比对已完成）")
        else:
            print("  --   无需哈希校验（合成地址，无独立实现可对账）")
    else:
        print(f"  keccak256 = {digest}")
        if pinned_hash and digest.lower() != pinned_hash:
            print(f"  FAIL 与设计文档记录的 {pinned_hash} 不符")
            print("       若是有意改编码器，需同时更新：设计文档、Go 的 pinnedDevnetPayloadHash、")
            print("       test/PGPValidatorInit.t.sol 的 PINNED_PAYLOAD_HASH、本脚本的 PINNED_HASH_6")
            return False
        if pinned_hash:
            print("  OK   与设计文档记录一致")

    return True


def main() -> int:
    print(f"workspace        : {WORKSPACE}")
    print(f"contract repo    : {CONTRACT_REPO}")

    ok = True
    for name, (expect_bytes, seats, pinned) in FIXTURES.items():
        ok = check_one(name, expect_bytes, seats, pinned) and ok

    print()
    if not ok:
        print("=> FAIL：Go 编码器与 Solidity 解码器已不指向同一份字节。")
        return 1
    print("=> OK：C1-d fixture 全部一致，Go 编码器与 Solidity 解码器指向同一份字节。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
