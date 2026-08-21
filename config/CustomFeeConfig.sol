// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Per-destination-chain configuration for the value-based (bps) CCV
///         operator fee. One entry per `destChainSelector`.
/// @dev    File-level struct so it can be shared by the verifier, config
///         setters, deploy scripts and tests without a library indirection.
struct CustomFeeConfig {
  /// @notice wstETH -> USD price adapter used to value the transfer for this
  ///         destination chain. See {IPriceAdapter}.
  /// @dev    Sourcing differs mainnet vs L2 (scoping doc Section 4), so the
  ///         adapter is configured per chain.
  address priceAdapter;
  /// @notice Fee in basis points of transfer value. e.g. 5 = 0.05%.
  uint16 feeBps;
  /// @notice Minimum fee floor, in USD cents. Applied when the bps fee is below it.
  uint16 minFeeUSDCents;
  /// @notice Maximum fee cap, in USD cents. MUST be <= 65_535 because getFee
  ///         returns uint16 (scoping doc Section 3, constraint #1). The fee is
  ///         clamped to this value BEFORE the uint16 cast so large transfers do
  ///         not revert.
  uint16 capUSDCents;
  /// @notice When false, this verifier falls back to the inherited flat
  ///         `RemoteChainConfig.feeUSDCents` for this destination chain.
  bool enabled;
}
