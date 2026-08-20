// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {CommitteeVerifier} from "@chainlink-ccip/ccvs/CommitteeVerifier.sol";
import {BaseVerifier} from "@chainlink-ccip/ccvs/components/BaseVerifier.sol";
import {ICrossChainVerifierV1} from "@chainlink-ccip/interfaces/ICrossChainVerifierV1.sol";
import {Client} from "@chainlink-ccip/libraries/Client.sol";

import {CustomFeeConfig} from "./config/CustomFeeConfig.sol";
import {IWstETHUSDPriceAdapter} from "./oracle/IWstETHUSDPriceAdapter.sol";

/// @title CustomFeeCommitteeVerifier
/// @notice A thin {CommitteeVerifier} subclass that charges the CCV operator a
///         value-based fee: `fee = transferValueUSD * feeBps`, clamped to a
///         `[minFeeUSDCents, capUSDCents]` range. Everything else — signature
///         verification (`verifyMessage`), forwarding (`forwardToVerifier`) and
///         fee withdrawal (`withdrawFeeTokens`) — is inherited unchanged so the
///         fee path stays cleanly isolated from the verification path
///         (scoping doc Section 2, "Recommended structure").
/// @dev    The default CCIP v2.0 CommitteeVerifier only supports a flat
///         per-message fee via `RemoteChainConfig.feeUSDCents`. This contract
///         overrides ONLY `getFee` to add the bps + cap model.
///
///         Deployment: register the deployed instance as the `implementation`
///         behind the `VersionedVerifierResolver` (outbound per dest chain,
///         inbound per version tag) using a distinct `versionTag` and a
///         non-overlapping signer set (scoping doc Section 3).
contract CustomFeeCommitteeVerifier is CommitteeVerifier {
  /// @notice Per-destination-chain bps fee configuration.
  mapping(uint64 destChainSelector => CustomFeeConfig config) internal s_customFeeConfig;

  /// @notice Emitted when the bps fee config for a destination chain is set.
  event CustomFeeConfigSet(uint64 indexed destChainSelector, CustomFeeConfig config);

  // TODO (later step): consider an event emitted from the send path (not from
  // the `view` getFee) to record { messageId, feeToken, amount, feeUSDCents,
  // oracleRate } for accounting (scoping doc Section 4 note).

  /// @param dynamicConfig     inherited CommitteeVerifier dynamic config (incl. feeAggregator)
  /// @param storageLocations  inherited BaseVerifier storage locations
  /// @param rmn               RMN address
  /// @param versionTag        distinct version tag for resolver registration (Section 3)
  constructor(
    DynamicConfig memory dynamicConfig,
    string[] memory storageLocations,
    address rmn,
    bytes4 versionTag
  ) CommitteeVerifier(dynamicConfig, storageLocations, rmn, versionTag) {}

  // ---------------------------------------------------------------------------
  // Fee override — THE single point of change (scoping doc Section 2)
  // ---------------------------------------------------------------------------

  /// @notice Overrides BaseVerifier.getFee (declared `virtual`, inherited via
  ///         CommitteeVerifier). Returns a value-based fee for token transfers, clamped to
  ///         `[minFeeUSDCents, capUSDCents]`; falls back to the inherited flat
  ///         fee when no bps config is enabled for `destChainSelector`.
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
    // Base config still supplies gasForVerification / payloadSizeBytes and the
    // flat-fee fallback.
    RemoteChainConfig storage baseCfg = _getRemoteChainConfig(destChainSelector);
    CustomFeeConfig storage cfg = s_customFeeConfig[destChainSelector];

    // silence unused-parameter warnings until the logic below is implemented
    message;
    extraArgs;
    requestedFinality;

    // TODO (later step) — implement the bps + floor + cap model:
    //
    //   if (!cfg.enabled) {
    //     return (baseCfg.feeUSDCents, baseCfg.gasForVerification, baseCfg.payloadSizeBytes);
    //   }
    //   uint256 valueUSDCents = message.tokenAmounts.length == 0
    //     ? 0
    //     : IWstETHUSDPriceAdapter(cfg.priceAdapter).getValueInUSDCents(message.tokenAmounts[0].amount);
    //   uint256 fee = (valueUSDCents * cfg.feeBps) / 10_000;      // feeBps 5 -> 0.05%
    //   if (fee < cfg.minFeeUSDCents) fee = cfg.minFeeUSDCents;   // floor
    //   if (fee > cfg.capUSDCents)    fee = cfg.capUSDCents;      // cap (<= 65_535) BEFORE cast
    //   return (uint16(fee), baseCfg.gasForVerification, baseCfg.payloadSizeBytes);
    //
    // Placeholder pass-through so the contract compiles and behaves exactly like
    // the stock CommitteeVerifier until the override is filled in:
    cfg; // referenced to avoid unused warning while the body is a stub
    return (baseCfg.feeUSDCents, baseCfg.gasForVerification, baseCfg.payloadSizeBytes);
  }

  // ---------------------------------------------------------------------------
  // Config administration
  // ---------------------------------------------------------------------------

  /// @notice Set (or update) the bps fee config for a destination chain.
  /// @dev    TODO (later step): access control (owner-only), input validation
  ///         (capUSDCents <= 65_535, capUSDCents >= minFeeUSDCents, priceAdapter
  ///         != address(0) when enabled). Left permissionless-looking on purpose
  ///         so the guard is a conscious decision, not a copy-paste default.
  function setCustomFeeConfig(uint64 destChainSelector, CustomFeeConfig calldata config) external /* onlyOwner */ {
    // TODO: validation + onlyOwner
    s_customFeeConfig[destChainSelector] = config;
    emit CustomFeeConfigSet(destChainSelector, config);
  }

  /// @notice Read the bps fee config for a destination chain.
  function getCustomFeeConfig(uint64 destChainSelector) external view returns (CustomFeeConfig memory) {
    return s_customFeeConfig[destChainSelector];
  }
}
