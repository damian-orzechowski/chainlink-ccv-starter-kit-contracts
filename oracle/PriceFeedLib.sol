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
