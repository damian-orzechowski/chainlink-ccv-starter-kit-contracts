// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { CustomFeeCommitteeVerifier } from "../src/CustomFeeCommitteeVerifier.sol";
import { CustomFeeConfig } from "../src/config/CustomFeeConfig.sol";
import { IPriceAdapter } from "../src/oracle/IPriceAdapter.sol";

import { CommitteeVerifier } from "@chainlink-ccip/ccvs/CommitteeVerifier.sol";
import { BaseVerifier } from "@chainlink-ccip/ccvs/components/BaseVerifier.sol";
import { IRouter } from "@chainlink-ccip/interfaces/IRouter.sol";
import { Client } from "@chainlink-ccip/libraries/Client.sol";
import { FinalityCodec } from "@chainlink-ccip/libraries/FinalityCodec.sol";

import { MockPriceAdapter } from "./mocks/MockPriceAdapter.sol";

/// @notice Unit tests for the bps + floor + cap fee override and its config
///         administration. Deploys the real verifier (dummy constructor args)
///         and configures the inherited RemoteChainConfig through the real
///         `applyRemoteChainConfigUpdates` admin path.
contract CustomFeeCommitteeVerifierTest is Test {
  CustomFeeCommitteeVerifier internal verifier;

  MockPriceAdapter internal adapterA; // 1 token == $1000 == 100_000 cents
  MockPriceAdapter internal adapterB; // 1 token == $500  ==  50_000 cents

  address internal tokenA = makeAddr("tokenA");
  address internal tokenB = makeAddr("tokenB");
  address internal tokenUnpriced = makeAddr("tokenUnpriced");
  address internal stranger = makeAddr("stranger");

  // Destination selectors
  uint64 internal constant DEST = 1; // bps fee enabled
  uint64 internal constant DEST_FLAT = 2; // only base config, bps disabled
  uint64 internal constant UNCONFIGURED = 999; // never given a base config (no router)

  // Base (inherited) RemoteChainConfig values
  uint16 internal constant FLAT_FEE = 25; // cents
  uint32 internal constant GAS = 90_000;
  uint16 internal constant PAYLOAD = 256;

  // bps policy for DEST
  uint16 internal constant FEE_BPS = 5; // 0.05%
  uint16 internal constant MIN_CENTS = 10; // $0.10 floor
  uint16 internal constant CAP_CENTS = 1000; // $10 cap

  function setUp() public {
    CommitteeVerifier.DynamicConfig memory dc =
      CommitteeVerifier.DynamicConfig({ feeAggregator: makeAddr("agg"), allowlistAdmin: makeAddr("allowlistAdmin") });

    verifier = new CustomFeeCommitteeVerifier(
      dc,
      new string[](0), // storageLocations (may be empty)
      makeAddr("rmn"), // rmn must be nonzero
      bytes4(uint32(1)) // versionTag must be nonzero
    );

    // Configure inherited base config for both destinations (gasForVerification must be != 0).
    BaseVerifier.RemoteChainConfigArgs[] memory args = new BaseVerifier.RemoteChainConfigArgs[](2);
    args[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(makeAddr("router")),
      remoteChainSelector: DEST,
      allowlistEnabled: false,
      feeUSDCents: FLAT_FEE,
      gasForVerification: GAS,
      payloadSizeBytes: PAYLOAD
    });
    args[1] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(makeAddr("router")),
      remoteChainSelector: DEST_FLAT,
      allowlistEnabled: false,
      feeUSDCents: FLAT_FEE,
      gasForVerification: GAS,
      payloadSizeBytes: PAYLOAD
    });
    verifier.applyRemoteChainConfigUpdates(args);

    // bps policy on DEST only.
    verifier.setFeeConfig(
      DEST, CustomFeeConfig({ feeBps: FEE_BPS, minFeeUSDCents: MIN_CENTS, capUSDCents: CAP_CENTS, enabled: true })
    );

    // Per-token adapters.
    adapterA = new MockPriceAdapter(tokenA, 100_000); // $1000 / token
    adapterB = new MockPriceAdapter(tokenB, 50_000); // $500 / token
    verifier.setPriceAdapter(tokenA, IPriceAdapter(address(adapterA)));
    verifier.setPriceAdapter(tokenB, IPriceAdapter(address(adapterB)));
  }

  // --- helpers ---------------------------------------------------------------

  function _emptyMsg() internal pure returns (Client.EVM2AnyMessage memory m) {
    m.receiver = "";
    m.data = "";
    m.tokenAmounts = new Client.EVMTokenAmount[](0);
    m.feeToken = address(0);
    m.extraArgs = "";
  }

  function _msg(address token, uint256 amount) internal pure returns (Client.EVM2AnyMessage memory m) {
    m = _emptyMsg();
    m.tokenAmounts = new Client.EVMTokenAmount[](1);
    m.tokenAmounts[0] = Client.EVMTokenAmount({ token: token, amount: amount });
  }

  function _msg2(address t0, uint256 a0, address t1, uint256 a1)
    internal
    pure
    returns (Client.EVM2AnyMessage memory m)
  {
    m = _emptyMsg();
    m.tokenAmounts = new Client.EVMTokenAmount[](2);
    m.tokenAmounts[0] = Client.EVMTokenAmount({ token: t0, amount: a0 });
    m.tokenAmounts[1] = Client.EVMTokenAmount({ token: t1, amount: a1 });
  }

  function _fee(uint64 dest, Client.EVM2AnyMessage memory m) internal view returns (uint16 feeUSDCents) {
    (feeUSDCents,,) = verifier.getFee(dest, m, "", bytes4(0));
  }

  // --- fee math --------------------------------------------------------------

  function test_getFee_disabled_returnsFlatFee() public view {
    // DEST_FLAT has base config but no enabled bps policy.
    (uint16 fee, uint32 gas, uint32 payload) = verifier.getFee(DEST_FLAT, _msg(tokenA, 1e18), "", bytes4(0));
    assertEq(fee, FLAT_FEE, "flat fee");
    assertEq(gas, GAS, "gas passthrough");
    assertEq(payload, PAYLOAD, "payload passthrough");
  }

  function test_getFee_inRange_returnsBpsFee() public view {
    // 1 tokenA == $1000 == 100_000 cents; 100_000 * 5 / 10_000 = 50 cents.
    assertEq(_fee(DEST, _msg(tokenA, 1e18)), 50);
  }

  function test_getFee_belowFloor_returnsFloor() public view {
    // 0.01 tokenA == $10 == 1000 cents; 1000 * 5 / 10_000 = 0 -> floor 10.
    assertEq(_fee(DEST, _msg(tokenA, 1e16)), MIN_CENTS);
  }

  function test_getFee_aboveCap_returnsCap() public view {
    // 100 tokenA == $100k == 10_000_000 cents; *5/10_000 = 5000 -> cap 1000.
    assertEq(_fee(DEST, _msg(tokenA, 100e18)), CAP_CENTS);
  }

  function test_getFee_noTokens_returnsFloor() public view {
    // No token transfer -> value 0 -> floor.
    assertEq(_fee(DEST, _emptyMsg()), MIN_CENTS);
  }

  function test_getFee_multipleTokens_sumsValues() public view {
    // tokenA 1e18 -> 100_000, tokenB 1e18 -> 50_000; sum 150_000; *5/10_000 = 75.
    assertEq(_fee(DEST, _msg2(tokenA, 1e18, tokenB, 1e18)), 75);
  }

  function test_getFee_unregisteredToken_contributesZero() public view {
    // tokenA priced (100_000) + unpriced token (ignored) -> value 100_000 -> 50.
    assertEq(_fee(DEST, _msg2(tokenA, 1e18, tokenUnpriced, 5e18)), 50);
  }

  function test_getFee_hugeTransfer_capsWithoutRevert() public view {
    // Enormous amount must clamp to cap and never overflow the uint16 cast.
    (uint16 fee,,) = verifier.getFee(DEST, _msg(tokenA, 1e30), "", bytes4(0));
    assertEq(fee, CAP_CENTS);
  }

  function testFuzz_getFee_withinBounds(uint256 amount) public view {
    amount = bound(amount, 0, 1e33);
    uint16 fee = _fee(DEST, _msg(tokenA, amount));
    assertLe(fee, CAP_CENTS, "never above cap");
    assertGe(fee, MIN_CENTS, "never below floor (enabled)");
  }

  // --- access control --------------------------------------------------------

  function test_setFeeConfig_onlyOwner() public {
    vm.prank(stranger);
    vm.expectRevert();
    verifier.setFeeConfig(DEST, CustomFeeConfig({ feeBps: 1, minFeeUSDCents: 1, capUSDCents: 2, enabled: true }));
  }

  function test_setPriceAdapter_onlyOwner() public {
    vm.prank(stranger);
    vm.expectRevert();
    verifier.setPriceAdapter(tokenA, IPriceAdapter(address(adapterA)));
  }

  function test_setPriceAdapters_onlyOwner() public {
    address[] memory tokens = new address[](1);
    IPriceAdapter[] memory adapters = new IPriceAdapter[](1);
    tokens[0] = tokenA;
    adapters[0] = IPriceAdapter(address(adapterA));
    vm.prank(stranger);
    vm.expectRevert();
    verifier.setPriceAdapters(tokens, adapters);
  }

  // --- validation ------------------------------------------------------------

  function test_setFeeConfig_revertsWhenCapBelowFloor() public {
    vm.expectRevert(abi.encodeWithSelector(CustomFeeCommitteeVerifier.CapBelowFloor.selector, uint16(50), uint16(100)));
    verifier.setFeeConfig(DEST, CustomFeeConfig({ feeBps: 5, minFeeUSDCents: 100, capUSDCents: 50, enabled: true }));
  }

  function test_setFeeConfig_revertsWhenFeeBpsTooHigh() public {
    vm.expectRevert(abi.encodeWithSelector(CustomFeeCommitteeVerifier.FeeBpsTooHigh.selector, uint16(10_001)));
    verifier.setFeeConfig(DEST, CustomFeeConfig({ feeBps: 10_001, minFeeUSDCents: 1, capUSDCents: 2, enabled: true }));
  }

  function test_getFee_revertsForUnconfiguredChain() public {
    vm.expectRevert(abi.encodeWithSelector(BaseVerifier.RemoteChainNotSupported.selector, UNCONFIGURED));
    verifier.getFee(UNCONFIGURED, _msg(tokenA, 1e18), "", bytes4(0));
  }

  function test_setFeeConfig_revertsWhenEnablingUnconfiguredLane() public {
    vm.expectRevert(abi.encodeWithSelector(BaseVerifier.RemoteChainNotSupported.selector, UNCONFIGURED));
    verifier.setFeeConfig(
      UNCONFIGURED, CustomFeeConfig({ feeBps: 5, minFeeUSDCents: 10, capUSDCents: 1000, enabled: true })
    );
  }

  function test_setFeeConfig_allowsDisablingUnconfiguredLane() public {
    // Disabling a lane never needs a base config (the check is enabled-only).
    verifier.setFeeConfig(
      UNCONFIGURED, CustomFeeConfig({ feeBps: 5, minFeeUSDCents: 10, capUSDCents: 1000, enabled: false })
    );
    assertFalse(verifier.getFeeConfig(UNCONFIGURED).enabled);
  }

  function test_getFee_revertsForDisallowedFinality() public {
    verifier.setAllowedFinalityConfig(bytes4(uint32(100))); // allow block depth >= 100
    vm.expectRevert(
      abi.encodeWithSelector(FinalityCodec.InvalidRequestedFinality.selector, bytes4(uint32(50)), bytes4(uint32(100)))
    );
    verifier.getFee(DEST, _msg(tokenA, 1e18), "", bytes4(uint32(50))); // depth 50 < 100 -> disallowed
  }

  function test_getFee_allowsPermittedFinality() public {
    verifier.setAllowedFinalityConfig(bytes4(uint32(100)));
    // depth 150 >= 100 is allowed; getFee proceeds and returns the in-range bps fee.
    (uint16 fee,,) = verifier.getFee(DEST, _msg(tokenA, 1e18), "", bytes4(uint32(150)));
    assertEq(fee, 50);
  }

  function test_setFeeConfig_revertsWhenEnabledWithZeroFloor() public {
    vm.expectRevert(CustomFeeCommitteeVerifier.MinFeeMustBeNonZero.selector);
    verifier.setFeeConfig(DEST, CustomFeeConfig({ feeBps: 5, minFeeUSDCents: 0, capUSDCents: 1000, enabled: true }));
  }

  function test_setFeeConfig_allowsZeroFloorWhenDisabled() public {
    // Disabled lanes fall back to the inherited flat fee, so a zero floor is fine.
    verifier.setFeeConfig(
      DEST_FLAT, CustomFeeConfig({ feeBps: 5, minFeeUSDCents: 0, capUSDCents: 1000, enabled: false })
    );
    assertFalse(verifier.getFeeConfig(DEST_FLAT).enabled);
    assertEq(verifier.getFeeConfig(DEST_FLAT).minFeeUSDCents, 0);
  }

  function test_setFeeConfig_allowsZeroBpsWithNonZeroFloor() public {
    // feeBps == 0 with a non-zero floor is a legitimate flat-fee-via-floor lane.
    verifier.setFeeConfig(DEST, CustomFeeConfig({ feeBps: 0, minFeeUSDCents: 10, capUSDCents: 1000, enabled: true }));
    assertEq(verifier.getFeeConfig(DEST).feeBps, 0);
    assertTrue(verifier.getFeeConfig(DEST).enabled);
  }

  function test_setPriceAdapter_revertsOnZeroToken() public {
    vm.expectRevert(CustomFeeCommitteeVerifier.ZeroToken.selector);
    verifier.setPriceAdapter(address(0), IPriceAdapter(address(adapterA)));
  }

  function test_setPriceAdapters_revertsOnLengthMismatch() public {
    address[] memory tokens = new address[](2);
    IPriceAdapter[] memory adapters = new IPriceAdapter[](1);
    vm.expectRevert(CustomFeeCommitteeVerifier.LengthMismatch.selector);
    verifier.setPriceAdapters(tokens, adapters);
  }

  function test_setPriceAdapter_revertsOnTokenMismatch() public {
    // adapterA prices tokenA; registering it under tokenB must revert.
    vm.expectRevert(abi.encodeWithSelector(CustomFeeCommitteeVerifier.AdapterTokenMismatch.selector, tokenB, tokenA));
    verifier.setPriceAdapter(tokenB, IPriceAdapter(address(adapterA)));
  }

  function test_setPriceAdapter_revertsOnNonContractAdapter() public {
    // An EOA "adapter" has no code, so adapter.token() reverts and registration fails.
    vm.expectRevert();
    verifier.setPriceAdapter(tokenA, IPriceAdapter(makeAddr("notAnAdapter")));
  }

  function test_setPriceAdapter_allowsClearing() public {
    // Clearing (adapter == 0) skips the token() check.
    verifier.setPriceAdapter(tokenA, IPriceAdapter(address(0)));
    assertEq(address(verifier.getPriceAdapter(tokenA)), address(0));
  }

  // --- getters ---------------------------------------------------------------

  function test_getters_roundtrip() public view {
    CustomFeeConfig memory cfg = verifier.getFeeConfig(DEST);
    assertEq(cfg.feeBps, FEE_BPS);
    assertTrue(cfg.enabled);
    assertEq(address(verifier.getPriceAdapter(tokenA)), address(adapterA));
    assertEq(address(verifier.getPriceAdapter(tokenUnpriced)), address(0));
  }
}
