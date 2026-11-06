// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IPriceAdapter
/// @notice Values an amount of ONE token in USD cents, for use inside `getFee`
///         (a `view` context). Each adapter is bound to a single token — it
///         knows that token's decimals and the oracle route to USD — so the
///         verifier registers one adapter per token and can price messages that
///         carry multiple, differently-denominated tokens. The interface is
///         token-agnostic; the concrete adapter chooses the asset and feeds.
/// @dev    The unit contract is strict: every adapter MUST return USD **cents**
///         so the verifier can sum results across different tokens. Each adapter
///         is responsible for its own decimals normalization, staleness checks
///         and rounding (round down for a fee quote).
interface IPriceAdapter {
  /// @notice The token this adapter prices.
  function token() external view returns (address);

  /// @notice The decimals the adapter's math assumes for `token()`.
  function tokenDecimals() external view returns (uint8);

  /// @notice USD-cents value of `amount` of the adapter's token.
  /// @param  amount token amount in the token's own smallest unit (the raw
  ///         on-chain integer, e.g. 1e18 for an 18-decimal token).
  /// @return valueUSDCents value in USD cents. NOT clamped — the verifier applies
  ///         the floor/cap. Returned as uint256 to avoid overflow before clamp.
  function getValueInUSDCents(uint256 amount) external view returns (uint256 valueUSDCents);
}
