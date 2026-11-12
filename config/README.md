# `config/` — config-as-data

Every deployment/config parameter lives here as JSON. The scripts under `script/` are generic loops that read these files, so one script serves every lane and chain you add here, with nothing hardcoded.

Each file has exactly one writer:

| Path            | One file per… | Holds | Written by |
|-----------------|---------------|-------|------------|
| `chains/`       | chain         | Chainlink's reference, seven fixed keys: `alias`, `chainId`, `chainSelector`, `router`, `rmn`, `feeTokens`, `explorerAddressPath` | `script/config/sync-ccip-config.sh` |
| `operator.json` | repo          | the operator's cross-chain identities: `resolverSalt`, the `versionTags` catalog | the operator |
| `operator/chains/` | chain      | the operator's intent for that chain: one entry per verifier tag (finality, storage locations, committee, role holders), plus the resolver and factory role holders | the operator; `SnapshotOperator` drafts it from live state |
| `operator/lanes/` | directed lane | per-lane config: `versionTag` (which verifier serves the lane), `remoteChainConfig` (fee, gas, payload size, optional router override), allowlist | the operator |
| `deployments/`  | chain         | the record of deployed artifacts and their constructor args | the deploy scripts |

Files starting with `_template` document the full schema; files ending in `.example.json`
are illustrative. Real files are named by the chain alias (`sepolia.json`) or lane
(`sepolia-to-base_sepolia.json`).

## Fork the kit before you start

The kit ships templates and examples only. Your own config lives in this directory and
belongs in your own git history, so fork the kit and work from your fork. Commit all
three:

- `chains/`: Chainlink's reference, written by the sync tooling
- `operator.json` and `operator/`: your config, written by you
- `deployments/`: the addresses you deployed, written by the deploy scripts

---

## `chains/<alias>.json`

Chainlink's per-chain reference, synced from the public CCIP API by
`script/config/sync-ccip-config.sh`. Nothing in it is typed by hand:
`bootstrap` creates the file complete, `check` reports drift against the API, `sync`
accepts it. The loader rejects any key outside this set, so operator data cannot land here.

```jsonc
{
  "alias":            "sepolia",              // identity: names the file; matches rpc_endpoints + operator/deployment files
  "chainId":          11155111,
  "chainSelector":    "16015286601757825753", // CCIP chain selector (string: exceeds JS safe int); the sync's join guard
  "router":           "0x...",                 // Chainlink's local CCIP router. Lanes inherit it unless they override.
  "rmn":              "0x...",                 // Chainlink-provided RMN address. MUST be non-zero.
  "feeTokens":        ["0x..."],               // fee tokens to report on / sweep. Empty => fee scripts no-op.
  "explorerAddressPath": "https://sepolia.etherscan.io/address" // chainMetadata.explorer.addressPath from the API.
                                                     // A FULL URL prefix, not a path fragment: deployments-report.sh
                                                     // links addresses as <explorerAddressPath>/<addr>.
                                                     // Empty => plain unlinked addresses.
}
```

> `feeTokens` drives `BalanceReport` (reads `balanceOf` for the verifier and resolver)
> and `SweepFees` (passes the list to `withdrawFeeTokens`). Optional by design: an absent
> or empty list makes both fee scripts a logged no-op, so a chain whose list is not
> decided yet still loads for every other script. Zero-balance tokens are omitted from
> the staged sweep by default; `SKIP_ZERO_BALANCES=false` stages every listed token — for
> Safe batches executed long after they are built, where fees accrue in between.
>
> The list mirrors CCIP's `FeeQuoter` and is maintained by the sync tooling,
> **append-only**: `sync` merges upstream additions in, and a token the upstream drops is
> kept and flagged as a `NOTE` — de-supporting a token does not zero a balance already
> sitting on the contracts, and `withdrawFeeTokens` is its only exit. Pruning is the one
> manual step: once the upstream no longer serves the token and both contracts read zero
> in `BalanceReport`, sweep and hand-edit it out — the sync will not re-add it.
>
> ⚠️ Every entry must be a real ERC20 **with code**. A zero address, a codeless address,
> or a `balanceOf` that reverts fails the `SweepFees` build with the offending entry named —
> a broken entry is a misconfiguration, never treated as an empty balance. `BalanceReport`
> flags such an entry as `UNREADABLE`.

## `operator/lanes/<source>-to-<dest>.json`

A **directed** lane (source → dest). Contracts deploy on both chains of every lane.

```jsonc
{
  "name":   "sepolia-to-base_sepolia",
  "source": { "alias": "sepolia",      "chainSelector": "16015286601757825753" },
  "dest":   { "alias": "base_sepolia", "chainSelector": "10344971235874465080" },

  // MANDATORY: which verifier serves this lane, on BOTH legs (the dest
  // verifier rejects any tag != its own immutable tag, so source tag == dest tag).
  // The versionTag must be recorded in deployments/<alias>.json on both endpoints.
  // Upgrades are per-lane, reviewed diffs: flip this tag, then re-run the configure
  // scripts (ApplyOutbound cutover last).
  "versionTag": "0x00010001",

  // -> applyRemoteChainConfigUpdates, keyed by DEST chain selector (outbound).
  //    `router` is OPTIONAL: absent inherits the SOURCE chain's synced router
  //    (chains/<alias>.json, maintained by script/config/sync-ccip-config.sh).
  //    An explicit 0x0 pauses the lane: see "Pausing a lane" below.
  "remoteChainConfig": {
    // "router":          "0x...",   // optional; omit to inherit the source chain's router
    "feeUSDCents":        0,
    "gasForVerification": 200000,
    "payloadSizeBytes":   0
  },

  // -> applyAllowlistUpdates, keyed by DEST chain selector.
  //    allowedSenders is the desired FULL set; the script stages only the delta.
  //    Listing senders requires allowlistEnabled: true.
  "allowlist": {
    "allowlistEnabled": false,
    "allowedSenders":   []
  }

  // OPTIONAL, BpsFeeCommitteeVerifier only -> setFeeConfig on the SOURCE verifier, keyed
  //    by DEST selector. Applied by `make apply-bps-config` (after apply-remote-config).
  //    Absent = the contract default: disabled, so getFee charges the flat feeUSDCents.
  //    All four keys when present. Same bounds as setFeeConfig, checked at load:
  //    feeBps <= 10000, capUSDCents >= minFeeUSDCents, minFeeUSDCents > 0 when enabled.
  // "bpsFeeConfig": {
  //   "enabled":        true,
  //   "feeBps":         5,      // 5 = 0.05% of the transfer's USD value
  //   "minFeeUSDCents": 50,     // floor
  //   "capUSDCents":    5000    // cap; <= 65535 (getFee returns uint16)
  // }
}
```

### Pausing a lane

Run `make pause-lane LANE=<name>` against the source chain. It zeroes the router for that
destination on the source verifier, skipping the call if it is already zero, and writes
`"router": "0x0000000000000000000000000000000000000000"` into the lane file. Commit that
change. Outbound traffic to that destination stops. To resume, remove the `router` key, so
the lane inherits the source chain's router from `chains/<source>.json` again, and run
`make apply-remote-config CHAIN=<source> TAG=<versionTag>`.

## `operator/chains/<alias>.json`

Everything the operator declares for one chain: machine-checkable intent that the
configure scripts push on-chain and `DriftCheck` compares the live state against.

One entry per verifier, keyed by `versionTag` like the deployment record, holding
everything that verifier owns: the finality a sender may ask of it, the storage locations
its signers publish to, the committee that signs the messages leaving this chain under its
tag, and who holds each of its roles. All four are per verifier on-chain, so two verifiers
running side by side during an upgrade can differ without either being drift. Declare an
entry BEFORE deploying that verifier: `DeployVerifier` reads it to set DynamicConfig and
propose the handovers, and refuses a tag with no entry.

The resolver and the factory are one per chain. They carry role holders only, under the
same `roles` key a verifier entry uses, so the rule holds across the whole file: whatever
sits under `roles` is who should hold or receive something, everything beside it is a
setting pushed on-chain.

```jsonc
{
  "alias": "sepolia",
  "verifiers": [
    {
      "versionTag": "0x00010001",  // matches deployments/<alias>.json

      "allowedFinality": {},       // what a SENDER may request; {} = full finality only. See note below.

      // The endpoints THIS verifier's signers publish to. Constructor argument, and
      // updatable afterwards by the storageLocationsAdmin via UpdateStorageLocations.
      "storageLocations": ["https://aggregator.<operator>.example/ccv"],

      // -> applySignatureConfigs on EVERY destination verifier of this tag, keyed by this
      //    chain's selector: the committee that signs messages LEAVING this chain, and
      //    uploads them to the storageLocations above. Declared once here, so two
      //    destinations cannot disagree. Full-set REPLACEMENT every time.
      //    Constraint: threshold below the signer count (no N-of-N) and above 2/3
      //    (e.g. 10 signers -> threshold 7; 3-of-4 is the smallest compliant committee).
      //    threshold 0 with no signers = this chain is never a source under this tag.
      "signatureConfig": { "threshold": 7, "signers": ["0x...", "0x..."] },

      "roles": {
        "owner":                 "0x...",  // 2-step ownable
        "storageLocationsAdmin": "0x...",  // separate 2-step admin role
        "allowlistAdmin":        "0x...",  // part of DynamicConfig
        "feeAggregator":         "0x..."   // DynamicConfig.feeAggregator (distinct from resolver's!)
      }

      // OPTIONAL, BpsFeeCommitteeVerifier only -> setRequireAllTokensPriced, applied by
      // `make apply-bps-config`. true: getFee reverts for a transferred token with no
      // registered adapter (or a reverting one). Absent = false: such a token counts as zero.
      // "requireAllTokensPriced": false
    }
  ],
  "resolver": {
    "roles": {
      "owner":         "0x...",        // 2-step ownable
      "feeAggregator": "0x..."         // resolver setFeeAggregator (a SECOND, distinct fee destination)
    }
  },
  "factory": {
    "roles": {
      "owner": "0x...",                 // transferred to governance after bootstrap
      "allowlist": ["0x..."]            // REQUIRED: the FULL createAndCall set the
                                        // factory should hold. BootstrapFactory
                                        // allowlists the deployer at construction, so
                                        // [] prunes it and nobody may createAndCall.
                                        // Applied by ApplyFactoryAllowlistUpdates.
    }
  },
  // OPTIONAL: price adapters for a BpsFeeCommitteeVerifier, one per token (unique).
  // Constructor arguments of an ownerless, immutable contract: DeployPriceAdapter reads
  // the entry for its TOKEN argument. Keys depend on "contract"; any other key is rejected.
  "priceAdapters": [
    {
      "contract": "WstETHUSDPriceAdapter",     // Ethereum: one direct wstETH/USD feed
      "token":    "0x...",                     // wstETH on this chain (must be 18-decimal)
      "usdFeed":  "0x...",                     // Chainlink wstETH/USD
      "usdMaxStaleness": 90000                 // seconds; the adapter's maxStaleness
    },
    {
      "contract": "WstETHUSDL2PriceAdapter",   // L2s: wstETH/ETH x ETH/USD
      "token":    "0x...",
      "rateFeed": "0x...",                     // Chainlink wstETH/ETH
      "rateMaxStaleness": 86400,
      "usdFeed":  "0x...",                     // Chainlink ETH/USD
      "usdMaxStaleness": 3600,
      "sequencerUptimeFeed": "0x...",          // Chainlink L2 Sequencer Uptime Feed
      "gracePeriod": 3600                      // seconds after sequencer recovery
    }
  ]
}
```

> **`priceAdapters` staleness**: set each bound to the feed's heartbeat **plus a buffer**;
> a bound equal to the heartbeat reverts quotes whenever an update lands slightly late.
> Typical values: wstETH/USD (24h heartbeat) `90000`; wstETH/ETH `86400` and ETH/USD
> `3600`, but check each feed's heartbeat on the target L2. Staleness bounds must lie in
> `[60, 604800]` and `gracePeriod` in `[60, 21600]` (`PriceFeedLib`); the constructor
> reverts otherwise.

> **`allowedFinality` is the ALLOWED finality** set on the verifier via
> `setAllowedFinalityConfig`: the requests a sender may make, as alternatives. Full finality
> is always allowed. Two optional keys widen it: `"allowSafeTag": true` also accepts a
> request for the `safe` tag; `"minBlockDepth": N` (1..65535) also accepts a depth request
> of N blocks or more. `{}` allows full finality only, the production default. The scripts
> generate the FinalityCodec `bytes4` from this block, so the encoding is never typed by
> hand; `{ "minBlockDepth": 1 }` waits one block instead of full finality, for lower latency.

Notes:
- `storageLocations` is an **input from the off-chain component**
  (the deployed aggregator hostname). It is per-operator and cannot be hardcoded.
  The deploy should not block on it — it can be set/updated later via the
  `UpdateStorageLocations` script (caller is the `storageLocationsAdmin`, not the owner).
- `DriftCheck` compares every RECORDED verifier against ITS entry; a recorded
  verifier without one is drift. Delete an entry together with its deployment record
  when the verifier retires.

## `operator.json`

The operator's cross-chain identities. One file for the whole repo, because both values
must be spelled identically on every chain.

- `resolverSalt`: the CREATE2 salt for the resolver. The same value on every chain is what
  gives the resolver the same address everywhere (the factory itself gets address parity
  from a fresh nonce-0 deployer — CREATE, not CREATE2 — and has no salt). The loader
  rejects a zero salt.
- `versionTags`: the catalog of every verifier `versionTag` in use. `DeployVerifier` takes
  the tag as an argument (`--sig "run(string,bytes4)" <alias> 0x00010001`), refuses an
  uncataloged one, and appends the new verifier to `deployments/<alias>.json`; a lane may
  only pin a catalogued tag. Entries follow the documented scheme — 2 bytes operator id +
  2 bytes version, both halves non-zero — which the loader enforces here (the contracts
  themselves treat the tag as an opaque `bytes4`).

```jsonc
{
  "resolverSalt": "0x0000...0001",
  "versionTags": [
    { "tag": "0x00010001", "description": "committee verifier v1" }
  ]
}
```

## `deployments/<alias>.json`

The record of deployed artifacts, **written by the deploy scripts — never by hand**.
Each contract's block holds its address plus the exact values its constructor received,
as plain fields (`args`) and pre-ABI-encoded (`encodedArgs`, what
`script/deploy/verify.sh` hands to `forge verify-contract`). Config edits never touch
this file: it records what was deployed, not current intent.

The `verifiers` array maps each DEPLOYED catalogued versionTag to its entry on this
chain — the stored mirror of the resolver's inbound map: one entry per live verifier,
tags unique per chain. `DeployVerifier` APPENDS an entry per deploy (a duplicate tag
reverts; `ALLOW_TAG_REPLACE=true` replaces that entry, for redoing a deploy that went
wrong before anything referenced it — never while it carries traffic).

```jsonc
{
  "alias": "sepolia",
  "factory": {
    "address":     "0x...",
    "deployer":    "0x...",        // the nonce-0 EOA the CREATE address derives from
    "args":        { "allowList": ["0x..."] },
    "encodedArgs": "0x..."         // abi.encode(allowList)
  },
  "resolver": {
    "address":     "0x...",        // the stable lane-facing CCV identity
    "salt":        "0x...",        // the CREATE2 salt that fixed this address
    "args":        {},             // the resolver takes no constructor arguments
    "encodedArgs": "0x"
  },
  "verifiers": [
    {
      "versionTag": "0x00010001",  // old verifier keeps verifying in-flight messages
      "address":    "0x...",
      "contract":   "CommitteeVerifier",  // or BpsFeeCommitteeVerifier; picks verify.sh's source
      "args": {
        "feeAggregator":    "0x...",  // mutable on-chain afterwards
        "allowlistAdmin":   "0x...",  // mutable on-chain afterwards
        "storageLocations": ["https://..."],
        "rmn":              "0x..."   // immutable — this record is its only readable copy
      },
      "encodedArgs": "0x..."       // abi.encode(dynamicConfig, storageLocations, rmn, versionTag)
    }
  ],
  "priceAdapters": [               // written by DeployPriceAdapter, one entry per token
    {
      "contract": "WstETHUSDL2PriceAdapter",
      "address":  "0x...",
      "args": {                    // every key on every entry; zero where the contract takes none
        "token": "0x...", "rateFeed": "0x...", "usdFeed": "0x...",
        "rateMaxStaleness": 86400, "usdMaxStaleness": 3600,
        "sequencerUptimeFeed": "0x...", "gracePeriod": 3600
      },
      "encodedArgs": "0x..."       // abi.encode of that contract's constructor arguments
    }
  ]
}
```

Every entry is written complete by `DeployVerifier` (or `DeployBpsVerifier`); the loader
rejects a record whose entries are missing their `args`/`encodedArgs` rather than reading
them as zeroes. `contract` is the one exception: an entry without it predates the field and
reads as `CommitteeVerifier`.

Retiring a verifier once its lanes have drained: stage an inbound update of
`{tag, address(0)}` on the resolver, then delete the entry from the record.
`DriftCheck` compares the inbound map closed-world, so an entry left in only one of
the two places is reported as drift.

