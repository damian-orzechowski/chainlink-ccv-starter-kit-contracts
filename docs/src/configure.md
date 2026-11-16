# Configuring the contracts

Once the contracts exist, the verifier and the resolver have to be told about each lane and
about this chain. Every configure script is one privileged call, and works in either
[output mode](safe-batches.md) — set `OUTPUT_MODE=EOA` to broadcast with a key, or
`OUTPUT_MODE=SAFE` plus `SAFE_ADDRESS` to stage a Safe batch.

The examples below use each script's `make` target — the variables are covered in
[running the scripts](getting-started.md#running-the-scripts). The table below keeps each
script's raw `--sig` for reference.

**Every script targets a single chain.** `run()` takes one chain alias and `forge script`
takes one `--rpc-url`, so one invocation touches one chain. Scripts that iterate do so over
*lanes* — [every file in `config/operator/lanes/`](#the-lane-directory-is-the-input-set) whose
source or destination is the target chain. There is no chain enumerator, so nothing loops
across chains. Configuring both sides of a lane means running the relevant scripts twice,
once per chain, with that chain's RPC.

Order does not matter. Each script writes disjoint state, so they can be applied and
re-applied in any sequence — but **each must be signed by whoever holds the role that call
requires on that chain**. There is no wrapper script: run them one at a time, switching
signer (or Safe) when the role changes. See [the full flow](full-flow.md#3-configure--per-chain-grouped-by-caller)
for a worked example grouped by caller.

Who can call what: the lane and finality calls are gated by the **verifier's** owner, the
implementation and fee-aggregator calls by the **resolver's** owner. Right after deploy —
before [handover](handover.md) — the deployer often still holds both, so one key may cover
several scripts in a row. That is coincidence, not a guarantee.

The one exception is `UpdateStorageLocations`: callable **only by the
`storageLocationsAdmin`** — not even the owner.

## Re-running stages only what changed

The lane-iterating scripts read the current on-chain value for each lane before
staging it, and skip the lanes that already match — adding a lane and re-running touches
just the new lane, not every lane in `config/operator/lanes/`. Each lane is logged as
`lane STAGED:` or `lane UNCHANGED:`, and a run where everything already matches stages
nothing and writes no batch file. Reading on-chain state is also why those four need
`--rpc-url` even in `OUTPUT_MODE=SAFE` — see
[When an RPC is required](safe-batches.md#when-an-rpc-is-required).

What counts as "already matching" is per script, and matches what
[`DriftCheck`](governance.md) compares:

| script | current when |
|---|---|
| `ApplyRemoteChainConfigUpdates` | router, `allowlistEnabled`, fee, gas and payload size all equal |
| `ApplySignatureConfigs` | threshold equal and the signer *set* equal — order is not compared |
| `ApplyOutboundImplementationUpdates` | the destination already resolves to the local verifier |
| `ApplyAllowlistUpdates` | the flag matches and the sender *set* equals `allowedSenders`, order is not compared |

## The lane directory is the input set

`ConfigLib.listLanes()` reads `config/operator/lanes/` at run time and returns every `.json` in it
whose name does not contain `_template` or `.example.`. There is no manifest and no
per-lane enable flag, so a file sitting in that directory is a lane that gets configured.
The scripts filter that list by target chain, which means a leftover or experimental lane
whose source or destination is the chain you are running against is staged alongside the
real ones.

Every lane a run takes is logged as `[<Script>] lane: <name>` — check that list against
the lanes you meant to configure. The Safe batch under `out/safe/<alias>/` is not a
per-lane view: each configure script collapses every matched lane into a single call, so
one entry covers all of them. Keep retired and in-progress lanes outside `config/operator/lanes/`.

## What each script configures

Ten scripts across three contracts. Every one is a single privileged call.

| script | contract | run on | caller | `--sig` | reads |
|---|---|---|---|---|---|
| `ApplyRemoteChainConfigUpdates` | verifier | **source** of each lane | verifier owner | `run(string,bytes4)` | `operator/lanes/*.json` → `remoteChainConfig` |
| `ApplyAllowlistUpdates` | verifier | **source** of each lane | owner *or* `allowlistAdmin` | `run(string,bytes4)` | `operator/lanes/*.json` → `allowlist` |
| `ApplySignatureConfigs` | verifier | **dest** of each lane | verifier owner | `run(string,bytes4)` | source's `operator/chains/*.json` → `verifiers[]` entry for the lane's tag → `signatureConfig` |
| `SetDynamicConfig` | verifier | the chain | verifier owner | `run(string,bytes4)` | `operator/chains/*.json` → `verifiers[]` entry for tag → `roles` |
| `SetAllowedFinalityConfig` | verifier | the chain | verifier owner | `run(string,bytes4)` | `operator/chains/*.json` → `verifiers[]` entry for tag → `allowedFinality` |
| `UpdateStorageLocations` | verifier | the chain | **`storageLocationsAdmin`** | `run(string,bytes4)` | `operator/chains/*.json` → `verifiers[]` entry for tag → `storageLocations` |
| `ApplyOutboundImplementationUpdates` | resolver | **source** of each lane | resolver owner | `run(string)` | `operator/lanes/*.json` → dest selector + lane `versionTag` |
| `ApplyInboundImplementationUpdates` | resolver | the chain | resolver owner | `run(string)` | `operator/lanes/*.json` → lane `versionTag` for inbound dest |
| `SetFeeAggregator` | resolver | the chain | resolver owner | `run(string)` | `operator/chains/*.json` → `resolver.roles.feeAggregator` |
| `ApplyFactoryAllowlistUpdates` | factory | the chain | factory owner | `run(string)` | `operator/chains/*.json` → `factory.roles.allowlist` |

## Configuring the verifier

The `CommitteeVerifier` holds everything about *who is trusted and what a message costs*.

The `bytes4` argument on verifier scripts selects **which recorded verifier** to configure
when a chain runs more than one tag. Lane-iterating scripts filter lanes by whether this
chain is the source or destination; the tag must match each lane's `versionTag` field.

### Per lane

```bash
# requires: CHAIN, TAG, RPC_URL, OUTPUT_MODE (+ SAFE_ADDRESS in SAFE mode)
TAG=0x00010001   # example — use your catalogued tag throughout

# on the lane's SOURCE chain
make apply-remote-config  CHAIN=sepolia TAG=$TAG RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
make apply-allowlists     CHAIN=sepolia TAG=$TAG RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA

# on the lane's DEST chain
make apply-signature-configs CHAIN=base_sepolia TAG=$TAG RPC_URL=$BASE_SEPOLIA_RPC_URL OUTPUT_MODE=EOA
```

A `BpsFeeCommitteeVerifier` takes one more step on the source chain, after
`apply-remote-config`: `make apply-bps-config` registers its price adapters and applies
each lane's `bpsFeeConfig`. See [BPS fee configuration](deploy.md#bps-fee-configuration).

- **`ApplyRemoteChainConfigUpdates`** — per destination: the local router to send through,
  the fee in US dollar cents, and the gas and payload size reserved for verifying on
  arrival. A zero `router` here is the **only outbound pause** in the system, so the script
  warns rather than refusing; `make pause-lane LANE=<name>` sets it for one lane and
  records it in the lane file. `gasForVerification` must be non-zero or `BaseVerifier`
  reverts `DestGasCannotBeZero`.
- **`ApplyAllowlistUpdates`** — which senders on this chain may send to each destination.
  `allowedSenders` is the desired **full** set: the script reads the on-chain set, stages
  only the delta, and a sender on-chain that the lane file does not list is removed. The
  contract only accepts adds while the allowlist is enabled, so the script refuses a
  non-empty `allowedSenders` with `allowlistEnabled: false`.
- **`ApplySignatureConfigs`** — the committee that verifies messages arriving *from* each
  source, read from that source's operator file so every destination applies the same
  set. This one **is** a full-set replacement: list the complete desired signer set
  every time, because the contract clears the existing set first. The script enforces two
  properties unless `ALLOW_WEAK_COMMITTEE=true`: liveness, so no N-of-N committee (one
  offline signer would halt the lane), and safety, so the threshold must exceed 2/3 of the
  set. The smallest committee that needs no waiver is 3-of-4.

### Per chain (verifier)

```bash
# requires: CHAIN, TAG, RPC_URL, OUTPUT_MODE (+ SAFE_ADDRESS in SAFE mode)
TAG=0x00010001   # example — use your catalogued tag throughout

make set-dynamic-config       CHAIN=sepolia TAG=$TAG RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
make set-finality-config      CHAIN=sepolia TAG=$TAG RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
make update-storage-locations CHAIN=sepolia TAG=$TAG RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
```

- **`SetDynamicConfig`** — sets `{ feeAggregator, allowlistAdmin }` as one struct for the
  selected verifier, so it always writes both. Changing one means passing the current value
  of the other; both come from the `verifiers[]` entry for `$TAG` in
  `config/operator/chains/<alias>.json`.
- **`SetAllowedFinalityConfig`** — the finality requests the verifier will accept, from
  the `allowedFinality` block. `{}` is full finality only; `{ "minBlockDepth": 1 }` also
  permits the depth-1 fast path. One value per verifier, **not per lane** —
  you cannot run one destination on the fast path and another on full finality from the
  same verifier. Enforced on the outbound `getFee` call, so a disallowed finality fails at
  quote time.
- **`UpdateStorageLocations`** — the operator's own aggregator endpoint URL(s). Callable
  **only by the `storageLocationsAdmin`**, not the owner — the sole exception to
  owner-gating in this directory. Writing an empty list clears the on-chain record, which
  the script warns about but allows.

## Configuring the resolver

The `VersionedVerifierResolver` is the address integrators hardcode. It holds only
*routing*: which local verifier handles what.

```bash
# requires: CHAIN, RPC_URL, OUTPUT_MODE (+ SAFE_ADDRESS in SAFE mode) — no TAG

# on the lane's SOURCE chain
make apply-outbound     CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA

# per chain
make apply-inbound      CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
make set-fee-aggregator CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
```

- **`ApplyOutboundImplementationUpdates`** — maps each destination selector to this chain's
  **local** verifier for that lane's `versionTag`. Per lane, but batched: one call carries
  every outbound destination whose source is this chain.
- **`ApplyInboundImplementationUpdates`** — maps each lane's `versionTag` (for lanes whose
  **dest** is this chain) to the local verifier recorded for that tag. Keyed by **version,
  not by source chain** — an incoming message carries the tag it was sealed with. Tags
  already matching on-chain are skipped, so `--rpc-url` is required even in SAFE mode.
- **`SetFeeAggregator`** — where the resolver sends withdrawn fees. Distinct from the
  verifier's aggregator; see below.

## Pruning the factory allowlist

`BootstrapFactory` allowlists the deployer in the constructor so it can deploy the
resolver through the factory. Nothing removes that afterwards, so the deployer key keeps
the ability to claim CREATE2 addresses until you prune it.

```bash
# requires: CHAIN, RPC_URL, OUTPUT_MODE (+ SAFE_ADDRESS in SAFE mode) — no TAG
make apply-factory-allowlist CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL OUTPUT_MODE=EOA
```

`factory.roles.allowlist` in `operator/chains/<alias>.json` is the **full** desired set, not a delta. The
script reads `getAllowList()`, stages only the difference, and does nothing when the two
already agree — so re-running is safe and a clean run is proof the on-chain set matches
config. An empty list means nobody may `createAndCall` until the owner re-adds an
account.

**Order matters.** Prune only after the factory owner has accepted ownership and every
deterministic deploy on that chain is done — removing the deployer earlier blocks the
resolver deploy. The script refuses to remove anything while no resolver is recorded for
the chain, which catches the common case but not a chain you have yet to deploy on. To
authorise a replacement deployment account later: add it to `factory.roles.allowlist`, run this,
deploy, remove it, run this again.

## What a fresh deploy already has

`DeployVerifier` passes three of these values into the constructor from config, so they are
set before you configure anything:

| already set at deploy | by |
|---|---|
| `feeAggregator`, `allowlistAdmin` (the dynamic config) | `operator/chains/<alias>.json` → `verifiers[]` entry for tag → `roles` |
| `storageLocations` | `operator/chains/<alias>.json` → `verifiers[]` entry for tag |
| `rmn`, `versionTag` (immutable) | chain config + deploy argument |

So `SetDynamicConfig` and `UpdateStorageLocations` are **change** operations, not setup
steps — which is why [the full flow](full-flow.md#3-configure--per-chain-grouped-by-caller) can
skip them on a first deploy. The resolver takes no constructor arguments, so nothing on it
is pre-set except what you configure explicitly (`SetFeeAggregator`, inbound/outbound maps).

## Two fee destinations, not one

The verifier's `DynamicConfig.feeAggregator` and the resolver's `setFeeAggregator` are
**different settings on different contracts**, and each contract withdraws its own fees to
its own aggregator. Set both. A zero aggregator makes `withdrawFeeTokens` revert on that
contract.

`SetDynamicConfig` handles the verifier's, and a fresh deploy already carries it.
`SetFeeAggregator` handles the resolver's, which is unset until you run it. `BalanceReport`
reads both back and flags a zero.

## Confirm it worked

Configuring both sides is not the same as configuring them *consistently*. Run the drift
and parity checks before treating a lane as live — see [Governance checks](governance.md).
