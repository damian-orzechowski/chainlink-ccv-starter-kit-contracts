// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IWstETH } from "../../src/oracle/WstETHUSDPriceAdapter.sol";

/// @notice Minimal wstETH mock exposing a settable stEthPerToken rate (1e18-scaled).
contract MockWstETH is IWstETH {
  uint256 internal _stEthPerToken;
  uint8 internal _decimals = 18;

  constructor(uint256 stEthPerToken_) {
    _stEthPerToken = stEthPerToken_;
  }

  function setDecimals(uint8 d) external {
    _decimals = d;
  }

  function setStEthPerToken(uint256 v) external {
    _stEthPerToken = v;
  }

  function stEthPerToken() external view returns (uint256) {
    return _stEthPerToken;
  }

  function decimals() external view returns (uint8) {
    return _decimals;
  }
}
