#!/usr/bin/env python3
"""从 validators-dev.conf 生成 PGP devnet 的 genesis config 片段。

为什么需要这个脚本
------------------
`INIT_VALIDATORSET_BYTES` / `INIT_NUM_OF_CABINETS` 已经不在合约里当编译期常量了
（BSCValidatorSet.init(bytes,uint256) 改为由节点传参）。验证人名单的唯一真源因此变成了
chain config —— 本脚本负责把「人读的 conf」翻译成「genesis 里的字段」，顺带把
RLP payload 算出来，好让评审时能对一个确定的哈希。

它不产出 Solidity 补丁，也不参与 forge 编译。这一点是刻意的：只要名单不进字节码，
「6 席 / 21 席两套码选错就分叉」这个失效模式就根本不存在。

字段顺序的三个坑（都踩过）
--------------------------
1. conf 列序是 `consensusAddr,feeAddr,bscFeeAddr,votingPower,bLSPublicKey`，
   但进 RLP 的顺序是 `[consensus, bscFeeAddr, feeAddr, votingPower]`。
   合约 `decodeValidator` 把 idx1 叫 feeAddress、idx2 叫 BBCFeeAddress ——
   名字对不上、顺序兼容。按名字对齐会把两个地址编反。
2. `packageType = 0` 必须编成 **0x80**（空串），不是 0x00。
   证据：BSC 主网自己的 INIT 字节以 `f905ec 80 f905e8` 开头。
   这里编错不影响合约解码（两者都解出 0），但会让 payload 哈希与别人不同，
   跨实现对齐时会白查一天。
3. 行顺序 = 共识。RLP 按行序编，调换两行 ⇒ H 块状态根不同 ⇒ 分叉。

工具链里为什么还留着 JS 版
--------------------------
`scripts/validators.js` / `validators.template` 已退出构建链，只作为「第二意见」：
对同一份 conf，JS 与 Go 编码器的输出应当逐字节相同（§B.9.6 G5）。
本脚本是第三个独立实现，用来交叉验证前两个。
"""
import argparse
import json
import os
import re
import sys

ADDR_RE = re.compile(r"^(0x)?[0-9a-fA-F]{40}$")


# ---------------------------------------------------------------- RLP (minimal)
def _rlp_length_prefix(length: int, offset: int) -> bytes:
    """RLP 的长度前缀：短形式 (offset+len) 单字节，长形式 (offset+55+lenlen) + 长度。"""
    if length < 56:
        return bytes([offset + length])
    encoded = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([offset + 55 + len(encoded)]) + encoded


def rlp_bytes(payload: bytes) -> bytes:
    """RLP 编码一个 byte string。"""
    if len(payload) == 1 and payload[0] < 0x80:
        return payload  # 单字节且 < 0x80：就是它自己
    return _rlp_length_prefix(len(payload), 0x80) + payload


def rlp_uint(value: int) -> bytes:
    """RLP 编码一个无符号整数（最小大端）。0 编成 0x80 —— 与 ethereumjs / geth 一致。"""
    if value == 0:
        return b"\x80"
    return rlp_bytes(value.to_bytes((value.bit_length() + 7) // 8, "big"))


def rlp_list(items: list[bytes]) -> bytes:
    """RLP 编码一个列表（元素须已编码）。"""
    body = b"".join(items)
    return _rlp_length_prefix(len(body), 0xC0) + body


# ---------------------------------------------------------------- conf 解析
def parse_conf(path: str) -> list[dict]:
    entries = []
    with open(path) as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line:
                continue
            # generate.py 的 generate_validators 不跳过注释，这里也不跳 ——
            # 宁可报错，也不要让「同一个 conf 被两个工具读出两种结果」。
            cols = line.split(",")
            if len(cols) != 5:
                sys.exit(f"{path}:{lineno} 需要 5 个字段（consensusAddr,feeAddr,bscFeeAddr,votingPower,bLSPublicKey），实际 {len(cols)}")
            consensus, fee, bsc_fee, power, bls = (c.strip() for c in cols)
            for label, addr in (("consensusAddr", consensus), ("feeAddr", fee), ("bscFeeAddr", bsc_fee)):
                if not ADDR_RE.match(addr):
                    sys.exit(f"{path}:{lineno} {label} 不是合法 40 位 hex 地址: {addr!r}")
            if not power.isdigit():
                sys.exit(f"{path}:{lineno} votingPower 必须是十进制整数: {power!r}")
            if bls not in ("-", ""):
                sys.exit(
                    f"{path}:{lineno} 本脚本只生成 4 元组（无 BLS）。"
                    f"如果确实要给真 BLS key，需要同时改合约侧的零 BLS 假设，见 §5.4"
                )
            entries.append(
                {
                    "consensusAddr": "0x" + consensus.lower().removeprefix("0x"),
                    "feeAddr": "0x" + fee.lower().removeprefix("0x"),
                    "bscFeeAddr": "0x" + bsc_fee.lower().removeprefix("0x"),
                    "votingPower": int(power),
                    "line": lineno,
                }
            )
    if not entries:
        sys.exit(f"{path} 里没有任何验证人")
    return entries


def validate(entries: list[dict], epoch: int, fork_height: int, cabinets: int) -> None:
    seen = {}
    for e in entries:
        a = e["consensusAddr"]
        if set(a[2:]) == {"0"}:
            sys.exit(f"第 {e['line']} 行是零地址，拒绝")
        if e["votingPower"] == 0:
            sys.exit(f"第 {e['line']} 行 votingPower 为 0，Parlia 会算出零权重")
        if a in seen:
            sys.exit(f"第 {e['line']} 行与第 {seen[a]} 行 consensusAddr 重复")
        seen[a] = e["line"]
    n = len(entries)
    if cabinets != n:
        sys.exit(f"parliaGenesisCabinets={cabinets} 与验证人数 {n} 不一致；devnet 阶段两者必须相等")
    if n > 255:
        sys.exit(f"验证人数 {n} > 255：header extra 的 count 字节是 uint8，装不下")
    if epoch <= 0:
        sys.exit("epoch 必须 > 0")
    if fork_height % epoch == 0:
        # D9：H 落在 epoch 块上会让 H 块要求带验证人列表，而那时合约刚写入、还没初始化
        sys.exit(
            f"ForkHeight={fork_height} 是 epoch({epoch}) 的整数倍。"
            f"请选一个不是 epoch 倍数的高度（当前 H%{epoch}={fork_height % epoch}）"
        )


def build_payload(entries: list[dict]) -> bytes:
    """RLP([0x00, [[consensus, bscFeeAddr, feeAddr, votingPower] x N]]) —— 4 元组。"""
    validators = []
    for e in entries:
        validators.append(
            rlp_list(
                [
                    rlp_bytes(bytes.fromhex(e["consensusAddr"][2:])),
                    # ⚠️ 顺序：bscFeeAddr 在前、feeAddr 在后（见文件头「坑 1」）
                    rlp_bytes(bytes.fromhex(e["bscFeeAddr"][2:])),
                    rlp_bytes(bytes.fromhex(e["feeAddr"][2:])),
                    rlp_uint(e["votingPower"]),
                ]
            )
        )
    return rlp_list([rlp_uint(0), rlp_list(validators)])


def build_fragment(entries, fork_height, epoch, cabinets, chain_id) -> dict:
    return {
        # ParliaConfig 是空结构体，只要有这个 key 就代表「Parlia 已启用」
        "parlia": {},
        # 现代档：Luban / Plato / Hertz 与共识分叉同高度激活（§5.1）
        "lubanBlock": fork_height,
        "platoBlock": fork_height,
        "hertzBlock": fork_height,
        # 时间类分叉（keplerTime / feynmanTime / lorentzTime / bohrTime…）故意不写：
        # devnet 是全新链，1100 块的真实时间戳要跑到才知道，genesis 里无法预先钉死。
        # Feynman 本来就要拆到 H2（§5.5）；Kepler/Lorentz 的启用留到能拿到 H 时间戳之后。
        "legacy": {
            "forkHeight": fork_height,
            "parliaGenesisValidators": [e["consensusAddr"] for e in entries],
            "parliaGenesisVotingPowers": [e["votingPower"] for e in entries],
            "parliaGenesisCabinets": cabinets,
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="生成 PGP devnet 的 genesis config 片段")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--conf", default=os.path.join(here, "validators-dev.conf"))
    ap.add_argument("--fork-height", type=int, default=1100)
    ap.add_argument("--epoch", type=int, default=500)
    ap.add_argument("--cabinets", type=int, default=0, help="0 = 取 conf 行数")
    ap.add_argument("--chain-id", type=int, default=8606211, help="devnet 的 chainId（主网是 860621）")
    ap.add_argument("--out", default=os.path.join(here, "pgp-devnet-config.fragment.json"))
    ap.add_argument("--patch", help="把片段合并进指定的 genesis.json（原地改写，先自己备份）")
    args = ap.parse_args()

    entries = parse_conf(args.conf)
    cabinets = args.cabinets or len(entries)
    validate(entries, args.epoch, args.fork_height, cabinets)

    fragment = build_fragment(entries, args.fork_height, args.epoch, cabinets, args.chain_id)
    payload = build_payload(entries)

    with open(args.out, "w") as f:
        json.dump(fragment, f, indent=2, ensure_ascii=False)
        f.write("\n")

    first_epoch = ((args.fork_height + args.epoch - 1) // args.epoch) * args.epoch
    print(f"验证人         : {len(entries)} 席")
    for i, e in enumerate(entries):
        print(f"  [{i}] {e['consensusAddr']}  power={e['votingPower']}")
    print(f"ForkHeight     : {args.fork_height}  (H%{args.epoch}={args.fork_height % args.epoch}，非 epoch 块 ✓)")
    print(f"首个 epoch 块  : {first_epoch}  该块 extra 长度 = 32+1+{len(entries)}*68+65 = {32 + 1 + len(entries) * 68 + 65}")
    print(f"cabinets       : {cabinets}")
    print(f"payload 长度   : {len(payload)} 字节（4 元组，无 BLS）")
    print(f"payload hex    : 0x{payload.hex()}")
    print(f"指纹（评审用） : cast keccak 0x{payload.hex()}")
    print(f"片段已写入     : {args.out}")

    if args.patch:
        with open(args.patch) as f:
            genesis = json.load(f)
        cfg = genesis.setdefault("config", {})
        # 顶层键直接覆盖；legacy 是嵌套结构，逐键合并，保留原有的 gasFeeRecipient 等
        for k, v in fragment.items():
            if k == "legacy":
                cfg.setdefault("legacy", {}).update(v)
            else:
                cfg[k] = v
        with open(args.patch, "w") as f:
            json.dump(genesis, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print(f"已合并进       : {args.patch}")
        print("                （legacy 段是逐键合并，原有 gasFeeRecipient / producers 等保留）")

    return 0


if __name__ == "__main__":
    sys.exit(main())
