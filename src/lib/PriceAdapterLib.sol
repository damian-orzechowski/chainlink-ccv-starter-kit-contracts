// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WstETHUSDL2PriceAdapter} from "../price-adapters/WstETHUSDL2PriceAdapter.sol";
import {WstETHUSDPriceAdapter} from "../price-adapters/WstETHUSDPriceAdapter.sol";
import {ConfigLib} from "./ConfigLib.sol";
import {Types} from "./Types.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title PriceAdapterLib
/// @notice Price adapters are ownerless and immutable: their constructor arguments are
///         their whole configuration. That makes three copies of the same values that
///         must agree - declared (`config/operator/chains/<alias>.json`), recorded
///         (`config/deployments/<alias>.json`) and on-chain (the adapter's immutables) -
///         and nothing on-chain can bring a stale copy back into line.
/// @dev Shared by ValidateConfig (declared vs recorded), DriftCheck (recorded vs
///      on-chain) and SnapshotOperator (on-chain back into the declared schema).
library PriceAdapterLib {
  Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

  /// @notice Reads an adapter's constructor arguments back from its public immutables.
  /// @return known False when `adapter` has no code or is neither WstETHUSDPriceAdapter
  ///         nor WstETHUSDL2PriceAdapter (told apart by RATE_FEED, which only L2 has).
  function describe(
    address adapter
  ) internal view returns (bool known, Types.PriceAdapterConfig memory c) {
    // A typed call to a codeless address fails in ABI decoding, which try/catch cannot catch.
    if (adapter.code.length == 0) return (known, c);
    try WstETHUSDL2PriceAdapter(adapter).RATE_FEED() returns (AggregatorV3Interface rateFeed) {
      WstETHUSDL2PriceAdapter l2 = WstETHUSDL2PriceAdapter(adapter);
      c.contractName = ConfigLib.L2_PRICE_ADAPTER;
      c.token = l2.TOKEN();
      c.rateFeed = address(rateFeed);
      c.rateMaxStaleness = l2.RATE_MAX_STALENESS();
      c.usdFeed = address(l2.USD_FEED());
      c.usdMaxStaleness = l2.USD_MAX_STALENESS();
      c.sequencerUptimeFeed = address(l2.SEQUENCER_UPTIME_FEED());
      c.gracePeriod = l2.GRACE_PERIOD();
      known = true;
      return (known, c);
    } catch {}
    try WstETHUSDPriceAdapter(adapter).MAX_STALENESS() returns (uint256 maxStaleness) {
      WstETHUSDPriceAdapter l1 = WstETHUSDPriceAdapter(adapter);
      c.contractName = ConfigLib.L1_PRICE_ADAPTER;
      c.token = l1.TOKEN();
      c.usdFeed = address(l1.USD_FEED());
      c.usdMaxStaleness = maxStaleness;
      known = true;
    } catch {}
  }

  /// @notice Every field where `actual` differs from `expected`, one
  ///         "<field> <expected> != <actual>" line each; empty when they agree.
  /// @dev Fields an adapter does not take are zero on both sides (the loaders and the
  ///      record write zeros there), so comparing all of them is exact for either kind.
  function diff(
    Types.PriceAdapterConfig memory expected,
    Types.PriceAdapterConfig memory actual
  ) internal pure returns (string[] memory lines) {
    lines = new string[](8);
    uint256 n = 0;
    if (keccak256(bytes(expected.contractName)) != keccak256(bytes(actual.contractName))) {
      lines[n++] = string.concat("contract ", expected.contractName, " != ", actual.contractName);
    }
    n = _address(lines, n, "token", expected.token, actual.token);
    n = _address(lines, n, "rateFeed", expected.rateFeed, actual.rateFeed);
    n = _uint(lines, n, "rateMaxStaleness", expected.rateMaxStaleness, actual.rateMaxStaleness);
    n = _address(lines, n, "usdFeed", expected.usdFeed, actual.usdFeed);
    n = _uint(lines, n, "usdMaxStaleness", expected.usdMaxStaleness, actual.usdMaxStaleness);
    n = _address(lines, n, "sequencerUptimeFeed", expected.sequencerUptimeFeed, actual.sequencerUptimeFeed);
    n = _uint(lines, n, "gracePeriod", expected.gracePeriod, actual.gracePeriod);
    assembly {
      mstore(lines, n)
    }
  }

  /// @notice Declared vs recorded, for every token either side names. Returns "" when
  ///         they agree, else one message naming each disagreement and the fix.
  /// @dev A declared token with no record is fine (not deployed yet). A recorded token
  ///      that is no longer declared, or declared with other values, means the operator
  ///      file stopped describing what is deployed: until a replacement adapter is
  ///      deployed (`ALLOW_ADAPTER_REPLACE=true`), the edit has no effect on chain.
  function declaredVsRecordedError(
    Types.PriceAdapterConfig[] memory declared,
    Types.Deployment memory deployment
  ) internal pure returns (string memory err) {
    string memory recordPath = ConfigLib.deploymentPath(deployment.aliasName);
    for (uint256 i = 0; i < deployment.priceAdapters.length; ++i) {
      Types.PriceAdapterDeployment memory recorded = deployment.priceAdapters[i];
      string memory subject = string.concat("priceAdapters entry for token ", vm.toString(recorded.args.token));
      (bool found, Types.PriceAdapterConfig memory entry) = _declaredFor(declared, recorded.args.token);
      if (!found) {
        err = _append(
          err,
          string.concat(
            subject,
            " is missing, but ",
            recordPath,
            " records adapter ",
            vm.toString(recorded.addr),
            " for it - restore the entry (make snapshot rebuilds it from chain)"
          )
        );
        continue;
      }
      string[] memory fields = diff(entry, recorded.args);
      if (fields.length == 0) continue;
      err = _append(
        err,
        string.concat(
          subject,
          " differs from adapter ",
          vm.toString(recorded.addr),
          " recorded in ",
          recordPath,
          " (declared != recorded): ",
          _join(fields),
          " - adapters are immutable: restore the recorded values, or deploy a replacement with make deploy-price-adapter CHAIN=",
          deployment.aliasName,
          " TOKEN=",
          vm.toString(recorded.args.token),
          " ALLOW_ADAPTER_REPLACE=true"
        )
      );
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

  function _address(
    string[] memory lines,
    uint256 n,
    string memory field,
    address expected,
    address actual
  ) private pure returns (uint256) {
    if (expected == actual) return n;
    lines[n] = string.concat(field, " ", vm.toString(expected), " != ", vm.toString(actual));
    return n + 1;
  }

  function _uint(
    string[] memory lines,
    uint256 n,
    string memory field,
    uint256 expected,
    uint256 actual
  ) private pure returns (uint256) {
    if (expected == actual) return n;
    lines[n] = string.concat(field, " ", vm.toString(expected), " != ", vm.toString(actual));
    return n + 1;
  }

  function _join(
    string[] memory parts
  ) private pure returns (string memory out) {
    for (uint256 i = 0; i < parts.length; ++i) {
      out = string.concat(out, i == 0 ? "" : ", ", parts[i]);
    }
  }

  function _append(
    string memory err,
    string memory next
  ) private pure returns (string memory) {
    return bytes(err).length == 0 ? next : string.concat(err, "; ", next);
  }
}
