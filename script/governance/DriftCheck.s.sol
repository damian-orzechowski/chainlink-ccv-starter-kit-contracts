// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BpsFeeCommitteeVerifier} from "../../src/bps/BpsFeeCommitteeVerifier.sol";
import {BpsFeeConfig} from "../../src/bps/BpsFeeConfig.sol";
import {BpsConfigLib} from "../../src/lib/BpsConfigLib.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {FinalityConfigLib} from "../../src/lib/FinalityConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CREATE2Factory} from "@chainlink/contracts-ccip/contracts/CREATE2Factory.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {
  SignatureQuorumValidator
} from "@chainlink/contracts-ccip/contracts/ccvs/components/SignatureQuorumValidator.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title DriftCheck
/// @notice READ-ONLY comparison of the FULL declared config
///         (`config/operator/chains`, `config/operator/lanes`, `config/deployments`)
///         against live on-chain getters. Designed to be CI-schedulable with DISTINCT
///         exit codes for clean / drift / RPC-unavailable — see drift-check.sh,
///         which maps this script's outcome to codes 0 / 1 / 2.
///
/// @dev Convention: on ANY drift, log a line beginning with the marker `DRIFT_DETECTED`
///      and revert. The wrapper greps for that marker to distinguish real drift
///      (exit 1) from an RPC/connection failure (exit 2). A clean run returns
///      normally (exit 0).
///
/// @dev A wrong `--rpc-url` is caught before anything is read: `run()` checks the
///      connected chainid against the chain config (`ConfigLib.assertChain`), and that
///      revert carries no marker, so the wrapper reports exit 2. Once the chain matches, a
///      recorded address with no code is a bad RECORD (a broadcast that never landed, a
///      same-chainid fork deploy, another chain's file, a hand-edited entry), so it is
///      reported as drift per contract and only that
///      contract's checks are skipped: one stale entry must not silence every other
///      comparison on the chain. The code-length guard is load-bearing for a second
///      reason: a staticcall to a codeless address SUCCEEDS with empty returndata, and the
///      ensuing ABI-decode failure is not catchable by try/catch (same trap documented in
///      `BalanceReport`).
///
/// @dev Lane direction follows the same mapping the configure scripts encode, which is
///      dictated by where each value is read on-chain:
///        - signature config  -> DEST verifier,   keyed by SOURCE selector
///          (`getSignatureConfig(sourceChainSelector)`)
///        - remote chain cfg  -> SOURCE verifier, keyed by DEST selector
///          (`getRemoteChainConfig(remoteChainSelector)`)
///        - outbound impl     -> SOURCE resolver, keyed by DEST selector
///        - inbound impl      -> LOCAL resolver,  keyed by each recorded verifier's versionTag
///
/// @dev Verifier-scoped checks run per RECORDED VERIFIER (`deployments/<alias>.json`
///      `verifiers` array), and the resolver maps are compared CLOSED-WORLD: an on-chain
///      inbound registration whose tag is not in the record is drift (a registered
///      inbound verifier is attack surface), as is an outbound entry no lane declares.
///      Each recorded verifier's signature configs are compared CLOSED-WORLD too
///      (`getAllSignatureConfigs()`): a committee for a source selector no lane declares
///      is still a valid quorum, so it is drift. `remoteChainConfig` is NOT closed-world:
///      `BaseVerifier` keeps it in a plain mapping with no enumerating getter, so a
///      retired lane's source-side entry is invisible here (pause it with
///      `make pause-lane` before retiring the lane file).
///
/// @dev One check needs no RPC: each recorded verifier's deploy-time `rmn` against the
///      chain config's (`checkRecordedRmn`). `rmn` is an immutable constructor argument
///      with no on-chain getter, and `sync-ccip-config.sh` rewrites the config side from
///      the CCIP API, so the record is the only place the two can be compared.
///
/// @dev A recorded BpsFeeCommitteeVerifier gets one more pass, `checkBpsFees`, over the
///      settings only it has. It is separate from `checkAll` and reads nothing for a
///      stock verifier, so the standard path is unchanged.
///
/// Usage (direct):
///   forge script script/governance/DriftCheck.s.sol --sig "run(string)" sepolia --rpc-url $SEPOLIA_RPC_URL
/// Usage (CI, with exit-code mapping):
///   script/governance/drift-check.sh sepolia $SEPOLIA_RPC_URL
contract DriftCheck is Script {
  error DriftDetected(uint256 count);

  function run(
    string calldata chainAlias
  ) external view {
    ConfigLib.assertChain(chainAlias);
    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    Types.OperatorConfig memory operator = ConfigLib.readOperator(chainAlias);
    Types.LaneCommittee[] memory lanes = ConfigLib.readLaneCommitteesAllowingDuplicates();

    console2.log("[DriftCheck] chain:", chainAlias);
    console2.log("  lanes considered:", lanes.length);

    uint256 drift = checkAll(deployment, chainConfig, operator, lanes);
    // A no-op unless the record holds a BpsFeeCommitteeVerifier.
    drift += checkBpsFees(deployment, BpsConfigLib.readLaneBpsFees(), BpsConfigLib.readVerifierPolicies(chainAlias));

    if (drift > 0) {
      console2.log("DRIFT_DETECTED total mismatches:", drift);
      revert DriftDetected(drift);
    }
    console2.log("[DriftCheck] clean:", chainAlias);
  }

  function checkAll(
    Types.Deployment memory deployment,
    Types.ChainConfig memory chainConfig,
    Types.OperatorConfig memory operator,
    Types.LaneCommittee[] memory lanes
  ) public view returns (uint256 drift) {
    drift += checkReachability(deployment);
    drift += checkRecordedRmn(deployment, chainConfig);
    drift += checkRoles(deployment, operator);
    drift += checkVerifierConfig(deployment, operator);
    drift += checkResolverImplementations(deployment, operator, lanes);
    drift += checkLanes(deployment, operator, lanes);
    drift += checkSignatureConfigs(deployment, operator, lanes);
    drift += checkLaneDirections(operator, lanes);
  }

  /// @notice Two lane files for the same direction (`ConfigLib.sameDirection`), reported
  ///         once per pair that touches this chain.
  function checkLaneDirections(
    Types.OperatorConfig memory operator,
    Types.LaneCommittee[] memory lanes
  ) public pure returns (uint256 drift) {
    for (uint256 i = 0; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = lanes[i].lane;
      for (uint256 j = i + 1; j < lanes.length; ++j) {
        Types.LaneConfig memory other = lanes[j].lane;
        if (!ConfigLib.sameDirection(lane, other)) continue;
        if (!_touches(lane, operator.aliasName) && !_touches(other, operator.aliasName)) continue;
        console2.log(
          string.concat(
            "DRIFT_DETECTED lanes ",
            lane.name,
            " and ",
            other.name,
            " declare the same direction - remove one file; every configure script refuses to run until then"
          )
        );
        ++drift;
      }
    }
  }

  function _touches(
    Types.LaneConfig memory lane,
    string memory aliasName
  ) private pure returns (bool) {
    return _stringsEqual(lane.source.aliasName, aliasName) || _stringsEqual(lane.dest.aliasName, aliasName);
  }

  /// @notice Owners and admin/fee roles vs `config/operator/chains/<alias>.json`.
  /// @dev There is no `pendingOwner()` getter on these contracts, so a half-finished
  ///      two-step handover is invisible here; the accept leg must be confirmed by the
  ///      ceremony itself. `getPendingStorageLocationsAdmin()` DOES exist and is
  ///      reported, because a stuck pending admin is a real operational state.
  function checkRoles(
    Types.Deployment memory deployment,
    Types.OperatorConfig memory operator
  ) public view returns (uint256 drift) {
    // Role holders are per verifier: each recorded verifier is compared against ITS
    // roles entry. A recorded verifier with no entry is drift — the operator file is the
    // machine-checkable intent, and a verifier without intent cannot be checked.
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      string memory prefix = string.concat("verifier ", ConfigLib.tagToString(deployment.verifiers[i].versionTag), " ");
      if (!ConfigLib.hasVerifierConfigTag(operator, deployment.verifiers[i].versionTag)) {
        console2.log(
          string.concat(
            "DRIFT_DETECTED ",
            prefix,
            "has no roles entry - add a verifiers[] entry to config/operator/chains/",
            operator.aliasName,
            ".json"
          )
        );
        ++drift;
        continue;
      }
      if (!_hasCode(deployment.verifiers[i].addr)) continue; // reported by checkReachability
      Types.VerifierRoles memory expected =
      ConfigLib.verifierConfigByTag(operator, deployment.verifiers[i].versionTag).roles;

      CommitteeVerifier verifier = CommitteeVerifier(deployment.verifiers[i].addr);
      drift += _diffAddress(string.concat(prefix, "owner"), expected.owner, verifier.owner());
      drift += _diffAddress(
        string.concat(prefix, "storageLocationsAdmin"),
        expected.storageLocationsAdmin,
        verifier.getStorageLocationsAdmin()
      );

      CommitteeVerifier.DynamicConfig memory dynamicConfig = verifier.getDynamicConfig();
      drift += _diffAddress(string.concat(prefix, "feeAggregator"), expected.feeAggregator, dynamicConfig.feeAggregator);
      drift += _diffAddress(
        string.concat(prefix, "allowlistAdmin"), expected.allowlistAdmin, dynamicConfig.allowlistAdmin
      );

      address pendingAdmin = verifier.getPendingStorageLocationsAdmin();
      if (pendingAdmin != address(0)) {
        console2.log(string.concat("  NOTE ", prefix, "has a pending storageLocationsAdmin (not drift):"), pendingAdmin);
      }
    }

    if (_hasCode(deployment.resolver)) {
      VersionedVerifierResolver resolver = VersionedVerifierResolver(deployment.resolver);
      drift += _diffAddress("resolver owner", operator.resolver.roles.owner, resolver.owner());
      drift += _diffAddress(
        "resolver feeAggregator", operator.resolver.roles.feeAggregator, resolver.getFeeAggregator()
      );
    }

    if (_hasCode(deployment.factory) && operator.factory.roles.owner != address(0)) {
      drift += _diffAddress("factory owner", operator.factory.roles.owner, CREATE2Factory(deployment.factory).owner());
    }

    if (_hasCode(deployment.factory)) {
      drift += _diffAddressSet(
        "factory allowlist", operator.factory.roles.allowlist, CREATE2Factory(deployment.factory).getAllowList()
      );
    }
  }

  /// @notice Chain-scoped verifier state vs the deployment record + `config/operator/chains/<alias>.json`,
  ///         checked per recorded verifier.
  /// @dev `versionTag` is immutable on-chain (`BaseVerifier.i_versionTag`), so a mismatch
  ///      here is unfixable by configuration — it means the recorded address is the wrong
  ///      verifier, or the record was edited after deploy. Flagged loudly for that reason.
  function checkVerifierConfig(
    Types.Deployment memory deployment,
    Types.OperatorConfig memory operator
  ) public view returns (uint256 drift) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (!_hasCode(deployment.verifiers[i].addr)) continue; // reported by checkReachability
      CommitteeVerifier verifier = CommitteeVerifier(deployment.verifiers[i].addr);
      string memory prefix = string.concat("verifier ", ConfigLib.tagToString(deployment.verifiers[i].versionTag), " ");

      bytes4 onChainTag = verifier.versionTag();
      if (onChainTag != deployment.verifiers[i].versionTag) {
        console2.log(
          string.concat(
            "DRIFT_DETECTED ", prefix, "versionTag (IMMUTABLE - wrong verifier address, or record edited post-deploy)"
          )
        );
        console2.log("  expected:", ConfigLib.tagToString(deployment.verifiers[i].versionTag));
        console2.log("  actual:  ", ConfigLib.tagToString(onChainTag));
        ++drift;
      }

      // Per tag, like the roles: two live verifiers may legitimately differ.
      if (!ConfigLib.hasVerifierConfigTag(operator, deployment.verifiers[i].versionTag)) continue;
      Types.VerifierConfig memory declared = ConfigLib.verifierConfigByTag(operator, deployment.verifiers[i].versionTag);
      drift += _diffFinality(
        string.concat(prefix, "allowedFinality"),
        FinalityConfigLib.encode(declared.allowedFinality),
        verifier.getAllowedFinalityConfig()
      );
      drift += _diffStrings(
        string.concat(prefix, "storageLocations"), declared.storageLocations, verifier.getStorageLocations()
      );
    }
  }

  /// @notice Each recorded verifier's deploy-time `rmn` vs `config/chains/<alias>.json` `.rmn`.
  /// @dev `rmn` is immutable on-chain (`BaseVerifier.i_rmn`, internal, no getter), so the
  ///      record is the only witness of what each verifier was built with. A mismatch is
  ///      unfixable by configuration: either the upstream ARMProxy moved and that verifier
  ///      needs a redeploy, or the chain config is wrong. Left unflagged, the next
  ///      `deploy-verifier` would silently build a verifier on a different RMN than its
  ///      siblings. Pure record-vs-config, so it runs even for a codeless record.
  function checkRecordedRmn(
    Types.Deployment memory deployment,
    Types.ChainConfig memory chainConfig
  ) public pure returns (uint256 drift) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      drift += _diffAddress(
        string.concat(
          "verifier ",
          ConfigLib.tagToString(deployment.verifiers[i].versionTag),
          " rmn (IMMUTABLE - recorded deploy arg vs config/chains; not fixable by configuration: redeploy the verifier, or the chain config is wrong)"
        ),
        deployment.verifiers[i].rmn,
        chainConfig.rmn
      );
    }
  }

  /// @notice Resolver inbound/outbound implementation maps vs deployments + lanes,
  ///         compared CLOSED-WORLD in both directions.
  /// @dev Inbound must equal exactly the recorded verifiers: a recorded tag missing
  ///      on-chain is drift, and an on-chain tag missing from the record is drift too —
  ///      an unknown registered inbound verifier is attack surface, not slack. Outbound
  ///      is derived from lanes (dest selector -> verifier of the lane's versionTag),
  ///      mirroring what `ApplyInbound/OutboundImplementationUpdates` stage; an on-chain
  ///      outbound entry no lane declares is drift for the same reason.
  function checkResolverImplementations(
    Types.Deployment memory deployment,
    Types.OperatorConfig memory operator,
    Types.LaneCommittee[] memory lanes
  ) public view returns (uint256 drift) {
    if (!_hasCode(deployment.resolver)) return 0; // unrecorded, or reported by checkReachability
    VersionedVerifierResolver resolver = VersionedVerifierResolver(deployment.resolver);

    // ---- inbound: recorded entries -> on-chain ----
    VersionedVerifierResolver.InboundImplementationArgs[] memory inbound = resolver.getAllInboundImplementations();
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      address inboundImplementation = address(0);
      for (uint256 j = 0; j < inbound.length; ++j) {
        if (inbound[j].version == deployment.verifiers[i].versionTag) inboundImplementation = inbound[j].verifier;
      }
      drift += _diffAddress(
        string.concat(
          "resolver inbound impl for versionTag ", ConfigLib.tagToString(deployment.verifiers[i].versionTag)
        ),
        deployment.verifiers[i].addr,
        inboundImplementation
      );
    }

    // ---- inbound: on-chain -> recorded entries ----
    for (uint256 i = 0; i < inbound.length; ++i) {
      if (!ConfigLib.hasVerifierTag(deployment, inbound[i].version)) {
        console2.log(
          string.concat(
            "DRIFT_DETECTED resolver inbound impl for UNRECORDED versionTag ",
            ConfigLib.tagToString(inbound[i].version),
            " (unknown registered verifier)"
          )
        );
        console2.log("  actual:", inbound[i].verifier);
        ++drift;
      }
    }

    // ---- outbound: lanes -> on-chain ----
    VersionedVerifierResolver.OutboundImplementationArgs[] memory outbound = resolver.getAllOutboundImplementations();
    for (uint256 i = 0; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = lanes[i].lane;
      if (!_stringsEqual(lane.source.aliasName, operator.aliasName)) continue;

      if (!ConfigLib.hasVerifierTag(deployment, lane.versionTag)) {
        console2.log(
          string.concat(
            "DRIFT_DETECTED lane ",
            lane.name,
            " versionTag ",
            ConfigLib.tagToString(lane.versionTag),
            " has no recorded verifier - run: make deploy-verifier CHAIN=",
            operator.aliasName,
            " TAG=",
            ConfigLib.tagToString(lane.versionTag)
          )
        );
        ++drift;
        continue;
      }

      address outboundImplementation = address(0);
      for (uint256 j = 0; j < outbound.length; ++j) {
        if (outbound[j].destChainSelector == lane.dest.chainSelector) {
          outboundImplementation = outbound[j].verifier;
        }
      }
      drift += _diffAddress(
        string.concat("resolver outbound impl for lane ", lane.name),
        ConfigLib.verifierByTag(deployment, lane.versionTag),
        outboundImplementation
      );
    }

    // ---- outbound: on-chain -> lanes ----
    for (uint256 i = 0; i < outbound.length; ++i) {
      bool declared = false;
      for (uint256 j = 0; j < lanes.length; ++j) {
        if (
          _stringsEqual(lanes[j].lane.source.aliasName, operator.aliasName)
            && lanes[j].lane.dest.chainSelector == outbound[i].destChainSelector
        ) declared = true;
      }
      if (!declared) {
        console2.log("DRIFT_DETECTED resolver outbound impl for a dest selector no lane declares");
        console2.log("  dest selector:", outbound[i].destChainSelector);
        console2.log("  actual:", outbound[i].verifier);
        ++drift;
      }
    }
  }

  /// @notice Every recorded verifier's on-chain signature configs vs the lanes, compared
  ///         CLOSED-WORLD: on-chain -> lanes. (lanes -> on-chain is `checkLanes`.)
  /// @dev A committee is declared for a verifier only by a lane whose DEST is this chain
  ///      and whose versionTag is that verifier's. Anything else on-chain is a signer set
  ///      that still forms a valid quorum for its source selector, typically left behind
  ///      by a lane file moved out of `config/operator/lanes/` or repinned to another tag.
  ///      The fix is `REMOVE_UNDECLARED_SIGNATURE_CONFIGS=true make apply-signature-configs`.
  function checkSignatureConfigs(
    Types.Deployment memory deployment,
    Types.OperatorConfig memory operator,
    Types.LaneCommittee[] memory lanes
  ) public view returns (uint256 drift) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (!_hasCode(deployment.verifiers[i].addr)) continue; // reported by checkReachability
      bytes4 tag = deployment.verifiers[i].versionTag;
      SignatureQuorumValidator.SignatureConfig[] memory onChain =
        SignatureQuorumValidator(deployment.verifiers[i].addr).getAllSignatureConfigs();
      for (uint256 j = 0; j < onChain.length; ++j) {
        bool declared = false;
        for (uint256 k = 0; k < lanes.length; ++k) {
          Types.LaneConfig memory lane = lanes[k].lane;
          if (
            _stringsEqual(lane.dest.aliasName, operator.aliasName) && lane.versionTag == tag
              && lane.source.chainSelector == onChain[j].sourceChainSelector
          ) declared = true;
        }
        if (!declared) {
          console2.log(
            string.concat(
              "DRIFT_DETECTED verifier ",
              ConfigLib.tagToString(tag),
              " signature config for a source selector no lane declares - remove it: REMOVE_UNDECLARED_SIGNATURE_CONFIGS=true make apply-signature-configs CHAIN=",
              operator.aliasName,
              " TAG=",
              ConfigLib.tagToString(tag)
            )
          );
          console2.log("  source selector:", onChain[j].sourceChainSelector);
          console2.log("  threshold / signers:", onChain[j].threshold, onChain[j].signers.length);
          ++drift;
        }
      }
    }
  }

  /// @notice Per-lane verifier state vs `config/operator/lanes/*.json`, direction-aware. Each
  ///         lane is checked on the verifier serving ITS versionTag; a tag with no
  ///         recorded verifier is reported once per leg and the leg skipped.
  function checkLanes(
    Types.Deployment memory deployment,
    Types.OperatorConfig memory operator,
    Types.LaneCommittee[] memory lanes
  ) public view returns (uint256 drift) {
    for (uint256 i = 0; i < lanes.length; ++i) {
      Types.LaneConfig memory lane = lanes[i].lane;
      string memory lanePrefix = string.concat("lane ", lane.name, " ");

      bool touchesThisChain = _stringsEqual(lane.dest.aliasName, operator.aliasName)
        || _stringsEqual(lane.source.aliasName, operator.aliasName);
      if (!touchesThisChain) continue;

      if (!ConfigLib.hasVerifierTag(deployment, lane.versionTag)) {
        console2.log(
          string.concat(
            "DRIFT_DETECTED ",
            lanePrefix,
            "versionTag ",
            ConfigLib.tagToString(lane.versionTag),
            " has no recorded verifier on this chain - run: make deploy-verifier CHAIN=",
            operator.aliasName,
            " TAG=",
            ConfigLib.tagToString(lane.versionTag)
          )
        );
        ++drift;
        continue;
      }
      CommitteeVerifier verifier = CommitteeVerifier(ConfigLib.verifierByTag(deployment, lane.versionTag));
      if (!_hasCode(address(verifier))) continue; // reported by checkReachability

      // Inbound leg: the signer set that verifies messages ARRIVING from lane.source
      // lives on this chain only when this chain is the destination.
      if (_stringsEqual(lane.dest.aliasName, operator.aliasName)) {
        (address[] memory signers, uint8 threshold) = verifier.getSignatureConfig(lane.source.chainSelector);
        drift += _diffUint(string.concat(lanePrefix, "threshold"), lanes[i].committee.threshold, threshold);
        drift += _diffAddressSet(string.concat(lanePrefix, "signers"), lanes[i].committee.signers, signers);
      }

      // Outbound leg: routing/fee/gas for messages LEAVING to lane.dest lives on this
      // chain only when this chain is the source.
      if (_stringsEqual(lane.source.aliasName, operator.aliasName)) {
        (BaseVerifier.RemoteChainConfigArgs memory remote, address[] memory senders) =
          verifier.getRemoteChainConfig(lane.dest.chainSelector);
        drift += _diffAddress(string.concat(lanePrefix, "router"), lane.remote.router, address(remote.router));
        drift += _diffBool(
          string.concat(lanePrefix, "allowlistEnabled"), lane.allowlist.allowlistEnabled, remote.allowlistEnabled
        );
        drift += _diffAddressSet(string.concat(lanePrefix, "allowedSenders"), lane.allowlist.allowedSenders, senders);
        drift += _diffUint(string.concat(lanePrefix, "feeUSDCents"), lane.remote.feeUSDCents, remote.feeUSDCents);
        drift += _diffUint(
          string.concat(lanePrefix, "gasForVerification"), lane.remote.gasForVerification, remote.gasForVerification
        );
        drift += _diffUint(
          string.concat(lanePrefix, "payloadSizeBytes"), lane.remote.payloadSizeBytes, remote.payloadSizeBytes
        );
      }
    }
  }

  /// @notice The bps-only state of every recorded BpsFeeCommitteeVerifier vs config:
  ///         requireAllTokensPriced vs its verifier entry, each recorded price adapter vs
  ///         the verifier's token -> adapter mapping, and each lane leaving this chain
  ///         under its tag vs the fee config keyed by the lane's destination. An absent
  ///         `bpsFeeConfig` / `requireAllTokensPriced` expects the contract default.
  /// @dev The token -> adapter mapping cannot be enumerated on-chain, so only tokens the
  ///      record knows are compared. Bps settings declared for a verifier the record says
  ///      is a stock CommitteeVerifier can never be applied, so they count as drift too.
  function checkBpsFees(
    Types.Deployment memory deployment,
    BpsConfigLib.LaneBpsFee[] memory laneFees,
    BpsConfigLib.VerifierBpsPolicy[] memory policies
  ) public view returns (uint256 drift) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      Types.VerifierDeployment memory entry = deployment.verifiers[i];
      string memory prefix = string.concat("verifier ", ConfigLib.tagToString(entry.versionTag), " ");
      bool declaredRequireAll = BpsConfigLib.requireAllTokensPricedFor(policies, entry.versionTag);

      if (!BpsConfigLib.isBpsVerifier(entry)) {
        drift += _bpsDeclaredOnStockVerifier(deployment.aliasName, entry.versionTag, declaredRequireAll, laneFees);
        continue;
      }

      require(entry.addr.code.length != 0, "DriftCheck: no code at recorded bps verifier (wrong --rpc-url?)");
      BpsFeeCommitteeVerifier bps = BpsFeeCommitteeVerifier(entry.addr);
      drift += _diffBool(
        string.concat(prefix, "requireAllTokensPriced"), declaredRequireAll, bps.requireAllTokensPriced()
      );

      for (uint256 j = 0; j < deployment.priceAdapters.length; ++j) {
        address token = deployment.priceAdapters[j].args.token;
        drift += _diffAddress(
          string.concat(prefix, "price adapter for token ", vm.toString(token)),
          deployment.priceAdapters[j].addr,
          address(bps.getPriceAdapter(token))
        );
      }

      for (uint256 j = 0; j < laneFees.length; ++j) {
        if (!_appliesTo(laneFees[j], deployment.aliasName, entry.versionTag)) continue;
        drift += _diffFeeConfig(
          string.concat("lane ", laneFees[j].laneName, " bpsFeeConfig"),
          laneFees[j].fee,
          bps.getFeeConfig(laneFees[j].destSelector)
        );
      }
    }
  }

  /// @dev Bps settings aimed at a stock CommitteeVerifier: each one is drift.
  function _bpsDeclaredOnStockVerifier(
    string memory chainAlias,
    bytes4 tag,
    bool declaredRequireAll,
    BpsConfigLib.LaneBpsFee[] memory laneFees
  ) private pure returns (uint256 drift) {
    string memory suffix =
      string.concat(" - verifier ", ConfigLib.tagToString(tag), " is not a BpsFeeCommitteeVerifier");
    if (declaredRequireAll) {
      console2.log(string.concat("DRIFT_DETECTED requireAllTokensPriced declared", suffix));
      ++drift;
    }
    for (uint256 j = 0; j < laneFees.length; ++j) {
      if (!_appliesTo(laneFees[j], chainAlias, tag) || !BpsConfigLib.isDeclared(laneFees[j].fee)) continue;
      console2.log(string.concat("DRIFT_DETECTED lane ", laneFees[j].laneName, " declares a bpsFeeConfig", suffix));
      ++drift;
    }
  }

  function _appliesTo(
    BpsConfigLib.LaneBpsFee memory lane,
    string memory chainAlias,
    bytes4 tag
  ) private pure returns (bool) {
    return _stringsEqual(lane.sourceAlias, chainAlias) && lane.versionTag == tag;
  }

  function _diffFeeConfig(
    string memory label,
    BpsFeeConfig memory expected,
    BpsFeeConfig memory actual
  ) private pure returns (uint256) {
    if (BpsConfigLib.feeConfigEq(expected, actual)) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected:", _describeFee(expected));
    console2.log("  actual:  ", _describeFee(actual));
    return 1;
  }

  function _describeFee(
    BpsFeeConfig memory fee
  ) private pure returns (string memory) {
    return string.concat(
      "enabled=",
      vm.toString(fee.enabled),
      " feeBps=",
      vm.toString(uint256(fee.feeBps)),
      " minFeeUSDCents=",
      vm.toString(uint256(fee.minFeeUSDCents)),
      " capUSDCents=",
      vm.toString(uint256(fee.capUSDCents))
    );
  }

  /// @notice Every recorded address has code on the connected chain.
  /// @dev Runs after `run()` has matched the chainid, so a codeless address here is a bad
  ///      record, not a bad RPC: it is drift, and every other check skips that contract
  ///      (see the contract-level notes) instead of the whole run aborting.
  function checkReachability(
    Types.Deployment memory deployment
  ) public view returns (uint256 drift) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (_hasCode(deployment.verifiers[i].addr)) continue;
      console2.log(
        string.concat(
          "DRIFT_DETECTED verifier ",
          ConfigLib.tagToString(deployment.verifiers[i].versionTag),
          " has NO CODE at its recorded address (stale or wrong-chain record in config/deployments) - its checks are skipped"
        )
      );
      console2.log("  recorded:", deployment.verifiers[i].addr);
      ++drift;
    }
    drift += _reportCodeless("resolver", deployment.resolver);
    drift += _reportCodeless("factory", deployment.factory);
  }

  /// @dev An unrecorded (zero) resolver or factory is not drift; a recorded one with no code is.
  function _reportCodeless(
    string memory label,
    address recorded
  ) private view returns (uint256) {
    if (recorded == address(0) || _hasCode(recorded)) return 0;
    console2.log(
      string.concat(
        "DRIFT_DETECTED ",
        label,
        " has NO CODE at its recorded address (stale or wrong-chain record in config/deployments) - its checks are skipped"
      )
    );
    console2.log("  recorded:", recorded);
    return 1;
  }

  function _hasCode(
    address target
  ) private view returns (bool) {
    return target.code.length != 0;
  }

  // ---------------------------------------------------------------------------
  //  comparators — each logs the marker and returns 1 on mismatch, else 0
  // ---------------------------------------------------------------------------
  function _diffAddress(
    string memory label,
    address expected,
    address actual
  ) private pure returns (uint256) {
    if (expected == actual) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected:", expected);
    console2.log("  actual:  ", actual);
    return 1;
  }

  function _diffUint(
    string memory label,
    uint256 expected,
    uint256 actual
  ) private pure returns (uint256) {
    if (expected == actual) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected:", expected);
    console2.log("  actual:  ", actual);
    return 1;
  }

  function _diffBool(
    string memory label,
    bool expected,
    bool actual
  ) private pure returns (uint256) {
    if (expected == actual) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected:", expected);
    console2.log("  actual:  ", actual);
    return 1;
  }

  /// @dev Prints each side in words too: the hex alone does not show which requests the
  ///      on-chain value admits, and a reserved bit set by other tooling is only visible there.
  function _diffFinality(
    string memory label,
    bytes4 expected,
    bytes4 actual
  ) private pure returns (uint256) {
    if (expected == actual) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected:", ConfigLib.tagToString(expected), FinalityConfigLib.describe(expected));
    console2.log("  actual:  ", ConfigLib.tagToString(actual), FinalityConfigLib.describe(actual));
    return 1;
  }

  /// @dev Storage locations are a plain `string[]` on-chain (`BaseVerifier.s_storageLocations`,
  ///      cleared and re-pushed on every update), so ORDER is meaningful and compared.
  function _diffStrings(
    string memory label,
    string[] memory expected,
    string[] memory actual
  ) private pure returns (uint256) {
    bool same = expected.length == actual.length;
    for (uint256 i = 0; same && i < expected.length; ++i) {
      if (!_stringsEqual(expected[i], actual[i])) same = false;
    }
    if (same) return 0;
    console2.log(string.concat("DRIFT_DETECTED ", label));
    console2.log("  expected count:", expected.length);
    console2.log("  actual count:  ", actual.length);
    return 1;
  }

  /// @dev The on-chain signer set is an EnumerableSet, so its iteration order is
  ///      insertion order and carries no meaning — compared as a SET, not a list.
  ///      (Ordering only matters for the signatures supplied at verification time.)
  function _diffAddressSet(
    string memory label,
    address[] memory expected,
    address[] memory actual
  ) private pure returns (uint256) {
    uint256 mismatches = 0;
    for (uint256 i = 0; i < expected.length; ++i) {
      if (!_contains(actual, expected[i])) {
        if (mismatches++ == 0) console2.log(string.concat("DRIFT_DETECTED ", label));
        console2.log("  in config, MISSING on-chain:", expected[i]);
      }
    }
    for (uint256 i = 0; i < actual.length; ++i) {
      if (!_contains(expected, actual[i])) {
        if (mismatches++ == 0) console2.log(string.concat("DRIFT_DETECTED ", label));
        console2.log("  on-chain, NOT in config:    ", actual[i]);
      }
    }
    if (mismatches == 0) return 0;
    console2.log("  expected count:", expected.length);
    console2.log("  actual count:  ", actual.length);
    return 1;
  }

  function _contains(
    address[] memory set,
    address needle
  ) private pure returns (bool) {
    for (uint256 i = 0; i < set.length; ++i) {
      if (set[i] == needle) return true;
    }
    return false;
  }

  function _stringsEqual(
    string memory left,
    string memory right
  ) private pure returns (bool) {
    return keccak256(bytes(left)) == keccak256(bytes(right));
  }
}
