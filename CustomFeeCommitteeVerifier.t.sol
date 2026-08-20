// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {CustomFeeCommitteeVerifier} from "../src/CustomFeeCommitteeVerifier.sol";
import {CustomFeeConfig} from "../src/config/CustomFeeConfig.sol";

/// @notice Test skeleton for the bps + cap fee override.
/// @dev    Section 5.1 of the scoping doc splits testing into:
///           - unit tests for the fee math + clamping edges,
///           - fuzz tests on the arithmetic,
///           - fork tests against live feeds on each dest chain.
///         These are stubs so the suite compiles; fill them in as the logic lands.
contract CustomFeeCommitteeVerifierTest is Test {
  CustomFeeCommitteeVerifier internal verifier;

  function setUp() public {
    // TODO (later step): deploy the verifier. Requires constructing the
    // inherited CommitteeVerifier args:
    //   - DynamicConfig (incl. feeAggregator)
    //   - storageLocations (string[])
    //   - rmn address (mock in unit tests)
    //   - versionTag (bytes4)
    // Then seed a per-dest-chain CustomFeeConfig via setCustomFeeConfig().
  }

  // --- Fee math ---------------------------------------------------------------

  function test_getFee_bpsBelowFloor_returnsFloor() public {
    vm.skip(true); // TODO
  }

  function test_getFee_bpsInRange_returnsBpsFee() public {
    vm.skip(true); // TODO
  }

  function test_getFee_bpsAboveCap_returnsCap() public {
    vm.skip(true); // TODO: assert cap applied BEFORE uint16 cast; no revert on large transfers
  }

  function test_getFee_disabledConfig_fallsBackToFlatFee() public {
    vm.skip(true); // TODO: no bps config -> inherited RemoteChainConfig.feeUSDCents
  }

  function test_getFee_noTokenTransfer_valueIsZero() public {
    vm.skip(true); // TODO: message.tokenAmounts.length == 0 -> value 0 -> floor
  }

  // --- Fuzz -------------------------------------------------------------------

  /// forge-config: default.fuzz.runs = 256
  function testFuzz_getFee_neverExceedsCap(uint256 wstETHAmount, uint16 feeBps) public {
    vm.skip(true); // TODO: for any input, returned fee in [minFee, cap] and fits uint16
  }

  // --- Fork (Section 5.1: live feeds per chain) -------------------------------

  function test_fork_mainnet_priceAdapter() public {
    vm.skip(true); // TODO: fork mainnet, wire real wstETH + stETH/USD feed, sanity-check value
  }
}
