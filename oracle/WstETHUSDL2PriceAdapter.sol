// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPriceAdapter } from "./IPriceAdapter.sol";
import { IAggregatorV3 } from "./IAggregatorV3.sol";
import { PriceFeedLib } from "./PriceFeedLib.sol";

interface IERC20Decimals {
  function decimals() external view returns (uint8);
}

/// @title WstETHUSDL2PriceAdapter
/// @notice Prices wstETH in USD cents on an L2, where the bridged wstETH does
///         not expose Lido's mainnet rate. Composes two Chainlink feeds
///         (scoping doc Section 4):
///           value_USD = amount_wstETH * (RATE_FEED: intermediate per wstETH)
///                                     * (USD_FEED: USD per intermediate)
///         where "intermediate" is stETH or ETH depending on which pair the
///         feeds quote (wstETH/stETH + stETH/USD, or wstETH/ETH + ETH/USD).
/// @dev    Each feed has its own heartbeat, so staleness is configured per feed.
///         Assumes wstETH has 18 decimals; the intermediate asset is treated as
///         18-decimals (stETH/ETH). Rounds down.
contract WstETHUSDL2PriceAdapter is IPriceAdapter {
  using PriceFeedLib for IAggregatorV3;

  error ZeroAddress();
  /// @notice The bound token's decimals don't match the adapter's assumption.
  error UnexpectedTokenDecimals(uint8 expected, uint8 actual);

  uint256 private constant WAD = 1e18; // wstETH & intermediate (stETH/ETH) decimals
  uint8 private constant TOKEN_DECIMALS = 18; // wstETH decimals (the WAD assumption)
  uint256 private constant CENTS_PER_USD = 100;

  address public immutable TOKEN; // the wstETH token this adapter prices

  IAggregatorV3 public immutable RATE_FEED; // wstETH/stETH or wstETH/ETH exchange rate
  uint8 public immutable RATE_FEED_DECIMALS;
  uint256 public immutable RATE_MAX_STALENESS; // seconds

  IAggregatorV3 public immutable USD_FEED; // stETH/USD or ETH/USD
  uint8 public immutable USD_FEED_DECIMALS;
  uint256 public immutable USD_MAX_STALENESS; // seconds

  IAggregatorV3 public immutable SEQUENCER_UPTIME_FEED; // Chainlink L2 sequencer uptime feed
  uint256 public immutable GRACE_PERIOD; // seconds to wait after sequencer recovery

  /// @param wstETH            the wstETH token this adapter prices (must be 18-decimal).
  /// @param rateFeed          Chainlink wstETH exchange-rate feed (intermediate per wstETH).
  /// @param usdFeed           Chainlink USD feed for the intermediate asset.
  /// @param rateMaxStaleness  max age (seconds) for the rate feed's round.
  /// @param usdMaxStaleness   max age (seconds) for the USD feed's round.
  /// @param sequencerUptimeFeed  Chainlink L2 Sequencer Uptime Feed for this L2
  /// @param gracePeriod       seconds to wait after sequencer recovery before trusting prices
  constructor(
    address wstETH,
    address rateFeed,
    address usdFeed,
    uint256 rateMaxStaleness,
    uint256 usdMaxStaleness,
    address sequencerUptimeFeed,
    uint256 gracePeriod
  ) {
    if (wstETH == address(0) || rateFeed == address(0) || usdFeed == address(0) || sequencerUptimeFeed == address(0)) revert ZeroAddress();

    PriceFeedLib.requireValidStaleness(rateMaxStaleness);
    PriceFeedLib.requireValidStaleness(usdMaxStaleness);
    PriceFeedLib.requireValidGracePeriod(gracePeriod);
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
    SEQUENCER_UPTIME_FEED = IAggregatorV3(sequencerUptimeFeed);
    GRACE_PERIOD = gracePeriod;
  }

  /// @inheritdoc IPriceAdapter
  function getValueInUSDCents(uint256 amount) external view virtual returns (uint256) {
    // Reject reads while the L2 sequencer is down or in its post-recovery grace period
    PriceFeedLib.requireSequencerUp(SEQUENCER_UPTIME_FEED, GRACE_PERIOD);
    // wstETH -> intermediate (stETH/ETH) wei: amount * rate / 10^rateDecimals
    uint256 rate = RATE_FEED.readFresh(RATE_MAX_STALENESS);
    uint256 intermediateWei = (amount * rate) / (10 ** RATE_FEED_DECIMALS);
    // intermediate -> USD cents: intermediateWei/1e18 * usdPrice/10^usdDec * 100
    uint256 usdPrice = USD_FEED.readFresh(USD_MAX_STALENESS);
    return (intermediateWei * usdPrice * CENTS_PER_USD) / (WAD * (10 ** USD_FEED_DECIMALS));
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
