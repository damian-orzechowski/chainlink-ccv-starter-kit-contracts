// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BpsFeeCommitteeVerifier} from "../../src/bps/BpsFeeCommitteeVerifier.sol";
import {BpsFeeConfig} from "../../src/bps/BpsFeeConfig.sol";
import {BaseScript} from "../../src/lib/BaseScript.sol";
import {BpsConfigLib} from "../../src/lib/BpsConfigLib.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {IPriceAdapter} from "../../src/price-adapters/IPriceAdapter.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {console2} from "forge-std/console2.sol";

/// @title ApplyBpsFeeConfig
/// @notice Pushes the bps-only settings onto ONE BpsFeeCommitteeVerifier (CHAIN + TAG):
///           1. setPriceAdapters      — every price adapter in config/deployments/<alias>.json
///           2. setFeeConfig          — per lane whose SOURCE is this chain and whose tag is
///                                      TAG, the lane's `bpsFeeConfig` keyed by its DEST
///           3. setRequireAllTokensPriced — the verifier entry's `requireAllTokensPriced`
///         Each call is staged only when it would change something, so a re-run is a no-op.
///         --rpc-url is required in both output modes.
///
/// @dev Refuses before building anything unless the tag is recorded as a
///      BpsFeeCommitteeVerifier: the stock CommitteeVerifier has none of these setters.
///
/// @dev Run AFTER apply-remote-config: setFeeConfig rejects an enabled policy for a
///      destination the verifier has no remote chain config for. The script checks that
///      up front instead of letting the batch revert.
///
/// @dev Order: adapters first, the strict-pricing switch last, so turning
///      requireAllTokensPriced on never leaves a window where a token the record prices is
///      still unregistered.
///
/// Usage:
///   OUTPUT_MODE=SAFE forge script script/configure/ApplyBpsFeeConfig.s.sol \
///     --sig "run(string,bytes4)" sepolia 0x00020001 --rpc-url $SEPOLIA_RPC_URL
///   (EOA path: OUTPUT_MODE=EOA + --broadcast --aws)
contract ApplyBpsFeeConfig is BaseScript {
  function run(
    string calldata chainAlias,
    bytes4 versionTag
  ) external {
    require(versionTag != bytes4(0), "ApplyBpsFeeConfig: versionTag cannot be zero");
    _initOutput(chainAlias);

    Types.Deployment memory deployment = ConfigLib.readDeployment(chainAlias);
    BpsConfigLib.requireBpsVerifier(deployment, versionTag);
    address verifier = ConfigLib.verifierByTag(deployment, versionTag);
    _assertReachable(verifier, "verifier");
    if (outputMode == OutputMode.SAFE) requireExecutorIsCurrentOwner(verifier, outputSafeAddress);

    // The entry must exist (intent precedes the push), and supplies the strict-pricing flag.
    ConfigLib.verifierConfigByTag(ConfigLib.readOperator(chainAlias), versionTag);
    bool requireAll = BpsConfigLib.requireAllTokensPricedFor(BpsConfigLib.readVerifierPolicies(chainAlias), versionTag);

    console2.log("[ApplyBpsFeeConfig] chain:", chainAlias);
    console2.log("  versionTag:", ConfigLib.tagToString(versionTag));
    console2.log("  target verifier:", verifier);
    console2.log("  recorded price adapters:", deployment.priceAdapters.length);
    console2.log("  requireAllTokensPriced:", requireAll);

    Call[] memory calls =
      callsFor(verifier, deployment.priceAdapters, BpsConfigLib.readLaneBpsFees(), chainAlias, versionTag, requireAll);
    if (calls.length == 0) console2.log("[ApplyBpsFeeConfig] nothing to do: the verifier already matches config");
    _stageMany(calls);
    _flush(string.concat("apply-bps-fee-config-", chainAlias, "-", ConfigLib.tagToString(versionTag)));
  }

  /// @notice Every call a run would stage, in order, skipping what is already current.
  function callsFor(
    address verifier,
    Types.PriceAdapterDeployment[] memory adapters,
    BpsConfigLib.LaneBpsFee[] memory laneFees,
    string memory chainAlias,
    bytes4 versionTag,
    bool requireAllTokensPriced
  ) public view returns (Call[] memory calls) {
    BpsFeeCommitteeVerifier bps = BpsFeeCommitteeVerifier(verifier);
    calls = new Call[](laneFees.length + 2);
    uint256 n = 0;

    // 1. adapters, as one batched call
    (address[] memory tokens, IPriceAdapter[] memory toRegister) = adaptersToRegister(verifier, adapters);
    if (tokens.length != 0) {
      calls[n++] = Call({
        to: verifier, value: 0, data: abi.encodeCall(BpsFeeCommitteeVerifier.setPriceAdapters, (tokens, toRegister))
      });
    }

    // 2. fee policy per lane leaving this chain under this tag
    uint256 matched = 0;
    for (uint256 i = 0; i < laneFees.length; ++i) {
      BpsConfigLib.LaneBpsFee memory lane = laneFees[i];
      if (!_stringsEqual(lane.sourceAlias, chainAlias) || lane.versionTag != versionTag) continue;
      ++matched;
      _assertApplicable(verifier, lane);
      if (BpsConfigLib.feeConfigEq(bps.getFeeConfig(lane.destSelector), lane.fee)) {
        console2.log("[ApplyBpsFeeConfig] fee config UNCHANGED for lane:", lane.laneName);
        continue;
      }
      console2.log("[ApplyBpsFeeConfig] fee config STAGED for lane:", lane.laneName);
      console2.log("  dest selector:", lane.destSelector);
      console2.log("  enabled:", lane.fee.enabled);
      console2.log("  feeBps:", uint256(lane.fee.feeBps));
      console2.log("  minFeeUSDCents:", uint256(lane.fee.minFeeUSDCents));
      console2.log("  capUSDCents:", uint256(lane.fee.capUSDCents));
      calls[n++] = callForFeeConfig(verifier, lane.destSelector, lane.fee);
    }
    if (matched == 0) console2.log("  no lanes leave this chain under this tag: no fee configs to apply");

    // 3. strict-pricing switch, last
    if (bps.requireAllTokensPriced() != requireAllTokensPriced) {
      console2.log("[ApplyBpsFeeConfig] requireAllTokensPriced STAGED:", requireAllTokensPriced);
      calls[n++] = Call({
        to: verifier,
        value: 0,
        data: abi.encodeCall(BpsFeeCommitteeVerifier.setRequireAllTokensPriced, (requireAllTokensPriced))
      });
    }

    // Drop the unused tail: a memory array's first word is its length, and `n` only shrinks it.
    // solhint-disable-next-line no-inline-assembly
    assembly {
      mstore(calls, n)
    }
  }

  function callForFeeConfig(
    address verifier,
    uint64 destSelector,
    BpsFeeConfig memory fee
  ) public pure returns (Call memory) {
    return
      Call({to: verifier, value: 0, data: abi.encodeCall(BpsFeeCommitteeVerifier.setFeeConfig, (destSelector, fee))});
  }

  /// @notice The recorded adapters the verifier does not have registered yet. Each one is
  ///         checked to price exactly its token: setPriceAdapter enforces that too, but a
  ///         reverting batch is a worse place to learn it.
  function adaptersToRegister(
    address verifier,
    Types.PriceAdapterDeployment[] memory adapters
  ) public view returns (address[] memory tokens, IPriceAdapter[] memory toRegister) {
    tokens = new address[](adapters.length);
    toRegister = new IPriceAdapter[](adapters.length);
    uint256 n = 0;
    for (uint256 i = 0; i < adapters.length; ++i) {
      address token = adapters[i].args.token;
      address adapter = adapters[i].addr;
      _assertReachable(adapter, "price adapter");
      address priced = IPriceAdapter(adapter).token();
      require(
        priced == token,
        string.concat(
          "ApplyBpsFeeConfig: recorded adapter ",
          vm.toString(adapter),
          " prices ",
          vm.toString(priced),
          ", not its recorded token ",
          vm.toString(token)
        )
      );
      if (address(BpsFeeCommitteeVerifier(verifier).getPriceAdapter(token)) == adapter) {
        console2.log("[ApplyBpsFeeConfig] price adapter UNCHANGED for token:", token);
        continue;
      }
      console2.log("[ApplyBpsFeeConfig] price adapter STAGED for token:", token);
      console2.log("  adapter:", adapter);
      tokens[n] = token;
      toRegister[n] = IPriceAdapter(adapter);
      ++n;
    }
    // solhint-disable-next-line no-inline-assembly
    assembly {
      mstore(tokens, n)
      mstore(toRegister, n)
    }
  }

  /// @dev setFeeConfig's rules, checked before any call is built. The bounds were already
  ///      enforced at load; the remote-config rule needs chain state.
  function _assertApplicable(
    address verifier,
    BpsConfigLib.LaneBpsFee memory lane
  ) internal view {
    string memory err = BpsConfigLib.feeConfigError(lane.fee);
    require(bytes(err).length == 0, string.concat("ApplyBpsFeeConfig: lane ", lane.laneName, " bpsFeeConfig: ", err));
    if (!lane.fee.enabled) return;
    (
      BaseVerifier.RemoteChainConfigArgs memory remote,
      // the allowlist is not this script's business
      // forge-lint: disable-next-line(unused-return)
    ) = BaseVerifier(verifier).getRemoteChainConfig(lane.destSelector);
    require(
      address(remote.router) != address(0),
      string.concat(
        "ApplyBpsFeeConfig: lane ",
        lane.laneName,
        " enables a bps fee, but the verifier has no remote chain config (router) for its destination",
        " - run make apply-remote-config CHAIN=",
        lane.sourceAlias,
        " TAG=",
        ConfigLib.tagToString(lane.versionTag),
        " first (and execute it)"
      )
    );
  }
}
