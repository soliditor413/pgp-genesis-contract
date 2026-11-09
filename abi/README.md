# ABI Files for Build-In System Contracts

| Contract Name         | Address                                    | ABI file name                                      |
| --------------------- | ------------------------------------------ | -------------------------------------------------- |
| BSCValidatorSet       | 0x0000000000000000000000000000000000001000 | [bscvalidatorset](bscvalidatorset.abi)             |
| SlashIndicator        | 0x0000000000000000000000000000000000001001 | [slashindicator](slashindicator.abi)               |
| SystemReward          | 0x0000000000000000000000000000000000001002 | [systemreward](systemreward.abi)                   |
| TendermintLightClient | 0x0000000000000000000000000000000000001003 | [tendermintlightclient](tendermintlightclient.abi) |
| TokenHub              | 0x0000000000000000000000000000000000001004 | [tokenhub](tokenhub.abi)                           |
| RelayerIncentivize    | 0x0000000000000000000000000000000000001005 | [relayerincentivize](relayerincentivize.abi)       |
| RelayerHub            | 0x0000000000000000000000000000000000001006 | [relayerhub](relayerhub.abi)                       |
| GovHub                | 0x0000000000000000000000000000000000001007 | [govhub](govhub.abi)                               |
| TokenManager          | 0x0000000000000000000000000000000000001008 | [tokenmanager](tokenmanager.abi)                   |
| CrossChain            | 0x0000000000000000000000000000000000002000 | [crosschain](crosschain.abi)                       |
| Staking               | 0x0000000000000000000000000000000000002001 | [staking](staking.abi)                             |
| StakeHub              | 0x0000000000000000000000000000000000002002 | [stakehub](stakehub.abi)                           |
| StakeCredit           | 0x0000000000000000000000000000000000002003 | [stakecredit](stakecredit.abi)                     |
| BSCGovernor           | 0x0000000000000000000000000000000000002004 | [bscgovernor](bscgovernor.abi)                     |
| GovToken              | 0x0000000000000000000000000000000000002005 | [govtoken](govtoken.abi)                           |
| BSCTimelock           | 0x0000000000000000000000000000000000002006 | [bsctimelock](bsctimelock.abi)                     |
| TokenRecoverPortal    | 0x0000000000000000000000000000000000003000 | [tokenrecoverportal](tokenrecoverportal.abi)                     |

## Regenerating

These files are exported from the compiled contracts, never edited by hand:

```bash
python3 scripts/export-abis.py            # rewrite abi/*.abi from out/
python3 scripts/export-abis.py --check    # exit 1 if anything is stale (CI)
```

`--check` compares the **entry set**, not bytes. ABI entry order carries no
meaning and solc/forge do not promise to preserve it across versions, so byte
comparison would go red for a reordering that changes nothing.

The check that actually protects the chain is separate:

```bash
python3 .baseline/check_abi_crossrepo.py
```

It asserts that every contract method the node packs in
`bsc/consensus/parlia/*.go` exists here with the expected argument count. A
missing method or a changed arity does not fail at startup — `init` and
`updateValidatorSetV2` are only packed inside `Finalize`, i.e. at the fork
height. The current list is 21 call sites, including the five-way `initialize()`
fan-out where one ABI is used to send the same calldata to StakeHub,
BSCGovernor, GovToken, BSCTimelock and TokenRecoverPortal.

**These files are documentation.** What the node executes is the ABI JSON
inlined in `bsc/consensus/parlia/abi.go`, which is a separate copy. Keeping the
two in step is tracked as C3; until that lands, a green run here does not prove
the node's copy agrees.
