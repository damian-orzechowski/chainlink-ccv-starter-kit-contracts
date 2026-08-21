// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { CommitteeVerifier } from "@chainlink-ccip/ccvs/CommitteeVerifier.sol";
import { BaseVerifier } from "@chainlink-ccip/ccvs/components/BaseVerifier.sol";
import { ICrossChainVerifierV1 } from "@chainlink-ccip/interfaces/ICrossChainVerifierV1.sol";
import { Client } from "@chainlink-ccip/libraries/Client.sol";

import { CustomFeeConfig } from "./config/CustomFeeConfig.sol";
import { IPriceAdapter } from "./oracle/IPriceAdapter.sol";

/// @title CustomFeeCommitteeVerifier
/// @notice A thin {CommitteeVerifier} subclass that charges the CCV operator a
///         value-based fee: `fee = transferValueUSD * feeBps`, clamped to a
///         `[minFeeUSDCents, capUSDCents]` range. Everything else — signature
///         verification (`verifyMessage`), forwarding (`forwardToVerifier`) and
///         fee withdrawal (`withdrawFeeTokens`) — is inherited unchanged so the
///         fee path stays cleanly isolated from the verification path
///         (scoping doc Section 2, "Recommended structure").
/// @dev    Token-agnostic by design. Transfer value is computed by pricing each
///         transferred token with a token-specific {IPriceAdapter} and summing
///         the USD-cent results, so a single deployment supports messages that
///         carry multiple, differently-denominated tokens. wstETH is just one
///         adapter you can register; nothing here is asset-specific.
///
///         Two independent config surfaces:
///           - fee policy   : per destination chain ({CustomFeeConfig})
///           - price adapter : per token, global (a token's USD value does not
///                             depend on the destination)
///
///         Deployment: register the deployed instance as the `implementation`
///         behind the `VersionedVerifierResolver` (outbound per dest chain,
///         inbound per version tag) using a distinct `versionTag` and a
///         non-overlapping signer set (scoping doc Section 3).
contract CustomFeeCommitteeVerifier is CommitteeVerifier {
  /// @notice Per-destination-chain bps fee policy.
  mapping(uint64 destChainSelector => CustomFeeConfig config) internal s_feeConfig;

  /// @notice Per-token price adapter registry (token address on this chain ->
  ///         adapter that prices it in USD cents). Unset (address(0)) means the
  ///         token is unpriced and contributes zero value (see {getFee}).
  mapping(address token => IPriceAdapter adapter) internal s_priceAdapter;

  error CapBelowFloor(uint16 capUSDCents, uint16 minFeeUSDCents);
  error FeeBpsTooHigh(uint16 feeBps);
  error ZeroToken();
  error LengthMismatch();

  /// @notice Emitted when the bps fee policy for a destination chain is set.
  event CustomFeeConfigSet(uint64 indexed destChainSelector, CustomFeeConfig config);

  /// @notice Emitted when a token's price adapter is set (or cleared to address(0)).
  event PriceAdapterSet(address indexed token, address indexed adapter);

  // TODO (later step): consider an event emitted from the send path (not from
  // the `view` getFee) to record { messageId, feeToken, amount, feeUSDCents }
  // for accounting (scoping doc Section 4 note).

  /// @param dynamicConfig     inherited CommitteeVerifier dynamic config (incl. feeAggregator)
  /// @param storageLocations  inherited BaseVerifier storage locations
  /// @param rmn               RMN address
  /// @param versionTag        distinct version tag for resolver registration (Section 3)
  constructor(DynamicConfig memory dynamicConfig, string[] memory storageLocations, address rmn, bytes4 versionTag)
    CommitteeVerifier(dynamicConfig, storageLocations, rmn, versionTag)
  { }

  // ---------------------------------------------------------------------------
  // Fee override — THE single point of change (scoping doc Section 2)
  // ---------------------------------------------------------------------------

  /// @notice Overrides BaseVerifier.getFee (declared `virtual`, inherited via
  ///         CommitteeVerifier). Returns a value-based fee for token transfers,
  ///         clamped to `[minFeeUSDCents, capUSDCents]`; falls back to the
  ///         inherited flat fee when no bps policy is enabled for
  ///         `destChainSelector`.
  function getFee(
    uint64 destChainSelector,
    Client.EVM2AnyMessage memory message,
    bytes memory extraArgs,
    bytes4 requestedFinality
  )
    external
    view
    override(BaseVerifier, ICrossChainVerifierV1)
    returns (uint16 feeUSDCents, uint32 gasForVerification, uint32 payloadSizeBytes)
  {
    // The inherited base config always supplies gasForVerification /
    // payloadSizeBytes, and the flat feeUSDCents used as the fallback.
    RemoteChainConfig storage baseCfg = _getRemoteChainConfig(destChainSelector);
    CustomFeeConfig storage cfg = s_feeConfig[destChainSelector];

    // No bps config -> stock flat-fee behavior.
    if (!cfg.enabled) {
      return (baseCfg.feeUSDCents, baseCfg.gasForVerification, baseCfg.payloadSizeBytes);
    }

    // Value the transfer by pricing each token with its own adapter and summing
    // the USD-cent results. This supports multi-token and mixed-token messages.
    // A message with no (priced) token transfer has zero value and falls to the
    // floor.
    uint256 valueUSDCents;
    uint256 nTokens = message.tokenAmounts.length;
    for (uint256 i = 0; i < nTokens; ++i) {
      IPriceAdapter adapter = s_priceAdapter[message.tokenAmounts[i].token];
      // Unpriced token -> contributes zero value
      if (address(adapter) == address(0)) continue;
      valueUSDCents += adapter.getValueInUSDCents(message.tokenAmounts[i].amount);
    }

    uint256 fee = (valueUSDCents * uint256(cfg.feeBps)) / 10_000; // feeBps 5 -> 0.05%
    if (fee < cfg.minFeeUSDCents) fee = cfg.minFeeUSDCents; // floor
    if (fee > cfg.capUSDCents) fee = cfg.capUSDCents; // cap (<= 65_535)

    return (uint16(fee), baseCfg.gasForVerification, baseCfg.payloadSizeBytes);
  }

  // ---------------------------------------------------------------------------
  // Config administration
  // ---------------------------------------------------------------------------

  /// @notice Set (or update) the bps fee policy for a destination chain.
  function setFeeConfig(uint64 destChainSelector, CustomFeeConfig calldata config) external onlyOwner {
    if (config.feeBps > 10_000) revert FeeBpsTooHigh(config.feeBps);
    if (config.capUSDCents < config.minFeeUSDCents) revert CapBelowFloor(config.capUSDCents, config.minFeeUSDCents);
    s_feeConfig[destChainSelector] = config;
    emit CustomFeeConfigSet(destChainSelector, config);
  }

  /// @notice Register (or clear) the price adapter for a token. Pass
  ///         `adapter == address(0)` to unregister.
  function setPriceAdapter(address token, IPriceAdapter adapter) external onlyOwner {
    _setPriceAdapter(token, adapter);
  }

  /// @notice Batch variant of setPriceAdapter.
  function setPriceAdapters(address[] calldata tokens, IPriceAdapter[] calldata adapters) external onlyOwner {
    if (tokens.length != adapters.length) revert LengthMismatch();
    for (uint256 i = 0; i < tokens.length; ++i) {
      _setPriceAdapter(tokens[i], adapters[i]);
    }
  }

  function _setPriceAdapter(address token, IPriceAdapter adapter) internal {
    if (token == address(0)) revert ZeroToken();
    s_priceAdapter[token] = adapter;
    emit PriceAdapterSet(token, address(adapter));
  }

  /// @notice Read the bps fee policy for a destination chain.
  function getFeeConfig(uint64 destChainSelector) external view returns (CustomFeeConfig memory) {
    return s_feeConfig[destChainSelector];
  }

  /// @notice Read the price adapter registered for a token (address(0) if none).
  function getPriceAdapter(address token) external view returns (IPriceAdapter) {
    return s_priceAdapter[token];
  }
}
