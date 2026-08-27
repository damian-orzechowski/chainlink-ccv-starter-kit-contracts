// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IWstETH} from "../../src/oracle/WstETHUSDPriceAdapter.sol";

/// @notice Minimal wstETH mock exposing a settable stEthPerToken rate (1e18-scaled).
contract MockWstETH is IWstETH {
  uint256 internal _stEthPerToken;

  constructor(uint256 stEthPerToken_) {
    _stEthPerToken = stEthPerToken_;
  }

  function setStEthPerToken(uint256 v) external {
    _stEthPerToken = v;
  }

  function stEthPerToken() external view returns (uint256) {
    return _stEthPerToken;
  }
}
