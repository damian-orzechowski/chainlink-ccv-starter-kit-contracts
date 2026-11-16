// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Types
/// @notice Plain data structs mirroring the JSON schema under `config/`.
/// @dev Kept deliberately decoupled from the Chainlink contract structs so the
///      config layer has no compile dependency on the contracts. The configure/
///      scripts translate these into the exact Chainlink argument structs
///      (e.g. SignatureQuorumValidator.SignatureConfig) at the call site.
/// @dev Adding a field here also means adding a comparison in `DriftCheck` and a case in
///      `DriftCheck.t.sol`. Nothing enforces that, so an uncompared field silently makes
///      the drift check incomplete.
/// @dev The recorded deploy params are exempt from that rule: they record what a past
///      deploy constructed, not declared intent, so differing from current config is
///      normal rather than drift.
library Types {
  // ----------------------------- config/chains ------------------------------
  /// @dev Chainlink's per-chain reference, synced from the CCIP API and committed. The
  ///      operator's own values live in `config/operator/chains/<alias>.json`.
  struct ChainConfig {
    string aliasName; // stable key; matches rpc alias + operator/deployment files
    uint256 chainId;
    uint64 chainSelector; // parsed from a JSON string (selectors exceed 2^53)
    address rmn; // Chainlink-provided; MUST be non-zero
    address router; // Chainlink's local CCIP router; default for lanes
    address[] feeTokens; // fee tokens to report on / sweep. Empty = no-op for fee scripts.
  }

  /// @dev Alternatives a sender may request, not a conjunction. Full finality is always
  ///      allowed; `minBlockDepth` is a floor on depth requests. FinalityConfigLib encodes it.
  struct AllowedFinality {
    bool allowSafeTag; // accept a request for the `safe` tag
    uint16 minBlockDepth; // accept a depth request of at least this many blocks; 0 = none
  }

  // -------------------------- config/operator/lanes --------------------------
  struct LaneEndpoint {
    string aliasName;
    uint64 chainSelector;
  }

  struct SignatureConfig {
    uint8 threshold;
    address[] signers; // FULL replacement set (no incremental add/remove)
  }

  struct RemoteChainConfig {
    address router; // router == address(0) is the outbound emergency lever
    uint16 feeUSDCents;
    uint32 gasForVerification;
    uint16 payloadSizeBytes;
  }

  /// @dev `allowedSenders` is the desired FULL set for the lane's destination.
  struct AllowlistConfig {
    bool allowlistEnabled;
    address[] allowedSenders;
  }

  struct LaneConfig {
    string name;
    LaneEndpoint source;
    LaneEndpoint dest;
    bytes4 versionTag;
    RemoteChainConfig remote;
    AllowlistConfig allowlist;
  }

  /// @dev A lane plus the committee that signs its messages. The committee is not a lane
  ///      field: it is declared on the SOURCE chain and resolved by `ConfigLib`, so every
  ///      lane leaving one chain under one tag carries the same set.
  struct LaneCommittee {
    LaneConfig lane;
    SignatureConfig committee;
  }

  // ------------------------- config/operator/chains --------------------------
  /// @dev Everything the operator declares for ONE verifier, keyed by its versionTag like
  ///      the deployment record. All of it is that verifier's own: its committee signs the
  ///      messages leaving this chain and publishes them to its `storageLocations`, and
  ///      `allowedFinality` is what a sender may ask of it. Declared BEFORE deploying it.
  struct VerifierConfig {
    bytes4 versionTag;
    AllowedFinality allowedFinality; // what a sender may request; empty block = full finality only
    string[] storageLocations; // where this verifier's signers publish
    // The committee, applied on every destination keyed by THIS chain's selector. An empty
    // set (threshold 0) means the chain is never a source under this tag.
    SignatureConfig signatureConfig;
    VerifierRoles roles;
  }

  /// @dev The intended holder of each role on one verifier.
  struct VerifierRoles {
    address owner;
    address storageLocationsAdmin;
    address allowlistAdmin;
    address feeAggregator;
  }

  struct ResolverRoles {
    address owner;
    address feeAggregator;
  }

  struct FactoryRoles {
    address owner;
    // The createAndCall allowlist the factory SHOULD hold: the desired full set, not a
    // delta. [] means nobody may createAndCall.
    address[] allowlist;
  }

  /// @dev The single resolver and factory per chain. Both carry role holders only, under
  ///      the same `roles` key a verifier entry uses, so one rule covers the whole file.
  struct ResolverConfig {
    ResolverRoles roles;
  }

  struct FactoryConfig {
    FactoryRoles roles;
  }

  /// @dev One IPriceAdapter for a BpsFeeCommitteeVerifier, keyed by the token it prices
  ///      (unique per chain). Adapters are ownerless and immutable: these are constructor
  ///      arguments, declared BEFORE deploying it, and changing one means a new adapter.
  ///      The fields are the union of every adapter's arguments; `contractName` decides
  ///      which apply, and the loader rejects a key that adapter does not take.
  /// @dev Exempt from the DriftCheck rule above: nothing on-chain can move away from
  ///      these values after construction.
  struct PriceAdapterConfig {
    string contractName; // WstETHUSDPriceAdapter | WstETHUSDL2PriceAdapter
    address token; // the token the adapter prices
    address rateFeed; // L2 only: wstETH/ETH feed
    address usdFeed; // L1: wstETH/USD feed; L2: ETH/USD feed
    uint256 rateMaxStaleness; // L2 only, seconds
    uint256 usdMaxStaleness; // seconds (the L1 adapter's `maxStaleness`)
    address sequencerUptimeFeed; // L2 only
    uint256 gracePeriod; // L2 only, seconds
  }

  /// @dev One chain's operator config: every verifier it runs, then the single resolver
  ///      and factory, then the price adapters its bps verifiers use.
  struct OperatorConfig {
    string aliasName;
    VerifierConfig[] verifiers; // one entry per verifier; tags unique per chain
    ResolverConfig resolver;
    FactoryConfig factory;
    PriceAdapterConfig[] priceAdapters; // optional; tokens unique per chain
  }

  // --------------------------- config/deployments ---------------------------
  // Deploy-time params are recorded beside each address: `encodedArgs` mirrors the plain
  // fields, both set from the same locals at the `new` call. The address is the presence
  // flag — zero means that contract is not deployed and its params carry no meaning.

  struct FactoryDeployParams {
    address deployer; // the nonce-0 EOA the CREATE address derives from
    address[] allowList;
    bytes encodedArgs; // abi.encode(allowList)
  }

  /// @dev The resolver takes no constructor arguments, so `encodedArgs` is always empty.
  ///      `salt` is not an argument either — it fixes the CREATE2 address, which makes it
  ///      the deploy-time input worth recording.
  struct ResolverDeployParams {
    bytes32 salt;
    bytes encodedArgs;
  }

  /// @dev One deployed verifier. Mirrors one entry of the resolver's
  ///      inbound map (bytes4 versionTag -> verifier); tags are unique per chain.
  struct VerifierDeployment {
    bytes4 versionTag; // immutable on-chain
    address addr;
    // Which implementation was deployed (CommitteeVerifier or a subclass sharing its
    // constructor, e.g. BpsFeeCommitteeVerifier). Selects the source verify.sh verifies.
    string contractName;
    address feeAggregator; // DynamicConfig member; mutable on-chain afterwards
    address allowlistAdmin; // DynamicConfig member; mutable on-chain afterwards
    string[] storageLocations; // mutable on-chain afterwards
    address rmn; // immutable on-chain
    bytes encodedArgs; // abi.encode(dynamicConfig, storageLocations, rmn, versionTag)
  }

  /// @dev One deployed IPriceAdapter: the declared params it was constructed from, as of
  ///      the deploy. Adapters are ownerless and immutable, so this is all of their state.
  struct PriceAdapterDeployment {
    address addr;
    PriceAdapterConfig args;
    bytes encodedArgs; // abi.encode of that adapter's own constructor arguments
  }

  struct Deployment {
    string aliasName;
    address factory;
    FactoryDeployParams factoryParams;
    address resolver;
    ResolverDeployParams resolverParams;
    // Which catalogued versionTags are DEPLOYED on this chain, and at what address.
    // config/operator.json enumerates the tag identities repo-wide; this record maps
    // the deployed ones to addresses.
    VerifierDeployment[] verifiers;
    // Price adapters for the BpsFeeCommitteeVerifier, one per token.
    PriceAdapterDeployment[] priceAdapters;
  }
}
