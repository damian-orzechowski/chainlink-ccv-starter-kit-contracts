// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {IPriceAdapter} from "../../src/price-adapters/IPriceAdapter.sol";
import {WstETHUSDL2PriceAdapter} from "../../src/price-adapters/WstETHUSDL2PriceAdapter.sol";
import {WstETHUSDPriceAdapter} from "../../src/price-adapters/WstETHUSDPriceAdapter.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployPriceAdapter
/// @notice Deploys the IPriceAdapter DECLARED for one token in
///         config/operator/chains/<alias>.json (`priceAdapters[]`, plain CREATE) and records
///         it in config/deployments/<alias>.json under `priceAdapters`. The entry's
///         `contract` picks the implementation:
///           WstETHUSDPriceAdapter   — one wstETH/USD feed (Ethereum)
///           WstETHUSDL2PriceAdapter — wstETH/ETH × ETH/USD, gated on the sequencer (L2s)
///
/// @dev Adapters are ownerless and immutable: the declared entry IS the configuration,
///      passed to the constructor as-is. Changing a feed or a staleness bound means
///      editing the entry and deploying a new adapter. A token already on record reverts;
///      ALLOW_ADAPTER_REPLACE=true replaces that entry (the old adapter stays deployed,
///      unused once the verifier is re-pointed at the new one).
///
/// @dev Deploying does NOT register the adapter on any verifier: the
///      BpsFeeCommitteeVerifier owner calls setPriceAdapter(token, adapter) afterwards.
///
/// @dev The constructors already reject zero addresses, out-of-range staleness / grace
///      periods and non-18-decimal tokens. This script adds one post-deploy price read
///      that only WARNS: a stale testnet feed must not block a deploy, but a wrong feed
///      address shows up here rather than later as a zero-priced or reverting getFee.
///
/// Usage:
///   OUTPUT_MODE=EOA forge script script/deploy/DeployPriceAdapter.s.sol --tc DeployPriceAdapter \
///     --sig "run(string,address)" sepolia <token> --rpc-url $SEPOLIA_RPC_URL --broadcast --aws
contract DeployPriceAdapter is Script {
  function run(
    string calldata chainAlias,
    address token
  ) external returns (address adapter) {
    require(token != address(0), "DeployPriceAdapter: token must be non-zero");

    Types.ChainConfig memory chainConfig = ConfigLib.readChain(chainAlias);
    ConfigLib.assertChainMatches(chainConfig, chainAlias);
    Types.OperatorConfig memory operator = ConfigLib.readOperator(chainAlias);
    Types.Deployment memory deployment = ConfigLib.readDeploymentOrEmpty(chainAlias);
    // Reverts unless config/operator/chains/<alias>.json declares an adapter for it.
    Types.PriceAdapterConfig memory config = ConfigLib.priceAdapterConfigByToken(operator, token);

    vm.broadcast();
    Types.PriceAdapterDeployment memory record = _createAdapter(config);
    adapter = record.addr;

    console2.log("[DeployPriceAdapter] chain:", chainAlias);
    console2.log("  implementation:", config.contractName);
    console2.log("  adapter deployed:", adapter);
    console2.log("  token:", config.token);
    _logArgs(config);
    _smokeRead(adapter);

    _recordAdapter(deployment, record, vm.envOr("ALLOW_ADAPTER_REPLACE", false));
    console2.log("  next: the verifier owner calls setPriceAdapter(token, adapter) on the BpsFeeCommitteeVerifier");
    if (ConfigLib.isDryRun()) {
      console2.log("  DRY RUN: nothing deployed, record NOT written - re-run with --broadcast");
      return adapter;
    }
    ConfigLib.writeDeployment(deployment);
    console2.log("  recorded ->", ConfigLib.deploymentPath(chainAlias));
  }

  /// @dev The single CREATE this script broadcasts. The record mirrors the constructor
  ///      call field for field; encodedArgs is the same values pre-encoded for
  ///      source verification (script/deploy/verify.sh).
  function _createAdapter(
    Types.PriceAdapterConfig memory c
  ) internal returns (Types.PriceAdapterDeployment memory record) {
    record.args = c;
    if (_isL2(c)) {
      record.addr = address(
        new WstETHUSDL2PriceAdapter(
          c.token, c.rateFeed, c.usdFeed, c.rateMaxStaleness, c.usdMaxStaleness, c.sequencerUptimeFeed, c.gracePeriod
        )
      );
      record.encodedArgs = abi.encode(
        c.token, c.rateFeed, c.usdFeed, c.rateMaxStaleness, c.usdMaxStaleness, c.sequencerUptimeFeed, c.gracePeriod
      );
    } else {
      record.addr = address(new WstETHUSDPriceAdapter(c.token, c.usdFeed, c.usdMaxStaleness));
      record.encodedArgs = abi.encode(c.token, c.usdFeed, c.usdMaxStaleness);
    }
  }

  /// @dev ConfigLib accepts exactly these two names, so anything not L2 is the L1 adapter.
  function _isL2(
    Types.PriceAdapterConfig memory c
  ) internal pure returns (bool) {
    return keccak256(bytes(c.contractName)) == keccak256(bytes(ConfigLib.L2_PRICE_ADAPTER));
  }

  function _logArgs(
    Types.PriceAdapterConfig memory c
  ) internal pure {
    if (_isL2(c)) {
      console2.log("  rateFeed (wstETH/ETH):", c.rateFeed);
      console2.log("  rateMaxStaleness (s):", c.rateMaxStaleness);
      console2.log("  usdFeed (ETH/USD):", c.usdFeed);
      console2.log("  usdMaxStaleness (s):", c.usdMaxStaleness);
      console2.log("  sequencerUptimeFeed:", c.sequencerUptimeFeed);
      console2.log("  gracePeriod (s):", c.gracePeriod);
    } else {
      console2.log("  usdFeed (wstETH/USD):", c.usdFeed);
      console2.log("  maxStaleness (s):", c.usdMaxStaleness);
    }
  }

  /// @dev Prices one whole token (18 decimals, enforced by the constructor) through the
  ///      live feeds. Warn-only; see the contract doc.
  function _smokeRead(
    address adapter
  ) internal view {
    try IPriceAdapter(adapter).getValueInUSDCents(1e18) returns (uint256 cents) {
      console2.log("  price check: 1 token = USD cents", cents);
    } catch {
      console2.log("  WARN price check reverted: stale feed, sequencer down / in grace, or a wrong feed address");
      console2.log("  WARN until it prices, getFee values this token at zero (or reverts if all must be priced)");
    }
  }

  /// @dev Appends the entry; a token already on record means this run would silently
  ///      orphan the previous adapter, so it reverts unless explicitly waived.
  function _recordAdapter(
    Types.Deployment memory deployment,
    Types.PriceAdapterDeployment memory record,
    bool allowReplace
  ) internal pure {
    address previous = ConfigLib.priceAdapterByToken(deployment, record.args.token);
    if (previous != address(0)) {
      require(
        allowReplace,
        string.concat(
          "DeployPriceAdapter: a price adapter for token ",
          vm.toString(record.args.token),
          " is already recorded for ",
          deployment.aliasName,
          " - set ALLOW_ADAPTER_REPLACE=true to replace it"
        )
      );
      console2.log("  WARN replacing recorded adapter for token (ALLOW_ADAPTER_REPLACE):", record.args.token);
      console2.log("  WARN previous adapter is dropped from the record:", previous);
      for (uint256 i = 0; i < deployment.priceAdapters.length; ++i) {
        if (deployment.priceAdapters[i].args.token == record.args.token) deployment.priceAdapters[i] = record;
      }
      return;
    }

    Types.PriceAdapterDeployment[] memory extended =
      new Types.PriceAdapterDeployment[](deployment.priceAdapters.length + 1);
    for (uint256 i = 0; i < deployment.priceAdapters.length; ++i) {
      extended[i] = deployment.priceAdapters[i];
    }
    extended[deployment.priceAdapters.length] = record;
    deployment.priceAdapters = extended;
  }
}
