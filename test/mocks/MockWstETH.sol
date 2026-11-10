// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal wstETH mock exposing settable ERC20 decimals.
contract MockWstETH {
  uint8 internal _decimals = 18;

  function setDecimals(
    uint8 d
  ) external {
    _decimals = d;
  }

  function decimals() external view returns (uint8) {
    return _decimals;
  }
}
