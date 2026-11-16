# Governance wrappers

Shell wrappers around the read-only governance scripts. All three share one exit-code
convention, so a single CI shape covers them:

| exit | meaning |
|---|---|
| `0` | clean |
| `1` | a real finding (drift, parity mismatch, divergence, stale output) |
| `2` | the check could not run (unreachable RPC, missing file, missing tool) |

The `1` / `2` split is load-bearing: the Solidity scripts log a `DRIFT_DETECTED` marker
on real findings, and the wrappers grep for it — a revert *without* the marker (wrong
RPC, missing deployment record) reports `2`, never a false `1`.

## `drift-check.sh` — one chain vs its own config

```bash
./script/governance/drift-check.sh <chainAlias> <rpcUrl>
make drift CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL
```

Wraps `DriftCheck.s.sol`: reconciles live on-chain state against `config/chains`,
`config/chains/`, `config/operator/chains/` and `config/operator/lanes/` for one chain — role holders, fee aggregators, storage
locations, finality config, resolver implementations, per-lane remote config. Needs an
RPC. Direction-aware: a chain that is only ever a lane *source* will not have its signer
sets checked (those live on the destination).

## `lane-parity-check.sh` — the two chains of one lane vs each other

```bash
./script/governance/lane-parity-check.sh <laneName> <sourceRpcUrl> <destRpcUrl>
```

Wraps `LaneParityCheck.s.sol` and runs its three legs, aggregating worst-of:

1. `runConfig` — config vs config, no RPC: selector agreement, `versionTag` recorded on
   both chains, recorded resolver salts and addresses identical.
2. `runSource` — on the source chain: outbound implementation and remote chain config,
   keyed by the destination selector.
3. `runDest` — on the destination chain: inbound implementation for the *source's*
   `versionTag`, the destination verifier's own immutable tag, and the signer set keyed
   by the source selector.

Covers one **directed** lane; a bidirectional pair takes two runs, with the RPC
arguments swapped for the reverse lane. `runConfig` can also be invoked alone via
`forge script ... --sig "runConfig(string)" <lane>`.

A lane whose halves disagree passes `drift-check.sh` on both chains while every message
fails on first use; this closes that gap. `router = 0` is reported as a NOTE, not a
mismatch — it is the deliberate outbound pause.

## `deployments-report.sh` — render config/ into the deployed-addresses page

```bash
./script/governance/deployments-report.sh            # write docs/src/deployments.md
./script/governance/deployments-report.sh --check    # print only; exit 1 if stale or diverged
```

No RPC. Joins `config/deployments/<alias>.json` (written by the deploy scripts at
broadcast time) with `config/chains/<alias>.json` (current intent), one row per alias
present in **both**. Constructor arguments come from the record, never from config: they are
what the contracts were built with, and three of the verifier's four are mutable
afterwards. Emits:

- **Contracts** — factory / resolver / verifiers (per versionTag) per chain, linked to an
  explorer
- **Deploy-time constructor arguments** — per-verifier `rmn` and the resolver's CREATE2
  salt, from the record; plus the recorded `storageLocations` per verifier
- **Resolver address parity** — asserts every recorded resolver is the SAME address;
  a divergence prints the distinct addresses and exits `1`, so the generator doubles as
  a CI check

`--check` renders to stdout without writing and additionally exits `1` when the page on
disk no longer matches `config/`, or is missing entirely — regeneration is a deliberate
step, not a CI side effect. Writing is the no-argument default, so any
other argument is rejected with exit `2` rather than treated as a write.

Incomplete config is reported rather than papered over, because a record grows in stages:
`bootstrap`, `deploy-resolver` and `deploy-verifier` each add one address.

- A deployment record with no `config/chains/<alias>.json` is skipped with a `SKIP` line
  on stderr, not dropped silently.
- An address a record does not carry yet renders as `not recorded`, never as a link.
- Parity is judged only over chains that actually have a resolver address, and the count
  of chains without one is stated beneath the verdict; an absent address is excluded from
  the comparison rather than counted as a value.
- With no records at all, writing over a populated page is refused (exit `2`): otherwise
  a checkout with no records would replace the page with the empty placeholder and exit
  `0`. Delete the page first to reset it deliberately.

`explorerAddressPath` in `config/chains/<alias>.json` is **optional** and synced from the
CCIP API (`chainMetadata.explorer.addressPath`). It is a full URL prefix, not a path
fragment, so addresses render as links (`<explorerAddressPath>/<address>`) with nothing
interpolated in between; when empty or absent they render as plain code text. The zero
address is never linked.

The API serves it as nullable. For a chain Chainlink has no explorer for, the sync
tooling skips the field rather than blanking it, so a hand-set value survives — see
[Config sync commands](../config/README.md).

The report shows what the records **claim**, not what the chains hold: a stale or
hand-edited record is rendered faithfully. On-chain truth is `drift-check.sh` and
`lane-parity-check.sh`'s job.

## `SnapshotOperator.s.sol`

```bash
forge script script/governance/SnapshotOperator.s.sol --sig "run(string)" <chainAlias> --rpc-url <url>
```

Writes `out/governance/<alias>-<block>.operator.local.json`: one entry per recorded verifier
with its live finality, storage locations and role holders, the committee carried over from
an existing operator file. Promote confirmed values
into `config/operator/chains/<alias>.json` by hand. Output is run-local (snapshots
hold live role addresses).

For a `BpsFeeCommitteeVerifier` the snapshot also writes that verifier's
`requireAllTokensPriced` and rebuilds `priceAdapters[]`: per token, the adapter the bps
verifiers point at (`getPriceAdapter`), else the recorded one, described from its public
immutables. The verifier cannot enumerate its tokens, so the token list is the deployment
record's `priceAdapters[]` plus the tokens the current operator file declares; an adapter
registered by hand for any other token is not captured. A declared adapter not yet
deployed, or one that is not a type the schema can describe, keeps its declared entry;
each such case is logged as a `NOTE`.
