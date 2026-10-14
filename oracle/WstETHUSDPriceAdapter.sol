// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPriceAdapter } from "./IPriceAdapter.sol";
import { IAggregatorV3 } from "./IAggregatorV3.sol";
import { PriceFeedLib } from "./PriceFeedLib.sol";

interface IERC20Decimals {
  function decimals() external view returns (uint8);
}

/// @title WstETHUSDPriceAdapter (mainnet)
/// @notice Prices wstETH in USD cents from a single wstETH/USD feed:
///           value_USD = amount_wstETH * (USD per wstETH)
///         One concrete {IPriceAdapter}; register it against the wstETH token
///         address in the verifier.
/// @dev    `USD_FEED` must quote wstETH/USD directly; the stETH exchange rate is
///         assumed to be priced into the feed, so no stETH conversion is done here.
///         Assumes wstETH has 18 decimals. Rounds down.
contract WstETHUSDPriceAdapter is IPriceAdapter {
  using PriceFeedLib for IAggregatorV3;

  error ZeroAddress();
  /// @notice The bound token's decimals don't match the adapter's assumption.
  error UnexpectedTokenDecimals(uint8 expected, uint8 actual);

  uint256 private constant WAD = 1e18; // wstETH decimals
  uint8 private constant TOKEN_DECIMALS = 18; // wstETH decimals
  uint256 private constant CENTS_PER_USD = 100;

  address public immutable TOKEN; // the wstETH token this adapter prices
  IAggregatorV3 public immutable USD_FEED; // wstETH/USD
  uint8 public immutable USD_FEED_DECIMALS;
  uint256 public immutable MAX_STALENESS; // seconds

  /// @param wstETH        the wstETH token this adapter prices (must be 18-decimal).
  /// @param usdFeed       Chainlink wstETH/USD aggregator.
  /// @param maxStaleness  max age (seconds) accepted for the feed's round.
  constructor(address wstETH, address usdFeed, uint256 maxStaleness) {
    if (wstETH == address(0) || usdFeed == address(0)) revert ZeroAddress();
    PriceFeedLib.requireValidStaleness(maxStaleness);
    TOKEN = wstETH;
    // The math assumes an 18-decimal token
    uint8 dec = IERC20Decimals(wstETH).decimals();
    if (dec != TOKEN_DECIMALS) revert UnexpectedTokenDecimals(TOKEN_DECIMALS, dec);
    USD_FEED = IAggregatorV3(usdFeed);
    USD_FEED_DECIMALS = IAggregatorV3(usdFeed).decimals();
    MAX_STALENESS = maxStaleness;
  }

  /// @inheritdoc IPriceAdapter
  function getValueInUSDCents(uint256 amount) external view virtual returns (uint256) {
    // wstETH -> USD cents: amount/1e18 * usdPrice/10^dec * 100
    uint256 usdPrice = USD_FEED.readFresh(MAX_STALENESS);
    return (amount * usdPrice * CENTS_PER_USD) / (WAD * (10 ** USD_FEED_DECIMALS));
  }

  /// @inheritdoc IPriceAdapter
  function token() external view virtual returns (address) {
    return TOKEN;
  }

  /// @inheritdoc IPriceAdapter
  function tokenDecimals() external pure virtual returns (uint8) {
    return TOKEN_DECIMALS;
  }
}
