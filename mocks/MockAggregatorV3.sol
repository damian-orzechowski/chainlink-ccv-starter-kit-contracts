// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IAggregatorV3} from "../../src/oracle/IAggregatorV3.sol";

/// @notice Minimal configurable Chainlink aggregator mock for unit tests.
contract MockAggregatorV3 is IAggregatorV3 {
  uint8 internal _decimals;
  int256 internal _answer;
  uint256 internal _updatedAt;

  constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
    _decimals = decimals_;
    _answer = answer_;
    _updatedAt = updatedAt_;
  }

  function setAnswer(int256 answer_) external {
    _answer = answer_;
  }

  function setUpdatedAt(uint256 updatedAt_) external {
    _updatedAt = updatedAt_;
  }

  function decimals() external view returns (uint8) {
    return _decimals;
  }

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    return (1, _answer, _updatedAt, _updatedAt, 1);
  }
}
