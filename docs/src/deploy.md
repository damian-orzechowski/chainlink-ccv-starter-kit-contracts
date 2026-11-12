# Deploying

Three contracts per chain, deployed in a fixed order. All three are EOA-only by design —
they depend on a fresh deployer and are not routed through a Safe.

The three targets always `--broadcast` and sign with `SIGNER` (default `--aws`; override
with e.g. `SIGNER="--private-key $PRIVATE_KEY"`). The signer must be the real deployer
key even for the simulation Foundry runs first — `msg.sender` is what the nonce and role
checks evaluate against.

A run that does not broadcast writes no deployment record — it stops at
`DRY RUN: ... record NOT written`. Foundry executes the whole script in simulation before
submitting anything, so this is what keeps a simulated address out of
`config/deployments/`.

**Before `deploy-verifier`**, ensure:

1. The tag is listed in `config/operator.json`.
2. `config/operator/chains/<alias>.json` has a `verifiers[]` entry for that tag (owner,
   `storageLocationsAdmin`, `feeAggregator`, `allowlistAdmin`).
3. `rmn` in the chain config is non-zero and correct — it is immutable with no getter.

**Deploying also hands over roles.** All three scripts read
`config/operator/chains/<alias>.json` and *propose* the roles declared there to their intended
holders. Every one of these roles is two-step, so proposing changes nothing on its own:
the deployer keeps the role until the incoming holder accepts, via
[handover](handover.md). A role whose configured holder is the deployer is left alone.

## 1. Bootstrap the factory

```bash
# requires: CHAIN, RPC_URL — broadcasts with SIGNER (default --aws)
make bootstrap-factory CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL
```

This **must** be the deployer's first ever transaction on that chain. A `CREATE` address
is `keccak256(rlp([deployer, nonce]))`, so a nonce-0 deployer lands the factory at the
same address on every chain. The script hard-requires it:

```solidity
require(vm.getNonce(deployer) == 0, "BootstrapFactory: deployer nonce != 0 (address parity broken)");
```

The deployer is placed in the factory's allowlist at construction so it can drive the
CREATE2 deploy in the next step. Ownership then goes to the configured
`factory.roles.owner` from `config/operator/chains/<alias>.json` — as a *proposal*, since `CREATE2Factory`
is `Ownable2Step`. Leave it unset (or equal to the deployer) to keep the deployer as owner.

The factory is recorded into `config/deployments/<alias>.json`, along with the deploy-time
params every deploy script records beside its address: the exact constructor arguments
(plain and pre-encoded), the deployer for the factory, the CREATE2 salt for the resolver.
These pin what was deployed — they do not move when config changes — and they feed
`script/deploy/verify.sh` for source verification.

## 2. Deploy the resolver

```bash
# requires: CHAIN, RPC_URL — broadcasts with SIGNER (default --aws)
make deploy-resolver CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL
```

Deployed through the factory with the repo-wide `resolverSalt` from `config/operator.json`. The
resolver has no constructor arguments, so its initcode is just its creation bytecode —
nothing per-chain can perturb the address.

The script precomputes the address, deploys, and asserts they match:

```solidity
require(resolver == predicted, "DeployResolver: deployed address != predicted (determinism broken)");
```

Ownership is proposed to `resolver.roles.owner`. If that is the deployer, the script accepts
in-place so the resolver is immediately usable.

**Confirm the resolver address matches the other chains before continuing.** Divergence
here is silent and only surfaces later as fee-quoting reverts.

## 3. Deploy the verifier

```bash
# requires: CHAIN, TAG, RPC_URL — broadcasts with SIGNER (default --aws)
make deploy-verifier CHAIN=sepolia TAG=0x00010001 RPC_URL=$SEPOLIA_RPC_URL
```

The `bytes4` tag is an explicit deploy argument — each run appends a new entry to
`deployments/<alias>.json`'s `verifiers[]` array. A duplicate tag reverts unless
`ALLOW_TAG_REPLACE=true` (for redoing a failed deploy before anything references it).

Five values must be set before this runs — `rmn` from the chain config, the tag in the
`config/operator.json` catalog, three from the operator file's entry for this tag. The
script checks all five up front:

| Requirement | Source file | Revert message |
|---|---|---|
| `rmn` non-zero | `config/chains/<alias>.json` | `DeployVerifier: rmn must be non-zero` |
| tag non-zero and catalogued | deploy argument + `config/operator.json` | `DeployVerifier: versionTag must be non-zero` / catalog error |
| `verifier.owner` set | `config/operator/chains/<alias>.json` → `verifiers[]` entry for tag | `DeployVerifier: verifier.owner role unset` |
| `verifier.storageLocationsAdmin` set | same | `DeployVerifier: verifier.storageLocationsAdmin role unset` |
| `verifier.feeAggregator` set | same | `DeployVerifier: verifier.feeAggregator role unset` |

`allowlistAdmin` is read from the same roles entry but is *not* checked — a zero value
deploys fine.

Plain `CREATE` with constructor arguments from config: dynamic config and storage locations (from the verifier's operator entry), RMN (from the chain config),
storage locations and RMN (from chain config), and the deploy-time `versionTag`. Its
address will differ per chain — that is fine, because callers reach it through the resolver.

This script hands over **two** roles, both as proposals:

- **`verifier.owner`** — gates every owner-only configure script. Until it is accepted,
  the deployer is still the owner and can keep configuring.
- **`verifier.storageLocationsAdmin`** — the constructor seeds this to the deployer, and
  the script proposes it onward.

`storageLocationsAdmin` is **not** carried by ownership, in either direction. It is a
separate two-step role with its own transfer pair, and the owner cannot move it:
`transferStorageLocationsAdmin` reverts `OnlyCallableByStorageLocationsAdmin` for anyone
who is not the current admin. There is no owner override, so an admin key lost before the
handover completes leaves `updateStorageLocations` permanently uncallable and needs a
redeployed verifier.

Two constructor arguments are **immutable**:

- **`rmn`** — stored as `IRMN internal immutable i_rmn` with no getter. It cannot be read
  back, so `DriftCheck` can never verify it, and the only way to change it is to redeploy
  the verifier. Worth double-checking against the chain config before this step.
- **`versionTag`** — a new tag means a new verifier deployment plus resolver re-wiring.

### BPS-fee verifier

```bash
# requires: CHAIN, TAG, RPC_URL — broadcasts with SIGNER (default --aws)
make deploy-bps-verifier CHAIN=sepolia TAG=0x00020001 RPC_URL=$SEPOLIA_RPC_URL
```

Deploys `BpsFeeCommitteeVerifier` (`src/bps/`) instead of the stock `CommitteeVerifier`.
`DeployBpsVerifier` subclasses `DeployVerifier` and only swaps the implementation, so
everything above applies unchanged: the same arguments, the same operator `verifiers[]`
entry for the tag, the same up-front checks and role handover, and the same record
(with `"contract": "BpsFeeCommitteeVerifier"`, which `make verify` uses to pick the
source). Give it its own tag; the resolver wiring treats it like any other verifier.

The contract is a `CommitteeVerifier`, so every configure, ownership, fee and governance
target works on it by tag. Its bps policy is not set at deploy: until
`make apply-bps-config` has run (see [below](#bps-fee-configuration)), `getFee` charges the
flat `remoteChainConfig.feeUSDCents`.

### Price adapters

```bash
# requires: CHAIN, TOKEN, RPC_URL — broadcasts with SIGNER (default --aws)
make deploy-price-adapter CHAIN=sepolia TOKEN=<wstETH address> RPC_URL=$SEPOLIA_RPC_URL
```

The BPS verifier values a transfer by asking one `IPriceAdapter` per token. Declare each
adapter in `config/operator/chains/<alias>.json` → `priceAdapters[]` first (see the
[config schema](config-schema.md)); its `contract` picks the implementation:

| `contract` | Where | Prices wstETH as |
|---|---|---|
| `WstETHUSDPriceAdapter` | Ethereum | one wstETH/USD feed |
| `WstETHUSDL2PriceAdapter` | L2s | wstETH/ETH × ETH/USD, refused while the sequencer is down or in its grace period |

`DeployPriceAdapter` deploys the entry for `TOKEN` with plain `CREATE` and appends it to
`deployments/<alias>.json` → `priceAdapters[]`. Adapters have no owner and nothing
mutable, so the entry is the whole configuration: changing a feed or a staleness bound
means editing the entry and deploying again with `ALLOW_ADAPTER_REPLACE=true` (a token
already on record otherwise reverts).

Because an edit does nothing on chain until the replacement is deployed, two checks keep
the copies in step:

- `make validate-config` fails an operator file whose `priceAdapters[]` no longer matches
  the record: an entry whose args differ from the recorded adapter's (each field is named,
  declared != recorded), or a recorded token the file no longer declares. A declared entry
  with nothing recorded yet passes.
- `make drift` reads each recorded adapter's immutables on chain and reports every field
  that differs from the record's `args` (a record edited after the deploy, or pointing at
  the wrong address). An adapter that is neither type counts once.

| Requirement | Source file | Revert message |
|---|---|---|
| `TOKEN` non-zero | deploy argument | `DeployPriceAdapter: token must be non-zero` |
| entry declared for `TOKEN` | `config/operator/chains/<alias>.json` → `priceAdapters[]` | `ConfigLib: no priceAdapters entry for token …` |
| every key the `contract` takes, non-zero addresses, no other key | same | `ConfigLib: missing …` / `zero address at …` / `unknown key …` |
| staleness in `[60, 604800]`, `gracePeriod` in `[60, 21600]`, token is 18-decimal | same | adapter constructor (`InvalidMaxStaleness` / `InvalidGracePeriod` / `UnexpectedTokenDecimals`) |

After deploying, the script prices one token through the live feeds. A revert there is
only a **warning**, because a testnet feed may simply be stale, but it also catches a
wrong feed address. Until the adapter prices, `getFee` values that token at zero (or
reverts, with `setRequireAllTokensPriced(true)`).

Deploying does not register the adapter; `make apply-bps-config` does.

### BPS fee configuration

```bash
# requires: CHAIN, TAG, RPC_URL, OUTPUT_MODE (EOA or SAFE + SAFE_ADDRESS)
make apply-bps-config CHAIN=sepolia TAG=0x00020001 RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=SAFE SAFE_ADDRESS=0x...
```

These settings exist only on a `BpsFeeCommitteeVerifier`, so they live in optional keys
the stock configure scripts never read, and only this target pushes them. It runs as the
verifier owner, on the verifier recorded for `TAG`, and stages, skipping whatever is
already current:

| Call | From | Absent means |
|---|---|---|
| `setPriceAdapters` | every adapter in `deployments/<alias>.json` → `priceAdapters[]` | — |
| `setFeeConfig(dest, …)` per lane leaving `CHAIN` under `TAG` | the lane's `bpsFeeConfig` | disabled (flat fee) |
| `setRequireAllTokensPriced` | the verifier entry's `requireAllTokensPriced` | `false` |

Before building anything it refuses a `TAG` the record does not list as a
`BpsFeeCommitteeVerifier`, and a lane that enables a policy for a destination the
verifier has no remote chain config for (`setFeeConfig` would revert). In SAFE mode it
also checks `SAFE_ADDRESS` is the verifier's current owner. `make validate-config` checks
the `bpsFeeConfig` bounds (`feeBps <= 10000`, `capUSDCents >= minFeeUSDCents`, a non-zero
`minFeeUSDCents` when enabled) and rejects bps settings aimed at a verifier recorded as a
stock `CommitteeVerifier`. `make drift` compares all three against the chain.

Order on each chain:

1. `make deploy-price-adapter` for each token.
2. `make deploy-bps-verifier`, then the usual configure steps, `apply-remote-config` first.
3. `make apply-bps-config`. Re-run it after adding an adapter or editing a `bpsFeeConfig`.

## Address determinism

Two preconditions:

1. **Nonce 0 on every target chain.** Enforced by `BootstrapFactory`, so this one fails
   loudly.
2. **Identical initcode everywhere.** Not enforced by anything. It requires the same
   pinned dependencies (`npm ci`) and the default compiler profile on every machine that
   deploys.

The second fails silently — the deploy succeeds, just at a different address. Always
deploy from a fresh `npm ci` install with the default profile, and confirm the resolver
address matches the other chains before configuring anything on top of it.

## Multiple verifiers

To run an upgrade alongside the old verifier:

1. Add the new tag to `config/operator.json`.
2. Add a `verifiers[]` entry for it in every chain's operator file.
3. `make deploy-verifier CHAIN=… TAG=<new> RPC_URL=…` on every chain.
4. Migrate lanes one at a time — flip `versionTag` in the lane file, re-run configure.
5. Retire the old verifier once in-flight messages drain — see
   [Rotating a verifier](operations.md#rotating-a-verifier).

## Source verification

```bash
# requires: CHAIN, ETHERSCAN_API_KEY in the environment; production build in out/
make verify CHAIN=sepolia                                   # everything recorded for the chain
make verify CHAIN=sepolia ONLY=factory                      # one contract: factory|resolver|verifiers
make verify CHAIN=sepolia ONLY=verifier:0x00010001          # one verifier, by tag
script/deploy/verify.sh sepolia --dry-run                   # print the forge verify-contract commands
```

Constructor arguments come from the deployment record, not from config — the record holds
the exact values each constructor received (`encodedArgs`), so verification reproduces
even after `SetDynamicConfig` or `UpdateStorageLocations` moved the live values. Needs
`ETHERSCAN_API_KEY` (or the per-chain key `foundry.toml` resolves) and the default build
profile — never verify a `dev` build.
