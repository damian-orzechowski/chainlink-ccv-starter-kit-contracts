// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPriceAdapter } from "../../src/oracle/IPriceAdapter.sol";

/// @notice Deterministic linear price adapter for unit tests.
/// @dev    value = amount * usdCentsPerToken / 1e18, so `usdCentsPerToken` is the
///         USD-cent value of ONE whole (1e18) token. Set `shouldRevert` to
///         exercise adapter-failure handling.
contract MockPriceAdapter is IPriceAdapter {
  address internal immutable TOKEN;
  uint256 public usdCentsPerToken;
  bool public shouldRevert;

  error MockAdapterReverted();

  constructor(address token_, uint256 usdCentsPerToken_) {
    TOKEN = token_;
    usdCentsPerToken = usdCentsPerToken_;
  }

  function setUsdCentsPerToken(uint256 v) external {
    usdCentsPerToken = v;
  }

  function setShouldRevert(bool v) external {
    shouldRevert = v;
  }

  function token() external view returns (address) {
    return TOKEN;
  }

  function tokenDecimals() external pure returns (uint8) {
    return 18;
  }

  function getValueInUSDCents(uint256 amount) external view returns (uint256) {
    if (shouldRevert) revert MockAdapterReverted();
    return (amount * usdCentsPerToken) / 1e18;
  }
}
