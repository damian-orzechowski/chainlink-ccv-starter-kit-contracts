// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Minimal configurable Chainlink aggregator mock for unit tests.
contract MockAggregatorV3 is AggregatorV3Interface {
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

  function description() external pure returns (string memory) {
    return "MockAggregatorV3";
  }

  function version() external pure returns (uint256) {
    return 1;
  }

  function getRoundData(uint80 roundId_)
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    return (roundId_, _answer, _updatedAt, _updatedAt, roundId_);
  }
}
