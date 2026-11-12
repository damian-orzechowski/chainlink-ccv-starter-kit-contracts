// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// vm.serializeX accumulates into the object; only the final call returns the JSON.
// forge-lint: disable-start(unused-return)

import {BpsFeeCommitteeVerifier} from "../../src/bps/BpsFeeCommitteeVerifier.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {BpsConfigLib} from "../../src/lib/BpsConfigLib.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {FinalityConfigLib} from "../../src/lib/FinalityConfigLib.sol";
import {PriceAdapterLib} from "../../src/lib/PriceAdapterLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {console2} from "forge-std/console2.sol";

/// @title SnapshotOperator
/// @notice Bootstraps the operator config file for a chain FROM LIVE on-chain state
///         (role holders and verifier settings), so an operator can capture the current
///         reality and then edit toward the desired intent.
/// @dev Writes to `out/governance/<alias>-<block>.operator.local.json` in the EXACT
///      `config/operator/chains/<alias>.json` schema, so promotion is a copy. It deliberately
///      does NOT write into `config/` directly: that file records *intent*, and
///      overwriting it with current reality would erase the very difference
///      `DriftCheck` exists to find. (`foundry.toml` enforces this independently:
///      `config/` is mounted read-only except `config/deployments`.)
/// @dev `<block>` in the filename — snapshots accumulate instead of clobbering, so the
///          record of who controlled what, when, survives. Keying on the observed block
///          rather than wall-clock makes it idempotent: re-running against the same block
///          rewrites an identical file, while any state change lands beside its
///          predecessor and stays diffable.
/// @dev Read-only on-chain: no broadcasting. Run without --broadcast. Extends BaseScript
///      for its shared preflights only; the staging plumbing goes unused.
/// @dev There is no `pendingOwner()` getter on these contracts, so a half-finished
///      two-step ownership handover cannot be captured. The verifier's pending
///      storage-locations admin IS readable and is reported to the console (it has no
///      home in the operator schema, which records settled state only).
/// @dev BpsFeeCommitteeVerifier extras: each bps verifier entry gets its live
///      `requireAllTokensPriced`, and `priceAdapters[]` is rebuilt from the adapters the
///      bps verifiers point at (`getPriceAdapter(token)`), described from each adapter's
///      public immutables. The verifier cannot list its tokens, so the token list is the
///      deployment record's `priceAdapters[]` plus the tokens the current operator file
///      declares; an adapter registered by hand for any other token is not seen.
///
/// Usage:
///   forge script script/governance/SnapshotOperator.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
contract SnapshotOperator is BaseScript {
  function run(
    string calldata chainAlias
  ) external {
    // A snapshot from the wrong RPC could be promoted into config/operator/chains/<alias>.json - refuse it.
    ConfigLib.assertChain(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    require(
      deployment.verifiers.length > 0 && deployment.resolver != address(0), "SnapshotOperator: contracts not deployed"
    );
    // Reachability, checked up front for a legible message: a typed call to a codeless
    // address fails with an ABI-decode error that try/catch cannot name.
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      _assertReachable(
        deployment.verifiers[i].addr,
        string.concat("verifier ", ConfigLib.tagToString(deployment.verifiers[i].versionTag))
      );
    }
    _assertReachable(deployment.resolver, "resolver");

    string memory existing = ConfigLib.operatorPath(chainAlias);
    Types.OperatorConfig memory declared;
    if (vm.exists(existing)) declared = ConfigLib.readOperatorByPath(existing);

    Types.OperatorConfig memory operator = snapshot(deployment, declared.priceAdapters);
    BpsConfigLib.VerifierBpsPolicy[] memory policies = snapshotBpsPolicies(deployment);
    _carryOverCommittees(declared, operator, vm.exists(existing));

    console2.log("[SnapshotOperator] chain:", chainAlias);
    for (uint256 i = 0; i < operator.verifiers.length; ++i) {
      Types.VerifierConfig memory v = operator.verifiers[i];
      console2.log("  verifier versionTag:           ", ConfigLib.tagToString(v.versionTag));
      console2.log("    owner:                ", v.roles.owner);
      console2.log("    storageLocationsAdmin:", v.roles.storageLocationsAdmin);
      console2.log("    allowlistAdmin:       ", v.roles.allowlistAdmin);
      console2.log("    feeAggregator:        ", v.roles.feeAggregator);
      console2.log(
        "    allowedFinality:      ", FinalityConfigLib.describe(FinalityConfigLib.encode(v.allowedFinality))
      );
      console2.log("    storageLocations:     ", v.storageLocations.length);
      if (BpsConfigLib.isBpsVerifier(deployment.verifiers[i])) {
        console2.log(
          "    requireAllTokensPriced:",
          BpsConfigLib.requireAllTokensPricedFor(policies, deployment.verifiers[i].versionTag)
        );
      }

      address pendingAdmin = CommitteeVerifier(deployment.verifiers[i].addr).getPendingStorageLocationsAdmin();
      if (pendingAdmin != address(0)) {
        console2.log("    NOTE pending storageLocationsAdmin (handover in flight):", pendingAdmin);
      }
    }
    console2.log("  resolver owner:                ", operator.resolver.roles.owner);
    console2.log("  resolver feeAggregator:        ", operator.resolver.roles.feeAggregator);
    if (deployment.factory != address(0)) {
      console2.log("  factory owner:                 ", operator.factory.roles.owner);
    } else {
      console2.log("  factory owner:                  (no factory recorded for this chain)");
    }
    for (uint256 i = 0; i < operator.priceAdapters.length; ++i) {
      console2.log(
        string.concat(
          "  priceAdapter: ",
          operator.priceAdapters[i].contractName,
          " for ",
          vm.toString(operator.priceAdapters[i].token)
        )
      );
    }

    string memory path = writeSnapshot(chainAlias, operator, policies);
    console2.log("[SnapshotOperator] written:", path);
    console2.log(
      string.concat(
        "[SnapshotOperator] review, then promote: cp ", path, " config/operator/chains/", chainAlias, ".json"
      )
    );
  }

  /// @dev The committee that signs messages LEAVING this chain is applied on the
  ///      destinations, so it cannot be read here. An existing declaration is carried
  ///      over per tag; a chain with no file yet gets an empty one to fill in.
  function _carryOverCommittees(
    Types.OperatorConfig memory declared,
    Types.OperatorConfig memory operator,
    bool hasDeclared
  ) private pure {
    if (!hasDeclared) {
      console2.log("  NOTE signatureConfig left empty per verifier: declare the committee before promoting");
      return;
    }
    for (uint256 i = 0; i < operator.verifiers.length; ++i) {
      if (!ConfigLib.hasVerifierConfigTag(declared, operator.verifiers[i].versionTag)) continue;
      operator.verifiers[i].signatureConfig =
      ConfigLib.verifierConfigByTag(declared, operator.verifiers[i].versionTag).signatureConfig;
    }
  }

  /// @notice THE test seam. Reads every live setting and role for a deployment, one entry
  ///         per recorded verifier.
  /// @dev Typed calls, not raw staticcalls: a missing getter or an undeployed address
  ///      must abort the snapshot rather than silently record `address(0)` as if it
  ///      were the real owner. Writing a zeroed operator file would be worse than failing.
  function snapshot(
    Types.Deployment memory deployment
  ) public view returns (Types.OperatorConfig memory operator) {
    return snapshot(deployment, new Types.PriceAdapterConfig[](0));
  }

  /// @notice As above, with the operator file's current `priceAdapters[]` supplying the
  ///         tokens the record does not, and the fallback for what chain cannot describe.
  function snapshot(
    Types.Deployment memory deployment,
    Types.PriceAdapterConfig[] memory declaredAdapters
  ) public view returns (Types.OperatorConfig memory operator) {
    operator.aliasName = deployment.aliasName;
    operator.priceAdapters = snapshotPriceAdapters(deployment, declaredAdapters);

    operator.verifiers = new Types.VerifierConfig[](deployment.verifiers.length);
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      CommitteeVerifier verifier = CommitteeVerifier(deployment.verifiers[i].addr);
      CommitteeVerifier.DynamicConfig memory dynamicConfig = verifier.getDynamicConfig();
      bytes4 finality = verifier.getAllowedFinalityConfig();
      if (FinalityConfigLib.hasReservedBits(finality)) {
        console2.log(
          string.concat(
            "  NOTE verifier ",
            ConfigLib.tagToString(deployment.verifiers[i].versionTag),
            " allowedFinality sets reserved bits; only the two assigned fields are recorded"
          )
        );
      }
      operator.verifiers[i].versionTag = deployment.verifiers[i].versionTag;
      operator.verifiers[i].allowedFinality = FinalityConfigLib.decode(finality);
      operator.verifiers[i].storageLocations = verifier.getStorageLocations();
      operator.verifiers[i].roles = Types.VerifierRoles({
        owner: verifier.owner(),
        storageLocationsAdmin: verifier.getStorageLocationsAdmin(),
        allowlistAdmin: dynamicConfig.allowlistAdmin,
        feeAggregator: dynamicConfig.feeAggregator
      });
    }

    VersionedVerifierResolver resolver = VersionedVerifierResolver(deployment.resolver);
    operator.resolver.roles.owner = resolver.owner();
    operator.resolver.roles.feeAggregator = resolver.getFeeAggregator();

    // Optional: not every chain records a factory (only the CREATE2 bootstrap chain
    // needs one long-term), so an absent factory is a zero, not a failure.
    if (deployment.factory != address(0)) {
      CREATE2Factory factory = CREATE2Factory(deployment.factory);
      operator.factory.roles.owner = factory.owner();
      operator.factory.roles.allowlist = factory.getAllowList();
    }
  }

  // --------------------------------------------------------------------------
  //  BpsFeeCommitteeVerifier extras
  // --------------------------------------------------------------------------

  /// @notice `requireAllTokensPriced` of every recorded bps verifier; stock verifiers have
  ///         no such setting and get no entry.
  function snapshotBpsPolicies(
    Types.Deployment memory deployment
  ) public view returns (BpsConfigLib.VerifierBpsPolicy[] memory policies) {
    policies = new BpsConfigLib.VerifierBpsPolicy[](deployment.verifiers.length);
    uint256 n = 0;
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (!BpsConfigLib.isBpsVerifier(deployment.verifiers[i])) continue;
      policies[n++] = BpsConfigLib.VerifierBpsPolicy({
        versionTag: deployment.verifiers[i].versionTag,
        requireAllTokensPriced: BpsFeeCommitteeVerifier(deployment.verifiers[i].addr).requireAllTokensPriced()
      });
    }
    assembly {
      mstore(policies, n)
    }
  }

  /// @notice The `priceAdapters[]` section, rebuilt from chain for every token the record
  ///         or `declared` names (declared order first, then recorded-only tokens).
  /// @dev Per token, the adapter described is the one the bps verifiers point at, else
  ///      the recorded one (deployed, not yet registered). A token with neither, or whose
  ///      adapter is not a type the schema can describe, keeps its declared entry; with no
  ///      declared entry either it is left out. Each fallback is logged as a NOTE.
  function snapshotPriceAdapters(
    Types.Deployment memory deployment,
    Types.PriceAdapterConfig[] memory declared
  ) public view returns (Types.PriceAdapterConfig[] memory adapters) {
    address[] memory tokens = _adapterTokens(deployment, declared);
    adapters = new Types.PriceAdapterConfig[](tokens.length);
    uint256 n = 0;
    for (uint256 i = 0; i < tokens.length; ++i) {
      (bool keep, Types.PriceAdapterConfig memory entry) = _snapshotAdapter(deployment, declared, tokens[i]);
      if (keep) adapters[n++] = entry;
    }
    assembly {
      mstore(adapters, n)
    }
  }

  /// @notice Reads an adapter's constructor arguments back from its public immutables
  ///         (see `PriceAdapterLib.describe`).
  function describeAdapter(
    address adapter
  ) public view returns (bool known, Types.PriceAdapterConfig memory c) {
    return PriceAdapterLib.describe(adapter);
  }

  function _snapshotAdapter(
    Types.Deployment memory deployment,
    Types.PriceAdapterConfig[] memory declared,
    address token
  ) private view returns (bool keep, Types.PriceAdapterConfig memory entry) {
    string memory label = vm.toString(token);
    (bool isDeclared, Types.PriceAdapterConfig memory declaredEntry) = _declaredFor(declared, token);
    address live = _registeredAdapter(deployment, token);
    address recorded = ConfigLib.priceAdapterByToken(deployment, token);
    address source = live != address(0) ? live : recorded;

    if (source == address(0)) {
      console2.log(string.concat("  NOTE priceAdapter for ", label, " is declared but not deployed: carried over"));
      return (isDeclared, declaredEntry); // only a declared token can have neither
    }
    if (live == address(0)) {
      console2.log(
        string.concat("  NOTE recorded priceAdapter for ", label, " is not registered on any bps verifier yet")
      );
    } else if (recorded != address(0) && recorded != live) {
      console2.log(
        string.concat(
          "  NOTE bps verifier prices ",
          label,
          " with ",
          vm.toString(live),
          ", not the recorded ",
          vm.toString(recorded),
          ": the registered one is described"
        )
      );
    }

    (bool known, Types.PriceAdapterConfig memory described) = describeAdapter(source);
    if (known && described.token == token) return (known, described);
    console2.log(
      string.concat(
        "  NOTE priceAdapter ",
        vm.toString(source),
        " for ",
        label,
        " cannot be described from chain: ",
        isDeclared ? "declared entry carried over" : "left out"
      )
    );
    return (isDeclared, declaredEntry);
  }

  /// @dev The adapter the bps verifiers use for `token`; zero when none registers one.
  ///      `priceAdapters[]` is per chain, so two bps verifiers that disagree cannot both
  ///      be captured: the first is kept and the disagreement logged.
  function _registeredAdapter(
    Types.Deployment memory deployment,
    address token
  ) private view returns (address found) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (!BpsConfigLib.isBpsVerifier(deployment.verifiers[i])) continue;
      address a = address(BpsFeeCommitteeVerifier(deployment.verifiers[i].addr).getPriceAdapter(token));
      if (a == address(0)) continue;
      if (found == address(0)) {
        found = a;
      } else if (a != found) {
        console2.log(
          string.concat(
            "  NOTE bps verifiers disagree on the adapter for ",
            vm.toString(token),
            ": ",
            vm.toString(found),
            " kept, ",
            vm.toString(a),
            " (verifier ",
            ConfigLib.tagToString(deployment.verifiers[i].versionTag),
            ") not captured"
          )
        );
      }
    }
  }

  function _adapterTokens(
    Types.Deployment memory deployment,
    Types.PriceAdapterConfig[] memory declared
  ) private pure returns (address[] memory tokens) {
    tokens = new address[](declared.length + deployment.priceAdapters.length);
    uint256 n = 0;
    for (uint256 i = 0; i < declared.length; ++i) {
      tokens[n++] = declared[i].token;
    }
    for (uint256 i = 0; i < deployment.priceAdapters.length; ++i) {
      (bool seen,) = _declaredFor(declared, deployment.priceAdapters[i].args.token);
      if (!seen) tokens[n++] = deployment.priceAdapters[i].args.token;
    }
    assembly {
      mstore(tokens, n)
    }
  }

  function _declaredFor(
    Types.PriceAdapterConfig[] memory declared,
    address token
  ) private pure returns (bool found, Types.PriceAdapterConfig memory entry) {
    for (uint256 i = 0; i < declared.length; ++i) {
      found = declared[i].token == token;
      if (found) return (found, declared[i]);
    }
  }

  // --------------------------------------------------------------------------
  //  writing
  // --------------------------------------------------------------------------

  /// @notice Serialises a snapshot with no bps verifier policies.
  function writeSnapshot(
    string memory chainAlias,
    Types.OperatorConfig memory operator
  ) public returns (string memory path) {
    return writeSnapshot(chainAlias, operator, new BpsConfigLib.VerifierBpsPolicy[](0));
  }

  /// @notice Serialises a snapshot in the `config/operator/chains` schema.
  /// @dev Assembled by hand: vm.serialize* has no array-of-objects form (same approach as
  ///      `ConfigLib.writeDeploymentByPath`). vm.writeJson re-parses the result, so a
  ///      malformed string fails here rather than at the next load.
  /// @param policies `requireAllTokensPriced` per bps verifier tag; written only on those
  ///        entries (ValidateConfig rejects the key on a stock verifier).
  /// @return path The file written.
  function writeSnapshot(
    string memory chainAlias,
    Types.OperatorConfig memory operator,
    BpsConfigLib.VerifierBpsPolicy[] memory policies
  ) public returns (string memory path) {
    string memory json = string.concat(
      "{\"alias\":",
      _quoted(chainAlias),
      ",\"verifiers\":",
      _verifiersJson(operator.verifiers, policies),
      ",\"resolver\":{\"roles\":{\"owner\":\"",
      vm.toString(operator.resolver.roles.owner),
      "\",\"feeAggregator\":\"",
      vm.toString(operator.resolver.roles.feeAggregator),
      "\"}},\"factory\":{\"roles\":{\"owner\":\"",
      vm.toString(operator.factory.roles.owner),
      "\",\"allowlist\":",
      _addressArrayJson(operator.factory.roles.allowlist),
      "}},\"priceAdapters\":",
      _priceAdaptersJson(operator.priceAdapters),
      "}"
    );

    vm.createDir("out/governance", true); // idempotent; survives a fresh clone
    // The block number keeps successive snapshots from clobbering each other.
    path = string.concat("out/governance/", chainAlias, "-", vm.toString(block.number), ".operator.local.json");
    vm.writeJson(json, path);
  }

  function _verifiersJson(
    Types.VerifierConfig[] memory verifiers,
    BpsConfigLib.VerifierBpsPolicy[] memory policies
  ) private pure returns (string memory json) {
    json = "[";
    for (uint256 i = 0; i < verifiers.length; ++i) {
      string memory settings = string.concat(
        "{\"versionTag\":\"",
        ConfigLib.tagToString(verifiers[i].versionTag),
        "\",\"allowedFinality\":",
        _finalityJson(verifiers[i].allowedFinality),
        ",\"storageLocations\":",
        _stringArrayJson(verifiers[i].storageLocations),
        ",\"signatureConfig\":{\"threshold\":",
        vm.toString(uint256(verifiers[i].signatureConfig.threshold)),
        ",\"signers\":",
        _addressArrayJson(verifiers[i].signatureConfig.signers),
        "}",
        _policyJson(policies, verifiers[i].versionTag)
      );
      json =
        string.concat(json, i == 0 ? "" : ",", settings, ",\"roles\":", _verifierRolesJson(verifiers[i].roles), "}");
    }
    json = string.concat(json, "]");
  }

  /// @dev `,"requireAllTokensPriced":<bool>` for a bps verifier's tag, else nothing.
  function _policyJson(
    BpsConfigLib.VerifierBpsPolicy[] memory policies,
    bytes4 tag
  ) private pure returns (string memory) {
    for (uint256 i = 0; i < policies.length; ++i) {
      if (policies[i].versionTag != tag) continue;
      return string.concat(",\"requireAllTokensPriced\":", policies[i].requireAllTokensPriced ? "true" : "false");
    }
    return "";
  }

  /// @dev Only the keys the entry's contract takes: the loader rejects any other.
  function _priceAdaptersJson(
    Types.PriceAdapterConfig[] memory adapters
  ) private pure returns (string memory json) {
    json = "[";
    for (uint256 i = 0; i < adapters.length; ++i) {
      Types.PriceAdapterConfig memory a = adapters[i];
      string memory entry =
        string.concat("{\"contract\":", _quoted(a.contractName), ",\"token\":\"", vm.toString(a.token), "\"");
      if (keccak256(bytes(a.contractName)) == keccak256(bytes(ConfigLib.L2_PRICE_ADAPTER))) {
        entry = string.concat(
          entry,
          ",\"rateFeed\":\"",
          vm.toString(a.rateFeed),
          "\",\"rateMaxStaleness\":",
          vm.toString(a.rateMaxStaleness)
        );
      }
      entry = string.concat(
        entry, ",\"usdFeed\":\"", vm.toString(a.usdFeed), "\",\"usdMaxStaleness\":", vm.toString(a.usdMaxStaleness)
      );
      if (keccak256(bytes(a.contractName)) == keccak256(bytes(ConfigLib.L2_PRICE_ADAPTER))) {
        entry = string.concat(
          entry,
          ",\"sequencerUptimeFeed\":\"",
          vm.toString(a.sequencerUptimeFeed),
          "\",\"gracePeriod\":",
          vm.toString(a.gracePeriod)
        );
      }
      json = string.concat(json, i == 0 ? "" : ",", entry, "}");
    }
    json = string.concat(json, "]");
  }

  function _verifierRolesJson(
    Types.VerifierRoles memory roles
  ) private pure returns (string memory) {
    return string.concat(
      "{\"owner\":\"",
      vm.toString(roles.owner),
      "\",\"storageLocationsAdmin\":\"",
      vm.toString(roles.storageLocationsAdmin),
      "\",\"allowlistAdmin\":\"",
      vm.toString(roles.allowlistAdmin),
      "\",\"feeAggregator\":\"",
      vm.toString(roles.feeAggregator),
      "\"}"
    );
  }

  /// @dev ConfigLib rejects a literal minBlockDepth of 0, so absent fields are omitted.
  function _finalityJson(
    Types.AllowedFinality memory finality
  ) private pure returns (string memory json) {
    json = "{";
    if (finality.allowSafeTag) json = string.concat(json, "\"allowSafeTag\":true");
    if (finality.minBlockDepth != 0) {
      json = string.concat(
        json, finality.allowSafeTag ? "," : "", "\"minBlockDepth\":", vm.toString(uint256(finality.minBlockDepth))
      );
    }
    json = string.concat(json, "}");
  }

  function _addressArrayJson(
    address[] memory values
  ) private pure returns (string memory json) {
    json = "[";
    for (uint256 i = 0; i < values.length; ++i) {
      json = string.concat(json, i == 0 ? "" : ",", "\"", vm.toString(values[i]), "\"");
    }
    json = string.concat(json, "]");
  }

  function _stringArrayJson(
    string[] memory values
  ) private pure returns (string memory json) {
    json = "[";
    for (uint256 i = 0; i < values.length; ++i) {
      json = string.concat(json, i == 0 ? "" : ",", _quoted(values[i]));
    }
    json = string.concat(json, "]");
  }

  /// @dev JSON string literal; URLs and aliases only need the quote and backslash escapes.
  function _quoted(
    string memory value
  ) private pure returns (string memory) {
    bytes memory b = bytes(value);
    bytes memory out = new bytes(b.length * 2 + 2);
    uint256 n = 0;
    out[n++] = '"';
    for (uint256 i = 0; i < b.length; ++i) {
      if (b[i] == '"' || b[i] == "\\") out[n++] = "\\";
      out[n++] = b[i];
    }
    out[n++] = '"';
    bytes memory trimmed = new bytes(n);
    for (uint256 i = 0; i < n; ++i) {
      trimmed[i] = out[i];
    }
    return string(trimmed);
  }
}
