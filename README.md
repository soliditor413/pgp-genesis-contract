# bsc-genesis-contracts

This repo hold all the genesis contracts on BNB Smart chain. More details in [doc-site](https://docs.bnbchain.org/docs/learn/system-contract).

## Prepare

Install node.js dependency:
```shell script
npm install
```

Install foundry:
```shell script
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge install --no-git foundry-rs/forge-std@v1.7.3
```

Install poetry:
```shell script
curl -sSL https://install.python-poetry.org | python3 -
poetry install
```

Tips: You can manage multi version of Node:
```Shell
## Install nvm and node
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.2/install.sh | bash
nvm install 18.17.0 && nvm use 18.17.0
```

## Unit test

You can get a free archive node endpoint from https://nodereal.io/.

Run forge test:
```shell script
forge test --fork-url ${archive_node_rpc}
```

## Flatten all system contracts

```shell script
bash scripts/flatten.sh
```

All system contracts will be flattened and output into `${workspace}/contracts/flattened/`.

## How to generate the genesis file

The genesis files used to be committed here (`genesis.json`, `genesis-dev.json`,
`genesis-testnet.json`, `genesis-template.json`, ~1.16 MB total) and regenerated
by `scripts/generate-genesis.js` + `init_holders.js`, with a CI job
(`check-genesis.yml`) that failed whenever they drifted. All of that is gone: it
only ever served the BSC alloc path, which this chain does not use.

Genesis is now produced on demand by `scripts/generate.py`, which writes the
system-contract bytecode into the alloc directly:

```shell
npm run generate:mainnet && poetry run python -m scripts.generate recover
npm run generate:testnet && poetry run python -m scripts.generate recover
npm run generate:dev     && poetry run python -m scripts.generate recover
```

(`poetry run python -m scripts.generate --help` for more details, and see
`generate:dev` in `package.json` for how to override params.)

Nothing is committed, so nothing can drift. What *is* checked is the compiled
bytecode itself, against a pinned baseline:

```shell
python3 .baseline/preflight.py        # 5 gates, see .baseline/preflight.py --help
```

## update ABI files

Never edit these by hand, and never redirect `forge inspect` yourself -- it
needs a fully-qualified name, `--json`, and `FOUNDRY_TEST`/`FOUNDRY_SCRIPT`
pointed away from the real trees, or it fails for reasons unrelated to the ABI.

```bash
python3 scripts/export-abis.py            # rewrite abi/*.abi
python3 scripts/export-abis.py --check    # exit 1 if stale
python3 .baseline/check_abi_crossrepo.py  # does the node still find what it packs?
```

## How to update contract interface for test

```shell script
// get metadata
forge build

// generate interface
cast interface ${workspace}/out/{contract_name}.sol/${contract_name}.json -p ^0.8.0 -n ${contract_name} > ${workspace}/test/utils/interface/I${contract_name}.sol
```

## BEP-171 unlock bot
```shell script
npm install ts-node -g

cp .env.example .env
# set UNLOCK_RECEIVER, OPERATOR_PRIVATE_KEY to .env

ts-node scripts/bep171-unlock-bot.ts 
```

## License

The library is licensed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0),
also included in our repository in the [LICENSE](LICENSE) file.
