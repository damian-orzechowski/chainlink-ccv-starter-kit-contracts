// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BpsFeeConfig} from "../bps/BpsFeeConfig.sol";
import {ConfigLib} from "./ConfigLib.sol";
import {Types} from "./Types.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title BpsConfigLib
/// @notice Loads the settings only a BpsFeeCommitteeVerifier has, kept apart from the
///         stock CommitteeVerifier config so that path is unchanged:
///           - `bpsFeeConfig`, an optional block in a lane file: the fee policy the
///             SOURCE verifier applies for the lane's destination (setFeeConfig).
///           - `requireAllTokensPriced`, an optional bool on a verifier entry in
///             config/operator/chains/<alias>.json (setRequireAllTokensPriced).
///         The price adapters themselves are deploy records (ConfigLib.priceAdapters).
/// @dev Both keys are optional and the standard loaders never read them. Absent means
///      the contract's default: fee policy disabled (all zero), requireAllTokensPriced
///      false. That is also what DriftCheck expects on-chain when the key is absent.
library BpsConfigLib {
  Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

  /// @dev The deployment record's `contract` for a bps verifier (DeployBpsVerifier).
  string internal constant BPS_VERIFIER_CONTRACT = "BpsFeeCommitteeVerifier";
  uint16 internal constant MAX_FEE_BPS = 10_000;

  /// @dev One lane's declared bps fee policy, with the lane identity it applies under:
  ///      the SOURCE chain's verifier for `versionTag`, keyed by the DEST selector.
  struct LaneBpsFee {
    string laneName;
    string sourceAlias;
    uint64 destSelector;
    bytes4 versionTag;
    BpsFeeConfig fee; // all zero when the lane declares no bpsFeeConfig
  }

  /// @dev One verifier entry's bps posture.
  struct VerifierBpsPolicy {
    bytes4 versionTag;
    bool requireAllTokensPriced;
  }

  // --------------------------------------------------------------------------
  //  lanes: bpsFeeConfig
  // --------------------------------------------------------------------------

  /// @notice Every real lane's bps fee policy, in ConfigLib.listLanes() order.
  function readLaneBpsFees() internal view returns (LaneBpsFee[] memory fees) {
    string[] memory paths = ConfigLib.listLanes();
    fees = new LaneBpsFee[](paths.length);
    for (uint256 i = 0; i < paths.length; ++i) {
      fees[i] = readLaneBpsFeeByPath(paths[i]);
    }
  }

  /// @dev The lane identity comes from the standard loader, so a lane that does not load
  ///      there does not load here either.
  function readLaneBpsFeeByPath(
    string memory path
  ) internal view returns (LaneBpsFee memory entry) {
    Types.LaneConfig memory lane = ConfigLib.readLaneByPath(path);
    entry.laneName = lane.name;
    entry.sourceAlias = lane.source.aliasName;
    entry.destSelector = lane.dest.chainSelector;
    entry.versionTag = lane.versionTag;
    entry.fee = _parseFeeConfig(vm.readFile(path), path);
  }

  /// @dev Strict when present: all four keys, nothing else, each a uint16, and the same
  ///      bounds setFeeConfig enforces, so a bad policy fails at load, not on-chain.
  function _parseFeeConfig(
    string memory json,
    string memory path
  ) private view returns (BpsFeeConfig memory fee) {
    string memory key = ".bpsFeeConfig";
    if (!vm.keyExistsJson(json, key)) return fee;

    string[] memory keys = vm.parseJsonKeys(json, key);
    for (uint256 i = 0; i < keys.length; ++i) {
      string memory k = keys[i];
      require(
        _eq(k, "enabled") || _eq(k, "feeBps") || _eq(k, "minFeeUSDCents") || _eq(k, "capUSDCents"),
        string.concat(
          "BpsConfigLib: bpsFeeConfig in ",
          path,
          " has unknown key '",
          k,
          "' - keys are enabled, feeBps, minFeeUSDCents, capUSDCents"
        )
      );
    }
    fee.enabled = vm.parseJsonBool(json, _required(json, key, "enabled", path));
    fee.feeBps = _toUint16(vm.parseJsonUint(json, _required(json, key, "feeBps", path)), "feeBps", path);
    fee.minFeeUSDCents =
      _toUint16(vm.parseJsonUint(json, _required(json, key, "minFeeUSDCents", path)), "minFeeUSDCents", path);
    fee.capUSDCents = _toUint16(vm.parseJsonUint(json, _required(json, key, "capUSDCents", path)), "capUSDCents", path);

    string memory err = feeConfigError(fee);
    require(bytes(err).length == 0, string.concat("BpsConfigLib: bpsFeeConfig in ", path, ": ", err));
  }

  /// @notice Why setFeeConfig would reject `fee`, or "" when it would accept it. Same
  ///         rules, same order as BpsFeeCommitteeVerifier.setFeeConfig. The remaining
  ///         on-chain rule (an enabled policy needs the destination's remote chain config)
  ///         depends on chain state and is checked by ApplyBpsFeeConfig.
  function feeConfigError(
    BpsFeeConfig memory fee
  ) internal pure returns (string memory) {
    if (fee.enabled && fee.minFeeUSDCents == 0) return "minFeeUSDCents must be non-zero when enabled";
    if (fee.feeBps > MAX_FEE_BPS) return "feeBps must be <= 10000 (100%)";
    if (fee.capUSDCents < fee.minFeeUSDCents) return "capUSDCents must be >= minFeeUSDCents";
    return "";
  }

  function feeConfigEq(
    BpsFeeConfig memory a,
    BpsFeeConfig memory b
  ) internal pure returns (bool) {
    return a.enabled == b.enabled && a.feeBps == b.feeBps && a.minFeeUSDCents == b.minFeeUSDCents
      && a.capUSDCents == b.capUSDCents;
  }

  /// @notice True when `fee` is anything but the contract default (disabled, all zero).
  function isDeclared(
    BpsFeeConfig memory fee
  ) internal pure returns (bool) {
    return fee.enabled || fee.feeBps != 0 || fee.minFeeUSDCents != 0 || fee.capUSDCents != 0;
  }

  // --------------------------------------------------------------------------
  //  operator: verifiers[].requireAllTokensPriced
  // --------------------------------------------------------------------------

  /// @notice Each verifier entry's bps posture; empty when the chain has no operator file.
  function readVerifierPolicies(
    string memory aliasName
  ) internal view returns (VerifierBpsPolicy[] memory policies) {
    string memory path = ConfigLib.operatorPath(aliasName);
    if (!vm.exists(path)) return policies;
    return readVerifierPoliciesByPath(path);
  }

  /// @dev Indexes match the standard loader's `verifiers`, which supplies the tags.
  function readVerifierPoliciesByPath(
    string memory path
  ) internal view returns (VerifierBpsPolicy[] memory policies) {
    Types.OperatorConfig memory operator = ConfigLib.readOperatorByPath(path);
    string memory json = vm.readFile(path);
    policies = new VerifierBpsPolicy[](operator.verifiers.length);
    for (uint256 i = 0; i < operator.verifiers.length; ++i) {
      policies[i].versionTag = operator.verifiers[i].versionTag;
      string memory key = string.concat(".verifiers[", vm.toString(i), "].requireAllTokensPriced");
      if (vm.keyExistsJson(json, key)) policies[i].requireAllTokensPriced = vm.parseJsonBool(json, key);
    }
  }

  /// @notice The declared requireAllTokensPriced for `tag`; false when not declared.
  function requireAllTokensPricedFor(
    VerifierBpsPolicy[] memory policies,
    bytes4 tag
  ) internal pure returns (bool) {
    for (uint256 i = 0; i < policies.length; ++i) {
      if (policies[i].versionTag == tag) return policies[i].requireAllTokensPriced;
    }
    return false;
  }

  // --------------------------------------------------------------------------
  //  deployment record: which verifiers are bps verifiers
  // --------------------------------------------------------------------------

  function isBpsVerifier(
    Types.VerifierDeployment memory entry
  ) internal pure returns (bool) {
    return _eq(ConfigLib.verifierContractName(entry.contractName), BPS_VERIFIER_CONTRACT);
  }

  /// @notice Reverts unless `tag` is recorded on this chain as a BpsFeeCommitteeVerifier.
  ///         The bps setters do not exist on a stock CommitteeVerifier, so nothing may be
  ///         built for one.
  function requireBpsVerifier(
    Types.Deployment memory deployment,
    bytes4 tag
  ) internal pure {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (deployment.verifiers[i].versionTag != tag) continue;
      require(
        isBpsVerifier(deployment.verifiers[i]),
        string.concat(
          "BpsConfigLib: verifier ",
          ConfigLib.tagToString(tag),
          " on ",
          deployment.aliasName,
          " is recorded as ",
          ConfigLib.verifierContractName(deployment.verifiers[i].contractName),
          ", not ",
          BPS_VERIFIER_CONTRACT,
          " - bps settings apply only to a verifier deployed with make deploy-bps-verifier"
        )
      );
      return;
    }
    // Not recorded at all: same reason the other scripts give.
    ConfigLib.verifierByTag(deployment, tag);
  }

  /// @notice Reverts when bps settings are declared for a tag this chain records as a
  ///         stock CommitteeVerifier. An unrecorded tag passes: it may not be deployed yet.
  function requireBpsTargetIfDeclared(
    string memory aliasName,
    bytes4 tag,
    string memory context
  ) internal view {
    Types.Deployment memory deployment = ConfigLib.readDeploymentOrEmpty(aliasName);
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (deployment.verifiers[i].versionTag != tag || isBpsVerifier(deployment.verifiers[i])) continue;
      revert(
        string.concat(
          context,
          " declares bps settings for tag ",
          ConfigLib.tagToString(tag),
          ", but ",
          ConfigLib.deploymentPath(aliasName),
          " records that verifier as ",
          ConfigLib.verifierContractName(deployment.verifiers[i].contractName)
        )
      );
    }
  }

  // --------------------------------------------------------------------------
  //  helpers
  // --------------------------------------------------------------------------
  function _required(
    string memory json,
    string memory key,
    string memory field,
    string memory path
  ) private view returns (string memory full) {
    full = string.concat(key, ".", field);
    require(vm.keyExistsJson(json, full), string.concat("BpsConfigLib: missing ", full, " in ", path));
  }

  function _toUint16(
    uint256 value,
    string memory field,
    string memory path
  ) private pure returns (uint16) {
    require(
      value <= type(uint16).max, string.concat("BpsConfigLib: bpsFeeConfig.", field, " in ", path, " exceeds uint16")
    );
    // casting to 'uint16' is safe because the require above bounds `value`
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint16(value);
  }

  function _eq(
    string memory a,
    string memory b
  ) private pure returns (bool) {
    return keccak256(bytes(a)) == keccak256(bytes(b));
  }
}
