// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BpsFeeCommitteeVerifier} from "../../src/bps/BpsFeeCommitteeVerifier.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {BpsConfigLib} from "../../src/lib/BpsConfigLib.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {IPriceAdapter} from "../../src/price-adapters/IPriceAdapter.sol";
import {console2} from "forge-std/console2.sol";

/// @title RemovePriceAdapter
/// @notice Retires the price adapter for one token on a chain: unregisters it on every
///         recorded BpsFeeCommitteeVerifier that still points at it
///         (`setPriceAdapter(token, address(0))`), then drops its entry from
///         config/deployments/<alias>.json. The adapter itself stays deployed (it is
///         ownerless and has nothing to switch off); its address is logged.
/// @dev Config first: refuses while config/operator/chains/<alias>.json still declares the
///      token. Deleting that entry is the intent; `make validate-config` then fails (a
///      recorded token no longer declared) until this script has run.
/// @dev Every bps verifier, not one tag: the record is per chain and apply-bps-config
///      registers every recorded adapter on every bps verifier, so a token unregistered
///      on one verifier only would be re-registered by the next apply.
/// @dev The record follows the chain: it is dropped only once no bps verifier points at
///      the adapter. EOA mode broadcasts and drops it in the same run. SAFE mode only
///      writes the batch, so the record (and DriftCheck's view of the token) stays until
///      the batch executes; re-run then, and it stages nothing and drops the record.
/// @dev Refuses to unregister on a verifier with requireAllTokensPriced on: getFee would
///      revert for every message carrying the token, blocking it on that verifier's
///      lanes. ALLOW_UNPRICED=true overrides (e.g. the token is being delisted).
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/RemovePriceAdapter.s.sol \
///     --sig "run(string,address)" sepolia <token> --rpc-url $SEPOLIA_RPC_URL
///   (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
contract RemovePriceAdapter is BaseScript {
  function run(
    string calldata chainAlias,
    address token
  ) external {
    require(token != address(0), "RemovePriceAdapter: token must be non-zero");
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    requireUndeclared(ConfigLib.readOperator(chainAlias), chainAlias, token);
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (!BpsConfigLib.isBpsVerifier(deployment.verifiers[i])) continue;
      _assertReachable(
        deployment.verifiers[i].addr,
        string.concat("bps verifier ", ConfigLib.tagToString(deployment.verifiers[i].versionTag))
      );
    }

    address recorded = ConfigLib.priceAdapterByToken(deployment, token);
    console2.log("[RemovePriceAdapter] chain:", chainAlias);
    console2.log("  token:", token);
    console2.log("  recorded adapter:", recorded);

    Call[] memory calls = callsFor(deployment, token, vm.envOr("ALLOW_UNPRICED", false));
    require(
      calls.length != 0 || recorded != address(0),
      string.concat(
        "RemovePriceAdapter: nothing to remove - no adapter is recorded for token ",
        vm.toString(token),
        " on ",
        chainAlias,
        " and no bps verifier has one registered"
      )
    );
    if (outputMode == OutputMode.SAFE) {
      for (uint256 i = 0; i < calls.length; ++i) {
        requireExecutorIsCurrentOwner(calls[i].to, outputSafeAddress);
      }
    }
    _stageMany(calls);
    _flush(string.concat("remove-price-adapter-", chainAlias, "-", vm.toString(token)));

    _dropRecordIfUnregistered(deployment, token, recorded);
  }

  /// @notice One setPriceAdapter(token, 0) per recorded bps verifier that still has an
  ///         adapter for `token`; empty once none does.
  function callsFor(
    Types.Deployment memory deployment,
    address token,
    bool allowUnpriced
  ) public view returns (Call[] memory calls) {
    calls = new Call[](deployment.verifiers.length);
    uint256 n = 0;
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      Types.VerifierDeployment memory entry = deployment.verifiers[i];
      if (!BpsConfigLib.isBpsVerifier(entry)) continue;
      BpsFeeCommitteeVerifier bps = BpsFeeCommitteeVerifier(entry.addr);
      address current = address(bps.getPriceAdapter(token));
      string memory tag = ConfigLib.tagToString(entry.versionTag);
      if (current == address(0)) {
        console2.log(string.concat("[RemovePriceAdapter] verifier ", tag, " UNCHANGED: no adapter registered"));
        continue;
      }
      require(
        allowUnpriced || !bps.requireAllTokensPriced(),
        string.concat(
          "RemovePriceAdapter: verifier ",
          tag,
          " has requireAllTokensPriced on - unregistering ",
          vm.toString(token),
          " makes getFee revert for every message carrying it; set ALLOW_UNPRICED=true to proceed anyway"
        )
      );
      console2.log(string.concat("[RemovePriceAdapter] verifier ", tag, " STAGED: unregister adapter"), current);
      calls[n++] = Call({
        to: entry.addr,
        value: 0,
        data: abi.encodeCall(BpsFeeCommitteeVerifier.setPriceAdapter, (token, IPriceAdapter(address(0))))
      });
    }
    assembly {
      mstore(calls, n)
    }
  }

  /// @notice Reverts while the operator file still declares `token`: the declaration is
  ///         the intent, so it goes first.
  function requireUndeclared(
    Types.OperatorConfig memory operator,
    string memory chainAlias,
    address token
  ) public pure {
    for (uint256 i = 0; i < operator.priceAdapters.length; ++i) {
      require(
        operator.priceAdapters[i].token != token,
        string.concat(
          "RemovePriceAdapter: ",
          ConfigLib.operatorPath(chainAlias),
          " still declares a priceAdapters entry for token ",
          vm.toString(token),
          " - delete it first (config is the intent this script applies)"
        )
      );
    }
  }

  /// @notice The record follows the chain: drop the entry only when there is one and no
  ///         bps verifier points at an adapter for `token` any more.
  function shouldDropRecord(
    Types.Deployment memory deployment,
    address token
  ) public view returns (bool) {
    return ConfigLib.priceAdapterByToken(deployment, token) != address(0) && !stillRegistered(deployment, token);
  }

  /// @notice True while any recorded bps verifier still has an adapter for `token`.
  function stillRegistered(
    Types.Deployment memory deployment,
    address token
  ) public view returns (bool registered) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (!BpsConfigLib.isBpsVerifier(deployment.verifiers[i])) continue;
      registered = address(BpsFeeCommitteeVerifier(deployment.verifiers[i].addr).getPriceAdapter(token)) != address(0);
      if (registered) return registered;
    }
  }

  /// @notice `deployment` without its `priceAdapters` entry for `token` (order kept).
  function withoutAdapter(
    Types.Deployment memory deployment,
    address token
  ) public pure returns (Types.Deployment memory) {
    Types.PriceAdapterDeployment[] memory kept = new Types.PriceAdapterDeployment[](deployment.priceAdapters.length);
    uint256 n = 0;
    for (uint256 i = 0; i < deployment.priceAdapters.length; ++i) {
      if (deployment.priceAdapters[i].args.token != token) kept[n++] = deployment.priceAdapters[i];
    }
    assembly {
      mstore(kept, n)
    }
    deployment.priceAdapters = kept;
    return deployment;
  }

  function _dropRecordIfUnregistered(
    Types.Deployment memory deployment,
    address token,
    address recorded
  ) private {
    if (recorded == address(0)) {
      console2.log("[RemovePriceAdapter] no record entry to drop");
      return;
    }
    if (!shouldDropRecord(deployment, token)) {
      console2.log(
        "[RemovePriceAdapter] record KEPT until the batch executes on chain - re-run this command afterwards to drop it"
      );
      return;
    }
    if (ConfigLib.isDryRun()) {
      console2.log("  DRY RUN: record NOT written - re-run with --broadcast");
      return;
    }
    ConfigLib.writeDeployment(withoutAdapter(deployment, token));
    console2.log("[RemovePriceAdapter] record entry dropped; the adapter stays deployed at:", recorded);
  }
}
