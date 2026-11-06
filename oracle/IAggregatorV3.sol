// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Minimal Chainlink aggregator interface (the subset the adapters use).
/// @dev    Declared locally to avoid coupling to a specific @chainlink/contracts
///         import path/version. Swap for the canonical interface if preferred.
interface IAggregatorV3 {
  function decimals() external view returns (uint8);

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
