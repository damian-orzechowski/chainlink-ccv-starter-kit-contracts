// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IWstETHUSDPriceAdapter } from "./IWstETHUSDPriceAdapter.sol";

/// @title WstETHUSDPriceAdapter (STUB)
/// @notice Skeleton adapter converting wstETH -> USD cents. Wiring only; the
///         oracle reads and rate composition are the main work item
///         (scoping doc Section 4) and land in a later step.
/// @dev    Two deployment shapes are expected (configure per chain):
///           - Mainnet: wstETH.stEthPerToken() * stETH/USD (or ETH/USD) feed
///           - L2:      Chainlink wstETH exchange-rate feed * stETH-or-ETH/USD feed
///         Both must guard against stale rounds and decimals mismatches
///         (scoping doc Section 5.2 audit focus).
contract WstETHUSDPriceAdapter is IWstETHUSDPriceAdapter {
  error NotImplemented();

  // TODO: immutables for the feed addresses / wstETH token, decimals, and
  // max staleness. Set them in the constructor once the sourcing is decided.

  /// @inheritdoc IWstETHUSDPriceAdapter
  function getValueInUSDCents(uint256 wstETHAmount) external view virtual returns (uint256) {
    // silence unused-parameter warning until implemented
    wstETHAmount;
    // TODO (later step):
    //   1. Read stETH-per-wstETH rate (mainnet: token contract; L2: exchange-rate feed).
    //   2. Read stETH/USD or ETH/USD from a Chainlink aggregator (latestRoundData).
    //   3. Assert both rounds are fresh (updatedAt within max staleness) and answer > 0.
    //   4. Compose with correct decimals -> USD cents. Round down.
    revert NotImplemented();
  }
}
