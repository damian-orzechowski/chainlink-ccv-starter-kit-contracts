# Governance checks

Each check answers a different question. None replaces another.

| check | question | scope |
|---|---|---|
| `make validate-config` | does every config file parse, and do lanes agree with chains, the operator files and the tag catalog? | all files, no RPC |
| `DriftCheck` | does chain X match X's own config? | one chain, one RPC |
| `LaneParityCheck` | do the two halves of a lane agree with each other? | one lane, two RPCs |
| `make sync-check` | does my config still match Chainlink's API? | all chains, no RPC — see [Configuration](configuration.md#where-the-chainlink-fields-come-from) |
| `deployments-report.sh --check` | is the deployed-addresses page current, and the resolver identical everywhere? | all records, no RPC |

All of them share one exit-code convention — **0** clean, **1** a real finding, **2** the
check could not run — so a single CI shape covers them.

A lane whose halves disagree **passes drift on both sides** while every message fails on
first use. That gap is exactly what parity exists to close.

## Validate the config files

```bash
# requires: nothing — no RPC, no keys
make validate-config
```

Parses **every** real file under `config/` through the same strict loaders the action
scripts use — one `[PASS]`/`[FAIL]` line per file — and cross-checks each lane: endpoint
chain configs exist and agree on the selector, filenames equal the declared names, and
each endpoint's operator file carries a `verifiers[]` entry for the lane's tag and the
source's entry declares a committee for it. Where both
directions of a lane exist — two files pair when each one's `source.alias` is the other's
`dest.alias` — the pair must pin the same `versionTag` and mirror each other's selectors;
a one-way lane is left alone. `config/operator.json` must parse with a non-zero
`resolverSalt`, and every recorded resolver must have been deployed with it. The action
scripts parse lazily, so without this a broken file surfaces only when the first script
touches it, possibly mid-ceremony. Run it first, on every config edit.

## Drift check

```bash
# requires: CHAIN, RPC_URL
make drift CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL
```

Reconciles live on-chain state against `config/operator/chains` and
`config/operator/lanes` — role holders, fee aggregators, storage locations, finality config,
resolver implementations, and per-lane remote config.

Exit codes: **0** clean, **1** drift, **2** RPC unreachable or another failure.

A run that cannot complete — an unreachable RPC, an RPC pointing at a different chain
than the alias, a missing deployment record — exits 2, never 1, so CI can distinguish
"the check broke" from real drift. Both drift and parity verify the connected chainid
against the chain config before reading anything.

Drift is direction-aware. Running against a chain that is only ever a lane *source* will
not check signer sets, because those live on the destination. If a chain's inbound
configuration never seems to be checked, the reverse lane file is probably missing.

### What drift cannot see

`rmn` is immutable with no getter, so it is the one configured value with **zero drift
coverage** — a wrong value sits there indefinitely looking correct. Verify it before
deploying; see [Deploying](deploy.md#3-deploy-the-verifier).

## Lane parity check

```bash
# requires: LANE, SOURCE_RPC, DEST_RPC
make parity LANE=sepolia-to-base_sepolia SOURCE_RPC=$SEPOLIA_RPC_URL DEST_RPC=$BASE_SEPOLIA_RPC_URL
```

Runs three legs and aggregates the worst result:

1. **`runConfig`** — config against config, no RPC. Selector agreement, lane `versionTag`
   recorded on both chains, recorded resolver salts and addresses identical,
   nothing left unrecorded, `gasForVerification` non-zero.
2. **`runSource`** — on the source chain: the outbound implementation for the destination
   selector, and the remote chain config.
3. **`runDest`** — on the destination chain: the inbound implementation for the **lane's**
   `versionTag`, that the destination verifier's own immutable tag matches, and the signer
   set keyed by the source selector.

Same exit codes as drift, so one CI shape covers both.

`router = 0` is reported as a NOTE, not a mismatch. It is the legitimate paused state.

### "Parity" means two chains, not two directions

The check operates on **one directed lane**. It never looks at the reverse lane, or asks
whether one exists. What it compares is the source chain's half against the destination
chain's half of that single direction — the halves that `DriftCheck` can only ever see one
at a time.

So a **one-way lane is checked exactly the same way, with one run**, and needs it just as
much: the outbound half lives on the source, the inbound half on the destination, and
nothing else verifies they were built from the same lane file. A bidirectional pair is two
directed lanes, so it takes two runs — and the RPC arguments flip for the reverse one,
since its source is the other chain.

### Running `runConfig` on its own

The first leg needs no RPC, no keys, and no contracts deployed:

```bash
# requires: LANE — no RPC
make parity-config LANE=sepolia-to-base_sepolia
```

That makes it the cheapest gate you have — it catches a stale selector, a diverged
`versionTag` or recorded salt, or a missing deployment record before anyone spends gas,
and it can run on every PR. It even runs **before anything is deployed**: a missing
deployment record is reported as a pre-deploy NOTE and the record comparisons are
skipped, while the config-vs-config checks still gate the lane. The other two legs need
the live chains.

### What must exist on disk

| | |
|---|---|
| `config/operator/lanes/<lane>.json` | one file — the direction being checked |
| `config/chains/<source>.json`, `config/chains/<dest>.json` | both, for the selector comparisons |
| `config/operator/chains/<source>.json` | `runDest` only: the committee for the lane's tag |
| `config/deployments/<source>.json`, `config/deployments/<dest>.json` | both, for the recorded-address comparisons — `runConfig` alone tolerates a missing one (pre-deploy NOTE) |

The expected tag is the one the lane file pins; `runDest` also reads the **source's**
operator entry for that tag, for the committee keyed by the source selector.

A missing file exits `2` — "couldn't complete the check", not "the lane is wrong". The
lane name is matched
against the `name` field inside the JSON, which must equal the filename.

## Deployments report

```bash
# requires: nothing — reads config/ locally
make deployments-doc      # regenerate docs/src/deployments.md from config/
make deployments-check    # CI: exit 1 if the page is stale or the resolver diverges
```

Renders the recorded deployments into the [Deployed addresses](deployments.md) page —
no RPC, one row per chain that has both a deployment record and a chain config. Verifiers
are listed as `versionTag` → address. While rendering it asserts the recorded **resolver
address is identical on every chain** and exits `1` if not, so the generator doubles as a
check.

It shows what the records *claim*, not what the chains hold — on-chain truth stays with
drift and parity above. Regenerating the page is a deliberate step, not a CI side effect:
`--check` only tells you it went stale.

## Operator snapshot

```bash
# requires: CHAIN, RPC_URL — read-only, no signer
make snapshot CHAIN=sepolia RPC_URL=$SEPOLIA_RPC_URL
```

Writes every live role holder and verifier setting to `out/governance/` for review, and
can be promoted into `config/operator/chains/<alias>.json` once confirmed. Useful when adopting a deployment whose
intended roles were never written down.

On a chain with a `BpsFeeCommitteeVerifier`, the snapshot also captures that verifier's
`requireAllTokensPriced` and rebuilds `priceAdapters[]` from the adapters the verifier uses,
read back from each adapter's immutables. The verifier keeps adapters in a mapping it
cannot list, so only tokens named by the deployment record or the current operator file
are looked up: an adapter registered by hand for any other token is not captured. Anything
the snapshot cannot read from chain keeps its declared entry, with a `NOTE` in the output.

## These checks are advisory about intent

They compare declared configuration against on-chain state. They cannot tell you the
*declared* values are the right ones. A lane whose config still holds placeholder values
will read as perfectly clean once those placeholders are applied.
