// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IAggregatorV3 } from "./IAggregatorV3.sol";

/// @title PriceFeedLib
/// @notice Single, audited place for reading a Chainlink feed safely. Every
///         adapter routes its oracle reads through here so the staleness and
///         positivity guards have one implementation, not one per adapter.
library PriceFeedLib {
  error StalePrice(address feed, uint256 updatedAt, uint256 maxStaleness);
  error NonPositivePrice(address feed, int256 answer);
  error InvalidMaxStaleness(uint256 provided, uint256 min, uint256 max);

  uint256 internal constant STALENESS_MIN = 1 minutes;
  uint256 internal constant STALENESS_MAX = 7 days;

  /// @notice Revert unless `maxStaleness` is within [STALENESS_MIN, STALENESS_MAX].
  function requireValidStaleness(uint256 maxStaleness) internal pure {
    if (maxStaleness < STALENESS_MIN || maxStaleness > STALENESS_MAX) {
      revert InvalidMaxStaleness(maxStaleness, STALENESS_MIN, STALENESS_MAX);
    }
  }

  /// @notice Read `latestRoundData`, reverting if the answer is non-positive or
  ///         older than `maxStaleness` seconds.
  /// @return answer the feed answer as a uint256 (guaranteed > 0).
  function readFresh(IAggregatorV3 feed, uint256 maxStaleness) internal view returns (uint256 answer) {
    (, int256 rawAnswer,, uint256 updatedAt,) = feed.latestRoundData();
    if (rawAnswer <= 0) revert NonPositivePrice(address(feed), rawAnswer);
    // updatedAt == 0 means "no data yet" and is treated as stale.
    if (updatedAt == 0 || block.timestamp - updatedAt > maxStaleness) {
      revert StalePrice(address(feed), updatedAt, maxStaleness);
    }
    return uint256(rawAnswer);
  }
}
