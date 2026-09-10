// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPriceAdapter } from "./IPriceAdapter.sol";
import { IAggregatorV3 } from "./IAggregatorV3.sol";
import { PriceFeedLib } from "./PriceFeedLib.sol";

interface IWstETH {
  /// @notice stETH per 1 wstETH, scaled by 1e18 (Lido's own on-chain rate).
  function stEthPerToken() external view returns (uint256);
  /// @notice ERC20 decimals of wstETH (expected 18).
  function decimals() external view returns (uint8);
}

/// @title WstETHUSDPriceAdapter (mainnet)
/// @notice Prices wstETH in USD cents on a chain where Lido's rate is readable
///         directly from the wstETH token (i.e. Ethereum mainnet):
///           value_USD = amount_wstETH * (stETH per wstETH) * (USD per stETH)
///         (scoping doc Section 4). One concrete {IPriceAdapter}; register it
///         against the wstETH token address in the verifier.
/// @dev    `USD_FEED` should be a stETH/USD feed. An ETH/USD feed also works but
///         ignores any stETH<->ETH depeg — acceptable for a small capped fee,
///         but a documented approximation.
///         Assumes wstETH has 18 decimals and `stEthPerToken()` is 1e18-scaled
///         (both true for Lido's wstETH).
contract WstETHUSDPriceAdapter is IPriceAdapter {
  using PriceFeedLib for IAggregatorV3;

  error ZeroAddress();
  /// @notice The bound token's decimals don't match the adapter's assumption.
  error UnexpectedTokenDecimals(uint8 expected, uint8 actual);

  uint256 private constant WAD = 1e18; // wstETH & stETH decimals
  uint8 private constant TOKEN_DECIMALS = 18; // wstETH decimals
  uint256 private constant CENTS_PER_USD = 100;

  IWstETH public immutable WSTETH;
  IAggregatorV3 public immutable USD_FEED; // stETH/USD (or ETH/USD)
  uint8 public immutable USD_FEED_DECIMALS;
  uint256 public immutable MAX_STALENESS; // seconds

  /// @param wstETH        the wstETH token (provides stEthPerToken()).
  /// @param usdFeed       Chainlink stETH/USD (or ETH/USD) aggregator.
  /// @param maxStaleness  max age (seconds) accepted for the feed's round.
  constructor(address wstETH, address usdFeed, uint256 maxStaleness) {
    if (wstETH == address(0) || usdFeed == address(0)) revert ZeroAddress();
    PriceFeedLib.requireValidStaleness(maxStaleness);
    WSTETH = IWstETH(wstETH);
    // The math assumes an 18-decimal token
    uint8 dec = IWstETH(wstETH).decimals();
    if (dec != TOKEN_DECIMALS) revert UnexpectedTokenDecimals(TOKEN_DECIMALS, dec);
    USD_FEED = IAggregatorV3(usdFeed);
    USD_FEED_DECIMALS = IAggregatorV3(usdFeed).decimals();
    MAX_STALENESS = maxStaleness;
  }

  /// @inheritdoc IPriceAdapter
  function getValueInUSDCents(uint256 amount) external view virtual returns (uint256) {
    // wstETH -> stETH (both 18 decimals): stEthWei = amount * stEthPerToken / 1e18
    uint256 stEthWei = (amount * WSTETH.stEthPerToken()) / WAD;
    // stETH -> USD cents: stEthWei/1e18 * usdPrice/10^dec * 100
    uint256 usdPrice = USD_FEED.readFresh(MAX_STALENESS);
    return (stEthWei * usdPrice * CENTS_PER_USD) / (WAD * (10 ** USD_FEED_DECIMALS));
  }

  /// @inheritdoc IPriceAdapter
  function token() external view virtual returns (address) {
    return address(WSTETH);
  }

  /// @inheritdoc IPriceAdapter
  function tokenDecimals() external pure virtual returns (uint8) {
    return TOKEN_DECIMALS;
  }
}
