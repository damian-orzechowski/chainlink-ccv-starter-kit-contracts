// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {CommitteeVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/CommitteeVerifier.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployVerifier
/// @notice Deploys the CommitteeVerifier (plain CREATE, with constructor
///         args) and hands the owner + storageLocationsAdmin roles to their CONFIGURED
///         holders (config/operator/chains/<alias>.json). It is NOT deterministic and its address
///         may differ per chain: fine, it rotates behind the stable resolver.
///
/// @dev Role handover rule (each role independently):
///        - configured holder == deployer: keep it (the deployer owns/admins it and can
///          run the config scripts directly — EOA / testing path).
///        - configured holder is another EOA / a Safe: PROPOSE the 2-step transfer; that
///          holder accepts before configuring (script/ownership/AcceptOwnership /
///          AcceptStorageLocationsAdmin, or the b- handover batch).
///
/// @dev feeAggregator + allowlistAdmin come from roles and can be re-pointed later via
///      SetDynamicConfig; storageLocations via UpdateStorageLocations.
///
/// @dev The versionTag is an explicit argument: each deploy creates a
///      new verifier, appended to `verifiers` in the deployment record. A duplicate tag
///      reverts; ALLOW_TAG_REPLACE=true replaces that entry instead, for redoing a deploy
///      that went wrong before anything referenced it (never while it carries traffic).
///
/// @dev The implementation is the one overridable step: a subclass sharing
///      CommitteeVerifier's constructor overrides `_createVerifier` + `_contractName` and
///      inherits every check, the role handover and the record (see DeployBpsVerifier).
///
/// Usage:
///   OUTPUT_MODE=EOA forge script script/deploy/DeployVerifier.s.sol \
///     --sig "run(string,bytes4)" sepolia 0x00010001 --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
contract DeployVerifier is Script {
  function run(
    string calldata chainAlias,
    bytes4 versionTag
  ) external returns (address verifier) {
    // Validate the tag before any tag-keyed lookup, so a bad argument fails on
    // itself rather than inside a config read.
    require(versionTag != bytes4(0), "DeployVerifier: versionTag must be non-zero");
    // The repo-wide catalog is the spelling authority for tags (they must match across
    // chains); an uncataloged tag is a typo or an undeclared verifier.
    ConfigLib.requireKnownTag(versionTag, "deploy argument");

    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    ConfigLib.assertChainMatches(chainConfig, chainAlias);
    Types.OperatorConfig memory operator = ConfigLib.readOperator(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeploymentOrEmpty(chainAlias);
    // Everything this verifier is declared with is per tag and precedes the deploy:
    // reverts unless config/operator/chains/<alias>.json declares an entry for it.
    Types.VerifierConfig memory verifierConfig = ConfigLib.verifierConfigByTag(operator, versionTag);
    Types.VerifierRoles memory verifierRoles = verifierConfig.roles;

    require(chainConfig.rmn != address(0), "DeployVerifier: rmn must be non-zero");
    require(verifierRoles.owner != address(0), "DeployVerifier: verifier.owner role unset");
    require(
      verifierRoles.storageLocationsAdmin != address(0), "DeployVerifier: verifier.storageLocationsAdmin role unset"
    );
    // Stricter than CommitteeVerifier on purpose: the contract accepts a zero
    // feeAggregator, which leaves fee withdrawals reverting until someone sets one.
    // Requiring it here means fees are never stranded. Do not loosen this to match
    // the contract.
    require(verifierRoles.feeAggregator != address(0), "DeployVerifier: verifier.feeAggregator role unset");

    address deployer = msg.sender;

    CommitteeVerifier.DynamicConfig memory dynamicConfig = CommitteeVerifier.DynamicConfig({
      feeAggregator: verifierRoles.feeAggregator, allowlistAdmin: verifierRoles.allowlistAdmin
    });

    vm.broadcast();
    CommitteeVerifier v = _createVerifier(dynamicConfig, verifierConfig.storageLocations, chainConfig.rmn, versionTag);
    verifier = address(v);

    console2.log("[DeployVerifier] chain:", chainAlias);
    console2.log("  implementation:", _contractName());
    console2.log("  verifier deployed:", verifier);
    console2.log("  versionTag:", ConfigLib.tagToString(versionTag));
    console2.log("  rmn:", chainConfig.rmn);

    // ---- owner handover ----
    if (verifierRoles.owner == deployer) {
      console2.log("  owner: deployer (configured verifier.owner == deployer)");
    } else {
      vm.broadcast();
      v.transferOwnership(verifierRoles.owner);
      console2.log("  owner PROPOSED to:", verifierRoles.owner);
      console2.log("  (must acceptOwnership() before running owner-gated config scripts)");
    }

    // ---- storageLocationsAdmin handover ----
    if (verifierRoles.storageLocationsAdmin == verifierRoles.owner) {
      console2.log("  NOTE owner and storageLocationsAdmin are the same address (no role segregation)");
    }
    if (verifierRoles.storageLocationsAdmin == deployer) {
      console2.log("  storageLocationsAdmin: deployer");
    } else {
      vm.broadcast();
      v.transferStorageLocationsAdmin(verifierRoles.storageLocationsAdmin);
      console2.log("  storageLocationsAdmin PROPOSED to:", verifierRoles.storageLocationsAdmin);
      console2.log("  (must acceptStorageLocationsAdmin() before running UpdateStorageLocations)");
    }

    // The recorded entry mirrors the constructor call above, field for field; encodedArgs
    // is the same values pre-encoded for source verification (script/deploy/verify.sh).
    Types.VerifierDeployment memory record = Types.VerifierDeployment({
      versionTag: versionTag,
      addr: verifier,
      contractName: _contractName(),
      feeAggregator: dynamicConfig.feeAggregator,
      allowlistAdmin: dynamicConfig.allowlistAdmin,
      storageLocations: verifierConfig.storageLocations,
      rmn: chainConfig.rmn,
      encodedArgs: abi.encode(dynamicConfig, verifierConfig.storageLocations, chainConfig.rmn, versionTag)
    });
    _recordVerifier(deployment, record, vm.envOr("ALLOW_TAG_REPLACE", false));
    if (ConfigLib.isDryRun()) {
      console2.log("  DRY RUN: nothing deployed, record NOT written - re-run with --broadcast");
      return verifier;
    }
    ConfigLib.writeDeployment(deployment);
    console2.log("  recorded ->", ConfigLib.deploymentPath(chainAlias));
  }

  /// @dev The single CREATE this script broadcasts. An override must keep CommitteeVerifier's
  ///      constructor signature: the recorded `encodedArgs` are built for it.
  function _createVerifier(
    CommitteeVerifier.DynamicConfig memory dynamicConfig,
    string[] memory storageLocations,
    address rmn,
    bytes4 versionTag
  ) internal virtual returns (CommitteeVerifier) {
    return new CommitteeVerifier(dynamicConfig, storageLocations, rmn, versionTag);
  }

  /// @dev Recorded as the entry's `contract`; verify.sh maps it to the source to verify.
  function _contractName() internal pure virtual returns (string memory) {
    return "CommitteeVerifier";
  }

  /// @dev Appends the new verifier entry; a tag already on record means this run would
  ///      silently orphan the previous deploy, so it reverts unless explicitly waived.
  function _recordVerifier(
    Types.Deployment memory deployment,
    Types.VerifierDeployment memory record,
    bool allowReplace
  ) internal pure {
    if (ConfigLib.hasVerifierTag(deployment, record.versionTag)) {
      require(
        allowReplace,
        string.concat(
          "DeployVerifier: versionTag ",
          ConfigLib.tagToString(record.versionTag),
          " already recorded for ",
          deployment.aliasName,
          " - pick a new tag, or set ALLOW_TAG_REPLACE=true to replace a deploy nothing references yet"
        )
      );
      console2.log(
        "  WARN replacing recorded verifier for tag (ALLOW_TAG_REPLACE):", ConfigLib.tagToString(record.versionTag)
      );
      console2.log(
        "  WARN previous address is dropped from the record:", ConfigLib.verifierByTag(deployment, record.versionTag)
      );
      for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
        if (deployment.verifiers[i].versionTag == record.versionTag) deployment.verifiers[i] = record;
      }
      return;
    }

    Types.VerifierDeployment[] memory extended = new Types.VerifierDeployment[](deployment.verifiers.length + 1);
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      extended[i] = deployment.verifiers[i];
    }
    extended[deployment.verifiers.length] = record;
    deployment.verifiers = extended;
  }
}
