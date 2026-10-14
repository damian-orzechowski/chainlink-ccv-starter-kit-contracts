// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPriceAdapter } from "./IPriceAdapter.sol";
import { IAggregatorV3 } from "./IAggregatorV3.sol";
import { PriceFeedLib } from "./PriceFeedLib.sol";

interface IERC20Decimals {
  function decimals() external view returns (uint8);
}

/// @title WstETHUSDPriceAdapter (mainnet)
/// @notice Prices wstETH in USD cents by composing two Chainlink feeds:
///           value_USD = amount_wstETH * (RATE_FEED: ETH per wstETH)
///                                     * (USD_FEED: USD per ETH)
///         i.e. wstETH/USD = (wstETH/ETH) × (ETH/USD). wstETH/ETH is used
///         because it is far more widely available than a direct wstETH/USD
///         feed. One concrete {IPriceAdapter}; register it against the wstETH
///         token address in the verifier.
/// @dev    Each feed has its own heartbeat, so staleness is configured per feed.
///         Assumes wstETH has 18 decimals; ETH is 18 decimals. Rounds down.
contract WstETHUSDPriceAdapter is IPriceAdapter {
  using PriceFeedLib for IAggregatorV3;

  error ZeroAddress();
  /// @notice The bound token's decimals don't match the adapter's assumption.
  error UnexpectedTokenDecimals(uint8 expected, uint8 actual);

  uint256 private constant WAD = 1e18; // wstETH & ETH decimals
  uint8 private constant TOKEN_DECIMALS = 18; // wstETH decimals (the WAD assumption)
  uint256 private constant CENTS_PER_USD = 100;

  address public immutable TOKEN; // the wstETH token this adapter prices

  IAggregatorV3 public immutable RATE_FEED; // wstETH/ETH
  uint8 public immutable RATE_FEED_DECIMALS;
  uint256 public immutable RATE_MAX_STALENESS; // seconds

  IAggregatorV3 public immutable USD_FEED; // ETH/USD
  uint8 public immutable USD_FEED_DECIMALS;
  uint256 public immutable USD_MAX_STALENESS; // seconds

  /// @param wstETH            the wstETH token this adapter prices (must be 18-decimal).
  /// @param rateFeed          Chainlink wstETH/ETH feed (ETH per wstETH).
  /// @param usdFeed           Chainlink ETH/USD feed.
  /// @param rateMaxStaleness  max age (seconds) for the wstETH/ETH feed's round.
  /// @param usdMaxStaleness   max age (seconds) for the ETH/USD feed's round.
  constructor(address wstETH, address rateFeed, address usdFeed, uint256 rateMaxStaleness, uint256 usdMaxStaleness) {
    if (wstETH == address(0) || rateFeed == address(0) || usdFeed == address(0)) revert ZeroAddress();
    PriceFeedLib.requireValidStaleness(rateMaxStaleness);
    PriceFeedLib.requireValidStaleness(usdMaxStaleness);
    TOKEN = wstETH;
    // The math assumes an 18-decimal token
    uint8 dec = IERC20Decimals(wstETH).decimals();
    if (dec != TOKEN_DECIMALS) revert UnexpectedTokenDecimals(TOKEN_DECIMALS, dec);
    RATE_FEED = IAggregatorV3(rateFeed);
    RATE_FEED_DECIMALS = IAggregatorV3(rateFeed).decimals();
    RATE_MAX_STALENESS = rateMaxStaleness;
    USD_FEED = IAggregatorV3(usdFeed);
    USD_FEED_DECIMALS = IAggregatorV3(usdFeed).decimals();
    USD_MAX_STALENESS = usdMaxStaleness;
  }

  /// @inheritdoc IPriceAdapter
  function getValueInUSDCents(uint256 amount) external view virtual returns (uint256) {
    // wstETH -> ETH wei: amount * rate / 10^rateDecimals
    uint256 rate = RATE_FEED.readFresh(RATE_MAX_STALENESS);
    uint256 ethWei = (amount * rate) / (10 ** RATE_FEED_DECIMALS);
    // ETH -> USD cents: ethWei/1e18 * usdPrice/10^usdDec * 100
    uint256 usdPrice = USD_FEED.readFresh(USD_MAX_STALENESS);
    return (ethWei * usdPrice * CENTS_PER_USD) / (WAD * (10 ** USD_FEED_DECIMALS));
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
