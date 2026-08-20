// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IWstETHUSDPriceAdapter
/// @notice Prices an amount of wstETH (wei) in USD cents for use inside
///         `getFee` (a `view` context). Isolated behind an interface so the
///         mainnet and L2 sourcing strategies (scoping doc Section 4) can be
///         swapped per destination chain without touching the verifier.
/// @dev    Composition of rates (scoping doc Section 4):
///           value_USD = amount_wstETH * (stETH per wstETH) * (stETH -> USD)
///         Mainnet: read the rate directly from the wstETH token contract
///                  (stEthPerToken / getStETHByWstETH) + a Chainlink
///                  stETH/USD (or ETH/USD) feed for the second hop.
///         L2:      read the Chainlink wstETH/ETH (or wstETH/stETH) exchange-rate
///                  feed, then multiply by stETH/USD or ETH/USD.
interface IWstETHUSDPriceAdapter {
  /// @notice Value of `wstETHAmount` (in wei) expressed in USD cents.
  /// @param  wstETHAmount amount of wstETH, in wei (1e18 = 1 wstETH).
  /// @return valueUSDCents value in USD cents. NOT clamped — the caller applies
  ///         the floor/cap. Returned as uint256 to avoid overflow before clamp.
  function getValueInUSDCents(uint256 wstETHAmount) external view returns (uint256 valueUSDCents);

  // TODO (later step): expose staleness / decimals metadata so the verifier or
  // monitoring can assert freshness, e.g.
  //   function description() external view returns (string memory);
  //   function maxStalenessSeconds() external view returns (uint256);
}
